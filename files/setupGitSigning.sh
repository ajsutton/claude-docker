#set -e

# Exit cleanly if the agent has no keys
ssh-add -l >/dev/null 2>&1 || return

key="$(ssh-add -L | sed -n '1p')"
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0=gpg.format
export GIT_CONFIG_VALUE_0=ssh
export GIT_CONFIG_KEY_1=user.signingkey
export GIT_CONFIG_VALUE_1="$key"
export GIT_CONFIG_KEY_2=gpg.ssh.program
export GIT_CONFIG_VALUE_2=ssh-keygen

