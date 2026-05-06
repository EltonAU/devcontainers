# AI Sandbox Devcontainers

Reusable devcontainer templates for sandboxed AI coding agents — **both Claude Code and OpenAI Codex CLI** are preinstalled in every template. Pick whichever you want by typing `claude` or `codex`. Apply via the [`devcontainer` CLI](https://github.com/devcontainers/cli) and open in any IDE that supports devcontainers (VS Code, Rider, IntelliJ, etc.).

Each template runs the agents in a hardened Debian container with:

- **Outbound network firewall** — only Anthropic API, OpenAI API, npm, GitHub, AWS, NuGet (csharp), and VS Code update endpoints reachable. DNS is locked to Docker's embedded resolver. SSH outbound and the host network are dropped. Everything else returns ICMP "administratively prohibited". Set up via `iptables`/`ipset` on every container start.
- **Non-root user** with passwordless `sudo` only for the firewall script.
- **Per-project named Docker volumes** for Claude, Codex, AWS, and gh credentials — parameterised by a `projectId` you set at template-apply time. Log in once per project per machine; volumes persist across container restarts and host reboots.
- **Read-only AWS and GitHub** by IAM policy and PAT scope. `AWS_PROFILE=readonly` is set globally; you supply static keys whose IAM policy enforces read-only access. GitHub access uses a fine-grained read-only PAT via `gh auth login`.

Forked from [Anthropic's reference devcontainer](https://github.com/anthropics/claude-code/tree/main/.devcontainer) with version pinning, named-volume credentials, and Codex support added.

## Templates

| Template | Description |
|---|---|
| `base` | Bare sandbox: Claude Code, Codex CLI, git, gh, zsh. Use as a starting point. |
| `csharp` | `base` + .NET 9.0 SDK + C# extensions + NuGet domains in firewall allowlist. |

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

### Cleaning up retired projects

Per-project volumes are not garbage-collected automatically. When you're done with a project for good, remove its volumes:

```sh
docker volume ls --format '{{.Name}}' | grep -E -- '-<projectId>$' | xargs -r docker volume rm
```

Replace `<projectId>` with the `projectId` you supplied at template-apply time.

## Agent guidance

Drop the following snippet into each project's `CLAUDE.md` (or `AGENTS.md` for Codex) so the agent knows the rules of the sandbox:

> **AWS access** is via the `readonly` profile (`AWS_PROFILE=readonly`) and is enforced as read-only by IAM policy — do not attempt write actions, they will fail.
>
> **Git and GitHub access** are read-only. You may `git fetch` / `git pull` / `git log` / `git diff` / `gh issue view` / `gh pr view`, but do not run `git push`, `gh pr create`, `gh issue create`, or any other write operation. They will fail.
>
> **Do not commit unless explicitly asked.** Even local commits (no network needed) should be left to the user — make the file changes and stop. The user reviews and commits themselves. If a workflow you're following says "commit X," skip that step and tell the user the change is ready to commit.

## What gets blocked

The firewall verifies itself at every container start. If it can reach `example.com`, container start fails. Anything the agent tries to do (curl a random site, hit a non-allowlisted package mirror) returns ICMP "administratively prohibited" immediately.

To extend the allowlist for your project, edit `.devcontainer/init-firewall.sh` in your applied project (the file the template wrote into your repo) and rebuild the container. To extend the allowlist for the *templates themselves*, add the domains to `src/<template>/.devcontainer/init-firewall.fragment` here and re-run `bash scripts/assemble-templates.sh`.

## Maintenance

This repo is intentionally low-maintenance:

- Releases are manual — no auto-publish on push (see [Releasing](#releasing) below).
- Claude Code and Codex versions are pinned via the `CLAUDE_CODE_VERSION` and `CODEX_VERSION` Dockerfile ARGs. Bump intentionally.
- Diff against [Anthropic's reference](https://github.com/anthropics/claude-code/tree/main/.devcontainer) periodically (a few times a year) to pull in their improvements.

## Releasing

The workflow is `workflow_dispatch` only — pushing code never publishes by itself. To cut a release:

1. **Bump the `version` field** in the affected template's `src/<template>/devcontainer-template.json`. Follow semver:
   - `1.0.0 → 1.0.1` for a fix (firewall domain added, version pin patched).
   - `1.0.0 → 1.1.0` for an addition (new VS Code extension, new tool installed).
   - `1.0.0 → 2.0.0` for a breaking change (mount path renamed, default user changed).
2. Commit + push the version bump.
3. **GitHub → Actions → Release Templates → Run workflow** (against the default branch). Takes ~30s.
4. Verify the new version tag appears at https://github.com/EltonAU?tab=packages.

After publishing, both `1.0.0` (the old tag) and `1.0.1` (the new tag) coexist on ghcr.io. Anyone pinned to `:1.0.0` keeps it; new consumers pulling `:latest` get `:1.0.1`.

**Changes that don't need a version bump or a workflow run:** README edits, LICENSE changes, comments in workflow YAML. Anything outside `src/<template>/` doesn't ship to ghcr.io.

## Adding a new language template

1. Copy `src/csharp/` to `src/<lang>/`.
2. Edit `<lang>/devcontainer-template.json` (id, name, description, keywords; start at `version: 1.0.0`; keep the `projectId` option).
3. Edit `<lang>/.devcontainer/devcontainer.json` (replace `dotnet:2` Feature, swap VS Code extensions).
4. Edit `<lang>/.devcontainer/init-firewall.fragment` (replace NuGet/dotnet domains with the new language's package registry domains, one per line).
5. Run `bash scripts/assemble-templates.sh` and verify `build/<lang>/.devcontainer/` looks right.
6. Commit, push, then trigger the Release workflow manually (see [Releasing](#releasing)).

## Design notes

This sandbox makes a few deliberate choices worth surfacing:

- **Per-project credential isolation, persistent across sessions.** Each project gets its own named Docker volumes for Claude, Codex, AWS, and gh credentials, parameterised by the `projectId` you supply at template-apply time. Volumes survive container recreation and host reboots — you log in once per project per machine, not once per session.
- **Egress allowlist via iptables + ipset.** DNS is restricted to Docker's embedded resolver (no exfiltration via arbitrary DNS servers). Outbound SSH is blocked. The host-network range is not allowed. AWS service ranges are fetched at firewall init from `ip-ranges.amazonaws.com` and added to the allowlist. The full agent flow (WebFetch, WebSearch, API calls) routes through Anthropic/OpenAI, both already allowlisted.
- **Read-only AWS and GitHub by IAM/PAT scope.** Read-only-ness is enforced server-side, not by the container. Static AWS keys are paired with the AWS-managed `ReadOnlyAccess` policy. GitHub access uses a fine-grained read-only PAT.
- **Build-time template composition.** Shared content (`Dockerfile`, firewall base script) lives in `src/_shared/`; each template overlays a per-template firewall fragment. The release workflow assembles `build/<template>/` and publishes from there. This keeps a single source of truth for the parts every template shares.

## License

MIT
