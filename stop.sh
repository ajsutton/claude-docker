#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/compose-files.sh"

if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
fi

if [[ "${EPHEMERAL_SESSIONS:-false}" == "true" ]]; then
    # Ephemeral mode: there is no long-running container. Stop any session
    # containers that happen to be running.
    running=$(docker ps -q --filter "name=^claude-session-")
    if [ -z "$running" ]; then
        echo "No active ephemeral sessions."
    else
        echo "Stopping active ephemeral sessions:"
        docker ps --filter "name=^claude-session-" --format 'table {{.Names}}\t{{.Status}}'
        echo "$running" | xargs docker stop
    fi

    # Reap orphan session staging dirs — these leak when a session is
    # SIGKILL'd before run_ephemeral_exec's cleanup can fire. Only remove
    # dirs whose matching container no longer exists.
    stage_root="$SCRIPT_DIR/.mount-stage"
    if [ -d "$stage_root" ]; then
        known="$(docker ps -a --filter "name=^claude-session-" --format '{{.Names}}' 2>/dev/null || true)"
        removed=0
        for dir in "$stage_root"/session-*; do
            [ -d "$dir" ] || continue
            container_name="$(basename "$dir")"
            container_name="${container_name#session-}"
            if ! printf '%s\n' "$known" | grep -qx "$container_name"; then
                rm -rf "$dir"
                removed=$((removed + 1))
            fi
        done
        if [ "$removed" -gt 0 ]; then
            echo "Reaped $removed orphan staging dir(s) in $stage_root."
        fi
    fi
    exit 0
fi

build_compose_file_args

docker compose "${COMPOSE_FILE_ARGS[@]}" down
