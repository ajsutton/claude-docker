# claude-docker

Run AI coding agents in an isolated Docker container. The container mirrors your local environment — same username, same file paths, same git config — so you can work as if the agent is running natively.

Currently supported agents:
- [Claude Code](https://claude.ai/claude-code) (Anthropic)
- [Codex CLI](https://github.com/openai/codex) (OpenAI)

> **Note:** This container provides encapsulation, not a security sandbox. Agents have read/write access to your mounted code directory, your git and agent configs, a GitHub token, and unrestricted internet access. Treat it as a convenience layer for keeping your host system clean, not as a trust boundary.

## Quick start

```sh
cp .env.example .env
# Edit .env — set CODE_PATH to your code directory
./run.sh
./be-claude    # launch Claude Code
./be-codex     # launch Codex CLI
./be-exec npm test
```

That's it. `run.sh` builds and starts the container, then use `be-claude` or `be-codex` to connect via SSH and launch the agent in your current directory. Set `USE_MOSH=true` in `.env` to use [mosh](https://mosh.org) instead for a resilient connection.

If `SSH_AUTHORIZED_KEYS` isn't set in `.env`, `run.sh` automatically uses keys from your ssh-agent.

### Project instructions

Both agents support repo-level instruction files (`CLAUDE.md` for Claude Code, `AGENTS.md` for Codex). To maintain a single source of truth, name your file `AGENTS.md` and symlink `CLAUDE.md` to it:

```sh
# In your project repo:
mv CLAUDE.md AGENTS.md    # or create AGENTS.md from scratch
ln -s AGENTS.md CLAUDE.md
```

Both agents will read the same instructions.

## How it works

An Ubuntu container runs an SSH server on port 2222. Your code directory is bind-mounted at the same path inside the container, so file references are identical on both sides. `be-claude` connects via SSH (or mosh if enabled) and starts Claude in the directory matching your current working directory on the host.

The container comes with Go, Node.js, Rust tooling, [mise](https://mise.run), [gopls](https://pkg.go.dev/golang.org/x/tools/gopls), git, gh, and other common development tools pre-installed.

## Usage

### be-claude / be-codex / be-exec

Run from anywhere inside your `CODE_PATH`:

```sh
./be-claude                    # launch Claude Code
./be-claude --resume           # pass arguments through to claude
./be-codex                     # launch Codex CLI
./be-codex --full-auto         # pass arguments through to codex
./be-exec npm test             # run a command after shell login/init
```

All three scripts can be symlinked onto your `PATH` for convenience — they resolve their own location to find `.env`.

`be-exec` runs the provided command through `zsh -ilc`, which is useful for tools that expect a fully initialized login shell before execution.

Environment variables listed in `FORWARD_ENVS` are forwarded securely into the container via SSH's `SendEnv` mechanism — values never appear in process arguments. Since `.env` is sourced as bash, you can use command substitution to set values dynamically (e.g. `GH_TOKEN=$(gh auth token)`). See `.env.example` for a typical setup.

**Codex CLI** authenticates via `codex` login — credentials are stored in `~/.codex/` which is bind-mounted from the host, so login persists across container rebuilds. Claude Code credentials are synced automatically from the macOS Keychain (see [Credential sync](#credential-sync)).

### Starting and stopping

```sh
./run.sh     # build and start (docker compose up -d --build)
./stop.sh    # stop (docker compose down)
```

## Configuration

All configuration lives in `.env` (gitignored). Copy `.env.example` to get started.

| Variable | Default | Description |
|---|---|---|
| `CODE_PATH` | *(required)* | Absolute path to your code directory on the host |
| `SSH_AUTHORIZED_KEYS` | ssh-agent keys | SSH public key(s) allowed into the container |
| `SSH_PORT` | `2222` | Host port mapped to the container's SSH server |
| `USE_MOSH` | `false` | Set to `true` to use mosh instead of SSH (requires mosh on host) |
| `MOSH_PORT` | `60001` | Host port mapped to the container's mosh server (UDP, only used when `USE_MOSH=true`) |
| `COMPOSE_PROJECT_NAME` | `claude-dev` | Container name — override to run multiple instances |
| `CLAUDE_ARGS` | *(empty)* | Default arguments passed to claude (e.g. `--dangerously-skip-permissions`) |
| `FORWARD_ENVS` | *(empty)* | Space-separated list of env var names to forward into the container |
| `CLAUDE_CREDENTIAL_SYNC` | `true` | Set to `false` to disable automatic credential sync (see below) |
| `CODEX_ARGS` | *(empty)* | Default arguments passed to codex (e.g. `--full-auto`) |
| `CODEX_SANDBOX` | `danger-full-access` | Codex sandbox mode — bubblewrap can't create namespaces inside Docker, so sandboxed modes require `--privileged` |
| `EXTRA_PACKAGES` | *(empty)* | Additional apt packages to install in the container (e.g. `postgresql-client redis-tools`) |

## Credential sync

Claude Code authenticates via OAuth. On macOS, logging in through Claude Desktop or Claude Code stores the OAuth token in the system Keychain. The container can't access the Keychain directly, so without credential sync you'd need to log in separately inside the container.

`be-claude` solves this by automatically reading credentials from the macOS Keychain before each session and injecting them into the container. After the session ends, if the container refreshed the token, `be-claude` updates the Keychain so native Claude picks it up. This means you can:

- **Log in once on macOS** (via Claude Desktop or `claude` on the command line) and have that login automatically work inside the container — no need to authenticate separately
- **Log in inside the container** (if you prefer) and have the token sync back to the Keychain for native use

On non-macOS hosts, the credentials file (`~/.claude/.credentials.json`) is the single source of truth — the container reads and writes it directly via bind mount.

To disable syncing, set `CLAUDE_CREDENTIAL_SYNC=false` in `.env`.

## Custom compose overlays

Drop `.yml` files into `compose.d/` to extend the Docker Compose configuration. All files are automatically included by `run.sh`. The directory is gitignored so overlays stay local.

For example, to keep Rust build artifacts on a named volume (avoiding macOS/Linux binary conflicts):

```yaml
# compose.d/rust-cache.yml
volumes:
  rust-target:
services:
  claude-dev:
    volumes:
      - rust-target:/Users/you/code/project/rust/target
      - ./compose.d/rust-cache.init.sh:/etc/claude-docker/init.d/rust-cache.sh:ro
```

### Init scripts

Named volumes are created by Docker as root, so they may need ownership fixed before the non-root user can write to them. The entrypoint sources any `*.sh` scripts found in `/etc/claude-docker/init.d/` at startup (running as root, before sshd starts). Overlays can bind-mount init scripts into this directory.

The `APP_USER` environment variable is set to the host username for use in init scripts.

```sh
# compose.d/rust-cache.init.sh
#!/bin/sh
target="/Users/you/code/project/rust/target"
[ -n "$APP_USER" ] && [ -d "$target" ] && chown "$APP_USER:$APP_USER" "$target"
```

## Custom CA certificates

Drop `.crt` files into the `certs/` directory and rebuild. They are installed into the container's trust store automatically.

The `certs/` directory is gitignored so certificates stay local.

## What gets mounted

| Host path | Container path | Mode |
|---|---|---|
| `$CODE_PATH` | `$CODE_PATH` | read/write |
| `~/.claude` | `~/.claude` | read/write |
| `~/.claude.json` | `~/.claude.json` | read/write |
| `~/.codex` | `~/.codex` | read/write |
| `~/.gitconfig` | `~/.gitconfig` | read-only |
| `~/.gitignore` | `~/.gitignore` | read-only |
| `~/.local/state/mise/trusted-configs` | `~/.local/state/mise/host-trusted-configs` | read-only |
| `~/.local/state/mise/tracked-configs` | `~/.local/state/mise/host-tracked-configs` | read-only |

## Persistent volumes

Named Docker volumes preserve data across container rebuilds:

| Volume | Mounted at | Contents |
|---|---|---|
| `ssh-host-keys` | `/etc/ssh` | SSH host keys (avoids host key warnings after rebuild) |
| `build-cache` | `~/.cache` | Go build/module cache, Cargo registry, Foundry cache, solc binaries, mise cache |

The `APP_USER` environment variable is also set to the host username, for use by init scripts (see [Custom compose overlays](#custom-compose-overlays)).

Environment variables redirect tool caches into `~/.cache` so a single volume covers everything:

- `GOMODCACHE` → `~/.cache/go-mod`
- `CARGO_HOME` → `~/.cache/cargo`
- `SVM_HOME` → `~/.cache/svm`
- Foundry and mise use `~/.cache` by default (XDG convention)

## Pre-installed tools

git, gh, go, gopls, node, npm, [codex](https://github.com/openai/codex), mise, mosh, tmux, vim, zsh, fzf, ripgrep, diff-so-fancy, jq, make, gpg, [tuicr](https://github.com/agavra/tuicr), iTerm2 utilities

## SSH agent forwarding

If you connect with SSH agent forwarding (`ssh -A`), your host SSH keys are available inside the container. Git commit signing is configured automatically via `setupGitSigning.sh` when agent keys are present.
