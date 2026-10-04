#!/usr/bin/env bash
# Cloudflare WARP lifecycle: dbus, warp-svc, headless registration, connect.
#
# warp-svc is started directly as a background process. The packaged systemd
# unit is unusable here because a container has no init, so the service is run
# the way the upstream warp-docker project does it.
# shellcheck shell=bash

set -euo pipefail

WARP_SVC_PID=""
WARP_STATE_DIR="${WARP_STATE_DIR:-/var/lib/cloudflare-warp}"
WARP_SLEEP="${WARP_SLEEP:-5}"

# ---------------------------------------------------------------------------
# dbus
# ---------------------------------------------------------------------------
start_dbus() {
    if [ -S /run/dbus/system_bus_socket ]; then
        log_debug "dbus already running"
        return 0
    fi
    mkdir -p /run/dbus
    log_info "Starting dbus-daemon"
    dbus-daemon --system --fork --nopidfile >/dev/null 2>&1 \
        || dbus-daemon --config-file=/usr/share/dbus-1/system.conf --fork >/dev/null 2>&1 \
        || die "Could not start dbus-daemon; warp-svc needs a system bus."
    wait_for 10 "dbus socket" test -S /run/dbus/system_bus_socket \
        || die "dbus system bus socket never appeared."
}

# ---------------------------------------------------------------------------
# TOS
# ---------------------------------------------------------------------------
seed_tos_acceptance() {
    local f="${HOME:-/root}/.local/share/warp/accepted-tos.txt"
    mkdir -p "$(dirname "$f")"
    # A pre-seeded file is the documented way to avoid the interactive prompt
    # in a headless container.
    [ -f "$f" ] || printf 'yes' > "$f"
}

# warp-cli wrapper. --accept-tos is a global flag and is required by some
# subcommands; passing it unconditionally is harmless on versions that ignore it.
warp_cli() {
    if [ "${WARP_ACCEPT_TOS:-1}" = "1" ]; then
        ns_run warp-cli --accept-tos "$@"
    else
        ns_run warp-cli "$@"
    fi
}

# ---------------------------------------------------------------------------
# warp-svc
# ---------------------------------------------------------------------------
start_warp_svc() {
    mkdir -p "$WARP_STATE_DIR" /var/log/cfw2tsen
    local log="/var/log/cfw2tsen/warp-svc.log"

    log_info "Starting warp-svc${WARP_NETNS:+ in netns ${WARP_NETNS}}"
    if [ "${WARP_ACCEPT_TOS:-1}" = "1" ]; then
        ns_run warp-svc --accept-tos >>"$log" 2>&1 &
    else
        ns_run warp-svc >>"$log" 2>&1 &
    fi
    WARP_SVC_PID=$!

    # warp-cli fails with "Unable to connect to CloudflareWARP daemon" until the
    # daemon is listening, so wait for the CLI itself rather than a fixed sleep.
    if ! wait_for 30 "warp-svc daemon" warp_cli status; then
        log_error "warp-svc did not become reachable. Last log lines:"
        tail -n 30 "$log" >&2 || true
        die "warp-svc failed to start."
    fi
    log_info "warp-svc is up"
}

stop_warp_svc() {
    if [ -n "$WARP_SVC_PID" ] && kill -0 "$WARP_SVC_PID" 2>/dev/null; then
        log_info "Stopping warp-svc"
        kill "$WARP_SVC_PID" 2>/dev/null || true
        wait "$WARP_SVC_PID" 2>/dev/null || true
    fi
    WARP_SVC_PID=""
}

# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

warp_registered() {
    [ -f "${WARP_STATE_DIR}/reg.json" ]
}

# Escape a value for use inside an XML text node. Service-token secrets are
# base64-ish but may contain '+', '/' and '='; organization names and ids can
# contain '&'. An unescaped '&' or '<' produces malformed XML, which warp-svc
# silently rejects, leaving the device unenrolled.
xml_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    printf '%s' "$s"
}

# Zero Trust service-token enrolment via the MDM file. This is the only fully
# headless Zero Trust path; it must be in place before warp-svc starts.
write_mdm_config() {
    local org="$1" client_id="$2" client_secret="$3"
    local mode="${WARP_SERVICE_MODE:-warp}"
    local mdm="${WARP_STATE_DIR}/mdm.xml"

    log_info "Writing Zero Trust MDM configuration for organization ${org}"
    mkdir -p "$WARP_STATE_DIR"
    # umask so the file is never briefly world-readable while it holds a secret.
    (
        umask 077
        cat > "$mdm" <<EOF
<dict>
    <key>auth_client_id</key>
    <string>$(xml_escape "$client_id")</string>
    <key>auth_client_secret</key>
    <string>$(xml_escape "$client_secret")</string>
    <key>organization</key>
    <string>$(xml_escape "$org")</string>
    <key>auto_connect</key>
    <integer>1</integer>
    <key>onboarding</key>
    <false/>
    <key>service_mode</key>
    <string>$(xml_escape "$mode")</string>
</dict>
EOF
    )
    chmod 0600 "$mdm"

    # Reject a configuration the daemon would silently ignore.
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import sys,xml.etree.ElementTree as E; E.parse(sys.argv[1])' "$mdm" 2>/dev/null \
            || die "Generated MDM configuration is not valid XML; check WARP_ORG/WARP_AUTH_CLIENT_ID for stray characters."
    fi
}

register_warp() {
    if warp_registered; then
        log_info "WARP already registered (${WARP_STATE_DIR}/reg.json present)"
        return 0
    fi

    # --- Zero Trust -------------------------------------------------------
    if [ -n "${WARP_ORG:-}" ] && [ -n "${WARP_AUTH_CLIENT_ID:-}" ] && [ -n "${WARP_AUTH_CLIENT_SECRET:-}" ]; then
        write_mdm_config "$WARP_ORG" "$WARP_AUTH_CLIENT_ID" "$WARP_AUTH_CLIENT_SECRET"
        stop_warp_svc
        start_warp_svc
    elif [ -n "${WARP_TEAMS_TOKEN:-}" ]; then
        # Service token enrollment URL, e.g.
        # com.cloudflare.warp://<team>.cloudflareaccess.com/auth?token=<token>
        log_info "Enrolling with a Zero Trust service token"
        warp_cli registration token "$WARP_TEAMS_TOKEN" \
            || die "Service-token enrollment failed. Verify the token and that the Access policy action is 'Service Auth'."
    elif [ -n "${WARP_TEAM:-}" ]; then
        log_info "Registering with Zero Trust team ${WARP_TEAM}"
        warp_cli registration new "$WARP_TEAM" || true
    else
        log_info "Registering a free (consumer) WARP account"
        warp_cli registration new || true
    fi

    # --- WARP+ license ----------------------------------------------------
    if [ -n "${WARP_LICENSE_KEY:-}" ]; then
        log_info "Applying WARP+ license key"
        warp_cli registration license "$WARP_LICENSE_KEY" || log_warn "License key was rejected"
    fi

    if ! warp_registered; then
        # Some versions report registration but do not create reg.json until the
        # daemon flushes state.
        sleep 2
    fi
    if ! warp_registered; then
        log_warn "No ${WARP_STATE_DIR}/reg.json after registration; continuing and relying on daemon state."
    fi
    log_info "Registration step complete"
}

# ---------------------------------------------------------------------------
# Mode, split tunnel, connect
# ---------------------------------------------------------------------------

set_warp_mode() {
    local mode="${WARP_MODE:-warp}"
    if [ "$mode" = "proxy" ]; then
        log_info "Setting WARP mode: proxy (port ${WARP_PROXY_PORT:-40000})"
        warp_cli mode proxy || die "Could not set proxy mode"
        warp_cli proxy port "${WARP_PROXY_PORT:-40000}" || log_warn "Could not set proxy port"
        return 0
    fi
    log_info "Setting WARP mode: ${mode}"
    warp_cli mode "$mode" || log_warn "Could not set mode ${mode}; leaving the daemon default."
}

# Keep tailnet traffic out of the WARP tunnel. Without this WARP captures the
# Tailscale control plane, DERP relays and CGNAT tailnet addresses, which is the
# documented cause of exit nodes losing connectivity.
exclude_tailscale_from_warp() {
    [ "$(env_bool WARP_EXCLUDE_TAILSCALE 1)" = "1" ] || { log_debug "Split tunnel exclusions disabled"; return 0; }

    local routes=(
        100.64.0.0/10
        fd7a:115c:a1e0::/48
    )
    local r
    for r in "${routes[@]}"; do
        if warp_cli add-excluded-route "$r" >/dev/null 2>&1; then
            log_debug "Excluded ${r} from the WARP tunnel"
        else
            log_debug "Could not exclude ${r} (unsupported by this warp-cli version)"
        fi
    done

    if [ -n "${WARP_EXCLUDE_EXTRA:-}" ]; then
        local IFS=','
        for r in $WARP_EXCLUDE_EXTRA; do
            r="${r// /}"
            [ -z "$r" ] && continue
            warp_cli add-excluded-route "$r" >/dev/null 2>&1 \
                && log_debug "Excluded ${r} from the WARP tunnel" \
                || log_debug "Could not exclude ${r}"
        done
    fi
}

warp_connected() {
    local status
    status="$(warp_cli status 2>/dev/null || true)"
    grep -qiE 'Status update: *Connected|^Connected' <<<"$status"
}

connect_warp() {
    local attempts="${WARP_CONNECT_RETRIES:-10}"
    local delay="${WARP_CONNECT_RETRY_SLEEP:-5}"
    local i

    for (( i = 1; i <= attempts; i++ )); do
        log_info "Connecting WARP (attempt ${i}/${attempts})"
        warp_cli connect >/dev/null 2>&1 || true
        sleep "$WARP_SLEEP"
        if warp_connected; then
            log_info "WARP connected"
            return 0
        fi
        # Retrying registration clears most transient handshake failures.
        if (( i == 3 )); then
            log_warn "Still not connected; re-running registration"
            warp_cli registration new >/dev/null 2>&1 || true
        fi
        (( i < attempts )) && sleep "$delay"
    done

    log_error "WARP did not connect. Diagnostics:"
    warp_cli status >&2 2>&1 || true
    warp_cli settings >&2 2>&1 || true
    tail -n 40 /var/log/cfw2tsen/warp-svc.log >&2 2>/dev/null || true
    return 1
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

# Assert the tunnel interface exists and carries a real address.
verify_warp_tunnel() {
    local tun="$1" addr
    if ! ns_run ip link show "$tun" >/dev/null 2>&1; then
        log_error "Tunnel interface ${tun} is missing inside ${WARP_NETNS:-the container netns}"
        ns_run ip -o link show >&2 2>&1 || true
        return 1
    fi
    addr="$(ns_run ip -4 -o addr show "$tun" 2>/dev/null | awk '{print $4}')"
    log_info "WARP tunnel ${tun} up${addr:+ with ${addr}}"

    if [ "$(env_bool WARP_VERIFY_EGRESS 1)" = "1" ]; then
        # Prove the tunnel actually carries traffic out of the namespace.
        local trace
        trace="$(ns_run curl -fsS --max-time 20 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
        if [ -z "$trace" ]; then
            log_warn "Could not fetch the Cloudflare trace endpoint through WARP"
            return 1
        fi
        local warp ip loc
        warp="$(grep -E '^warp=' <<<"$trace" | cut -d= -f2- || true)"
        ip="$(grep -E '^ip=' <<<"$trace" | cut -d= -f2- || true)"
        loc="$(grep -E '^loc=' <<<"$trace" | cut -d= -f2- || true)"
        if [ "${warp:-}" = "on" ]; then
            log_info "WARP egress verified: warp=on ip=${ip:-?} loc=${loc:-?}"
        else
            log_warn "Egress is not going through WARP (warp=${warp:-unknown}, ip=${ip:-?})"
            return 1
        fi
    fi
    return 0
}

# Wait until the tunnel is actually usable before starting Tailscale, otherwise
# tailscaled can come up with a broken path to the control plane.
await_warp_ready() {
    local tun="$1" timeout="${WARP_READY_TIMEOUT:-60}" waited=0
    while (( waited < timeout )); do
        if ns_run ip link show "$tun" >/dev/null 2>&1 && warp_connected; then
            return 0
        fi
        sleep 2
        waited=$(( waited + 2 ))
    done
    log_warn "WARP not fully ready after ${timeout}s"
    return 1
}
