#!/bin/bash
# idm-post-upgrade — detect image version change, run ipa-server-upgrade
#
# Runs on every boot via idm-post-upgrade.service. Compares the current
# freeipa-server RPM version against a stamp file. On version change:
# backs up sysupgrade state and schema, then runs ipa-server-upgrade.

set -euo pipefail

STAMP_FILE="/var/lib/idm-image-mode/.image-version"
BACKUP_BASE="/var/lib/idm-image-mode/backups"
CURRENT_VERSION=$(rpm -q freeipa-server 2>/dev/null || echo "unknown")

HOOKS_DIR="/usr/local/lib/idm-image-mode/post-upgrade.d"

log() { logger -t idm-post-upgrade "$*"; echo "idm-post-upgrade: $*"; }

derive_suffix_dn() {
    local domain
    domain=$(hostname -d 2>/dev/null || echo "")
    if [[ -z "$domain" ]] && [[ -f /etc/ipa/default.conf ]]; then
        domain=$(grep -oP '(?<=domain = ).*' /etc/ipa/default.conf)
    fi
    echo "$domain" | sed 's/\./,dc=/g; s/^/dc=/'
}

run_hooks() {
    if [[ ! -d "$HOOKS_DIR" ]]; then
        log "No hooks directory ($HOOKS_DIR), skipping"
        return 0
    fi

    local hooks
    hooks=$(find "$HOOKS_DIR" -maxdepth 1 -name '*.sh' -executable | sort)
    if [[ -z "$hooks" ]]; then
        log "No executable hooks in $HOOKS_DIR"
        return 0
    fi

    export IDM_SUFFIX_DN
    IDM_SUFFIX_DN=$(derive_suffix_dn)
    export IDM_REALM
    IDM_REALM=$(hostname -d 2>/dev/null | tr '[:lower:]' '[:upper:]')
    export IDM_IMAGE_VERSION="$CURRENT_VERSION"

    local hook rc
    for hook in $hooks; do
        log "Running hook: $(basename "$hook")"
        rc=0
        "$hook" 2>&1 | while IFS= read -r line; do log "  $line"; done || rc=$?
        if [[ $rc -ne 0 ]]; then
            log "WARNING: hook $(basename "$hook") exited $rc (continuing)"
        fi
    done
    log "All hooks complete"
}

wait_for_ds() {
    local retries=12
    local delay=5
    local i
    for i in $(seq 1 "$retries"); do
        if ldapwhoami -Y EXTERNAL -H ldapi:/// 2>/dev/null; then
            return 0
        fi
        log "Waiting for 389-DS... ($i/$retries)"
        sleep "$delay"
    done
    log "ERROR: 389-DS not responding after $((retries * delay))s"
    return 1
}

if [[ -f "$STAMP_FILE" ]]; then
    PREV_VERSION=$(cat "$STAMP_FILE")
    if [[ "$CURRENT_VERSION" != "$PREV_VERSION" ]]; then
        log "Image version changed: $PREV_VERSION -> $CURRENT_VERSION"

        BACKUP_DIR="$BACKUP_BASE/$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        cp /var/lib/ipa/sysupgrade/sysupgrade.state "$BACKUP_DIR/" 2>/dev/null || true
        ldapsearch -Y EXTERNAL -H ldapi:/// \
            -b "cn=schema" -s base objectClasses attributeTypes \
            > "$BACKUP_DIR/schema-before.ldif" 2>/dev/null || true

        wait_for_ds || exit 1

        log "Running ipa-server-upgrade"
        if ipa-server-upgrade; then
            echo "$CURRENT_VERSION" > "$STAMP_FILE"
            log "Upgrade successful"
            run_hooks
        else
            log "Upgrade FAILED (rc=$?) — rollback may be needed"
            exit 1
        fi
    else
        log "Version unchanged ($CURRENT_VERSION), nothing to do"
    fi
else
    log "First boot stamp: $CURRENT_VERSION"
    echo "$CURRENT_VERSION" > "$STAMP_FILE"
    run_hooks
fi
