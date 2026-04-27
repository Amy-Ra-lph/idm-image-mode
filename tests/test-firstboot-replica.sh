#!/bin/bash
# tests/test-firstboot-replica.sh — Verify replica join and promotion
#
# Prerequisites:
#   1. Server image built: ./scripts/build.sh
#   2. Primary running: ./scripts/deploy-container.sh --role=primary
#   3. Replica deployed: ./scripts/deploy-container.sh --role=replica

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_DIR}/scripts/lib/common.sh"

CNAME=$(container_name "replica")
PRIMARY_CNAME=$(container_name "primary")
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

exec_primary() {
    podman exec "$PRIMARY_CNAME" bash -c "$*"
}

log_section "Testing replica join: ${CNAME}"

# ── Container Running ────────────────────────────────────────────────
assert "container is running" \
    container_running "replica"

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

assert "pki-tomcatd (CA) is running" \
    exec_in "systemctl is-active pki-tomcatd@*"

assert "named is running (DNS)" \
    exec_in "systemctl is-active named-pkcs11 || systemctl is-active named"

# ── Kerberos ─────────────────────────────────────────────────────────
assert "kinit admin succeeds on replica" \
    exec_in "echo '${IDM_ADMIN_PASSWORD:-Secret123!}' | kinit admin"

# ── Topology ─────────────────────────────────────────────────────────
assert "topology segment exists (primary ↔ replica)" \
    exec_in "echo '${IDM_ADMIN_PASSWORD:-Secret123!}' | kinit admin && ipa topologysegment-find domain | grep -q idm-primary"

# ── Replication ──────────────────────────────────────────────────────
REPL_TEST_USER="repltest-$(date +%s)"
log_info "Creating test user on primary: ${REPL_TEST_USER}"
exec_primary "echo 'Secret123!' | kinit admin && ipa user-add ${REPL_TEST_USER} --first=Repl --last=Test" >/dev/null 2>&1
sleep 5

assert "user created on primary is visible on replica" \
    exec_in "echo 'Secret123!' | kinit admin && ipa user-show ${REPL_TEST_USER}"

log_info "Creating test user on replica: ${REPL_TEST_USER}-rev"
exec_in "echo 'Secret123!' | kinit admin && ipa user-add ${REPL_TEST_USER}-rev --first=Repl --last=Reverse" >/dev/null 2>&1
sleep 5

assert "user created on replica is visible on primary" \
    exec_primary "echo 'Secret123!' | kinit admin && ipa user-show ${REPL_TEST_USER}-rev"

# ── Cleanup Test Users ───────────────────────────────────────────────
exec_primary "echo 'Secret123!' | kinit admin && ipa user-del ${REPL_TEST_USER} ${REPL_TEST_USER}-rev" >/dev/null 2>&1 || true

# ── Idempotency ──────────────────────────────────────────────────────
log_info "Testing idempotency (restart container)..."
podman restart "$CNAME" 2>/dev/null
sleep 20

assert "after restart: stamp file still exists" \
    exec_in "test -f /var/lib/idm-image-mode/.firstboot-complete"

assert "after restart: ipactl status still healthy" \
    exec_in "ipactl status"

assert "after restart: firstboot did not re-run" \
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
