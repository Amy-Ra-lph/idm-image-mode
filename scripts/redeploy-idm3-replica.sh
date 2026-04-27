#!/bin/bash
# Redeploy idm3 replica after cleaning stale server entry
# Run on idm3 console (not via SSH — host SSHD is stopped)

set -e

echo "=== Stopping old container ==="
sudo podman rm -f idm-replica 2>/dev/null || true
sudo podman volume rm idm-replica-var 2>/dev/null || true

echo "=== Restarting host SSHD ==="
sudo systemctl start sshd

echo "=== Stopping host SSHD (container needs port 22) ==="
sudo systemctl stop sshd

echo "=== Starting fresh replica container ==="
sudo podman run -d \
  --name idm-replica \
  --privileged \
  --systemd=true \
  --network=host \
  --dns=none \
  --hostname=idm3.test.example.com \
  -v /var/tmp/config.env:/etc/idm-image-mode/config.env:ro,z \
  -v idm-replica-var:/var:Z \
  localhost/idm-image-mode-server:latest

echo "=== Container started. Monitor with: ==="
echo "sudo podman logs -f idm-replica"
