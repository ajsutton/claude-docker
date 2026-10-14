#!/usr/bin/env bash
# load_key_helper_secret reads the KEY_HELPER_* globals that this test sets.
# shellcheck disable=SC2034
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The container side needs a directory on the root mount and one on a bind mount.
ROOT_MOUNT_DIR="$(mktemp -d)"
failures=0

cleanup() {
    rm -rf "$ROOT_MOUNT_DIR"
}
trap cleanup EXIT

# shellcheck source=../lib/key-helper.sh
source "$REPO_ROOT/lib/key-helper.sh"

ok() {
    printf 'ok - %s\n' "$1"
}

not_ok() {
    printf 'not ok - %s\n' "$1" >&2
    failures=$((failures + 1))
}

assert_eq() {
    local description="$1" expected="$2" actual="$3"

    if [ "$expected" = "$actual" ]; then
        ok "$description"
    else
        not_ok "$description (expected '$expected', got '$actual')"
    fi
}

assert_true() {
    local description="$1"
    shift

    if "$@"; then
        ok "$description"
    else
        not_ok "$description"
    fi
}

contains() {
    [[ "$1" == *"$2"* ]]
}


host_helper="$ROOT_MOUNT_DIR/host bin/helper"
mkdir -p "${host_helper%/*}"
printf '#!/bin/sh\nprintf from-helper\n' >"$host_helper"
chmod +x "$host_helper"

unset KEY_HELPER_PATH KEY_HELPER_COMMAND
KEY_HELPER_SECRET=""
load_key_helper_secret 2>/dev/null
assert_eq "host: no secret without KEY_HELPER_PATH" "" "$KEY_HELPER_SECRET"

KEY_HELPER_PATH="$host_helper"
load_key_helper_secret
assert_eq "host: runs the helper at KEY_HELPER_PATH by default" "from-helper" "$KEY_HELPER_SECRET"

KEY_HELPER_COMMAND="printf from-command"
load_key_helper_secret
assert_eq "host: KEY_HELPER_COMMAND overrides the helper" "from-command" "$KEY_HELPER_SECRET"

KEY_HELPER_COMMAND="printf partial; exit 1"
warning="$(load_key_helper_secret 2>&1)"
load_key_helper_secret 2>/dev/null
assert_eq "host: failed command forwards no secret" "" "$KEY_HELPER_SECRET"
assert_true "host: failed command warns" contains "$warning" "Warning:"

assert_eq "container: helper prints the forwarded key" "s3cret" \
    "$(KEY_HELPER_SECRET=s3cret "$REPO_ROOT/files/key-helper")"
KEY_HELPER_SECRET="" "$REPO_ROOT/files/key-helper" >/dev/null 2>&1
assert_eq "container: helper fails without a forwarded key" "1" "$?"

if ! command -v zsh >/dev/null || ! command -v findmnt >/dev/null; then
    echo "skip - container shell init tests need zsh and findmnt"
elif [ "$(findmnt -n -o TARGET -T "$ROOT_MOUNT_DIR")" != "/" ]; then
    echo "skip - container shell init tests need $ROOT_MOUNT_DIR on the root mount"
else
    run_init() {
        KEY_HELPER_PATH="$1" KEY_HELPER_TARGET="$REPO_ROOT/files/key-helper" \
            zsh -fc "source $(printf '%q' "$REPO_ROOT/files/20-key-helper.sh")"
    }

    link="$ROOT_MOUNT_DIR/new dir/helper"
    run_init "$link"
    assert_eq "container: links KEY_HELPER_PATH to the helper" "$REPO_ROOT/files/key-helper" "$(readlink "$link")"
    run_init "$link"
    assert_eq "container: second run keeps the link" "$REPO_ROOT/files/key-helper" "$(readlink "$link")"

    stale="$ROOT_MOUNT_DIR/stale"
    printf 'old' >"$stale"
    run_init "$stale"
    assert_eq "container: replaces a container-local file" "$REPO_ROOT/files/key-helper" "$(readlink "$stale")"

    if [ "$(findmnt -n -o TARGET -T "$REPO_ROOT")" != "/" ]; then
        mounted="$REPO_ROOT/tests/.key-helper-test-link"
        warning="$(run_init "$mounted" 2>&1)"
        assert_true "container: warns about a path on a host mount" contains "$warning" "host mount"
        assert_true "container: leaves a host mount alone" test ! -L "$mounted"
        rm -f "$mounted"
    else
        echo "skip - host mount test needs the repository on a bind mount"
    fi

    warning="$(cd "$ROOT_MOUNT_DIR" && run_init "relative/helper" 2>&1)"
    assert_true "container: warns about a relative path" contains "$warning" "absolute path"
    assert_true "container: ignores a relative path" test ! -L "$ROOT_MOUNT_DIR/relative/helper"
fi

if [ "$failures" -ne 0 ]; then
    printf '%s test(s) failed\n' "$failures" >&2
    exit 1
fi
