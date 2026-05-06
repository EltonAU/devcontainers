# Devcontainer Sandbox Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **User preference (overrides skill default):** Do NOT run `git commit` at the end of any task. After each task's implementation steps complete, stop and tell the user "Task N is ready for review and commit." The user reviews and commits themselves.

**Goal:** Apply the hardening described in `docs/superpowers/specs/2026-05-06-sandbox-hardening-design.md` to the existing devcontainer templates: per-project credential volumes, firewall hardening, AWS read-only support, shared-source de-duplication, CI validation, and SHA-pinned actions.

**Architecture:** Composition-driven build. A shared `Dockerfile` and `init-firewall.base.sh` live in `src/_shared/`; `scripts/assemble-templates.sh` produces per-template `.devcontainer/` directories under `build/<template>/`. CI validates the assembled output. The release workflow publishes the assembled `build/` (not `src/`) to GHCR.

**Tech Stack:** Bash, jq, devcontainer-templates spec (containers.dev), GitHub Actions, Docker, iptables/ipset.

---

## Pre-execution context

Before starting, the executor should know:

- Repo root: `e:\Professional\MyProjects\devcontainers` on a Windows host. Git Bash, WSL, or any POSIX shell is needed to run shell scripts locally; PowerShell is fine for git/npm/docker. CI runs on `ubuntu-latest`.
- Templates publish to `ghcr.io/eltonau/devcontainers/<template>` via `workflow_dispatch` only — no auto-publish on push.
- Current templates: `src/base` and `src/csharp`. Their `Dockerfile`s are byte-identical; `init-firewall.sh` differs only in the C# template's added NuGet/dotnet domains.
- Approved design doc: `docs/superpowers/specs/2026-05-06-sandbox-hardening-design.md` — read it once before starting.

---

## File structure after this plan completes

```
.github/workflows/
  release.yml          (modified: SHA-pin actions, build from build/ not src/)
  validate.yml         (new: shellcheck, jq, assembly, docker build, firewall smoke test)

scripts/
  assemble-templates.sh (new: composes src/_shared/ + per-template overlays into build/)

src/
  _shared/
    Dockerfile                 (new: moved from src/base, src/csharp)
    init-firewall.base.sh      (new: shared firewall logic, no template-specific domains)
  base/
    devcontainer-template.json (modified: add projectId option)
    .devcontainer/
      devcontainer.json        (modified: parameterised mounts, postStartCommand, AWS env, gh volume)
      init-firewall.fragment   (new: empty — no extra domains for base)
  csharp/
    devcontainer-template.json (modified: add projectId option)
    .devcontainer/
      devcontainer.json        (modified: same as base)
      init-firewall.fragment   (new: NuGet + dotnet domains, one per line)

build/                         (gitignored: assembled output, produced by assemble-templates.sh)
  base/.devcontainer/...
  csharp/.devcontainer/...

docs/
  superpowers/
    specs/2026-05-06-sandbox-hardening-design.md  (already exists)
    plans/2026-05-06-sandbox-hardening.md         (this file)

.gitignore                     (modified: add build/)
README.md                      (modified: rewritten sections per spec)
```

The current `src/base/.devcontainer/Dockerfile`, `src/base/.devcontainer/init-firewall.sh`, `src/csharp/.devcontainer/Dockerfile`, and `src/csharp/.devcontainer/init-firewall.sh` are deleted by Task 1. Their content moves into `src/_shared/` and per-template fragments.

---

## Task 1: Shared source layout and composition script

**Goal:** Move the duplicated `Dockerfile` and `init-firewall.sh` content into `src/_shared/`, introduce per-template fragments, and write the script that assembles `build/<template>/.devcontainer/`.

**Files:**
- Create: `src/_shared/Dockerfile`
- Create: `src/_shared/init-firewall.base.sh`
- Create: `src/base/.devcontainer/init-firewall.fragment`
- Create: `src/csharp/.devcontainer/init-firewall.fragment`
- Create: `scripts/assemble-templates.sh`
- Modify: `.gitignore`
- Delete: `src/base/.devcontainer/Dockerfile`
- Delete: `src/base/.devcontainer/init-firewall.sh`
- Delete: `src/csharp/.devcontainer/Dockerfile`
- Delete: `src/csharp/.devcontainer/init-firewall.sh`

This task does NOT change runtime behavior. After it completes, running `scripts/assemble-templates.sh` should produce a `build/` tree whose contents are byte-equivalent to the current `src/<template>/.devcontainer/` (modulo the one new firewall change in Task 3 — but in this task we keep the firewall script semantically identical to today's).

- [ ] **Step 1: Create `src/_shared/Dockerfile`**

Copy the current contents of `src/base/.devcontainer/Dockerfile` verbatim into `src/_shared/Dockerfile`. (The csharp Dockerfile is byte-identical — confirm with `diff src/base/.devcontainer/Dockerfile src/csharp/.devcontainer/Dockerfile`.) No content changes in this step.

- [ ] **Step 2: Create `src/_shared/init-firewall.base.sh`**

Copy the current contents of `src/base/.devcontainer/init-firewall.sh` into `src/_shared/init-firewall.base.sh`, with one structural change: replace the inline domain block

```bash
for domain in \
    "registry.npmjs.org" \
    "api.anthropic.com" \
    ...
    "update.code.visualstudio.com"; do
```

with a sentinel line that the assembler will replace:

```bash
for domain in \
    "registry.npmjs.org" \
    "api.anthropic.com" \
    "api.openai.com" \
    "auth.openai.com" \
    "chatgpt.com" \
    "sentry.io" \
    "statsig.anthropic.com" \
    "statsig.com" \
    "marketplace.visualstudio.com" \
    "vscode.blob.core.windows.net" \
    "update.code.visualstudio.com" \
    # __TEMPLATE_DOMAINS__
    ; do
```

The `# __TEMPLATE_DOMAINS__` line is the sentinel. Bash treats `#` after `\` as a continuation oddity — to avoid that, use a more robust marker pattern: keep the base list closed (`"update.code.visualstudio.com"` followed by `;` `do`) and add a second `for` loop in a separate sentinel block. Concretely, replace the block with:

```bash
for domain in \
    "registry.npmjs.org" \
    "api.anthropic.com" \
    "api.openai.com" \
    "auth.openai.com" \
    "chatgpt.com" \
    "sentry.io" \
    "statsig.anthropic.com" \
    "statsig.com" \
    "marketplace.visualstudio.com" \
    "vscode.blob.core.windows.net" \
    "update.code.visualstudio.com" \
    ; do
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        echo "ERROR: Failed to resolve $domain"
        exit 1
    fi

    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "ERROR: Invalid IP from DNS for $domain: $ip"
            exit 1
        fi
        echo "Adding $ip for $domain"
        ipset add allowed-domains "$ip"
    done < <(echo "$ips")
done

# __TEMPLATE_DOMAINS_BLOCK_START__
# __TEMPLATE_DOMAINS_BLOCK_END__
```

The assembler replaces the lines between `__TEMPLATE_DOMAINS_BLOCK_START__` and `__TEMPLATE_DOMAINS_BLOCK_END__` with a second resolve-and-add loop using the per-template domains. Keep everything else (host-network, default DROP, verification at bottom) byte-identical to today's script. Mark the file executable: `chmod +x src/_shared/init-firewall.base.sh`.

- [ ] **Step 3: Create per-template fragments**

`src/base/.devcontainer/init-firewall.fragment` — empty file (no extra domains for base):

```
```

`src/csharp/.devcontainer/init-firewall.fragment` — one domain per line, no quotes, no trailing whitespace:

```
api.nuget.org
www.nuget.org
dist.nuget.org
dotnetcli.azureedge.net
dotnetbuilds.azureedge.net
```

- [ ] **Step 4: Write `scripts/assemble-templates.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Assembles per-template .devcontainer directories under build/<template>/
# from src/_shared/ + src/<template>/ overlays.
#
# Usage: scripts/assemble-templates.sh
# Output: build/<template>/{devcontainer-template.json,.devcontainer/...}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARED_DIR="$REPO_ROOT/src/_shared"
SRC_DIR="$REPO_ROOT/src"
BUILD_DIR="$REPO_ROOT/build"

if [ ! -d "$SHARED_DIR" ]; then
    echo "ERROR: $SHARED_DIR not found" >&2
    exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Discover templates: every src/<name>/ that has devcontainer-template.json
# and is not _shared.
for template_dir in "$SRC_DIR"/*/; do
    template_name="$(basename "$template_dir")"
    [ "$template_name" = "_shared" ] && continue
    [ -f "$template_dir/devcontainer-template.json" ] || continue

    echo "Assembling $template_name..."

    out="$BUILD_DIR/$template_name"
    mkdir -p "$out/.devcontainer"

    # 1. Copy template-template.json (the OCI template metadata) verbatim.
    cp "$template_dir/devcontainer-template.json" "$out/devcontainer-template.json"

    # 2. Copy devcontainer.json verbatim.
    cp "$template_dir/.devcontainer/devcontainer.json" "$out/.devcontainer/devcontainer.json"

    # 3. Copy shared Dockerfile.
    cp "$SHARED_DIR/Dockerfile" "$out/.devcontainer/Dockerfile"

    # 4. Compose init-firewall.sh from base + fragment.
    fragment="$template_dir/.devcontainer/init-firewall.fragment"
    if [ ! -f "$fragment" ]; then
        echo "ERROR: $fragment not found" >&2
        exit 1
    fi

    # Build the per-template domain block. If fragment is empty, block is empty.
    domain_block=""
    if [ -s "$fragment" ]; then
        domain_block=$'for domain in \\\n'
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            domain_block+=$'    "'"$line"$'" \\\n'
        done < "$fragment"
        domain_block+=$'    ; do\n'
        domain_block+=$'    echo "Resolving $domain..."\n'
        domain_block+=$'    ips=$(dig +noall +answer A "$domain" | awk \'$4 == "A" {print $5}\')\n'
        domain_block+=$'    if [ -z "$ips" ]; then\n'
        domain_block+=$'        echo "ERROR: Failed to resolve $domain"\n'
        domain_block+=$'        exit 1\n'
        domain_block+=$'    fi\n'
        domain_block+=$'    while read -r ip; do\n'
        domain_block+=$'        if [[ ! "$ip" =~ ^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}$ ]]; then\n'
        domain_block+=$'            echo "ERROR: Invalid IP from DNS for $domain: $ip"\n'
        domain_block+=$'            exit 1\n'
        domain_block+=$'        fi\n'
        domain_block+=$'        echo "Adding $ip for $domain"\n'
        domain_block+=$'        ipset add allowed-domains "$ip"\n'
        domain_block+=$'    done < <(echo "$ips")\n'
        domain_block+=$'done\n'
    fi

    # Substitute the block between sentinels in init-firewall.base.sh.
    awk -v block="$domain_block" '
        /__TEMPLATE_DOMAINS_BLOCK_START__/ {
            print "# __TEMPLATE_DOMAINS_BLOCK_START__"
            printf "%s", block
            in_block = 1
            next
        }
        /__TEMPLATE_DOMAINS_BLOCK_END__/ {
            print "# __TEMPLATE_DOMAINS_BLOCK_END__"
            in_block = 0
            next
        }
        !in_block { print }
    ' "$SHARED_DIR/init-firewall.base.sh" > "$out/.devcontainer/init-firewall.sh"

    chmod +x "$out/.devcontainer/init-firewall.sh"

    echo "  -> $out"
done

echo "Done."
```

Mark executable: `chmod +x scripts/assemble-templates.sh`.

- [ ] **Step 5: Add `build/` to `.gitignore`**

Append to `.gitignore`:

```
build/
```

- [ ] **Step 6: Run the assembler and verify byte-equivalence with current templates**

```sh
bash scripts/assemble-templates.sh
diff -r src/base/.devcontainer build/base/.devcontainer
diff -r src/csharp/.devcontainer build/csharp/.devcontainer
```

Expected: both `diff` calls produce no output (the assembled output is byte-equivalent to the current `.devcontainer` directories). If diffs appear, fix the assembler or the base script until they vanish. **This is the test for Task 1.**

- [ ] **Step 7: Delete the now-redundant per-template files**

```sh
rm src/base/.devcontainer/Dockerfile src/base/.devcontainer/init-firewall.sh
rm src/csharp/.devcontainer/Dockerfile src/csharp/.devcontainer/init-firewall.sh
```

Run the assembler again to confirm it still produces correct output (now sourcing only from `_shared/` and the fragments).

- [ ] **Step 8: Update `.github/workflows/release.yml`**

The current `release.yml` runs `devcontainers/action@v1` with `base-path-to-templates: ./src`. That won't work after Task 1 because `src/_shared` isn't a valid template. Change it to assemble first, then publish from `build/`:

```yaml
name: Release Templates

on:
  workflow_dispatch:

jobs:
  publish:
    name: Publish templates to GHCR
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - name: Checkout
        uses: actions/checkout@v4  # SHA pin in Task 8

      - name: Assemble templates
        run: bash scripts/assemble-templates.sh

      - name: Publish templates
        uses: devcontainers/action@v1  # SHA pin in Task 8
        with:
          publish-templates: "true"
          base-path-to-templates: "./build"
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

- [ ] **Step 9: Stop for review**

Tell the user: "Task 1 (shared source layout and composition) is ready for review and commit. The assembled output under `build/` is byte-equivalent to the previous `src/<template>/.devcontainer/` content."

---

## Task 2: CI validation workflow

**Goal:** Add a `validate.yml` workflow that runs on push/PR and catches regressions in the assembled templates before they ship.

**Files:**
- Create: `.github/workflows/validate.yml`

- [ ] **Step 1: Write `.github/workflows/validate.yml`**

```yaml
name: Validate Templates

on:
  push:
    branches: [master]
  pull_request:

jobs:
  validate:
    name: Validate
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - name: Checkout
        uses: actions/checkout@v4  # SHA pin in Task 8

      - name: Validate JSON files
        run: |
          set -euo pipefail
          fail=0
          while IFS= read -r f; do
            if ! jq -e . "$f" >/dev/null 2>&1; then
              echo "INVALID: $f"
              fail=1
            fi
          done < <(find src -name '*.json')
          [ $fail -eq 0 ]

      - name: Shellcheck
        run: |
          sudo apt-get update -qq && sudo apt-get install -y -qq shellcheck
          shellcheck src/_shared/init-firewall.base.sh scripts/assemble-templates.sh

      - name: Assemble templates
        run: bash scripts/assemble-templates.sh

      - name: Shellcheck assembled output
        run: |
          for f in build/*/.devcontainer/init-firewall.sh; do
            shellcheck "$f"
          done

      - name: Docker build (each template)
        run: |
          set -euo pipefail
          for d in build/*/.devcontainer; do
            template=$(basename "$(dirname "$d")")
            echo "Building $template..."
            docker build -t "devcontainer-test:$template" "$d"
          done

      - name: Firewall smoke test (base)
        run: |
          set -euo pipefail
          docker run --rm \
            --cap-add=NET_ADMIN --cap-add=NET_RAW \
            --entrypoint /bin/bash \
            devcontainer-test:base \
            -c '
              sudo /usr/local/bin/init-firewall.sh
              # Allowed
              curl --connect-timeout 5 -fsS https://api.github.com/zen >/dev/null
              # Blocked
              if curl --connect-timeout 5 -fsS https://example.com >/dev/null 2>&1; then
                echo "FAIL: example.com reachable"; exit 1
              fi
              # DNS exfil channel must be blocked (only Docker resolver allowed)
              if dig +time=2 +tries=1 @8.8.8.8 google.com >/dev/null 2>&1; then
                echo "FAIL: DNS to 8.8.8.8 succeeded"; exit 1
              fi
              echo "Smoke test passed"
            '
```

Note: the DNS-to-8.8.8.8 check will only pass after Task 3 (DNS lockdown). Until then, expect that smoke test step to fail. That's intentional — the workflow lands first so subsequent tasks are guarded by it.

- [ ] **Step 2: Run validate.yml steps locally to verify the non-firewall checks pass**

```sh
bash scripts/assemble-templates.sh
shellcheck src/_shared/init-firewall.base.sh scripts/assemble-templates.sh
shellcheck build/*/.devcontainer/init-firewall.sh
for d in build/*/.devcontainer; do
  template=$(basename "$(dirname "$d")")
  docker build -t "devcontainer-test:$template" "$d"
done
```

Expected: shellcheck passes (or output any issues, fix them inline), all docker builds succeed.

- [ ] **Step 3: Commit checkpoint — stop for review**

Tell the user: "Task 2 (validate.yml) is ready for review and commit. The DNS-block smoke step will fail until Task 3 lands; that's expected."

---

## Task 3: Firewall hardening

**Goal:** Tighten DNS to Docker's resolver, drop outbound SSH, drop the host-network hole, and move firewall application to `postStartCommand`.

**Files:**
- Modify: `src/_shared/init-firewall.base.sh`
- Modify: `src/base/.devcontainer/devcontainer.json`
- Modify: `src/csharp/.devcontainer/devcontainer.json`

- [ ] **Step 1: Tighten DNS rules in `init-firewall.base.sh`**

Find these lines:

```bash
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
```

Replace with:

```bash
iptables -A OUTPUT -p udp --dport 53 -d 127.0.0.11 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -s 127.0.0.11 -j ACCEPT
```

- [ ] **Step 2: Remove SSH allow rules in `init-firewall.base.sh`**

Find and delete these lines:

```bash
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
```

- [ ] **Step 3: Remove host-network hole in `init-firewall.base.sh`**

Find and delete this block:

```bash
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"

iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT
```

- [ ] **Step 4: Move firewall to `postStartCommand` in both `devcontainer.json` files**

In `src/base/.devcontainer/devcontainer.json` and `src/csharp/.devcontainer/devcontainer.json`, replace:

```jsonc
"postCreateCommand": "sudo /usr/local/bin/init-firewall.sh",
```

with:

```jsonc
"postStartCommand": "sudo /usr/local/bin/init-firewall.sh",
```

- [ ] **Step 5: Re-assemble and run the smoke test locally**

```sh
bash scripts/assemble-templates.sh
docker build -t devcontainer-test:base build/base/.devcontainer
docker run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW \
  --entrypoint /bin/bash devcontainer-test:base \
  -c 'sudo /usr/local/bin/init-firewall.sh && \
      curl --connect-timeout 5 -fsS https://api.github.com/zen >/dev/null && \
      ! curl --connect-timeout 5 -fsS https://example.com >/dev/null 2>&1 && \
      ! dig +time=2 +tries=1 @8.8.8.8 google.com >/dev/null 2>&1 && \
      echo PASSED'
```

Expected output: `PASSED`. If the script aborts at the `! dig` step, DNS lockdown is correct. If `! curl example.com` fails, the firewall isn't blocking. If `curl api.github.com` fails, GitHub allowlist isn't working.

- [ ] **Step 6: Stop for review**

Tell the user: "Task 3 (firewall hardening) is ready for review and commit. Local smoke test passes; CI validate.yml's DNS-block step now passes too."

---

## Task 4: Per-project credential volumes via template option

**Goal:** Add a `projectId` template option and parameterise all volume mount names with `${templateOption:projectId}`. Also rename existing volumes (Claude/Codex/bashhistory) to the per-project pattern.

**Files:**
- Modify: `src/base/devcontainer-template.json`
- Modify: `src/base/.devcontainer/devcontainer.json`
- Modify: `src/csharp/devcontainer-template.json`
- Modify: `src/csharp/.devcontainer/devcontainer.json`

- [ ] **Step 1: Add `projectId` option to `src/base/devcontainer-template.json`**

Replace the current `"options": {}` with:

```jsonc
"options": {
  "projectId": {
    "type": "string",
    "description": "Unique identifier used in Docker volume names so credentials don't collide across projects. Lowercase letters, digits, hyphens. Example: 'my-app'.",
    "default": "myproject"
  }
}
```

- [ ] **Step 2: Add the same option to `src/csharp/devcontainer-template.json`**

Same JSON block as Step 1, in the csharp template's metadata file.

- [ ] **Step 3: Parameterise mounts in `src/base/.devcontainer/devcontainer.json`**

Replace the current `"mounts": [...]` block with:

```jsonc
"mounts": [
  "source=claude-credentials-${templateOption:projectId},target=/home/node/.claude,type=volume",
  "source=codex-credentials-${templateOption:projectId},target=/home/node/.codex,type=volume",
  "source=bashhistory-${templateOption:projectId},target=/commandhistory,type=volume"
],
```

(AWS and gh volumes are added in Task 7.)

- [ ] **Step 4: Same change in `src/csharp/.devcontainer/devcontainer.json`**

Identical mounts block to Step 3.

- [ ] **Step 5: Validate the rendered output via the devcontainers CLI**

```sh
bash scripts/assemble-templates.sh
npx -y @devcontainers/cli@latest templates apply \
  --template-id ./build/base \
  --workspace-folder /tmp/dctest \
  --template-args '{"projectId":"smoke"}' || true
grep -F 'claude-credentials-smoke' /tmp/dctest/.devcontainer/devcontainer.json
```

Expected: the rendered devcontainer.json contains literal `claude-credentials-smoke` (not the `${templateOption:...}` placeholder). If grep returns no match, substitution didn't happen — verify the template option syntax.

- [ ] **Step 6: Stop for review**

Tell the user: "Task 4 (per-project volumes) is ready for review and commit. Substitution verified end-to-end via the devcontainers CLI."

---

## Task 5: AWS CLI install (and explicit curl/wget pinning)

**Goal:** Install the AWS CLI v2 in the shared Dockerfile, and make `curl`/`wget` explicit dependencies (they're inherited from the `node:20.20.2` base today; pinning makes the dependency intentional).

**Files:**
- Modify: `src/_shared/Dockerfile`

- [ ] **Step 0: Make `curl` and `wget` explicit in the apt install list**

Find the apt-get block in `src/_shared/Dockerfile`:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
  less \
  git \
  procps \
  sudo \
  fzf \
  zsh \
  man-db \
  unzip \
  gnupg2 \
  gh \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  jq \
  nano \
  vim \
  && apt-get clean && rm -rf /var/lib/apt/lists/*
```

Add `curl` and `wget` to the list (alphabetical-ish placement):

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
  less \
  git \
  procps \
  sudo \
  fzf \
  zsh \
  man-db \
  unzip \
  gnupg2 \
  gh \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  jq \
  nano \
  vim \
  curl \
  wget \
  && apt-get clean && rm -rf /var/lib/apt/lists/*
```

- [ ] **Step 1: Look up the latest stable AWS CLI v2 version**

Visit https://github.com/aws/aws-cli/blob/v2/CHANGELOG.rst (or run `curl -sL https://api.github.com/repos/aws/aws-cli/releases | jq -r '[.[] | select(.tag_name | startswith("2."))][0].tag_name'`) and pick the most recent `2.x.y` tag. Note the chosen version.

- [ ] **Step 2: Add AWS CLI install to `src/_shared/Dockerfile`**

Insert after the `git-delta` install block (before `USER node`):

```dockerfile
ARG AWS_CLI_VERSION=2.X.Y
RUN ARCH_RAW=$(dpkg --print-architecture) && \
  case "$ARCH_RAW" in \
    amd64) AWS_ARCH=x86_64 ;; \
    arm64) AWS_ARCH=aarch64 ;; \
    *) echo "Unsupported arch: $ARCH_RAW" >&2; exit 1 ;; \
  esac && \
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}-${AWS_CLI_VERSION}.zip" -o /tmp/awscliv2.zip && \
  unzip -q /tmp/awscliv2.zip -d /tmp && \
  /tmp/aws/install && \
  rm -rf /tmp/aws /tmp/awscliv2.zip
```

Replace `2.X.Y` with the version chosen in Step 1.

Note: `curl` and `unzip` are already in the apt list. The install pulls from `awscli.amazonaws.com` at build time, before the firewall exists, so no allowlist conflict.

- [ ] **Step 3: Re-assemble, build, verify**

```sh
bash scripts/assemble-templates.sh
docker build -t devcontainer-test:base build/base/.devcontainer
docker run --rm --entrypoint aws devcontainer-test:base --version
```

Expected: prints `aws-cli/2.X.Y ...`.

- [ ] **Step 4: Stop for review**

Tell the user: "Task 5 (AWS CLI install) is ready for review and commit."

---

## Task 6: AWS endpoints in firewall + verification

**Goal:** Allow outbound traffic to AWS services by fetching `ip-ranges.json` at firewall init and adding the `AMAZON` service prefixes to the allowed-domains ipset. Add `sts.amazonaws.com` to the must-succeed verification.

**Files:**
- Modify: `src/_shared/init-firewall.base.sh`

- [ ] **Step 1: Add AWS allowlist fetch to `init-firewall.base.sh`**

Insert after the GitHub IPs block (after the `done < <(echo "$gh_ranges" | jq -r ... | aggregate -q)` line) and before the per-template domain resolution:

```bash
echo "Fetching AWS IP ranges..."
aws_ranges=$(curl -fsSL https://ip-ranges.amazonaws.com/ip-ranges.json)
if [ -z "$aws_ranges" ]; then
    echo "ERROR: Failed to fetch AWS IP ranges"
    exit 1
fi
if ! echo "$aws_ranges" | jq -e '.prefixes' >/dev/null; then
    echo "ERROR: AWS ip-ranges response missing .prefixes"
    exit 1
fi
echo "Processing AWS IPs..."
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid CIDR from AWS ip-ranges: $cidr"
        exit 1
    fi
    ipset add allowed-domains "$cidr"
done < <(echo "$aws_ranges" | jq -r '.prefixes[] | select(.service=="AMAZON") | .ip_prefix' | aggregate -q)
```

- [ ] **Step 2: Add `sts.amazonaws.com` to verification**

Find the verification block at the bottom of `init-firewall.base.sh`:

```bash
if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
fi
```

Append, immediately after, a matching check for STS:

```bash
if ! curl --connect-timeout 5 https://sts.amazonaws.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://sts.amazonaws.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://sts.amazonaws.com as expected"
fi
```

- [ ] **Step 3: Re-assemble and smoke test**

```sh
bash scripts/assemble-templates.sh
docker build -t devcontainer-test:base build/base/.devcontainer
docker run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW \
  --entrypoint /bin/bash devcontainer-test:base \
  -c 'sudo /usr/local/bin/init-firewall.sh && \
      curl --connect-timeout 5 -fsS https://sts.amazonaws.com >/dev/null && \
      curl --connect-timeout 5 -fsS https://api.github.com/zen >/dev/null && \
      ! curl --connect-timeout 5 -fsS https://example.com >/dev/null 2>&1 && \
      echo PASSED'
```

Expected: `PASSED`. The firewall init log should also show `Firewall verification passed - able to reach https://sts.amazonaws.com`.

- [ ] **Step 4: Add STS check to validate.yml smoke test**

In `.github/workflows/validate.yml`, in the "Firewall smoke test (base)" step, add this line after the `curl --connect-timeout 5 -fsS https://api.github.com/zen >/dev/null` line:

```bash
              curl --connect-timeout 5 -fsS https://sts.amazonaws.com >/dev/null
```

- [ ] **Step 5: Stop for review**

Tell the user: "Task 6 (AWS firewall allowlist) is ready for review and commit."

---

## Task 7: AWS profile env, AWS volume, gh volume

**Goal:** Set `AWS_PROFILE=readonly` globally, mount the per-project AWS credentials volume, and mount the per-project gh CLI credentials volume.

**Files:**
- Modify: `src/base/.devcontainer/devcontainer.json`
- Modify: `src/csharp/.devcontainer/devcontainer.json`

- [ ] **Step 1: Update `src/base/.devcontainer/devcontainer.json`**

Add a `containerEnv` block (before or after `runArgs` is fine):

```jsonc
"containerEnv": {
  "AWS_PROFILE": "readonly"
},
```

Extend `mounts` to include the AWS and gh volumes:

```jsonc
"mounts": [
  "source=claude-credentials-${templateOption:projectId},target=/home/node/.claude,type=volume",
  "source=codex-credentials-${templateOption:projectId},target=/home/node/.codex,type=volume",
  "source=aws-credentials-${templateOption:projectId},target=/home/node/.aws,type=volume",
  "source=gh-credentials-${templateOption:projectId},target=/home/node/.config/gh,type=volume",
  "source=bashhistory-${templateOption:projectId},target=/commandhistory,type=volume"
],
```

- [ ] **Step 2: Same changes in `src/csharp/.devcontainer/devcontainer.json`**

Identical `containerEnv` and `mounts` blocks.

- [ ] **Step 3: Pre-create `.aws` and `.config/gh` directories in the shared Dockerfile**

Find the existing `mkdir -p` line in `src/_shared/Dockerfile`:

```dockerfile
RUN mkdir -p /workspace /home/node/.claude /home/node/.codex && \
  chown -R node:node /workspace /home/node/.claude /home/node/.codex
```

Replace with:

```dockerfile
RUN mkdir -p /workspace \
      /home/node/.claude \
      /home/node/.codex \
      /home/node/.aws \
      /home/node/.config/gh && \
  chown -R node:node /workspace /home/node/.claude /home/node/.codex /home/node/.aws /home/node/.config
```

This ensures the volumes pick up correct ownership on first mount.

- [ ] **Step 4: Re-assemble, build, verify**

```sh
bash scripts/assemble-templates.sh
docker build -t devcontainer-test:base build/base/.devcontainer
docker run --rm --entrypoint env devcontainer-test:base | grep AWS_PROFILE
```

Expected: `AWS_PROFILE=readonly`.

Then verify substitution by re-running the templates apply test from Task 4 Step 5 with the new mounts list:

```sh
rm -rf /tmp/dctest
npx -y @devcontainers/cli@latest templates apply \
  --template-id ./build/base \
  --workspace-folder /tmp/dctest \
  --template-args '{"projectId":"smoke"}'
grep -F 'aws-credentials-smoke' /tmp/dctest/.devcontainer/devcontainer.json
grep -F 'gh-credentials-smoke' /tmp/dctest/.devcontainer/devcontainer.json
```

Expected: both grep calls match a line.

- [ ] **Step 5: Stop for review**

Tell the user: "Task 7 (AWS profile, AWS volume, gh volume) is ready for review and commit."

---

## Task 8: SHA-pin GitHub Actions

**Goal:** Replace tag refs in both workflows with commit SHAs, with version comments alongside.

**Files:**
- Modify: `.github/workflows/release.yml`
- Modify: `.github/workflows/validate.yml`

- [ ] **Step 1: Look up SHAs for each pinned action**

For `actions/checkout@v4`:

```sh
gh api repos/actions/checkout/git/refs/tags/v4 --jq '.object.sha'
```

If the tag points at a tag object (annotated tag), follow it:

```sh
SHA=$(gh api repos/actions/checkout/git/refs/tags/v4 --jq '.object.sha')
gh api repos/actions/checkout/git/tags/$SHA --jq '.object.sha' 2>/dev/null || echo $SHA
```

Record the resolved commit SHA and the human-readable version (e.g., `v4.2.2`).

For `devcontainers/action@v1`:

```sh
SHA=$(gh api repos/devcontainers/action/git/refs/tags/v1 --jq '.object.sha')
gh api repos/devcontainers/action/git/tags/$SHA --jq '.object.sha' 2>/dev/null || echo $SHA
```

Record the SHA and version.

- [ ] **Step 2: Update `.github/workflows/release.yml`**

Replace:

```yaml
      - name: Checkout
        uses: actions/checkout@v4
```

with (substituting the resolved SHA and version):

```yaml
      - name: Checkout
        uses: actions/checkout@<SHA-FROM-STEP-1>  # v4.2.2
```

Replace:

```yaml
      - name: Publish templates
        uses: devcontainers/action@v1
```

with:

```yaml
      - name: Publish templates
        uses: devcontainers/action@<SHA-FROM-STEP-1>  # v1.x.x
```

- [ ] **Step 3: Update `.github/workflows/validate.yml`**

Apply the same SHA pin to the `actions/checkout` step. (`devcontainers/action` is not used in validate.yml.)

- [ ] **Step 4: Stop for review**

Tell the user: "Task 8 (SHA-pinned actions) is ready for review and commit."

---

## Task 9: README rewrite

**Goal:** Update the README to reflect the new templates: per-project setup via `devcontainer templates apply`, the four credential stores, the agent guidance snippet, the volume cleanup note, and removal of any GitHub-Pages mentions.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace the "Usage" section**

Replace the current "Usage" section (numbered steps for VS Code's command palette) with:

```markdown
## Usage

### Per-project setup (run once per new project)

The cleanest, IDE-agnostic flow uses the [devcontainers CLI](https://github.com/devcontainers/cli):

```sh
npm install -g @devcontainers/cli  # one-time, host-side

cd /path/to/your/project
devcontainer templates apply \
  --template-id ghcr.io/eltonau/devcontainers/csharp \
  --workspace-folder . \
  --template-args '{"projectId":"my-app"}'
```

Replace `csharp` with whichever template you want, and pick a unique `projectId` per project (lowercase, hyphens; this becomes part of the Docker volume names so credentials don't collide across projects). Commit the resulting `.devcontainer/` directory.

Then open the project in **any IDE** that supports devcontainers — VS Code, Rider, IntelliJ, etc. — and choose "Reopen in container". Once applied, no IDE-specific tooling is needed.

**VS Code shortcut:** if you only use VS Code, you can also run **Cmd Palette → "Dev Containers: Add Dev Container Configuration Files…"** which prompts for the same `projectId` interactively.
```

- [ ] **Step 2: Replace the "First-time login" section**

Replace with:

```markdown
### First-time login (per project, per machine)

The first container you open for a project on a machine has empty credential volumes. Inside the container terminal, set up whichever you'll use:

**Claude Code:**
```sh
claude
# Run /login at the prompt; complete OAuth flow.
```

**OpenAI Codex CLI:**
```sh
codex
# Choose "Sign in with ChatGPT" or supply OPENAI_API_KEY.
```

**AWS (read-only static keys):**

Edit `~/.aws/credentials`:
```ini
[readonly]
aws_access_key_id = AKIA...
aws_secret_access_key = ...
region = ap-southeast-2
```

Or run `aws configure --profile readonly` interactively. The `AWS_PROFILE=readonly` env var is set globally in the container, so every `aws` command picks it up automatically. Read-only-ness is enforced server-side by the IAM policy attached to the user (e.g., the AWS-managed `ReadOnlyAccess` policy).

**GitHub (read-only PAT):**
```sh
gh auth login
# Paste a fine-grained PAT scoped to read-only on the repos you care about.
```

You'll re-do this once per project per machine. Within a project, the credentials persist across container restarts, host reboots, and weeks of inactivity — they only disappear if you `docker volume rm` them explicitly.
```

- [ ] **Step 3: Add a "Volume cleanup" section**

Insert after the "First-time login" section:

```markdown
### Cleaning up retired projects

Per-project volumes are not garbage-collected automatically. When you're done with a project for good, remove its volumes:

```sh
docker volume ls --format '{{.Name}}' | grep -E -- '-<projectId>$' | xargs -r docker volume rm
```

Replace `<projectId>` with the `projectId` you supplied at template-apply time.
```

- [ ] **Step 4: Add an "Agent guidance" section**

Insert after the "Templates" section (or before "What gets blocked", wherever fits the flow):

```markdown
## Agent guidance

Drop the following snippet into each project's `CLAUDE.md` (or `AGENTS.md` for Codex) so the agent knows the rules of the sandbox:

> **AWS access** is via the `readonly` profile (`AWS_PROFILE=readonly`) and is enforced as read-only by IAM policy — do not attempt write actions, they will fail.
>
> **Git and GitHub access** are read-only. You may `git fetch` / `git pull` / `git log` / `git diff` / `gh issue view` / `gh pr view`, but do not run `git push`, `gh pr create`, `gh issue create`, or any other write operation. They will fail.
>
> **Do not commit unless explicitly asked.** Even local commits (no network needed) should be left to the user — make the file changes and stop. The user reviews and commits themselves. If a workflow you're following says "commit X," skip that step and tell the user the change is ready to commit.
```

- [ ] **Step 5: Update the "Adding a new language template" section**

Replace step 1's `cp src/csharp src/<lang>` instructions with the new layout:

```markdown
## Adding a new language template

1. Copy `src/csharp/` to `src/<lang>/`.
2. Edit `<lang>/devcontainer-template.json` (id, name, description, keywords; start at `version: 1.0.0`; keep the `projectId` option).
3. Edit `<lang>/.devcontainer/devcontainer.json` (replace `dotnet:2` Feature, swap VS Code extensions).
4. Edit `<lang>/.devcontainer/init-firewall.fragment` (replace NuGet/dotnet domains with the new language's package registry domains, one per line).
5. Run `bash scripts/assemble-templates.sh` and verify `build/<lang>/.devcontainer/` looks right.
6. Commit, push, then trigger the Release workflow manually (see [Releasing](#releasing)).
```

- [ ] **Step 6: Add a "Design notes" section near the bottom**

Insert before the "License" section:

```markdown
## Design notes

This sandbox makes a few deliberate choices worth surfacing:

- **Per-project credential isolation, persistent across sessions.** Each project gets its own named Docker volumes for Claude, Codex, AWS, and gh credentials, parameterised by the `projectId` you supply at template-apply time. Volumes survive container recreation and host reboots — you log in once per project per machine, not once per session.
- **Egress allowlist via iptables + ipset.** DNS is restricted to Docker's embedded resolver (no exfiltration via arbitrary DNS servers). Outbound SSH is blocked. The host-network range is not allowed. AWS service ranges are fetched at firewall init from `ip-ranges.amazonaws.com` and added to the allowlist. The full agent flow (WebFetch, WebSearch, API calls) routes through Anthropic/OpenAI, both already allowlisted.
- **Read-only AWS and GitHub by IAM/PAT scope.** Read-only-ness is enforced server-side, not by the container. Static AWS keys are paired with the AWS-managed `ReadOnlyAccess` policy. GitHub access uses a fine-grained read-only PAT.
- **Build-time template composition.** Shared content (`Dockerfile`, firewall base script) lives in `src/_shared/`; each template overlays a per-template firewall fragment. The release workflow assembles `build/<template>/` and publishes from there. This keeps a single source of truth for the parts every template shares.
```

- [ ] **Step 7: Remove or correct any GitHub Pages mentions**

Search the README for any text suggesting GitHub Pages or a downloaded bootstrap script:

```sh
grep -ni 'pages\|bootstrap script' README.md
```

Replace any such wording with descriptions of the GHCR + `devcontainer templates apply` flow. If no matches, no action.

- [ ] **Step 8: Stop for review**

Tell the user: "Task 9 (README rewrite) is ready for review and commit. The full hardening plan is now implemented."

---

## Final verification

After all 9 tasks are committed:

- [ ] **Step 1: Run validate.yml steps end-to-end locally**

```sh
bash scripts/assemble-templates.sh
shellcheck src/_shared/init-firewall.base.sh scripts/assemble-templates.sh build/*/.devcontainer/init-firewall.sh
for d in build/*/.devcontainer; do
  template=$(basename "$(dirname "$d")")
  docker build -t "devcontainer-test:$template" "$d"
done
docker run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW \
  --entrypoint /bin/bash devcontainer-test:base \
  -c 'sudo /usr/local/bin/init-firewall.sh && \
      curl --connect-timeout 5 -fsS https://api.github.com/zen >/dev/null && \
      curl --connect-timeout 5 -fsS https://sts.amazonaws.com >/dev/null && \
      ! curl --connect-timeout 5 -fsS https://example.com >/dev/null 2>&1 && \
      ! dig +time=2 +tries=1 @8.8.8.8 google.com >/dev/null 2>&1 && \
      echo "ALL CHECKS PASSED"'
```

Expected: `ALL CHECKS PASSED`.

- [ ] **Step 2: Push to a branch and verify CI passes**

Verify the validate.yml workflow runs to green on a PR or push.

- [ ] **Step 3: Bump versions and dispatch the release workflow**

Bump `version` in `src/base/devcontainer-template.json` and `src/csharp/devcontainer-template.json` to a major version (the mount-name change is a breaking change for consumers pinned to `:1.x`). Per the README's existing convention: `1.0.0 → 2.0.0`.

Then GitHub → Actions → Release Templates → Run workflow. After ~30s, verify new tags appear at https://github.com/EltonAU?tab=packages.

- [ ] **Step 4: Smoke-test the published template**

In a scratch directory:

```sh
mkdir -p /tmp/published-smoke && cd /tmp/published-smoke
devcontainer templates apply \
  --template-id ghcr.io/eltonau/devcontainers/base \
  --workspace-folder . \
  --template-args '{"projectId":"published-smoke"}'
grep -F 'claude-credentials-published-smoke' .devcontainer/devcontainer.json
```

Expected: the rendered `devcontainer.json` has the literal volume names. The hardened sandbox is live.
