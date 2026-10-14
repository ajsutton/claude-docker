#!/bin/bash
# Host side of key helper forwarding. See "Key helpers" in README.md.

# load_key_helper_secret
# Runs KEY_HELPER_COMMAND (default: the helper at KEY_HELPER_PATH) and stores its output in
# KEY_HELPER_SECRET. A failure only warns, so the session still starts without the key.
load_key_helper_secret() {
    [[ -z "${KEY_HELPER_PATH:-}" ]] && return 0

    local command="${KEY_HELPER_COMMAND:-$(printf '%q' "$KEY_HELPER_PATH")}"
    if ! KEY_HELPER_SECRET="$(bash -c "$command")" || [[ -z "$KEY_HELPER_SECRET" ]]; then
        echo "Warning: key helper command printed no key: $command" >&2
        KEY_HELPER_SECRET=""
    fi
}
