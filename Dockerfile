# syntax=docker/dockerfile:1.7
#
# cfw2tsen — Cloudflare WARP → Tailscale exit node
#
# One image, three roles (see MODE in scripts/entrypoint.sh):
#   all-in-one      WARP (isolated netns) + tailscaled exit node, single container
#   warp-only       WARP NAT gateway, for use with the split compose file
#   tailscale-only  tailscaled exit node whose default route is a WARP gateway
#
# WARP is deliberately kept in a separate network namespace from tailscaled.
# WARP's nftables `input`/`output` chains use `policy drop` and only admit
# Cloudflare endpoints, private/CGNAT ranges and the CloudflareWARP device, so
# co-locating it with tailscaled drops inbound direct WireGuard traffic.
# See https://github.com/tailscale/tailscale/issues/15288

ARG DEBIAN_RELEASE=bookworm
# Empty means "whatever the repository currently ships". Set it to pin, e.g.
# --build-arg TAILSCALE_VERSION=1.80.3
ARG TAILSCALE_VERSION=
ARG TRACK=stable

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_RELEASE}-slim AS runtime

# ARGs declared before FROM are only visible to FROM instructions, so they must
# be re-declared here. Without this, `set -u` in the RUN below aborts the build
# on an unbound variable.
ARG TAILSCALE_VERSION
ARG TRACK

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Never let a package's postinst try to start a systemd unit: there is no init.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
 && chmod 0755 /usr/sbin/policy-rc.d

# dbus         warp-svc talks to a system bus, even headless
# iproute2     ip / ss, required for the netns + policy routing glue
# nftables     WARP installs its rules with nft; we add NAT/MSS rules with it
# iptables     docker's FORWARD policy is DROP, we add explicit accepts
# kmod         modprobe for nf modules where the host allows it
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      dbus \
      gnupg \
      iproute2 \
      iptables \
      iputils-ping \
      jq \
      kmod \
      nftables \
      procps \
      python3 \
      tini \
 && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Cloudflare WARP client
#
# The repository signing key is re-fetched on every build on purpose:
# Cloudflare rotated it on 2025-09-12 and stated the repository stops working
# for keys installed before that date. Baking a cached key breaks the build.
# https://pkg.cloudflareclient.com/
# ---------------------------------------------------------------------------
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    set -euo pipefail \
 && . /etc/os-release \
 && curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
      | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${VERSION_CODENAME} main" \
      > /etc/apt/sources.list.d/cloudflare-client.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends cloudflare-warp \
 && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Tailscale, from the vendor's own apt repository.
#
# The repository URL and key come from the URLs that Tailscale's installer
# script (scripts/installer.sh) uses for the keyring method, so this tracks the
# supported install path rather than guessing at an image's internal layout.
# ---------------------------------------------------------------------------
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    set -euo pipefail \
 && . /etc/os-release \
 && curl -fsSL "https://pkgs.tailscale.com/${TRACK}/debian/${VERSION_CODENAME}.noarmor.gpg" \
      > /usr/share/keyrings/tailscale-archive-keyring.gpg \
 && chmod 0644 /usr/share/keyrings/tailscale-archive-keyring.gpg \
 && curl -fsSL "https://pkgs.tailscale.com/${TRACK}/debian/${VERSION_CODENAME}.tailscale-keyring.list" \
      > /etc/apt/sources.list.d/tailscale.list \
 && chmod 0644 /etc/apt/sources.list.d/tailscale.list \
 && apt-get update \
 && if [ -n "${TAILSCALE_VERSION}" ]; then \
        apt-get install -y --no-install-recommends "tailscale=${TAILSCALE_VERSION}" tailscale-archive-keyring; \
    else \
        apt-get install -y --no-install-recommends tailscale tailscale-archive-keyring; \
    fi \
 && rm -rf /var/lib/apt/lists/* \
 && tailscaled --version \
 && tailscale --version

# State directories, declared as volumes so identity survives a container
# replace. Losing /var/lib/tailscale makes the node appear as a new device.
RUN install -d -m 0755 /var/lib/tailscale /var/lib/cloudflare-warp \
 && install -d -m 0755 /var/run/netns /etc/netns \
 && install -d -m 0755 /var/log/cfw2tsen

COPY scripts/ /usr/local/lib/cfw2tsen/
RUN chmod 0755 /usr/local/lib/cfw2tsen/*.sh \
 && ln -sf /usr/local/lib/cfw2tsen/entrypoint.sh   /usr/local/bin/entrypoint.sh \
 && ln -sf /usr/local/lib/cfw2tsen/healthcheck.sh  /usr/local/bin/healthcheck.sh \
 && ln -sf /usr/local/lib/cfw2tsen/warpctl.sh      /usr/local/bin/warpctl \
 && ln -sf /usr/local/lib/cfw2tsen/tsctl.sh        /usr/local/bin/tsctl

ENV \
    MODE=all-in-one \
    WARP_ENABLE=1 \
    WARP_MODE=warp \
    WARP_NETNS=warpns \
    WARP_ACCEPT_TOS=1 \
    WARP_SLEEP=5 \
    WARP_ENABLE_NAT=1 \
    WARP_EXCLUDE_TAILSCALE=1 \
    WARP_PROXY_PORT=40000 \
    TS_USERSPACE=false \
    TS_STATE_DIR=/var/lib/tailscale \
    TS_ADVERTISE_EXIT_NODE=1 \
    TS_ACCEPT_DNS=false \
    TS_AUTH_ONCE=true \
    VETH_HOST_IP=10.200.0.1 \
    VETH_WARP_IP=10.200.0.2 \
    VETH_PREFIX=30 \
    WARP_ROUTE_TABLE=200 \
    WARP_TUN_IFACE=CloudflareWARP \
    TS_TAILNET_CIDR=100.64.0.0/10 \
    LOG_LEVEL=info

# Tailscale needs NET_ADMIN + /dev/net/tun; WARP additionally needs MKNOD and
# nftables, and creating its network namespace needs SYS_ADMIN. The exact
# capability set is documented in README.md; --privileged also works.
VOLUME ["/var/lib/tailscale", "/var/lib/cloudflare-warp"]

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD []
