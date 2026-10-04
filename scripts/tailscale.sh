#!/usr/bin/env bash
# tailscaled lifecycle: start the daemon, join the tailnet, advertise the exit
# node, and optionally pin the device's IPv4 address through the Tailscale API.
# shellcheck shell=bash

set -euo pipefail

TAILSCALED_PID=""
TS_SOCKET="${TS_SOCKET:-/var/run/tailscale/tailscaled.sock}"
TS_STATE_DIR="${TS_STATE_DIR:-/var/lib/tailscale}"
TS_TUN_IFACE="${TS_TUN_IFACE:-tailscale0}"

ts_cli() { tailscale --socket="$TS_SOCKET" "$@"; }

# ---------------------------------------------------------------------------
# Daemon
# ---------------------------------------------------------------------------
start_tailscaled() {
    mkdir -p "$TS_STATE_DIR" /var/run/tailscale /var/log/cfw2tsen
    local log="/var/log/cfw2tsen/tailscaled.log"
    local args=(--socket="$TS_SOCKET" --statedir="$TS_STATE_DIR")

    # TS_STATE_DIR must persist across restarts. When it is unset the official
    # container uses --state=mem:, which registers a brand new node every boot.
    if [ "$(env_bool TS_USERSPACE 0)" = "1" ]; then
        log_warn "TS_USERSPACE=1: userspace mode is TCP/UDP-only and much slower. Kernel mode is strongly recommended for an exit node."
        args+=(--tun=userspace-networking)
    else
        ensure_tun_device
        # containerboot does not enable forwarding for --advertise-exit-node,
        # only for TS_ROUTES, so set it explicitly.
        sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || log_warn "Could not set net.ipv4.ip_forward=1"
        sysctl -qw net.ipv6.conf.all.forwarding=1 2>/dev/null || true
    fi

    if [ -n "${TS_TAILSCALED_EXTRA_ARGS:-}" ]; then
        # shellcheck disable=SC2206
        args+=(${TS_TAILSCALED_EXTRA_ARGS})
    fi

    log_info "Starting tailscaled (userspace=$(env_bool TS_USERSPACE 0))"
    tailscaled "${args[@]}" >>"$log" 2>&1 &
    TAILSCALED_PID=$!

    if ! wait_for 30 "tailscaled socket" test -S "$TS_SOCKET"; then
        tail -n 30 "$log" >&2 || true
        die "tailscaled did not create its socket."
    fi
    log_info "tailscaled is up"
}

stop_tailscaled() {
    if [ -n "$TAILSCALED_PID" ] && kill -0 "$TAILSCALED_PID" 2>/dev/null; then
        log_info "Stopping tailscaled"
        kill "$TAILSCALED_PID" 2>/dev/null || true
        wait "$TAILSCALED_PID" 2>/dev/null || true
    fi
    TAILSCALED_PID=""
}

ts_logged_in() {
    ts_cli status --json 2>/dev/null | jq -e '.BackendState == "Running"' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Join the tailnet
# ---------------------------------------------------------------------------
tailscale_up() {
    local args=(--hostname="${TS_HOSTNAME:-cfw2tsen-exit-node}" --timeout=60s)

    # Prefer the env var, but accept a file so the key can come from a secret
    # mount instead of the process environment.
    local authkey="${TS_AUTHKEY:-}"
    if [ -z "$authkey" ] && [ -n "${TS_AUTHKEY_FILE:-}" ] && [ -r "${TS_AUTHKEY_FILE}" ]; then
        authkey="$(tr -d '\r\n' < "${TS_AUTHKEY_FILE}")"
    fi
    if [ -z "$authkey" ] && [ -n "${TS_AUTHKEY:-}" ] && [[ "${TS_AUTHKEY}" == file:* ]]; then
        authkey="$(tr -d '\r\n' < "${TS_AUTHKEY#file:}")"
    fi
    [ -n "$authkey" ] && args+=(--auth-key="$authkey")

    if [ "$(env_bool TS_ADVERTISE_EXIT_NODE 1)" = "1" ]; then
        args+=(--advertise-exit-node)
    fi
    if [ -n "${TS_ADVERTISE_ROUTES:-}" ]; then
        args+=(--advertise-routes="$TS_ADVERTISE_ROUTES")
    fi
    if [ -n "${TS_ADVERTISE_TAGS:-}" ]; then
        args+=(--advertise-tags="$TS_ADVERTISE_TAGS")
    fi
    [ "$(env_bool TS_ACCEPT_DNS 0)" = "1" ] && args+=(--accept-dns) || args+=(--accept-dns=false)
    [ "$(env_bool TS_ACCEPT_ROUTES 0)" = "1" ] && args+=(--accept-routes)
    [ "$(env_bool TS_SSH 0)" = "1" ] && args+=(--ssh)
    [ "$(env_bool TS_SHIELDS_UP 0)" = "1" ] && args+=(--shields-up)

    # Tailscale's own nftables chains can conflict with WARP's and with the
    # policy routing that steers exit traffic. 'nodivert' keeps Tailscale's
    # rules installed but stops it from diverting packets into them.
    if [ -n "${TS_NETFILTER_MODE:-}" ]; then
        args+=(--netfilter-mode="$TS_NETFILTER_MODE")
    fi

    if [ -n "${TS_EXTRA_ARGS:-}" ]; then
        # shellcheck disable=SC2206
        args+=(${TS_EXTRA_ARGS})
    fi

    if [ "$(env_bool TS_AUTH_ONCE 1)" = "1" ] && ts_logged_in; then
        log_info "Already authenticated; applying settings only"
        ts_cli set --hostname="${TS_HOSTNAME:-cfw2tsen-exit-node}" \
                   --advertise-exit-node="$(env_bool TS_ADVERTISE_EXIT_NODE 1)" \
            || log_warn "Could not update node settings"
        return 0
    fi

    log_info "Joining the tailnet as ${TS_HOSTNAME:-cfw2tsen-exit-node}"
    # --reset makes the declared flags authoritative, so a restarted container
    # with changed settings converges instead of keeping stale ones.
    retry 3 5 "tailscale up" ts_cli up --reset "${args[@]}" \
        || die "tailscale up failed. Check TS_AUTHKEY validity and that the key is not expired."
    log_info "Joined the tailnet"
}

# ---------------------------------------------------------------------------
# Device IPv4 address
#
# tailscale up/set have no flag for requesting a specific address, and there is
# no TS_IP variable: the control plane assigns addresses. The supported way to
# pin one is the API, so do that after the node has registered.
# ---------------------------------------------------------------------------
TS_API_BASE="${TS_API_BASE:-https://api.tailscale.com/api/v2}"

api_request() {
    local method="$1" path="$2" body="${3:-}"
    local auth=()
    if [ -n "${TS_API_KEY:-}" ]; then
        auth=(-u "${TS_API_KEY}:")
    elif [ -n "${TS_OAUTH_CLIENT_ID:-}" ] && [ -n "${TS_OAUTH_CLIENT_SECRET:-}" ]; then
        # OAuth tokens are short-lived; exchange them for a bearer token.
        local tok
        tok="$(curl -fsS --max-time 20 https://api.tailscale.com/api/v2/oauth/token \
                -d "client_id=${TS_OAUTH_CLIENT_ID}" \
                -d "client_secret=${TS_OAUTH_CLIENT_SECRET}" 2>/dev/null \
              | jq -r '.access_token // empty' || true)"
        [ -n "$tok" ] || { log_warn "OAuth token exchange failed"; return 1; }
        auth=(-H "Authorization: Bearer ${tok}")
    else
        log_warn "No TS_API_KEY or OAuth credentials; skipping API call"
        return 1
    fi

    if [ -n "$body" ]; then
        curl -fsS --max-time 20 -X "$method" "${auth[@]}" \
            -H 'Content-Type: application/json' -d "$body" "${TS_API_BASE}${path}"
    else
        curl -fsS --max-time 20 -X "$method" "${auth[@]}" "${TS_API_BASE}${path}"
    fi
}

# Resolve this node's device id from its own status output.
resolve_device_id() {
    local self id
    self="$(ts_cli status --json 2>/dev/null | jq -r '.Self.PublicKey // empty' || true)"
    [ -z "$self" ] && { log_warn "Cannot read the node public key from tailscale status"; return 1; }

    if [ -n "${TS_DEVICE_ID:-}" ]; then
        printf '%s' "$TS_DEVICE_ID"
        return 0
    fi

    id="$(api_request GET "/tailnet/${TS_TAILNET:-%2D}/devices" 2>/dev/null \
          | jq -r --arg k "$self" '.devices[] | select(.publicKey == $k) | .id' 2>/dev/null | head -n1 || true)"
    if [ -z "$id" ]; then
        log_warn "Could not find this device via the API; set TS_DEVICE_ID to skip the lookup."
        return 1
    fi
    printf '%s' "$id"
}

apply_device_ip() {
    [ -n "${TS_DEVICE_IP:-}" ] || { log_debug "TS_DEVICE_IP not set; leaving the assigned address"; return 0; }

    local want="$TS_DEVICE_IP"
    if [[ ! "$want" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        log_error "TS_DEVICE_IP='${want}' is not a valid IPv4 address"
        return 1
    fi

    local current
    current="$(ts_cli ip -4 2>/dev/null | head -n1 || true)"
    if [ "$current" = "$want" ]; then
        log_info "Device IPv4 already ${want}"
        return 0
    fi

    log_info "Requesting device IPv4 ${want} (currently ${current:-unknown})"
    local id
    id="$(resolve_device_id)" || { log_warn "Skipping TS_DEVICE_IP: device id unavailable"; return 1; }

    if api_request POST "/device/${id}/ip" "{\"ipv4\":\"${want}\"}" >/dev/null; then
        log_info "Device IPv4 set to ${want}"
        # The client picks the new address up from the control plane.
        retry 6 5 "address refresh" bash -c \
            "[ \"\$(tailscale --socket='${TS_SOCKET}' ip -4 2>/dev/null | head -n1)\" = '${want}' ]" \
            || log_warn "Address change requested but the node still reports ${current:-unknown}; it may apply on the next reconnect."
    else
        log_warn "API rejected the address change. It must be a free address inside your tailnet's IPv4 range."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
verify_exit_node() {
    local json
    json="$(ts_cli status --json 2>/dev/null || true)"
    [ -z "$json" ] && { log_error "tailscale status returned nothing"; return 1; }

    local state ip
    state="$(jq -r '.BackendState // "unknown"' <<<"$json")"
    ip="$(jq -r '.Self.TailscaleIPs[0] // "unknown"' <<<"$json")"
    log_info "Tailscale state=${state} ip=${ip}"

    if [ "$(env_bool TS_ADVERTISE_EXIT_NODE 1)" = "1" ]; then
        if jq -e '.Self.ExitNodeOption == true' <<<"$json" >/dev/null 2>&1; then
            log_info "Exit node is advertised"
        else
            log_warn "Exit node is NOT advertised yet. Approve it in the admin console:"
            log_warn "  Machines -> this device -> Edit route settings -> Use as exit node"
        fi
    fi
    return 0
}
