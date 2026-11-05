#!/bin/bash
# scripts/cu-verify.sh — Verify CU seed objects survive lifecycle transitions
#
# Runs a verification sweep against the customer-universe data created
# by cu-seed.sh. Designed to run at every lifecycle stage:
#   - After initial seed (baseline)
#   - After bootc image upgrade
#   - After bootc rollback
#   - After backup/restore
#
# Usage:
#   ./scripts/cu-verify.sh                                    # reads config.env
#   CU_DOMAIN=imagemode.test ./scripts/cu-verify.sh           # override
#   ./scripts/cu-verify.sh --stage=post-upgrade               # label output
#   ./scripts/cu-verify.sh --client=client.imagemode.test      # add client checks
#   ./scripts/cu-verify.sh --replica=replica.imagemode.test    # add replication checks

set -euo pipefail

CU_DOMAIN="${CU_DOMAIN:-${IDM_DOMAIN:-test.example.com}}"
CU_REALM="${CU_REALM:-${IDM_REALM:-$(echo "$CU_DOMAIN" | tr '[:lower:]' '[:upper:]')}}"
CU_PASSWORD="${CU_PASSWORD:-${IDM_ADMIN_PASSWORD:-Secret123!}}"
CU_USER_PASSWORD="${CU_USER_PASSWORD:-CUpass#2026test!}"
STAGE="baseline"
CLIENT_FQDN=""
REPLICA_FQDN=""
SSH_HOST=""
SKIP_SSH="${SKIP_SSH:-false}"

for arg in "$@"; do
    case "$arg" in
        --stage=*)    STAGE="${arg#*=}" ;;
        --client=*)   CLIENT_FQDN="${arg#*=}" ;;
        --replica=*)  REPLICA_FQDN="${arg#*=}" ;;
        --ssh-host=*) SSH_HOST="${arg#*=}" ;;
        --skip-ssh)   SKIP_SSH=true ;;
    esac
done

_B='\033[1m'
_G='\033[0;32m'
_R='\033[0;31m'
_Y='\033[0;33m'
_N='\033[0m'

PASS=0
FAIL=0
TOTAL=0
WARNINGS=0

assert() {
    local desc=$1
    shift
    TOTAL=$((TOTAL + 1))
    if "$@" >/dev/null 2>&1; then
        echo -e "${_G}[PASS]${_N} $desc"
        PASS=$((PASS + 1))
    else
        echo -e "${_R}[FAIL]${_N} $desc"
        FAIL=$((FAIL + 1))
    fi
}

assert_output() {
    local desc=$1
    local expected=$2
    shift 2
    TOTAL=$((TOTAL + 1))
    local output
    if output=$("$@" 2>/dev/null) && echo "$output" | grep -q "$expected"; then
        echo -e "${_G}[PASS]${_N} $desc"
        PASS=$((PASS + 1))
    else
        echo -e "${_R}[FAIL]${_N} $desc (expected: $expected)"
        FAIL=$((FAIL + 1))
    fi
}

section() {
    echo ""
    echo -e "${_B}── $* ──${_N}"
}

# ── Auth ────────────────────────────────────────────────────────────
echo "$CU_PASSWORD" | kinit admin 2>/dev/null

echo ""
echo -e "${_B}════════════════════════════════════════════════════════════${_N}"
echo -e "${_B}  CU Verification — stage: ${STAGE}${_N}"
echo -e "${_B}  domain=${CU_DOMAIN}  realm=${CU_REALM}${_N}"
echo -e "${_B}════════════════════════════════════════════════════════════${_N}"

# ── Users ───────────────────────────────────────────────────────────
section "Users (15)"

for user in sysadmin1 sysadmin2 secadmin1 \
            deployer1 deployer2 sre1 \
            dev1 dev2 dev3 \
            dba1 dba2 \
            svc-monitoring svc-backup \
            jsmith mjones; do
    assert "user $user exists" ipa user-show "$user"
done

# ── Groups + Membership ─────────────────────────────────────────────
section "Groups (6) + Membership"

assert "group it-admins exists" ipa group-show it-admins
assert_output "it-admins has sysadmin1" "sysadmin1" ipa group-show it-admins --all
assert_output "it-admins has secadmin1" "secadmin1" ipa group-show it-admins --all

assert "group devops exists" ipa group-show devops
assert_output "devops has deployer1" "deployer1" ipa group-show devops --all
assert_output "devops has sre1" "sre1" ipa group-show devops --all

assert "group developers exists" ipa group-show developers
assert_output "developers has dev1" "dev1" ipa group-show developers --all

assert "group dba exists" ipa group-show dba
assert_output "dba has dba1" "dba1" ipa group-show dba --all

assert "group svc-accounts exists" ipa group-show svc-accounts
assert_output "svc-accounts has svc-monitoring" "svc-monitoring" \
    ipa group-show svc-accounts --all

assert "group privileged-ops exists" ipa group-show privileged-ops
assert_output "privileged-ops nests it-admins" "it-admins" \
    ipa group-show privileged-ops --all
assert_output "privileged-ops nests devops" "devops" \
    ipa group-show privileged-ops --all

# ── Host Groups ─────────────────────────────────────────────────────
section "Host Groups (3)"

assert "hostgroup hg-webservers exists"  ipa hostgroup-show hg-webservers
assert "hostgroup hg-dbservers exists"   ipa hostgroup-show hg-dbservers
assert "hostgroup hg-appservers exists"  ipa hostgroup-show hg-appservers

if [[ -n "$CLIENT_FQDN" ]]; then
    assert_output "client in hg-appservers" "$CLIENT_FQDN" \
        ipa hostgroup-show hg-appservers --all
fi

# ── HBAC Rules ──────────────────────────────────────────────────────
section "HBAC Rules (4)"

assert "hbacrule allow-admins-all exists" ipa hbacrule-show allow-admins-all
assert_output "allow-admins-all has it-admins group" "it-admins" \
    ipa hbacrule-show allow-admins-all --all
assert_output "allow-admins-all has sshd service" "sshd" \
    ipa hbacrule-show allow-admins-all --all

assert "hbacrule allow-devops-app exists" ipa hbacrule-show allow-devops-app
assert_output "allow-devops-app has devops group" "devops" \
    ipa hbacrule-show allow-devops-app --all
assert_output "allow-devops-app has hg-appservers" "hg-appservers" \
    ipa hbacrule-show allow-devops-app --all

assert "hbacrule allow-dba-db exists" ipa hbacrule-show allow-dba-db
assert_output "allow-dba-db has dba group" "dba" \
    ipa hbacrule-show allow-dba-db --all
assert_output "allow-dba-db has hg-dbservers" "hg-dbservers" \
    ipa hbacrule-show allow-dba-db --all

assert "hbacrule allow-monitoring exists" ipa hbacrule-show allow-monitoring
assert_output "allow-monitoring has svc-monitoring" "svc-monitoring" \
    ipa hbacrule-show allow-monitoring --all

# HBAC evaluation tests (rule-specific, allow_all stays enabled for CI)
if [[ -n "$CLIENT_FQDN" ]]; then
    section "HBAC Evaluation (rule-specific)"

    assert_output "HBAC: sysadmin1 → client via allow-admins-all = GRANTED" \
        "Access granted: True" \
        ipa hbactest --user=sysadmin1 --host="$CLIENT_FQDN" \
            --service=sshd --rules=allow-admins-all

    assert_output "HBAC: deployer1 → client via allow-devops-app = GRANTED" \
        "Access granted: True" \
        ipa hbactest --user=deployer1 --host="$CLIENT_FQDN" \
            --service=sshd --rules=allow-devops-app

    assert_output "HBAC: dba1 → client via allow-dba-db = DENIED (wrong hostgroup)" \
        "Access granted: False" \
        ipa hbactest --user=dba1 --host="$CLIENT_FQDN" \
            --service=sshd --rules=allow-dba-db

    assert_output "HBAC: dev1 → client via allow-admins-all = DENIED (not admin)" \
        "Access granted: False" \
        ipa hbactest --user=dev1 --host="$CLIENT_FQDN" \
            --service=sshd --rules=allow-admins-all
fi

# ── Sudo Rules ──────────────────────────────────────────────────────
section "Sudo Rules (4)"

assert "sudorule sudo-admins-full exists" ipa sudorule-show sudo-admins-full
assert_output "sudo-admins-full has it-admins" "it-admins" \
    ipa sudorule-show sudo-admins-full --all

assert "sudorule sudo-devops-svc exists" ipa sudorule-show sudo-devops-svc
assert_output "sudo-devops-svc has svc-management cmdgroup" "svc-management" \
    ipa sudorule-show sudo-devops-svc --all
assert_output "sudo-devops-svc has hg-appservers" "hg-appservers" \
    ipa sudorule-show sudo-devops-svc --all

assert "sudorule sudo-dba-pg exists" ipa sudorule-show sudo-dba-pg
assert_output "sudo-dba-pg has db-management cmdgroup" "db-management" \
    ipa sudorule-show sudo-dba-pg --all
assert_output "sudo-dba-pg has hg-dbservers" "hg-dbservers" \
    ipa sudorule-show sudo-dba-pg --all

assert "sudorule sudo-monitoring exists" ipa sudorule-show sudo-monitoring
assert_output "sudo-monitoring has monitoring-readonly cmdgroup" "monitoring-readonly" \
    ipa sudorule-show sudo-monitoring --all

# ── Sudo Command Groups ────────────────────────────────────────────
section "Sudo Command Groups (3)"

assert "sudocmdgroup svc-management exists" ipa sudocmdgroup-show svc-management
assert_output "svc-management has systemctl" "systemctl" \
    ipa sudocmdgroup-show svc-management --all
assert_output "svc-management has journalctl" "journalctl" \
    ipa sudocmdgroup-show svc-management --all

assert "sudocmdgroup db-management exists" ipa sudocmdgroup-show db-management
assert_output "db-management has psql" "psql" \
    ipa sudocmdgroup-show db-management --all

assert "sudocmdgroup monitoring-readonly exists" ipa sudocmdgroup-show monitoring-readonly
assert_output "monitoring-readonly has ss" "/usr/bin/ss" \
    ipa sudocmdgroup-show monitoring-readonly --all

# ── Password Policies ──────────────────────────────────────────────
section "Password Policies (3)"

assert_output "global pwpolicy minlength=12" "12" ipa pwpolicy-show --all
assert "it-admins pwpolicy exists" ipa pwpolicy-show it-admins
assert_output "it-admins pwpolicy minlength=16" "16" ipa pwpolicy-show it-admins --all
assert "svc-accounts pwpolicy exists" ipa pwpolicy-show svc-accounts
assert_output "svc-accounts pwpolicy minlength=24" "24" ipa pwpolicy-show svc-accounts --all

# ── Automember ──────────────────────────────────────────────────────
section "Automember Rules"

assert "automember it-admins-auto exists" \
    ipa automember-show --type=group it-admins
assert "automember devops-auto exists" \
    ipa automember-show --type=group devops

# Post-upgrade: test that automember still triggers
if [[ "$STAGE" == "post-upgrade" || "$STAGE" == "post-rollback" ]]; then
    TS=$(date +%s)
    AUTOTEST_USER="autotest-${TS}"
    ipa user-add "$AUTOTEST_USER" --first=Auto --last=Test \
        --setattr=departmentnumber=100 2>/dev/null
    assert_output "automember: dept=100 user auto-added to it-admins" \
        "$AUTOTEST_USER" ipa group-show it-admins --all
    ipa user-del "$AUTOTEST_USER" 2>/dev/null || true
fi

# ── Replication ─────────────────────────────────────────────────────
if [[ -n "$REPLICA_FQDN" ]]; then
    section "Replication to ${REPLICA_FQDN}"

    assert "topology segments exist" \
        ipa topologysegment-find domain

    # Create a marker user, check it appears on replica
    MARKER="cu-repl-check-$(date +%s)"
    ipa user-add "$MARKER" --first=Repl --last=Check 2>/dev/null

    echo -e "  Waiting for replication (max 60s)..."
    REPL_OK=false
    for i in $(seq 1 12); do
        if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
               "root@${REPLICA_FQDN}" \
               "echo '$CU_PASSWORD' | kinit admin 2>/dev/null && ipa user-show $MARKER" \
               >/dev/null 2>&1; then
            REPL_OK=true
            break
        fi
        sleep 5
    done

    TOTAL=$((TOTAL + 1))
    if $REPL_OK; then
        echo -e "${_G}[PASS]${_N} marker user ${MARKER} replicated"
        PASS=$((PASS + 1))
    else
        echo -e "${_R}[FAIL]${_N} marker user ${MARKER} not replicated within 60s"
        FAIL=$((FAIL + 1))
    fi

    ipa user-del "$MARKER" 2>/dev/null || true
fi

# ── Client Identity Resolution ──────────────────────────────────────
if [[ -n "$CLIENT_FQDN" ]]; then
    section "Client Identity Resolution (${CLIENT_FQDN})"

    for user in sysadmin1 deployer1 dev1 dba1 svc-monitoring; do
        TOTAL=$((TOTAL + 1))
        if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
               "root@${CLIENT_FQDN}" \
               "id ${user}@${CU_REALM}" >/dev/null 2>&1; then
            echo -e "${_G}[PASS]${_N} ${user}@${CU_REALM} resolvable on client"
            PASS=$((PASS + 1))
        else
            echo -e "${_R}[FAIL]${_N} ${user}@${CU_REALM} NOT resolvable on client"
            FAIL=$((FAIL + 1))
        fi
    done
fi

# ── SSH Auth Tests (sshpass) ─────────────────────────────────────────
# Temporarily disables allow_all to verify HBAC enforces access control
# via real SSH. CI infra uses root+SSH key (local user, not subject to
# HBAC), so disabling allow_all won't break the test harness.
SSH_TARGET="${SSH_HOST:-${CLIENT_FQDN:-localhost}}"
if [[ "$SKIP_SSH" != "true" ]] && command -v sshpass >/dev/null 2>&1; then
    section "SSH Auth Tests (${SSH_TARGET})"
    SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o PreferredAuthentications=password -o PubkeyAuthentication=no"

    ALLOW_ALL_WAS_ENABLED=false
    if ipa hbacrule-show allow_all 2>/dev/null | grep -q "Enabled: TRUE"; then
        ALLOW_ALL_WAS_ENABLED=true
    fi
    trap 'if $ALLOW_ALL_WAS_ENABLED; then ipa hbacrule-enable allow_all >/dev/null 2>&1; fi' EXIT
    ipa hbacrule-disable allow_all >/dev/null 2>&1
    echo -e "  ${_Y}allow_all disabled for SSH test (trap re-enables on exit)${_N}"

    # Clear SSSD cache so HBAC changes take effect immediately
    sss_cache -E 2>/dev/null || true
    if [[ "$SSH_TARGET" != "localhost" ]]; then
        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            "root@${SSH_TARGET}" "sss_cache -E" >/dev/null 2>&1 || true
    fi
    sleep 3

    # SHOULD SUCCEED: sysadmin1 (it-admins → all hosts via allow-admins-all)
    TOTAL=$((TOTAL + 1))
    if sshpass -p "$CU_USER_PASSWORD" ssh $SSH_OPTS \
           "sysadmin1@${SSH_TARGET}" "whoami" >/dev/null 2>&1; then
        echo -e "${_G}[PASS]${_N} SSH: sysadmin1 → ${SSH_TARGET} (allow-admins-all)"
        PASS=$((PASS + 1))
    else
        echo -e "${_R}[FAIL]${_N} SSH: sysadmin1 → ${SSH_TARGET} DENIED (expected: allowed)"
        FAIL=$((FAIL + 1))
    fi

    # SHOULD SUCCEED: svc-monitoring (allow-monitoring → all hosts)
    TOTAL=$((TOTAL + 1))
    if sshpass -p "$CU_USER_PASSWORD" ssh $SSH_OPTS \
           "svc-monitoring@${SSH_TARGET}" "whoami" >/dev/null 2>&1; then
        echo -e "${_G}[PASS]${_N} SSH: svc-monitoring → ${SSH_TARGET} (allow-monitoring)"
        PASS=$((PASS + 1))
    else
        echo -e "${_R}[FAIL]${_N} SSH: svc-monitoring → ${SSH_TARGET} DENIED (expected: allowed)"
        FAIL=$((FAIL + 1))
    fi

    # SHOULD FAIL: dev1 (no HBAC rule grants access to this host)
    TOTAL=$((TOTAL + 1))
    if sshpass -p "$CU_USER_PASSWORD" ssh $SSH_OPTS \
           "dev1@${SSH_TARGET}" "whoami" >/dev/null 2>&1; then
        echo -e "${_R}[FAIL]${_N} SSH: dev1 → ${SSH_TARGET} ALLOWED (expected: denied)"
        FAIL=$((FAIL + 1))
    else
        echo -e "${_G}[PASS]${_N} SSH: dev1 → ${SSH_TARGET} denied (no matching HBAC rule)"
        PASS=$((PASS + 1))
    fi

    # SHOULD FAIL: dba1 (allow-dba-db targets hg-dbservers only)
    TOTAL=$((TOTAL + 1))
    if sshpass -p "$CU_USER_PASSWORD" ssh $SSH_OPTS \
           "dba1@${SSH_TARGET}" "whoami" >/dev/null 2>&1; then
        echo -e "${_R}[FAIL]${_N} SSH: dba1 → ${SSH_TARGET} ALLOWED (expected: denied)"
        FAIL=$((FAIL + 1))
    else
        echo -e "${_G}[PASS]${_N} SSH: dba1 → ${SSH_TARGET} denied (not in hg-dbservers)"
        PASS=$((PASS + 1))
    fi

    # Re-enable allow_all
    if $ALLOW_ALL_WAS_ENABLED; then
        ipa hbacrule-enable allow_all >/dev/null 2>&1
        echo -e "  ${_Y}allow_all re-enabled${_N}"
    fi
    trap - EXIT

elif [[ "$SKIP_SSH" != "true" ]]; then
    echo ""
    echo -e "  ${_Y}[SKIP] SSH auth tests: sshpass not installed${_N}"
    WARNINGS=$((WARNINGS + 1))
fi

# ── Summary ─────────────────────────────────────────────────────────
echo ""
echo -e "${_B}════════════════════════════════════════════════════════════${_N}"
echo -e "${_B}  CU Verify — ${STAGE}${_N}"
echo -e "  Total: ${TOTAL}"
echo -e "  ${_G}Pass:  ${PASS}${_N}"
if [[ $FAIL -gt 0 ]]; then
    echo -e "  ${_R}Fail:  ${FAIL}${_N}"
else
    echo -e "  Fail:  0"
fi
echo -e "${_B}════════════════════════════════════════════════════════════${_N}"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
