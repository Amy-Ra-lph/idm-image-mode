#!/bin/bash
# tests/test-build.sh — Verify IdM Image Mode images are built correctly
#
# Checks that the built images contain the required packages, services,
# and configuration files.
#
# Usage:
#   ./tests/test-build.sh                  # test server image
#   ./tests/test-build.sh --type=client    # test client image
#   ./tests/test-build.sh --type=all       # test both

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_DIR}/scripts/lib/common.sh"

TYPE="${1:---type=server}"
TYPE="${TYPE#--type=}"

PASS=0
FAIL=0
TOTAL=0

assert() {
    local desc=$1
    shift
    TOTAL=$((TOTAL + 1))
    if "$@" 2>/dev/null; then
        log_ok "PASS: $desc"
        PASS=$((PASS + 1))
    else
        log_err "FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

test_image() {
    local type=$1
    local image
    image=$(image_name "$type")

    log_section "Testing ${type} image: ${image}"

    # Image exists
    assert "${type}: image exists in local storage" \
        podman image exists "$image"

    # Key binaries
    if [[ "$type" == "server" ]]; then
        assert "${type}: contains ipa-server-install" \
            podman run --rm "$image" test -f /usr/sbin/ipa-server-install

        assert "${type}: contains ipa-replica-install" \
            podman run --rm "$image" test -f /usr/sbin/ipa-replica-install

        assert "${type}: contains named (DNS)" \
            podman run --rm "$image" test -f /usr/sbin/named
    fi

    assert "${type}: contains ipa-client-install" \
        podman run --rm "$image" test -f /usr/sbin/ipa-client-install

    # Firstboot service
    assert "${type}: contains idm-firstboot script" \
        podman run --rm "$image" test -f /usr/local/sbin/idm-firstboot

    assert "${type}: idm-firstboot is executable" \
        podman run --rm "$image" test -x /usr/local/sbin/idm-firstboot

    assert "${type}: contains idm-firstboot.service" \
        podman run --rm "$image" test -f /etc/systemd/system/idm-firstboot.service

    assert "${type}: idm-firstboot.service is enabled" \
        podman run --rm "$image" systemctl is-enabled idm-firstboot.service

    # Config example
    assert "${type}: contains config.env.example" \
        podman run --rm "$image" test -f /etc/idm-image-mode/config.env.example

    # Stamp directory
    assert "${type}: /var/lib/idm-image-mode directory exists" \
        podman run --rm "$image" test -d /var/lib/idm-image-mode

    # bootc base image verification
    assert "${type}: based on fedora-bootc (has bootc binary)" \
        podman run --rm "$image" test -f /usr/bin/bootc
}

case "$TYPE" in
    server) test_image server ;;
    client) test_image client ;;
    all)    test_image server; test_image client ;;
    *)      log_err "Unknown type: $TYPE"; exit 1 ;;
esac

# ── Summary ──────────────────────────────────────────────────────────
echo ""
log_section "Results"
echo "  Total: ${TOTAL}"
echo "  Pass:  ${PASS}"
echo "  Fail:  ${FAIL}"

if [[ $FAIL -gt 0 ]]; then
    log_err "${FAIL} test(s) failed"
    exit 1
fi

log_ok "All ${TOTAL} tests passed"
