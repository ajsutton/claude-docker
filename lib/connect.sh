#!/bin/bash
# Shared connection logic for the be-* launchers.
# Expects SCRIPT_DIR to be set by the caller.
# Sets up env forwarding and defines run_remote().

set -euo pipefail

# Load config
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "Error: $SCRIPT_DIR/.env not found. Copy .env.example to .env and configure it." >&2
    exit 1
fi
source "$SCRIPT_DIR/.env"

# Reconcile Claude OAuth credentials between Keychain and ~/.claude/ on macOS
# hosts. The container sees ~/.claude/.credentials.json directly via the bind
# mount, so no env-var forwarding is needed.
if [[ "${SKIP_CLAUDE_CREDS:-}" != "1" ]]; then
    "$SCRIPT_DIR/files/sync-claude-credentials" sync || true
fi

full=$(pwd)
base=$CODE_PATH
if [[ "$full" == "$base"* ]]; then
    prep="cd $full; "
else
    prep=""
fi
iterm_opts=()
if [[ -n "${ITERM_SESSION_ID:-}" ]]; then
    iterm_opts=(-o "SendEnv=ITERM_SESSION_ID")
fi

# Forward env vars into the container via SSH SendEnv with FORWARD_ prefix.
# 00-forward-env.sh (in .zshrc.d) strips the prefix during shell init so all
# processes see the real names.
send_env_opts=()
for key in TERM_PROGRAM ${FORWARD_ENVS:-}; do
    [[ -z "${!key:-}" ]] && continue
    export "FORWARD_${key}=${!key}"
    send_env_opts+=(-o "SendEnv=FORWARD_${key}")
done

ssh_port="${SSH_PORT:-2222}"
mosh_port="${MOSH_PORT:-60001}"

ssh_extra_opts=()
if [[ -n "${SSH_EXTRA_OPTS:-}" ]]; then
    # Word-split SSH_EXTRA_OPTS so users can pass multiple "-o key=value" pairs.
    read -ra ssh_extra_opts <<<"$SSH_EXTRA_OPTS"
fi

# run_remote <remote_command>
# Connects via mosh or ssh and runs the given command.
run_remote() {
    local remote_cmd="${prep}$1"
    local exit_code=0

    local ssh_cmd="ssh -p ${ssh_port} ${ssh_extra_opts[*]} ${send_env_opts[*]} ${iterm_opts[*]}"

    if [[ "${USE_MOSH:-false}" == "true" ]] && command -v mosh &>/dev/null; then
        mosh --ssh="$ssh_cmd" -p "$mosh_port" localhost -- zsh -c "$remote_cmd" || exit_code=$?
    else
        ssh -A -t -p "${ssh_port}" ${ssh_extra_opts[@]+"${ssh_extra_opts[@]}"} ${send_env_opts[@]+"${send_env_opts[@]}"} ${iterm_opts[@]+"${iterm_opts[@]}"} localhost "$remote_cmd" || exit_code=$?
    fi

    # Post-session: reconcile any token refresh done inside the container back
    # to the host Keychain.
    if [[ "${SKIP_CLAUDE_CREDS:-}" != "1" ]]; then
        "$SCRIPT_DIR/files/sync-claude-credentials" sync || true
    fi

    exit "${exit_code:-0}"
}
