#!/bin/bash
# Run this on idm3 console (not via SSH)

sudo podman network rm idm-macvlan 2>/dev/null
sudo podman rm -f idm-replica 2>/dev/null
sudo podman volume rm idm-replica-var 2>/dev/null
sudo systemctl stop sshd
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
