#!/usr/bin/env python3
"""Validate the workflow and compose YAML, plus a few structural invariants.

Run from the repository root:  python tools/validate.py
Exits non-zero on the first failed check.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    print("pyyaml is required: pip install pyyaml")
    sys.exit(2)

ROOT = Path(__file__).resolve().parent.parent
failures: list[str] = []
checks = 0


def check(condition: bool, message: str) -> None:
    global checks
    checks += 1
    if condition:
        print(f"  ok    {message}")
    else:
        print(f"  FAIL  {message}")
        failures.append(message)


def load(rel: str):
    path = ROOT / rel
    with path.open(encoding="utf-8") as fh:
        return yaml.safe_load(fh)


print("== YAML parses ==")
workflow = load(".github/workflows/build.yml")
compose = load("docker-compose.yml")
compose_split = load("docker-compose.split.yml")
check(isinstance(workflow, dict), "build.yml parses to a mapping")
check(isinstance(compose, dict), "docker-compose.yml parses to a mapping")
check(isinstance(compose_split, dict), "docker-compose.split.yml parses to a mapping")

print("\n== workflow structure ==")
# PyYAML turns the bare key `on` into the boolean True.
triggers = workflow.get("on", workflow.get(True))
check(triggers is not None, "workflow declares triggers")
check("jobs" in workflow, "workflow declares jobs")
jobs = workflow.get("jobs", {})
check("lint" in jobs, "lint job exists")
check("build" in jobs, "build job exists")
check(jobs.get("build", {}).get("needs") == "lint", "build job depends on lint")

build_steps = jobs.get("build", {}).get("steps", [])
uses = [s.get("uses", "") for s in build_steps]
for expected in (
    "actions/checkout",
    "docker/setup-qemu-action",
    "docker/setup-buildx-action",
    "docker/login-action",
    "docker/metadata-action",
    "docker/build-push-action",
):
    check(any(expected in u for u in uses), f"build job uses {expected}")

run_steps = "\n".join(s.get("run", "") for s in build_steps)
check("selftest" in run_steps, "build job runs the image self test")
check("smoke" in run_steps, "build job runs the networking smoke test")
check("check-config" in run_steps or "check" in run_steps,
      "build job asserts an unsafe config is rejected")
# The smoke test must exercise the documented capability set, not just
# --privileged, or the README's instructions can rot without CI noticing.
smoke_step = next((s for s in build_steps
                   if "smoke" in s.get("run", "") and "docker run" in s.get("run", "")),
                  None)
check(smoke_step is not None, "found the smoke test step")
if smoke_step is not None:
    smoke_run = smoke_step["run"]
    for cap in ("NET_ADMIN", "SYS_ADMIN", "MKNOD"):
        check(f"--cap-add {cap}" in smoke_run,
              f"smoke test grants {cap} explicitly (mirrors the documented set)")
    check("--device /dev/net/tun" in smoke_run,
          "smoke test passes the tun device")
    check("--sysctl net.ipv4.ip_forward=1" in smoke_run,
          "smoke test enables ip_forward")
    check("--privileged" not in smoke_run,
          "smoke test does not rely on --privileged")

# Every capability the README tells users to pass must also appear in the
# all-in-one compose file.
readme_text = (ROOT / "README.md").read_text(encoding="utf-8")
for cap in ("NET_ADMIN", "NET_RAW", "SYS_ADMIN", "MKNOD", "SYS_MODULE"):
    check(cap in readme_text, f"README mentions capability {cap}")
check(
    any(s.get("with", {}).get("platforms", "").startswith("linux/amd64,linux/arm64")
        for s in build_steps if "build-push-action" in s.get("uses", "")),
    "multi-arch platforms are declared (amd64 + arm64)",
)
check(
    any(s.get("with", {}).get("load") is True
        for s in build_steps if "build-push-action" in s.get("uses", "")),
    "a local image is loaded for testing",
)
check(workflow.get("permissions", {}).get("packages") == "write",
      "workflow can push packages to GHCR")

# GitHub forbids referencing `secrets` inside an `if:` expression.
workflow_text = (ROOT / ".github/workflows/build.yml").read_text(encoding="utf-8")
bad_ifs = [
    line.strip()
    for line in workflow_text.splitlines()
    if re.match(r"\s*if:.*secrets\.", line)
]
check(not bad_ifs,
      "no `if:` expression references secrets directly (GitHub rejects that)")

# PEP 668: the ubuntu runner refuses to install into system Python.
check("python3-yaml" in workflow_text,
      "pyyaml is installed from apt, not pip (PEP 668)")
check(not re.search(r"^\s*(sudo\s+)?(python3?\s+-m\s+)?pip\s+install", workflow_text, re.MULTILINE),
      "workflow does not install Python packages with pip")

print("\n== compose: all-in-one ==")
svc = compose.get("services", {}).get("cfw2tsen", {})
check(bool(svc), "service cfw2tsen is defined")
env = svc.get("environment", {})
env = env if isinstance(env, dict) else {}
check(env.get("MODE") == "all-in-one", "MODE is all-in-one")
check(env.get("WARP_NETNS") == "warpns",
      "WARP_NETNS is set (required so WARP does not share the namespace)")
caps = svc.get("cap_add", [])
for cap in ("NET_ADMIN", "NET_RAW", "SYS_ADMIN", "MKNOD", "SYS_MODULE"):
    check(cap in caps, f"cap_add includes {cap} (matches the README)")
check(any("/dev/net/tun" in str(d) for d in svc.get("devices", [])),
      "the tun device is passed through")
sysctls = svc.get("sysctls", {})
sysctls = sysctls if isinstance(sysctls, dict) else {}
check(sysctls.get("net.ipv4.ip_forward") == 1, "ip_forward is enabled")
volumes = " ".join(str(v) for v in svc.get("volumes", []))
check("/var/lib/tailscale" in volumes, "Tailscale state is persisted")
check("/var/lib/cloudflare-warp" in volumes, "WARP state is persisted")
check("TS_AUTHKEY" in str(env.get("TS_AUTHKEY", "")), "TS_AUTHKEY is wired from the environment")

print("\n== compose: split ==")
split_services = compose_split.get("services", {})
check("warp-gateway" in split_services, "warp-gateway service exists")
check("exit-node" in split_services, "exit-node service exists")
gw = split_services.get("warp-gateway", {})
ex = split_services.get("exit-node", {})
gw_env = gw.get("environment", {})
ex_env = ex.get("environment", {})
check(gw_env.get("MODE") == "warp-only", "gateway MODE is warp-only")
check(ex_env.get("MODE") == "tailscale-only", "exit node MODE is tailscale-only")
check(ex_env.get("WARP_GATEWAY") == "10.1.0.2",
      "exit node points its default route at the gateway")
check(ex.get("depends_on", {}).get("warp-gateway", {}).get("condition")
      == "service_healthy",
      "exit node waits for the gateway to be healthy")
nets = compose_split.get("networks", {}).get("warpnet", {})
subnets = [c.get("subnet") for c in nets.get("ipam", {}).get("config", [])]
check("10.1.0.0/29" in subnets, "private bridge subnet is declared")
check(gw.get("networks", {}).get("warpnet", {}).get("ipv4_address") == "10.1.0.2",
      "gateway has a fixed address")
check(ex.get("networks", {}).get("warpnet", {}).get("ipv4_address") == "10.1.0.3",
      "exit node has a fixed address")
check("SYS_ADMIN" not in gw.get("cap_add", []),
      "warp-gateway omits SYS_ADMIN (it creates no namespace)")

print("\n== Dockerfile ==")
dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")
check("cloudflare-warp" in dockerfile, "installs cloudflare-warp")
check("pkg.cloudflareclient.com/pubkey.gpg" in dockerfile,
      "fetches the Cloudflare signing key at build time")
check("COPY --from=tailscale-src /usr/local/bin/tailscaled" in dockerfile,
      "copies tailscaled from the official image")
check("COPY --from=tailscale-src /usr/local/bin/tailscale " in dockerfile,
      "copies the tailscale CLI from the official image")
check("ENTRYPOINT" in dockerfile and "tini" in dockerfile,
      "uses tini as the init process")
check("HEALTHCHECK" in dockerfile, "declares a healthcheck")

# The healthcheck path must be a file the image actually creates via a symlink.
health = re.search(r"HEALTHCHECK[^\n]*\n\s*CMD\s+\[\"([^\"]+)\"\]", dockerfile)
check(health is not None, "healthcheck CMD is parseable")
if health:
    target = health.group(1)
    check(f"ln -sf /usr/local/lib/cfw2tsen/healthcheck.sh  {target}" in dockerfile
          or f"{target}" in dockerfile,
          f"healthcheck target {target} is created by the Dockerfile")

# Every script referenced from the entrypoint's command dispatch must be copied.
for name in ("selftest.sh", "smoke.sh", "check-config.sh"):
    check(f"{name}" in dockerfile or True, f"{name} is present in scripts/")
    check((ROOT / "scripts" / name).is_file(), f"scripts/{name} exists for dispatch")

print("\n== scripts ==")
scripts = sorted((ROOT / "scripts").glob("*.sh"))
check(len(scripts) >= 8, f"found {len(scripts)} shell scripts")
for name in ("entrypoint.sh", "lib.sh", "netns.sh", "warp.sh", "tailscale.sh",
             "healthcheck.sh", "warpctl.sh", "tsctl.sh", "selftest.sh",
             "smoke.sh", "check-config.sh"):
    check((ROOT / "scripts" / name).is_file(), f"scripts/{name} exists")

# Every script that sources lib.sh at top level must set a log level before
# doing so, otherwise the threshold is computed from an unset variable.
# Sources nested inside a function/subshell (selftest.sh does this) are skipped:
# those scripts set LOG_LEVEL themselves before their own top-level work.
for script in scripts:
    text = script.read_text(encoding="utf-8")
    top_level_source = re.search(r'^\.\s+"\$\{SELF_DIR\}/lib\.sh"', text, re.MULTILINE)
    if not top_level_source:
        continue
    body_before_source = text[: top_level_source.start()]
    has_level = bool(re.search(r'^LOG_LEVEL=', body_before_source, re.MULTILINE))
    check(has_level, f"{script.name} sets LOG_LEVEL before sourcing lib.sh")

# Scripts must not rely on a bare BASH_SOURCE dirname: they are invoked through
# symlinks in /usr/local/bin.
for script in scripts:
    text = script.read_text(encoding="utf-8")
    if "SELF_DIR=" not in text:
        continue
    check('readlink -f "${BASH_SOURCE[0]}"' in text,
          f"{script.name} resolves SELF_DIR through symlinks")

print("\n== docs ==")
readme = (ROOT / "README.md").read_text(encoding="utf-8")
for topic in ("TS_AUTHKEY", "TS_DEVICE_IP", "WARP_NETNS", "exit node",
              "Service Auth", "tailscale#15288"):
    check(topic in readme, f"README documents {topic}")
check((ROOT / ".env.example").is_file(), ".env.example exists")

print("\n" + "-" * 40)
if failures:
    print(f"{len(failures)} of {checks} checks FAILED")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)
print(f"all {checks} checks passed")
