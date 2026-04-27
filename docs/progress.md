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

## Phase 2: Client Image + Replica — COMPLETE

**Date:** 2026-04-27
**Result:** Full 3-node topology running in rootless Podman — primary + replica + client

| Item | Status | Notes |
|------|--------|-------|
| Client enrollment against primary | Done | `id admin@TEST.EXAMPLE.COM` resolves, kinit works |
| Replica join | Done | 2-step: ipa-client-install → ipa-replica-install |
| Bidirectional replication | Done | Users created on either server appear on the other within seconds |
| HBAC + Sudo policies | Done | Rules enforced across topology |
| config.env.client | Done | Client config pointing to primary at 10.99.0.10 |
| config.env.replica | Done | Replica config with DNS and CA setup |
| test-firstboot-client.sh | Done | 12/12 pass — enrollment, SSSD, Kerberos, idempotency |
| test-firstboot-replica.sh | Done | 16/16 pass — services, topology, bidir replication, idempotency |
| test-policies.sh | Done | 12/12 pass — HBAC rules, sudo rules, bidir policy creation |

**Issues found & fixed:**
- systemd-resolved must be fully stopped/disabled (not just resolv.conf overwrite) — it manages resolv.conf as a symlink
- Replica needs /etc/hosts entry for primary (no reverse DNS with --no-reverse)
- `--no-ntp` invalid during ipa-replica-install (NTP already configured by client step)
- ipa-replica-install needs explicit `--principal=admin --admin-password=...`

## Phase 3: Mixed Topology (VM + Container) — COMPLETE

**Date:** 2026-04-27
**Result:** 3 deployment formats coexist in one FreeIPA topology with full bidirectional replication

- **idm1** (192.168.140.101) — rpm-format primary (traditional ipa-server-install)
- **idm2** (192.168.140.102) — bootc image-mode VM replica (qcow2 on OCP Virt)
- **idm3** (192.168.140.103) — image-mode Podman container replica (--network=host)

| Item | Status | Notes |
|------|--------|-------|
| Upgrade VMs to F44 | Done | All 3 VMs upgraded, snapshotted clean |
| Install FreeIPA primary on idm1 (rpm) | Done | Traditional ipa-server-install, all services healthy |
| idm3 — Podman container replica | Done | `--network=host`, bidirectional replication confirmed |
| idm2 — bootc qcow2 VM replica | Done | Symlink fix for `/usr` read-only, static IP, all 9 services running |
| Containerfile.server-vm | Done | Lab-only layer: claude user, SSH key, root password, DHCP, baked config |
| config.env.idm2 | Done | Replica config pointing at idm1 |
| scripts/build-vm.sh | Done | bootc-image-builder wrapper (`--rootfs ext4`) |
| scripts/deploy-idm3-replica.sh | Done | Console deploy helper for `--network=host` |
| test-mixed-topology.sh | Done | 19/19 pass against containers, `--target=vm` flag for VMs |

**Issues found & fixed:**
- **bootc /usr is read-only (ostree)** — FreeIPA writes `ca.crt` to `/usr/share/ipa/html/`. Fix: symlink to `/var/lib/ipa/html` in Containerfile
- bootc-image-builder needs `--rootfs ext4` (fedora-bootc has no default rootfs)
- OCP Virt network has no DHCP — must use static IP in NetworkManager config
- bootc images have no default users — must bake in SSH key + root password for lab access
- `--network=host` means container SSHD takes port 22 — stop host SSHD first
- Stale replication agreements persist after failed replica-install — `ipa server-del --force --ignore-topology-disconnect` to clean up
- SSH to idm3 container requires hopping through idm1 with Kerberos GSSAPI

## Phase 4: OCP Container Workload — NOT STARTED

**Goal:** Run FreeIPA as a Pod on OpenShift, proving the same image works across VM, Podman, and OCP

| Item | Status | Notes |
|------|--------|-------|
| OCP namespace + SCC | | Custom SecurityContextConstraints for privileged + systemd |
| PVC for /var | | Persistent storage for LDAP, PKI, logs |
| StatefulSet manifest | | Stable hostname, ordered scaling |
| DNS strategy | | IPA DNS vs CoreDNS coexistence |
| Service/Route | | Expose LDAP (389/636), Kerberos (88/464), HTTPS (443) |
| Replica join from OCP Pod | | Pod enrolls against idm1, promotes to replica |
| Network policy | | Lock down IPA ports to namespace |
| test-ocp-topology.sh | | Cross-format tests including OCP Pod |

**Key challenges:**
- Privileged containers restricted by OCP SCC — need custom policy
- systemd as PID 1 is non-standard for OCP (CRI-O supports it)
- FreeIPA DNS vs CoreDNS coexistence needs careful design
- StatefulSet (not Deployment) for stable hostnames + persistent storage

## Phase 5: Management Tooling — NOT STARTED

| Item | Status | Notes |
|------|--------|-------|
| manage.sh | | status, upgrade, rollback, logs, shell, destroy |
| status.sh | | Health dashboard across all nodes |

## Phase 6: Upgrade Workflow — NOT STARTED

| Item | Status | Notes |
|------|--------|-------|
| pre-upgrade / post-upgrade scripts | | ipactl stop, backup, ipa-server-upgrade |
| deploy-vm.sh | | bootc-image-builder → qcow2 |
| test-upgrade.sh | | Deploy v1, upgrade v2, verify data, rollback |
| ansible/playbooks/upgrade.yml | | Rolling upgrade (serial:1) |

## Phase 7: CI + Docs — NOT STARTED

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
