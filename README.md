# claude-docker

A Docker-based development environment for running [Claude Code](https://claude.ai/claude-code) in an isolated container. The container runs an SSH server so you can connect to it from your terminal or editor as if it were a remote machine.

Your local code directory is mounted at the same path inside the container, so file paths are identical on both sides — no translation needed.

## How it works

- An Ubuntu container runs `sshd` on port 2222
- Your code directory is bind-mounted at the same path inside the container
- `be-claude` is a helper script that SSHs into the container and launches Claude Code in the directory matching your current working directory

## Setup

### 1. Create your `.env` file

Copy the example and fill in your values:

```sh
cp .env.example .env
```

Edit `.env` and fill in at minimum `CODE_PATH` and `SSH_AUTHORIZED_KEYS`:

```sh
# Path to your local code directory
CODE_PATH=/Users/yourname/Documents/code

# Your SSH public key (for SSHing into the container)
SSH_AUTHORIZED_KEYS="ssh-ed25519 AAAA...your_key_here... user@host"
```

You can get your public key with:

```sh
cat ~/.ssh/id_ed25519.pub
```

### 2. Build and start the container

```sh
./run.sh
```

This runs `docker compose up -d --build`.

### 3. Use Claude Code

From any directory inside your `CODE_PATH`, run:

```sh
./be-claude
```

This SSHs into the container and launches Claude Code in the equivalent directory.

`be-claude` will use `GH_TOKEN` from your environment if set, otherwise it falls back to `gh auth token` (the [GitHub CLI](https://cli.github.com/)).

## Configuration

All user-specific configuration lives in `.env` (not committed to git). See `.env.example` for available options.

| Variable | Description |
|---|---|
| `CODE_PATH` | Absolute path to your code directory on the host |
| `SSH_AUTHORIZED_KEYS` | SSH public key(s) allowed into the container |
| `SSH_PORT` | Host port mapped to SSH inside the container (default: `2222`) |
| `COMPOSE_PROJECT_NAME` | Container name; override to run multiple instances (default: `claude-dev`) |

## Custom CA certificates

If your network requires custom root CA certificates (e.g., for corporate proxies or internal domains), drop `.crt` files into the `certs/` directory. They will be installed into the container's trust store on the next build.

The `certs/` directory is gitignored, so your certificates stay local and are never committed.

## Mounted paths

These paths from your host are mounted into the container:

| Path | Description |
|---|---|
| `$CODE_PATH` | Your code directory (read/write) |
| `~/.claude` | Claude config and data |
| `~/.claude.json` | Claude auth |
| `~/.gitconfig` | Git config (read-only) |
| `~/.gitignore` | Global gitignore (read-only) |

SSH host keys are preserved across container rebuilds in a named Docker volume.
