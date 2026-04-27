# IdM Image Mode

Run FreeIPA / RHEL Identity Management as bootc (Image Mode) containers and VMs.

This project proves that an IdM topology can mix rpm-format and image-mode nodes
transparently — the topology doesn't care how a node was deployed.

## Why Image Mode?

RHEL Image Mode (bootc) provides immutable OS images with A/B upgrades and
rollback. FreeIPA's installers only write to `/etc` and `/var`, making them
fully compatible with bootc's immutable root filesystem.

A single server image handles both primary and replica roles. The deployment
config (`config.env`) determines behavior at first boot.

## Prerequisites

- Podman (rootful, for `--privileged --systemd=true`)
- ~4 GB disk for the server image

## Quick Start

```bash
# 1. Configure
cp config/config.env.example config.env
# Edit config.env — set passwords, domain, realm

# 2. Build
./scripts/build.sh                    # server image
./scripts/build.sh --type=client      # client image

# 3. Deploy primary
./scripts/deploy-container.sh --role=primary

# 4. Verify (after firstboot completes, ~5-10 min)
./tests/test-firstboot-primary.sh
```

## Multi-Node Topology

```bash
# Create the network first
./scripts/setup-network.sh

# Deploy all roles
./scripts/deploy-container.sh --role=primary
./scripts/deploy-container.sh --role=replica
./scripts/deploy-container.sh --role=client
```

## Image Types

| Image | Packages | Roles |
|-------|----------|-------|
| `idm-image-mode-server` | freeipa-server, DNS, trust-ad | primary, replica |
| `idm-image-mode-client` | freeipa-client, admintools | client |

## Configuration

See [`config/config.env.example`](config/config.env.example) for all options.

Key variables:
- `IDM_ROLE` — `primary`, `replica`, or `client`
- `IDM_DOMAIN` / `IDM_REALM` — IPA domain and Kerberos realm
- `IDM_ADMIN_PASSWORD` / `IDM_DS_PASSWORD` — admin and Directory Server passwords
- `IDM_SERVER` — primary server FQDN (for replica/client enrollment)

## Testing

```bash
./tests/test-build.sh                     # image content checks
./tests/test-build.sh --type=all          # both images
./tests/test-firstboot-primary.sh         # primary provisioning + idempotency
```

## Design

IdM installers only write to `/etc` and `/var`, making them compatible
with bootc's immutable root filesystem.

Key design decisions:
- **Monolithic image** — keeps FreeIPA's tightly coupled services together
  (unlike the abandoned freeipa-podman microservices approach)
- **Systemd firstboot** — oneshot service with stamp file guard ensures
  the installer runs exactly once
- **`/var` persistence** — stamp files, IPA data, and certificates all
  live in `/var`, which persists fully across bootc upgrades

## Project Status

Phase 2 (Client + Replica) — complete. 53 tests passing across 3-node topology.

## License

Apache-2.0
