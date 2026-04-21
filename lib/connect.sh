#!/bin/bash
# Shared connection logic for be-claude / be-codex / be-shell / be-exec.
# Expects SCRIPT_DIR to be set by the caller.
# Sets up env forwarding and defines run_remote().
#
# Two execution modes:
#   EPHEMERAL_SESSIONS=true  -> each be-* call runs a fresh container
#   EPHEMERAL_SESSIONS=false -> SSH into the long-running shared container
# The default is the shared-container path for backwards compatibility.

set -euo pipefail

# Load config
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "Error: $SCRIPT_DIR/.env not found. Copy .env.example to .env and configure it." >&2
    exit 1
fi
source "$SCRIPT_DIR/.env"

# Reconcile Claude OAuth credentials between Keychain and ~/.claude/ on macOS
# hosts. The container sees ~/.claude/.credentials.json directly via the bind
# mount, so no env-var forwarding is needed. Skipped in ephemeral mode —
# run_ephemeral_exec handles pre- and post-session sync itself.
if [[ "${EPHEMERAL_SESSIONS:-false}" != "true" ]] && [[ "${SKIP_CLAUDE_CREDS:-}" != "1" ]]; then
    "$SCRIPT_DIR/files/sync-claude-credentials" sync || true
fi

full=$(pwd)
base=${CODE_PATH:-}
if [[ -n "$base" && "$full" == "$base"* ]]; then
    prep="cd $full; "
else
    prep=""
fi

if [[ "${EPHEMERAL_SESSIONS:-false}" == "true" ]]; then
    # Ephemeral path: each session gets its own container.
    source "$SCRIPT_DIR/lib/run-ephemeral.sh"

    run_remote() {
        local remote_cmd="${prep}$1"
        local exit_code=0
        run_ephemeral_exec "$remote_cmd" || exit_code=$?
        exit "${exit_code:-0}"
    }
else
    # Shared-container path: SSH into the running claude-dev container.
    iterm_opts=()
    if [[ -n "${ITERM_SESSION_ID:-}" ]]; then
        iterm_opts=(-o "SendEnv=ITERM_SESSION_ID")
    fi

    # Forward env vars via SSH SendEnv with FORWARD_ prefix. 00-forward-env.sh
    # (in .zshrc.d) strips the prefix during shell init so all processes see
    # the real names.
    send_env_opts=()
    for key in TERM_PROGRAM ${FORWARD_ENVS:-}; do
        [[ -z "${!key:-}" ]] && continue
        export "FORWARD_${key}=${!key}"
        send_env_opts+=(-o "SendEnv=FORWARD_${key}")
    done

    ssh_port="${SSH_PORT:-2222}"
    mosh_port="${MOSH_PORT:-60001}"

    run_remote() {
        local remote_cmd="${prep}$1"
        local exit_code=0

        local ssh_cmd="ssh -p ${ssh_port} ${send_env_opts[*]} ${iterm_opts[*]}"

        if [[ "${USE_MOSH:-false}" == "true" ]] && command -v mosh &>/dev/null; then
            mosh --ssh="$ssh_cmd" -p "$mosh_port" localhost -- zsh -c "$remote_cmd" || exit_code=$?
        else
            ssh -A -t -p "${ssh_port}" ${send_env_opts[@]+"${send_env_opts[@]}"} ${iterm_opts[@]+"${iterm_opts[@]}"} localhost "$remote_cmd" || exit_code=$?
        fi

        # Post-session: reconcile any token refresh done inside the container
        # back to the host Keychain.
        if [[ "${SKIP_CLAUDE_CREDS:-}" != "1" ]]; then
            "$SCRIPT_DIR/files/sync-claude-credentials" sync || true
        fi

        exit "${exit_code:-0}"
    }
fi
