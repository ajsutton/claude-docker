#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/compose-files.sh"

# Load .env so we can inspect SSH_AUTHORIZED_KEYS
if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
fi

# Validate CODE_PATH
if [ -z "${CODE_PATH:-}" ]; then
    echo "Error: CODE_PATH is not set. Set it in .env to the directory you want mounted in the container." >&2
    exit 1
fi
if [ ! -d "$CODE_PATH" ]; then
    echo "Error: CODE_PATH=$CODE_PATH does not exist. Update it in .env to point to an existing directory." >&2
    exit 1
fi

# Default SSH_AUTHORIZED_KEYS to the host ssh-agent's loaded keys
if [ -z "${SSH_AUTHORIZED_KEYS:-}" ]; then
    if ! ssh-add -l >/dev/null 2>&1; then
        echo "Error: SSH_AUTHORIZED_KEYS is not set in .env and no keys are loaded in ssh-agent." >&2
        echo "Either add SSH_AUTHORIZED_KEYS=\"...\" to .env or load a key with: ssh-add <your-key>" >&2
        exit 1
    fi
    SSH_AUTHORIZED_KEYS=$(ssh-add -L)
fi

export SSH_AUTHORIZED_KEYS

# Detect host timezone so the container matches
if [ -z "${TZ:-}" ]; then
    if [ -L /etc/localtime ]; then
        # macOS: /var/db/timezone/zoneinfo/<tz>, Linux: /usr/share/zoneinfo/<tz>
        TZ=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')
    elif [ -f /etc/timezone ]; then
        TZ=$(cat /etc/timezone)
    fi
fi
export TZ="${TZ:-UTC}"

build_compose_file_args

# Stage .claude.json into a directory mount to avoid Docker single-file bind
# mount corruption.  When Claude Code does an atomic write (write-tmp + rename)
# on the host, a file-level bind mount loses track of the new inode and the
# container sees stale / truncated data.  A directory mount handles this correctly.
mkdir -p "$SCRIPT_DIR/.mount-stage"
cp "$HOME/.claude.json" "$SCRIPT_DIR/.mount-stage/.claude.json" 2>/dev/null || true

docker compose "${COMPOSE_FILE_ARGS[@]}" up -d --build
