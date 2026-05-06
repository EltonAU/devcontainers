# Devcontainer Sandbox Hardening — Design

**Date:** 2026-05-06
**Status:** Approved for implementation planning
**Scope:** All templates under `src/` (currently `base`, `csharp`)

## Goal

Tighten the existing `eltonau/devcontainers` templates into a stronger sandbox suitable for **agent-only** use (Claude Code and OpenAI Codex CLI), with read-only AWS access and read-only GitHub access. Improve maintainability and add CI validation. Preserve the existing OCI-template publishing flow to GHCR.

## Threat model

The container hosts an autonomous agent acting on behalf of the user. The agent is **not malicious** but is **untrusted to make broad outbound calls or touch host state**. Specifically:

- The agent should reach only the APIs it needs (Anthropic, OpenAI, GitHub, npm, NuGet, AWS, VS Code update servers) and nothing else.
- The agent must not reach host services or other containers on the local Docker network.
- The agent must not exfiltrate via DNS or open SSH.
- AWS access is read-only, enforced server-side via IAM policy (`ReadOnlyAccess` or tighter custom policy attached to the IAM user whose static keys are mounted).
- GitHub access is read-only, enforced via a fine-grained PAT scoped to `read` on the repos the user works in. The user (not the agent) handles `git push` and PR creation.

## Non-goals

- Defending against an actively malicious agent that has reached arbitrary code execution and is intentionally trying to break out. Containers are not a security boundary against root code execution.
- Per-session credential isolation. Credentials persist across sessions per project (see "Credential persistence" below).
- Multi-user access. This is a single-user repo for personal use.

## Architectural overview

```
┌─────────────────────────────────────────────┐
│ Host (Windows / macOS / Linux)              │
│                                             │
│  ┌────────────────────────────────────────┐ │
│  │ Devcontainer (per project)             │ │
│  │                                        │ │
│  │  Shell + Claude Code + Codex CLI       │ │
│  │  AWS CLI + gh CLI + git                │ │
│  │                                        │ │
│  │  iptables + ipset egress allowlist:    │ │
│  │   - Anthropic, OpenAI, npm, GitHub     │ │
│  │   - VS Code, NuGet (csharp), AWS       │ │
│  │   - DNS only to 127.0.0.11             │ │
│  │   - No SSH, no host network            │ │
│  │                                        │ │
│  └────┬──────────┬──────────┬──────────┬──┘ │
│       │          │          │          │    │
│  ┌────▼──┐ ┌────▼──┐ ┌────▼──┐ ┌────▼──┐   │
│  │claude-│ │codex- │ │aws-   │ │gh-    │   │
│  │creds- │ │creds- │ │creds- │ │creds- │   │
│  │<pid>  │ │<pid>  │ │<pid>  │ │<pid>  │   │
│  └───────┘ └───────┘ └───────┘ └───────┘   │
│   (per-project named Docker volumes)        │
└─────────────────────────────────────────────┘
```

`<pid>` is a per-project identifier supplied at template-apply time via the `projectId` template option. Volume names are stable for the life of the project.

## Components

### 1. Per-project credential volumes

**Decision:** Replace the current shared volume names (`claude-credentials`, `codex-credentials`, `claude-bashhistory`) with per-project volumes parameterised by a template option.

In `src/<template>/devcontainer-template.json`:

```jsonc
"options": {
  "projectId": {
    "type": "string",
    "description": "Unique identifier used in Docker volume names so credentials don't collide across projects. Lowercase letters, digits, hyphens.",
    "default": "myproject"
  }
}
```

In `src/<template>/.devcontainer/devcontainer.json`:

```jsonc
"mounts": [
  "source=claude-credentials-${templateOption:projectId},target=/home/node/.claude,type=volume",
  "source=codex-credentials-${templateOption:projectId},target=/home/node/.codex,type=volume",
  "source=aws-credentials-${templateOption:projectId},target=/home/node/.aws,type=volume",
  "source=gh-credentials-${templateOption:projectId},target=/home/node/.config/gh,type=volume",
  "source=bashhistory-${templateOption:projectId},target=/commandhistory,type=volume"
]
```

**Rationale:** Substitution at template-apply time is IDE-agnostic. Template options are part of the devcontainer-templates spec, supported by the `@devcontainers/cli` npm package and VS Code's apply UI. JetBrains/Rider users (or anyone whose IDE lacks the apply UX) can run the CLI directly:

```sh
npm i -g @devcontainers/cli
devcontainer templates apply \
  --template-id ghcr.io/eltonau/devcontainers/<template> \
  --workspace-folder . \
  --template-args '{"projectId":"my-app"}'
```

Once applied, the rendered `devcontainer.json` has literal volume names — it's a normal devcontainer, openable in any tool.

**Trade-off:** First-time login per project (login to Claude, login to Codex, paste AWS keys, login to gh CLI). One-time per project, persistent thereafter. Volumes survive container recreation, host reboot, etc. — they only disappear on explicit `docker volume rm`.

**Cleanup:** Volumes accumulate when projects are retired. README will document `docker volume ls --filter name=<pid> | xargs docker volume rm`.

### 2. Firewall hardening

`init-firewall.sh` changes:

- **DNS lockdown**: replace the unscoped `OUTPUT -p udp --dport 53 -j ACCEPT` with `OUTPUT -p udp --dport 53 -d 127.0.0.11 -j ACCEPT`, and similarly scope the `INPUT -p udp --sport 53` rule to `-s 127.0.0.11`. DNS goes only to Docker's embedded resolver.
- **Drop SSH**: remove `iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT` and the matching INPUT rule. The agent uses HTTPS for git; SSH outbound is unneeded and a textbook escape path.
- **Drop host network hole**: remove the `HOST_NETWORK` ACCEPT rules. The agent has no reason to reach host services for this threat model.
- **AWS allowlist**: fetch AWS's `ip-ranges.json` from `ip-ranges.amazonaws.com` (a static endpoint), filter to `service: AMAZON` (covers all AWS services), and add the resulting CIDRs to the `allowed-domains` ipset. Same pattern as the existing GitHub-meta fetch. No region filtering — the user wants global coverage and the keys are read-only anyway.
- **Verification expansion**: extend the post-config curl checks to include `sts.amazonaws.com` (must succeed) so a misconfigured AWS allowlist fails the container start instead of failing later at runtime.

The existing GitHub IP fetch, the curated domain list (Anthropic, OpenAI, npm, VS Code, etc.), and the default-DROP policies stay as-is.

### 3. Firewall lifecycle

**Decision:** Move firewall application from `postCreateCommand` to `postStartCommand`. Rules re-apply on every container start, not just creation.

```jsonc
// devcontainer.json
"postStartCommand": "sudo /usr/local/bin/init-firewall.sh"
```

**Known limitation:** there is still a brief window between container start and the script's completion during which the rules from the previous session may or may not be in effect (iptables rules in the network namespace usually persist across stop/start, but it's implementation-dependent). Closing this fully would require an entrypoint-level wrapper. Out of scope for this change; flagged as a future hardening if needed.

### 4. AWS support in `base`

Add to `src/base/.devcontainer/Dockerfile`:

```dockerfile
ARG AWS_CLI_VERSION=2.x.x  # actual version pinned during implementation
RUN ARCH=$(dpkg --print-architecture) && \
  curl "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}-${AWS_CLI_VERSION}.zip" -o awscliv2.zip && \
  unzip awscliv2.zip && ./aws/install && rm -rf aws awscliv2.zip
```

(Installer pulls from `awscli.amazonaws.com` at build time, before the firewall exists, so no allowlist conflict.)

In `src/base/.devcontainer/devcontainer.json`:

```jsonc
"containerEnv": {
  "AWS_PROFILE": "readonly"
}
```

The user supplies the actual keys by writing to `~/.aws/credentials` inside the container on first use, e.g.:

```ini
[readonly]
aws_access_key_id = AKIA...
aws_secret_access_key = ...
region = ap-southeast-2
```

Alternatively `aws configure --profile readonly` does the same interactively. The file lives in the per-project `aws-credentials-<pid>` volume.

**No direnv.** With a single read-only profile baked into `containerEnv`, every command picks it up automatically. Direnv was originally proposed for per-project profile switching, which the user has decided against.

### 5. De-duplication via build-time composition

**Problem:** `src/base/.devcontainer/Dockerfile` and `src/csharp/.devcontainer/Dockerfile` are byte-identical. `init-firewall.sh` between them differs only in the C# template's added NuGet/dotnet domains.

**Solution:** Move shared content to `src/_shared/`:

```
src/
  _shared/
    Dockerfile
    init-firewall.base.sh
    init-firewall.fragments/
      nuget.txt
  base/
    devcontainer-template.json
    .devcontainer/
      devcontainer.json
  csharp/
    devcontainer-template.json
    .devcontainer/
      devcontainer.json
```

The `release.yml` workflow assembles per-template `.devcontainer/` directories at publish time:

1. Copy `src/_shared/Dockerfile` into each template's `.devcontainer/`.
2. Compose `init-firewall.sh` for each template by concatenating `src/_shared/init-firewall.base.sh` with any template-specific domain fragments (`nuget.txt` for csharp, etc.).
3. Run `devcontainers/action@v1` with `base-path-to-templates` pointing at the assembled output directory (e.g., `./build`), not `./src`.

The composed `.devcontainer/` is a build artifact, not committed. `src/` becomes the source of truth; `build/` is `.gitignore`d.

**Trade-off:** Slightly more complex CI. Significantly less hand-maintenance — single source of truth for the Dockerfile and the firewall base script.

### 6. Tool installation cleanup

Add `curl` and `wget` explicitly to the apt install list in the shared Dockerfile. They are present in `node:20.20.2` by default, but pinning makes the dependency explicit.

### 7. CI validation workflow

New file: `.github/workflows/validate.yml`. Triggers on `push` and `pull_request`. Steps:

1. **JSON validation** — `jq -e . < <file>` on every `*.json` in `src/`.
2. **Shellcheck** — `shellcheck` on every `*.sh` in `src/_shared/` and assembled output.
3. **Template assembly** — run the same composition logic the release workflow uses, fail on missing fragments.
4. **Docker build** — `docker build` on each assembled template's Dockerfile.
5. **Firewall smoke test** — boot the assembled `base` container with `--cap-add=NET_ADMIN --cap-add=NET_RAW`, run `init-firewall.sh`, then verify:
   - `curl --connect-timeout 5 https://example.com` fails.
   - `curl --connect-timeout 5 https://api.github.com/zen` succeeds.
   - `curl --connect-timeout 5 https://sts.amazonaws.com` succeeds.
   - `dig @8.8.8.8 google.com` fails (DNS lockdown verification).
6. **Devcontainer template lint** — `devcontainer templates validate` against each template directory.

This catches regressions before they ship to GHCR.

### 8. Action SHA-pinning

In both `release.yml` and `validate.yml`, replace tag refs with commit SHAs:

```yaml
- uses: actions/checkout@<sha>  # v4.x.x
- uses: devcontainers/action@<sha>  # v1.x.x
```

A comment alongside each pin records the human-readable version. Dependabot's `github-actions` ecosystem can be enabled later if desired to keep these current; out of scope for this change.

### 9. Documentation

Update `README.md`:

- Replace the "First-time login" section to cover the four credential stores: Claude, Codex, AWS (file-write or `aws configure`), gh (`gh auth login`).
- Add a "Per-project setup" section describing the `devcontainer templates apply` CLI workflow, with the exact command. Note this is the IDE-agnostic path.
- Add a "Volume cleanup when retiring a project" one-liner.
- Add an "Agent guidance" section with a starter `AGENTS.md` / `CLAUDE.md` snippet to drop into each project:
  > **AWS access** is via the `readonly` profile (`AWS_PROFILE=readonly`) and is enforced as read-only by IAM policy — do not attempt write actions, they will fail.
  >
  > **Git and GitHub access** are read-only. You may `git fetch` / `git pull` / `git log` / `git diff` / `gh issue view` / `gh pr view`, but do not run `git push`, `gh pr create`, `gh issue create`, or any other write operation. They will fail.
  >
  > **Do not commit unless explicitly asked.** Even local commits (no network needed) should be left to the user — make the file changes and stop. The user reviews and commits themselves. If a workflow you're following says "commit X," skip that step and tell the user the change is ready to commit.
- Note the explicit design choice: shared inside-project credential persistence across sessions, isolated across projects.
- Remove or correct any wording suggesting GitHub Pages bootstrap; the publishing target is GHCR.

## Out of scope (deliberately)

- **DNS-aware egress proxy** (Squid / mitmproxy with SNI inspection). Would give cleaner `*.amazonaws.com`-style filtering but doubles operational complexity. Note as a future option if IP-based filtering becomes brittle.
- **Strict vs practical template profiles** (Codex's recommendation). Single-user repo with one well-defined threat model; doubling templates doubles maintenance for marginal benefit.
- **Documentation-site allowlists** (MDN, docs.aws.amazon.com, etc.). Agents have `WebFetch`/`WebSearch` tools that route through the Anthropic/OpenAI APIs, which are already allowlisted. Direct `curl` from the container shell to docs sites stays blocked; the agent has a working alternative.
- **Entrypoint-level firewall enforcement** (closing the post-start window). Larger refactor; deferred unless evidence emerges that the window matters.

## Implementation phases

The implementation plan (separate document) will sequence these changes. A reasonable order:

1. **Refactor: build-time composition.** Move shared files to `src/_shared/`, write the assembly logic, update `release.yml`. No behavioural change to published templates yet.
2. **Firewall hardening.** DNS lockdown, drop SSH, drop host network, postStartCommand move. Add the new firewall verification.
3. **AWS support.** Install AWS CLI, fetch ip-ranges.json in firewall init, add `containerEnv` profile, add `aws-credentials` volume.
4. **Per-project volumes.** Add `projectId` template option, parameterise all volume mounts.
5. **GitHub credential volume.** Add `gh-credentials` volume.
6. **CI validation workflow.** `validate.yml` with all checks.
7. **Action SHA-pinning.** Both workflows.
8. **README rewrite.** Updated first-time login, per-project setup, agent guidance, volume cleanup, trade-offs.

Each phase is independently mergeable; later phases assume earlier ones are in place.

## Open questions

None outstanding. All design decisions reflected above are approved by the user.
