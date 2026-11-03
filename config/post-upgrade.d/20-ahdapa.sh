#!/bin/bash
# Configure ahdapa (Authorization Daemon for HTTP Protocol Assertions).
# Deploys httpd config, systemd unit, and credential directories.
# Idempotent: skips steps already completed.

set -euo pipefail

AHDAPA_BIN="/usr/local/sbin/ahdapa"
AHDAPA_CONF="/etc/ipa/ahdapa"
STAMP="/var/lib/idm-image-mode/.ahdapa-configured"

if [[ ! -x "$AHDAPA_BIN" ]]; then
    echo "ahdapa binary not found at $AHDAPA_BIN, skipping (not installed in this image)"
    exit 0
fi

if [[ -f "$STAMP" ]]; then
    STAMP_VER=$(cat "$STAMP")
    CURRENT_VER=$("$AHDAPA_BIN" --version 2>/dev/null || echo "unknown")
    if [[ "$STAMP_VER" == "$CURRENT_VER" ]]; then
        echo "ahdapa already configured at version $CURRENT_VER"
        exit 0
    fi
    echo "ahdapa version changed: $STAMP_VER -> $CURRENT_VER"
fi

echo "Configuring ahdapa..."

mkdir -p "$AHDAPA_CONF" /run/ipa/oauth2-secrets
chmod 700 "$AHDAPA_CONF"
chmod 770 /run/ipa/oauth2-secrets
chown ipaapi:ipaapi /run/ipa/oauth2-secrets 2>/dev/null || true

if [[ ! -f "$AHDAPA_CONF/ahdapa.conf" ]]; then
    SUFFIX_DN="${IDM_SUFFIX_DN:?IDM_SUFFIX_DN not set}"
    cat > "$AHDAPA_CONF/ahdapa.conf" <<EOF
[global]
ldap_uri = ldapi:///
base_dn = cn=oauth2,$SUFFIX_DN
secrets_dir = /run/ipa/oauth2-secrets
log_level = info

[httpd]
auth_location = /ipa/oauth2
socket_path = /run/ipa/ahdapa.sock

[jwt]
signing_algorithm = ES256
token_lifetime = 600
refresh_token_lifetime = 3600
EOF
    echo "Created $AHDAPA_CONF/ahdapa.conf"
fi

if [[ -f /etc/systemd/system/ahdapa.service ]]; then
    systemctl daemon-reload
    systemctl enable ahdapa.service
    if systemctl is-active --quiet ipa.service; then
        systemctl restart ahdapa.service
        echo "ahdapa service restarted"
    else
        echo "IPA not running yet, ahdapa will start on next boot"
    fi
fi

CURRENT_VER=$("$AHDAPA_BIN" --version 2>/dev/null || echo "unknown")
echo "$CURRENT_VER" > "$STAMP"
echo "ahdapa configured (version $CURRENT_VER)"
