#!/usr/bin/env bash
# In-image self test.
#
# Validates the image contents without touching the network or registering a
# WARP account, so it is safe to run in CI and on a laptop:
#
#   docker run --rm cfw2tsen selftest
#   docker run --rm --cap-add NET_ADMIN --device /dev/net/tun cfw2tsen selftest
#
# With NET_ADMIN it additionally proves that dbus and warp-svc really start in
# a container, which is the failure mode that fixed sleeps usually hide.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

pass=0
fail=0
skip=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; pass=$(( pass + 1 )); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$(( fail + 1 )); }
skipped() { printf '  \033[33mSKIP\033[0m  %s\n' "$*"; skip=$(( skip + 1 )); }
section() { printf '\n== %s ==\n' "$*"; }

echo "cfw2tsen self test"

# ---------------------------------------------------------------------------
section "Shell syntax"
# ---------------------------------------------------------------------------
for f in "${SELF_DIR}"/*.sh; do
    if bash -n "$f" 2>/dev/null; then
        ok "bash -n $(basename "$f")"
    else
        bad "bash -n $(basename "$f")"
        bash -n "$f" || true
    fi
done

# ---------------------------------------------------------------------------
section "Required binaries"
# ---------------------------------------------------------------------------
for c in bash ip nft iptables curl jq dbus-daemon warp-svc warp-cli tailscaled tailscale tini python3; do
    if command -v "$c" >/dev/null 2>&1; then
        ok "found $c"
    else
        bad "missing $c"
    fi
done

# ---------------------------------------------------------------------------
section "Versions"
# ---------------------------------------------------------------------------
if dpkg-query -W -f='${Version}' cloudflare-warp >/dev/null 2>&1; then
    ok "cloudflare-warp $(dpkg-query -W -f='${Version}' cloudflare-warp 2>/dev/null)"
else
    bad "cloudflare-warp is not installed"
fi

if v="$(tailscaled --version 2>&1 | head -n1)"; then
    ok "tailscaled: ${v}"
else
    bad "tailscaled --version failed"
fi

# ---------------------------------------------------------------------------
section "Configuration validation"
# ---------------------------------------------------------------------------
# A valid all-in-one configuration must pass...
if MODE=all-in-one WARP_NETNS=warpns TS_AUTHKEY=tskey-auth-test-only \
   WARP_ENABLE=1 TS_ADVERTISE_EXIT_NODE=1 \
   bash "${SELF_DIR}/check-config.sh" >/dev/null 2>&1; then
    ok "check-config accepts a valid all-in-one configuration"
else
    bad "check-config rejected a valid all-in-one configuration"
    MODE=all-in-one WARP_NETNS=warpns TS_AUTHKEY=tskey-auth-test-only bash "${SELF_DIR}/check-config.sh" || true
fi

# ...and a configuration that co-locates WARP with Tailscale must fail.
# WARP_NETNS must be empty here, hence WARP_NETNS='' rather than WARP_NETNS=.
if MODE=all-in-one WARP_NETNS='' TS_AUTHKEY=tskey-auth-test-only \
   bash "${SELF_DIR}/check-config.sh" >/dev/null 2>&1; then
    bad "check-config accepted WARP without a netns in all-in-one mode"
else
    ok "check-config rejects WARP and Tailscale sharing a namespace"
fi

# A bad device address must be rejected.
if MODE=all-in-one WARP_NETNS=warpns TS_AUTHKEY=tskey-auth-test-only TS_DEVICE_IP=not-an-ip \
   bash "${SELF_DIR}/check-config.sh" >/dev/null 2>&1; then
    bad "check-config accepted an invalid TS_DEVICE_IP"
else
    ok "check-config rejects an invalid TS_DEVICE_IP"
fi

# ---------------------------------------------------------------------------
section "MDM XML escaping"
# ---------------------------------------------------------------------------
# A '&' or '<' in a service-token secret must not produce malformed XML, which
# warp-svc would silently ignore.
mdm_tmp="$(mktemp -d)"
# write_mdm_config reads WARP_STATE_DIR from the environment, so export it for
# the subshell rather than assigning a shell-local it would not see.
(
    # shellcheck source=lib.sh
    . "${SELF_DIR}/lib.sh"
    # shellcheck source=netns.sh
    . "${SELF_DIR}/netns.sh"
    # shellcheck source=warp.sh
    . "${SELF_DIR}/warp.sh"
    WARP_STATE_DIR="$mdm_tmp"
    export WARP_STATE_DIR
    write_mdm_config 'team&co' 'id<with>chars' 'secret&value'
) >/dev/null 2>&1
if [ -f "$mdm_tmp/mdm.xml" ] \
   && python3 -c 'import sys,xml.etree.ElementTree as E; E.parse(sys.argv[1])' "$mdm_tmp/mdm.xml" 2>"$mdm_tmp/parse.err"; then
    ok "MDM configuration stays valid XML with special characters"
else
    bad "MDM configuration is malformed when values contain & or <"
    # Print the reason rather than swallowing it: the XML may be well-formed
    # while the interpreter itself is the problem.
    sed -n '1,5p' "$mdm_tmp/mdm.xml" 2>/dev/null | sed 's/^/        /' || true
    sed -n '1,5p' "$mdm_tmp/parse.err" 2>/dev/null | sed 's/^/        /' || true
fi
if grep -q 'team&amp;co' "$mdm_tmp/mdm.xml" 2>/dev/null; then
    ok "MDM values are XML-escaped (&)"
else
    bad "MDM values are not XML-escaped (&)"
fi
# Assert the < and > cases explicitly. Checking only '&' misses the bash 5.2
# patsub_replacement bug, where '&lt;' expands to '<lt;' and emits a raw '<'.
if grep -q 'id&lt;with&gt;chars' "$mdm_tmp/mdm.xml" 2>/dev/null; then
    ok "MDM values are XML-escaped (< and >)"
else
    bad "MDM values are not XML-escaped (< and >)"
    grep -n 'auth_client_id' -A1 "$mdm_tmp/mdm.xml" 2>/dev/null | sed 's/^/        /' || true
fi
rm -rf "$mdm_tmp"

# ---------------------------------------------------------------------------
section "Kernel capabilities (optional)"
# ---------------------------------------------------------------------------
if nft list ruleset >/dev/null 2>&1; then
    ok "nftables is usable (CAP_NET_ADMIN present)"

    if [ -c /dev/net/tun ]; then
        ok "/dev/net/tun is present"
    else
        bad "/dev/net/tun is missing; pass --device /dev/net/tun"
    fi

    # Prove the daemon really comes up, which a fixed sleep would mask.
    mkdir -p /run/dbus
    if ! [ -S /run/dbus/system_bus_socket ]; then
        dbus-daemon --system --fork --nopidfile >/dev/null 2>&1 \
            || dbus-daemon --config-file=/usr/share/dbus-1/system.conf --fork >/dev/null 2>&1
    fi
    if [ -S /run/dbus/system_bus_socket ]; then
        ok "dbus system bus is running"
    else
        bad "dbus system bus did not start"
    fi

    mkdir -p /var/lib/cloudflare-warp
    warp-svc --accept-tos >/tmp/selftest-warp-svc.log 2>&1 &
    svc_pid=$!
    reachable=0
    for _ in $(seq 1 30); do
        if warp-cli --accept-tos status >/dev/null 2>&1; then
            reachable=1
            break
        fi
        sleep 1
    done
    if [ "$reachable" = "1" ]; then
        ok "warp-svc is reachable via warp-cli"
    else
        bad "warp-svc did not become reachable"
        tail -n 20 /tmp/selftest-warp-svc.log 2>/dev/null || true
    fi
    kill "$svc_pid" 2>/dev/null || true
    wait "$svc_pid" 2>/dev/null || true
else
    skipped "nftables unusable: no CAP_NET_ADMIN, skipping daemon test"
fi

# ---------------------------------------------------------------------------
printf '\n%s\n' "----------------------------------------"
printf 'PASS=%d FAIL=%d SKIP=%d\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] || exit 1
echo "self test OK"
