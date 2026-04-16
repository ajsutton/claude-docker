#!/bin/sh
# Entrypoint runs as root: sets up SSH, then drops to the non-root user.

if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
  cp -r /etc/ssh.original/. /etc/ssh/
  ssh-keygen -A
fi
cp /etc/ssh.original/sshd_config /etc/ssh/sshd_config

# Fix ownership on named volumes (created as root by Docker)
USER_HOME="$(eval echo ~"$APP_USER")"
for dir in "$USER_HOME/.local/share/mise" "$USER_HOME/.cache"; do
  [ -d "$dir" ] && chown -R "$APP_USER:$APP_USER" "$dir" 2>/dev/null || true
done

# Copy .claude.json from the directory-mounted staging area into the real path.
# This avoids Docker single-file bind mount corruption caused by atomic writes.
STAGED_CLAUDE_JSON="$USER_HOME/.claude-mount-stage/.claude.json"
if [ -f "$STAGED_CLAUDE_JSON" ]; then
  cp "$STAGED_CLAUDE_JSON" "$USER_HOME/.claude.json"
  chown "$APP_USER:$APP_USER" "$USER_HOME/.claude.json"
fi

# Run user-provided init scripts (compose overlays bind-mount into this dir)
for f in /etc/claude-docker/init.d/*.sh; do
  [ -f "$f" ] && . "$f"
done

exec /usr/sbin/sshd -D
