#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/compose-files.sh"

# Load .env so we can inspect SSH_AUTHORIZED_KEYS / EPHEMERAL_SESSIONS
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

# In shared-container mode we need SSH keys; in ephemeral mode we use
# SSH_AUTH_SOCK forwarding instead so authorized_keys can be a dummy.
if [[ "${EPHEMERAL_SESSIONS:-false}" != "true" ]]; then
    if [ -z "${SSH_AUTHORIZED_KEYS:-}" ]; then
        if ! ssh-add -l >/dev/null 2>&1; then
            echo "Error: SSH_AUTHORIZED_KEYS is not set in .env and no keys are loaded in ssh-agent." >&2
            echo "Either add SSH_AUTHORIZED_KEYS=\"...\" to .env or load a key with: ssh-add <your-key>" >&2
            exit 1
        fi
        SSH_AUTHORIZED_KEYS=$(ssh-add -L)
    fi
    export SSH_AUTHORIZED_KEYS
else
    # Provide a placeholder so the Dockerfile ARG is satisfied. The resulting
    # sshd isn't used in ephemeral mode anyway.
    export SSH_AUTHORIZED_KEYS="${SSH_AUTHORIZED_KEYS:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA unused@ephemeral}"
fi

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

if [[ "${EPHEMERAL_SESSIONS:-false}" == "true" ]]; then
    # Ephemeral mode: build the image only. Containers are spawned on demand
    # by be-claude / be-codex / be-shell / be-exec via lib/run-ephemeral.sh.
    # Already-running session containers keep using the image they started
    # from; new sessions pick up this build automatically.
    echo "Building ephemeral-session image..."
    docker build \
        --build-arg "CODE_PATH=$CODE_PATH" \
        --build-arg "USERNAME=$USER" \
        --build-arg "USER_HOME=$HOME" \
        --build-arg "SSH_AUTHORIZED_KEYS=$SSH_AUTHORIZED_KEYS" \
        --build-arg "EXTRA_PACKAGES=${EXTRA_PACKAGES:-}" \
        --build-arg "EXTRA_NPM_PACKAGES=${EXTRA_NPM_PACKAGES:-}" \
        -t "${EPHEMERAL_IMAGE:-claude-docker:latest}" \
        "$SCRIPT_DIR"
    echo
    echo "Image built. Run ./be-claude or ./be-shell to start a session."
    exit 0
fi

# Shared-container mode: compose up --build.
build_compose_file_args

# Stage .claude.json into a directory mount to avoid Docker single-file bind
# mount corruption.  When Claude Code does an atomic write (write-tmp + rename)
# on the host, a file-level bind mount loses track of the new inode and the
# container sees stale / truncated data.  A directory mount handles this correctly.
mkdir -p "$SCRIPT_DIR/.mount-stage"
cp "$HOME/.claude.json" "$SCRIPT_DIR/.mount-stage/.claude.json" 2>/dev/null || true

docker compose "${COMPOSE_FILE_ARGS[@]}" up -d --build
