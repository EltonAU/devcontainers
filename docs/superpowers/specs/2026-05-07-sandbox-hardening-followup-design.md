# Devcontainer Sandbox Hardening — Follow-up Design

**Date:** 2026-05-07
**Status:** Approved for implementation planning
**Builds on:** `2026-05-06-sandbox-hardening-design.md`
**Scope:** Address Codex's follow-up review of the v2 templates: close the lifecycle gaps Codex identified (#2, #3), tighten CI to validate Features (#4, #5), reduce ergonomic-collision risk (#6), correct stale documentation (#7), document the broad-AWS trade-off (#1), and refresh all pinned versions to current stable.

## Goal

The first hardening pass left three real lifecycle gaps:
- **Phase 3 (Features install)**: dotnet Feature runs unfiltered, no firewall yet, with credential volumes mounted.
- **Phase 4 (post-start window)**: 10–30 seconds between container start and `postStartCommand` running the firewall.
- **IPv6**: `iptables` only governs IPv4; IPv6 egress is unfiltered.

This pass closes them where feasible and tightens CI so Feature regressions get caught before publish. Out of scope (and deliberately): full base-image SHA-digest pinning, an SNI-aware egress proxy, and any Docker-build-phase firewall (architecturally impossible).

## Threat model (unchanged)

Same as v1 design: the agent is *untrusted but not malicious*. We constrain network egress and enforce read-only AWS/GitHub by IAM/PAT scope. We are not defending against an actively malicious agent that has reached arbitrary code execution.

## Architectural changes

### 1. ENTRYPOINT-driven firewall (#3A, "post-start window")

**Files:** `src/_shared/Dockerfile`, `src/_shared/entrypoint.sh` (new), `src/base/.devcontainer/devcontainer.json`, `src/csharp/.devcontainer/devcontainer.json`.

Replace the implicit `node:<x>` entrypoint with a thin wrapper that runs the firewall first, then exec's into the container's normal command. This brings firewall application from "after container is fully up + IDE attached + post-start fires" to "before any container process runs".

`src/_shared/entrypoint.sh` (new file):

```bash
#!/usr/bin/env bash
set -e
sudo /usr/local/bin/init-firewall.sh
exec "$@"
```

In `src/_shared/Dockerfile`, after the firewall script copy/sudoers setup, append:

```dockerfile
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
USER root
RUN chmod +x /usr/local/bin/entrypoint.sh
USER node
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
```

Drop `"postStartCommand": "sudo /usr/local/bin/init-firewall.sh"` from both `devcontainer.json` files.

The assembler must copy the new `entrypoint.sh` into each template's `.devcontainer/` (mirror the existing Dockerfile copy logic).

**Trade-offs:**
- Container "ready" time goes up by ~10–15 s. Acceptable.
- Failure mode shifts from "container starts unfiltered, then firewall applies" to "container fails to start if firewall init fails". Fail-closed is the correct posture.
- The firewall script still needs DNS + outbound HTTPS to fetch GitHub IPs and AWS `ip-ranges.json`. The script already builds rules incrementally (DNS allowed before default DROP), so the fetch order continues to work.

### 2. Feature SHA-digest pinning (#3B, "Features install")

**Files:** `src/csharp/.devcontainer/devcontainer.json`, `README.md`.

The csharp template currently pulls `ghcr.io/devcontainers/features/dotnet:2` — a tag, mutable upstream. Switch to digest:

```jsonc
"features": {
  "ghcr.io/devcontainers/features/dotnet@sha256:<digest>": {
    "version": "9.0",
    "installUsingApt": false
  }
}
```

The digest is resolved at implementation time by querying GHCR's manifest for the current `:2` tag. README's "Adding a new language template" section adds a step: when a Feature is added or bumped, resolve its current SHA-digest and pin in `devcontainer.json`.

**Trade-off:** every intentional Feature bump requires a digest re-pin. Same friction as our SHA-pinned GitHub Actions; acceptable for the supply-chain win.

### 3. IPv6 default-drop (#2)

**Files:** `src/_shared/init-firewall.base.sh`, `.github/workflows/validate.yml`.

Today's firewall uses only `iptables` (IPv4). If Docker is configured with IPv6, all v6 egress is unfiltered. Add `ip6tables` rules right after the existing `iptables -F` block at the top of the script:

```bash
# IPv6: deny by default; we do not allowlist any v6 traffic.
ip6tables -F
ip6tables -X
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT DROP
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A OUTPUT -o lo -j ACCEPT
```

In `validate.yml`, the firewall smoke tests get a new must-fail check:

```bash
if curl --connect-timeout 5 -6 -fsS https://ipv6.google.com >/dev/null 2>&1; then
  echo "FAIL: IPv6 egress reachable"; exit 1
fi
```

If the test environment doesn't have IPv6 connectivity at all, this check passes trivially — that's fine; it's a regression guard, not a presence check.

### 4. Real `devcontainer build` in CI (#4)

**Files:** `.github/workflows/validate.yml`.

Today CI runs `docker build` on each assembled `Dockerfile`. That validates the Dockerfile but not the `features` block in `devcontainer.json` — meaning the csharp template's `dotnet` Feature is currently never exercised by CI. Anything that breaks the Feature configuration only surfaces at release time.

Replace the existing "Docker build" step with:

```yaml
- name: Install devcontainer CLI
  run: npm install -g @devcontainers/cli

- name: Devcontainer build (each template)
  run: |
    set -euo pipefail
    for d in build/*/; do
      template=$(basename "$d")
      echo "Building $template..."
      devcontainer build --workspace-folder "$d" --image-name "devcontainer-test:$template"
    done
```

`devcontainer build` runs the full pipeline: Dockerfile build → Features apply → lifecycle hooks. The resulting images carry tags like `devcontainer-test:base` and `devcontainer-test:csharp`, which the existing smoke-test steps `docker run` against (no change there).

**Trade-off:** CI run time goes up (each Feature install adds time). Acceptable; this is the protection we wanted.

### 5. csharp firewall smoke test (#5)

**Files:** `.github/workflows/validate.yml`.

Duplicate the "Firewall smoke test (base)" step for csharp. Add a NuGet reachability assertion to confirm the csharp-specific allowlist works:

```bash
curl --connect-timeout 5 -fsS https://api.nuget.org/v3/index.json >/dev/null
```

Plus the same must-fail checks as base (example.com unreachable, DNS-to-8.8.8.8 dropped, IPv6 egress dropped, sts.amazonaws.com reachable).

### 6. `projectId` default tightening (#6)

**Files:** `src/base/devcontainer-template.json`, `src/csharp/devcontainer-template.json`, `README.md`.

Today's default is `"myproject"` — too friendly. A user who hits enter without supplying `--template-args` (or accepts the default in VS Code's prompt) silently gets the same volumes shared across every project. Change the default to a value that's deliberately wrong:

```jsonc
"options": {
  "projectId": {
    "type": "string",
    "description": "REQUIRED: unique per project. Becomes part of Docker volume names so credentials don't collide across projects. Use lowercase letters, digits, hyphens. If you leave the default, multiple projects WILL share volumes.",
    "default": "CHANGE-ME-PER-PROJECT"
  }
}
```

Anyone who accepts the default ends up with volumes containing the literal string `CHANGE-ME-PER-PROJECT`, which is impossible to miss in `docker volume ls` and obvious in any troubleshooting output. The README's first-time-login section gets an upfront warning about this.

### 7. Template descriptions + design-notes update (#7, #1)

**Files:** `src/base/devcontainer-template.json`, `src/csharp/devcontainer-template.json`, `README.md`.

The `description` field in both templates currently lists "Anthropic, OpenAI, npm, GitHub, and VS Code endpoints" only. AWS, DNS lockdown, and SSH/host blocks are missing. Update to:

> "Sandboxed devcontainer with Claude Code and OpenAI Codex CLI both preinstalled. Outbound network locked to Anthropic, OpenAI, npm, GitHub, AWS, [NuGet for csharp,] and VS Code endpoints; DNS scoped to the Docker resolver; SSH and host network blocked. Credentials persist via per-project named Docker volumes."

(csharp variant inserts NuGet; both variants otherwise identical text.)

In the README's "Design notes" section, add a bullet recording the deliberate broad-AWS trade-off:

> - **AWS allowlist is broad by design.** The firewall allows the full `service==AMAZON` set from `ip-ranges.amazonaws.com`, not a curated subset of services or regions. This means CloudFront-hosted third-party content and arbitrary AWS-hosted services are reachable. Read-only IAM scope on the supplied keys is the primary blast-radius limit; tightening to specific services/regions is possible but adds maintenance, and a stronger policy would require an SNI-aware egress proxy.

### 8. Version refresh

**Files:** `src/_shared/Dockerfile`, `src/csharp/.devcontainer/devcontainer.json`, both `devcontainer-template.json`.

Bump every pinned version to current stable at implementation time. Specific items:

- `FROM node:20.20.2` → latest active-LTS Node major. As of 2026-05, expect Node 24 LTS; if 24 isn't yet LTS at lookup time, fall back to Node 22.
- `CLAUDE_CODE_VERSION=2.1.121` → latest `@anthropic-ai/claude-code` from npm
- `CODEX_VERSION=0.125.0` → latest `@openai/codex` from npm
- `AWS_CLI_VERSION=2.34.43` → latest stable 2.x.y from `aws/aws-cli` GitHub tags
- `GIT_DELTA_VERSION=0.18.2` → latest from `dandavison/delta` releases
- `ZSH_IN_DOCKER_VERSION=1.2.0` → latest from `deluan/zsh-in-docker` releases
- dotnet Feature → resolve current `:2` tag's SHA-digest (per section 2)
- Both `devcontainer-template.json` `version` → bump to `2.0.0` (entrypoint change is breaking for consumers who layered onto v1)

Lookup commands are straightforward (npm view, GitHub API, GHCR API). Plan will list them.

## CI behavior after this pass

Given the changes, `validate.yml` runs on push/PR with steps:

1. JSON validation (jq)
2. Shellcheck on `init-firewall.base.sh`, `assemble-templates.sh`, `entrypoint.sh`, and assembled output
3. Assemble templates
4. Install devcontainer CLI
5. `devcontainer build` per template (validates Features)
6. Firewall smoke test (base) — allowed reachable, blocked unreachable, DNS lockdown, IPv6 dropped, STS reachable
7. Firewall smoke test (csharp) — same as base + NuGet reachable

## Out of scope (deliberately)

- **Base image SHA-digest pinning.** Tag-only is the design choice; monthly digest churn isn't worth it.
- **SNI-aware egress proxy** for narrowing the AWS allowlist (#1 deeper fix). Documented as a deliberate trade-off; the next step if the IP-based approach proves brittle.
- **Phase-1 (Docker build) firewall.** Docker build doesn't grant `NET_ADMIN`; iptables can't run during build. External mitigations only (version pinning, registry trust).
- **Per-project AWS profile switching via direnv.** Declined in v1; single readonly profile remains the model.
- **Multi-template Feature catalog.** No new templates in this pass.

## Implementation phases

A reasonable order (the implementation plan will detail each):

1. Entrypoint wrapper (file, Dockerfile change, devcontainer.json updates, assembler update).
2. IPv6 lockdown in firewall script.
3. Feature SHA-digest pinning (csharp).
4. CI: install devcontainer CLI, switch to `devcontainer build`.
5. CI: csharp firewall smoke test + NuGet check + IPv6 must-fail check.
6. `projectId` default change + descriptions update + README updates (default warning + AWS trade-off bullet + Feature-pinning step).
7. Version refresh (lookup-driven; can be parallelised with other phases at implementation time).

Each phase is independently mergeable.

## Open questions

None. All design decisions above are approved by the user.
