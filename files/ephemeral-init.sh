#!/bin/sh
# Init script for ephemeral per-session containers.
#
# The shared-container entrypoint.sh handles similar work, but it also runs
# sshd and expects long-lived state. This script does the minimal setup then
# execs the user's command (EPHEMERAL_USER_CMD) as the app user.
#
# Runs as root (forced via `docker run --user 0:0`, overriding the Dockerfile
# USER directive) so we can chown named-volume mounts that Docker creates on
# first attach. Drops to APP_USER before executing the user command.

set -eu

: "${APP_USER:?APP_USER not set}"
: "${APP_HOME:?APP_HOME not set}"
: "${EPHEMERAL_USER_CMD:?EPHEMERAL_USER_CMD not set}"

# Fix ownership on named-volume mounts. Docker creates them as root on first
# attach, so the first session after a volume is created pays this cost;
# subsequent sessions find the tree already owned and skip the chown.
# We chown to APP_USER (which in this image is a Linux-conventional UID from
# useradd, not the host UID) because the container-local passwd is what
# `su - $APP_USER` below will use.
for dir in "$APP_HOME/.cache" "$APP_HOME/.local/share/mise"; do
  [ -d "$dir" ] || continue
  owner="$(stat -c %U "$dir" 2>/dev/null || echo)"
  if [ "$owner" != "$APP_USER" ]; then
    chown -R "$APP_USER:$APP_USER" "$dir" 2>/dev/null || true
  fi
done

# Copy .claude.json from the directory-mount staging area into the real path
# to survive host-side atomic writes. Same trick as the shared-container
# entrypoint.
STAGED_CLAUDE_JSON="$APP_HOME/.claude-mount-stage/.claude.json"
if [ -f "$STAGED_CLAUDE_JSON" ]; then
  cp "$STAGED_CLAUDE_JSON" "$APP_HOME/.claude.json"
  chown "$APP_USER:$APP_USER" "$APP_HOME/.claude.json"
fi

# Run user-provided init scripts (bind-mounted in via files/init.d/).
for f in /etc/claude-docker/init.d/*.sh; do
  [ -f "$f" ] && . "$f"
done

# Hand off to the user command as APP_USER. We use a fresh login shell so
# .profile / .zshenv / .zshrc.d are sourced — this is where FORWARD_* env
# vars get unprefixed.
exec su - "$APP_USER" -c "exec zsh -ilc $(printf '%q' "$EPHEMERAL_USER_CMD")"
