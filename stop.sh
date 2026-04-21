#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/compose-files.sh"

if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
fi

if [[ "${EPHEMERAL_SESSIONS:-false}" == "true" ]]; then
    # Ephemeral mode: there is no long-running container. Stop any session
    # containers that happen to be running and be done.
    running=$(docker ps -q --filter "name=^claude-session-")
    if [ -z "$running" ]; then
        echo "No active ephemeral sessions."
    else
        echo "Stopping active ephemeral sessions:"
        docker ps --filter "name=^claude-session-" --format 'table {{.Names}}\t{{.Status}}'
        echo "$running" | xargs docker stop
    fi
    exit 0
fi

build_compose_file_args

docker compose "${COMPOSE_FILE_ARGS[@]}" down
