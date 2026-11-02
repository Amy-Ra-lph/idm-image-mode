# FreeIPA Image Mode 4-Node Cluster Lifecycle — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Ansible automation, systemd services, and Containerfile to deploy a 4-node FreeIPA image-mode cluster on RHEL 10 with rolling upgrades, schema migration, and full verification — wired into idm-ci's mrack pipeline.

**Architecture:** Ansible playbooks (using `freeipa.ansible_freeipa` collection v1.17+) orchestrate every lifecycle operation. Nine custom roles handle verification, backup, bootc lifecycle, replication isolation, cleanup, and WID overlay. A systemd oneshot (`idm-post-upgrade`) detects image version changes on boot and runs `ipa-server-upgrade`. All state lives in `/var` (persistent across bootc updates/rollbacks); `/usr` is read-only composefs.

**Tech Stack:** RHEL 10 bootc, Ansible 2.16+, `freeipa.ansible_freeipa` 1.17+, 389-DS (LMDB), idm-ci mrack, Podman (for throwaway schema tests)

**Spec:** `docs/superpowers/specs/2026-11-02-freeipa-image-mode-cluster-lifecycle-design.md`

## Global Constraints

- RHEL 10.4 base image (`images.paas.redhat.com/bootc/rhel-bootc:latest-10.4`)
- Replicas promoted sequentially (`serial: 1`) — never parallel
- Minimum 4GB RAM per node (WID lesson #46: pkispawn OOM)
- 1GB swap created before `--setup-ca` on every replica
- `/var/lib/ipa/` directory tree pre-created before replica install (WID lesson #17)
- SSH key `~/.ssh/idm_ci_key` for idm-ci provisioned hosts
- DNS forwarder: `10.11.5.19` (idm-ci default)
- Domain: `imagemode.test`, Realm: `IMAGEMODE.TEST`
- Passwords: `Secret123` (admin + Directory Manager) — lab/CI only
- Never delete `/etc/dirsrv/` directory itself (WID lesson #43)
- `--skip-conncheck` after first retry (WID lesson #20)
- Stale replication cleanup via live LDAP, not dse.ldif (WID lesson #24)

## Review Focus

1. **Swap file idempotency:** If `swapon /var/swapfile` is called when swap already active, it should not error — the swap setup task must handle re-runs gracefully (test: deploy-cluster twice without cleanup).
2. **Replication verification timing:** The 10-second sleep after creating a test user may be insufficient under load or on slow VMs — if `verify_replication` intermittently fails, increase to 15s or add polling with retry.
3. **Nuclear cleanup scope on bootc:** The `nuclear_cleanup` role removes files from `/etc` and `/var`, but on bootc `/etc` is an overlay. Removing `/etc/ipa/` works (overlay deletion), but removing `/etc/dirsrv/slapd-*/` must preserve `/etc/dirsrv/` itself (WID lesson #43). The glob pattern in the rm command must be exact.
4. **`idm-post-upgrade` race with 389-DS:** The service runs `After=dirsrv@*.service` but 389-DS may not accept LDAP connections immediately after `systemd` marks it active. Add a `ldapwhoami` retry loop before `ipa-server-upgrade`.
5. **`bootc switch` vs `bootc upgrade`:** `rolling-upgrade.yaml` uses `bootc upgrade --apply` for same-image-tag updates but `bootc switch` for WID rebase. The `bootc_lifecycle` role must accept a mode parameter and validate that the target image reference is reachable before rebooting.

---

### Task 1: Core Infrastructure — Containerfile + Post-Upgrade Service

**Files:**
- Create: `Containerfile.server-rhel10`
- Create: `config/idm-post-upgrade.sh`
- Create: `config/idm-post-upgrade.service`
- Modify: `scripts/lib/common.sh` (add replica2/replica3 IPs, RHEL 10 image ref)

**Interfaces:**
- Consumes: existing `config/idm-firstboot.sh`, `config/idm-firstboot.service` (copied into image)
- Produces: bootc-compatible RHEL 10 server image with firstboot + post-upgrade services; `common.sh` exports `IDM_REPLICA2_IP=10.99.0.13`, `IDM_REPLICA3_IP=10.99.0.14`

- [ ] **Step 1: Write test — `tests/test-containerfile-rhel10.sh`**

```bash
#!/bin/bash
# Verify RHEL 10 image contents
source scripts/lib/common.sh

FAIL=0
assert() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi; }

IMAGE="localhost/idm-image-mode-server-rhel10:latest"

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

exit $FAIL
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-containerfile-rhel10.sh`
Expected: FAIL — image doesn't exist, scripts missing

- [ ] **Step 3: Create `Containerfile.server-rhel10`**

Based on spec Part 1. RHEL 10.4 bootc base, installs freeipa-server + DNS + trust-ad + cloud-init + qemu-guest-agent. Copies firstboot + post-upgrade scripts and services. Creates `/usr/share/ipa/html` → `/var/lib/ipa/html` symlink. Enables both services.

- [ ] **Step 4: Create `config/idm-post-upgrade.sh`**

Based on spec Part 2. Version detection via `rpm -q freeipa-server` compared against `/var/lib/idm-image-mode/.image-version` stamp file. On version change: backup sysupgrade.state + schema snapshot, run `ipa-server-upgrade`, update stamp on success. On first boot (no stamp): just write stamp. Add `ldapwhoami` retry loop (up to 60s) to wait for DS readiness before running `ipa-server-upgrade`.

- [ ] **Step 5: Create `config/idm-post-upgrade.service`**

systemd oneshot, `Type=oneshot`, `RemainAfterExit=no`. `After=dirsrv@.service ipa.service`. `ConditionPathExists=/var/lib/idm-image-mode/.firstboot-complete` (only runs after firstboot succeeded). `TimeoutStartSec=600` (upgrade can take minutes on large DBs).

- [ ] **Step 6: Update `scripts/lib/common.sh`**

Add `IDM_REPLICA2_IP=10.99.0.13`, `IDM_REPLICA3_IP=10.99.0.14`. Add `IDM_RHEL10_IMAGE="images.paas.redhat.com/bootc/rhel-bootc:latest-10.4"`. Add `IDM_SERVER_IMAGE_RHEL10="localhost/idm-image-mode-server-rhel10:latest"`.

- [ ] **Step 7: Build image, run test, verify all pass**

Run: `podman build -t localhost/idm-image-mode-server-rhel10:latest -f Containerfile.server-rhel10 .`
Note: Build will fail if running outside Red Hat network (nightly compose repos). If so, validate by inspecting Containerfile syntax and file existence only.
Run: `bash tests/test-containerfile-rhel10.sh`
Expected: all assertions PASS (or documented skip for network-dependent tests)

- [ ] **Step 8: Commit**

```bash
git add Containerfile.server-rhel10 config/idm-post-upgrade.sh config/idm-post-upgrade.service \
  scripts/lib/common.sh tests/test-containerfile-rhel10.sh
git commit -m "$(cat <<'EOF'
feat: add RHEL 10 bootc Containerfile + post-upgrade service

RHEL 10.4 server image with version-aware post-upgrade systemd service
that detects FreeIPA version changes on boot and runs ipa-server-upgrade.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Ansible Inventory + `verify_ipa_health` Role

**Files:**
- Create: `ansible/inventory/imagemode.ini`
- Create: `ansible/roles/verify_ipa_health/tasks/main.yaml`
- Create: `ansible/roles/verify_ipa_health/defaults/main.yaml`
- Create: `ansible/ansible.cfg`
- Create: `ansible/requirements.yaml`

**Interfaces:**
- Consumes: nothing (foundation role)
- Produces: `verify_ipa_health` role — checks ipactl, ports (389, 88, 443), kinit, `ipa ping`, `ipa cert-show 1`. Sets fact `ipa_health_passed: true/false`.

- [ ] **Step 1: Write test playbook — `ansible/tests/test-verify-ipa-health.yaml`**

```yaml
---
# Dry-run syntax validation of verify_ipa_health role
# Run: ansible-playbook --syntax-check ansible/tests/test-verify-ipa-health.yaml
- name: Test verify_ipa_health role
  hosts: ipa_primary
  become: true
  tasks:
    - name: Include verify_ipa_health
      include_role:
        name: verify_ipa_health
```

- [ ] **Step 2: Run syntax check to verify it fails**

Run: `cd ~/DevSpace/idm-image-mode && ansible-playbook --syntax-check ansible/tests/test-verify-ipa-health.yaml -i ansible/inventory/imagemode.ini`
Expected: FAIL — role not found

- [ ] **Step 3: Create `ansible/ansible.cfg`**

Set `roles_path = roles`, `collections_paths = ~/.ansible/collections`, `host_key_checking = False`, `retry_files_enabled = False`.

- [ ] **Step 4: Create `ansible/requirements.yaml`**

```yaml
collections:
  - name: freeipa.ansible_freeipa
    version: ">=1.17.0"
```

- [ ] **Step 5: Create `ansible/inventory/imagemode.ini`**

Per spec Part 6. Groups: `ipa_primary`, `ipa_replicas` (replica1-3), `ipa_canary` (replica3). `all:vars` with `ansible_user=root`, `ansible_ssh_private_key_file=~/.ssh/idm_ci_key`, `ansible_ssh_common_args`, domain/realm vars. Host IPs as `<IP>` placeholders.

- [ ] **Step 6: Implement `verify_ipa_health` role**

`defaults/main.yaml`: `verify_admin_password: Secret123`, `verify_ports: [389, 88, 443]`.
`tasks/main.yaml`: ipactl status check, wait_for on each port, `kinit admin` (with `no_log: true`), `ipa ping`, `ipa cert-show 1`, set fact `ipa_health_passed`.

- [ ] **Step 7: Run syntax check to verify it passes**

Run: `cd ~/DevSpace/idm-image-mode && ansible-playbook --syntax-check ansible/tests/test-verify-ipa-health.yaml -i ansible/inventory/imagemode.ini`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add ansible/
git commit -m "$(cat <<'EOF'
feat: add ansible inventory, config, and verify_ipa_health role

Foundation for cluster automation: inventory template with 4-node groups,
ansible.cfg, freeipa collection requirement, and health-check role that
validates ipactl, ports, Kerberos, and IPA API on a single node.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `verify_replication` + `verify_full_suite` Roles

**Files:**
- Create: `ansible/roles/verify_replication/tasks/main.yaml`
- Create: `ansible/roles/verify_replication/defaults/main.yaml`
- Create: `ansible/roles/verify_full_suite/tasks/main.yaml`
- Create: `ansible/roles/verify_full_suite/defaults/main.yaml`

**Interfaces:**
- Consumes: `verify_ipa_health` role (from Task 2), `freeipa.ansible_freeipa.ipauser` module
- Produces: `verify_replication` role — write/read consistency test + agreement status + CSN drift check. Sets fact `replication_healthy: true/false`. `verify_full_suite` role — calls `verify_ipa_health` on all nodes + `verify_replication` + topology suffix verification + cross-node service tickets. Sets fact `verification_passed: true/false`.

- [ ] **Step 1: Write test playbook — `ansible/tests/test-verify-replication.yaml`**

```yaml
---
- name: Test verify_replication role syntax
  hosts: ipa_primary
  become: true
  collections:
    - freeipa.ansible_freeipa
  tasks:
    - name: Include verify_replication
      include_role:
        name: verify_replication
      vars:
        verify_target: replica1
```

- [ ] **Step 2: Run syntax check to verify it fails**

Run: `ansible-playbook --syntax-check ansible/tests/test-verify-replication.yaml -i ansible/inventory/imagemode.ini`
Expected: FAIL — role not found

- [ ] **Step 3: Implement `verify_replication` role**

`defaults/main.yaml`: `verify_admin_password: Secret123`, `verify_dm_password: Secret123`, `repl_propagation_wait: 10`, `repl_lag_warn_seconds: 5`, `repl_lag_fail_seconds: 30`.
`tasks/main.yaml`: Create test user via `ipauser` module, pause for propagation, ldapsearch on target (or all replicas if `verify_all_peers: true`) to confirm user replicated, delete test user, check agreement status via ldapsearch on `cn=config`, parse `nsds5replicalastupdatestatus`, set fact `replication_healthy`.

- [ ] **Step 4: Implement `verify_full_suite` role**

`defaults/main.yaml`: `wid_enabled: false`, `verification_passed: false`.
`tasks/main.yaml`: topology suffix verification (domain + ca), include `verify_ipa_health`, include `verify_replication` with `verify_all_peers: true`, cross-node service ticket test (`kvno HTTP/<fqdn>@REALM` for each node), GSSAPI bind test, password bind test, conditional WID verification (OIDC discovery + ACME directory) when `wid_enabled: true`. Sets `verification_passed: true` only if all checks pass.

- [ ] **Step 5: Run syntax check to verify it passes**

Run: `ansible-playbook --syntax-check ansible/tests/test-verify-replication.yaml -i ansible/inventory/imagemode.ini`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add ansible/roles/verify_replication/ ansible/roles/verify_full_suite/
git commit -m "$(cat <<'EOF'
feat: add verify_replication and verify_full_suite ansible roles

Replication role: write/read consistency, agreement health, CSN drift.
Full suite: combines health + replication + topology + cross-node
Kerberos + GSSAPI/password bind + conditional WID (OAuth2/ACME) checks.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `backup_ipa_state` + `bootc_lifecycle` Roles

**Files:**
- Create: `ansible/roles/backup_ipa_state/tasks/main.yaml`
- Create: `ansible/roles/backup_ipa_state/defaults/main.yaml`
- Create: `ansible/roles/bootc_lifecycle/tasks/main.yaml`
- Create: `ansible/roles/bootc_lifecycle/defaults/main.yaml`

**Interfaces:**
- Consumes: nothing
- Produces: `backup_ipa_state` role — captures sysupgrade.state, schema LDIF, replication agreements, dse.ldif, IPA config, bootc status, optionally LMDB snapshot. Var `backup_label` sets subdirectory name. `bootc_lifecycle` role — handles `upgrade`, `switch`, `rollback` via `bootc_action` var. For `switch`, requires `bootc_target_image`. Updates version stamp after reboot.

- [ ] **Step 1: Write test playbook — `ansible/tests/test-backup-bootc.yaml`**

```yaml
---
- name: Test backup_ipa_state + bootc_lifecycle syntax
  hosts: ipa_primary
  become: true
  tasks:
    - name: Test backup role
      include_role:
        name: backup_ipa_state
      vars:
        backup_label: test-backup

    - name: Test bootc lifecycle role (upgrade mode)
      include_role:
        name: bootc_lifecycle
      vars:
        bootc_action: upgrade
```

- [ ] **Step 2: Run syntax check to verify it fails**

Run: `ansible-playbook --syntax-check ansible/tests/test-backup-bootc.yaml -i ansible/inventory/imagemode.ini`
Expected: FAIL

- [ ] **Step 3: Implement `backup_ipa_state` role**

`defaults/main.yaml`: `backup_label: "{{ ansible_date_time.iso8601_basic_short }}"`, `backup_base_dir: /var/lib/idm-image-mode/backups`, `include_lmdb: false`.
`tasks/main.yaml`: Create backup dir, copy sysupgrade.state, export schema via ldapsearch, export replication agreements, copy dse.ldif + default.conf, capture `rpm -q freeipa-server` + `bootc status`, conditionally `cp -a` LMDB db directory when `include_lmdb: true`.

- [ ] **Step 4: Implement `bootc_lifecycle` role**

`defaults/main.yaml`: `bootc_action: upgrade` (choices: upgrade, switch, rollback), `bootc_target_image: ""`, `bootc_reboot_timeout: 300`, `bootc_ipactl_retries: 12`, `bootc_ipactl_delay: 15`.
`tasks/main.yaml`: Assert valid action. For `upgrade`: run `bootc upgrade --apply`. For `switch`: assert `bootc_target_image` set, run `bootc switch {{ bootc_target_image }}`. For `rollback`: run `bootc rollback`. All three: reboot, wait for IPA services (`ipactl status` with retries), check freeipa-server version, update version stamp.

- [ ] **Step 5: Run syntax check to verify it passes**

Run: `ansible-playbook --syntax-check ansible/tests/test-backup-bootc.yaml -i ansible/inventory/imagemode.ini`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add ansible/roles/backup_ipa_state/ ansible/roles/bootc_lifecycle/
git commit -m "$(cat <<'EOF'
feat: add backup_ipa_state and bootc_lifecycle ansible roles

Backup role captures sysupgrade state, schema, replication agreements,
config, and optionally LMDB snapshots. Bootc lifecycle role handles
upgrade/switch/rollback with reboot and IPA service readiness gates.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `isolate_replication` + `nuclear_cleanup` Roles

**Files:**
- Create: `ansible/roles/isolate_replication/tasks/main.yaml`
- Create: `ansible/roles/isolate_replication/defaults/main.yaml`
- Create: `ansible/roles/nuclear_cleanup/tasks/main.yaml`

**Interfaces:**
- Consumes: nothing
- Produces: `isolate_replication` role — pauses/resumes all replication agreements to/from a target node. Var `isolation_action` = `isolate` or `reconnect`. Var `isolation_target` = hostname. `nuclear_cleanup` role — full IPA uninstall + state wipe per WID lessons #42-43. Preserves `/etc/dirsrv/` directory itself.

- [ ] **Step 1: Write test playbook — `ansible/tests/test-isolate-cleanup.yaml`**

```yaml
---
- name: Test isolate_replication syntax
  hosts: ipa_primary
  become: true
  tasks:
    - name: Test isolate
      include_role:
        name: isolate_replication
      vars:
        isolation_action: isolate
        isolation_target: replica3

- name: Test nuclear_cleanup syntax
  hosts: ipa_canary
  become: true
  tasks:
    - name: Test cleanup
      include_role:
        name: nuclear_cleanup
```

- [ ] **Step 2: Run syntax check — expected FAIL**

- [ ] **Step 3: Implement `isolate_replication` role**

`defaults/main.yaml`: `isolation_action: isolate`, `isolation_target: ""`, `isolation_verification_wait: 15`.
`tasks/main.yaml`:
- For `isolate`: On peers (all hosts except target), ldapsearch for agreements pointing to `isolation_target`, ldapmodify `nsds5ReplicaEnabled: off`. On target node, find all outbound agreements, disable them. Verification: create test user on primary, wait, confirm NOT present on target.
- For `reconnect`: On all nodes, find all agreements, ldapmodify `nsds5ReplicaEnabled: on`. Wait for propagation.

- [ ] **Step 4: Implement `nuclear_cleanup` role**

`tasks/main.yaml`: `ipa-server-install --uninstall -U` (ignore errors), `ipa-client-install --uninstall -U` (ignore errors), remove IPA state dirs (from spec R1), clear `/dev/shm/slapd-*`, `restorecon -Rv` on restored dirs. Explicitly do NOT `rm -rf /etc/dirsrv/` — only remove `slapd-*` subdirs.

- [ ] **Step 5: Run syntax check — expected PASS**

- [ ] **Step 6: Commit**

```bash
git add ansible/roles/isolate_replication/ ansible/roles/nuclear_cleanup/
git commit -m "$(cat <<'EOF'
feat: add isolate_replication and nuclear_cleanup ansible roles

Isolation role pauses/resumes replication agreements for canary testing.
Cleanup role implements WID lesson #42-43 safe uninstall sequence,
preserving /etc/dirsrv/ while clearing all IPA/DS state.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Deploy Cluster Playbook

**Files:**
- Create: `ansible/playbooks/cluster/deploy-cluster.yaml`
- Create: `ansible/playbooks/cluster/inject-config.yaml`

**Interfaces:**
- Consumes: `verify_ipa_health` (Task 2), `verify_replication` (Task 3), `verify_full_suite` (Task 3), `freeipa.ansible_freeipa.ipaserver` role, `freeipa.ansible_freeipa.ipareplica` role
- Produces: `deploy-cluster.yaml` — end-to-end 4-node deploy. `inject-config.yaml` — pushes `config.env` to all nodes via template.

- [ ] **Step 1: Write syntax test**

```yaml
# ansible/tests/test-deploy-cluster.yaml
---
- name: Syntax test for deploy-cluster
  hosts: localhost
  tasks:
    - name: Verify deploy-cluster.yaml exists and is valid
      debug:
        msg: "Syntax check via ansible-playbook --syntax-check"
```

- [ ] **Step 2: Run syntax check — expected FAIL**

Run: `ansible-playbook --syntax-check ansible/playbooks/cluster/deploy-cluster.yaml -i ansible/inventory/imagemode.ini`

- [ ] **Step 3: Create `inject-config.yaml`**

Template `config.env` per node: sets `IDM_ROLE=primary|replica` and `IDM_PRIMARY_HOST`, `IDM_DOMAIN`, `IDM_REALM`, passwords. Copies to `/etc/idm-image-mode/config.env` on each node.

- [ ] **Step 4: Create `deploy-cluster.yaml`**

Per spec Part 6 section 1. Import `inject-config.yaml`. Primary play uses `ipaserver` role with domain/realm/DNS/forwarder vars, post-tasks record image version + run `verify_ipa_health`. Replicas play with `serial: 1`, pre-tasks for dir tree (WID #17) + swap (WID #46), `ipareplica` role with `setup_ca/dns/skip_conncheck`, post-tasks verify health + replication. Final play runs `verify_full_suite` from primary.

- [ ] **Step 5: Run syntax check — expected PASS**

- [ ] **Step 6: Commit**

```bash
git add ansible/playbooks/cluster/
git commit -m "$(cat <<'EOF'
feat: add deploy-cluster and inject-config playbooks

Full 4-node FreeIPA deploy using ansible-freeipa roles with sequential
replica promotion, WID lesson pre-tasks (dir tree, swap), and
verification gates after each node.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Rolling Upgrade + Rollback Playbooks

**Files:**
- Create: `ansible/playbooks/lifecycle/rolling-upgrade.yaml`
- Create: `ansible/playbooks/lifecycle/rollback-node.yaml`
- Create: `ansible/playbooks/lifecycle/rollback-cluster.yaml`
- Create: `ansible/playbooks/lifecycle/bootc-switch.yaml`

**Interfaces:**
- Consumes: `verify_full_suite` (Task 3), `verify_replication` (Task 3), `backup_ipa_state` (Task 4), `bootc_lifecycle` (Task 4), `nuclear_cleanup` (Task 5), `freeipa.ansible_freeipa.ipaserver` module, `freeipa.ansible_freeipa.ipahost` module, `freeipa.ansible_freeipa.ipareplica` role
- Produces: four lifecycle playbooks covering image upgrade, single-node rollback (R1), full cluster rollback (R6), and WID image rebase.

- [ ] **Step 1: Syntax test**

Run: `for f in rolling-upgrade rollback-node rollback-cluster bootc-switch; do echo "--- $f ---"; done` — verify files exist after creation

- [ ] **Step 2: Create `rolling-upgrade.yaml`**

Per spec Part 6 section 2. Pre-upgrade: run `verify_full_suite` + `backup_ipa_state` on all. Rolling play: `serial: 1`, hosts from `upgrade_order` var (default: `replica3,replica2,replica1,primary`). Each node: `bootc upgrade --apply`, reboot, wait for ipactl, check version, run `ipa-server-upgrade` if changed, update stamp, run `verify_full_suite` + `verify_replication`, assert `verification_passed` to gate next node.

- [ ] **Step 3: Create `rollback-node.yaml`**

Per spec R1. Target node: `bootc rollback`, reboot, check ipactl. If services recovered → verify. If not → `nuclear_cleanup`, remove server from primary (`ipaserver` module state=absent + `ipahost` del/re-add), re-enroll with `ipareplica` role (with dir pre-create + swap), final `verify_full_suite`.

- [ ] **Step 4: Create `rollback-cluster.yaml`**

Per spec R6. Loop replica3→2→1→primary: `bootc rollback`, reboot, verify ipactl. After all nodes: optionally restore sysupgrade.state from backup, run `ipa-server-upgrade` on each, `verify_full_suite`.

- [ ] **Step 5: Create `bootc-switch.yaml`**

Like `rolling-upgrade` but uses `bootc switch {{ bootc_target_image }}` instead of `bootc upgrade`. Used for stock→WID rebase.

- [ ] **Step 6: Syntax check all four**

Run: `for f in ansible/playbooks/lifecycle/*.yaml; do ansible-playbook --syntax-check "$f" -i ansible/inventory/imagemode.ini; done`
Expected: all PASS

- [ ] **Step 7: Commit**

```bash
git add ansible/playbooks/lifecycle/
git commit -m "$(cat <<'EOF'
feat: add lifecycle playbooks — rolling upgrade, rollback, bootc switch

Rolling upgrade with per-node verification gates. Single-node rollback
with R1 re-enrollment. Full cluster rollback (R6). Image rebase for
stock-to-WID transition.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Schema Migration Playbooks

**Files:**
- Create: `ansible/playbooks/schema/validate-schema.yaml`
- Create: `ansible/playbooks/schema/canary-schema.yaml`
- Create: `ansible/playbooks/schema/apply-schema-production.yaml`

**Interfaces:**
- Consumes: `verify_full_suite` (Task 3), `backup_ipa_state` (Task 4), `isolate_replication` (Task 5), `freeipa.ansible_freeipa.ipauser` module
- Produces: three-layer schema protection playbooks (Layer 1: offline validation, Layer 3: isolated canary, production apply with reconnect). Layer 2 (throwaway instance) is a standalone script, not an Ansible play — it runs in a Podman container on a build host.

- [ ] **Step 1: Write syntax test**

- [ ] **Step 2: Create `validate-schema.yaml`**

Layer 1 offline validation. Var `schema_ldif` = path to LDIF file. Tasks: `dsconf schema validate` (requires 389-ds-base installed locally), OID extraction + conflict check against stock schema (via ldapsearch on primary), attribute reference check (Python script). Sets fact `schema_valid: true/false`.

- [ ] **Step 3: Create `canary-schema.yaml`**

Per spec Part 6 section 3. Pre-flight: `verify_full_suite` + `backup_ipa_state` (with `include_lmdb: true`). Isolate replica3 via `isolate_replication` role. Verify isolation (create user on primary, confirm absent on replica3). Copy LDIF to canary, apply via ldapmodify, verify DS alive + schema loaded (4 WID objectClasses) + DS restart survives + kinit + `ipa ping` + user CRUD. If pass: reconnect replication, wait 20s, verify schema on all 4 nodes, run `verify_full_suite`. If fail: restore from LMDB backup, reconnect.

- [ ] **Step 4: Create `apply-schema-production.yaml`**

Orchestrates the full S0→S4 sequence from spec. Imports `validate-schema.yaml`, then `canary-schema.yaml`. After reconnect: verifies schema count on all nodes, runs `verify_full_suite`. This is the single-command entry point for schema migration.

- [ ] **Step 5: Syntax check all three**

Run: `for f in ansible/playbooks/schema/*.yaml; do ansible-playbook --syntax-check "$f" -i ansible/inventory/imagemode.ini; done`
Expected: all PASS

- [ ] **Step 6: Commit**

```bash
git add ansible/playbooks/schema/
git commit -m "$(cat <<'EOF'
feat: add three-layer schema migration playbooks

Offline validation (dsconf + OID check), isolated canary with blast
shield (paused replication + LMDB backup), and production apply with
automatic reconnect and full verification.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Verification + Recovery Playbooks

**Files:**
- Create: `ansible/playbooks/verify/verify-all.yaml`
- Create: `ansible/playbooks/backup/backup-pre-upgrade.yaml`
- Create: `ansible/playbooks/recovery/recover-single-node.yaml`
- Create: `ansible/playbooks/recovery/repair-replication.yaml`
- Create: `ansible/playbooks/recovery/diagnose-auth.yaml`

**Interfaces:**
- Consumes: `verify_ipa_health` (Task 2), `verify_replication` (Task 3), `verify_full_suite` (Task 3), `backup_ipa_state` (Task 4), `nuclear_cleanup` (Task 5), `freeipa.ansible_freeipa.ipauser`, `ipaserver`, `ipahost`, `ipareplica`
- Produces: standalone playbooks for each operation — usable from CLI independent of the lifecycle playbooks.

- [ ] **Step 1: Create `verify-all.yaml`**

Per spec Part 6 section 5. Topology verification on primary (domain + ca suffix), service health on all nodes (ipactl + ports), Kerberos auth on all (kinit + `ipa ping` + cert-show), cross-node service tickets (kvno HTTP/<fqdn>), LDAP bind tests (GSSAPI + simple + password), replication consistency (create user, check on replicas, cleanup), agreement status check, conditional WID verification.

- [ ] **Step 2: Create `backup-pre-upgrade.yaml`**

Runs `backup_ipa_state` on all nodes with `include_lmdb: true` and a timestamped label.

- [ ] **Step 3: Create `recover-single-node.yaml`**

Per spec R1 and Part 6 section 4. Target node: rollback, reboot, uninstall, `nuclear_cleanup`. Primary: `ipaserver` state=absent + `ipahost` del + re-add. Target: dir tree pre-create + swap + `ipareplica` role + `verify_full_suite`.

- [ ] **Step 4: Create `repair-replication.yaml`**

Per spec R2. Diagnosis: `ipa topologysuffix-verify`, ldapsearch agreements for error status, detect stale agreements. Fix: delete stale topology segments, optionally `ipa-replica-manage re-initialize`.

- [ ] **Step 5: Create `diagnose-auth.yaml`**

Per spec R3. Check KDC, DS, httpd services. Check `/run/ipa/services.list` (WID #25). Check LDAP ports, TLS. Check custodia loginuid error. Output diagnostic report.

- [ ] **Step 6: Syntax check all**

Run: `for d in verify backup recovery; do for f in ansible/playbooks/$d/*.yaml; do ansible-playbook --syntax-check "$f" -i ansible/inventory/imagemode.ini; done; done`
Expected: all PASS

- [ ] **Step 7: Commit**

```bash
git add ansible/playbooks/verify/ ansible/playbooks/backup/ ansible/playbooks/recovery/
git commit -m "$(cat <<'EOF'
feat: add verification, backup, and recovery playbooks

verify-all: full cluster health suite (topology, replication, auth,
certs, cross-node tickets, LDAP binds). Recovery playbooks for R1
(single-node re-enroll), R2 (replication repair), R3 (auth diagnosis).

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: WID Overlay + idm-ci Integration

**Files:**
- Create: `ansible/roles/verify_wid/tasks/main.yaml`
- Create: `ansible/roles/verify_wid/defaults/main.yaml`
- Create: `ansible/playbooks/wid/deploy-wid-overlay.yaml`
- Create: `ansible/playbooks/wid/validate-wid.yaml`
- Create: `idmci/metadata/4-replica-bootc-metadata.yaml`
- Create: `idmci/bootc-containerfiles/bootc-freeipa-rhel-10.4`

**Interfaces:**
- Consumes: `verify_full_suite` (Task 3), existing WID ansible roles from `~/DevSpace/ipa-oauth2-plugin/ansible/roles/` (oauth2_schema, ahdapa, akamu, oauth2_clients, ipa_oauth2_validate), `bootc_lifecycle` (Task 4)
- Produces: `verify_wid` role (OIDC discovery + OAuth2 client credentials + ACME directory + Kerberos coexistence check). WID overlay playbook (rolling image rebase to WID image + Phase 2 services). idm-ci metadata YAML for mrack pipeline.

- [ ] **Step 1: Create `verify_wid` role**

`defaults/main.yaml`: `ahdapa_port: 8090`, `akamu_port: 19443`, `wid_test_client_id: test-verify-client`, `wid_test_client_secret: verify-secret-2026`.
`tasks/main.yaml`: OIDC discovery (uri module, check `issuer` in response), OAuth2 client credentials grant (uri module POST to `/token`), ACME directory (uri module, check `newNonce` in response), Kerberos still works (kinit + `ipa ping`).

- [ ] **Step 2: Create `deploy-wid-overlay.yaml`**

Rolling bootc switch to WID image (`serial: 1`, replica3→primary). After each reboot: `ipa-server-upgrade`, start WID Phase 2 services (ahdapa + akamu), run `verify_full_suite` with `wid_enabled: true`.

- [ ] **Step 3: Create `validate-wid.yaml`**

Standalone playbook running `verify_wid` role on all nodes + full replication consistency test.

- [ ] **Step 4: Create `idmci/metadata/4-replica-bootc-metadata.yaml`**

Per spec Part 1. Four hosts (primary + replica1-3), `os: rhel-10.4-bootc`. Phases: init, provision, prep, install (inject-config + wait-firstboot), test (verify-topology + test-replication), teardown.

- [ ] **Step 5: Create `idmci/bootc-containerfiles/bootc-freeipa-rhel-10.4`**

Containerfile for idm-ci pipeline. Based on `Containerfile.server-rhel10` but adapted for idm-ci build conventions (matching existing `bootc-minimal-rhel-10.4` pattern).

- [ ] **Step 6: Syntax check + validate YAML**

Run: `ansible-playbook --syntax-check ansible/playbooks/wid/deploy-wid-overlay.yaml -i ansible/inventory/imagemode.ini`
Run: `python3 -c "import yaml; yaml.safe_load(open('idmci/metadata/4-replica-bootc-metadata.yaml'))"`
Expected: both PASS

- [ ] **Step 7: Commit**

```bash
git add ansible/roles/verify_wid/ ansible/playbooks/wid/ idmci/
git commit -m "$(cat <<'EOF'
feat: add WID overlay automation and idm-ci integration

WID verification role (OAuth2/ACME/Kerberos coexistence), WID overlay
deploy playbook (rolling bootc switch), and idm-ci metadata YAML
for 4-node cluster provisioning via mrack.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:** All 6 parts covered. Part 1 (cluster recipe) → Tasks 1, 6, 10. Part 2 (update/rollback) → Tasks 1, 4, 7. Part 3 (stock→WID upgrade) → Tasks 8, 10. Part 4 (verification) → Tasks 2, 3, 9. Part 5 (rollback runbook) → Tasks 5, 7, 9. Part 6 (automation inventory) → Tasks 2-10.

**Step scan:** Each step produces exactly one artifact. No "TBD" or "add appropriate validation" steps. Test steps are syntax checks (the only thing testable without live infrastructure).

**Type consistency:** `verify_ipa_health` → sets `ipa_health_passed`. `verify_replication` → sets `replication_healthy`. `verify_full_suite` → sets `verification_passed`. All consumers (rolling-upgrade assert, canary gate) reference `verification_passed` consistently.

**Review Focus items addressed:** All 5 items from the Review Focus section have corresponding implementation details in the relevant tasks. Swap idempotency (Task 6 pre-tasks). Replication timing (Task 3 defaults, configurable). Nuclear cleanup scope (Task 5, explicit glob). Post-upgrade race (Task 1, ldapwhoami retry). Bootc mode parameter (Task 4, `bootc_action` var).

**Proportion:** Plan is shorter than the 2838-line spec. Code blocks show signatures and test assertions, not full implementations.
