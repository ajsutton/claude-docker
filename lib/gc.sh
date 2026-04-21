#!/bin/bash
# ./run.sh gc [--apply]
#
# Garbage-collect claude-docker state:
#   1. Orphan .mount-stage/session-<name>/ dirs where the matching
#      container no longer exists in `docker ps -a`. These leak when a
#      session is SIGKILL'd (the trap in run_ephemeral_exec never fires).
#   2. Named volumes that hold the ephemeral build caches, if no
#      containers are currently using them. We never remove volumes that
#      active sessions depend on.
#
# Default is dry-run — nothing is deleted unless --apply is passed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APPLY=0
case "${1:-}" in
    --apply|-a) APPLY=1 ;;
    "")         ;;
    -h|--help)
        echo "Usage: ./run.sh gc [--apply]"
        echo "  Default: dry-run, prints what would be removed."
        echo "  --apply: actually remove."
        exit 0
        ;;
    *)
        echo "Unknown arg: $1" >&2
        echo "Usage: ./run.sh gc [--apply]" >&2
        exit 2
        ;;
esac

note() { printf '%s\n' "$*"; }
act()  {
    if [ "$APPLY" -eq 1 ]; then
        printf '  apply:  %s\n' "$*"
        eval "$*"
    else
        printf '  dryrun: %s\n' "$*"
    fi
}

# --- Stage dirs ---------------------------------------------------------
note ""
note "== Orphan .mount-stage/session-* directories =="

stage_root="$SCRIPT_DIR/.mount-stage"
orphan_count=0
reclaimable=0
if [ -d "$stage_root" ]; then
    # All known session container names from docker (running + stopped).
    # --format {{.Names}} is a single column.
    known=""
    if command -v docker >/dev/null 2>&1; then
        known="$(docker ps -a --filter "name=^claude-session-" --format '{{.Names}}' 2>/dev/null || true)"
    fi

    for dir in "$stage_root"/session-*; do
        [ -d "$dir" ] || continue
        name="$(basename "$dir")"
        # session-<containername>. The full container name is "session-"
        # stripped.
        container_name="${name#session-}"
        if ! printf '%s\n' "$known" | grep -qx "$container_name"; then
            orphan_count=$((orphan_count + 1))
            size=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
            reclaimable=$((reclaimable + ${size:-0}))
            act "rm -rf $(printf %q "$dir")"
        fi
    done
fi
note "  found $orphan_count orphan(s), ${reclaimable} KiB reclaimable"

# --- Named volumes ------------------------------------------------------
note ""
note "== Named volumes =="

if ! command -v docker >/dev/null 2>&1; then
    note "  docker not installed; skipping volume scan"
    exit 0
fi

for vol in claude-docker-build-cache claude-docker-mise-installs; do
    if ! docker volume inspect "$vol" >/dev/null 2>&1; then
        note "  $vol: does not exist"
        continue
    fi
    # Any container currently using this volume? We check both running
    # and stopped because `docker volume rm` will refuse either way.
    in_use="$(docker ps -a --filter "volume=$vol" --format '{{.Names}}' 2>/dev/null || true)"
    if [ -n "$in_use" ]; then
        note "  $vol: IN USE by:"
        printf '    %s\n' $in_use
        note "  $vol: skipping (would fail). Stop the containers first if you really want to reclaim."
        continue
    fi
    # Size on disk, best-effort (not all docker versions support this).
    size="$(docker system df -v --format '{{json .}}' 2>/dev/null | \
            python3 -c "import sys,json
try:
    for line in sys.stdin:
        d = json.loads(line)
        for v in d.get('Volumes', []):
            if v.get('Name') == '$vol':
                print(v.get('Size', 'unknown'))
                sys.exit(0)
except Exception: pass
print('unknown')" 2>/dev/null || echo unknown)"
    note "  $vol: not in use, size=$size"
    act "docker volume rm $(printf %q "$vol")"
done

note ""
if [ "$APPLY" -eq 0 ]; then
    note "Dry run. Re-run with --apply to actually remove."
fi
