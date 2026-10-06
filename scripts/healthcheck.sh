#!/usr/bin/env bash
# Container healthcheck.
#
# Reports healthy only when the components that this MODE is responsible for are
# actually functional, so an exit node that lost its tunnel is restarted instead
# of silently black-holing client traffic.
set -uo pipefail

# Set before sourcing lib.sh: the log threshold is computed at source time.
LOG_LEVEL="${LOG_LEVEL:-warn}"

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib.sh
. "${SELF_DIR}/lib.sh"
# shellcheck source=netns.sh
. "${SELF_DIR}/netns.sh"
# shellcheck source=dns.sh
. "${SELF_DIR}/dns.sh"
# shellcheck source=warp.sh
. "${SELF_DIR}/warp.sh"
# shellcheck source=tailscale.sh
. "${SELF_DIR}/tailscale.sh"

MODE="${MODE:-all-in-one}"

fail() { printf 'unhealthy: %s\n' "$*" >&2; exit 1; }

case "$MODE" in
    all-in-one)
        # WARP side
        warp_cli status >/dev/null 2>&1 || fail "warp-svc is not responding"
        warp_connected || fail "WARP is not connected"

        if [ "${WARP_MODE:-warp}" = "proxy" ]; then
            printf 'healthy: WARP SOCKS proxy mode\n'
            exit 0
        fi

        tun="$(detect_warp_tun "${WARP_TUN_IFACE:-CloudflareWARP}")"
        ns_run ip link show "$tun" >/dev/null 2>&1 || fail "WARP tunnel ${tun} is missing"

        # Tailscale side
        ts_cli status --json >/dev/null 2>&1 || fail "tailscaled is not responding"
        ts_logged_in || fail "tailscaled is not logged in"

        # Steering
        if ! ip rule show | grep -qF "iif ${TS_TUN_IFACE:-tailscale0} lookup ${WARP_ROUTE_TABLE:-200}"; then
            fail "exit-node policy routing rule is missing"
        fi

        # DNS: the container's own resolver must survive WARP rewriting the
        # shared /etc/resolv.conf to its namespace-local 127.0.2.2. Without the
        # root-namespace stub, name resolution dies here while the tunnel still
        # looks healthy.
        verify_dns || fail "DNS is broken in one of the namespaces"
        printf 'healthy: WARP tunnel %s + tailscaled + steering + DNS\n' "$tun"
        ;;
    warp-only)
        warp_cli status >/dev/null 2>&1 || fail "warp-svc is not responding"
        warp_connected || fail "WARP is not connected"

        if [ "${WARP_MODE:-warp}" = "proxy" ]; then
            printf 'healthy: WARP SOCKS proxy mode\n'
            exit 0
        fi

        tun="$(detect_warp_tun "${WARP_TUN_IFACE:-CloudflareWARP}")"
        ns_run ip link show "$tun" >/dev/null 2>&1 || fail "WARP tunnel ${tun} is missing"
        printf 'healthy: WARP NAT gateway on %s\n' "$tun"
        ;;
    tailscale-only)
        ts_cli status --json >/dev/null 2>&1 || fail "tailscaled is not responding"
        ts_logged_in || fail "tailscaled is not logged in"
        printf 'healthy: tailscaled exit node\n'
        ;;
    *)
        fail "unknown MODE=${MODE}"
        ;;
esac

exit 0
