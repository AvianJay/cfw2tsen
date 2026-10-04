#!/usr/bin/env bash
# warpctl — operator helper for the WARP side of the container.
#
#   docker exec <container> warpctl status
#   docker exec <container> warpctl trace
#   docker exec <container> warpctl reconnect
#   docker exec <container> warpctl routes
#   docker exec <container> warpctl shell
set -uo pipefail

LOG_LEVEL="${LOG_LEVEL:-info}"

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib.sh
. "${SELF_DIR}/lib.sh"
# shellcheck source=netns.sh
. "${SELF_DIR}/netns.sh"
# shellcheck source=warp.sh
. "${SELF_DIR}/warp.sh"



cmd_status() {
    echo "--- warp-cli status ---"
    warp_cli status 2>&1 || true
    echo
    echo "--- warp-cli settings ---"
    warp_cli settings 2>&1 || true
    echo
    echo "--- interfaces in ${WARP_NETNS:-root netns} ---"
    ns_run ip -brief addr show 2>&1 || true
    echo
    echo "--- routes in ${WARP_NETNS:-root netns} ---"
    ns_run ip route show 2>&1 || true
    echo
    echo "--- policy rules in ${WARP_NETNS:-root netns} ---"
    ns_run ip rule show 2>&1 || true
}

cmd_trace() {
    local tun; tun="$(detect_warp_tun "${WARP_TUN_IFACE:-CloudflareWARP}")"
    echo "--- WARP namespace egress ---"
    ns_run curl -fsS --max-time 20 https://www.cloudflare.com/cdn-cgi/trace 2>&1 || echo "(failed)"
    if [ -n "${WARP_NETNS:-}" ]; then
        echo
        echo "--- forwarded egress (source ${VETH_HOST_IP}) ---"
        curl -fsS --max-time 20 --interface "$VETH_HOST_IP" \
            https://www.cloudflare.com/cdn-cgi/trace 2>&1 || echo "(failed)"
        echo
        echo "--- steering ---"
        ip rule show | grep -F "lookup ${WARP_ROUTE_TABLE:-200}" || echo "(no steering rule)"
        ip route show table "${WARP_ROUTE_TABLE:-200}" 2>&1 || true
        echo "tunnel: ${tun}"
    fi
}

cmd_reconnect() {
    log_info "Reconnecting WARP"
    warp_cli disconnect >/dev/null 2>&1 || true
    sleep 2
    connect_warp || die "Reconnect failed"
    local tun; tun="$(detect_warp_tun "${WARP_TUN_IFACE:-CloudflareWARP}")"
    verify_warp_tunnel "$tun" || true
}

cmd_routes() {
    echo "--- excluded routes ---"
    warp_cli get-excluded-routes 2>&1 || warp_cli excluded-routes list 2>&1 || true
}

cmd_shell() {
    local pid
    if pid="$(_ns_pid)"; then
        exec nsenter --net="/proc/${pid}/ns/net" -- bash
    fi
    exec bash
}

cmd_nft() {
    echo "=== root netns ==="
    nft list ruleset 2>&1 || true
    if ns_exists; then
        echo
        echo "=== netns ${WARP_NETNS} (pid $(_ns_pid)) ==="
        ns_run nft list ruleset 2>&1 || true
    fi
}

usage() {
    cat <<'EOF'
warpctl — Cloudflare WARP control

Usage: warpctl <command>

Commands:
  status      warp-cli status/settings, interfaces, routes and policy rules
  trace       show the egress IP through WARP, including forwarded traffic
  reconnect   disconnect and reconnect the tunnel
  routes      list split-tunnel excluded routes
  nft         dump the nftables ruleset (root netns and WARP netns)
  shell       open a shell inside the WARP network namespace
EOF
}

case "${1:-status}" in
    status)    cmd_status ;;
    trace)     cmd_trace ;;
    reconnect) cmd_reconnect ;;
    routes)    cmd_routes ;;
    nft)       cmd_nft ;;
    shell)     cmd_shell ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
esac
