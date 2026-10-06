#!/usr/bin/env bash
# veth / policy-routing glue that connects the WARP namespace to the container's
# namespace, and steers Tailscale exit-node traffic into it.
#
# Topology (all-in-one mode):
#
#   root netns                          warpns
#   ┌───────────────────────────┐       ┌───────────────────────────┐
#   │ tailscaled (exit node)    │       │ warp-svc                  │
#   │  tailscale0 100.x.y.z     │       │  CloudflareWARP (tun)     │
#   │                           │       │                           │
#   │ eth0 ──► internet         │       │ default via 10.200.0.1    │
#   │ veth-host 10.200.0.1/30 ◄─┼───────┼─► veth0 10.200.0.2/30     │
#   └───────────────────────────┘       └───────────────────────────┘
#
#   root:   ip rule iif tailscale0 lookup 200
#           ip route default via 10.200.0.2 dev veth-host table 200
#   warpns: ip rule iif veth0 lookup <warp-table>   (forwarded traffic -> tun)
#           nft masquerade oifname CloudflareWARP
#
# Why the WARP client is not simply run in the container namespace: its
# nftables `input` chain is `policy drop`, so inbound direct WireGuard from
# tailnet peers is discarded. See
# https://github.com/tailscale/tailscale/issues/15288
#
# Why iif-based policy routing instead of a plain default route in the root
# namespace: WARP's WireGuard underlay also traverses this veth. Sending
# everything to 10.200.0.2 would bounce the underlay back and loop. Matching on
# the ingress interface separates "client traffic to be tunnelled" (arrives on
# tailscale0) from "WARP's own encrypted underlay" (arrives on veth-host, which
# keeps using the real default route out of eth0).
# shellcheck shell=bash

set -euo pipefail

VETH_HOST_IF="${VETH_HOST_IF:-veth-host}"
VETH_WARP_IF="${VETH_WARP_IF:-veth0}"
VETH_HOST_IP="${VETH_HOST_IP:-10.200.0.1}"
VETH_WARP_IP="${VETH_WARP_IP:-10.200.0.2}"
VETH_PREFIX="${VETH_PREFIX:-30}"
WARP_ROUTE_TABLE="${WARP_ROUTE_TABLE:-200}"
TS_TUN_IFACE="${TS_TUN_IFACE:-tailscale0}"
WARP_TUN_IFACE="${WARP_TUN_IFACE:-CloudflareWARP}"

# ---------------------------------------------------------------------------
# nft helpers. Two flavours: one inside the WARP namespace, one in the root
# namespace. In warp-only mode WARP_NETNS is empty and they coincide.
# ---------------------------------------------------------------------------
_nft() { ns_run nft "$@"; }

nft_table()   { _nft list table   "$1" "$2" >/dev/null 2>&1 || _nft add table   "$1" "$2"; }
nft_chain()   { _nft list chain   "$1" "$2" "$3" >/dev/null 2>&1 || _nft add chain "$1" "$2" "$3" "$4"; }
nft_has()     { _nft list chain "$1" "$2" "$3" 2>/dev/null | grep -q "$4"; }
nft_rule()    { _nft add rule "$@"; }

root_nft_table() { nft list table "$1" "$2" >/dev/null 2>&1 || nft add table "$1" "$2"; }
root_nft_chain() { nft list chain "$1" "$2" "$3" >/dev/null 2>&1 || nft add chain "$1" "$2" "$3" "$4"; }
root_nft_has()   { nft list chain "$1" "$2" "$3" 2>/dev/null | grep -q "$4"; }
root_nft_rule()  { nft add rule "$@"; }

# ---------------------------------------------------------------------------
# veth pair between the root namespace and the WARP namespace
# ---------------------------------------------------------------------------

setup_veth_pair() {
    local ns="$1"
    local pid
    pid="$(_ns_pid)" || die "No network namespace is held; call ns_create first."

    if ip link show "$VETH_HOST_IF" >/dev/null 2>&1; then
        log_debug "veth ${VETH_HOST_IF} already present"
        return 0
    fi

    log_info "Creating veth pair ${VETH_HOST_IF} <-> ${VETH_WARP_IF} (ns ${ns})"
    ip link add "$VETH_HOST_IF" type veth peer name "$VETH_WARP_IF"
    # Move the peer into the held namespace by PID.
    ip link set "$VETH_WARP_IF" netns "$pid"

    ip addr add "${VETH_HOST_IP}/${VETH_PREFIX}" dev "$VETH_HOST_IF"
    ip link set "$VETH_HOST_IF" up
    sysctl -qw "net.ipv4.conf.${VETH_HOST_IF}.rp_filter=0" 2>/dev/null || true

    ns_run ip addr add "${VETH_WARP_IP}/${VETH_PREFIX}" dev "$VETH_WARP_IF"
    ns_run ip link set "$VETH_WARP_IF" up
    ns_run ip link set lo up
    sysctl -qw net.ipv4.conf.all.forwarding=1 2>/dev/null || true
}

# The WARP namespace needs an underlay route so warp-svc can reach the
# Cloudflare edge; its tunnelled default route is installed by WARP itself.
setup_warpns_underlay() {
    local ns="$1"
    ns_run ip route replace default via "$VETH_HOST_IP" dev "$VETH_WARP_IF"

    # Point the *namespace's* resolver at Cloudflare for the registration
    # handshake. WARP later replaces it with its own 127.0.2.2/127.0.2.3
    # resolver, reachable only inside this namespace -- which is exactly why the
    # namespace gets its own /etc/resolv.conf.
    #
    # Never write the root namespace's /etc/resolv.conf here. Doing that is what
    # broke DNS for tailscaled and every other process in the container: WARP's
    # rewrite leaked out of the namespace and left the root side pointing at a
    # resolver that does not exist there.
    mkdir -p "$(dirname "$WARP_RESOLV_CONF")"
    printf 'nameserver 1.1.1.1\nnameserver 1.0.0.1\n' > "$WARP_RESOLV_CONF"
    ns_isolate_resolv_conf || true

    log_info "warpns underlay: default via ${VETH_HOST_IP} dev ${VETH_WARP_IF}"
    log_debug "root resolv.conf : $(cat /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
    log_debug "warpns resolv.conf: $(ns_run cat /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
}

# The root namespace masquerades the WARP underlay as it leaves the container.
setup_root_underlay_nat() {
    local egress_if="$1"
    root_nft_table ip nat
    root_nft_chain ip nat postrouting '{ type nat hook postrouting priority srcnat; policy accept; }'
    if ! root_nft_has ip nat postrouting "cfw2tsen-underlay"; then
        root_nft_rule ip nat postrouting \
            oifname "$egress_if" ip saddr "${VETH_HOST_IP}/${VETH_PREFIX}" \
            counter masquerade comment "cfw2tsen-underlay"
    fi
    log_debug "Underlay NAT via ${egress_if}"
}

# ---------------------------------------------------------------------------
# WARP's own routing table
#
# The client steers its tunnel with `ip rule not from all fwmark <mark> lookup
# <table>`, where the table holds a default route via the tunnel device. That
# rule only fires for the client's own sockets, so forwarded traffic needs an
# explicit rule pointing at the same table.
# ---------------------------------------------------------------------------

# Echo the routing table that holds the tunnel's default route, or the
# configured fallback when it cannot be discovered.
detect_warp_table() {
    local tun="$1" table=""

    # Preferred: ask the kernel which table routes a probe address.
    table="$(ns_run sh -c "ip route get 1.1.1.1 2>/dev/null" | sed -n 's/.* table \([0-9]\{1,\}\).*/\1/p' | head -n1 || true)"
    if [ -n "$table" ]; then
        printf '%s' "$table"
        return 0
    fi

    # Fallback: find any table with a default route via the tunnel device.
    local t
    for t in $(ns_run sh -c "ip route show table all 2>/dev/null" | awk '/^default/ && /table/ {for(i=1;i<=NF;i++) if($i=="table") print $(i+1)}' | sort -u); do
        if ns_run ip route show table "$t" 2>/dev/null | grep -q "$tun"; then
            printf '%s' "$t"
            return 0
        fi
    done

    printf '%s' "${WARP_ROUTE_TABLE_FALLBACK:-65743}"
}

# Route traffic arriving from the veth into the tunnel's table, so that packets
# forwarded on behalf of tailnet clients actually egress through WARP.
setup_warpns_forwarding() {
    local tun="$1" table="$2"
    local tailnet="${TS_TAILNET_CIDR:-100.64.0.0/10}"
    # In warp-only mode there is no veth: clients reach this container over the
    # Docker bridge, so the ingress interface is the container's own eth0 and
    # the return path is that same subnet.
    local ingress="${VETH_WARP_IF}" return_if="${VETH_WARP_IF}"
    local return_via="${VETH_HOST_IP}"

    if ! ns_run ip link show "${VETH_WARP_IF}" >/dev/null 2>&1; then
        ingress="$(ns_run ip route show default | awk '/^default/ {print $5; exit}')"
        [ -z "$ingress" ] && ingress="eth0"
        return_if="$ingress"
        return_via=""
        log_info "No ${VETH_WARP_IF}; forwarding for ingress ${ingress} (bridge mode)"
    fi

    if ! ns_run ip rule show | grep -qF "iif ${ingress} lookup ${table}"; then
        ns_run ip rule add iif "$ingress" lookup "$table" pref 1000
    fi

    # Return path. WARP's rule sends *every* unmarked packet to its tunnel
    # table, whose only route is the tunnel default. A reply coming back for a
    # forwarded flow would therefore be sent straight back into the tunnel.
    # Pin the tailnet range to the main table, which reaches the client.
    if ! ns_run ip rule show | grep -qF "to ${tailnet} lookup main"; then
        ns_run ip rule add to "$tailnet" lookup main pref 900
    fi
    if [ -n "$return_via" ]; then
        ns_run ip route replace "$tailnet" via "$return_via" dev "$return_if"
    fi

    if ! ns_run ip rule show | grep -qF "lookup ${table}"; then
        log_warn "WARP's policy rule for table ${table} is missing; the tunnel may not carry traffic."
    fi

    log_info "forwarding: iif ${ingress} -> table ${table}; return ${tailnet} -> main${return_via:+ via ${return_via}}"
}

# ---------------------------------------------------------------------------
# NAT + MSS clamping inside the WARP namespace
# ---------------------------------------------------------------------------

setup_warpns_nat() {
    local tun="$1"

    nft_table ip nat
    nft_chain ip nat postrouting '{ type nat hook postrouting priority srcnat; policy accept; }'
    if ! nft_has ip nat postrouting "cfw2tsen-warpnat"; then
        nft_rule ip nat postrouting oifname "$tun" counter masquerade comment "cfw2tsen-warpnat"
    fi

    if _nft add table ip6 nat 2>/dev/null || _nft list table ip6 nat >/dev/null 2>&1; then
        nft_chain ip6 nat postrouting '{ type nat hook postrouting priority srcnat; policy accept; }'
        if ! nft_has ip6 nat postrouting "cfw2tsen-warpnat6"; then
            nft_rule ip6 nat postrouting oifname "$tun" counter masquerade comment "cfw2tsen-warpnat6" 2>/dev/null || true
        fi
    fi

    # A tunnel inside a tunnel shrinks the usable MTU. Without clamping, large
    # TCP segments are black-holed rather than fragmented.
    nft_table ip mangle
    nft_chain ip mangle forward '{ type filter hook forward priority mangle; policy accept; }'
    if ! nft_has ip mangle forward "cfw2tsen-mss"; then
        nft_rule ip mangle forward oifname "$tun" \
            tcp flags syn tcp option maxseg size set rt mtu comment "cfw2tsen-mss"
    fi

    log_info "warpns NAT: masquerade on ${tun} + MSS clamp"
}

# ---------------------------------------------------------------------------
# Steering exit-node traffic into the WARP namespace
# ---------------------------------------------------------------------------

setup_exit_steering() {
    local rule="iif ${TS_TUN_IFACE} lookup ${WARP_ROUTE_TABLE}"

    if ! ip rule show | grep -qF "$rule"; then
        ip rule add iif "$TS_TUN_IFACE" lookup "$WARP_ROUTE_TABLE" pref 1000
    fi
    ip route replace default via "$VETH_WARP_IP" dev "$VETH_HOST_IF" table "$WARP_ROUTE_TABLE"

    # Only ingress on the tunnel interface is steered. A source-address rule
    # (for example "from 100.64.0.0/10") would also capture tailscaled's own
    # locally-generated packets, which share that source range and must keep
    # using the real interface to reach the control plane and DERP relays.
    root_nft_table ip mangle
    root_nft_chain ip mangle forward '{ type filter hook forward priority mangle; policy accept; }'
    if ! root_nft_has ip mangle forward "cfw2tsen-rootmss"; then
        root_nft_rule ip mangle forward oifname "$VETH_HOST_IF" \
            tcp flags syn tcp option maxseg size set rt mtu comment "cfw2tsen-rootmss"
    fi

    # Tailscale installs its own rules; make sure ours stay in front of them.
    if ! ip rule show | grep -qF "$rule"; then
        log_warn "Exit-node steering rule disappeared immediately after being added"
    fi

    log_info "Exit-node traffic (iif ${TS_TUN_IFACE}) -> ${VETH_WARP_IP} table ${WARP_ROUTE_TABLE}"
}

teardown_exit_steering() {
    ip rule del iif "$TS_TUN_IFACE" lookup "$WARP_ROUTE_TABLE" pref 1000 2>/dev/null || true
    ip route flush table "$WARP_ROUTE_TABLE" 2>/dev/null || true
}

# The container itself is a router, so its own forward hook must accept the
# traffic we are steering. WARP sets its own tables to policy drop, which is
# exactly why this rule lives in a separate table.
setup_forward_accept() {
    nft_table inet cfw2tsen
    nft_chain inet cfw2tsen forward '{ type filter hook forward priority 0; policy accept; }'
    root_nft_table inet cfw2tsen
    root_nft_chain inet cfw2tsen forward '{ type filter hook forward priority 0; policy accept; }'
    log_debug "Forwarding accepted via inet cfw2tsen"
}

# Prove that name resolution works on BOTH sides of the namespace boundary.
#
# These are separate resolvers on purpose: the root namespace (tailscaled, and
# the exit node's DNS forwarding) uses the container's resolver, while WARP uses
# its own 127.0.2.2 resolver inside the namespace. A shared /etc/resolv.conf
# makes one of them point at a resolver that does not exist in that namespace,
# which surfaces to users as "DNS is broken".
verify_dns() {
    [ -n "${WARP_NETNS:-}" ] || return 0

    local root_ok=0 warp_ok=0
    local root_ns warp_ns

    root_ns="$(cat /etc/resolv.conf 2>/dev/null | awk '/^nameserver/ {printf "%s ", $2}')"
    warp_ns="$(ns_run cat /etc/resolv.conf 2>/dev/null | awk '/^nameserver/ {printf "%s ", $2}')"

    # Resolve through the root namespace's resolver.
    if getent hosts one.one.one.one >/dev/null 2>&1 || \
       curl -fsS --max-time 10 -o /dev/null https://one.one.one.one 2>/dev/null; then
        root_ok=1
    fi
    # Resolve through the namespace's resolver.
    if ns_run getent hosts one.one.one.one >/dev/null 2>&1 || \
       ns_run curl -fsS --max-time 10 -o /dev/null https://one.one.one.one 2>/dev/null; then
        warp_ok=1
    fi

    log_info "DNS root namespace  [${root_ns% }] : $([ "$root_ok" = 1 ] && echo ok || echo FAILED)"
    log_info "DNS warp namespace  [${warp_ns% }] : $([ "$warp_ok" = 1 ] && echo ok || echo FAILED)"

    if [ "$root_ok" != 1 ] || [ "$warp_ok" != 1 ]; then
        if ! ns_has_mount_isolation; then
            log_error "The WARP namespace shares /etc/resolv.conf with the container."
            log_error "WARP rewrites that file to 127.0.2.2, which only exists inside the namespace."
        fi
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Introspection used by the entrypoint, healthcheck and tsctl
# ---------------------------------------------------------------------------

# Print the interface the container actually reaches the internet through.
detect_egress_iface() {
    local iface
    iface="$(ip route show default 2>/dev/null | awk '/^default/ {print $5; exit}')"
    if [ -z "$iface" ]; then
        iface="$(ip -o link show up 2>/dev/null | awk -F': ' '$2 != "lo" {print $2; exit}')"
    fi
    printf '%s' "${iface:-eth0}"
}

# Print the WARP tunnel interface name, tolerating version differences.
detect_warp_tun() {
    local want="$1" found
    found="$(ns_run ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -ix "$want" || true)"
    if [ -n "$found" ]; then
        printf '%s' "$found"
        return 0
    fi
    found="$(ns_run ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -i 'cloudflare' || true)"
    printf '%s' "${found:-$want}"
}

# Prove that traffic entering the veth is actually tunnelled.
#
# Binding a source address is not enough: the kernel still routes the packet
# out the ordinary default route, so nothing is forwarded and the check would
# pass even with broken steering. Instead run a throwaway process *inside a
# fresh network namespace* whose only path out is the veth, which is the same
# situation an exit-node client's packet is in.
verify_forwarded_egress() {
    [ "$(env_bool WARP_VERIFY_EGRESS 1)" = "1" ] || return 0
    [ -n "${WARP_NETNS:-}" ] || return 0

    # The probe gets its own /30: the WARP veth already owns VETH_HOST_IP and
    # VETH_WARP_IP, so reusing that subnet would collide.
    local probe_if="probe0"
    local probe_host_ip="${PROBE_HOST_IP:-10.201.0.1}"
    local probe_ns_ip="${PROBE_NS_IP:-10.201.0.2}"
    local probe_pid=""

    # A probe namespace is created the same way as the WARP one (unshare +
    # nsenter), because `ip netns add` is blocked by Docker's AppArmor profile.
    probe_run() { nsenter --net="/proc/${probe_pid}/ns/net" -- "$@"; }

    cleanup_probe() {
        [ -n "$probe_pid" ] || return 0
        kill -TERM "$probe_pid" 2>/dev/null || true
        sleep 0.1
        kill -KILL "$probe_pid" 2>/dev/null || true
        wait "$probe_pid" 2>/dev/null || true
        probe_pid=""
    }

    unshare --net -- sleep infinity &
    probe_pid=$!
    local waited=0
    while [ ! -e "/proc/${probe_pid}/ns/net" ] && (( waited < 50 )); do
        sleep 0.1
        waited=$(( waited + 1 ))
    done
    if [ ! -e "/proc/${probe_pid}/ns/net" ]; then
        log_warn "Could not create a probe namespace; skipping forwarded egress verification"
        cleanup_probe
        return 0
    fi

    if ! ip link add "$probe_if" type veth peer name "${probe_if}-p" 2>/dev/null; then
        log_warn "Could not create a probe veth; skipping forwarded egress verification"
        cleanup_probe
        return 0
    fi
    ip link set "${probe_if}-p" netns "$probe_pid"
    ip addr add "${probe_host_ip}/30" dev "$probe_if"
    ip link set "$probe_if" up
    probe_run ip addr add "${probe_ns_ip}/30" dev "${probe_if}-p"
    probe_run ip link set "${probe_if}-p" up
    probe_run ip link set lo up
    # The probe has no other interface, so everything it sends must be
    # forwarded by this container -- exactly the exit-node client's situation.
    probe_run ip route add default via "$probe_host_ip" dev "${probe_if}-p"

    # Steer only what arrives on the probe interface, so this does not disturb
    # the real tailscale0 rule.
    if ! ip rule show | grep -qF "iif ${probe_if} lookup ${WARP_ROUTE_TABLE}"; then
        ip rule add iif "$probe_if" lookup "$WARP_ROUTE_TABLE" pref 1001
    fi
    ip route replace default via "$VETH_WARP_IP" dev "$VETH_HOST_IF" table "$WARP_ROUTE_TABLE" 2>/dev/null || true
    nft_table inet cfw2tsen
    nft_chain inet cfw2tsen forward '{ type filter hook forward priority 0; policy accept; }'

    local trace warp ip
    trace="$(probe_run curl -fsS --max-time 20 \
             https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"

    ip rule del iif "$probe_if" lookup "$WARP_ROUTE_TABLE" pref 1001 2>/dev/null || true
    ip link del "$probe_if" 2>/dev/null || true
    cleanup_probe

    if [ -z "$trace" ]; then
        log_warn "Could not verify forwarded egress through the veth (no response)"
        return 1
    fi
    warp="$(grep -E '^warp=' <<<"$trace" | cut -d= -f2- || true)"
    ip="$(grep -E '^ip=' <<<"$trace" | cut -d= -f2- || true)"
    if [ "${warp:-}" = "on" ]; then
        log_info "Forwarded egress verified through WARP: ip=${ip:-?}"
        return 0
    fi
    log_warn "Forwarded traffic is NOT egressing through WARP (warp=${warp:-unknown}, ip=${ip:-?})"
    return 1
}
