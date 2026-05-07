# Allowlist Cleanup + Strict Resolve — Design

**Date:** 2026-05-07
**Status:** Approved for implementation planning
**Builds on:** `2026-05-07-sandbox-hardening-followup-design.md`
**Scope:** Remove dead and telemetry-only domains from the firewall allowlist, replace deprecated .NET CDN domains, restore strict fail-on-resolve behavior, and reset template versions to pre-release.

## Goal

The previous follow-up pass added `WARNING: ... did not resolve to any A records — skipping` behavior because two real domains (`statsig.anthropic.com`, `dotnetbuilds.azureedge.net`) failed to resolve and were aborting firewall init. That was a band-aid. The right fix is to remove dead entries from the lists so resolution failures never happen during normal operation, and restore strict mode so any *future* dead domain surfaces immediately at boot rather than silently degrading the firewall.

This pass also drops domains that exist purely for vendor telemetry/feature-flag analytics (which the agents do not require to function), and resets template versions from the speculative `2.0.0` to `0.1.0` since nothing has ever been published.

## Threat model (unchanged)

Same as v1/v2 design. The cleanup tightens the allowlist (removes things) and tightens the failure behavior (strict resolve); both are pure-positive for the threat model.

## Domain audit

### Base curated list (`src/_shared/init-firewall.base.sh`)

| Domain | Decision | Rationale |
|---|---|---|
| `registry.npmjs.org` | Keep | Required for npm operations |
| `api.anthropic.com` | Keep | Claude Code's API endpoint — required |
| `api.openai.com` | Keep | Codex's API endpoint — required |
| `auth.openai.com` | Keep | Codex OAuth — required for login |
| `chatgpt.com` | Keep | Codex "Sign in with ChatGPT" subscription auth |
| `sentry.io` | **Remove** | Pure error-reporting telemetry. Agents work fine without it. Removing it just means crash reports don't reach the vendors. |
| `statsig.anthropic.com` | **Remove** | Anthropic-fronted alias for Statsig that no longer resolves (NXDOMAIN). |
| `statsig.com` | **Remove** | Feature-flag service used by Claude Code for runtime config (model availability, A/B tests, feature gates). Claude Code falls back to built-in defaults when unreachable. Removing it means: no dynamic feature toggling, no experiment bucket assignments — none of which affect dev work. |
| `marketplace.visualstudio.com` | Keep | VS Code extension installs on first container open |
| `vscode.blob.core.windows.net` | Keep | VS Code Server binary download (required for VS Code attach) |
| `update.code.visualstudio.com` | Keep | VS Code Server in-container updates |

### csharp fragment (`src/csharp/.devcontainer/init-firewall.fragment`)

| Domain | Decision | Rationale |
|---|---|---|
| `api.nuget.org` | Keep | NuGet API |
| `www.nuget.org` | Keep | NuGet UI/index |
| `dist.nuget.org` | Keep | NuGet binary distribution |
| `dotnetcli.azureedge.net` | **Remove** | Microsoft retired the Azure CDN endpoints. Migrated to `builds.dotnet.microsoft.com`. |
| `dotnetbuilds.azureedge.net` | **Remove** | Same — already failed to resolve during the v2 smoke test. |
| `builds.dotnet.microsoft.com` | **Add** | The actual current endpoint where `.NET` SDK installs fetch from. Confirmed live during the v2 csharp `devcontainer build`. |

## Strict-resolve restoration

The warn-and-skip introduced in the v2 follow-up pass becomes:

`src/_shared/init-firewall.base.sh`:
```bash
if [ -z "$ips" ]; then
    echo "ERROR: Failed to resolve $domain"
    exit 1
fi
```

`scripts/assemble-templates.sh` (the per-template fragment loop's emitted code):
```bash
if [ -z "\$ips" ]; then
    echo "ERROR: Failed to resolve \$domain"
    exit 1
fi
```

After the dead-domain removals, every remaining domain in the curated list and the csharp fragment resolves today, so strict mode is the right default. A future failure becomes a loud signal at container boot rather than a silent gap in the allowlist.

## Version reset

Both `src/base/devcontainer-template.json` and `src/csharp/devcontainer-template.json` `"version"` fields go from `"2.0.0"` to `"0.1.0"`. Rationale:

- Nothing has been published to GHCR yet — there are no consumers pinned to `1.x` or `2.x`.
- The `1.0.0` placeholder was scaffolding, not a deliberate release.
- `0.x` accurately conveys "pre-release, breaking changes possible, semver applies once we hit 1.0.0".
- The first actual `workflow_dispatch` of the Release workflow becomes `0.1.0`.

Subsequent bumps follow the README's existing rules (patch / minor / major) but anchored to `0.x` until the user decides the templates are stable enough to call `1.0.0`.

## Verification

The existing CI pipeline (devcontainer build per template + firewall smoke tests + IPv6 must-fail) catches any allowlist regression. After this cleanup:

- Smoke tests must still pass on both base and csharp
- The firewall init log shows no `WARNING: ... skipping` lines
- Init exit code is 0

If a smoke test fails, the cleanup is wrong (e.g., we removed something Claude actually needs). Roll back the specific removal and re-run.

## Out of scope

- **Audit JetBrains-specific domains.** No active need; deferred until the user actually runs out of VS Code-specific functionality in Rider.
- **Empirical observe-mode** (run firewall in REJECT-with-log mode for a session and capture every domain attempted). Useful exercise but heavier than this cleanup needs to be.
- **Dropping `update.code.visualstudio.com`.** Could remove if user wanted to pin VS Code Server version, but it's small and harmless.

## Open questions

None. All decisions reflected above are approved by the user.
