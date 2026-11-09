#!/bin/bash
# idm-firstboot — First boot provisioning for IdM Image Mode nodes
#
# Reads /etc/idm-image-mode/config.env and runs the appropriate
# FreeIPA installer based on IDM_ROLE (primary, replica, client).
#
# This script runs exactly once via idm-firstboot.service.
# The stamp file at /var/lib/idm-image-mode/.firstboot-complete
# prevents re-execution on subsequent boots.

set -euo pipefail

CONFIG_FILE="/etc/idm-image-mode/config.env"
LOG_PREFIX="[idm-firstboot]"

log_info() { echo "${LOG_PREFIX} INFO: $*"; }
log_err()  { echo "${LOG_PREFIX} ERROR: $*" >&2; }
log_ok()   { echo "${LOG_PREFIX} OK: $*"; }

# ── Load Config ──────────────────────────────────────────────────────
if [[ ! -f "$CONFIG_FILE" ]]; then
    log_err "Config file not found: $CONFIG_FILE"
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# ── Validate Required Variables ──────────────────────────────────────
required_vars=(IDM_ROLE IDM_DOMAIN IDM_REALM IDM_ADMIN_PASSWORD IDM_DS_PASSWORD)
for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        log_err "Required variable not set: $var"
        exit 1
    fi
done

log_info "Role: ${IDM_ROLE}"
log_info "Domain: ${IDM_DOMAIN}"
log_info "Realm: ${IDM_REALM}"

# ── Set Hostname ─────────────────────────────────────────────────────
if [[ -n "${IDM_HOSTNAME:-}" ]]; then
    log_info "Setting hostname: ${IDM_HOSTNAME}"
    hostnamectl set-hostname "${IDM_HOSTNAME}" 2>/dev/null || hostname "${IDM_HOSTNAME}"
else
    IDM_HOSTNAME=$(hostname -f)
    log_info "Using system hostname: ${IDM_HOSTNAME}"
fi

# ── Container Environment Fixups ─────────────────────────────────────
# Containers share the host clock — skip NTP (chronyd needs SYS_TIME)
CONTAINER_ARGS=(--no-ntp)

# Disable systemd-resolved — it manages /etc/resolv.conf as a symlink
# to a stub that breaks IPA DNS. Replace with a static file.
if systemctl is-active systemd-resolved &>/dev/null; then
    log_info "Disabling systemd-resolved (incompatible with IPA DNS)"
    systemctl stop systemd-resolved
    systemctl disable systemd-resolved
    rm -f /etc/resolv.conf
    echo "nameserver ${IDM_DNS_FORWARDER:-8.8.8.8}" > /etc/resolv.conf
fi

# Add /etc/hosts entries for the primary server so reverse lookups work
# in the Podman network (no reverse DNS zone by default)
if [[ -n "${IDM_SERVER_IP:-}" && -n "${IDM_SERVER_FQDN:-}" ]]; then
    if ! grep -q "${IDM_SERVER_FQDN}" /etc/hosts 2>/dev/null; then
        log_info "Adding ${IDM_SERVER_FQDN} to /etc/hosts"
        echo "${IDM_SERVER_IP} ${IDM_SERVER_FQDN}" >> /etc/hosts
    fi
fi

# ── SELinux Relabel for bootc ────────────────────────────────────────
# On bootc, /var survives image switches but SELinux contexts don't get
# relabeled. RPM scriptlets that handle this on mutable RHEL don't run.
if [[ -f /run/ostree-booted ]]; then
    log_info "bootc detected — relabeling /var/lib directories for SELinux"
    for dir in /var/lib/dirsrv /var/lib/ipa /var/lib/certmonger /var/lib/pki; do
        [[ -d "$dir" ]] && restorecon -Rv "$dir" 2>/dev/null || true
    done
fi

# ── Install Based on Role ────────────────────────────────────────────
case "$IDM_ROLE" in
    primary)
        log_info "Installing FreeIPA primary server..."

        install_args=(
            --domain="${IDM_DOMAIN}"
            --realm="${IDM_REALM}"
            --hostname="${IDM_HOSTNAME}"
            --ds-password="${IDM_DS_PASSWORD}"
            --admin-password="${IDM_ADMIN_PASSWORD}"
            --unattended
            "${CONTAINER_ARGS[@]}"
        )

        if [[ "${IDM_SETUP_DNS:-yes}" == "yes" ]]; then
            install_args+=(--setup-dns)
            if [[ -n "${IDM_DNS_FORWARDER:-}" ]]; then
                install_args+=(--forwarder="${IDM_DNS_FORWARDER}")
            else
                install_args+=(--no-forwarders)
            fi
            if [[ "${IDM_NO_REVERSE:-yes}" == "yes" ]]; then
                install_args+=(--no-reverse)
            fi
        fi

        if [[ "${IDM_SETUP_ADTRUST:-no}" == "yes" ]]; then
            install_args+=(--setup-adtrust)
        fi

        if [[ "${IDM_USE_THINCA:-no}" == "yes" ]]; then
            install_args+=(--use-ipathinca)
            log_info "Using IPAThinCA backend (no Dogtag/PKI)"
        fi

        ipa-server-install "${install_args[@]}"
        log_ok "FreeIPA primary server installed"
        ;;

    replica)
        log_info "Installing FreeIPA replica..."

        if [[ -z "${IDM_SERVER_FQDN:-}" ]]; then
            log_err "IDM_SERVER_FQDN required for replica role"
            exit 1
        fi

        # Step 1: Enroll as client first
        log_info "Step 1/2: Enrolling as IPA client..."

        # Point DNS at the primary server for discovery
        if [[ -n "${IDM_SERVER_IP:-}" ]]; then
            log_info "Setting DNS resolver to ${IDM_SERVER_IP}"
            echo "nameserver ${IDM_SERVER_IP}" > /etc/resolv.conf
        fi

        ipa-client-install \
            --server="${IDM_SERVER_FQDN}" \
            --domain="${IDM_DOMAIN}" \
            --realm="${IDM_REALM}" \
            --hostname="${IDM_HOSTNAME}" \
            --principal=admin \
            --password="${IDM_ADMIN_PASSWORD}" \
            --unattended \
            --force-join \
            "${CONTAINER_ARGS[@]}"

        # Step 2: Promote to replica
        log_info "Step 2/2: Promoting to replica..."

        replica_args=(
            --principal=admin
            --admin-password="${IDM_ADMIN_PASSWORD}"
            --unattended
        )

        if [[ "${IDM_REPLICA_SETUP_DNS:-yes}" == "yes" ]]; then
            replica_args+=(--setup-dns)
            if [[ -n "${IDM_DNS_FORWARDER:-}" ]]; then
                replica_args+=(--forwarder="${IDM_DNS_FORWARDER}")
            else
                replica_args+=(--no-forwarders)
            fi
        fi

        if [[ "${IDM_REPLICA_SETUP_CA:-yes}" == "yes" ]]; then
            replica_args+=(--setup-ca)
        fi

        if [[ "${IDM_USE_THINCA:-no}" == "yes" ]]; then
            replica_args+=(--use-ipathinca)
            log_info "Using IPAThinCA backend (no Dogtag/PKI)"
        fi

        if [[ "${IDM_SKIP_CONNCHECK:-no}" == "yes" ]]; then
            replica_args+=(--skip-conncheck)
            log_info "Skipping connection check (primary cannot reach this node)"
        fi

        ipa-replica-install "${replica_args[@]}"
        log_ok "FreeIPA replica installed"
        ;;

    client)
        log_info "Installing FreeIPA client..."

        if [[ -z "${IDM_SERVER_FQDN:-}" ]]; then
            log_err "IDM_SERVER_FQDN required for client role"
            exit 1
        fi

        # Point DNS at the server for discovery
        if [[ -n "${IDM_SERVER_IP:-}" ]]; then
            log_info "Setting DNS resolver to ${IDM_SERVER_IP}"
            echo "nameserver ${IDM_SERVER_IP}" > /etc/resolv.conf
        fi

        ipa-client-install \
            --server="${IDM_SERVER_FQDN}" \
            --domain="${IDM_DOMAIN}" \
            --realm="${IDM_REALM}" \
            --hostname="${IDM_HOSTNAME}" \
            --principal=admin \
            --password="${IDM_ADMIN_PASSWORD}" \
            --unattended \
            --force-join \
            "${CONTAINER_ARGS[@]}"

        log_ok "FreeIPA client installed"
        ;;

    *)
        log_err "Unknown role: ${IDM_ROLE} (expected: primary, replica, client)"
        exit 1
        ;;
esac

# ── OAuth2 LDAP Schema + Plugin Registration ──────────────────────
# IPA plugins in ipaserver/plugins/ need their LDAP schema loaded into DS
# and container entries created. On bootc, these can't be baked into the
# image because the DS instance doesn't exist until ipa-server-install runs.

OAUTH2_SCHEMA="/usr/local/lib/idm-image-mode/schema/80oauth2.ldif"
if [[ -f "$OAUTH2_SCHEMA" && "$IDM_ROLE" == "primary" ]]; then
    DS_INSTANCE=$(ls -1d /etc/dirsrv/slapd-* 2>/dev/null | head -1)
    if [[ -n "$DS_INSTANCE" ]]; then
        DS_SCHEMA_DIR="${DS_INSTANCE}/schema"
        if [[ ! -f "${DS_SCHEMA_DIR}/80oauth2.ldif" ]]; then
            log_info "Loading OAuth2 LDAP schema into DS"
            cp "$OAUTH2_SCHEMA" "${DS_SCHEMA_DIR}/80oauth2.ldif"
            systemctl restart "dirsrv@$(basename "$DS_INSTANCE" | sed 's/slapd-//')"
            sleep 3
        fi

        # Create OAuth2 container entries if missing
        BASEDN="dc=${IDM_DOMAIN//./,dc=}"
        ldapsearch -x -D "cn=Directory Manager" -w "${IDM_DS_PASSWORD}" \
            -b "cn=oauth2,${BASEDN}" -s base "(objectClass=*)" dn 2>/dev/null || {
            log_info "Creating OAuth2 container entries under ${BASEDN}"
            ldapmodify -x -D "cn=Directory Manager" -w "${IDM_DS_PASSWORD}" <<LDIF
dn: cn=oauth2,${BASEDN}
changetype: add
objectClass: top
objectClass: nsContainer
cn: oauth2

dn: cn=clients,cn=oauth2,${BASEDN}
changetype: add
objectClass: top
objectClass: nsContainer
cn: clients

dn: cn=scopes,cn=oauth2,${BASEDN}
changetype: add
objectClass: top
objectClass: nsContainer
cn: scopes

dn: cn=workloads,cn=oauth2,${BASEDN}
changetype: add
objectClass: top
objectClass: nsContainer
cn: workloads

dn: cn=vendors,cn=oauth2,${BASEDN}
changetype: add
objectClass: top
objectClass: nsContainer
cn: vendors

dn: cn=delegations,cn=oauth2,${BASEDN}
changetype: add
objectClass: top
objectClass: nsContainer
cn: delegations
LDIF
        }

        # Restart httpd to reload IPA plugins with new schema
        systemctl restart httpd 2>/dev/null || true
        log_ok "OAuth2 schema and containers ready"
    fi
fi

# ── ahdapa OAuth2/OIDC Configuration ────────────────────────────────
# Runs after IPA install on primary/replica when ahdapa is installed.
# Configures CORS for browser-based OIDC and ensures ahdapa is running.

if command -v ahdapactl &>/dev/null && [[ "$IDM_ROLE" != "client" ]]; then
    log_info "Configuring ahdapa OIDC provider..."

    # On bootc images, ipa-server-install doesn't register COPR ahdapa with
    # ipactl — start it explicitly if ipactl doesn't manage it.
    if ipactl status 2>/dev/null | grep -q "ahdapa Service"; then
        log_info "ahdapa managed by ipactl"
        if ! ipactl status 2>/dev/null | grep -q "ahdapa Service: RUNNING"; then
            ipactl start ahdapa 2>/dev/null || true
        fi
    else
        log_info "ahdapa not in ipactl — starting via systemctl"
        systemctl enable ahdapa 2>/dev/null || true
        systemctl start ahdapa
        for i in $(seq 1 15); do
            systemctl is-active ahdapa &>/dev/null && break
            sleep 2
        done
        if systemctl is-active ahdapa &>/dev/null; then
            log_ok "ahdapa started via systemctl"
        else
            log_err "ahdapa failed to start"
            journalctl -u ahdapa --no-pager -n 20 >&2
        fi
    fi

    # Ensure httpd proxy config for /idp/ exists — ahdapa RPM ships it,
    # but on bootc the post-install scriptlet may not run.
    if [[ ! -f /etc/httpd/conf.d/ipa-idp-proxy.conf ]]; then
        AHDAPA_PORT="${AHDAPA_PORT:-8900}"
        cat > /etc/httpd/conf.d/ipa-idp-proxy.conf <<PROXY
ProxyPass /idp/ http://127.0.0.1:${AHDAPA_PORT}/
ProxyPassReverse /idp/ http://127.0.0.1:${AHDAPA_PORT}/
<Location /idp>
    Require all granted
</Location>
PROXY
        log_info "Created httpd proxy config for /idp/ → ahdapa:${AHDAPA_PORT}"
    fi

    # CORS config for browser OIDC token exchange
    if [[ ! -f /etc/httpd/conf.d/ipa-idp-cors.conf ]]; then
        cat > /etc/httpd/conf.d/ipa-idp-cors.conf <<'CORS'
<Location /idp>
    Header always set Access-Control-Allow-Origin "*"
    Header always set Access-Control-Allow-Methods "GET, POST, OPTIONS"
    Header always set Access-Control-Allow-Headers "Authorization, Content-Type, Accept"
    Header always set Access-Control-Max-Age "3600"
</Location>
CORS
        log_info "CORS config deployed"
    fi

    # OPTIONS preflight in idp proxy
    if [[ -f /etc/httpd/conf.d/ipa-idp-proxy.conf ]]; then
        if ! grep -q "RewriteCond.*OPTIONS" /etc/httpd/conf.d/ipa-idp-proxy.conf 2>/dev/null; then
            sed -i '/Require all granted/a\    RewriteEngine On\n    RewriteCond %{REQUEST_METHOD} =OPTIONS\n    RewriteRule .* - [R=204,L]' \
                /etc/httpd/conf.d/ipa-idp-proxy.conf
            log_info "OPTIONS preflight added to idp proxy"
        fi
    fi

    systemctl reload httpd 2>/dev/null || true

    # Register OAuth2 clients from config.env if provided
    if [[ -n "${AHDAPA_CLIENT_ID:-}" && -n "${AHDAPA_CLIENT_SECRET:-}" ]]; then
        log_info "Registering OAuth2 client: ${AHDAPA_CLIENT_ID}"
        echo "${IDM_ADMIN_PASSWORD}" | kinit admin 2>/dev/null || true
        ahdapactl login "https://${IDM_HOSTNAME}/idp" --kerberos --insecure 2>/dev/null || true

        # Client config via blockinfile-style append to clients.toml
        CLIENTS_TOML="/etc/ahdapa/clients.toml"
        if ! grep -q "client_id.*=.*\"${AHDAPA_CLIENT_ID}\"" "$CLIENTS_TOML" 2>/dev/null; then
            REDIRECT_URI="${AHDAPA_REDIRECT_URI:-https://${AHDAPA_CLIENT_ID}/auth/callback}"
            cat >> "$CLIENTS_TOML" <<CLIENT

[[client]]
client_id                  = "${AHDAPA_CLIENT_ID}"
client_name                = "${AHDAPA_CLIENT_NAME:-${AHDAPA_CLIENT_ID}}"
client_secret              = "${AHDAPA_CLIENT_SECRET}"
token_endpoint_auth_method = "client_secret_basic"
scopes                     = ${AHDAPA_SCOPES:-["openid", "profile"]}
grant_types                = ["authorization_code", "client_credentials", "urn:ietf:params:oauth:grant-type:token-exchange"]
redirect_uris              = ["${REDIRECT_URI}", "${REDIRECT_URI%/callback}/"]
skip_consent               = true
allow_token_exchange_actor  = true
CLIENT
            log_info "OAuth2 client registered in clients.toml"
            systemctl restart ahdapa 2>/dev/null || true
        fi
    fi

    # Federation config if SPIFFE trust domain is specified
    if [[ -n "${SPIFFE_TRUST_DOMAIN:-}" ]]; then
        SPIRE_ISSUER="https://${IDM_HOSTNAME}/spire"
        log_info "Configuring SPIFFE federation: trust_domain=${SPIFFE_TRUST_DOMAIN}"

        AHDAPA_TOML="/etc/ahdapa/ahdapa.toml"
        if ! grep -q '\[federation\]' "$AHDAPA_TOML" 2>/dev/null; then
            cat >> "$AHDAPA_TOML" <<FEDERATION

[federation]
trusted_issuers     = ["${SPIRE_ISSUER}"]
trust_anchors       = []
max_clock_skew_secs = 30
FEDERATION
            log_info "Federation section added to ahdapa.toml"
            systemctl restart ahdapa 2>/dev/null || true
        fi

        # Add allowed_token_exchange_audiences to client if registered
        if [[ -n "${AHDAPA_CLIENT_ID:-}" ]]; then
            CLIENTS_TOML="/etc/ahdapa/clients.toml"
            if ! grep -q "allowed_token_exchange_audiences" "$CLIENTS_TOML" 2>/dev/null; then
                sed -i "/client_id.*=.*\"${AHDAPA_CLIENT_ID}\"/,/^$/{
                    /allow_token_exchange_actor/a\\
allowed_token_exchange_audiences = [\"${SPIRE_ISSUER}\"]
                }" "$CLIENTS_TOML"
                systemctl restart ahdapa 2>/dev/null || true
            fi
        fi

        # Create Identity HBAC rule for federation token exchange
        ahdapactl login "https://${IDM_HOSTNAME}/idp" --kerberos --insecure 2>/dev/null || true
        ahdapactl hbac create \
            --name "federation-token-exchange" \
            --enabled true \
            --user-category true --client-category true --scope-category true \
            --network-category true --device-category true --mfa-bypass true \
            --delegation-target-category true 2>/dev/null || log_info "HBAC rule may already exist"
    fi

    log_ok "ahdapa OIDC provider configured"
fi

log_ok "First boot provisioning complete (role=${IDM_ROLE})"
