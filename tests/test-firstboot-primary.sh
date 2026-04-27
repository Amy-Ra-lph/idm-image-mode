#!/bin/bash
# tests/test-firstboot-primary.sh — Verify primary server firstboot provisioning
#
# Prerequisites:
#   1. Server image built: ./scripts/build.sh
#   2. Primary container deployed: ./scripts/deploy-container.sh --role=primary
#
# This test verifies that the firstboot service correctly installs and
# configures a FreeIPA primary server inside the container.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_DIR}/scripts/lib/common.sh"

CNAME=$(container_name "primary")
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

exec_in() {
    podman exec "$CNAME" bash -c "$*"
}

log_section "Testing primary server firstboot: ${CNAME}"

# ── Container Running ────────────────────────────────────────────────
assert "container is running" \
    container_running "primary"

# ── Firstboot Completed ──────────────────────────────────────────────
assert "firstboot stamp file exists" \
    exec_in "test -f /var/lib/idm-image-mode/.firstboot-complete"

assert "idm-firstboot.service succeeded" \
    exec_in "systemctl is-active idm-firstboot.service"

# ── IPA Services ─────────────────────────────────────────────────────
assert "ipactl status reports all services running" \
    exec_in "ipactl status"

assert "389 Directory Server is running" \
    exec_in "systemctl is-active dirsrv@*"

assert "KDC (krb5kdc) is running" \
    exec_in "systemctl is-active krb5kdc"

assert "httpd is running" \
    exec_in "systemctl is-active httpd"

# ── Kerberos ─────────────────────────────────────────────────────────
assert "kinit admin succeeds" \
    exec_in "echo '${IDM_ADMIN_PASSWORD:-Secret123!}' | kinit admin"

assert "ipa user-find returns results" \
    exec_in "echo '${IDM_ADMIN_PASSWORD:-Secret123!}' | kinit admin && ipa user-find --sizelimit=1"

# ── DNS (if configured) ─────────────────────────────────────────────
assert "named is running (DNS)" \
    exec_in "systemctl is-active named-pkcs11 || systemctl is-active named"

# ── Idempotency ──────────────────────────────────────────────────────
# Restart the container and verify firstboot does NOT re-run
log_info "Testing idempotency (restart container)..."
podman restart "$CNAME" 2>/dev/null

# Wait for systemd and IPA services to settle after restart
sleep 20

assert "after restart: stamp file still exists" \
    exec_in "test -f /var/lib/idm-image-mode/.firstboot-complete"

assert "after restart: ipactl status still healthy" \
    exec_in "ipactl status"

assert "after restart: firstboot service did not re-run (check journal)" \
    exec_in "! journalctl -u idm-firstboot --since '30 seconds ago' | grep -q 'Installing FreeIPA'"

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
