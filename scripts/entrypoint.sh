#!/usr/bin/env bash
# cfw2tsen entrypoint.
#
# MODE selects the role:
#   all-in-one      WARP inside its own netns + tailscaled exit node (default)
#   warp-only       WARP NAT gateway for the split compose deployment
#   tailscale-only  tailscaled exit node behind an external WARP gateway
#
# Environment is documented in README.md.
set -euo pipefail

# Set before sourcing lib.sh: the log threshold is computed at source time.
LOG_LEVEL="${LOG_LEVEL:-info}"

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib.sh
. "${SELF_DIR}/lib.sh"
# shellcheck source=netns.sh
. "${SELF_DIR}/netns.sh"
# shellcheck source=warp.sh
. "${SELF_DIR}/warp.sh"
# shellcheck source=tailscale.sh
. "${SELF_DIR}/tailscale.sh"

MODE="${MODE:-all-in-one}"
WARP_ENABLED=0
TS_ENABLED=0
SHUTTING_DOWN=0

case "$MODE" in
    all-in-one)     WARP_ENABLED="$(env_bool WARP_ENABLE 1)"; TS_ENABLED=1 ;;
    warp-only)      WARP_ENABLED=1; TS_ENABLED=0 ;;
    tailscale-only) WARP_ENABLED=0; TS_ENABLED=1 ;;
    *) die "Unknown MODE='${MODE}'. Expected all-in-one, warp-only or tailscale-only." ;;
esac

# ---------------------------------------------------------------------------
# Shutdown
# ---------------------------------------------------------------------------
shutdown() {
    [ "$SHUTTING_DOWN" = "1" ] && return 0
    SHUTTING_DOWN=1
    log_info "Shutting down"
    set +e
    if [ "$TS_ENABLED" = "1" ]; then
        teardown_exit_steering 2>/dev/null
        stop_tailscaled 2>/dev/null
    fi
    if [ "$WARP_ENABLED" = "1" ]; then
        stop_warp_svc 2>/dev/null
    fi
    if [ -n "${WARP_NETNS:-}" ] && ns_exists; then
        ns_delete "$WARP_NETNS" 2>/dev/null
    fi
    log_info "Shutdown complete"
    exit 0
}

trap shutdown SIGTERM SIGINT SIGQUIT

# ---------------------------------------------------------------------------
# WARP bring-up
# ---------------------------------------------------------------------------
bring_up_warp() {
    log_info "=== Cloudflare WARP bring-up (mode=${MODE}) ==="

    ensure_tun_device
    ensure_nft_support
    ensure_warp_sysctls
    start_dbus

    local egress_if; egress_if="$(detect_egress_iface)"
    log_info "Detected egress interface: ${egress_if}"

    if [ -n "${WARP_NETNS:-}" ]; then
        # --- isolated namespace ------------------------------------------
        ns_create "$WARP_NETNS"
        setup_veth_pair "$WARP_NETNS"
        setup_warpns_underlay "$WARP_NETNS"
        setup_root_underlay_nat "$egress_if"
        # Let the namespace resolve and reach the edge before warp-svc starts.
        if ! ns_run ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then
            log_warn "warpns cannot reach 1.1.1.1 yet; continuing, warp-svc will retry"
        fi
    else
        log_warn "WARP_NETNS is empty: WARP runs in the container namespace. Tailscale must not run here, or inbound WireGuard will be dropped."
    fi

    start_warp_svc
    register_warp
    set_warp_mode

    if [ "${WARP_MODE:-warp}" = "proxy" ]; then
        log_info "Proxy mode selected; skipping tunnel and NAT configuration"
        warp_cli connect >/dev/null 2>&1 || true
        log_info "WARP SOCKS5 proxy on 127.0.0.1:${WARP_PROXY_PORT:-40000}"
        return 0
    fi

    exclude_tailscale_from_warp
    connect_warp || die "Could not bring the WARP tunnel up."

    local tun; tun="$(detect_warp_tun "$WARP_TUN_IFACE")"
    await_warp_ready "$tun" || true
    verify_warp_tunnel "$tun" || log_warn "WARP tunnel verification reported problems; continuing."

    if [ "$(env_bool WARP_ENABLE_NAT 1)" = "1" ]; then
        local table; table="$(detect_warp_table "$tun")"
        # Accept forwarded traffic before steering it. This matters in warp-only
        # mode, where clients reach this container over the Docker bridge.
        setup_forward_accept
        setup_warpns_forwarding "$tun" "$table"
        setup_warpns_nat "$tun"

        # End-to-end proof that forwarded traffic reaches WARP, not just that
        # the tunnel itself works.
        verify_forwarded_egress || log_warn "Forwarded-egress verification failed; exit-node clients may not reach the internet."
    fi
    log_info "=== WARP is up (tunnel=${tun}) ==="
}

# ---------------------------------------------------------------------------
# Tailscale bring-up
# ---------------------------------------------------------------------------
bring_up_tailscale() {
    log_info "=== Tailscale exit node bring-up ==="

    ensure_tun_device

    if [ -n "${WARP_GATEWAY:-}" ]; then
        # tailscale-only mode: an external WARP container is the upstream.
        setup_external_gateway "$WARP_GATEWAY"
    fi

    start_tailscaled
    tailscale_up

    # Steer exit-node traffic after tailscaled has created its interface,
    # because tailscaled rewrites the routing table as it comes up.
    if [ "$WARP_ENABLED" = "1" ] && [ -n "${WARP_NETNS:-}" ] && [ "${WARP_MODE:-warp}" != "proxy" ]; then
        wait_for 20 "tailscale interface ${TS_TUN_IFACE}" \
            ip link show "$TS_TUN_IFACE" || log_warn "Interface ${TS_TUN_IFACE} not found"
        setup_forward_accept
        setup_exit_steering
    fi

    # tailscaled rewrites the routing table as it starts, which can undo the
    # gateway default route installed before it came up. Re-apply it.
    if [ -n "${WARP_GATEWAY:-}" ]; then
        reapply_external_gateway "$WARP_GATEWAY"
    fi

    apply_device_ip || true
    verify_exit_node || true
    log_info "=== Tailscale is up ==="
}

# Point this container's default route at an external WARP gateway container.
setup_external_gateway() {
    local gw="$1"
    local egress_if; egress_if="$(detect_egress_iface)"
    log_info "Routing default via external WARP gateway ${gw} (dev ${egress_if})"

    ip route replace default via "$gw" dev "$egress_if"
    setup_root_underlay_nat "$egress_if"

    # Reach the gateway itself over the directly attached subnet.
    local net
    net="$(ip -o -4 addr show "$egress_if" 2>/dev/null | awk '{print $4}' | head -n1)"
    if [ -n "$net" ]; then
        ip route replace "$net" dev "$egress_if" scope link 2>/dev/null || true
    fi
}

# Idempotent re-application, used after tailscaled has touched the routing table.
reapply_external_gateway() {
    local gw="$1"
    local egress_if; egress_if="$(detect_egress_iface)"
    local current
    current="$(ip route show default 2>/dev/null | awk '/^default/ {print $3; exit}')"
    if [ "$current" = "$gw" ]; then
        log_debug "Default route still points at ${gw}"
        return 0
    fi
    log_info "Default route changed to '${current:-none}'; restoring ${gw}"
    setup_external_gateway "$gw"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
    log_info "---------------- configuration ----------------"
    log_info "MODE                : ${MODE}"
    log_info "WARP enabled        : ${WARP_ENABLED} (mode=${WARP_MODE:-warp}${WARP_NETNS:+, netns=${WARP_NETNS}})"
    log_info "Tailscale enabled   : ${TS_ENABLED}"
    if [ "$TS_ENABLED" = "1" ]; then
        log_info "Tailscale hostname  : ${TS_HOSTNAME:-cfw2tsen-exit-node}"
        log_info "Advertise exit node : $(env_bool TS_ADVERTISE_EXIT_NODE 1)"
        [ -n "${TS_DEVICE_IP:-}" ] && log_info "Requested device IP : ${TS_DEVICE_IP}"
    fi
    log_info "-----------------------------------------------"
    if [ "$TS_ENABLED" = "1" ] && [ "$(env_bool TS_ADVERTISE_EXIT_NODE 1)" = "1" ]; then
        log_info "ACTION REQUIRED: approve this device as an exit node in the Tailscale admin console"
        log_info "  https://login.tailscale.com/admin/machines  ->  Edit route settings  ->  Use as exit node"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    # CI / diagnostic entry points that do not contact any network.
    case "${1:-}" in
        selftest)  exec bash "${SELF_DIR}/selftest.sh" ;;
        smoke)     exec bash "${SELF_DIR}/smoke.sh" ;;
        check)     exec bash "${SELF_DIR}/check-config.sh" ;;
        shell)     exec bash ;;
        -h|--help)
            cat <<'EOF'
cfw2tsen — Cloudflare WARP egress for a Tailscale exit node

Usage: <container> [command]

Commands (default: run the configured MODE):
  (none)     start the service described by MODE
  selftest   validate the image contents; with NET_ADMIN also start warp-svc
  smoke      bring up netns/veth/policy routing and assert the topology
  check      validate the environment configuration and print what is missing
  shell      open an interactive shell
EOF
            exit 0
            ;;
    esac

    require_cmd ip nft curl jq

    if [ "$(env_bool SMOKE_TEST 0)" = "1" ]; then
        # Bring up the plumbing, verify it, then exit without connecting.
        [ -n "${WARP_NETNS:-}" ] && { ns_create "$WARP_NETNS"; setup_veth_pair "$WARP_NETNS"; setup_warpns_underlay "$WARP_NETNS"; }
        exec bash "${SELF_DIR}/smoke.sh"
    fi

    [ "$WARP_ENABLED" = "1" ] && bring_up_warp
    [ "$TS_ENABLED" = "1" ] && bring_up_tailscale

    print_summary
    log_info "Supervision started; waiting for signals"

    # Supervise: if a child dies, take the container down so the restart policy
    # can recover it rather than leaving a half-broken exit node running.
    while [ "$SHUTTING_DOWN" = "0" ]; do
        if [ "$WARP_ENABLED" = "1" ] && [ -n "$WARP_SVC_PID" ] && ! kill -0 "$WARP_SVC_PID" 2>/dev/null; then
            log_error "warp-svc exited unexpectedly"
            exit 1
        fi
        if [ "$TS_ENABLED" = "1" ] && [ -n "$TAILSCALED_PID" ] && ! kill -0 "$TAILSCALED_PID" 2>/dev/null; then
            log_error "tailscaled exited unexpectedly"
            exit 1
        fi
        sleep 5 &
        wait $! || true
    done
}

main "$@"
