#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load .env so we can inspect SSH_AUTHORIZED_KEYS
if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
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

# Resolve symlinks by copying to a staging dir that Docker Desktop can mount
MOUNT_STAGE="$SCRIPT_DIR/.mount-stage"
rm -rf "$MOUNT_STAGE"
mkdir -p "$MOUNT_STAGE"

COMPOSE_FILES="-f docker-compose.yml"
if [ -f "$HOME/.gitconfig" ]; then
    cp -L "$HOME/.gitconfig" "$MOUNT_STAGE/.gitconfig"
    export GITCONFIG_PATH="$MOUNT_STAGE/.gitconfig"
    COMPOSE_FILES="$COMPOSE_FILES -f compose.d/gitconfig.yml"
fi
if [ -f "$HOME/.gitignore" ]; then
    cp -L "$HOME/.gitignore" "$MOUNT_STAGE/.gitignore"
    export GITIGNORE_PATH="$MOUNT_STAGE/.gitignore"
    COMPOSE_FILES="$COMPOSE_FILES -f compose.d/gitignore.yml"
fi
[ -d "$HOME/.local/state/mise" ] && COMPOSE_FILES="$COMPOSE_FILES -f compose.d/mise.yml"

docker compose $COMPOSE_FILES up -d --build
