#!/bin/bash
# Unit tests for lib/ssh-agent-detect.sh.
#
# Uses a temp directory as a fake $HOME with socket files created at the
# expected paths for each agent. Overrides detect_docker_provider to avoid
# calling docker during tests.
#
# Run: ./tests/test-ssh-agent-detect.sh

set -u  # NOT -e — we want to continue past assertion failures so the
        # summary reports all of them, not just the first.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
FAILS=()
CUR_FAILS_FILE=""

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf '  ok   %s\n' "$label"
        printf 'pass\n' >> "$CUR_FAILS_FILE"
    else
        printf '  FAIL %s\n    expected: [%s]\n    actual:   [%s]\n' \
            "$label" "$expected" "$actual"
        printf 'fail\t%s: expected=[%s] actual=[%s]\n' \
            "$label" "$expected" "$actual" >> "$CUR_FAILS_FILE"
    fi
}

note_pass() {
    local label="$1"
    printf '  ok   %s\n' "$label"
    printf 'pass\n' >> "$CUR_FAILS_FILE"
}
note_fail() {
    local label="$1" detail="${2:-}"
    printf '  FAIL %s\n' "$label"
    [ -n "$detail" ] && printf '    %s\n' "$detail"
    printf 'fail\t%s: %s\n' "$label" "$detail" >> "$CUR_FAILS_FILE"
}

# Each test runs in a subshell so we can mutate HOME / unset vars without
# leaking to the next one. Subshells record pass/fail lines to a shared
# file the parent tallies after each test.
run_test() {
    local name="$1"
    shift
    echo ""
    echo "= $name ="
    CUR_FAILS_FILE="$(mktemp)"
    (
        FAKE_HOME="$(mktemp -d)"
        export HOME="$FAKE_HOME"
        unset SSH_AGENT_HOST_SOCK SSH_AUTH_SOCK XDG_RUNTIME_DIR _CD_DOCKER_PROVIDER
        source "$SCRIPT_DIR/lib/ssh-agent-detect.sh"
        # Stub the docker provider detector so tests are hermetic.
        detect_docker_provider() { echo "${FAKE_PROVIDER:-native}"; }
        # Stub uname for macOS-specific branches.
        uname() { echo "${FAKE_UNAME:-Linux}"; }

        "$@"

        rm -rf "$FAKE_HOME"
    )
    # Tally in the parent.
    while IFS=$'\t' read -r kind detail; do
        case "$kind" in
            pass) PASS=$((PASS + 1)) ;;
            fail)
                FAIL=$((FAIL + 1))
                FAILS+=("$detail")
                ;;
        esac
    done < "$CUR_FAILS_FILE"
    rm -f "$CUR_FAILS_FILE"
}

mksock() {
    # Create a unix socket at the given path. python is required; we use
    # it here because `nc -lU` behaves differently across distros.
    local path="$1"
    mkdir -p "$(dirname "$path")"
    python3 -c "
import os, socket, sys
path = sys.argv[1]
try: os.unlink(path)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.close()  # bind() creates the node; close() keeps it on disk
" "$path"
}

# --------------------------------------------------------------------------
# Test 1: explicit override wins over everything else
# --------------------------------------------------------------------------
test_override_wins() {
    mksock "$HOME/.override.sock"
    mksock "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
    export SSH_AGENT_HOST_SOCK="$HOME/.override.sock"
    local out
    out="$(detect_ssh_agent)"
    assert_eq "label" "override" "${out%%	*}"
    assert_eq "path" "$HOME/.override.sock" "${out#*	}"
}
run_test "override wins over 1Password" test_override_wins

# --------------------------------------------------------------------------
# Test 2: bad override falls through to auto-detection
# --------------------------------------------------------------------------
test_bad_override_falls_through() {
    # Override points at something that isn't a socket.
    export SSH_AGENT_HOST_SOCK="$HOME/does-not-exist"
    mksock "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
    local out stderr_file
    stderr_file="$(mktemp)"
    out="$(detect_ssh_agent 2>"$stderr_file")"
    assert_eq "label" "1Password (macOS)" "${out%%	*}"
    if grep -q "is not a socket" "$stderr_file"; then
        note_pass "warned about bad override"
    else
        note_fail "bad override didn't warn"
    fi
    rm -f "$stderr_file"
}
run_test "bad override falls through with warning" test_bad_override_falls_through

# --------------------------------------------------------------------------
# Test 3: 1Password macOS detected
# --------------------------------------------------------------------------
test_1password_macos() {
    mksock "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
    local out
    out="$(detect_ssh_agent)"
    assert_eq "label" "1Password (macOS)" "${out%%	*}"
    assert_eq "path" "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock" "${out#*	}"
}
run_test "1Password macOS" test_1password_macos

# --------------------------------------------------------------------------
# Test 4: 1Password Linux detected
# --------------------------------------------------------------------------
test_1password_linux() {
    mksock "$HOME/.1password/agent.sock"
    local out
    out="$(detect_ssh_agent)"
    assert_eq "label" "1Password (Linux)" "${out%%	*}"
}
run_test "1Password Linux" test_1password_linux

# --------------------------------------------------------------------------
# Test 5: 1Password macOS preferred over 1Password Linux when both exist
# --------------------------------------------------------------------------
test_1password_priority() {
    mksock "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
    mksock "$HOME/.1password/agent.sock"
    local out
    out="$(detect_ssh_agent)"
    assert_eq "label" "1Password (macOS)" "${out%%	*}"
}
run_test "1Password macOS preferred over Linux" test_1password_priority

# --------------------------------------------------------------------------
# Test 6: Secretive detected
# --------------------------------------------------------------------------
test_secretive() {
    mksock "$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
    local out
    out="$(detect_ssh_agent)"
    assert_eq "label" "Secretive" "${out%%	*}"
}
run_test "Secretive" test_secretive

# --------------------------------------------------------------------------
# Test 7: KeePassXC Linux detected
# --------------------------------------------------------------------------
test_keepassxc_linux() {
    mksock "$HOME/.keepassxc/sshagent.sock"
    local out
    out="$(detect_ssh_agent)"
    assert_eq "label" "KeePassXC (Linux)" "${out%%	*}"
}
run_test "KeePassXC Linux" test_keepassxc_linux

# --------------------------------------------------------------------------
# Test 8: gnome-keyring via XDG_RUNTIME_DIR
# --------------------------------------------------------------------------
test_gnome_keyring() {
    export XDG_RUNTIME_DIR="$HOME/runtime"
    mksock "$XDG_RUNTIME_DIR/keyring/ssh"
    local out
    out="$(detect_ssh_agent)"
    assert_eq "label" "gnome-keyring" "${out%%	*}"
}
run_test "gnome-keyring via XDG_RUNTIME_DIR" test_gnome_keyring

# --------------------------------------------------------------------------
# Test 9: SSH_AUTH_SOCK trusted on native Linux
# --------------------------------------------------------------------------
test_ssh_auth_sock_native() {
    export FAKE_PROVIDER="native"
    mksock "$HOME/agent.sock"
    export SSH_AUTH_SOCK="$HOME/agent.sock"
    local out
    out="$(detect_ssh_agent)"
    assert_eq "label" "SSH_AUTH_SOCK" "${out%%	*}"
    assert_eq "path" "$SSH_AUTH_SOCK" "${out#*	}"
}
run_test "SSH_AUTH_SOCK trusted on native Linux" test_ssh_auth_sock_native

# --------------------------------------------------------------------------
# Test 10: SSH_AUTH_SOCK trusted on OrbStack
# --------------------------------------------------------------------------
test_ssh_auth_sock_orbstack() {
    export FAKE_PROVIDER="orbstack"
    mksock "$HOME/agent.sock"
    export SSH_AUTH_SOCK="$HOME/agent.sock"
    local out
    out="$(detect_ssh_agent)"
    assert_eq "label" "SSH_AUTH_SOCK" "${out%%	*}"
}
run_test "SSH_AUTH_SOCK trusted on OrbStack" test_ssh_auth_sock_orbstack

# --------------------------------------------------------------------------
# Test 11: SSH_AUTH_SOCK outside $HOME skipped on Docker Desktop
# --------------------------------------------------------------------------
test_ssh_auth_sock_dd_skipped() {
    export FAKE_PROVIDER="docker-desktop"
    export FAKE_UNAME="Darwin"
    # Socket in a path Docker Desktop can't share.
    mksock "/tmp/cd-test-agent.sock"
    export SSH_AUTH_SOCK="/tmp/cd-test-agent.sock"
    # With no other agent present, detection should fall through to the
    # macOS synth path.
    local out
    out="$(detect_ssh_agent)"
    assert_eq "label" "Docker Desktop/OrbStack synth (launchd only)" "${out%%	*}"
    assert_eq "path" "/run/host-services/ssh-auth.sock" "${out#*	}"
    rm -f /tmp/cd-test-agent.sock
}
run_test "SSH_AUTH_SOCK in /tmp skipped on Docker Desktop" test_ssh_auth_sock_dd_skipped

# --------------------------------------------------------------------------
# Test 12: SSH_AUTH_SOCK under $HOME accepted on Docker Desktop
# --------------------------------------------------------------------------
test_ssh_auth_sock_dd_home_ok() {
    export FAKE_PROVIDER="docker-desktop"
    export FAKE_UNAME="Darwin"
    mksock "$HOME/agent.sock"
    export SSH_AUTH_SOCK="$HOME/agent.sock"
    local out
    out="$(detect_ssh_agent)"
    assert_eq "label" "SSH_AUTH_SOCK" "${out%%	*}"
}
run_test "SSH_AUTH_SOCK under \$HOME accepted on Docker Desktop" test_ssh_auth_sock_dd_home_ok

# --------------------------------------------------------------------------
# Test 13: macOS fallback when nothing else matches
# --------------------------------------------------------------------------
test_macos_fallback() {
    export FAKE_PROVIDER="docker-desktop"
    export FAKE_UNAME="Darwin"
    # No sockets present, no env vars.
    local out
    out="$(detect_ssh_agent)"
    assert_eq "label" "Docker Desktop/OrbStack synth (launchd only)" "${out%%	*}"
}
run_test "macOS synth fallback" test_macos_fallback

# --------------------------------------------------------------------------
# Test 14: Linux with nothing available returns failure
# --------------------------------------------------------------------------
test_linux_nothing() {
    export FAKE_PROVIDER="native"
    export FAKE_UNAME="Linux"
    local rc=0
    detect_ssh_agent >/dev/null || rc=$?
    assert_eq "exit code" "1" "$rc"
}
run_test "Linux with no agent returns 1" test_linux_nothing

# --------------------------------------------------------------------------
# Test 15: describe_ssh_agent_options prints the known list
# --------------------------------------------------------------------------
test_describe() {
    local out
    out="$(describe_ssh_agent_options)"
    if echo "$out" | grep -q "1Password (macOS)" && \
       echo "$out" | grep -q "Secretive" && \
       echo "$out" | grep -q "KeePassXC"; then
        note_pass "describe lists all known agents"
    else
        note_fail "describe missing entries" "$(echo "$out" | tr '\n' ' ')"
    fi
}
run_test "describe_ssh_agent_options" test_describe

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "================================================"
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Failures:"
    for f in "${FAILS[@]}"; do
        echo "  - $f"
    done
    exit 1
fi
exit 0
