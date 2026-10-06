# cfw2tsen

**Cloudflare WARP egress for a Tailscale exit node.**

A single Docker image that routes your Tailscale exit-node traffic out through
Cloudflare WARP, so your devices get a Cloudflare egress IP while staying on your
tailnet.

- 🔒 **Isolated by design** — WARP runs in its own network namespace, because
  co-locating it with Tailscale breaks inbound WireGuard (see
  [Why a namespace](#why-a-namespace)).
- 🧩 **One image, three roles** — all-in-one, split gateway + exit node, or
  standalone.
- ⚙️ **Fully configurable** — auth keys, device IP, hostname, tags, subnet
  routes, Zero Trust service tokens, WARP+ license, split-tunnel exclusions.
- 🏗️ **Multi-arch CI** — `linux/amd64` and `linux/arm64`, built, self-tested and
  smoke-tested on every push, published to GHCR.

---

## Quick start

```bash
git clone https://github.com/avianjay/cfw2tsen.git
cd cfw2tsen
cp .env.example .env
# Put your Tailscale auth key in .env
$EDITOR .env

docker compose up -d
docker compose logs -f
```

Then **approve the exit node** (required once):

1. Open <https://login.tailscale.com/admin/machines>
2. Find the device (it gets an **Exit Node** badge)
3. **⋯ → Edit route settings… → tick “Use as exit node” → Save**

Point a client at it:

```bash
tailscale set --exit-node=cfw2tsen-exit-node
curl https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|warp)='
# ip=104.28.x.x
# warp=on
```

That `warp=on` line is the whole point: the traffic left through Cloudflare.

---

## Why a namespace

The obvious implementation — run `warp-svc` and `tailscaled` side by side — does
not work. WARP installs nftables chains with `policy drop`:

```nft
table inet cloudflare-warp {
    chain input  { type filter hook input  priority filter; policy drop; ... }
    chain output { type filter hook output priority filter; policy drop; ... }
    chain forward { type filter hook forward priority mangle; policy accept; ... }
}
```

Only Cloudflare endpoints, private/CGNAT ranges and the `CloudflareWARP` device
are admitted. Inbound direct WireGuard from tailnet peers arrives from a public
address and is silently dropped, so the exit node only works over DERP relays —
or not at all. This is [tailscale#15288][issue], where a Tailscale maintainer
recommends exactly what this image does: separate network namespaces, and route
the exit traffic into WARP.

```
 root netns                          warpns
 ┌───────────────────────────┐       ┌───────────────────────────┐
 │ tailscaled (exit node)    │       │ warp-svc                  │
 │  tailscale0 100.x.y.z     │       │  CloudflareWARP (tun)     │
 │                           │       │                           │
 │ eth0 ──► internet         │       │ default via 10.200.0.1    │
 │ veth-host 10.200.0.1/30 ◄─┼───────┼─► veth0 10.200.0.2/30     │
 └───────────────────────────┘       └───────────────────────────┘

 root:   ip rule iif tailscale0 lookup 200
         ip route default via 10.200.0.2 dev veth-host table 200
 warpns: ip rule iif veth0 lookup <warp-table>
         nft masquerade oifname CloudflareWARP
```

Two details make this work without loops:

- **Steering matches the ingress interface** (`iif tailscale0`), not the source
  address. A source rule for `100.64.0.0/10` would also capture tailscaled's own
  control-plane and DERP packets — which share that range and must leave via
  `eth0` — and would break the node's connectivity.
- **WARP's own underlay is not steered.** It arrives on `veth-host`, so it keeps
  using the real default route. Its return path inside the namespace is pinned to
  the main table so replies are not fed back into the tunnel.

[issue]: https://github.com/tailscale/tailscale/issues/15288

---

## Deployments

### All-in-one (default)

One container, both components, WARP isolated. See `docker-compose.yml`.

```yaml
services:
  cfw2tsen:
    image: ghcr.io/avianjay/cfw2tsen:latest
    cap_add: [NET_ADMIN, NET_RAW, SYS_ADMIN, MKNOD, SYS_MODULE]
    devices: ["/dev/net/tun:/dev/net/tun"]
    sysctls:
      net.ipv4.ip_forward: 1
      net.ipv6.conf.all.forwarding: 1
      net.ipv4.conf.all.src_valid_mark: 1
    environment:
      MODE: all-in-one
      WARP_NETNS: warpns
      TS_AUTHKEY: ${TS_AUTHKEY}
      TS_ADVERTISE_EXIT_NODE: 1
```

### Split (gateway + exit node)

Two containers on a private bridge: a WARP NAT gateway and a Tailscale exit node
whose default route points at it. Use this when you cannot grant the all-in-one
container the capabilities it needs, or when the gateway should serve other
workloads too. See `docker-compose.split.yml`.

```bash
docker compose -f docker-compose.split.yml up -d
```

### Docker run

```bash
docker run -d --name cfw2tsen \
  --cap-add NET_ADMIN --cap-add NET_RAW --cap-add SYS_ADMIN \
  --cap-add MKNOD --cap-add SYS_MODULE \
  --device /dev/net/tun \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv6.conf.all.forwarding=1 \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  -e TS_AUTHKEY=tskey-auth-... \
  -e TS_HOSTNAME=cfw2tsen-exit-node \
  -e TS_ADVERTISE_EXIT_NODE=1 \
  -v tailscale-state:/var/lib/tailscale \
  -v warp-state:/var/lib/cloudflare-warp \
  --restart unless-stopped \
  ghcr.io/avianjay/cfw2tsen:latest
```

> **Why `SYS_ADMIN`.** Creating a network namespace (`unshare(CLONE_NEWNET)`)
> and entering it (`nsenter`) require `CAP_SYS_ADMIN`; `NET_ADMIN` alone covers
> the nftables rules but not the namespace. The split deployment's
> `warp-gateway` does not need it, because that role does not create one.
>
> **Why not `ip netns`.** The namespace is held open by a long-lived
> `unshare --net` process and entered with `nsenter`, rather than with
> `ip netns add`. That is deliberate: `ip netns add` bind-mounts the namespace
> into `/run/netns`, and Docker's default AppArmor profile denies
> `mount --make-shared /run/netns`, so it fails with
> `mount --make-shared /run/netns failed: Permission denied` even with
> `CAP_SYS_ADMIN`. Holding the namespace with a process needs no such mount.
> The trade-off is that the namespace is addressed by PID instead of by name;
> `warpctl shell` and `warpctl nft` handle that for you.
>
> **Why DNS still works even though `/etc/resolv.conf` is shared.** WARP rewrites
> `/etc/resolv.conf` to its own resolver on `127.0.2.2`/`127.0.2.3`, which only
> exists inside the WARP namespace. Because that file lives in the *mount*
> namespace, one copy is shared with tailscaled — which is why DNS used to break
> until you turned Tailscale DNS off. Duplicating the file is not possible here:
> Docker's default AppArmor profile contains a blanket `deny mount,`, so
> `unshare --mount` dies with `cannot change root filesystem propagation:
> Permission denied` and no bind mount can be created, whatever capabilities you
> add. Instead the single shared file is made correct for *both* namespaces: a
> stub resolver ([dnsmasq](https://dnsmasq.org/)) runs in the container's own
> namespace on the very same `127.0.2.2`/`127.0.2.3`, so each namespace resolves
> through its own listener on its own loopback. See
> [`scripts/dns.sh`](scripts/dns.sh) and `WARP_ROOT_DNS_STUB` below.
>
> **If your runtime still refuses the capability list** — older containerd and
> Podman are the usual culprits — use `--privileged` instead. That always works,
> at the cost of a much wider grant. Prefer the explicit list where you can.

---

## Configuration

Every variable has a working default except `TS_AUTHKEY`. Full list with
comments in [`.env.example`](.env.example).

### Tailscale

| Variable | Default | Meaning |
|---|---|---|
| `TS_AUTHKEY` | — | Auth key (`tskey-auth-…`). Also accepts `file:/path/to/key`. |
| `TS_AUTHKEY_FILE` | — | Read the key from a file (for Docker/Podman secrets). |
| `TS_HOSTNAME` | `cfw2tsen-exit-node` | Node name in the admin console. |
| `TS_ADVERTISE_EXIT_NODE` | `1` | Advertise as an exit node. |
| `TS_ADVERTISE_ROUTES` | — | Subnet routes, e.g. `192.168.1.0/24`. |
| `TS_ADVERTISE_TAGS` | — | ACL tags, e.g. `tag:exit-node`. |
| `TS_USERSPACE` | `false` | Kernel TUN mode. See [Userspace mode](#userspace-mode). |
| `TS_ACCEPT_DNS` | `false` | Let Tailscale manage `/etc/resolv.conf`. |
| `TS_AUTH_ONCE` | `true` | Reuse persisted state instead of re-registering. |
| `TS_ACCEPT_ROUTES` | `false` | Accept routes advertised by other nodes. |
| `TS_SSH` | `0` | Enable Tailscale SSH on this node. |
| `TS_NETFILTER_MODE` | — | `on`, `nodivert` or `off`. |
| `TS_EXTRA_ARGS` | — | Extra flags appended to `tailscale up`. |
| `TS_STATE_DIR` | `/var/lib/tailscale` | **Mount a volume here.** |

#### The auth key

Create one at <https://login.tailscale.com/admin/settings/keys>:

- **Reusable: yes** if the container may need to register more than once
  (a wiped volume, a changed hostname). A one-shot key plus `TS_AUTH_ONCE=true`
  and a persisted volume is tighter.
- **Ephemeral: no** — an exit node should be a persistent device.
- **Tags**: set `TS_ADVERTISE_TAGS` to match, if you use tag-based ACLs.

Prefer a secret file over the environment, so the key does not appear in
`docker inspect`:

```yaml
environment:
  TS_AUTHKEY: file:/run/secrets/ts_authkey
volumes:
  - ./ts_authkey:/run/secrets/ts_authkey:ro
```

> **Always persist `TS_STATE_DIR`.** Without a volume the container registers a
> brand-new node on every restart and your admin console fills with duplicates.

### Setting the device IP

`tailscale up` and `tailscale set` have **no flag** to request a specific
address, and there is no `TS_IP` variable — the control plane assigns it. The
supported way to pin one is the Tailscale API, which this image calls after the
node registers:

```bash
TS_DEVICE_IP=100.64.0.10
TS_API_KEY=tskey-api-xxxxxxxxxxxx
TS_TAILNET=your-tailnet.ts.net
```

The address must be **free and inside your tailnet's IPv4 range**. To check the
range, look at any existing node's address, or configure an IP pool in your
policy file:

```json
{
  "nodeAttrs": [
    { "target": ["tag:exit-node"], "ipPool": ["100.64.0.0/24"] }
  ]
}
```

If no API credential is supplied the image logs a warning and keeps the assigned
address; the node still works, just not at the address you asked for. You can
also change the address by hand in the admin console at any time.

> Set the address **before** clients start using the node. Changing it later
> moves the node and clients pointing at the old address lose the exit path.

### Cloudflare WARP

| Variable | Default | Meaning |
|---|---|---|
| `WARP_MODE` | `warp` | `warp` (full tunnel) or `proxy` (SOCKS5). |
| `WARP_NETNS` | `warpns` | Isolation namespace. **Keep set in all-in-one mode.** |
| `WARP_ROOT_DNS_STUB` | `1` | Run a stub resolver in the container namespace on `127.0.2.2`/`127.0.2.3`, so the shared `/etc/resolv.conf` stays valid in both namespaces. Leave on unless you supply your own resolver. |
| `WARP_ENABLE_NAT` | `1` | Masquerade forwarded traffic onto the tunnel. |
| `WARP_EXCLUDE_TAILSCALE` | `1` | Keep tailnet ranges out of the tunnel. |
| `WARP_EXCLUDE_EXTRA` | — | Extra split-tunnel exclusions, comma separated. |
| `WARP_LICENSE_KEY` | — | WARP+ license (`xxxxxxxx-xxxxxxxx-xxxxxxxx`). |
| `WARP_ORG` | — | Zero Trust organization name. |
| `WARP_AUTH_CLIENT_ID` | — | Zero Trust service token — client id. |
| `WARP_AUTH_CLIENT_SECRET` | — | Zero Trust service token — secret. |
| `WARP_TEAMS_TOKEN` | — | Enrollment token URL. |
| `WARP_TEAM` | — | Team name for Zero Trust enrollment. |

#### Free WARP or Zero Trust

With none of the Zero Trust variables set, the image registers a free consumer
WARP account — no Cloudflare account needed.

For Zero Trust, set all three of `WARP_ORG`, `WARP_AUTH_CLIENT_ID` and
`WARP_AUTH_CLIENT_SECRET`. This writes the MDM configuration that `warp-svc`
reads at startup, which is the only fully headless Zero Trust path:

```xml
<dict>
    <key>auth_client_id</key><string>…</string>
    <key>auth_client_secret</key><string>…</string>
    <key>organization</key><string>your-team</string>
    <key>auto_connect</key><integer>1</integer>
    <key>onboarding</key><false/>
    <key>service_mode</key><string>warp</string>
</dict>
```

> The Access policy for a service token **must use the “Service Auth” action**.
> “Allow” does not work for service tokens and produces a `400` on enrollment.

### Runtime

| Variable | Default | Meaning |
|---|---|---|
| `MODE` | `all-in-one` | `all-in-one`, `warp-only`, `tailscale-only`. |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error`. |
| `WARP_VERIFY_EGRESS` | `1` | Verify egress through WARP at startup. |
| `WARP_GATEWAY` | — | Gateway address for `MODE=tailscale-only`. |
| `WARP_ROUTE_TABLE` | `200` | Routing table used to steer exit traffic. |
| `VETH_HOST_IP` / `VETH_WARP_IP` | `10.200.0.1` / `10.200.0.2` | veth addressing. |

---

## Operations

```bash
docker exec cfw2tsen warpctl status     # WARP state, interfaces, rules
docker exec cfw2tsen warpctl trace      # egress IP, including forwarded traffic
docker exec cfw2tsen warpctl reconnect  # bounce the tunnel
docker exec cfw2tsen warpctl nft        # dump both nftables rulesets
docker exec cfw2tsen warpctl shell      # shell inside the WARP namespace

docker exec cfw2tsen tsctl status       # tailscale status + netcheck
docker exec cfw2tsen tsctl ip           # this node's addresses
docker exec cfw2tsen tsctl set-ip 100.64.0.10
docker exec cfw2tsen tsctl approve-hint # how to approve the exit node

docker exec cfw2tsen check              # validate the configuration
```

### Verifying it works

```bash
# Inside the container: is WARP connected?
docker exec cfw2tsen warpctl status | head -n 5

# Does forwarded traffic (what exit-node clients generate) leave via WARP?
docker exec cfw2tsen warpctl trace

# From a client using this exit node:
curl https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|warp|loc)='
```

At startup the container runs a real forwarding check: it creates a throwaway
network namespace whose only route out is this container, fetches Cloudflare's
trace endpoint from inside it, and asserts `warp=on`. That exercises the whole
path — policy routing, forwarding, NAT and MSS clamping — rather than just
proving the tunnel is up. A failure is logged as a warning, and the reason is
visible in `docker logs`.

The client-side trace must report `warp=on` **and** a Cloudflare address. If it
reports `warp=off` with your home IP, the client is not using the exit node yet
(check that it is approved, and that the client ran
`tailscale set --exit-node=…`).

### Troubleshooting

| Symptom | Cause and fix |
|---|---|
| **DNS broken until Tailscale DNS is turned off** | `/etc/resolv.conf` is one file shared by both network namespaces, and WARP rewrites it to its own `127.0.2.2`/`127.0.2.3` resolver, which exists only inside the WARP namespace — so the container's own resolver was left pointing at nothing. Duplicating the file needs a bind mount, which Docker's default AppArmor profile denies outright (`deny mount,`), so the fix is to run a stub resolver in the container namespace on those same addresses. Both namespaces then resolve through their own listener on their own loopback. Turning Tailscale DNS off only masked the symptom. Verify with `warpctl status` and the `DNS root namespace … / DNS warp namespace …` lines at startup. |
| `Operation not permitted` opening TUN | Add `--device /dev/net/tun`. containerd ≥ 1.7.24 no longer grants tun/tap by default. |
| `Unable to connect to CloudflareWARP daemon` | `warp-svc` was not up yet. This image waits for the CLI, so seeing it means the daemon crashed — check `docker logs`. |
| Exit node works over relays only, no direct connection | WARP and Tailscale share a namespace. Set `WARP_NETNS=warpns`. |
| Client has no internet through the exit node | Exit node not approved, or `WARP_ENABLE_NAT=0`. |
| `Failed to run NFT command` | Host kernel lacks `nf_tables` (some NAS devices). Use `WARP_MODE=proxy` instead. |
| Large transfers stall, small requests work | MTU. The image clamps MSS; if it persists, lower the client MTU (`TS_DEBUG_MTU=1280`). |
| Duplicate devices in the admin console | `TS_STATE_DIR` is not on a persistent volume. |
| `Registration Missing due to: Does not exist in API` | Zero Trust service-token policy is not set to **Service Auth**. |
| `Authentication Expired` | Container clock is off by >20s. Fix host NTP. |

---

## Userspace mode

`TS_USERSPACE=true` runs `tailscaled --tun=userspace-networking`. It needs no
`/dev/net/tun` and no `NET_ADMIN`, which is handy on restricted hosts — but an
exit node in this mode **only carries TCP and UDP**. ICMP, SCTP and everything
else is dropped, and throughput is lower. Kernel mode (`TS_USERSPACE=false`, the
default) is strongly recommended for an exit node.

## Security notes

This container is a router with `NET_ADMIN`, a TUN device and a network
namespace. That is inherent to being an exit node — an exit node decrypts and
forwards other devices' traffic. Concretely:

- **Only your tailnet can use it.** Tailscale authenticates peers; the container
  does not expose the exit path to the public internet. Do not publish its ports.
- **`--privileged` is broad.** Prefer the explicit capability list. Use
  `--privileged` only if your runtime rejects the narrower set.
- **Both state volumes hold credentials.** `/var/lib/tailscale` contains the node
  key; `/var/lib/cloudflare-warp` contains the WARP registration. Treat them as
  secrets and back them up accordingly.
- **An exit node sees plaintext** for any traffic its clients do not encrypt
  themselves. Run it on a host you trust.

## Building

```bash
docker build -t cfw2tsen .

# Pin the Tailscale version (default: whatever the stable repo ships):
docker build --build-arg TAILSCALE_VERSION=1.80.3 -t cfw2tsen .

# Validate the image without touching the network:
docker run --rm --cap-add NET_ADMIN --cap-add MKNOD --device /dev/net/tun \
  cfw2tsen selftest

# Validate the netns/veth/policy-routing plumbing, still offline.
# Uses the same capability set the README documents for production.
docker run --rm \
  --cap-add NET_ADMIN --cap-add NET_RAW --cap-add SYS_ADMIN --cap-add MKNOD \
  --device /dev/net/tun \
  --sysctl net.ipv4.ip_forward=1 \
  cfw2tsen smoke
```

Both vendor clients come from their **own apt repositories** —
`pkg.cloudflareclient.com` and `pkgs.tailscale.com` — using the same URLs each
vendor's installer uses, so the image tracks the supported install path.

Cloudflare's signing key is re-fetched on every build. This is deliberate: the
key was rotated on 2025-09-12 and the repository stopped working for keys
installed before then, so a cached key breaks the build.

### CI

`.github/workflows/build.yml` runs on every push and pull request:

1. **lint** — `bash -n` and `shellcheck` on all scripts.
2. **build** — builds `linux/amd64` + `linux/arm64`, runs `selftest` and `smoke`
   inside the image, asserts that an unsafe configuration is rejected, then
   pushes a multi-arch manifest.

Published tags: `edge` and `sha-<short>` on the default branch, semver tags for
`v*.*.*` releases, `latest` for the newest release.

To push to Docker Hub as well, add `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`
repository secrets — the workflow skips that step when they are absent.

## License

MIT
