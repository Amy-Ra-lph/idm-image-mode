#!/bin/bash
# test-security-assessment.sh — STRIDE-based security checks for IdM Image Mode + Arbiter Hub
#
# Runs against live cluster VMs via SSH. Covers:
#   S — Spoofing:     credential exposure, auth bypass, token validation
#   T — Tampering:    file integrity, SELinux, config mutability
#   R — Repudiation:  audit logging, journal namespaces
#   I — Info Disclosure: secret exposure, network services, TLS
#   D — Denial of Service: resource limits, crash recovery
#   E — Elevation:    privilege boundaries, RBAC, sandbox escape
#
# Usage:
#   ./test-security-assessment.sh <primary_ip> [hub_ip] [agent_ip]
#
# Requires: SSH key access as root (idm_ci_key)

set -u

PRIMARY_IP="${1:?Usage: $0 <primary_ip> [hub_ip] [agent_ip]}"
HUB_IP="${2:-}"
AGENT_IP="${3:-}"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/idm_ci_key}"
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -i ${SSH_KEY}"

PASS=0 FAIL=0 WARN=0 SKIP=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
warn() { echo "  WARN: $1"; WARN=$((WARN+1)); }
skip() { echo "  SKIP: $1"; SKIP=$((SKIP+1)); }

run_on() {
    local host=$1; shift
    $SSH "root@${host}" "$@" 2>/dev/null
}

run_on_sudo() {
    local host=$1; shift
    $SSH "fedora@${host}" "sudo $*" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════════
echo "=== STRIDE Security Assessment ==="
echo "Primary: ${PRIMARY_IP}"
[ -n "$HUB_IP" ] && echo "Hub:     ${HUB_IP}"
[ -n "$AGENT_IP" ] && echo "Agent:   ${AGENT_IP}"
echo ""

# ─── S: SPOOFING ─────────────────────────────────────────────────
echo "── S: Spoofing Identity ──"

# S1: config.env should not contain plaintext passwords after firstboot
if run_on "$PRIMARY_IP" 'test -f /etc/idm-image-mode/config.env && grep -E "PASSWORD\s*=\s*[^<]" /etc/idm-image-mode/config.env | grep -qv REDACTED'; then
    fail "S1: config.env still contains plaintext passwords after firstboot"
else
    pass "S1: config.env passwords redacted (or file removed)"
fi

# S2: ahdapa client secrets in clients.toml — check file permissions
CLIENTS_PERMS=$(run_on "$PRIMARY_IP" 'stat -c "%a %U:%G" /etc/ahdapa/clients.toml 2>/dev/null')
if echo "$CLIENTS_PERMS" | grep -q "640 ahdapa:ahdapa"; then
    pass "S2: clients.toml restricted (640 ahdapa:ahdapa)"
elif echo "$CLIENTS_PERMS" | grep -qE "^6[04]0"; then
    warn "S2: clients.toml perms: ${CLIENTS_PERMS} (expected 640 ahdapa:ahdapa)"
else
    fail "S2: clients.toml too permissive: ${CLIENTS_PERMS}"
fi

# S3: ahdapa.toml permissions
TOML_PERMS=$(run_on "$PRIMARY_IP" 'stat -c "%a %U:%G" /etc/ahdapa/ahdapa.toml 2>/dev/null')
if echo "$TOML_PERMS" | grep -q "640 ahdapa:ahdapa"; then
    pass "S3: ahdapa.toml restricted (640 ahdapa:ahdapa)"
else
    fail "S3: ahdapa.toml perms: ${TOML_PERMS}"
fi

# S4: OIDC tokens use ES256 (not none/HS256)
TOKEN_RESP=$(run_on "$PRIMARY_IP" '
  curl -sk -u "test-client:test-secret-value-123" \
    -X POST "https://$(hostname -f)/idp/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&scope=openid" 2>/dev/null')
if echo "$TOKEN_RESP" | python3 -c "
import sys,json,base64
t=json.load(sys.stdin).get('access_token','')
header=json.loads(base64.urlsafe_b64decode(t.split('.')[0]+'=='))
alg=header.get('alg','')
print(alg)
sys.exit(0 if alg in ('ES256','ES384','ES512','EdDSA') else 1)
" 2>/dev/null; then
    pass "S4: JWT uses asymmetric signing ($(echo "$TOKEN_RESP" | python3 -c "import sys,json,base64; t=json.load(sys.stdin)['access_token']; print(json.loads(base64.urlsafe_b64decode(t.split('.')[0]+'=='))['alg'])" 2>/dev/null))"
else
    fail "S4: JWT signing algorithm not asymmetric"
fi

# S5: OIDC discovery issuer matches configured issuer
ISSUER=$(run_on "$PRIMARY_IP" 'curl -sk "https://$(hostname -f)/idp/.well-known/openid-configuration" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get(\"issuer\",\"\"))"')
EXPECTED="https://$(run_on "$PRIMARY_IP" 'hostname -f')/idp"
if [ "$ISSUER" = "$EXPECTED" ]; then
    pass "S5: OIDC issuer matches hostname (${ISSUER})"
else
    fail "S5: OIDC issuer mismatch: got ${ISSUER}, expected ${EXPECTED}"
fi

# S6: gssproxy keytab not world-readable
KEYTAB_PERMS=$(run_on "$PRIMARY_IP" 'stat -c "%a" /var/lib/ipa/gssproxy/http.keytab 2>/dev/null')
if [ "${KEYTAB_PERMS:-777}" -le 640 ] 2>/dev/null; then
    pass "S6: HTTP keytab restricted (${KEYTAB_PERMS})"
else
    fail "S6: HTTP keytab too permissive (${KEYTAB_PERMS})"
fi

# S7: No anonymous LDAP bind
ANON_BIND=$(run_on "$PRIMARY_IP" 'ldapsearch -x -b "" -s base namingContexts 2>&1 | grep -c "namingContexts"')
if [ "${ANON_BIND:-0}" -eq 0 ]; then
    pass "S7: Anonymous LDAP bind returns no naming contexts"
else
    warn "S7: Anonymous LDAP bind returns ${ANON_BIND} naming contexts"
fi

echo ""
# ─── T: TAMPERING ────────────────────────────────────────────────
echo "── T: Tampering ──"

# T1: SELinux enforcing
SELINUX=$(run_on "$PRIMARY_IP" 'getenforce 2>/dev/null')
if [ "$SELINUX" = "Enforcing" ]; then
    pass "T1: SELinux enforcing on primary"
else
    fail "T1: SELinux ${SELINUX:-unknown} on primary (expected Enforcing)"
fi

# T2: ahdapa SELinux module loaded
if run_on "$PRIMARY_IP" 'semodule -l 2>/dev/null | grep -q "^ahdapa"'; then
    pass "T2: ahdapa SELinux policy module loaded"
else
    warn "T2: ahdapa SELinux policy module not found"
fi

# T3: bootc filesystem immutability — /usr is read-only
if run_on "$PRIMARY_IP" 'touch /usr/.security-test 2>/dev/null'; then
    fail "T3: /usr is writable (bootc immutability broken)"
    run_on "$PRIMARY_IP" 'rm -f /usr/.security-test' 2>/dev/null
else
    pass "T3: /usr is read-only (bootc immutability intact)"
fi

# T4: ahdapa service hardening (ProtectSystem=strict)
if run_on "$PRIMARY_IP" 'systemctl show ahdapa -p ProtectSystem 2>/dev/null | grep -q strict'; then
    pass "T4: ahdapa ProtectSystem=strict"
else
    fail "T4: ahdapa missing ProtectSystem=strict"
fi

# T5: ahdapa runs as non-root
AHDAPA_USER=$(run_on "$PRIMARY_IP" 'ps -o user= -p $(pgrep ahdapa) 2>/dev/null | head -1')
if [ "$AHDAPA_USER" = "ahdapa" ]; then
    pass "T5: ahdapa runs as dedicated user (ahdapa)"
else
    fail "T5: ahdapa runs as ${AHDAPA_USER:-unknown}"
fi

# T6: NoNewPrivileges on ahdapa
if run_on "$PRIMARY_IP" 'systemctl show ahdapa -p NoNewPrivileges 2>/dev/null | grep -q yes'; then
    pass "T6: ahdapa NoNewPrivileges=yes"
else
    fail "T6: ahdapa missing NoNewPrivileges"
fi

# T7: httpd proxy config not writable by ahdapa
PROXY_OWNER=$(run_on "$PRIMARY_IP" 'stat -c "%U" /etc/httpd/conf.d/ipa-idp-proxy.conf 2>/dev/null')
if [ "$PROXY_OWNER" = "root" ]; then
    pass "T7: httpd proxy config owned by root"
else
    fail "T7: httpd proxy config owned by ${PROXY_OWNER}"
fi

echo ""
# ─── R: REPUDIATION ──────────────────────────────────────────────
echo "── R: Repudiation ──"

# R1: ahdapa audit journal namespace exists and has entries
JOURNAL_COUNT=$(run_on "$PRIMARY_IP" 'journalctl --namespace=ahdapa --no-pager -q 2>/dev/null | wc -l')
if [ "${JOURNAL_COUNT:-0}" -gt 0 ]; then
    pass "R1: ahdapa journal namespace has ${JOURNAL_COUNT} entries"
else
    fail "R1: ahdapa journal namespace empty or missing"
fi

# R2: IPA audit log captures admin actions
if run_on "$PRIMARY_IP" 'ls /var/log/dirsrv/slapd-*/access 2>/dev/null | head -1 | xargs test -s'; then
    pass "R2: 389-ds access log exists and non-empty"
else
    fail "R2: 389-ds access log missing"
fi

# R3: httpd access log captures /idp/ requests
if run_on "$PRIMARY_IP" 'grep -q "/idp/" /var/log/httpd/access_log 2>/dev/null'; then
    pass "R3: httpd logs /idp/ requests"
else
    warn "R3: no /idp/ entries in httpd access log yet"
fi

echo ""
# ─── I: INFORMATION DISCLOSURE ───────────────────────────────────
echo "── I: Information Disclosure ──"

# I1: TLS on HTTPS endpoints
TLS_VERSION=$(run_on "$PRIMARY_IP" 'curl -sk -v "https://$(hostname -f)/idp/" 2>&1 | grep "SSL connection" | grep -oP "TLSv[\d.]+"')
if echo "$TLS_VERSION" | grep -qE "TLSv1\.[23]"; then
    pass "I1: HTTPS uses ${TLS_VERSION}"
else
    warn "I1: TLS version: ${TLS_VERSION:-unknown}"
fi

# I2: ahdapa database not world-readable
DB_PERMS=$(run_on "$PRIMARY_IP" 'stat -c "%a %U:%G" /var/lib/ahdapa/ahdapa.db 2>/dev/null')
if echo "$DB_PERMS" | grep -qE "^6[04]0.*ahdapa"; then
    pass "I2: ahdapa.db restricted (${DB_PERMS})"
else
    fail "I2: ahdapa.db perms: ${DB_PERMS:-not found}"
fi

# I3: CORS not wildcard in production (warn for PoC)
CORS=$(run_on "$PRIMARY_IP" 'grep "Access-Control-Allow-Origin" /etc/httpd/conf.d/ipa-idp-cors.conf 2>/dev/null')
if echo "$CORS" | grep -q '"[*]"'; then
    warn "I3: CORS allows wildcard origin (acceptable for PoC, restrict for production)"
else
    pass "I3: CORS origin restricted"
fi

# I4: No sensitive headers leaked in OIDC discovery
DISCO=$(run_on "$PRIMARY_IP" 'curl -sk -D- "https://$(hostname -f)/idp/.well-known/openid-configuration" 2>/dev/null | head -20')
if echo "$DISCO" | grep -qi "x-powered-by\|server:.*ahdapa"; then
    warn "I4: Server identity leaked in response headers"
else
    pass "I4: No server identity in OIDC discovery headers"
fi

# I5: cloud-init userdata not accessible after boot
if run_on "$PRIMARY_IP" 'curl -sf --connect-timeout 2 http://169.254.169.254/latest/user-data 2>/dev/null | grep -q PASSWORD'; then
    fail "I5: Instance metadata still serves passwords via userdata"
else
    pass "I5: Instance metadata not serving passwords"
fi

# I6: No secrets in environment variables
AHDAPA_ENV=$(run_on "$PRIMARY_IP" 'tr "\0" "\n" < /proc/$(pgrep -x ahdapa | head -1)/environ 2>/dev/null | grep -ciE "password|secret|token|key=" || true')
AHDAPA_ENV=$(echo "$AHDAPA_ENV" | tr -d '[:space:]')
if [ "${AHDAPA_ENV:-0}" -eq 0 ] 2>/dev/null; then
    pass "I6: No secrets in ahdapa process environment"
else
    fail "I6: ${AHDAPA_ENV} potential secrets in ahdapa environment"
fi

echo ""
# ─── D: DENIAL OF SERVICE ───────────────────────────────────────
echo "── D: Denial of Service ──"

# D1: ahdapa restart recovery
run_on "$PRIMARY_IP" 'systemctl restart ahdapa 2>/dev/null; sleep 3'
if run_on "$PRIMARY_IP" 'systemctl is-active ahdapa 2>/dev/null | grep -qx active'; then
    pass "D1: ahdapa recovers after restart"
else
    fail "D1: ahdapa did not recover after restart"
fi

# D2: systemd resource limits set
if run_on "$PRIMARY_IP" 'systemctl show ahdapa -p MemoryDenyWriteExecute 2>/dev/null | grep -q yes'; then
    pass "D2: ahdapa MemoryDenyWriteExecute=yes"
else
    warn "D2: ahdapa missing MemoryDenyWriteExecute"
fi

# D3: Token endpoint rate — not exhaustive, just verify it responds under load
RATE_OK=$(run_on "$PRIMARY_IP" '
  for i in $(seq 1 10); do
    curl -sk -o /dev/null -w "%{http_code}\n" -u "test-client:test-secret-value-123" \
      -X POST "https://$(hostname -f)/idp/token" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "grant_type=client_credentials&scope=openid" &
  done
  wait
' 2>/dev/null | grep -c "200")
if [ "${RATE_OK:-0}" -ge 8 ]; then
    pass "D3: Token endpoint handles 10 concurrent requests (${RATE_OK}/10 OK)"
else
    warn "D3: Token endpoint: only ${RATE_OK}/10 succeeded under load"
fi

echo ""
# ─── E: ELEVATION OF PRIVILEGE ───────────────────────────────────
echo "── E: Elevation of Privilege ──"

# E1: ahdapa service has PrivateTmp enabled
if run_on "$PRIMARY_IP" 'systemctl show ahdapa -p PrivateTmp 2>/dev/null | grep -q yes'; then
    pass "E1: ahdapa PrivateTmp=yes"
else
    fail "E1: ahdapa missing PrivateTmp"
fi

# E2: RBAC — non-admin user cannot list clients
E2_RESP=$(run_on "$PRIMARY_IP" '
  echo Secret123! | kinit admin 2>/dev/null
  ipa user-add sectest --first=Sec --last=Test 2>/dev/null || true
  echo "TempPass#123" | ipa passwd sectest 2>/dev/null || true
  kdestroy 2>/dev/null
  echo "TempPass#123" | kinit sectest 2>/dev/null || true
  curl -sk --negotiate -u : "https://$(hostname -f)/idp/admin/clients" 2>/dev/null
  kdestroy 2>/dev/null
  echo Secret123! | kinit admin 2>/dev/null
  ipa user-del sectest 2>/dev/null || true
')
if echo "$E2_RESP" | grep -qiE "forbidden\|unauthorized\|403\|401"; then
    pass "E2: Non-admin user denied access to /idp/admin/clients"
else
    warn "E2: Non-admin /idp/admin/clients response unclear"
fi

# E3: SystemCallFilter restricts dangerous syscalls (expanded output won't contain @group name)
SYSCALL_FILTER=$(run_on "$PRIMARY_IP" 'systemctl show ahdapa -p SystemCallFilter 2>/dev/null')
if [ -n "$SYSCALL_FILTER" ] && echo "$SYSCALL_FILTER" | grep -q "execve"; then
    pass "E3: ahdapa SystemCallFilter active (seccomp)"
else
    warn "E3: ahdapa SystemCallFilter not set"
fi

# E4: ahdapa socket permissions
SOCK_PERMS=$(run_on "$PRIMARY_IP" 'stat -c "%a %U:%G" /run/ahdapa/ahdapa.sock 2>/dev/null')
if echo "$SOCK_PERMS" | grep -qE "^66[02]"; then
    pass "E4: ahdapa socket restricted (${SOCK_PERMS})"
else
    warn "E4: ahdapa socket perms: ${SOCK_PERMS:-not found}"
fi

# ─── Arbiter Hub checks (if hub IP provided) ────────────────────
if [ -n "$HUB_IP" ]; then
    echo ""
    echo "── Arbiter Hub ──"

    # AH1: Hub API requires authentication on sensitive endpoints
    AH1_CODE=$(run_on_sudo "$HUB_IP" 'curl -sk -o /dev/null -w "%{http_code}" http://localhost:8400/workloads 2>/dev/null')
    if [ "${AH1_CODE}" = "401" ] || [ "${AH1_CODE}" = "403" ]; then
        pass "AH1: Hub API requires auth (${AH1_CODE})"
    elif [ "${AH1_CODE}" = "000" ] || [ -z "${AH1_CODE}" ]; then
        skip "AH1: Hub API not reachable (not deployed yet?)"
    else
        fail "AH1: Hub API /workloads returns ${AH1_CODE} without auth (should require auth)"
    fi

    # AH2: PostgreSQL not exposed on host network (runs in podman network)
    if run_on_sudo "$HUB_IP" 'ss -tlnp | grep "5432" | grep -q "0.0.0.0"'; then
        fail "AH2: PostgreSQL listening on all host interfaces"
    else
        pass "AH2: PostgreSQL not exposed on host network"
    fi

    # AH3: enforcement-mcp running
    if run_on_sudo "$HUB_IP" 'systemctl is-active enforcement-mcp 2>/dev/null | grep -qx active' || \
       run_on_sudo "$HUB_IP" 'podman ps 2>/dev/null | grep -q enforcement'; then
        pass "AH3: enforcement-mcp running"
    else
        skip "AH3: enforcement-mcp not deployed"
    fi

    # AH4: SELinux enforcing on hub
    HUB_SE=$(run_on_sudo "$HUB_IP" 'getenforce 2>/dev/null')
    if [ "$HUB_SE" = "Enforcing" ]; then
        pass "AH4: SELinux enforcing on hub"
    else
        fail "AH4: SELinux ${HUB_SE:-unknown} on hub"
    fi
fi

# ─── Agent checks (if agent IP provided) ────────────────────────
if [ -n "$AGENT_IP" ]; then
    echo ""
    echo "── Agent Node ──"

    # AG1: Keylime agent running
    if run_on_sudo "$AGENT_IP" 'systemctl is-active keylime_agent 2>/dev/null | grep -qx active'; then
        pass "AG1: Keylime agent running"
    else
        skip "AG1: Keylime agent not deployed"
    fi

    # AG2: Falco running
    if run_on_sudo "$AGENT_IP" 'systemctl is-active falco 2>/dev/null | grep -qx active' || \
       run_on_sudo "$AGENT_IP" 'podman ps 2>/dev/null | grep -q falco'; then
        pass "AG2: Falco runtime monitor running"
    else
        skip "AG2: Falco not deployed"
    fi

    # AG3: SELinux enforcing on agent
    AGENT_SE=$(run_on_sudo "$AGENT_IP" 'getenforce 2>/dev/null')
    if [ "$AGENT_SE" = "Enforcing" ]; then
        pass "AG3: SELinux enforcing on agent"
    else
        fail "AG3: SELinux ${AGENT_SE:-unknown} on agent"
    fi

    # AG4: OpenShell sandbox isolation
    if run_on_sudo "$AGENT_IP" 'podman ps --format "{{.Names}}" 2>/dev/null | grep -q openshell'; then
        pass "AG4: OpenShell sandbox containers running"
    else
        skip "AG4: OpenShell not deployed"
    fi
fi

# ═══════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════"
echo "  STRIDE Assessment: ${PASS} pass, ${FAIL} fail, ${WARN} warn, ${SKIP} skip"
echo "═══════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
