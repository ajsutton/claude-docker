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

# Resolve a symlink to a mountable path. For symlinked dotfiles (e.g. Nix Home
# Manager pointing into /nix/store), Docker Desktop can't follow the symlink.
# We hard link the resolved target into .mount-stage/ so Docker sees a local path
# that shares the same inode. Falls back to cp -L if hard linking fails (cross-fs).
# For non-symlinks, mounts the original file directly.
resolve_mount_path() {
    local src="$1" name="$2"
    if [ -L "$src" ]; then
        local resolved mount_stage="$SCRIPT_DIR/.mount-stage"
        mkdir -p "$mount_stage"
        # python -c is portable across macOS and Linux (readlink -f is GNU-only)
        resolved="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$src")"
        local dest="$mount_stage/$name"
        if ln -f "$resolved" "$dest" 2>/dev/null || cp -L "$src" "$dest"; then
            echo "$dest"
        else
            echo "$src"
        fi
    else
        echo "$src"
    fi
}

COMPOSE_FILES="-f docker-compose.yml"

# Built-in modules (conditional on host state)
if [ -f "$HOME/.gitconfig" ]; then
    export GITCONFIG_PATH
    GITCONFIG_PATH="$(resolve_mount_path "$HOME/.gitconfig" .gitconfig)"
    COMPOSE_FILES="$COMPOSE_FILES -f modules/gitconfig.yml"
fi
if [ -f "$HOME/.gitignore" ]; then
    export GITIGNORE_PATH
    GITIGNORE_PATH="$(resolve_mount_path "$HOME/.gitignore" .gitignore)"
    COMPOSE_FILES="$COMPOSE_FILES -f modules/gitignore.yml"
fi
[ -d "$HOME/.local/state/mise" ] && COMPOSE_FILES="$COMPOSE_FILES -f modules/mise.yml"

# User-provided compose overlays
for f in "$SCRIPT_DIR"/compose.d/*.yml; do
    [ -f "$f" ] && COMPOSE_FILES="$COMPOSE_FILES -f $f"
done

docker compose $COMPOSE_FILES up -d --build
