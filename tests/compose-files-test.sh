#!/usr/bin/env bash
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
failures=0

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

export HOME="$TEST_ROOT/source-home"
SCRIPT_DIR="$TEST_ROOT/source-script"
mkdir -p "$HOME" "$SCRIPT_DIR/compose.d"
# shellcheck source=../lib/compose-files.sh
source "$REPO_ROOT/lib/compose-files.sh"

set_case_dirs() {
    local name="$1"
    HOME="$TEST_ROOT/$name/home"
    SCRIPT_DIR="$TEST_ROOT/$name/script"
    export HOME
    mkdir -p "$HOME" "$SCRIPT_DIR/compose.d"
}

has_compose_file() {
    local needle="$1"
    local i

    for ((i = 0; i + 1 < ${#COMPOSE_FILE_ARGS[@]}; i++)); do
        if [ "${COMPOSE_FILE_ARGS[$i]}" = "-f" ] && [ "${COMPOSE_FILE_ARGS[$((i + 1))]}" = "$needle" ]; then
            return 0
        fi
    done

    return 1
}

ok() {
    printf 'ok - %s\n' "$1"
}

not_ok() {
    printf 'not ok - %s\n' "$1" >&2
    failures=$((failures + 1))
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

assert_false() {
    local description="$1"
    shift

    if "$@"; then
        not_ok "$description"
    else
        ok "$description"
    fi
}

set_case_dirs omp-present
mkdir -p "$HOME/.omp"
build_compose_file_args
assert_true 'includes modules/omp.yml when ~/.omp exists' has_compose_file modules/omp.yml

set_case_dirs omp-absent
build_compose_file_args
assert_false 'does not include modules/omp.yml when ~/.omp is absent' has_compose_file modules/omp.yml
if [ -e "$HOME/.omp" ]; then
    not_ok 'does not create ~/.omp when it is absent'
else
    ok 'does not create ~/.omp when it is absent'
fi

set_case_dirs herdr-present
mkdir -p "$HOME/.config/herdr"
touch "$HOME/.config/herdr/config.toml"
build_compose_file_args
assert_true 'includes modules/herdr.yml when herdr config.toml exists' has_compose_file modules/herdr.yml

set_case_dirs herdr-absent
build_compose_file_args
assert_false 'does not include modules/herdr.yml when herdr config.toml is absent' has_compose_file modules/herdr.yml

if [ "$failures" -ne 0 ]; then
    printf '%s assertion(s) failed\n' "$failures" >&2
    exit 1
fi
