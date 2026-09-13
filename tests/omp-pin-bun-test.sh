#!/usr/bin/env bash
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
failures=0

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

USER_HOME="$TEST_ROOT/home"
APP_USER="omp-test-user-$$"
export USER_HOME APP_USER

bundle="$USER_HOME/.local/install/global/node_modules/@oh-my-pi/pi-coding-agent/dist/cli.js"
launcher="$USER_HOME/.local/bin/omp"
bun="$USER_HOME/.local/bin/bun"
mkdir -p "$(dirname "$bundle")" "$(dirname "$launcher")" "$TEST_ROOT/bin"
printf '#!/usr/bin/env bun\nconsole.log("omp bundle")\n' > "$bundle"
printf '#!/bin/sh\nexit 0\n' > "$bun"
printf '#!/bin/sh\nexit 0\n' > "$TEST_ROOT/bin/chown"
chmod +x "$bundle" "$bun" "$TEST_ROOT/bin/chown"
ln -s ../install/global/node_modules/@oh-my-pi/pi-coding-agent/dist/cli.js "$launcher"

PATH="$TEST_ROOT/bin:$PATH"
export PATH
# shellcheck source=../files/omp-pin-bun.init.sh
source "$REPO_ROOT/files/omp-pin-bun.init.sh"

if [ -L "$launcher" ]; then
    printf 'not ok - replaces the Bun symlink with a launcher file\n' >&2
    failures=$((failures + 1))
else
    printf 'ok - replaces the Bun symlink with a launcher file\n'
fi

expected_bundle="$TEST_ROOT/expected-bundle"
printf '#!/usr/bin/env bun\nconsole.log("omp bundle")\n' > "$expected_bundle"
if cmp -s "$expected_bundle" "$bundle"; then
    printf 'ok - preserves the installed OMP bundle\n'
else
    printf 'not ok - preserves the installed OMP bundle\n' >&2
    failures=$((failures + 1))
fi

expected_launcher="$TEST_ROOT/expected-launcher"
printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' "$bun" "$bundle" > "$expected_launcher"
if cmp -s "$expected_launcher" "$launcher"; then
    printf 'ok - writes the pinned Bun launcher\n'
else
    printf 'not ok - writes the pinned Bun launcher\n' >&2
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    printf '%s assertion(s) failed\n' "$failures" >&2
    exit 1
fi
