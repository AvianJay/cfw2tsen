#!/usr/bin/env bash
# Plumbing smoke test.
#
# Brings up the namespace, veth and policy routing *without* contacting
# Cloudflare or Tailscale, then asserts the resulting topology. This is what CI
# runs, because the parts most likely to break are the routing rules and the
# nftables chains, not the vendor binaries.
#
# Enabled with SMOKE_TEST=1. Exits 0 on success, 1 on the first failed
# assertion, after printing the full state dump.
set -uo pipefail

LOG_LEVEL="${LOG_LEVEL:-info}"

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib.sh
. "${SELF_DIR}/lib.sh"
# shellcheck source=netns.sh
. "${SELF_DIR}/netns.sh"

fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$(( fail + 1 )); }

echo "cfw2tsen plumbing smoke test (netns=${WARP_NETNS:-<root>})"

# A stand-in for tailscale0, so the steering rule has a real device to match.
# A veth pair is used instead of a dummy device because the dummy module is not
# always available in a container.
create_stub_tailscale_iface() {
    local iface="${TS_TUN_IFACE:-tailscale0}"
    if ip link show "$iface" >/dev/null 2>&1; then
        return 0
    fi
    ip link add "$iface" type veth peer name ts-stub-peer 2>/dev/null \
        || ip link add "$iface" type dummy 2>/dev/null \
        || { log_warn "Could not create a stub ${iface}"; return 1; }
    ip link set "$iface" up
    log_debug "Created stub interface ${iface}"
}

dump_state() {
    echo
    echo "--- namespace holder ---"
    _ns_pid 2>/dev/null | sed 's/^/  pid /' || echo "  (none)"
    echo "--- root links ---"
    ip -brief addr show 2>&1 || true
    echo "--- root rules ---"
    ip rule show 2>&1 || true
    echo "--- root table ${WARP_ROUTE_TABLE:-200} ---"
    ip route show table "${WARP_ROUTE_TABLE:-200}" 2>&1 || true
    if [ -n "${WARP_NETNS:-}" ] && ns_exists; then
        echo "--- ${WARP_NETNS} links ---"
        ns_run ip -brief addr show 2>&1 || true
        echo "--- ${WARP_NETNS} routes ---"
        ns_run ip route show 2>&1 || true
        echo "--- ${WARP_NETNS} rules ---"
        ns_run ip rule show 2>&1 || true
        echo "--- ${WARP_NETNS} nft ---"
        ns_run nft list ruleset 2>&1 || true
    fi
    echo "--- root nft ---"
    nft list ruleset 2>&1 || true
    echo
}

echo
echo "== namespace and veth =="

if [ -n "${WARP_NETNS:-}" ]; then
    if ns_exists; then
        ok "netns ${WARP_NETNS} is held (pid $(_ns_pid))"
    else
        bad "netns ${WARP_NETNS} is missing"
    fi

    if ip link show "${VETH_HOST_IF:-veth-host}" >/dev/null 2>&1; then
        ok "veth host side ${VETH_HOST_IF:-veth-host} exists"
    else
        bad "veth host side ${VETH_HOST_IF:-veth-host} is missing"
    fi

    if ns_run ip link show "${VETH_WARP_IF:-veth0}" >/dev/null 2>&1; then
        ok "veth peer ${VETH_WARP_IF:-veth0} is inside ${WARP_NETNS}"
    else
        bad "veth peer ${VETH_WARP_IF:-veth0} is not in ${WARP_NETNS}"
    fi

    if ip addr show "${VETH_HOST_IF:-veth-host}" 2>/dev/null | grep -q "${VETH_HOST_IP:-10.200.0.1}"; then
        ok "host side has ${VETH_HOST_IP:-10.200.0.1}"
    else
        bad "host side is missing ${VETH_HOST_IP:-10.200.0.1}"
    fi

    if ns_run ip route show 2>/dev/null | grep -q "via ${VETH_HOST_IP:-10.200.0.1}"; then
        ok "warpns has an underlay default route"
    else
        bad "warpns has no underlay default route"
    fi
else
    ok "no netns configured (warp-only without isolation)"
fi

echo
echo "== steering =="

if [ -n "${WARP_NETNS:-}" ]; then
    create_stub_tailscale_iface
    setup_forward_accept
    setup_exit_steering

    if ip rule show | grep -qF "iif ${TS_TUN_IFACE:-tailscale0} lookup ${WARP_ROUTE_TABLE:-200}"; then
        ok "ingress rule on ${TS_TUN_IFACE:-tailscale0} -> table ${WARP_ROUTE_TABLE:-200}"
    else
        bad "ingress rule on ${TS_TUN_IFACE:-tailscale0} is missing"
    fi

    # A source-address rule would capture tailscaled's own control-plane
    # traffic, which must leave via eth0. Assert we did not add one.
    if ip rule show | grep -qE "from (100\.64\.0\.0/10|${TS_TAILNET_CIDR:-100\.64\.0\.0/10}).*lookup ${WARP_ROUTE_TABLE:-200}"; then
        bad "a source-address steering rule exists and would capture tailscaled's own traffic"
    else
        ok "no source-address rule (tailscaled keeps its own egress path)"
    fi

    if ip route show table "${WARP_ROUTE_TABLE:-200}" | grep -q "via ${VETH_WARP_IP:-10.200.0.2}"; then
        ok "table ${WARP_ROUTE_TABLE:-200} defaults via ${VETH_WARP_IP:-10.200.0.2}"
    else
        bad "table ${WARP_ROUTE_TABLE:-200} has no route via ${VETH_WARP_IP:-10.200.0.2}"
    fi

    # The steering rule must win over the main table for tunnel-bound traffic.
    pref_steer="$(ip rule show | awk -v pat="iif ${TS_TUN_IFACE:-tailscale0} lookup ${WARP_ROUTE_TABLE:-200}" 'index($0, pat) {print $1}' | tr -d ':' | head -n1)"
    pref_main="$(ip rule show | awk '/lookup main/ {print $1}' | tr -d ':' | head -n1)"
    if [ -n "$pref_steer" ] && [ -n "$pref_main" ] && [ "$pref_steer" -lt "$pref_main" ]; then
        ok "steering rule (${pref_steer}) precedes the main table (${pref_main})"
    else
        bad "steering rule does not precede the main table (${pref_steer:-?} vs ${pref_main:-?})"
    fi
fi

echo
echo "== forwarding and nftables =="

# The WARP namespace must not send replies for forwarded flows back into the
# tunnel; the tailnet range has to be pinned to the main table. Exercise the
# real function rather than asserting on state nothing created.
if [ -n "${WARP_NETNS:-}" ]; then
    tailnet="${TS_TAILNET_CIDR:-100.64.0.0/10}"

    # A fake tunnel device inside the namespace, so the NAT/MSS rules that
    # reference it by name can actually be installed and inspected.
    if ! ns_run ip link show "${WARP_TUN_IFACE:-CloudflareWARP}" >/dev/null 2>&1; then
        ns_run ip link add "${WARP_TUN_IFACE:-CloudflareWARP}" type dummy 2>/dev/null \
            || ns_run ip link add "${WARP_TUN_IFACE:-CloudflareWARP}" type veth peer name warp-tun-peer 2>/dev/null \
            || log_warn "Could not create a stub ${WARP_TUN_IFACE:-CloudflareWARP} device"
        ns_run ip link set "${WARP_TUN_IFACE:-CloudflareWARP}" up 2>/dev/null || true
    fi

    setup_warpns_forwarding "${WARP_TUN_IFACE:-CloudflareWARP}" "${WARP_ROUTE_TABLE:-200}"
    setup_warpns_nat "${WARP_TUN_IFACE:-CloudflareWARP}"

    if ns_run ip rule show | grep -qF "iif ${VETH_WARP_IF:-veth0} lookup ${WARP_ROUTE_TABLE:-200}"; then
        ok "warpns steers veth ingress into table ${WARP_ROUTE_TABLE:-200}"
    else
        bad "warpns does not steer veth ingress into the tunnel table"
    fi

    if ns_run ip rule show | grep -qF "to ${tailnet} lookup main"; then
        ok "warpns pins ${tailnet} to the main table (return path)"
    else
        bad "warpns has no return-path rule for ${tailnet}"
    fi
    if ns_run ip route show | grep -q "via ${VETH_HOST_IP:-10.200.0.1}.*${VETH_WARP_IF:-veth0}"; then
        ok "warpns routes ${tailnet} back via ${VETH_HOST_IP:-10.200.0.1}"
    else
        bad "warpns has no explicit route back to the host for the tailnet range"
    fi

    # The return-path rule must be evaluated before WARP's own tunnel rule.
    pref_return="$(ns_run ip rule show | awk -v pat="to ${tailnet} lookup main" 'index($0, pat) {print $1}' | tr -d ':' | head -n1)"
    pref_tunnel="$(ns_run ip rule show | awk -v pat="lookup ${WARP_ROUTE_TABLE:-200}" 'index($0, pat) {print $1}' | tr -d ':' | head -n1)"
    if [ -n "$pref_return" ] && [ -n "$pref_tunnel" ] && [ "$pref_return" -lt "$pref_tunnel" ]; then
        ok "return-path rule (${pref_return}) precedes tunnel steering (${pref_tunnel})"
    else
        bad "return-path rule does not precede tunnel steering (${pref_return:-?} vs ${pref_tunnel:-?})"
    fi

    if ns_run nft list chain ip nat postrouting 2>/dev/null | grep -q "cfw2tsen-warpnat"; then
        ok "warpns masquerades forwarded traffic onto the tunnel"
    else
        bad "warpns has no masquerade rule for the tunnel device"
    fi
    if ns_run nft list chain ip mangle forward 2>/dev/null | grep -q "cfw2tsen-mss"; then
        ok "warpns clamps MSS on the tunnel device"
    else
        bad "warpns has no MSS clamp rule"
    fi
fi

if nft list chain inet cfw2tsen forward >/dev/null 2>&1; then
    ok "inet cfw2tsen forward chain exists"
else
    bad "inet cfw2tsen forward chain is missing"
fi

if [ -n "${WARP_NETNS:-}" ]; then
    # setup_warpns_nat already created these; assert they are present rather
    # than only creatable, since the rules above depend on them.
    if ns_run nft list chain ip nat postrouting >/dev/null 2>&1; then
        ok "warpns nat postrouting chain exists"
    else
        bad "warpns nat postrouting chain is missing"
    fi

    if ns_run nft list chain ip mangle forward >/dev/null 2>&1; then
        ok "warpns mangle forward chain exists"
    else
        bad "warpns mangle forward chain is missing"
    fi
fi

echo
echo "== forwarding sysctls =="
# ip_forward is the one that matters for forwarding traffic.
ipf="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '?')"
if [ "$ipf" = "1" ]; then
    ok "net.ipv4.ip_forward=1"
else
    bad "net.ipv4.ip_forward=${ipf} (expected 1)"
fi

dump_state

echo "----------------------------------------"
if [ "$fail" -eq 0 ]; then
    echo "smoke test OK"
    exit 0
fi
echo "smoke test FAILED (${fail} assertion(s))"
exit 1
