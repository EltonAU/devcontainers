# Allowlist Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

> **User preference (overrides skill default):** Do NOT run `git commit`. Just edit files. The user reviews and commits.

**Goal:** Apply `docs/superpowers/specs/2026-05-07-allowlist-cleanup-design.md` — remove dead/telemetry domains, replace deprecated .NET CDN with the current endpoint, restore strict fail-on-resolve, reset template versions to `0.1.0`.

**Architecture:** Same — `src/_shared/` is source of truth, `scripts/assemble-templates.sh` composes `build/<template>/`. No structural changes; just edits.

**Tech Stack:** Bash, jq.

---

## Pre-execution context

- Repo root: `e:\Professional\MyProjects\devcontainers` (Windows host).
- Both v1 and v2 hardening passes are committed and pushed already.
- Local Docker is available for verification.
- Current working tree is clean of uncommitted changes (state at the start of this pass).

---

## Task 1: Cleanup edits (single task — all changes in scope)

**Goal:** Apply all 4 changes from the spec atomically. Small enough that splitting would just add ceremony.

**Files:**
- Modify: `src/_shared/init-firewall.base.sh`
- Modify: `src/csharp/.devcontainer/init-firewall.fragment`
- Modify: `scripts/assemble-templates.sh`
- Modify: `src/base/devcontainer-template.json`
- Modify: `src/csharp/devcontainer-template.json`

- [ ] **Step 1: Remove `sentry.io`, `statsig.anthropic.com`, `statsig.com` from the curated domain list**

In `src/_shared/init-firewall.base.sh`, find the curated `for domain in \` block. Today it contains:

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
```

Remove the three lines for `sentry.io`, `statsig.anthropic.com`, and `statsig.com` so the block becomes:

```bash
for domain in \
    "registry.npmjs.org" \
    "api.anthropic.com" \
    "api.openai.com" \
    "auth.openai.com" \
    "chatgpt.com" \
    "marketplace.visualstudio.com" \
    "vscode.blob.core.windows.net" \
    "update.code.visualstudio.com" \
    ; do
```

- [ ] **Step 2: Restore strict fail-on-resolve in `src/_shared/init-firewall.base.sh`**

Find the block (still inside the same domain loop):

```bash
    if [ -z "$ips" ]; then
        echo "WARNING: $domain did not resolve to any A records — skipping"
        continue
    fi
```

Replace with:

```bash
    if [ -z "$ips" ]; then
        echo "ERROR: Failed to resolve $domain"
        exit 1
    fi
```

- [ ] **Step 3: Update csharp fragment**

Replace the entire contents of `src/csharp/.devcontainer/init-firewall.fragment` with (one domain per line, no quotes, no trailing whitespace):

```
api.nuget.org
www.nuget.org
dist.nuget.org
builds.dotnet.microsoft.com
```

(`dotnetcli.azureedge.net` and `dotnetbuilds.azureedge.net` are removed; `builds.dotnet.microsoft.com` is added.)

- [ ] **Step 4: Restore strict fail-on-resolve in `scripts/assemble-templates.sh`**

In the assembler's per-template fragment loop generation, find:

```bash
        domain_block+="    if [ -z \"\$ips\" ]; then${NL}"
        domain_block+="        echo \"WARNING: \$domain did not resolve to any A records — skipping\"${NL}"
        domain_block+="        continue${NL}"
        domain_block+="    fi${NL}"
```

Replace with:

```bash
        domain_block+="    if [ -z \"\$ips\" ]; then${NL}"
        domain_block+="        echo \"ERROR: Failed to resolve \$domain\"${NL}"
        domain_block+="        exit 1${NL}"
        domain_block+="    fi${NL}"
```

- [ ] **Step 5: Reset template versions to `0.1.0`**

In `src/base/devcontainer-template.json` and `src/csharp/devcontainer-template.json`, change:

```jsonc
"version": "2.0.0",
```

to:

```jsonc
"version": "0.1.0",
```

- [ ] **Step 6: Re-assemble**

```sh
bash scripts/assemble-templates.sh
```

Verify the output:

```sh
# Confirm dead domains are gone everywhere
grep -E 'sentry\.io|statsig\.com|statsig\.anthropic\.com|dotnetcli\.azureedge|dotnetbuilds\.azureedge' src/_shared/init-firewall.base.sh src/csharp/.devcontainer/init-firewall.fragment build/base/.devcontainer/init-firewall.sh build/csharp/.devcontainer/init-firewall.sh && echo "FOUND DEAD" || echo "DEAD GONE"

# Confirm new domain is present
grep -E 'builds\.dotnet\.microsoft\.com' build/csharp/.devcontainer/init-firewall.sh

# Confirm strict mode is back
grep -F 'WARNING:' src/_shared/init-firewall.base.sh scripts/assemble-templates.sh build/base/.devcontainer/init-firewall.sh build/csharp/.devcontainer/init-firewall.sh && echo "WARNING REMAINS" || echo "STRICT RESTORED"
grep -E 'echo "ERROR: Failed to resolve' src/_shared/init-firewall.base.sh build/base/.devcontainer/init-firewall.sh build/csharp/.devcontainer/init-firewall.sh

# Confirm version reset
grep -F '"version": "0.1.0"' src/base/devcontainer-template.json src/csharp/devcontainer-template.json build/base/devcontainer-template.json build/csharp/devcontainer-template.json
```

Expected:
- `DEAD GONE`
- `STRICT RESTORED`
- `builds.dotnet.microsoft.com` appears in csharp's assembled init-firewall.sh
- All four `devcontainer-template.json` files (src + build) show `"version": "0.1.0"`

- [ ] **Step 7: Build and smoke-test both images locally**

```sh
devcontainer build --workspace-folder build/base --image-name devcontainer-test:base
devcontainer build --workspace-folder build/csharp --image-name devcontainer-test:csharp
```

Then smoke test base (use `MSYS_NO_PATHCONV=1` to prevent Git Bash mangling `/bin/bash`):

```sh
MSYS_NO_PATHCONV=1 docker run --rm \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  --entrypoint /bin/bash \
  devcontainer-test:base \
  -c '
    sudo /usr/local/bin/init-firewall.sh >/tmp/fw.log 2>&1
    INIT_EXIT=$?
    echo "=== firewall init exit: $INIT_EXIT (expect 0) ==="
    grep -E "WARNING|ERROR" /tmp/fw.log && echo "WARN/ERR PRESENT" || echo "no warn/err"
    curl --connect-timeout 5 -fsS https://api.github.com/zen >/dev/null && echo "PASS: api.github.com" || echo "FAIL: api.github.com"
    curl --connect-timeout 5 -fsS https://sts.amazonaws.com >/dev/null && echo "PASS: sts.amazonaws.com" || echo "FAIL: sts.amazonaws.com"
    curl --connect-timeout 5 -fsS https://example.com >/dev/null 2>&1 && echo "FAIL: example.com reachable" || echo "PASS: example.com blocked"
  '
```

Expected: `firewall init exit: 0`, `no warn/err`, all PASS lines.

Same for csharp:

```sh
MSYS_NO_PATHCONV=1 docker run --rm \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  --entrypoint /bin/bash \
  devcontainer-test:csharp \
  -c '
    sudo /usr/local/bin/init-firewall.sh >/tmp/fw.log 2>&1
    INIT_EXIT=$?
    echo "=== firewall init exit: $INIT_EXIT (expect 0) ==="
    grep -E "WARNING|ERROR" /tmp/fw.log && echo "WARN/ERR PRESENT" || echo "no warn/err"
    curl --connect-timeout 5 -fsS https://api.github.com/zen >/dev/null && echo "PASS: api.github.com" || echo "FAIL: api.github.com"
    curl --connect-timeout 5 -fsS https://api.nuget.org/v3/index.json >/dev/null && echo "PASS: api.nuget.org" || echo "FAIL: api.nuget.org"
    curl --connect-timeout 5 -fsS https://builds.dotnet.microsoft.com >/dev/null 2>&1 && echo "PASS: builds.dotnet.microsoft.com" || echo "FAIL: builds.dotnet.microsoft.com (4xx is OK if connection succeeded)"
    curl --connect-timeout 5 -fsS https://example.com >/dev/null 2>&1 && echo "FAIL: example.com reachable" || echo "PASS: example.com blocked"
  '
```

Expected: `firewall init exit: 0`, `no warn/err`, all PASS lines (a 4xx HTTP from `builds.dotnet.microsoft.com/` is fine — only the connection is the test).

If `firewall init exit` is non-zero or any "PASS" check fails, capture the firewall log (`/tmp/fw.log`) for debugging. The most likely culprit would be a domain that we expected to resolve but doesn't — re-add it and rebuild, OR pick a different live alternative.

- [ ] **Step 8: Stop**

Report "All cleanup changes applied and verified locally."

---

## Final notes for the controller

- Single task = single subagent dispatch.
- After it returns, run any controller-side spot-checks (re-grep) and report to the user.
- No commit at the end. The user reviews and pushes.
