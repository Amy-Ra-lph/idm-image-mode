#!/bin/bash
# Configure ahdapa (Authorization Daemon for HTTP Protocol Assertions).
# Ensures ahdapa service is enabled and CORS config is deployed.
# Idempotent: skips steps already completed.

set -euo pipefail

STAMP="/var/lib/idm-image-mode/.ahdapa-configured"

if ! command -v ahdapactl &>/dev/null; then
    echo "ahdapactl not found, skipping (ahdapa not installed in this image)"
    exit 0
fi

CURRENT_VER=$(rpm -q ahdapa 2>/dev/null || echo "unknown")

if [[ -f "$STAMP" ]]; then
    STAMP_VER=$(cat "$STAMP")
    if [[ "$STAMP_VER" == "$CURRENT_VER" ]]; then
        echo "ahdapa already configured at version $CURRENT_VER"
        exit 0
    fi
    echo "ahdapa version changed: $STAMP_VER -> $CURRENT_VER"
fi

echo "Configuring ahdapa..."

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
    echo "CORS config deployed"
fi

# Ensure ahdapa service is enabled
systemctl daemon-reload
systemctl enable ahdapa.service 2>/dev/null || true
if ipactl status 2>/dev/null | grep -q "ahdapa Service"; then
    systemctl restart ahdapa.service 2>/dev/null || true
    echo "ahdapa service restarted"
fi

systemctl reload httpd 2>/dev/null || true

mkdir -p "$(dirname "$STAMP")"
echo "$CURRENT_VER" > "$STAMP"
echo "ahdapa configured (version $CURRENT_VER)"
