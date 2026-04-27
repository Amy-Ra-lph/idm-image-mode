#!/bin/bash
# tests/test-policies.sh — Verify HBAC and Sudo rules work across topology
#
# Prerequisites:
#   1. Primary, replica, and client all running
#   2. All nodes enrolled and healthy

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_DIR}/scripts/lib/common.sh"

PRIMARY=$(container_name "primary")
REPLICA=$(container_name "replica")
CLIENT=$(container_name "client")
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

exec_primary() {
    podman exec "$PRIMARY" bash -c "$*"
}

exec_replica() {
    podman exec "$REPLICA" bash -c "$*"
}

exec_client() {
    podman exec "$CLIENT" bash -c "$*"
}

kinit_primary() {
    exec_primary "echo '${IDM_ADMIN_PASSWORD:-Secret123!}' | kinit admin"
}

log_section "Testing HBAC and Sudo policies"

# ── Setup: Create test users and groups ──────────────────────────────
log_info "Creating test users and groups..."
kinit_primary

exec_primary "echo 'Secret123!' | kinit admin && \
    ipa group-add devops --desc='DevOps team' 2>/dev/null || true && \
    ipa user-add alice --first=Alice --last=Developer 2>/dev/null || true && \
    ipa user-add bob --first=Bob --last=Operator 2>/dev/null || true && \
    ipa group-add-member devops --users=bob 2>/dev/null || true"

sleep 3

# ── Verify users replicated ─────────────────────────────────────────
assert "alice visible on replica" \
    exec_replica "echo 'Secret123!' | kinit admin && ipa user-show alice"

assert "bob visible on client" \
    exec_client "id bob@TEST.EXAMPLE.COM"

assert "devops group visible on replica" \
    exec_replica "echo 'Secret123!' | kinit admin && ipa group-show devops"

# ── HBAC Rules ───────────────────────────────────────────────────────
log_info "Creating HBAC rules..."
exec_primary "echo 'Secret123!' | kinit admin && \
    ipa hbacrule-add allow_devops_ssh --desc='Allow devops SSH' 2>/dev/null || true && \
    ipa hbacrule-add-user allow_devops_ssh --groups=devops 2>/dev/null || true && \
    ipa hbacrule-add-host allow_devops_ssh --hosts=idm-client.test.example.com 2>/dev/null || true && \
    ipa hbacrule-add-service allow_devops_ssh --hbacsvcs=sshd 2>/dev/null || true"

sleep 3

assert "HBAC rule created on primary" \
    exec_primary "echo 'Secret123!' | kinit admin && ipa hbacrule-show allow_devops_ssh"

assert "HBAC rule replicated to replica" \
    exec_replica "echo 'Secret123!' | kinit admin && ipa hbacrule-show allow_devops_ssh"

assert "HBAC test: bob (devops) allowed SSH to client" \
    exec_primary "echo 'Secret123!' | kinit admin && ipa hbactest --user=bob --host=idm-client.test.example.com --service=sshd | grep -q 'Access granted: True'"

assert "HBAC test: alice (not devops) matched by allow_all only" \
    exec_primary "echo 'Secret123!' | kinit admin && ipa hbactest --user=alice --host=idm-client.test.example.com --service=sshd --rules=allow_devops_ssh | grep -q 'Access granted: False'"

# ── Sudo Rules ───────────────────────────────────────────────────────
log_info "Creating sudo rules..."
exec_primary "echo 'Secret123!' | kinit admin && \
    ipa sudorule-add devops_sudo --desc='DevOps sudo access' 2>/dev/null || true && \
    ipa sudorule-add-user devops_sudo --groups=devops 2>/dev/null || true && \
    ipa sudorule-add-host devops_sudo --hosts=idm-client.test.example.com 2>/dev/null || true && \
    ipa sudorule-add-runasuser devops_sudo --users=root 2>/dev/null || true && \
    ipa sudorule-add-option devops_sudo --sudooption='!authenticate' 2>/dev/null || true && \
    ipa sudocmd-add /usr/bin/systemctl 2>/dev/null || true && \
    ipa sudorule-add-allow-command devops_sudo --sudocmds=/usr/bin/systemctl 2>/dev/null || true"

sleep 3

assert "sudo rule created on primary" \
    exec_primary "echo 'Secret123!' | kinit admin && ipa sudorule-show devops_sudo"

assert "sudo rule replicated to replica" \
    exec_replica "echo 'Secret123!' | kinit admin && ipa sudorule-show devops_sudo"

assert "sudo rule has correct command (/usr/bin/systemctl)" \
    exec_primary "echo 'Secret123!' | kinit admin && ipa sudorule-show devops_sudo | grep -q systemctl"

assert "sudo rule has correct host (client)" \
    exec_primary "echo 'Secret123!' | kinit admin && ipa sudorule-show devops_sudo | grep -q idm-client"

# ── Bidirectional Policy Creation ────────────────────────────────────
log_info "Testing policy creation from replica..."
exec_replica "echo 'Secret123!' | kinit admin && \
    ipa hbacrule-add allow_all_web --desc='Allow all web access' --usercat=all --hostcat=all 2>/dev/null || true && \
    ipa hbacrule-add-service allow_all_web --hbacsvcs=httpd 2>/dev/null || true"

sleep 5

assert "HBAC rule created on replica visible on primary" \
    exec_primary "echo 'Secret123!' | kinit admin && ipa hbacrule-show allow_all_web"

# ── Cleanup ──────────────────────────────────────────────────────────
log_info "Cleaning up test objects..."
exec_primary "echo 'Secret123!' | kinit admin && \
    ipa hbacrule-del allow_devops_ssh allow_all_web 2>/dev/null || true && \
    ipa sudorule-del devops_sudo 2>/dev/null || true && \
    ipa sudocmd-del /usr/bin/systemctl 2>/dev/null || true && \
    ipa user-del alice bob 2>/dev/null || true && \
    ipa group-del devops 2>/dev/null || true" >/dev/null 2>&1

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
