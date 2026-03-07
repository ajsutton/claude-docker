# claude-docker

Run [Claude Code](https://claude.ai/claude-code) in an isolated Docker container. The container mirrors your local environment — same username, same file paths, same git config — so you can work as if Claude is running natively.

> **Note:** This container provides encapsulation, not a security sandbox. Claude has read/write access to your mounted code directory, your git and Claude configs, a GitHub token, and unrestricted internet access. Treat it as a convenience layer for keeping your host system clean, not as a trust boundary.

## Quick start

```sh
cp .env.example .env
# Edit .env — set CODE_PATH to your code directory
./run.sh
./be-claude
```

That's it. `run.sh` builds and starts the container, `be-claude` SSHs in and launches Claude Code in your current directory.

If `SSH_AUTHORIZED_KEYS` isn't set in `.env`, `run.sh` automatically uses keys from your ssh-agent.

## How it works

An Ubuntu container runs an SSH server on port 2222. Your code directory is bind-mounted at the same path inside the container, so file references are identical on both sides. `be-claude` connects via SSH and starts Claude in the directory matching your current working directory on the host.

The container comes with Go, Node.js, Rust tooling, [mise](https://mise.run), [gopls](https://pkg.go.dev/golang.org/x/tools/gopls), git, gh, and other common development tools pre-installed.

## Usage

### be-claude

Run from anywhere inside your `CODE_PATH`:

```sh
./be-claude                    # launch Claude Code
./be-claude --resume           # pass arguments through to claude
```

`be-claude` can be symlinked onto your `PATH` for convenience — it resolves its own location to find `.env`.

A GitHub token is passed into the container automatically. It uses `GH_TOKEN` from your environment if set, otherwise it runs `gh auth token`.

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
| `COMPOSE_PROJECT_NAME` | `claude-dev` | Container name — override to run multiple instances |
| `CLAUDE_ARGS` | *(empty)* | Default arguments passed to claude (e.g. `--dangerously-skip-permissions`) |
| `EXTRA_PACKAGES` | *(empty)* | Additional apt packages to install in the container (e.g. `postgresql-client redis-tools`) |

## Custom CA certificates

Drop `.crt` files into the `certs/` directory and rebuild. They are installed into the container's trust store automatically.

The `certs/` directory is gitignored so certificates stay local.

## What gets mounted

| Host path | Container path | Mode |
|---|---|---|
| `$CODE_PATH` | `$CODE_PATH` | read/write |
| `~/.claude` | `~/.claude` | read/write |
| `~/.claude.json` | `~/.claude.json` | read/write |
| `~/.gitconfig` | `~/.gitconfig` | read-only |
| `~/.gitignore` | `~/.gitignore` | read-only |
| `~/.local/share/mise/trusted-configs` | `~/.local/share/mise/trusted-configs` | read-only |

## Persistent volumes

Named Docker volumes preserve data across container rebuilds:

| Volume | Mounted at | Contents |
|---|---|---|
| `ssh-host-keys` | `/etc/ssh` | SSH host keys (avoids host key warnings after rebuild) |
| `build-cache` | `~/.cache` | Go build/module cache, Cargo registry, Foundry cache, solc binaries, mise cache |

Environment variables redirect tool caches into `~/.cache` so a single volume covers everything:

- `GOMODCACHE` → `~/.cache/go-mod`
- `CARGO_HOME` → `~/.cache/cargo`
- `SVM_HOME` → `~/.cache/svm`
- Foundry and mise use `~/.cache` by default (XDG convention)

## Pre-installed tools

git, gh, go, gopls, node, npm, mise, tmux, vim, zsh, fzf, ripgrep, diff-so-fancy, jq, make, gpg, iTerm2 utilities

## SSH agent forwarding

If you connect with SSH agent forwarding (`ssh -A`), your host SSH keys are available inside the container. Git commit signing is configured automatically via `setupGitSigning.sh` when agent keys are present.
