# Devcontainer Sandbox Hardening Follow-up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

> **User preference (overrides skill default):** Do NOT run `git commit` at the end of any task. After each task's implementation steps complete, stop and report "Task N is ready for review." The user reviews and commits at the end of the whole pass.

**Goal:** Apply the hardening described in `docs/superpowers/specs/2026-05-07-sandbox-hardening-followup-design.md`: ENTRYPOINT-driven firewall, Feature SHA-digest pinning, IPv6 default-drop, real `devcontainer build` in CI, csharp smoke test, `projectId` default tightening, doc updates, and a full version refresh.

**Architecture:** Single source of truth at `src/_shared/`. Templates compose at build time via `scripts/assemble-templates.sh`. CI uses `@devcontainers/cli` to validate the full Features pipeline. Firewall applies via container ENTRYPOINT, not `postStartCommand`.

**Tech Stack:** Bash, jq, ip6tables, devcontainer-templates spec, GitHub Actions, Docker, `@devcontainers/cli`.

---

## Pre-execution context

- Repo root: `e:\Professional\MyProjects\devcontainers` (Windows host).
- Prior hardening pass (`2026-05-06-sandbox-hardening-design.md`) is fully implemented in the working tree but **not committed yet** — the user will review and commit everything at the end of this pass.
- Source-of-truth files:
  - `src/_shared/Dockerfile`
  - `src/_shared/init-firewall.base.sh`
  - `scripts/assemble-templates.sh`
  - `src/base/`, `src/csharp/` (each with `devcontainer-template.json`, `.devcontainer/devcontainer.json`, `.devcontainer/init-firewall.fragment`)
  - `.github/workflows/{release.yml, validate.yml}`
- Read both design docs before starting:
  - `docs/superpowers/specs/2026-05-06-sandbox-hardening-design.md`
  - `docs/superpowers/specs/2026-05-07-sandbox-hardening-followup-design.md`

---

## Task 1: ENTRYPOINT wrapper

**Goal:** Apply the firewall before any container process runs, eliminating the post-start window.

**Files:**
- Create: `src/_shared/entrypoint.sh`
- Modify: `src/_shared/Dockerfile`
- Modify: `src/base/.devcontainer/devcontainer.json`
- Modify: `src/csharp/.devcontainer/devcontainer.json`
- Modify: `scripts/assemble-templates.sh`

- [ ] **Step 1: Create `src/_shared/entrypoint.sh`**

```bash
#!/usr/bin/env bash
set -e
sudo /usr/local/bin/init-firewall.sh
exec "$@"
```

Mark executable: `chmod +x src/_shared/entrypoint.sh`.

- [ ] **Step 2: Update `src/_shared/Dockerfile`**

Find the existing block at the bottom of the Dockerfile that copies `init-firewall.sh` and configures sudoers (look for `COPY init-firewall.sh /usr/local/bin/` followed by the sudoers `echo`). The current state ends with `USER node` after the sudoers setup.

Append immediately after the existing `USER node` line:

```dockerfile
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
USER root
RUN chmod +x /usr/local/bin/entrypoint.sh
USER node

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
```

- [ ] **Step 3: Update `scripts/assemble-templates.sh`**

The assembler currently copies the shared `Dockerfile` and assembles `init-firewall.sh`. It must now also copy `entrypoint.sh` from `src/_shared/` into each template's `.devcontainer/`. Find the block that copies the Dockerfile (a `cp "$SHARED_DIR/Dockerfile" "$out/.devcontainer/Dockerfile"` line) and add immediately after it:

```bash
    cp "$SHARED_DIR/entrypoint.sh" "$out/.devcontainer/entrypoint.sh"
    chmod +x "$out/.devcontainer/entrypoint.sh"
```

- [ ] **Step 4: Drop `postStartCommand` from both `devcontainer.json` files**

In `src/base/.devcontainer/devcontainer.json` and `src/csharp/.devcontainer/devcontainer.json`, remove the line:

```jsonc
"postStartCommand": "sudo /usr/local/bin/init-firewall.sh",
```

(Including its trailing comma. Make sure the JSON still parses afterward — the line above it should not have a trailing comma if `postStartCommand` was the last property in its block.)

- [ ] **Step 5: Re-assemble and verify**

```sh
bash scripts/assemble-templates.sh
ls build/base/.devcontainer build/csharp/.devcontainer
```

Both directories must contain `entrypoint.sh` alongside the existing files. Then verify the assembled Dockerfile contains the `ENTRYPOINT` line:

```sh
grep -E '^ENTRYPOINT' build/base/.devcontainer/Dockerfile build/csharp/.devcontainer/Dockerfile
```

Expected: both files show `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]`.

Verify both assembled `devcontainer.json` files no longer reference `postStartCommand`:

```sh
grep -E 'postStartCommand|postCreateCommand' build/base/.devcontainer/devcontainer.json build/csharp/.devcontainer/devcontainer.json && echo "FOUND" || echo "GONE"
```

Expected: `GONE`.

- [ ] **Step 6: Stop**

Report "Task 1 (ENTRYPOINT wrapper) is ready for review."

---

## Task 2: IPv6 default-drop

**Goal:** Prevent IPv6 egress from bypassing our IPv4-only iptables rules.

**Files:**
- Modify: `src/_shared/init-firewall.base.sh`

- [ ] **Step 1: Insert IPv6 lockdown after the existing iptables flush block**

Find this block near the top of `src/_shared/init-firewall.base.sh`:

```bash
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true
```

Insert immediately after `ipset destroy allowed-domains ...`:

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

- [ ] **Step 2: Re-assemble**

```sh
bash scripts/assemble-templates.sh
```

- [ ] **Step 3: Verify**

```sh
grep -E '^ip6tables' build/base/.devcontainer/init-firewall.sh | wc -l
grep -E '^ip6tables' build/csharp/.devcontainer/init-firewall.sh | wc -l
```

Expected: both report `7` (seven `ip6tables` lines).

- [ ] **Step 4: Stop**

Report "Task 2 (IPv6 lockdown) is ready for review."

---

## Task 3: Feature SHA-digest pinning (csharp)

**Goal:** Replace the mutable `ghcr.io/devcontainers/features/dotnet:2` tag with an immutable `@sha256:<digest>` reference so the dotnet Feature can't be swapped out from under us.

**Files:**
- Modify: `src/csharp/.devcontainer/devcontainer.json`

- [ ] **Step 1: Resolve the current digest of the `:2` tag**

The Feature lives at `ghcr.io/devcontainers/features/dotnet`. To resolve a tag to a manifest digest from GHCR (which uses the OCI Distribution Spec), use the `manifests` endpoint with an anonymous bearer token:

```sh
TOKEN=$(curl -fsSL "https://ghcr.io/token?scope=repository:devcontainers/features/dotnet:pull" | jq -r .token)
curl -fsSL -I -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.oci.image.index.v1+json" \
  -H "Accept: application/vnd.oci.image.manifest.v1+json" \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
  -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
  "https://ghcr.io/v2/devcontainers/features/dotnet/manifests/2" \
  | grep -i '^docker-content-digest:' \
  | awk '{print $2}' | tr -d '\r'
```

Record the printed `sha256:<...>` value. If the curl returns `401`, the token scope or `Accept` headers are wrong; retry. If GHCR is unreachable, report `BLOCKED` — do not guess a digest.

- [ ] **Step 2: Update the csharp `devcontainer.json`**

In `src/csharp/.devcontainer/devcontainer.json`, find:

```jsonc
"features": {
  "ghcr.io/devcontainers/features/dotnet:2": {
    "version": "9.0",
    "installUsingApt": false
  }
},
```

Replace the key only (preserve the `version` and `installUsingApt` values):

```jsonc
"features": {
  "ghcr.io/devcontainers/features/dotnet@sha256:<DIGEST-FROM-STEP-1>": {
    "version": "9.0",
    "installUsingApt": false
  }
},
```

- [ ] **Step 3: Re-assemble and verify**

```sh
bash scripts/assemble-templates.sh
grep -E 'ghcr.io/devcontainers/features/dotnet' src/csharp/.devcontainer/devcontainer.json build/csharp/.devcontainer/devcontainer.json
```

Both occurrences must contain `@sha256:` and the resolved digest.

Validate JSON still parses:

```sh
python3 -c "import json; json.load(open('build/csharp/.devcontainer/devcontainer.json'))"
```

- [ ] **Step 4: Stop**

Report "Task 3 (Feature digest pinning) is ready for review. Digest pinned: `<digest>`."

---

## Task 4: Real `devcontainer build` in CI

**Goal:** CI must validate the full devcontainer pipeline (Dockerfile + Features + lifecycle), not just the Dockerfile.

**Files:**
- Modify: `.github/workflows/validate.yml`

- [ ] **Step 1: Replace the Docker build step**

Find the existing step:

```yaml
      - name: Docker build (each template)
        run: |
          set -euo pipefail
          for d in build/*/.devcontainer; do
            template=$(basename "$(dirname "$d")")
            echo "Building $template..."
            docker build -t "devcontainer-test:$template" "$d"
          done
```

Replace with two steps:

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

Note the path change: `build/*/` (workspace folder, contains `.devcontainer/`), not `build/*/.devcontainer` (which was the Dockerfile context). `devcontainer build` infers the rest.

- [ ] **Step 2: Verify YAML still parses**

```sh
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/validate.yml'))"
```

(If `pyyaml` isn't installed locally, skip — GitHub Actions will reject malformed YAML.)

- [ ] **Step 3: Stop**

Report "Task 4 (devcontainer build in CI) is ready for review."

---

## Task 5: csharp firewall smoke test + IPv6 must-fail

**Goal:** Validate the csharp template's firewall (NuGet/dotnet allowlist) and add an IPv6 must-fail check to both base and csharp smoke tests.

**Files:**
- Modify: `.github/workflows/validate.yml`

- [ ] **Step 1: Add IPv6 must-fail check to the existing base smoke test**

Find the base smoke test step (it has `devcontainer-test:base`). Inside its inline shell script, after the existing `! dig +time=2 +tries=1 @8.8.8.8 ...` check, add:

```bash
              if curl --connect-timeout 5 -6 -fsS https://ipv6.google.com >/dev/null 2>&1; then
                echo "FAIL: IPv6 egress reachable"; exit 1
              fi
```

- [ ] **Step 2: Add csharp smoke test step**

After the base smoke test step, add a parallel csharp step. The full step:

```yaml
      - name: Firewall smoke test (csharp)
        run: |
          set -euo pipefail
          docker run --rm \
            --cap-add=NET_ADMIN --cap-add=NET_RAW \
            --entrypoint /bin/bash \
            devcontainer-test:csharp \
            -c '
              sudo /usr/local/bin/init-firewall.sh
              # Allowed
              curl --connect-timeout 5 -fsS https://api.github.com/zen >/dev/null
              curl --connect-timeout 5 -fsS https://sts.amazonaws.com >/dev/null
              curl --connect-timeout 5 -fsS https://api.nuget.org/v3/index.json >/dev/null
              # Blocked
              if curl --connect-timeout 5 -fsS https://example.com >/dev/null 2>&1; then
                echo "FAIL: example.com reachable"; exit 1
              fi
              if dig +time=2 +tries=1 @8.8.8.8 google.com >/dev/null 2>&1; then
                echo "FAIL: DNS to 8.8.8.8 succeeded"; exit 1
              fi
              if curl --connect-timeout 5 -6 -fsS https://ipv6.google.com >/dev/null 2>&1; then
                echo "FAIL: IPv6 egress reachable"; exit 1
              fi
              echo "csharp smoke test passed"
            '
```

Note: this step uses `--entrypoint /bin/bash` to bypass our new `entrypoint.sh` (since the smoke test calls `init-firewall.sh` itself for explicit verification). That's intentional — the test exercises the firewall script directly, independent of the entrypoint.

- [ ] **Step 3: Verify YAML parses and grep coverage**

```sh
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/validate.yml'))" 2>/dev/null && echo "YAML OK" || echo "YAML FAILED"
grep -c 'IPv6 egress reachable' .github/workflows/validate.yml
grep -c 'devcontainer-test:csharp' .github/workflows/validate.yml
grep -c 'api.nuget.org' .github/workflows/validate.yml
```

Expected: `YAML OK`, IPv6 check appears 2 times (base + csharp), `devcontainer-test:csharp` appears at least 1 time, `api.nuget.org` appears at least 1 time.

- [ ] **Step 4: Stop**

Report "Task 5 (csharp smoke test + IPv6 must-fail) is ready for review."

---

## Task 6: `projectId` default + descriptions + design-notes

**Goal:** Make accidentally-shared volumes obvious, mention AWS in template descriptions, document the broad-AWS trade-off.

**Files:**
- Modify: `src/base/devcontainer-template.json`
- Modify: `src/csharp/devcontainer-template.json`
- Modify: `README.md`

- [ ] **Step 1: Update `projectId` option in both `devcontainer-template.json` files**

In `src/base/devcontainer-template.json` and `src/csharp/devcontainer-template.json`, replace the existing `projectId` option block with:

```jsonc
"projectId": {
  "type": "string",
  "description": "REQUIRED: unique per project. Becomes part of Docker volume names so credentials don't collide across projects. Use lowercase letters, digits, hyphens. If you leave the default, multiple projects WILL share volumes.",
  "default": "CHANGE-ME-PER-PROJECT"
}
```

- [ ] **Step 2: Update template `description` fields**

Use Read to view each `devcontainer-template.json` first, then update only the top-level `description` field (preserve every other field).

`src/base/devcontainer-template.json` description becomes:

```
"description": "Sandboxed devcontainer with Claude Code and OpenAI Codex CLI both preinstalled. Outbound network locked to Anthropic, OpenAI, npm, GitHub, AWS, and VS Code endpoints; DNS scoped to the Docker resolver; SSH and host network blocked. Credentials persist via per-project named Docker volumes."
```

`src/csharp/devcontainer-template.json` description becomes:

```
"description": "Sandboxed devcontainer with Claude Code and OpenAI Codex CLI both preinstalled, plus .NET 9.0 SDK and C# tooling. Outbound network locked to Anthropic, OpenAI, npm, GitHub, AWS, NuGet, and VS Code endpoints; DNS scoped to the Docker resolver; SSH and host network blocked. Credentials persist via per-project named Docker volumes."
```

- [ ] **Step 3: Bump template versions**

In each `devcontainer-template.json`, bump `"version": "1.0.0"` to `"version": "2.0.0"`. This pass introduces the entrypoint change (and may change other behavior); it's a breaking change for v1 consumers.

- [ ] **Step 4: Add the broad-AWS trade-off bullet to README**

Find the "Design notes" section in `README.md`. After the "Build-time template composition" bullet, append:

```markdown
- **AWS allowlist is broad by design.** The firewall allows the full `service==AMAZON` set from `ip-ranges.amazonaws.com`, not a curated subset of services or regions. This means CloudFront-hosted third-party content and arbitrary AWS-hosted services are reachable. Read-only IAM scope on the supplied keys is the primary blast-radius limit; tightening to specific services/regions is possible but adds maintenance, and a stronger policy would require an SNI-aware egress proxy.
```

- [ ] **Step 5: Add a `projectId` warning to README "First-time login" section intro**

Find the heading "### First-time login (per project, per machine)" in `README.md`. Immediately after that heading, before the existing intro paragraph, insert:

```markdown
> **Important:** the `projectId` you supplied at template-apply time is what makes credential volumes per-project. If you accepted the default `CHANGE-ME-PER-PROJECT`, every project on this machine will share the same volumes — fix it before logging in by re-applying the template with a real `projectId`.
```

- [ ] **Step 6: Re-assemble and verify**

```sh
bash scripts/assemble-templates.sh
grep -E 'CHANGE-ME-PER-PROJECT' build/base/devcontainer-template.json build/csharp/devcontainer-template.json
grep -E 'AWS, and VS Code' build/base/devcontainer-template.json
grep -E 'AWS, NuGet' build/csharp/devcontainer-template.json
grep -E '"version": "2.0.0"' build/base/devcontainer-template.json build/csharp/devcontainer-template.json
grep -F 'broad by design' README.md
grep -F 'CHANGE-ME-PER-PROJECT' README.md
```

All greps must produce output; report the final lines.

- [ ] **Step 7: Stop**

Report "Task 6 (projectId default + descriptions + design notes) is ready for review."

---

## Task 7: Version refresh

**Goal:** Bump every pinned version to current stable.

**Files:**
- Modify: `src/_shared/Dockerfile`

- [ ] **Step 1: Look up the latest stable for each pin**

Use the following commands. If a network call fails, fall back to the existing pinned version and note the failure in the report.

**Node LTS major:**
```sh
# Active LTS list from nodejs.org
curl -fsSL https://nodejs.org/dist/index.json | jq -r '.[] | select(.lts != false) | "\(.version) \(.lts)"' | head -20
```
Pick the highest-numbered Active LTS major (currently expected to be Node 24, fall back to 22). For the chosen major, also pick the latest patch — e.g. `node:24.5.0`. The Docker tag format is `node:<major>.<minor>.<patch>`.

**Claude Code:**
```sh
npm view @anthropic-ai/claude-code version
```

**Codex:**
```sh
npm view @openai/codex version
```

**AWS CLI v2:**
```sh
curl -fsSL https://api.github.com/repos/aws/aws-cli/tags?per_page=100 \
  | jq -r '.[].name' | grep -E '^2\.[0-9]+\.[0-9]+$' | sort -V | tail -1
```

**git-delta:**
```sh
curl -fsSL https://api.github.com/repos/dandavison/delta/releases/latest | jq -r '.tag_name'
```
(Strip leading `v` if present — the Dockerfile's ARG is just the bare version like `0.18.2`.)

**zsh-in-docker:**
```sh
curl -fsSL https://api.github.com/repos/deluan/zsh-in-docker/releases/latest | jq -r '.tag_name'
```
(Strip leading `v` if present.)

Record each chosen version in the report.

- [ ] **Step 2: Update `src/_shared/Dockerfile`**

In `src/_shared/Dockerfile`, update each pinned ARG/FROM:

- `FROM node:20.20.2` → `FROM node:<chosen>` (e.g. `FROM node:24.5.0`)
- `ARG CLAUDE_CODE_VERSION=2.1.121` → `ARG CLAUDE_CODE_VERSION=<chosen>`
- `ARG CODEX_VERSION=0.125.0` → `ARG CODEX_VERSION=<chosen>`
- `ARG AWS_CLI_VERSION=2.34.43` → `ARG AWS_CLI_VERSION=<chosen>`
- `ARG GIT_DELTA_VERSION=0.18.2` → `ARG GIT_DELTA_VERSION=<chosen>`
- `ARG ZSH_IN_DOCKER_VERSION=1.2.0` → `ARG ZSH_IN_DOCKER_VERSION=<chosen>`

- [ ] **Step 3: Re-assemble and verify**

```sh
bash scripts/assemble-templates.sh
grep -E 'FROM node|ARG (CLAUDE_CODE|CODEX|AWS_CLI|GIT_DELTA|ZSH_IN_DOCKER)_VERSION' build/base/.devcontainer/Dockerfile build/csharp/.devcontainer/Dockerfile
```

Both Dockerfiles should show identical pinned versions for all six lines.

- [ ] **Step 4: Stop**

Report "Task 7 (version refresh) is ready for review. Versions pinned: node `<x>`, claude-code `<x>`, codex `<x>`, aws-cli `<x>`, git-delta `<x>`, zsh-in-docker `<x>`."

---

## Final verification

After all 7 tasks are complete, run a sanity sweep:

- [ ] **Step 1: Re-assemble cleanly**

```sh
bash scripts/assemble-templates.sh
ls build/base/.devcontainer build/csharp/.devcontainer
```

Both directories must list: `Dockerfile`, `devcontainer.json`, `entrypoint.sh`, `init-firewall.sh`.

- [ ] **Step 2: All JSON parses**

```sh
python3 -c "
import json
for f in [
  'src/base/devcontainer-template.json',
  'src/csharp/devcontainer-template.json',
  'src/base/.devcontainer/devcontainer.json',
  'src/csharp/.devcontainer/devcontainer.json',
  'build/base/devcontainer-template.json',
  'build/csharp/devcontainer-template.json',
  'build/base/.devcontainer/devcontainer.json',
  'build/csharp/.devcontainer/devcontainer.json',
]:
  json.load(open(f))
print('All 8 JSON files parse')
"
```

- [ ] **Step 3: Confirm no `postStartCommand` anywhere**

```sh
grep -r 'postStartCommand\|postCreateCommand' src/ build/ && echo "FOUND" || echo "GONE"
```

Expected: `GONE`.

- [ ] **Step 4: Confirm IPv6 rules and ENTRYPOINT in assembled output**

```sh
grep -c '^ip6tables' build/base/.devcontainer/init-firewall.sh
grep -c '^ip6tables' build/csharp/.devcontainer/init-firewall.sh
grep -E '^ENTRYPOINT' build/base/.devcontainer/Dockerfile build/csharp/.devcontainer/Dockerfile
```

Expected: 7 ip6tables lines per file, ENTRYPOINT line in both Dockerfiles.

- [ ] **Step 5: Final report to user**

Tell the user: "All 7 follow-up tasks complete and ready for review. The cumulative diff includes both the v1 hardening pass (uncommitted from the previous session) and this v2 follow-up. No commits were made — review and commit at your discretion."
