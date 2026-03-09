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

# Stage a file for mounting: hard link to resolve symlinks (Docker Desktop can't
# follow symlinks to paths outside its allowed directories, e.g. /nix/store).
# Falls back to cp -L if hard linking fails (cross-filesystem).
stage_file() {
    local src="$1" dest="$2"
    if [ -L "$src" ]; then
        local resolved
        resolved="$(readlink -f "$src")"
        ln -f "$resolved" "$dest" 2>/dev/null || cp -L "$src" "$dest"
    else
        ln -f "$src" "$dest" 2>/dev/null || cp -L "$src" "$dest"
    fi
}

MOUNT_STAGE="$SCRIPT_DIR/.mount-stage"
rm -rf "$MOUNT_STAGE"
mkdir -p "$MOUNT_STAGE"

COMPOSE_FILES="-f docker-compose.yml"

# Built-in modules (conditional on host state)
if [ -f "$HOME/.gitconfig" ]; then
    stage_file "$HOME/.gitconfig" "$MOUNT_STAGE/.gitconfig"
    export GITCONFIG_PATH="$MOUNT_STAGE/.gitconfig"
    COMPOSE_FILES="$COMPOSE_FILES -f modules/gitconfig.yml"
fi
if [ -f "$HOME/.gitignore" ]; then
    stage_file "$HOME/.gitignore" "$MOUNT_STAGE/.gitignore"
    export GITIGNORE_PATH="$MOUNT_STAGE/.gitignore"
    COMPOSE_FILES="$COMPOSE_FILES -f modules/gitignore.yml"
fi
[ -d "$HOME/.local/state/mise" ] && COMPOSE_FILES="$COMPOSE_FILES -f modules/mise.yml"

# User-provided compose overlays
for f in "$SCRIPT_DIR"/compose.d/*.yml; do
    [ -f "$f" ] && COMPOSE_FILES="$COMPOSE_FILES -f $f"
done

docker compose $COMPOSE_FILES up -d --build
