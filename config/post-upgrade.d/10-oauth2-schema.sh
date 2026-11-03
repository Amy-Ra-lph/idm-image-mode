#!/bin/bash
# Deploy OAuth2/WID LDAP schema and DIT containers to 389-DS.
# Idempotent: skips if schema file and DIT already present.

set -euo pipefail

SCHEMA_SRC="/usr/local/lib/idm-image-mode/schema/80oauth2.ldif"
STAMP="/var/lib/idm-image-mode/.oauth2-schema-version"
SUFFIX_DN="${IDM_SUFFIX_DN:?IDM_SUFFIX_DN not set}"

schema_version() {
    grep -c '^attributeTypes:' "$SCHEMA_SRC" 2>/dev/null || echo 0
}

CURRENT_SCHEMA_VER=$(schema_version)

if [[ -f "$STAMP" ]] && [[ "$(cat "$STAMP")" == "$CURRENT_SCHEMA_VER" ]]; then
    echo "OAuth2 schema already at version $CURRENT_SCHEMA_VER, skipping"
    exit 0
fi

INSTANCE_DIR=$(find /etc/dirsrv -maxdepth 1 -name 'slapd-*' -type d | head -1)
if [[ -z "$INSTANCE_DIR" ]]; then
    echo "ERROR: no 389-DS instance found"
    exit 1
fi

SCHEMA_DST="$INSTANCE_DIR/schema/80oauth2.ldif"
if ! diff -q "$SCHEMA_SRC" "$SCHEMA_DST" &>/dev/null; then
    echo "Installing 80oauth2.ldif -> $SCHEMA_DST"
    cp "$SCHEMA_SRC" "$SCHEMA_DST"

    INSTANCE_NAME=$(basename "$INSTANCE_DIR")
    echo "Restarting dirsrv@${INSTANCE_NAME#slapd-}"
    systemctl restart "dirsrv@${INSTANCE_NAME#slapd-}"

    retries=12
    for i in $(seq 1 "$retries"); do
        ldapwhoami -Y EXTERNAL -H ldapi:/// 2>/dev/null && break
        echo "Waiting for DS restart... ($i/$retries)"
        sleep 5
    done
else
    echo "Schema file unchanged"
fi

create_container() {
    local dn="$1" cn="$2"
    if ldapsearch -Y EXTERNAL -H ldapi:/// -b "$dn" -s base '(objectClass=*)' dn 2>/dev/null | grep -q "^dn:"; then
        echo "DIT container exists: $dn"
        return 0
    fi
    echo "Creating DIT container: $dn"
    ldapadd -Y EXTERNAL -H ldapi:/// <<EOF
dn: $dn
objectClass: top
objectClass: nsContainer
cn: $cn
EOF
}

create_config_entry() {
    local dn="cn=config,cn=oauth2,$SUFFIX_DN"
    if ldapsearch -Y EXTERNAL -H ldapi:/// -b "$dn" -s base '(objectClass=*)' dn 2>/dev/null | grep -q "^dn:"; then
        echo "Config entry exists: $dn"
        return 0
    fi
    echo "Creating config entry: $dn"
    ldapadd -Y EXTERNAL -H ldapi:/// <<EOF
dn: $dn
objectClass: top
objectClass: oauth2Config
cn: config
oauth2Enabled: TRUE
oauth2TokenLifetime: 600
oauth2SchemaVersion: $CURRENT_SCHEMA_VER
description: Global OAuth2 subsystem configuration
EOF
}

create_container "cn=oauth2,$SUFFIX_DN" "oauth2"
create_container "cn=clients,cn=oauth2,$SUFFIX_DN" "clients"
create_container "cn=scopes,cn=oauth2,$SUFFIX_DN" "scopes"
create_container "cn=workloads,cn=oauth2,$SUFFIX_DN" "workloads"
create_container "cn=delegations,cn=oauth2,$SUFFIX_DN" "delegations"
create_container "cn=vendors,cn=oauth2,$SUFFIX_DN" "vendors"
create_config_entry

mkdir -p "$(dirname "$STAMP")"
echo "$CURRENT_SCHEMA_VER" > "$STAMP"
echo "OAuth2 schema deployed (version $CURRENT_SCHEMA_VER)"
