# IdM Image Mode

FreeIPA / RHEL IdM running in bootc Image Mode. Same server image handles
primary and replica roles — `IDM_ROLE` in config.env determines behavior.

## Quick Start

```bash
cp config/config.env.example config.env   # edit with your values
./scripts/build.sh                         # build server image
./scripts/deploy-container.sh --role=primary
./tests/test-firstboot-primary.sh          # verify
```

## Architecture

- **Base image:** `quay.io/fedora/fedora-bootc:44` (dev), RHEL 10 bootc (production)
- **Provisioning:** systemd oneshot (`idm-firstboot.service`) runs installer on first boot
- **Stamp file:** `/var/lib/idm-image-mode/.firstboot-complete` prevents re-run
- **Containers:** `--privileged --systemd=true --dns=none` required for IPA install
- **Persistence:** `/var` on named volume survives container restarts and bootc upgrades

## Project Layout

```
Containerfile.server          # bootc server image (primary + replica)
Containerfile.client          # bootc client image
config/
  idm-firstboot.sh            # reads config.env, runs ipa-*-install
  idm-firstboot.service       # systemd oneshot with ConditionPathExists guard
  config.env.example          # template — never commit real config.env
scripts/
  build.sh                    # podman build wrapper
  deploy-container.sh         # podman run with correct flags
  setup-network.sh            # multi-container network (static IPs)
  lib/common.sh               # shared logging, config, helpers
tests/
  test-build.sh               # image content verification
  test-firstboot-primary.sh   # primary server provisioning + idempotency
```

## Conventions

- Config secrets go in `config.env` (gitignored). Never hardcode passwords.
- All scripts source `scripts/lib/common.sh` for logging and helpers.
- Image naming: `localhost/idm-image-mode-{server,client}:latest`
- Container naming: `idm-{primary,replica,client}`
- Network: `idm-image-mode-net`, subnet `10.89.0.0/24`
  - primary: `10.89.0.10`, replica: `10.89.0.11`, client: `10.89.0.12`

## Lab VMs

Three Fedora 43 VMs (will upgrade to F44 for Phase 3):
- idm1 (192.168.140.101), idm2 (192.168.140.102), idm3 (192.168.140.103)
- SSH: `claude` user with `~/.ssh/claude_id_ed25519`

## Testing

```bash
./tests/test-build.sh                    # verify image contents
./tests/test-build.sh --type=client      # client image
./tests/test-firstboot-primary.sh        # full primary server test
```

## Reference

Alexander Bokovoy's design doc: "Considerations for RHEL IdM in RHEL Image Mode"
(Google Doc `1LZ4L7eRgsDtrk9HqmEBNz1ptdsE3LIlgokkpDtsav8g`)
