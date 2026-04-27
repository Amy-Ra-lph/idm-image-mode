# IdM Image Mode — Progress Tracker

**Goal:** FreeIPA running in bootc Image Mode, topology-agnostic (rpm + image-mode nodes coexist)
**Reference:** Alexander Bokovoy's design doc (GDoc `1LZ4L7eRgsDtrk9HqmEBNz1ptdsE3LIlgokkpDtsav8g`)
**Repo:** `~/DevSpace/idm-image-mode`

## Phase 1: Server Image + First Boot — COMPLETE

**Date:** 2026-04-27
**Result:** FreeIPA primary installs in ~4 min inside rootless Podman container

| Item | Status | Notes |
|------|--------|-------|
| Containerfile.server | Done | Based on `fedora-bootc:44`, installs freeipa-server + DNS + trust-ad |
| Containerfile.client | Done | Installs freeipa-client + admintools |
| idm-firstboot.service | Done | Systemd oneshot with stamp file guard |
| idm-firstboot.sh | Done | Handles primary/replica/client roles |
| build.sh | Done | Builds 2.5 GB server image |
| deploy-container.sh | Done | Rootless Podman with high-port mappings |
| setup-network.sh | Done | 10.99.0.0/24 with static IPs |
| test-build.sh | Done | 12/12 pass |
| test-firstboot-primary.sh | Done | 13/13 pass (after fixes) |

**Issues found & fixed:**
- chronyd fails in containers (no SYS_TIME) → `--no-ntp` flag
- systemd-resolved stub (127.0.0.53) breaks IPA DNS → replace resolv.conf before install
- Rootless Podman can't bind privileged ports → remap to 8443, 3389, etc.
- Subnet 10.89.0.0/24 in use → changed to 10.99.0.0/24
- IPA services need ~20s to settle after container restart

## Phase 2: Client Image + Replica — NOT STARTED

| Item | Status | Notes |
|------|--------|-------|
| Client enrollment against primary | | Deploy client container, verify `id admin@REALM` |
| Replica join | | Deploy replica, verify `ipactl status`, replication |
| test-firstboot-client.sh | | Client enrollment tests |
| test-firstboot-replica.sh | | Replica join + topology tests |
| test-replication.sh | | Cross-node LDAP replication |

## Phase 3: Mixed Topology Testing — NOT STARTED

Requires lab VMs upgraded to Fedora 44 (currently F43). Snapshot after upgrade, before IPA install.

| Item | Status | Notes |
|------|--------|-------|
| Upgrade VMs to F44 | | idm1, idm2, idm3 — snapshot clean F44 baseline |
| Install FreeIPA on rpm VMs | | At least one primary + one client |
| ansible/inventory/hosts.yml | | Mixed groups: rpm + image-mode |
| test-mixed-topology.sh | | rpm↔image-mode interop matrix |
| ansible/playbooks/smoke-test.yml | | Automated validation |

## Phase 4: Management Tooling — NOT STARTED

| Item | Status | Notes |
|------|--------|-------|
| manage.sh | | status, upgrade, rollback, logs, shell, destroy |
| status.sh | | Health dashboard across all nodes |

## Phase 5: Upgrade Workflow — NOT STARTED

| Item | Status | Notes |
|------|--------|-------|
| pre-upgrade / post-upgrade scripts | | ipactl stop, backup, ipa-server-upgrade |
| deploy-vm.sh | | bootc-image-builder → qcow2 |
| test-upgrade.sh | | Deploy v1, upgrade v2, verify data, rollback |
| ansible/playbooks/upgrade.yml | | Rolling upgrade (serial:1) |

## Phase 6: CI + Docs — NOT STARTED

| Item | Status | Notes |
|------|--------|-------|
| ansible/playbooks/deploy.yml | | Full lifecycle |
| .github/workflows/ci.yml | | Build + test in CI |
| docs/design.md | | Architecture doc with diagrams |

## Future / Backlog

- **Thin-CA variant:** Build image using twoerner's `IPAthinCA` branch (`gitlab.cee.redhat.com/twoerner/freeipa/-/tree/IPAthinCA`)
- **RHEL 10 bootc base:** Switch from `fedora-bootc:44` to `registry.redhat.io/rhel10/rhel-bootc:latest`
- **VM deployment:** Test with bootc-image-builder qcow2 output
- **3-way /etc merge testing:** Verify IPA configs survive bootc upgrades
