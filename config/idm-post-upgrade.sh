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

log() { logger -t idm-post-upgrade "$*"; echo "idm-post-upgrade: $*"; }

wait_for_ds() {
    local retries=12
    local delay=5
    local i
    for i in $(seq 1 "$retries"); do
        if ldapwhoami -Y EXTERNAL -H ldapi://%2Fvar%2Frun%2Fslapd-*.socket 2>/dev/null; then
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
        ldapsearch -Y EXTERNAL -H ldapi://%2Fvar%2Frun%2Fslapd-*.socket \
            -b "cn=schema" -s base objectClasses attributeTypes \
            > "$BACKUP_DIR/schema-before.ldif" 2>/dev/null || true

        wait_for_ds || exit 1

        log "Running ipa-server-upgrade"
        if ipa-server-upgrade; then
            echo "$CURRENT_VERSION" > "$STAMP_FILE"
            log "Upgrade successful"
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
fi
