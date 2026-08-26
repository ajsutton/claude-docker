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
et_iterm_opts=()
if [[ -n "${ITERM_SESSION_ID:-}" ]]; then
    iterm_opts=(-o "SendEnv=ITERM_SESSION_ID")
    et_iterm_opts=(--ssh-option "SendEnv=ITERM_SESSION_ID")
fi

# Forward env vars into the container via SSH SendEnv with FORWARD_ prefix.
# 00-forward-env.sh (in .zshrc.d) strips the prefix during shell init so all
# processes see the real names.
# et forwards them the same way: --ssh-option is handed straight to `ssh -o`,
# and et runs etterminal over that ssh session, so the pty inherits the values.
send_env_opts=()
et_send_env_opts=()
for key in TERM_PROGRAM ${FORWARD_ENVS:-}; do
    [[ -z "${!key:-}" ]] && continue
    export "FORWARD_${key}=${!key}"
    send_env_opts+=(-o "SendEnv=FORWARD_${key}")
    et_send_env_opts+=(--ssh-option "SendEnv=FORWARD_${key}")
done

ssh_port="${SSH_PORT:-2222}"
et_port="${ET_PORT:-2022}"

ssh_extra_opts=()
et_extra_opts=()
if [[ -n "${SSH_EXTRA_OPTS:-}" ]]; then
    # Word-split SSH_EXTRA_OPTS so users can pass multiple "-o key=value" pairs.
    read -ra ssh_extra_opts <<<"$SSH_EXTRA_OPTS"
    # Translate the same pairs into et's --ssh-option form.
    for ((i = 0; i < ${#ssh_extra_opts[@]}; i++)); do
        if [[ "${ssh_extra_opts[i]}" == "-o" && $((i + 1)) -lt ${#ssh_extra_opts[@]} ]]; then
            et_extra_opts+=(--ssh-option "${ssh_extra_opts[i + 1]}")
            i=$((i + 1))
        fi
    done
fi

# run_remote <remote_command>
# Connects via et or ssh and runs the given command.
run_remote() {
    local remote_cmd="${prep}$1"
    local exit_code=0

    if [[ "${USE_ET:-false}" == "true" ]] && command -v et &>/dev/null; then
        # et runs the login shell and then types the command into it, so the
        # command is not wrapped in an explicit shell invocation.
        # -f replaces ssh's -A for agent forwarding.
        et -f -c "$remote_cmd" \
            --ssh-option "Port=${ssh_port}" \
            ${et_extra_opts[@]+"${et_extra_opts[@]}"} \
            ${et_send_env_opts[@]+"${et_send_env_opts[@]}"} \
            ${et_iterm_opts[@]+"${et_iterm_opts[@]}"} \
            "localhost:${et_port}" || exit_code=$?
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
