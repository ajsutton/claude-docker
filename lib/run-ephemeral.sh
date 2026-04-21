#!/bin/bash
# Ephemeral per-session container launcher.
#
# Each invocation of be-claude / be-codex / be-shell / be-exec calls
# run_ephemeral_exec() to start a fresh container from the current image,
# execute the agent command, and tear the container down on exit.
#
# Concurrent sessions each get their own container — rebuilding the image
# (./run.sh) does not disturb already-running sessions; the next session
# starts from the new image.
#
# Caches are shared across containers via named Docker volumes (see
# docs/ephemeral-sessions.md for the per-tool concurrency analysis).
#
# Requires SCRIPT_DIR to be set by the caller.

set -euo pipefail

# Auto-detection of the host ssh-agent socket lives in a separate lib so
# it's easy to test in isolation. See lib/ssh-agent-detect.sh.
source "$SCRIPT_DIR/lib/ssh-agent-detect.sh"

# The image tag built by ./run.sh in ephemeral mode.
EPHEMERAL_IMAGE="${EPHEMERAL_IMAGE:-claude-docker:latest}"

# Named volumes shared across sessions. They are created lazily by docker
# the first time a session starts.
CACHE_VOLUME="${CACHE_VOLUME_NAME:-claude-docker-build-cache}"
MISE_VOLUME="${MISE_VOLUME_NAME:-claude-docker-mise-installs}"

# Resolve a symlinked dotfile to a concrete path the way compose-files.sh does,
# so Docker Desktop can bind-mount it even when the source lives in the Nix
# store or a Home Manager profile.
_resolve_mount_path_ephemeral() {
    local src="$1" name="$2"
    if [ -L "$src" ]; then
        local resolved mount_stage="$SCRIPT_DIR/.mount-stage"
        mkdir -p "$mount_stage"
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

# Each session gets a unique container name so `docker ps` is readable and
# leaked containers are easy to spot. --rm still handles cleanup on exit.
_ephemeral_container_name() {
    local rand
    rand="$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    echo "claude-session-$(date +%s)-$$-${rand}"
}

# Append the right ssh-agent flags to EPH_RUN_ARGS via lib/ssh-agent-detect.sh.
# Announces which agent was selected so the user sees it before the session
# starts. Emits a clear warning with the full list of supported agents if
# detection fails, so the fix is obvious.
_configure_ssh_agent_forwarding() {
    local container_sock="/ssh-agent"
    local result label host_sock

    if result="$(detect_ssh_agent)"; then
        label="${result%%	*}"
        host_sock="${result#*	}"
        echo "[claude-docker] ssh-agent: $label ($host_sock)" >&2
        EPH_RUN_ARGS+=(
            -v "${host_sock}:${container_sock}"
            -e "SSH_AUTH_SOCK=${container_sock}"
        )
        return
    fi

    echo "Warning: no ssh-agent detected. git push over ssh and commit" >&2
    echo "         signing will not work inside the session." >&2
    describe_ssh_agent_options >&2
}

# Populate EPH_RUN_ARGS and EPH_STAGE_DIR from the current environment.
# EPH_CONTAINER_NAME must already be set.
_build_ephemeral_run_args() {
    EPH_RUN_ARGS=(
        --rm
        --name "$EPH_CONTAINER_NAME"
        --hostname "claude-session"
        --workdir "$EPH_WORKDIR"
        # Run the entrypoint as root so it can chown freshly-created named
        # volume mounts. ephemeral-init.sh drops to APP_USER before exec'ing
        # the user command.
        --user "0:0"
        -e "APP_USER=$USER"
        -e "APP_HOME=$HOME"
        -e "TZ=${TZ:-UTC}"
        -e "GOMODCACHE=${HOME}/.cache/go-mod"
        -e "CARGO_HOME=${HOME}/.cache/cargo"
        -e "SVM_HOME=${HOME}/.cache/svm"
        # Interactive + TTY: required for terminal apps.
        -it
    )

    # Mount code directory at the same path so in-container paths match the
    # host. This is the core "feels native" property of claude-docker.
    EPH_RUN_ARGS+=(-v "${CODE_PATH}:${CODE_PATH}")

    # ~/.claude holds credentials + session history.
    EPH_RUN_ARGS+=(-v "${HOME}/.claude:${HOME}/.claude")

    # ~/.claude.json via a per-session staging dir. Docker's file-level bind
    # mounts break when the host does an atomic write (write-tmp + rename)
    # because the mount is pinned to the original inode. A directory mount
    # survives that. Each session gets its own stage so concurrent starts
    # don't clobber each other while copying.
    EPH_STAGE_DIR="$SCRIPT_DIR/.mount-stage/$EPH_CONTAINER_NAME"
    mkdir -p "$EPH_STAGE_DIR"
    cp "$HOME/.claude.json" "$EPH_STAGE_DIR/.claude.json" 2>/dev/null || true
    EPH_RUN_ARGS+=(-v "$EPH_STAGE_DIR:${HOME}/.claude-mount-stage")

    # Shared caches — the whole point of the design. See
    # docs/ephemeral-sessions.md for the per-tool concurrency analysis.
    EPH_RUN_ARGS+=(--mount "type=volume,src=${CACHE_VOLUME},dst=${HOME}/.cache")

    # Forward user-designated env vars (FORWARD_ENVS in .env) with the same
    # FORWARD_ prefix the shared-container path uses, so 00-forward-env.sh
    # continues to un-prefix them inside the container.
    local key
    for key in TERM TERM_PROGRAM ITERM_SESSION_ID ${FORWARD_ENVS:-}; do
        [[ -z "${!key:-}" ]] && continue
        EPH_RUN_ARGS+=(-e "FORWARD_${key}=${!key}")
    done

    # SSH agent forwarding. Replaces `ssh -A` from the shared-container path.
    # Needed for: onward SSH (e.g. git push over ssh://) and container-side
    # git commit signing (see files/setupGitSigning.sh, which reads the first
    # key from `ssh-add -L`).
    #
    # Platform detection:
    #   Linux host          -> bind-mount $SSH_AUTH_SOCK directly
    #   Docker Desktop/macOS-> use the synthesized /run/host-services/ssh-auth.sock
    #   OrbStack/macOS      -> same synthesized path (docs.orbstack.dev/docker/)
    # The user can override with SSH_AGENT_HOST_SOCK in .env, e.g. to point
    # at 1Password's agent socket or the OrbStack legacy path
    # /opt/orbstack-guest/run/host-ssh-agent.sock for third-party agents.
    _configure_ssh_agent_forwarding


    # Optional bind mounts, mirroring compose-files.sh.
    if [ -f "$HOME/.gitconfig" ]; then
        local gc
        gc="$(_resolve_mount_path_ephemeral "$HOME/.gitconfig" .gitconfig)"
        EPH_RUN_ARGS+=(-v "${gc}:${HOME}/.gitconfig:ro")
    fi
    if [ -f "$HOME/.gitignore" ]; then
        local gi
        gi="$(_resolve_mount_path_ephemeral "$HOME/.gitignore" .gitignore)"
        EPH_RUN_ARGS+=(-v "${gi}:${HOME}/.gitignore:ro")
    fi
    if [ -d "$HOME/.local/state/mise" ]; then
        EPH_RUN_ARGS+=(
            -v "${HOME}/.local/state/mise/trusted-configs:${HOME}/.local/state/mise/host-trusted-configs:ro"
            -v "${HOME}/.local/state/mise/tracked-configs:${HOME}/.local/state/mise/host-tracked-configs:ro"
            --mount "type=volume,src=${MISE_VOLUME},dst=${HOME}/.local/share/mise"
        )
    fi

    # Codex login state — always mount; create dir if missing so Docker
    # doesn't create it as root.
    mkdir -p "$HOME/.codex"
    EPH_RUN_ARGS+=(-v "${HOME}/.codex:${HOME}/.codex")

    # Init scripts from files/init.d/ for ephemeral sessions. Compose
    # overlays bind individual scripts; in ephemeral mode we just mount the
    # directory if it exists.
    if [ -d "$SCRIPT_DIR/files/init.d" ]; then
        EPH_RUN_ARGS+=(-v "$SCRIPT_DIR/files/init.d:/etc/claude-docker/init.d:ro")
    fi
}

# run_ephemeral_exec <remote_command>
# Starts a fresh container, runs the command, cleans up on exit.
run_ephemeral_exec() {
    local remote_cmd="$1"

    EPH_WORKDIR="$(pwd)"
    # If cwd is outside CODE_PATH the bind mount won't cover it; fall back
    # to $HOME to match the shared-container behaviour.
    if [[ "$EPH_WORKDIR" != "$CODE_PATH"* ]]; then
        EPH_WORKDIR="$HOME"
    fi

    local EPH_CONTAINER_NAME
    EPH_CONTAINER_NAME="$(_ephemeral_container_name)"
    local EPH_STAGE_DIR=""
    local EPH_RUN_ARGS=()
    _build_ephemeral_run_args

    if ! docker image inspect "$EPHEMERAL_IMAGE" >/dev/null 2>&1; then
        echo "Error: image '$EPHEMERAL_IMAGE' not found. Run ./run.sh first." >&2
        exit 1
    fi

    # Before the session: reconcile Claude credentials (same as connect.sh).
    if [[ "${SKIP_CLAUDE_CREDS:-}" != "1" ]]; then
        "$SCRIPT_DIR/files/sync-claude-credentials" sync || true
    fi

    # Export the remote command so the in-container init script can see it.
    EPH_RUN_ARGS+=(-e "EPHEMERAL_USER_CMD=$remote_cmd")

    local exit_code=0
    docker run "${EPH_RUN_ARGS[@]}" "$EPHEMERAL_IMAGE" \
        /usr/local/bin/ephemeral-init.sh || exit_code=$?

    # Clean up this session's staging dir.
    [ -n "$EPH_STAGE_DIR" ] && rm -rf "$EPH_STAGE_DIR" 2>/dev/null || true

    # After the session: sync back any refreshed token (same as connect.sh).
    if [[ "${SKIP_CLAUDE_CREDS:-}" != "1" ]]; then
        "$SCRIPT_DIR/files/sync-claude-credentials" sync || true
    fi

    return "${exit_code:-0}"
}
