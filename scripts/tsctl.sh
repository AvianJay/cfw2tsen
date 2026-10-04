#!/usr/bin/env bash
# tsctl — operator helper for the Tailscale side of the container.
#
#   docker exec <container> tsctl status
#   docker exec <container> tsctl ip
#   docker exec <container> tsctl set-ip 100.64.0.10
#   docker exec <container> tsctl approve-hint
set -uo pipefail

LOG_LEVEL="${LOG_LEVEL:-info}"

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib.sh
. "${SELF_DIR}/lib.sh"
# shellcheck source=netns.sh
. "${SELF_DIR}/netns.sh"
# shellcheck source=tailscale.sh
. "${SELF_DIR}/tailscale.sh"



cmd_status() {
    echo "--- tailscale status ---"
    ts_cli status 2>&1 || true
    echo
    echo "--- tailscale netcheck (summary) ---"
    ts_cli netcheck 2>&1 | head -n 25 || true
    echo
    echo "--- interfaces ---"
    ip -brief addr show 2>&1 || true
    echo
    echo "--- policy rules ---"
    ip rule show 2>&1 || true
}

cmd_ip() {
    echo "IPv4: $(ts_cli ip -4 2>/dev/null || echo unknown)"
    echo "IPv6: $(ts_cli ip -6 2>/dev/null || echo unknown)"
    ts_cli status --json 2>/dev/null | jq -r '.Self | "hostname: \(.HostName)\nexit-node advertised: \(.ExitNodeOption)"' 2>/dev/null || true
}

# set-ip <address> — pin this device's IPv4 through the Tailscale API.
cmd_set_ip() {
    local addr="${1:-}"
    [ -n "$addr" ] || die "Usage: tsctl set-ip <ipv4-address>"
    TS_DEVICE_IP="$addr" apply_device_ip
}

cmd_approve_hint() {
    cat <<'EOF'
The exit node must be approved before clients can use it:

  1. Open https://login.tailscale.com/admin/machines
  2. Find the device (it has an "Exit Node" badge once it advertises itself)
  3. Open its menu -> "Edit route settings..."
  4. Tick "Use as exit node" and save

If you use a custom policy file, make sure a grant allows the traffic:

  {
    "grants": [
      { "src": ["autogroup:member"], "dst": ["autogroup:internet"], "ip": ["*"] }
    ]
  }

To let clients pick this node, on the client run:

  tailscale set --exit-node=<this-node-ip-or-name>

Verify from the client with:  tailscale status   and   curl https://www.cloudflare.com/cdn-cgi/trace
The trace output should show warp=on and a Cloudflare egress address.
EOF
}

usage() {
    cat <<'EOF'
tsctl — Tailscale exit node control

Usage: tsctl <command>

Commands:
  status              tailscale status, netcheck and routing state
  ip                  show this node's Tailscale addresses
  set-ip <address>    request a specific IPv4 for this device via the API
  approve-hint        how to approve the exit node in the admin console
EOF
}

case "${1:-status}" in
    status)       cmd_status ;;
    ip)           cmd_ip ;;
    set-ip)       shift; cmd_set_ip "$@" ;;
    approve-hint) cmd_approve_hint ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
esac
