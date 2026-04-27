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
    hostnamectl set-hostname "${IDM_HOSTNAME}"
else
    IDM_HOSTNAME=$(hostname -f)
    log_info "Using system hostname: ${IDM_HOSTNAME}"
fi

# ── Container Environment Fixups ─────────────────────────────────────
# Containers share the host clock — skip NTP (chronyd needs SYS_TIME)
CONTAINER_ARGS=(--no-ntp)

# Replace systemd-resolved stub with a working resolver
if grep -q '127.0.0.53' /etc/resolv.conf 2>/dev/null; then
    log_info "Replacing systemd-resolved stub in /etc/resolv.conf"
    echo "nameserver ${IDM_DNS_FORWARDER:-8.8.8.8}" > /etc/resolv.conf
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

        replica_args=(--unattended)

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

log_ok "First boot provisioning complete (role=${IDM_ROLE})"
