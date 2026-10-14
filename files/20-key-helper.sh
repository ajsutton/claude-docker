# Link KEY_HELPER_PATH to the container key helper, so configs shared with the host find a
# helper that works here. Runs after 00-forward-env.sh has unprefixed KEY_HELPER_PATH.

link_key_helper() {
    local target="${KEY_HELPER_TARGET:-/usr/local/bin/claude-docker-key-helper}"
    local helper_path="$1"

    [[ "$(readlink "$helper_path" 2>/dev/null)" == "$target" ]] && return 0

    if [[ "$helper_path" != /* ]]; then
        echo "claude-docker: KEY_HELPER_PATH must be an absolute path: $helper_path" >&2
        return 1
    fi

    # A path on a bind mount is the host's own helper. Replacing it would break the host.
    local existing="${helper_path:h}"
    while [[ ! -e "$existing" ]]; do existing="${existing:h}"; done
    if [[ "$(findmnt -n -o TARGET -T "$existing")" != "/" ]]; then
        echo "claude-docker: KEY_HELPER_PATH is on a host mount, so the container can't replace it: $helper_path" >&2
        return 1
    fi

    mkdir -p "${helper_path:h}" && ln -sfn "$target" "$helper_path"
}

if [[ -n "${KEY_HELPER_PATH:-}" ]]; then
    link_key_helper "$KEY_HELPER_PATH"
fi
unfunction link_key_helper
