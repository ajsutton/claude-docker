#!/bin/sh
# Entrypoint runs as the non-root user. sshd listens on port 2222 (non-privileged)
# and runs without privilege separation since we only serve one user.

SSH_DIR="$HOME/.ssh"
BUILD_DIR="$HOME/.ssh.build"
SSHD_CONFIG="$SSH_DIR/sshd_config"
HOST_KEY="$SSH_DIR/ssh_host_ed25519_key"
PID_FILE="$SSH_DIR/sshd.pid"

# Copy build-time SSH files (authorized_keys, known_hosts) into the volume.
# This runs on every start so rebuilds with new keys take effect immediately.
if [ -d "$BUILD_DIR" ]; then
  cp "$BUILD_DIR"/authorized_keys "$SSH_DIR/authorized_keys" 2>/dev/null || true
  cp "$BUILD_DIR"/known_hosts "$SSH_DIR/known_hosts" 2>/dev/null || true
  chmod 600 "$SSH_DIR"/authorized_keys "$SSH_DIR"/known_hosts 2>/dev/null || true
fi

# Generate host keys on first run (persisted via the ssh-host-keys volume)
if [ ! -f "$HOST_KEY" ]; then
  ssh-keygen -t ed25519 -f "$HOST_KEY" -N "" -q
  ssh-keygen -t rsa -b 4096 -f "$SSH_DIR/ssh_host_rsa_key" -N "" -q
fi

# Write sshd config for non-root operation
cat > "$SSHD_CONFIG" <<EOF
Port 2222
ListenAddress 0.0.0.0

HostKey $SSH_DIR/ssh_host_ed25519_key
HostKey $SSH_DIR/ssh_host_rsa_key

AuthorizedKeysFile $SSH_DIR/authorized_keys
PasswordAuthentication no
PubkeyAuthentication yes
UsePAM no

LogLevel INFO

PidFile $PID_FILE

AcceptEnv ITERM_SESSION_ID FORWARD_*
EOF

# Run user-provided init scripts (compose overlays bind-mount into this dir)
for f in /etc/claude-docker/init.d/*.sh; do
  [ -f "$f" ] && . "$f"
done

exec /usr/sbin/sshd -D -f "$SSHD_CONFIG" -e
