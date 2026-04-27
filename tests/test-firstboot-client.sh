#!/bin/bash
# tests/test-firstboot-client.sh — Verify client enrollment
#
# Prerequisites:
#   1. Client image built: ./scripts/build.sh --type=client
#   2. Primary running: ./scripts/deploy-container.sh --role=primary
#   3. Client deployed: ./scripts/deploy-container.sh --role=client

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_DIR}/scripts/lib/common.sh"

CNAME=$(container_name "client")
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

log_section "Testing client enrollment: ${CNAME}"

# ── Container Running ────────────────────────────────────────────────
assert "container is running" \
    container_running "client"

# ── Firstboot Completed ──────────────────────────────────────────────
assert "firstboot stamp file exists" \
    exec_in "test -f /var/lib/idm-image-mode/.firstboot-complete"

assert "idm-firstboot.service succeeded" \
    exec_in "systemctl is-active idm-firstboot.service"

# ── SSSD ─────────────────────────────────────────────────────────────
assert "sssd is running" \
    exec_in "systemctl is-active sssd"

# ── Identity Resolution ─────────────────────────────────────────────
assert "id admin@REALM succeeds" \
    exec_in "id admin@TEST.EXAMPLE.COM"

assert "id resolves correct UID range (>= 1866200000)" \
    exec_in "test \$(id -u admin@TEST.EXAMPLE.COM) -ge 1866200000"

# ── Kerberos ─────────────────────────────────────────────────────────
assert "kinit admin succeeds" \
    exec_in "echo '${IDM_ADMIN_PASSWORD:-Secret123!}' | kinit admin"

assert "klist shows valid TGT" \
    exec_in "echo '${IDM_ADMIN_PASSWORD:-Secret123!}' | kinit admin && klist | grep -q krbtgt/TEST.EXAMPLE.COM"

# ── Host Registration ───────────────────────────────────────────────
PRIMARY_CNAME=$(container_name "primary")
assert "client host appears in ipa host-find on primary" \
    podman exec "$PRIMARY_CNAME" bash -c \
        "echo 'Secret123!' | kinit admin && ipa host-show idm-client.test.example.com" 2>/dev/null

# ── Idempotency ──────────────────────────────────────────────────────
log_info "Testing idempotency (restart container)..."
podman restart "$CNAME" 2>/dev/null
sleep 15

assert "after restart: stamp file still exists" \
    exec_in "test -f /var/lib/idm-image-mode/.firstboot-complete"

assert "after restart: id admin still works" \
    exec_in "id admin@TEST.EXAMPLE.COM"

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
