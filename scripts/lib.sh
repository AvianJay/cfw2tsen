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

# The namespace is held open by a long-lived `unshare` process and reached with
# nsenter. This deliberately avoids `ip netns`, which bind-mounts the namespace
# into /run/netns: Docker's default AppArmor profile denies
# `mount --make-shared /run/netns`, so `ip netns add` fails with
# "mount --make-shared /run/netns failed: Permission denied" even with
# CAP_SYS_ADMIN. Holding the namespace with a process needs no such mount.
#
# The holder unshares the MOUNT namespace as well as the network namespace.
# That part is essential, not incidental. WARP rewrites /etc/resolv.conf to its
# own resolver on 127.0.2.2/127.0.2.3, which only exists inside the WARP
# namespace. With a single shared /etc/resolv.conf that rewrite is visible to
# tailscaled in the root namespace, whose DNS then dies -- and turning Tailscale
# DNS off only masks it. `ip netns exec` used to provide this isolation
# implicitly; unsharing the mount namespace restores it explicitly.
NETNS_HOLDER_PID="${NETNS_HOLDER_PID:-/run/cfw2tsen-netns.pid}"
# Private resolver bind-mounted over /etc/resolv.conf inside the WARP namespace.
WARP_RESOLV_CONF="${WARP_RESOLV_CONF:-/etc/cfw2tsen/resolv.conf}"

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

# True when the holder has its own mount namespace, so /etc/resolv.conf is
# private to it and WARP's rewrite cannot reach the root namespace.
ns_has_mount_isolation() {
    local pid
    pid="$(_ns_pid)" || return 1
    [ -e "/proc/${pid}/ns/mnt" ] || return 1
    [ "/proc/${pid}/ns/mnt" -ef "/proc/self/ns/mnt" ] && return 1
    return 0
}

# ns_run <command...> — run inside the WARP namespace when one is held.
# Enters the mount namespace too, so the command sees the namespace's own
# /etc/resolv.conf rather than the root one.
ns_run() {
    local pid
    if pid="$(_ns_pid)"; then
        local args=(--net="/proc/${pid}/ns/net")
        if ns_has_mount_isolation; then
            args+=(--mount="/proc/${pid}/ns/mnt")
        fi
        nsenter "${args[@]}" -- "$@"
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

    # Seed the namespace's private resolver. warp-svc needs working DNS for the
    # registration handshake before it installs its own 127.0.2.2 resolver.
    mkdir -p "$(dirname "$WARP_RESOLV_CONF")"
    if [ ! -s "$WARP_RESOLV_CONF" ]; then
        printf 'nameserver 1.1.1.1\nnameserver 1.0.0.1\n' > "$WARP_RESOLV_CONF"
    fi

    log_info "Creating network namespace ${ns} (held by unshare)"

    # --mount gives the namespace a private /etc/resolv.conf; the sleeping
    # process keeps both namespaces alive.
    unshare --net --mount -- sleep infinity &
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

    ns_isolate_resolv_conf

    ns_run ip link set lo up
    log_info "Created network namespace ${ns} (pid ${pid})"
}

# Give the WARP namespace its own /etc/resolv.conf.
#
# This bind mount is what keeps WARP's rewrite of that file away from the root
# namespace. Mounts are made private first, so the bind cannot propagate back out
# of the namespace when the container's / is a shared mount.
ns_isolate_resolv_conf() {
    local pid
    pid="$(_ns_pid)" || return 1

    if ! nsenter --net="/proc/${pid}/ns/net" --mount="/proc/${pid}/ns/mnt" -- \
         sh -c '
             mount --make-rprivate / 2>/dev/null || true
             mkdir -p /etc
             mount --bind "$1" /etc/resolv.conf
         ' _ "$WARP_RESOLV_CONF" 2>/dev/null; then
        log_warn "Could not give the WARP namespace its own /etc/resolv.conf; DNS may be shared with the container."
        return 1
    fi

    log_debug "WARP namespace has a private /etc/resolv.conf (${WARP_RESOLV_CONF})"
    return 0
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
