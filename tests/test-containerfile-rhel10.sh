#!/bin/bash
# Verify RHEL 10 image contents and post-upgrade service
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/scripts/lib/common.sh" 2>/dev/null || true

FAIL=0
PASS_COUNT=0
TOTAL=0

assert() {
    TOTAL=$((TOTAL + 1))
    if eval "$2" >/dev/null 2>&1; then
        echo "PASS: $1"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL: $1"
        FAIL=1
    fi
}

IMAGE="${IDM_SERVER_IMAGE_RHEL10:-localhost/idm-image-mode-server-rhel10:latest}"

echo "=== Containerfile.server-rhel10 Verification ==="
echo "Image: $IMAGE"
echo ""

# Image exists
assert "image built" "podman image exists $IMAGE"

# FreeIPA packages installed
assert "freeipa-server" "podman run --rm $IMAGE rpm -q freeipa-server"
assert "freeipa-server-dns" "podman run --rm $IMAGE rpm -q freeipa-server-dns"
assert "freeipa-server-trust-ad" "podman run --rm $IMAGE rpm -q freeipa-server-trust-ad"

# bootc infra
assert "cloud-init" "podman run --rm $IMAGE rpm -q cloud-init"
assert "qemu-guest-agent" "podman run --rm $IMAGE rpm -q qemu-guest-agent"

# Firstboot service enabled
assert "firstboot enabled" "podman run --rm $IMAGE systemctl is-enabled idm-firstboot.service"

# Post-upgrade service enabled
assert "post-upgrade enabled" "podman run --rm $IMAGE systemctl is-enabled idm-post-upgrade.service"

# /usr/share/ipa/html symlink to /var
assert "html symlink" "podman run --rm $IMAGE test -L /usr/share/ipa/html"

# Post-upgrade script executable
assert "post-upgrade exec" "podman run --rm $IMAGE test -x /usr/local/sbin/idm-post-upgrade"

# fstab entry
assert "fstab root" "podman run --rm $IMAGE grep -q 'LABEL=root' /etc/fstab"

echo ""
echo "Results: $PASS_COUNT/$TOTAL passed"
exit $FAIL
