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

Edit `.env`:

```sh
# Path to your local code directory
CODE_PATH=/Users/yourname/Documents/code

# Anthropic API key
ANTHROPIC_API_KEY=sk-ant-...
```

### 2. Add your SSH public key

Place your public key in `files/authorized_keys` so you can SSH into the container:

```sh
cp ~/.ssh/id_ed25519.pub files/authorized_keys
```

### 3. Build and start the container

```sh
./run.sh
```

This runs `docker compose up -d --build`.

### 4. Use Claude Code

From any directory inside your `CODE_PATH`, run:

```sh
./be-claude
```

This SSHs into the container and launches Claude Code in the equivalent directory.

## Configuration

All user-specific configuration lives in `.env` (not committed to git). See `.env.example` for available options.

| Variable | Description |
|---|---|
| `CODE_PATH` | Absolute path to your code directory on the host |
| `ANTHROPIC_API_KEY` | Your Anthropic API key |

## Persisted data

| Path | Description |
|---|---|
| `data/home/` | The container user's home directory |
| `data/ssh/` | SSH host keys (preserved across rebuilds) |
| `~/.claude` | Claude config, mounted from the host |
