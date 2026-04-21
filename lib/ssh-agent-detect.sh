#!/bin/bash
# Auto-detect the host ssh-agent socket to bind-mount into ephemeral
# containers, supporting any agent anyone on the team might use.
#
# Exposes two functions:
#   detect_ssh_agent
#       Stdout: "<label>\t<path>" on success, empty on failure
#       Stderr: unused
#       Exit:   0 on success, 1 on no agent found
#   describe_ssh_agent_options
#       Prints the list of supported agent paths to stderr (for error msgs)
#
# Detection priority (first match wins):
#   1. $SSH_AGENT_HOST_SOCK if set (explicit override)
#   2. $SSH_AUTH_SOCK if on a docker runtime that can bind-mount it
#      (native Linux always; OrbStack usually; Docker Desktop usually not)
#   3. Known third-party agent sockets on disk (1Password, Secretive,
#      KeePassXC, gnome-keyring) - checked in order
#   4. Docker Desktop / OrbStack synthesized /run/host-services/ssh-auth.sock
#      on macOS (works for the launchd default agent)
#   5. $SSH_AUTH_SOCK on Linux as a last resort
#
# All path checks use -S (socket file) so typos / broken symlinks don't
# falsely positive.

set -euo pipefail

# Detect the docker provider so we know whether to trust $SSH_AUTH_SOCK
# (Docker Desktop can't bind arbitrary macOS sockets; OrbStack and native
# Docker can). Cached in _CD_DOCKER_PROVIDER across calls.
detect_docker_provider() {
    if [ -n "${_CD_DOCKER_PROVIDER:-}" ]; then
        echo "$_CD_DOCKER_PROVIDER"
        return
    fi

    local os
    os="$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || true)"
    case "$os" in
        *OrbStack*)       _CD_DOCKER_PROVIDER="orbstack" ;;
        *"Docker Desktop"*) _CD_DOCKER_PROVIDER="docker-desktop" ;;
        "")               _CD_DOCKER_PROVIDER="unknown" ;;
        *)                _CD_DOCKER_PROVIDER="native" ;;
    esac
    export _CD_DOCKER_PROVIDER
    echo "$_CD_DOCKER_PROVIDER"
}

# Known agent socket paths, ordered by decreasing specificity. Each entry
# is: "<label>|<path pattern>". Path patterns are shell-expanded so ~ and
# $UID work. Listed with the agents that are actually usable from a Docker
# container bind mount (home directory, XDG runtime, etc.).
_known_agent_paths() {
    local uid
    uid="$(id -u 2>/dev/null || echo 1000)"
    local xdg="${XDG_RUNTIME_DIR:-/run/user/$uid}"
    cat <<EOF
1Password (macOS)|$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock
1Password (Linux)|$HOME/.1password/agent.sock
1Password (Linux snap)|$HOME/snap/1password/common/1Password/1password-ssh-agent.sock
Secretive|$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh
KeePassXC (macOS)|$HOME/Library/Application Support/KeePassXC/sshagent.sock
KeePassXC (Linux)|$HOME/.keepassxc/sshagent.sock
gnome-keyring|$xdg/keyring/ssh
EOF
}

# Print the options list for error messages. Stdout (callers redirect).
describe_ssh_agent_options() {
    echo "Tried (set SSH_AGENT_HOST_SOCK to override):"
    local line label path
    while IFS='|' read -r label path; do
        echo "  - $label: $path"
    done < <(_known_agent_paths)
    echo "  - Docker Desktop/OrbStack synth: /run/host-services/ssh-auth.sock (macOS)"
    echo "  - \$SSH_AUTH_SOCK (Linux / OrbStack)"
}

# Check whether a path is safe to bind-mount on the current docker
# provider. Returns 0 if yes, 1 if no. The concern is Docker Desktop: it
# can only share paths inside macOS home or the explicitly-configured
# filesharing list. Everything under $HOME is fine by default; paths in
# /tmp, /var/folders, /private/tmp etc. often are not.
_path_is_mountable() {
    local path="$1"
    local provider
    provider="$(detect_docker_provider)"

    case "$provider" in
        native|orbstack)
            return 0
            ;;
        docker-desktop)
            # Docker Desktop's default shares include $HOME. Sockets under
            # ~/Library (1Password, Secretive, KeePassXC) and the macOS
            # synth path are fine; $SSH_AUTH_SOCK pointing at /tmp or
            # /var/folders is not.
            case "$path" in
                "$HOME"/*|/run/host-services/*) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        unknown|*)
            # If we can't tell, don't block — let docker run produce the
            # authoritative error.
            return 0
            ;;
    esac
}

# Main detection. Prints "<label>\t<path>" to stdout on success.
# Returns 0 on success, 1 on no agent found.
detect_ssh_agent() {
    # 1. Explicit override.
    if [ -n "${SSH_AGENT_HOST_SOCK:-}" ]; then
        if [ -S "$SSH_AGENT_HOST_SOCK" ] || [ "$SSH_AGENT_HOST_SOCK" = "/run/host-services/ssh-auth.sock" ]; then
            printf 'override\t%s\n' "$SSH_AGENT_HOST_SOCK"
            return 0
        fi
        echo "Warning: SSH_AGENT_HOST_SOCK=$SSH_AGENT_HOST_SOCK is not a socket." >&2
        # Keep trying detection — an explicit-but-bad override shouldn't
        # block a working default.
    fi

    # 2. $SSH_AUTH_SOCK if the provider can mount it. Skip on Docker
    # Desktop when the socket lives outside a shared path (common: a
    # Homebrew-launched ssh-agent under /tmp).
    if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
        if _path_is_mountable "$SSH_AUTH_SOCK"; then
            printf 'SSH_AUTH_SOCK\t%s\n' "$SSH_AUTH_SOCK"
            return 0
        fi
    fi

    # 3. Known agent sockets on disk. First socket that exists wins.
    local label path
    while IFS='|' read -r label path; do
        if [ -S "$path" ]; then
            printf '%s\t%s\n' "$label" "$path"
            return 0
        fi
    done < <(_known_agent_paths)

    # 4. macOS synth path — last resort because it only proxies the
    # default launchd agent, and most OP Labs users have third-party
    # agents. We can't stat this one from the host (it lives inside the
    # VM), so we just trust the platform: if we're on macOS and nothing
    # else matched, this is the best we can do.
    if [ "$(uname -s)" = "Darwin" ]; then
        printf 'Docker Desktop/OrbStack synth (launchd only)\t/run/host-services/ssh-auth.sock\n'
        return 0
    fi

    return 1
}
