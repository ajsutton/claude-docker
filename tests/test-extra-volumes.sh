#!/bin/bash
# Unit test for _append_extra_volumes in lib/run-ephemeral.sh.
# Re-sources the helper with a stub HOME/SCRIPT_DIR and asserts EPH_RUN_ARGS
# gets the expected --mount flags.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
FAILS=()

assert_contains_run() {
    local label="$1" needle="$2"
    local found=0
    local a
    for a in "${EPH_RUN_ARGS[@]}"; do
        if [ "$a" = "$needle" ]; then found=1; break; fi
    done
    if [ "$found" -eq 1 ]; then
        PASS=$((PASS + 1))
        printf '  ok   %s\n' "$label"
    else
        FAIL=$((FAIL + 1))
        FAILS+=("$label")
        printf '  FAIL %s (looking for %s)\n' "$label" "$needle"
        printf '    EPH_RUN_ARGS=' ; printf '%q ' "${EPH_RUN_ARGS[@]}" ; echo ''
    fi
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf '  ok   %s\n' "$label"
    else
        FAIL=$((FAIL + 1))
        FAILS+=("$label")
        printf '  FAIL %s expected=[%s] actual=[%s]\n' "$label" "$expected" "$actual"
    fi
}

# Extract just the helper function from run-ephemeral.sh to avoid sourcing
# the full file (which depends on .env, docker, etc.).
extract_helper() {
    sed -n '/^_append_extra_volumes()/,/^}$/p' "$SCRIPT_DIR/lib/run-ephemeral.sh"
}

run_test() {
    local name="$1"
    shift
    echo ""
    echo "= $name ="
    EPH_RUN_ARGS=()
    unset EXTRA_VOLUMES
    eval "$(extract_helper)"
    "$@"
}

test_empty() {
    _append_extra_volumes
    assert_eq "no flags on empty EXTRA_VOLUMES" "0" "${#EPH_RUN_ARGS[@]}"
}
run_test "empty EXTRA_VOLUMES" test_empty

test_single() {
    EXTRA_VOLUMES="rust-target:/Users/aj/code/rust/target"
    _append_extra_volumes
    assert_contains_run "--mount flag" "--mount"
    assert_contains_run "type/src/dst" "type=volume,src=rust-target,dst=/Users/aj/code/rust/target"
}
run_test "single entry" test_single

test_multiple() {
    EXTRA_VOLUMES="rust-target:/a/b,node-cache:/c/d"
    _append_extra_volumes
    assert_contains_run "first entry" "type=volume,src=rust-target,dst=/a/b"
    assert_contains_run "second entry" "type=volume,src=node-cache,dst=/c/d"
}
run_test "multiple entries" test_multiple

test_whitespace() {
    EXTRA_VOLUMES="  rust-target:/path  ,  other:/x  "
    _append_extra_volumes
    assert_contains_run "leading/trailing whitespace trimmed" "type=volume,src=rust-target,dst=/path"
    assert_contains_run "second trimmed" "type=volume,src=other,dst=/x"
}
run_test "whitespace around entries" test_whitespace

test_malformed_skipped() {
    EXTRA_VOLUMES="no-colon-here"
    local stderr_file
    stderr_file="$(mktemp)"
    _append_extra_volumes 2>"$stderr_file"
    assert_eq "no flags on malformed" "0" "${#EPH_RUN_ARGS[@]}"
    if grep -q "not in volume:path form" "$stderr_file"; then
        PASS=$((PASS + 1))
        printf '  ok   warned about malformed entry\n'
    else
        FAIL=$((FAIL + 1))
        FAILS+=("no warn on malformed")
        printf '  FAIL no warning on malformed entry\n'
    fi
    rm -f "$stderr_file"
}
run_test "malformed entry" test_malformed_skipped

test_mixed() {
    EXTRA_VOLUMES="good:/path,broken,another:/x"
    _append_extra_volumes 2>/dev/null
    assert_contains_run "good entry kept" "type=volume,src=good,dst=/path"
    assert_contains_run "another entry kept" "type=volume,src=another,dst=/x"
}
run_test "mixed good/bad" test_mixed

echo ""
echo "================================================"
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Failures:"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
