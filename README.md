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

That's it. By default `run.sh` builds **and starts** a shared long-running container that `be-*` SSHes into. If you'd rather each `be-*` run its own container (so image rebuilds never disturb active sessions), set `EPHEMERAL_SESSIONS=true` in `.env` — see [Ephemeral mode](#ephemeral-mode) below.

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

Your code directory is bind-mounted into the container at the same path, so file references are identical on both sides. Each `be-*` script starts (or attaches to) a container and launches the agent in the directory matching your current working directory on the host.

The container comes with Go, Node.js, Rust tooling, [mise](https://mise.run), [bun](https://bun.sh), [gopls](https://pkg.go.dev/golang.org/x/tools/gopls), git, gh, and other common development tools pre-installed.

There are two modes.

### Shared-container mode (default)

An Ubuntu container runs an SSH server on port 2222. `be-claude` connects via SSH (or mosh if `USE_MOSH=true`). All concurrent `be-*` invocations share the same container, so they share runtime state, `/tmp`, and mutable shell history; rebuilding the image kills every active session.

### Ephemeral mode

Set `EPHEMERAL_SESSIONS=true` in `.env`. Each `be-*` invocation runs a fresh container from the current image:

- Sessions are isolated from each other. State changes in one (installed packages, `/tmp`, shell history) don't leak to others.
- Rebuilding the image does not disturb already-running sessions — they stay pinned to the image they started from. The next session you start picks up the new image automatically.
- Build caches (Go module + build cache, Cargo registry, svm, mise installs, bun cache) remain shared across sessions via named Docker volumes. See [`docs/ephemeral-sessions.md`](docs/ephemeral-sessions.md) for the per-tool concurrency analysis.
- `./run.sh` just builds the image; there is no long-running container to stop.
- `./stop.sh` stops any currently-running session containers and reaps orphan staging dirs.

Mode-specific setup and utilities are covered under [Ephemeral mode](#ephemeral-mode) below.

## Usage

### be-claude / be-codex / be-exec

Run from anywhere inside your `CODE_PATH`:

```sh
./be-claude                    # launch Claude Code
./be-claude --resume           # pass arguments through to claude
./be-codex                     # launch Codex CLI
./be-codex --full-auto         # pass arguments through to codex
./be-shell                     # interactive shell
./be-exec npm test             # run a command after shell login/init
```

All scripts can be symlinked onto your `PATH` for convenience — they resolve their own location to find `.env`.

`be-exec` runs the provided command through `zsh -ilc`, which is useful for tools that expect a fully initialized login shell before execution.

Environment variables listed in `FORWARD_ENVS` are forwarded securely into the container. In shared-container mode they go via SSH's `SendEnv`; in ephemeral mode they go via `docker run -e`. Values never appear in process arguments either way. Since `.env` is sourced as bash, you can use command substitution to set values dynamically (e.g. `GH_TOKEN=$(gh auth token)`). See `.env.example` for a typical setup.

**Codex CLI** authenticates via `codex` login — credentials are stored in `~/.codex/` which is bind-mounted from the host, so login persists across container rebuilds. Claude Code credentials are synced automatically from the macOS Keychain (see [Credential sync](#credential-sync)).

### Starting and stopping

```sh
./run.sh     # shared mode: build and start. ephemeral mode: build only.
./stop.sh    # shared mode: compose down. ephemeral mode: stop active sessions + reap stage dirs.
```

## Ephemeral mode

Set `EPHEMERAL_SESSIONS=true` in `.env` to opt in. What you get and what to know:

### First-run: pick your ssh-agent

ephemeral mode bind-mounts a host ssh-agent socket into each session for onward SSH (git push) and container-side git commit signing. Auto-detection handles most setups without any config:

```sh
./run.sh ssh-agent-check
```

This prints which agent will be selected and the path it will bind. Detection order:

1. `SSH_AGENT_HOST_SOCK` in `.env` (explicit override)
2. `$SSH_AUTH_SOCK` if your docker runtime can share it (native Linux, OrbStack; Docker Desktop only when the socket lives under `$HOME`)
3. 1Password (macOS: `~/Library/Group Containers/.../agent.sock`; Linux: `~/.1password/agent.sock` or the snap path)
4. Secretive (`~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh`)
5. KeePassXC (`~/Library/Application Support/KeePassXC/sshagent.sock` or `~/.keepassxc/sshagent.sock`)
6. gnome-keyring (`$XDG_RUNTIME_DIR/keyring/ssh`)
7. Docker Desktop / OrbStack synth (`/run/host-services/ssh-auth.sock`) — macOS, launchd-only

Per-agent notes:

- **1Password (macOS + Linux)**: enable the SSH agent under *1Password → Settings → Developer → Use the SSH agent*. Auto-detected afterward.
- **Secretive**: install, add keys, ensure the agent is running. Auto-detected.
- **KeePassXC**: enable *Tools → Settings → SSH Agent → Enable SSH Agent integration* and open your database. Auto-detected.
- **Default macOS launchd agent** (ssh-add stores keys in the Keychain): works out of the box via the synth path fallback.
- **gnome-keyring / plain ssh-agent on Linux**: works via `$SSH_AUTH_SOCK` or the XDG runtime path.
- **Something exotic / unusual path**: set `SSH_AGENT_HOST_SOCK=/your/socket/path` in `.env`.

Inside a session, run `ssh-add -L` to verify your keys are visible.

### Extra volumes (replacement for compose.d overlays)

Shared-container mode reads `compose.d/*.yml` files to extend the docker-compose config. Ephemeral mode doesn't go through compose, so overlays there are ignored. Two replacement mechanisms cover the common cases:

**Named volumes** — declare in `.env`:

```sh
EXTRA_VOLUMES="rust-target:/Users/you/Documents/code/optimism/rust/target"
```

Comma-separated `volume:path` pairs. Each becomes `--mount type=volume,src=...,dst=...` on every session, letting `cargo` (with sccache on top) reuse compilation artefacts across sessions.

**Init scripts** — drop `*.sh` files into `files/init.d/`. They run as root at container start, before the user command. See `files/init.d/README.md` for conventions and `files/init.d/rust-cache.sh.example` for the typical "chown a freshly-created named-volume mount" pattern.

### Attaching a second terminal

Shared-container mode lets you `ssh localhost -p 2222` from any terminal. Ephemeral mode replaces that with `be-attach`:

```sh
./be-attach                    # attach to the single running session, or prompt
./be-attach claude-session-17  # attach by name / pattern
./be-attach -c "ps aux"        # run a one-shot command
```

### Cleanup

Session containers are `--rm`, so they clean up on exit. The state that accrues:

- **Staging dirs under `.mount-stage/session-*/`** when a session is SIGKILL'd before its trap runs. `./stop.sh` reaps these automatically.
- **Named volumes** (`claude-docker-build-cache`, `claude-docker-mise-installs`). These are intentional — they share caches across sessions.

To reclaim volume space:

```sh
./run.sh gc            # dry run — prints what would be removed
./run.sh gc --apply    # actually remove volumes that no container is using
```

`gc` never removes a volume a container (running or stopped) references.

## Configuration

All configuration lives in `.env` (gitignored). Copy `.env.example` to get started.

| Variable | Default | Description |
|---|---|---|
| `CODE_PATH` | *(required)* | Absolute path to your code directory on the host |
| `SSH_AUTHORIZED_KEYS` | ssh-agent keys | SSH public key(s) allowed into the container (shared mode only) |
| `SSH_PORT` | `2222` | Host port mapped to the container's SSH server (shared mode only) |
| `USE_MOSH` | `false` | Use mosh instead of SSH (requires mosh on host; shared mode only) |
| `MOSH_PORT` | `60001` | Host port for mosh (UDP, shared mode only) |
| `COMPOSE_PROJECT_NAME` | `claude-dev` | Shared-container name — override to run multiple instances |
| `CLAUDE_ARGS` | *(empty)* | Default arguments passed to claude (e.g. `--dangerously-skip-permissions`) |
| `FORWARD_ENVS` | *(empty)* | Space-separated list of env var names to forward into the container |
| `CLAUDE_CREDENTIAL_SYNC` | `true` | Disable with `false` to skip automatic credential sync |
| `CODEX_ARGS` | *(empty)* | Default arguments passed to codex (e.g. `--full-auto`) |
| `CODEX_SANDBOX` | `danger-full-access` | Codex sandbox mode — bubblewrap can't create namespaces inside Docker, so sandboxed modes require `--privileged` |
| `EXTRA_PACKAGES` | *(empty)* | Additional apt packages to install in the container |
| `EPHEMERAL_SESSIONS` | `false` | Run each `be-*` in its own container. See [Ephemeral mode](#ephemeral-mode). |
| `SSH_AGENT_HOST_SOCK` | *(auto)* | Override the auto-detected ssh-agent socket path (ephemeral mode) |
| `EXTRA_VOLUMES` | *(empty)* | Named volumes to add to every ephemeral session, comma-separated `name:path` |

## Credential sync

Claude Code authenticates via OAuth. On macOS, logging in through Claude Desktop or Claude Code stores the OAuth token in the system Keychain. The container can't access the Keychain directly, so without credential sync you'd need to log in separately inside the container.

`be-claude` solves this by automatically reading credentials from the macOS Keychain before each session and injecting them into the container. After the session ends, if the container refreshed the token, `be-claude` updates the Keychain so native Claude picks it up. This means you can:

- **Log in once on macOS** (via Claude Desktop or `claude` on the command line) and have that login automatically work inside the container
- **Log in inside the container** and have the token sync back to the Keychain for native use

On non-macOS hosts, the credentials file (`~/.claude/.credentials.json`) is the single source of truth — the container reads and writes it directly via bind mount.

To disable syncing, set `CLAUDE_CREDENTIAL_SYNC=false` in `.env`.

## Custom compose overlays (shared-container mode only)

Drop `.yml` files into `compose.d/` to extend the Docker Compose configuration. All files are automatically included by `run.sh` when `EPHEMERAL_SESSIONS=false`. The directory is gitignored so overlays stay local.

```yaml
# compose.d/rust-cache.yml (shared-container mode)
volumes:
  rust-target:
services:
  claude-dev:
    volumes:
      - rust-target:/Users/you/code/project/rust/target
      - ./compose.d/rust-cache.init.sh:/etc/claude-docker/init.d/rust-cache.sh:ro
```

In ephemeral mode, use [`EXTRA_VOLUMES` + `files/init.d/`](#extra-volumes-replacement-for-composed-overlays) instead.

### Init scripts (both modes)

Named volumes are created by Docker as root, so they may need ownership fixed before the non-root user can write to them. The entrypoint sources any `*.sh` scripts found in `/etc/claude-docker/init.d/`:

- **Shared-container mode**: overlays bind-mount individual init scripts into that path.
- **Ephemeral mode**: `files/init.d/*.sh` on the host is bind-mounted to that path.

The `APP_USER` environment variable is set to the host username for use in init scripts.

## Custom CA certificates

Drop `.crt` files into the `certs/` directory and rebuild. They are installed into the container's trust store automatically.

The `certs/` directory is gitignored so certificates stay local.

## What gets mounted

| Host path | Container path | Mode |
|---|---|---|
| `$CODE_PATH` | `$CODE_PATH` | read/write |
| `~/.claude` | `~/.claude` | read/write |
| `~/.claude.json` | `~/.claude.json` | read/write (via directory staging) |
| `~/.codex` | `~/.codex` | read/write |
| `~/.gitconfig` | `~/.gitconfig` | read-only |
| `~/.gitignore` | `~/.gitignore` | read-only |
| `~/.local/state/mise/trusted-configs` | `~/.local/state/mise/host-trusted-configs` | read-only |
| `~/.local/state/mise/tracked-configs` | `~/.local/state/mise/host-tracked-configs` | read-only |
| ssh-agent socket | `/ssh-agent` | read/write (ephemeral mode, auto-selected) |

## Persistent volumes

Named Docker volumes preserve data across container rebuilds.

| Volume | Mounted at | Contents | Mode |
|---|---|---|---|
| `ssh-host-keys` | `/etc/ssh` | SSH host keys | shared only |
| `build-cache` | `~/.cache` | Go build/module cache, Cargo registry, Foundry, solc, bun install cache | shared only |
| `claude-docker-build-cache` | `~/.cache` | same contents, separate volume namespace | ephemeral |
| `claude-docker-mise-installs` | `~/.local/share/mise` | mise tool installs | ephemeral |
| anything in `EXTRA_VOLUMES` | as configured | user-declared | ephemeral |

Environment variables redirect tool caches into `~/.cache` so a single volume covers most tools:

- `GOMODCACHE` → `~/.cache/go-mod`
- `CARGO_HOME` → `~/.cache/cargo`
- `SVM_HOME` → `~/.cache/svm`
- Foundry, mise, bun use `~/.cache` by default (XDG convention)

## Pre-installed tools

git, gh, go, gopls, node, npm, [bun](https://bun.sh), [codex](https://github.com/openai/codex), mise, mosh, tmux, vim, zsh, fzf, ripgrep, diff-so-fancy, jq, make, gpg, [tuicr](https://github.com/agavra/tuicr), iTerm2 utilities

## SSH agent forwarding

- **Shared-container mode**: `be-claude` connects with `ssh -A`, so your host keys are available inside. Git commit signing is configured automatically via `files/setupGitSigning.sh` when agent keys are present.
- **Ephemeral mode**: the host agent socket is bind-mounted directly. Auto-detection covers 1Password / Secretive / KeePassXC / gnome-keyring / `$SSH_AUTH_SOCK` / macOS launchd. See [First-run: pick your ssh-agent](#first-run-pick-your-ssh-agent) above and run `./run.sh ssh-agent-check` to see which one will be used.
