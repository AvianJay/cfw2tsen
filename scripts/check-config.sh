#!/usr/bin/env bash
# Generate a tailnet lock-safe, single-use Tailscale auth key is out of scope;
# this script validates the configuration the container was started with and
# prints exactly what is missing, before the image is deployed.
set -euo pipefail

LOG_LEVEL="${LOG_LEVEL:-info}"

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib.sh
. "${SELF_DIR}/lib.sh"

errors=0
warnings=0

ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; warnings=$(( warnings + 1 )); }
bad()  { printf '  \033[31mfail\033[0m  %s\n' "$*"; errors=$(( errors + 1 )); }

MODE="${MODE:-all-in-one}"

echo "cfw2tsen configuration check (MODE=${MODE})"
echo

echo "Mode"
case "$MODE" in
    all-in-one|warp-only|tailscale-only) ok "MODE=${MODE}" ;;
    *) bad "MODE=${MODE} is not one of all-in-one, warp-only, tailscale-only" ;;
esac

if [ "$MODE" != "warp-only" ]; then
    echo
    echo "Tailscale"
    if [ -n "${TS_AUTHKEY:-}" ]; then
        case "$TS_AUTHKEY" in
            tskey-auth-*)  ok "TS_AUTHKEY looks like a reusable auth key" ;;
            tskey-client-*) ok "TS_AUTHKEY looks like a client key" ;;
            file:*)        [ -r "${TS_AUTHKEY#file:}" ] && ok "TS_AUTHKEY points at a readable file" || bad "TS_AUTHKEY=file:... but the file is not readable" ;;
            *)             warn "TS_AUTHKEY does not start with tskey- ; double-check it" ;;
        esac
    elif [ -n "${TS_AUTHKEY_FILE:-}" ]; then
        [ -r "$TS_AUTHKEY_FILE" ] && ok "TS_AUTHKEY_FILE is readable" || bad "TS_AUTHKEY_FILE=${TS_AUTHKEY_FILE} is not readable"
    else
        warn "No TS_AUTHKEY/TS_AUTHKEY_FILE: the node will need interactive login and will not survive a restart"
    fi

    if [ "$(env_bool TS_AUTH_ONCE 1)" = "1" ]; then
        [ -n "${TS_STATE_DIR:-}" ] && ok "TS_STATE_DIR=${TS_STATE_DIR}" || warn "TS_STATE_DIR is unset; a fresh node is registered on every start"
    fi

    if [ "$(env_bool TS_USERSPACE 0)" = "1" ]; then
        warn "TS_USERSPACE=1: userspace exit nodes only carry TCP and UDP, and are slower"
    else
        ok "Kernel TUN mode (TS_USERSPACE=false)"
    fi

    if [ "$(env_bool TS_ADVERTISE_EXIT_NODE 1)" = "1" ]; then
        ok "Exit node will be advertised"
    else
        warn "TS_ADVERTISE_EXIT_NODE=0: this node will not act as an exit node"
    fi

    if [ -n "${TS_DEVICE_IP:-}" ]; then
        if [[ "$TS_DEVICE_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            ok "TS_DEVICE_IP=${TS_DEVICE_IP} is a valid IPv4 literal"
            if [ -z "${TS_API_KEY:-}" ] && { [ -z "${TS_OAUTH_CLIENT_ID:-}" ] || [ -z "${TS_OAUTH_CLIENT_SECRET:-}" ]; }; then
                bad "TS_DEVICE_IP is set but there is no TS_API_KEY or OAuth credential to apply it"
            else
                ok "API credential present for the address change"
            fi
        else
            bad "TS_DEVICE_IP=${TS_DEVICE_IP} is not a valid IPv4 address"
        fi
    fi

    [ "$(env_bool TS_ACCEPT_DNS 0)" = "1" ] && warn "TS_ACCEPT_DNS=1 can overwrite the container resolver"
fi

if [ "$MODE" != "tailscale-only" ]; then
    echo
    echo "WARP"
    if [ -n "${WARP_ORG:-}${WARP_AUTH_CLIENT_ID:-}${WARP_AUTH_CLIENT_SECRET:-}" ]; then
        if [ -n "${WARP_ORG:-}" ] && [ -n "${WARP_AUTH_CLIENT_ID:-}" ] && [ -n "${WARP_AUTH_CLIENT_SECRET:-}" ]; then
            ok "Zero Trust service-token enrollment is fully configured"
        else
            bad "Set all three of WARP_ORG, WARP_AUTH_CLIENT_ID and WARP_AUTH_CLIENT_SECRET, or none"
        fi
    elif [ -n "${WARP_TEAMS_TOKEN:-}" ]; then
        case "$WARP_TEAMS_TOKEN" in
            com.cloudflare.warp://*) ok "Zero Trust token enrollment URL looks well-formed" ;;
            *) warn "WARP_TEAMS_TOKEN does not start with com.cloudflare.warp:// ; check the format" ;;
        esac
    elif [ -n "${WARP_TEAM:-}" ]; then
        ok "Zero Trust team ${WARP_TEAM}"
    else
        ok "Free WARP account will be registered"
    fi

    case "${WARP_MODE:-warp}" in
        warp)  ok "WARP_MODE=warp (full tunnel)" ;;
        proxy)
            warn "WARP_MODE=proxy: no UDP, 10s request timeout, and it cannot be an exit node upstream"
            # The SOCKS listener binds 127.0.0.1 inside whichever namespace it
            # runs in, so isolating it would make the proxy unreachable.
            if [ -n "${WARP_NETNS:-}" ]; then
                bad "WARP_MODE=proxy with WARP_NETNS=${WARP_NETNS} makes the SOCKS proxy unreachable; set WARP_NETNS= for proxy mode"
            fi
            ;;
        *)     warn "WARP_MODE=${WARP_MODE} is unusual; expected warp or proxy" ;;
    esac

    if [ "$MODE" = "all-in-one" ] && [ "$(env_bool WARP_ENABLE 1)" = "1" ]; then
        if [ -n "${WARP_NETNS:-}" ]; then
            ok "WARP is isolated in netns '${WARP_NETNS}' (required when tailscaled shares the container)"
        else
            bad "MODE=all-in-one with WARP_NETNS empty: WARP's nftables policy drop will break inbound WireGuard. Set WARP_NETNS=warpns."
        fi
    fi

    if [ -n "${WARP_LICENSE_KEY:-}" ]; then
        case "$WARP_LICENSE_KEY" in
            ????????-????????-????????) ok "WARP_LICENSE_KEY has the expected shape" ;;
            *) warn "WARP_LICENSE_KEY does not look like the usual 8-8-8 format" ;;
        esac
    fi
fi

echo
echo "Result: ${errors} error(s), ${warnings} warning(s)"
[ "$errors" -eq 0 ] || exit 1
