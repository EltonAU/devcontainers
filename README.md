# AI Sandbox Devcontainers

Reusable VS Code Dev Container templates for sandboxed AI coding agents — **both Claude Code and OpenAI Codex CLI** are preinstalled in every template. Pick whichever you want per session by typing `claude` or `codex`.

Each template runs the agents in a hardened Debian container with:

- **Outbound network firewall** — only Anthropic API, OpenAI API, npm, GitHub, and VS Code endpoints reachable. Everything else is dropped. Set up via `iptables`/`ipset` at container start.
- **Non-root user** with passwordless `sudo` only for the firewall script.
- **Per-agent named Docker volumes** for credentials — log in once per agent per machine, never touch the host filesystem.

Forked from [Anthropic's reference devcontainer](https://github.com/anthropics/claude-code/tree/main/.devcontainer) with version pinning, named-volume credentials, and Codex support added.

## Templates

| Template | Description |
|---|---|
| `base` | Bare sandbox: Claude Code, Codex CLI, git, gh, zsh. Use as a starting point. |
| `csharp` | `base` + .NET 9.0 SDK + C# extensions + NuGet domains in firewall allowlist. |

## Usage

In a new (or existing) repo, in VS Code:

1. **Cmd Palette** → "Dev Containers: Add Dev Container Configuration Files…"
2. Select **"From a predefined container configuration template"**.
3. Enter the OCI reference, e.g. `ghcr.io/eltonau/devcontainers/csharp`.
4. VS Code drops `.devcontainer/` into the workspace. Commit it.
5. **Reopen in container** when prompted.

### First-time login

The first container you open on a machine will have empty `claude-credentials` and `codex-credentials` volumes. Inside the container terminal, log in to whichever agents you want to use:

**Claude Code:**
```sh
claude
# Run /login at the prompt; complete OAuth flow.
```

**OpenAI Codex CLI:**
```sh
codex
# Choose "Sign in with ChatGPT" (uses your ChatGPT subscription) or supply OPENAI_API_KEY.
```

You can log into one, both, or neither. Tokens are written to the respective named volumes.

Every subsequent container on the same machine — any project, any template — starts already logged in for whichever agents you authenticated. No re-authentication.

PC and laptop have independent volumes. Log in once on each.

## What gets blocked

The firewall verifies itself at boot. If it can reach `example.com`, the container fails to start. Anything an agent tries to do (curl a random site, hit a non-allowlisted package mirror) returns ICMP "administratively prohibited" immediately.

To extend the allowlist for your project, edit `init-firewall.sh` in your project's `.devcontainer/` and rebuild the container.

## Maintenance

This repo is intentionally low-maintenance:

- Push to `main` → GitHub Actions republishes all templates.
- Claude Code and Codex versions are pinned via the `CLAUDE_CODE_VERSION` and `CODEX_VERSION` Dockerfile ARGs. Bump intentionally.
- Diff against [Anthropic's reference](https://github.com/anthropics/claude-code/tree/main/.devcontainer) periodically (a few times a year) to pull in their improvements.

## Adding a new language template

1. Copy `src/csharp/` to `src/<lang>/`.
2. Edit `devcontainer-template.json` (id, name, description, keywords).
3. Edit `devcontainer.json` (replace `dotnet:2` Feature, swap VS Code extensions).
4. Edit `init-firewall.sh` (replace NuGet domains with the new language's package registry).
5. Push. The workflow publishes it.

## License

MIT
