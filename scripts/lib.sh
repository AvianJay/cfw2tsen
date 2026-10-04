#!/usr/bin/env bash
# Shared helpers for cfw2tsen.
# Sourced by the other scripts; never executed directly.
# shellcheck shell=bash

set -euo pipefail

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
: "${LOG_LEVEL:=info}"

_log_level_num() {
    case "${1,,}" in
        debug) echo 10 ;;
        info)  echo 20 ;;
        warn)  echo 30 ;;
        error) echo 40 ;;
        *)     echo 20 ;;
    esac
}

_LOG_THRESHOLD="$(_log_level_num "$LOG_LEVEL")"

# _log <level> <message...>
_log() {
    local level="$1"; shift
    local num; num="$(_log_level_num "$level")"
    (( num < _LOG_THRESHOLD )) && return 0
    local ts; ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s [%-5s] %s\n' "$ts" "${level^^}" "$*" >&2
}

log_debug() { _log debug "$@"; }
log_info()  { _log info  "$@"; }
log_warn()  { _log warn  "$@"; }
log_error() { _log error "$@"; }

die() { log_error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------

# env_bool <name> <default:0|1> -> 0/1
env_bool() {
    local name="$1" default="${2:-0}"
    local raw="${!name-}"
    [ -z "$raw" ] && { echo "$default"; return 0; }
    case "${raw,,}" in
        1|true|yes|y|on)  echo 1 ;;
        0|false|no|n|off) echo 0 ;;
        *) log_warn "Ignoring invalid boolean ${name}=${raw}; using ${default}"; echo "$default" ;;
    esac
}

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "Required command not found: $c"
    done
}

# retry <attempts> <delay_seconds> <description> <command...>
retry() {
    local attempts="$1" delay="$2" desc="$3"; shift 3
    local i
    for (( i = 1; i <= attempts; i++ )); do
        if "$@"; then
            log_debug "${desc}: ok (attempt ${i}/${attempts})"
            return 0
        fi
        log_debug "${desc}: attempt ${i}/${attempts} failed"
        (( i < attempts )) && sleep "$delay"
    done
    log_warn "${desc}: gave up after ${attempts} attempts"
    return 1
}

# wait_for <timeout_seconds> <description> <command...>
wait_for() {
    local timeout="$1" desc="$2"; shift 2
    local waited=0
    while (( waited < timeout )); do
        if "$@" >/dev/null 2>&1; then
            log_debug "${desc}: ready after ${waited}s"
            return 0
        fi
        sleep 1
        waited=$(( waited + 1 ))
    done
    log_warn "${desc}: not ready after ${timeout}s"
    return 1
}

# ---------------------------------------------------------------------------
# Kernel / capability helpers
# ---------------------------------------------------------------------------

# Ensure /dev/net/tun exists. The Dockerfile cannot create it because /dev is a
# tmpfs mounted at container start, and containerd >= 1.7.24 no longer permits
# tun/tap by default unless the device is explicitly granted.
ensure_tun_device() {
    if [ -c /dev/net/tun ]; then
        return 0
    fi
    log_info "Creating /dev/net/tun (c 10 200)"
    mkdir -p /dev/net
    if ! mknod /dev/net/tun c 10 200 2>/dev/null; then
        die "Cannot create /dev/net/tun. Add '--device /dev/net/tun' or '--cap-add MKNOD'."
    fi
    chmod 0600 /dev/net/tun
}

# WARP marks its own sockets with src_valid_mark; without this the tunnel's
# packets are dropped by reverse-path filtering.
ensure_warp_sysctls() {
    local key val
    for key in net.ipv4.conf.all.src_valid_mark net.ipv4.ip_forward; do
        val=1
        if ! sysctl -qw "${key}=${val}" 2>/dev/null; then
            log_debug "Could not set ${key} (host may not allow it)"
        fi
    done
    # The container is a router: asymmetric routing is expected.
    sysctl -qw net.ipv4.conf.all.rp_filter=0 2>/dev/null || true
    sysctl -qw net.ipv4.conf.default.rp_filter=0 2>/dev/null || true
}

# Load nf modules when the host exposes them; harmless when they are built in.
ensure_nft_support() {
    if ! command -v nft >/dev/null 2>&1; then
        die "nft not found. WARP configures its tunnel with nftables."
    fi
    local m
    for m in nf_tables nft_masq nft_chain_nat nft_nat; do
        modprobe "$m" 2>/dev/null || true
    done
    if ! nft list ruleset >/dev/null 2>&1; then
        die "Cannot read the nftables ruleset. The container needs CAP_NET_ADMIN and a host kernel with nf_tables."
    fi
}

# ---------------------------------------------------------------------------
# Network namespace plumbing
#
# Every networking command funnels through ns_run so the same script can drive
# WARP either inside its own namespace (all-in-one) or in the container's own
# namespace (warp-only).
# ---------------------------------------------------------------------------

WARP_NETNS="${WARP_NETNS:-}"

# The namespace is held open by a long-lived `unshare --net` process and reached
# with nsenter. This deliberately avoids `ip netns`, which bind-mounts the
# namespace into /run/netns: Docker's default AppArmor profile denies
# `mount --make-shared /run/netns`, so `ip netns add` fails with
# "mount --make-shared /run/netns failed: Permission denied" even with
# CAP_SYS_ADMIN. Holding the namespace with a process needs no mount.
NETNS_HOLDER_PID="${NETNS_HOLDER_PID:-/run/cfw2tsen-netns.pid}"

_ns_pid() {
    [ -f "$NETNS_HOLDER_PID" ] || return 1
    local pid
    pid="$(cat "$NETNS_HOLDER_PID" 2>/dev/null)" || return 1
    [ -n "$pid" ] || return 1
    # Confirm the holder is alive and is really our namespace.
    kill -0 "$pid" 2>/dev/null || return 1
    [ -e "/proc/${pid}/ns/net" ] || return 1
    printf '%s' "$pid"
}

ns_exists() {
    [ -n "${WARP_NETNS:-}" ] || return 1
    _ns_pid >/dev/null 2>&1
}

# ns_run <command...> — run inside the WARP namespace when one is held.
ns_run() {
    local pid
    if pid="$(_ns_pid)"; then
        nsenter --net="/proc/${pid}/ns/net" -- "$@"
    else
        "$@"
    fi
}

# ns_run_root <command...> — always run in the container's own namespace.
ns_run_root() {
    "$@"
}

ns_create() {
    local ns="$1"
    if ns_exists; then
        log_debug "network namespace ${ns} already held by pid $(_ns_pid)"
        return 0
    fi

    mkdir -p "$(dirname "$NETNS_HOLDER_PID")"
    log_info "Creating network namespace ${ns} (held by unshare)"

    # `unshare --net` creates the namespace; the sleeping process keeps it
    # alive. Its stdin is held open by a fifo so the process cannot exit early.
    unshare --net -- sleep infinity &
    local pid=$!
    printf '%s' "$pid" > "$NETNS_HOLDER_PID"

    # Wait for the new namespace to be visible.
    local waited=0
    while [ ! -e "/proc/${pid}/ns/net" ] && (( waited < 50 )); do
        sleep 0.1
        waited=$(( waited + 1 ))
    done
    if [ ! -e "/proc/${pid}/ns/net" ]; then
        die "Could not create the network namespace (unshare --net failed)."
    fi

    ns_run ip link set lo up
    log_info "Created network namespace ${ns} (pid ${pid})"
}

ns_delete() {
    local ns="$1"
    local pid
    pid="$(_ns_pid 2>/dev/null)" || { rm -f "$NETNS_HOLDER_PID"; return 0; }
    # Kill anything still holding the namespace, then the holder itself.
    ns_run sh -c 'command -v pkill >/dev/null 2>&1 && pkill -TERM -P 1 2>/dev/null; true' 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
    sleep 0.2
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -f "$NETNS_HOLDER_PID"
    log_debug "Deleted network namespace ${ns}"
}

# ns_has_default_route — true when the namespace can already reach the underlay.
ns_has_default_route() {
    ns_run ip route show default 2>/dev/null | grep -q '^default'
}
