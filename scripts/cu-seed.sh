#!/bin/bash
# scripts/cu-seed.sh — Populate a customer-like IdM environment
#
# Creates users, groups, host groups, HBAC rules, sudo rules, and
# password policies that approximate a real deployment. Idempotent —
# safe to run multiple times.
#
# Usage:
#   ./scripts/cu-seed.sh                          # reads config.env
#   CU_DOMAIN=imagemode.test ./scripts/cu-seed.sh # override domain
#   CU_CLIENT_FQDN=client.imagemode.test ./scripts/cu-seed.sh

set -euo pipefail

CU_DOMAIN="${CU_DOMAIN:-${IDM_DOMAIN:-test.example.com}}"
CU_REALM="${CU_REALM:-${IDM_REALM:-$(echo "$CU_DOMAIN" | tr '[:lower:]' '[:upper:]')}}"
CU_PASSWORD="${CU_PASSWORD:-${IDM_ADMIN_PASSWORD:-Secret123!}}"
CU_USER_PASSWORD="${CU_USER_PASSWORD:-CUpass#2026test!}"
CU_CLIENT_FQDN="${CU_CLIENT_FQDN:-}"

_B='\033[1m'
_G='\033[0;32m'
_R='\033[0;31m'
_Y='\033[0;33m'
_N='\033[0m'

info()  { echo -e "${_B}[cu-seed]${_N} $*"; }
ok()    { echo -e "${_G}[  ok  ]${_N} $*"; }
warn()  { echo -e "${_Y}[ warn ]${_N} $*"; }
err()   { echo -e "${_R}[ err  ]${_N} $*" >&2; }

section() {
    echo ""
    echo -e "${_B}── $* ──${_N}"
}

ipa_add() {
    "$@" 2>/dev/null && return 0
    return 0
}

# ── Auth ────────────────────────────────────────────────────────────
echo "$CU_PASSWORD" | kinit admin 2>/dev/null
info "Seeding CU for domain=${CU_DOMAIN} realm=${CU_REALM}"
if [[ -n "$CU_CLIENT_FQDN" ]]; then
    info "Client FQDN: ${CU_CLIENT_FQDN}"
fi

# ── Users ───────────────────────────────────────────────────────────
section "Users (15)"

declare -A USERS=(
    # IT Admins
    [sysadmin1]="Sys Admin1:100"
    [sysadmin2]="Sys Admin2:100"
    [secadmin1]="Sec Admin1:100"
    # DevOps
    [deployer1]="Deploy Er1:150"
    [deployer2]="Deploy Er2:150"
    [sre1]="Site Reliab1:150"
    # Developers
    [dev1]="Dev Eloper1:200"
    [dev2]="Dev Eloper2:200"
    [dev3]="Dev Eloper3:200"
    # DBAs
    [dba1]="Data Base1:300"
    [dba2]="Data Base2:300"
    # Service accounts
    [svc-monitoring]="Service Monitoring:900"
    [svc-backup]="Service Backup:900"
    # Regular users (for automember testing)
    [jsmith]="Jane Smith:200"
    [mjones]="Mike Jones:100"
)

for user in "${!USERS[@]}"; do
    IFS=: read -r fullname dept <<< "${USERS[$user]}"
    first="${fullname%% *}"
    last="${fullname#* }"
    ipa_add ipa user-add "$user" \
        --first="$first" --last="$last" \
        --setattr=departmentnumber="$dept"
done
ok "15 users created"

# Set passwords (before password policies are tightened)
info "Setting user passwords for SSH auth testing..."
for user in "${!USERS[@]}"; do
    echo -e "${CU_USER_PASSWORD}\n${CU_USER_PASSWORD}" | ipa passwd "$user" 2>/dev/null || true
    ipa_add ipa user-mod "$user" --setattr=krbPasswordExpiration=20281231235959Z
done
ok "Passwords set (${CU_USER_PASSWORD}), forced-change cleared"

# ── Groups ──────────────────────────────────────────────────────────
section "Groups (6)"

ipa_add ipa group-add it-admins    --desc="IT Administrators — full system access"
ipa_add ipa group-add devops       --desc="DevOps / SRE — application server access"
ipa_add ipa group-add developers   --desc="Software developers — limited access"
ipa_add ipa group-add dba          --desc="Database administrators"
ipa_add ipa group-add svc-accounts --desc="Non-human service accounts"
ipa_add ipa group-add privileged-ops --desc="Nested: it-admins + devops"

# Memberships
ipa_add ipa group-add-member it-admins    --users=sysadmin1 --users=sysadmin2 --users=secadmin1
ipa_add ipa group-add-member devops       --users=deployer1 --users=deployer2 --users=sre1
ipa_add ipa group-add-member developers   --users=dev1 --users=dev2 --users=dev3
ipa_add ipa group-add-member dba          --users=dba1 --users=dba2
ipa_add ipa group-add-member svc-accounts --users=svc-monitoring --users=svc-backup

# Nested group
ipa_add ipa group-add-member privileged-ops --groups=it-admins --groups=devops

ok "6 groups with memberships"

# ── Host Groups ─────────────────────────────────────────────────────
section "Host Groups (3)"

ipa_add ipa hostgroup-add hg-webservers  --desc="Web/proxy servers"
ipa_add ipa hostgroup-add hg-dbservers   --desc="Database servers"
ipa_add ipa hostgroup-add hg-appservers  --desc="Application servers"

if [[ -n "$CU_CLIENT_FQDN" ]]; then
    ipa_add ipa hostgroup-add-member hg-appservers --hosts="$CU_CLIENT_FQDN"
    ok "Client ${CU_CLIENT_FQDN} added to hg-appservers"
fi

ok "3 host groups"

# ── HBAC Rules ──────────────────────────────────────────────────────
# NOTE: allow_all stays enabled for CI safety. Rules tested via
# ipa hbactest --rules=<name> which evaluates a specific rule only.
section "HBAC Rules (4)"

ipa_add ipa hbacrule-add allow-admins-all \
    --desc="IT admins: SSH to all hosts"
ipa_add ipa hbacrule-add-user allow-admins-all --groups=it-admins
ipa_add ipa hbacrule-mod allow-admins-all --hostcat=all
ipa_add ipa hbacrule-add-service allow-admins-all --hbacsvcs=sshd

ipa_add ipa hbacrule-add allow-devops-app \
    --desc="DevOps: SSH to app+web servers"
ipa_add ipa hbacrule-add-user allow-devops-app --groups=devops
ipa_add ipa hbacrule-add-host allow-devops-app --hostgroups=hg-appservers
ipa_add ipa hbacrule-add-host allow-devops-app --hostgroups=hg-webservers
ipa_add ipa hbacrule-add-service allow-devops-app --hbacsvcs=sshd

ipa_add ipa hbacrule-add allow-dba-db \
    --desc="DBAs: SSH to database servers only"
ipa_add ipa hbacrule-add-user allow-dba-db --groups=dba
ipa_add ipa hbacrule-add-host allow-dba-db --hostgroups=hg-dbservers
ipa_add ipa hbacrule-add-service allow-dba-db --hbacsvcs=sshd

ipa_add ipa hbacrule-add allow-monitoring \
    --desc="Monitoring service: SSH everywhere"
ipa_add ipa hbacrule-add-user allow-monitoring --users=svc-monitoring
ipa_add ipa hbacrule-mod allow-monitoring --hostcat=all
ipa_add ipa hbacrule-add-service allow-monitoring --hbacsvcs=sshd

ok "4 HBAC rules"

# ── Sudo Commands ───────────────────────────────────────────────────
section "Sudo Commands + Command Groups"

for cmd in /usr/bin/systemctl /usr/bin/journalctl /usr/bin/podman \
           /usr/bin/psql /usr/bin/pg_dump /usr/bin/pg_restore \
           /usr/bin/ss /usr/bin/df /usr/bin/free /usr/bin/top; do
    ipa_add ipa sudocmd-add "$cmd"
done

ipa_add ipa sudocmdgroup-add svc-management --desc="Service management commands"
ipa_add ipa sudocmdgroup-add-member svc-management \
    --sudocmds=/usr/bin/systemctl,/usr/bin/journalctl,/usr/bin/podman

ipa_add ipa sudocmdgroup-add db-management --desc="Database management commands"
ipa_add ipa sudocmdgroup-add-member db-management \
    --sudocmds=/usr/bin/psql,/usr/bin/pg_dump,/usr/bin/pg_restore

ipa_add ipa sudocmdgroup-add monitoring-readonly --desc="Read-only diagnostic commands"
ipa_add ipa sudocmdgroup-add-member monitoring-readonly \
    --sudocmds=/usr/bin/ss,/usr/bin/df,/usr/bin/free,/usr/bin/top

ok "10 sudo commands, 3 command groups"

# ── Sudo Rules ──────────────────────────────────────────────────────
section "Sudo Rules (4)"

ipa_add ipa sudorule-add sudo-admins-full \
    --desc="IT admins: full sudo everywhere"
ipa_add ipa sudorule-add-user sudo-admins-full --groups=it-admins
ipa_add ipa sudorule-mod sudo-admins-full --hostcat=all --cmdcat=all
ipa_add ipa sudorule-add-runasuser sudo-admins-full --users=root

ipa_add ipa sudorule-add sudo-devops-svc \
    --desc="DevOps: service management on app servers"
ipa_add ipa sudorule-add-user sudo-devops-svc --groups=devops
ipa_add ipa sudorule-add-host sudo-devops-svc --hostgroups=hg-appservers
ipa_add ipa sudorule-add-allow-command sudo-devops-svc --sudocmdgroups=svc-management
ipa_add ipa sudorule-add-runasuser sudo-devops-svc --users=root
ipa_add ipa sudorule-add-option sudo-devops-svc --sudooption='!authenticate'

ipa_add ipa sudorule-add sudo-dba-pg \
    --desc="DBAs: database tools on DB servers"
ipa_add ipa sudorule-add-user sudo-dba-pg --groups=dba
ipa_add ipa sudorule-add-host sudo-dba-pg --hostgroups=hg-dbservers
ipa_add ipa sudorule-add-allow-command sudo-dba-pg --sudocmdgroups=db-management
ipa_add ipa sudorule-add-runasuser sudo-dba-pg --users=root

ipa_add ipa sudorule-add sudo-monitoring \
    --desc="Monitoring: read-only diagnostics everywhere"
ipa_add ipa sudorule-add-user sudo-monitoring --users=svc-monitoring
ipa_add ipa sudorule-mod sudo-monitoring --hostcat=all
ipa_add ipa sudorule-add-allow-command sudo-monitoring --sudocmdgroups=monitoring-readonly
ipa_add ipa sudorule-add-runasuser sudo-monitoring --users=root

ok "4 sudo rules with command groups"

# ── Password Policies ──────────────────────────────────────────────
section "Password Policies (3)"

# Global default (maxlife is in days)
ipa_add ipa pwpolicy-mod --minlength=12 --maxlife=90 --minclasses=3

# IT admins — stricter
ipa_add ipa pwpolicy-add it-admins \
    --minlength=16 --maxlife=60 --minclasses=4 --priority=10

# Service accounts — long passwords, no expiry
ipa_add ipa pwpolicy-add svc-accounts \
    --minlength=24 --maxlife=0 --priority=20

ok "3 password policies (global + it-admins + svc-accounts)"

# ── Automember Rules ───────────────────────────────────────────────
section "Automember Rules (2)"

ipa_add ipa automember-default-group-set --type=group --default-group=developers
ipa_add ipa automember-add --type=group it-admins
ipa_add ipa automember-add-condition it-admins --type=group \
    --key=departmentnumber --inclusive-regex='^100$'
ipa_add ipa automember-add --type=group devops
ipa_add ipa automember-add-condition devops --type=group \
    --key=departmentnumber --inclusive-regex='^150$'

ok "2 automember rules (dept 100→it-admins, 150→devops) + default→developers"

# ── Summary ─────────────────────────────────────────────────────────
section "CU Seed Complete"
echo "  Users:            15"
echo "  Groups:           6 (1 nested)"
echo "  Host groups:      3"
echo "  HBAC rules:       4"
echo "  Sudo rules:       4 (3 command groups, 10 commands)"
echo "  Password policies: 3"
echo "  Automember rules: 2"
echo ""
info "Run cu-verify.sh to validate"
