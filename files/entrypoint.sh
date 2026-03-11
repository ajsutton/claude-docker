#!/bin/sh
# Entrypoint runs as root: sets up SSH, then drops to the non-root user.

if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
  cp -r /etc/ssh.original/. /etc/ssh/
  ssh-keygen -A
fi
cp /etc/ssh.original/sshd_config /etc/ssh/sshd_config

# Run user-provided init scripts (compose overlays bind-mount into this dir)
for f in /etc/claude-docker/init.d/*.sh; do
  [ -f "$f" ] && . "$f"
done

exec /usr/sbin/sshd -D
