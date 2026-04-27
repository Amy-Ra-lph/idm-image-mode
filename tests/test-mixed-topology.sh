#!/bin/bash
# tests/test-mixed-topology.sh — Verify topology works across node formats
#
# Tests that identity operations work transparently across rpm-format and
# image-mode nodes. Can target either Podman containers or lab VMs.
#
# Usage:
#   ./tests/test-mixed-topology.sh              # test containers (default)
#   ./tests/test-mixed-topology.sh --target=vm  # test lab VMs
#
# Prerequisites (containers):
#   Primary, replica, and client containers all running
#
# Prerequisites (VMs):
#   idm1 = rpm primary, idm2 = image-mode replica, idm3 = rpm client

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_DIR}/scripts/lib/common.sh"

TARGET="${1:-container}"
TARGET="${TARGET#--target=}"

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

if [[ "$TARGET" == "vm" ]]; then
    log_section "Mixed topology tests (VMs: idm1=rpm, idm2=image-mode, idm3=rpm)"
    SSH_OPTS="-o ControlPath=none -o ControlMaster=no -o ConnectTimeout=10"

    exec_primary() { ssh $SSH_OPTS idm1 "sudo bash -c '$*'"; }
    exec_replica() { ssh $SSH_OPTS idm2 "sudo bash -c '$*'"; }
    exec_client()  { ssh $SSH_OPTS idm3 "sudo bash -c '$*'"; }

    PRIMARY_DESC="idm1 (rpm)"
    REPLICA_DESC="idm2 (image-mode)"
    CLIENT_DESC="idm3 (rpm)"
    DOMAIN="test.example.com"
    REALM="TEST.EXAMPLE.COM"
    CLIENT_FQDN="idm3.test.example.com"
else
    log_section "Mixed topology tests (containers)"
    PRIMARY=$(container_name "primary")
    REPLICA=$(container_name "replica")
    CLIENT=$(container_name "client")

    exec_primary() { podman exec "$PRIMARY" bash -c "$*"; }
    exec_replica() { podman exec "$REPLICA" bash -c "$*"; }
    exec_client()  { podman exec "$CLIENT" bash -c "$*"; }

    PRIMARY_DESC="primary (container)"
    REPLICA_DESC="replica (container)"
    CLIENT_DESC="client (container)"
    DOMAIN="test.example.com"
    REALM="TEST.EXAMPLE.COM"
    CLIENT_FQDN="idm-client.test.example.com"
fi

# ── Health Checks ───────────────────────────────────────────────────
log_info "Verifying all nodes are healthy..."

assert "${PRIMARY_DESC}: ipactl status healthy" \
    exec_primary "ipactl status"

assert "${REPLICA_DESC}: ipactl status healthy" \
    exec_replica "ipactl status"

assert "${CLIENT_DESC}: id admin@${REALM} resolves" \
    exec_client "id admin@${REALM}"

# ── Kerberos Cross-Authentication ───────────────────────────────────
log_info "Testing Kerberos across formats..."

assert "kinit admin on primary" \
    exec_primary "echo 'Secret123!' | kinit admin"

assert "kinit admin on replica" \
    exec_replica "echo 'Secret123!' | kinit admin"

assert "kinit admin on client" \
    exec_client "echo 'Secret123!' | kinit admin"

# ── Forward Replication (primary → replica) ─────────────────────────
REPL_USER="mixtest-fwd-$(date +%s)"
log_info "Testing forward replication: create ${REPL_USER} on ${PRIMARY_DESC}..."

exec_primary "echo 'Secret123!' | kinit admin && ipa user-add ${REPL_USER} --first=Forward --last=Test" >/dev/null 2>&1
sleep 5

assert "user created on primary visible on replica" \
    exec_replica "echo 'Secret123!' | kinit admin && ipa user-show ${REPL_USER}"

assert "user created on primary resolvable on client" \
    exec_client "id ${REPL_USER}@${REALM}"

# ── Reverse Replication (replica → primary) ─────────────────────────
REPL_USER_REV="mixtest-rev-$(date +%s)"
log_info "Testing reverse replication: create ${REPL_USER_REV} on ${REPLICA_DESC}..."

exec_replica "echo 'Secret123!' | kinit admin && ipa user-add ${REPL_USER_REV} --first=Reverse --last=Test" >/dev/null 2>&1
sleep 5

assert "user created on replica visible on primary" \
    exec_primary "echo 'Secret123!' | kinit admin && ipa user-show ${REPL_USER_REV}"

assert "user created on replica resolvable on client" \
    exec_client "id ${REPL_USER_REV}@${REALM}"

# ── Group Replication ───────────────────────────────────────────────
log_info "Testing group operations across formats..."

exec_primary "echo 'Secret123!' | kinit admin && \
    ipa group-add mixtest-group --desc='Mixed topology test' 2>/dev/null || true && \
    ipa group-add-member mixtest-group --users=${REPL_USER} 2>/dev/null || true" >/dev/null 2>&1
sleep 3

assert "group created on primary visible on replica" \
    exec_replica "echo 'Secret123!' | kinit admin && ipa group-show mixtest-group"

assert "group membership correct on replica" \
    exec_replica "echo 'Secret123!' | kinit admin && ipa group-show mixtest-group | grep -q ${REPL_USER}"

# ── HBAC Rules Across Formats ──────────────────────────────────────
log_info "Testing HBAC rules across formats..."

exec_primary "echo 'Secret123!' | kinit admin && \
    ipa hbacrule-add mixtest-hbac --desc='Mixed topology HBAC test' 2>/dev/null || true && \
    ipa hbacrule-add-user mixtest-hbac --users=${REPL_USER} 2>/dev/null || true && \
    ipa hbacrule-add-host mixtest-hbac --hosts=${CLIENT_FQDN} 2>/dev/null || true && \
    ipa hbacrule-add-service mixtest-hbac --hbacsvcs=sshd 2>/dev/null || true" >/dev/null 2>&1
sleep 3

assert "HBAC rule created on primary visible on replica" \
    exec_replica "echo 'Secret123!' | kinit admin && ipa hbacrule-show mixtest-hbac"

assert "HBAC test: allowed user passes" \
    exec_primary "echo 'Secret123!' | kinit admin && ipa hbactest --user=${REPL_USER} --host=${CLIENT_FQDN} --service=sshd | grep -q 'Access granted: True'"

assert "HBAC test: unmatched user denied (rule-specific)" \
    exec_primary "echo 'Secret123!' | kinit admin && ipa hbactest --user=${REPL_USER_REV} --host=${CLIENT_FQDN} --service=sshd --rules=mixtest-hbac | grep -q 'Access granted: False'"

# ── Sudo Rules Across Formats ──────────────────────────────────────
log_info "Testing sudo rules across formats..."

exec_primary "echo 'Secret123!' | kinit admin && \
    ipa sudorule-add mixtest-sudo --desc='Mixed topology sudo test' 2>/dev/null || true && \
    ipa sudorule-add-user mixtest-sudo --users=${REPL_USER} 2>/dev/null || true && \
    ipa sudorule-add-host mixtest-sudo --hosts=${CLIENT_FQDN} 2>/dev/null || true && \
    ipa sudorule-add-runasuser mixtest-sudo --users=root 2>/dev/null || true && \
    ipa sudocmd-add /usr/bin/systemctl 2>/dev/null || true && \
    ipa sudorule-add-allow-command mixtest-sudo --sudocmds=/usr/bin/systemctl 2>/dev/null || true" >/dev/null 2>&1
sleep 3

assert "sudo rule created on primary visible on replica" \
    exec_replica "echo 'Secret123!' | kinit admin && ipa sudorule-show mixtest-sudo"

assert "sudo rule has correct command" \
    exec_replica "echo 'Secret123!' | kinit admin && ipa sudorule-show mixtest-sudo | grep -q systemctl"

# ── Bidirectional Policy Creation ──────────────────────────────────
log_info "Testing policy creation from replica..."

exec_replica "echo 'Secret123!' | kinit admin && \
    ipa hbacrule-add mixtest-rev-hbac --desc='Reverse HBAC' --usercat=all --hostcat=all 2>/dev/null || true && \
    ipa hbacrule-add-service mixtest-rev-hbac --hbacsvcs=httpd 2>/dev/null || true" >/dev/null 2>&1
sleep 5

assert "HBAC rule created on replica visible on primary" \
    exec_primary "echo 'Secret123!' | kinit admin && ipa hbacrule-show mixtest-rev-hbac"

# ── Topology Verification ──────────────────────────────────────────
log_info "Verifying topology segments..."

assert "topology segment exists between primary and replica" \
    exec_primary "echo 'Secret123!' | kinit admin && ipa topologysegment-find domain | grep -c . | grep -qv '^0$'"

# ── Cleanup ─────────────────────────────────────────────────────────
log_info "Cleaning up test objects..."
exec_primary "echo 'Secret123!' | kinit admin && \
    ipa hbacrule-del mixtest-hbac mixtest-rev-hbac 2>/dev/null || true && \
    ipa sudorule-del mixtest-sudo 2>/dev/null || true && \
    ipa sudocmd-del /usr/bin/systemctl 2>/dev/null || true && \
    ipa user-del ${REPL_USER} ${REPL_USER_REV} 2>/dev/null || true && \
    ipa group-del mixtest-group 2>/dev/null || true" >/dev/null 2>&1

# ── Summary ─────────────────────────────────────────────────────────
echo ""
log_section "Results (${TARGET})"
echo "  Total: ${TOTAL}"
echo "  Pass:  ${PASS}"
echo "  Fail:  ${FAIL}"

if [[ $FAIL -gt 0 ]]; then
    log_err "${FAIL} test(s) failed"
    exit 1
fi

log_ok "All ${TOTAL} tests passed"
