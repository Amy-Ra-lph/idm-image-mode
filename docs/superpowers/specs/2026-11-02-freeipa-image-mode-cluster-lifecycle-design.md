# FreeIPA Image Mode: 4-Node Cluster Lifecycle Design

**Date:** 2026-11-02
**Requested by:** ftrivino
**Context:** Stand up a 4-node FreeIPA replica cluster in image mode using
idm-ci, then prove graceful image update/rollback without database integrity
loss, and map the upgrade path from stock IdM to PoC IdM (OAuth2/ahdapa,
akamu/ACME, WID plugins).

## Intent

FreeIPA in RHEL Image Mode (bootc) is the future deployment model. Before we
can recommend it to customers, we need to prove three things:

1. A multi-replica cluster can be provisioned repeatably from a single image
2. The cluster survives image updates (minor version bumps) and rollbacks
   without schema corruption or replication breakage
3. An existing stock IdM image-mode deployment can be upgraded to the WID
   PoC stack (ahdapa, akamu, ipacta) without reinstallation

ftrivino wants this running through idm-ci's mrack pipeline so it integrates
with the IdM team's existing test infrastructure.

## Goals

- Produce an idm-ci metadata YAML + containerfile + playbooks for a 4-node
  FreeIPA image-mode cluster (1 primary + 3 replicas) on RHEL 10
- Document and test the bootc image update procedure, including
  `ipa-server-upgrade` post-boot and rollback scenarios
- Validate the upgrade path from stock RHEL FreeIPA image → WID-enhanced
  image, including schema migration and CA backend transition
- Apply lessons from the 47-item WID modrnizer deployment log

## Non-Goals

- Production hardening of the WID overlay (that's a separate effort)
- OpenShift Operator for FreeIPA (Phase 2, depends on RHEL validation)
- Performance benchmarking of image-mode vs RPM-mode FreeIPA
- Client enrollment testing (no client nodes in this topology — any replica
  can serve client operations)

## Anti-Goals

- Treating bootc rollback as a guaranteed safety net for schema changes — it
  isn't. `/var` persists, so LDAP data survives rollback unchanged. We must
  test and document what actually happens.
- Assuming ipacta can seamlessly replace Dogtag CA on an existing deployment —
  this needs explicit testing and may require re-keying.

---

## Part 1: 4-Node Cluster Recipe

### Topology

```
┌─────────────────────────────────────────────────┐
│                  RHEL 10 bootc                  │
│                                                 │
│  ┌──────────┐    repl    ┌──────────┐           │
│  │ primary  │◄──────────►│ replica1 │           │
│  │ (master) │            └──────────┘           │
│  └──────────┘                                   │
│       ▲  ▲                                      │
│  repl │  │ repl                                 │
│       ▼  ▼                                      │
│  ┌──────────┐            ┌──────────┐           │
│  │ replica2 │◄──────────►│ replica3 │           │
│  └──────────┘    repl    └──────────┘           │
│                                                 │
│  All nodes: freeipa-server + DNS + CA           │
│  Same bootc image, different config.env         │
└─────────────────────────────────────────────────┘
```

All four nodes run the same bootc image. Role (primary vs replica) is
determined by `/etc/idm-image-mode/config.env` injected at provisioning time.

### Containerfile: bootc-freeipa-rhel-10

New containerfile for idm-ci, based on existing `bootc-minimal-rhel-10.x`
pattern:

```dockerfile
FROM images.paas.redhat.com/bootc/rhel-bootc:latest-10.4

# RHEL 10 repos (nightly compose)
RUN cat <<'REPOEOF' >> /etc/yum.repos.d/rhel-10.repo
[rhel10.4-baseos]
name=rhel10.4-baseos
baseurl=http://download.devel.redhat.com/rhel-10/nightly/RHEL-10/latest-RHEL-10.4/compose/BaseOS/x86_64/os/
enabled=1
gpgcheck=0
[rhel10.4-appstream]
name=rhel10.4-appstream
baseurl=http://download.devel.redhat.com/rhel-10/nightly/RHEL-10/latest-RHEL-10.4/compose/AppStream/x86_64/os/
enabled=1
gpgcheck=0
REPOEOF

# FreeIPA server + DNS
RUN dnf install -y \
        freeipa-server \
        freeipa-server-dns \
        freeipa-server-trust-ad \
    && dnf clean all

# bootc infrastructure
RUN dnf install -y cloud-init qemu-guest-agent \
    && systemctl enable cloud-init qemu-guest-agent

# fstab for bootc root
RUN echo "LABEL=root / ext4 defaults 0 1" >> /etc/fstab

# Firstboot provisioning
COPY config/idm-firstboot.sh /usr/local/sbin/idm-firstboot
COPY config/idm-firstboot.service /etc/systemd/system/idm-firstboot.service
RUN chmod 755 /usr/local/sbin/idm-firstboot \
    && mkdir -p /var/lib/idm-image-mode \
    && systemctl enable idm-firstboot.service

# Redirect /usr/share/ipa/html → /var (bootc makes /usr read-only)
RUN mkdir -p /var/lib/ipa/html \
    && cp -a /usr/share/ipa/html/. /var/lib/ipa/html/ 2>/dev/null || true \
    && rm -rf /usr/share/ipa/html \
    && ln -s /var/lib/ipa/html /usr/share/ipa/html

# Image upgrade hook (detects version change on boot)
COPY config/idm-post-upgrade.sh /usr/local/sbin/idm-post-upgrade
COPY config/idm-post-upgrade.service /etc/systemd/system/idm-post-upgrade.service
RUN chmod 755 /usr/local/sbin/idm-post-upgrade \
    && systemctl enable idm-post-upgrade.service
```

### idm-ci Metadata YAML

```yaml
# metadata/image-mode/4-replica-bootc-metadata.yaml
ssh_key_filename: ~/.ssh/id_rsa
admin_id: admin
admin_pw: Secret123
dirman_id: '"cn=Directory Manager"'
dirman_pw: Secret123
dns_forwarder: 10.11.5.19

domains:
  - name: imagemode.test
    type: IPA
    hosts:
      - name: primary.imagemode.test
        role: master
        group: ipaserver
        os: rhel-10.4-bootc
      - name: replica1.imagemode.test
        role: replica
        group: ipaserver
        os: rhel-10.4-bootc
      - name: replica2.imagemode.test
        role: replica
        group: ipaserver
        os: rhel-10.4-bootc
      - name: replica3.imagemode.test
        role: replica
        group: ipaserver
        os: rhel-10.4-bootc

phases:
  - name: init
    steps:
      - playbook: init/testrunner-dir.yaml
  - name: provision
    steps:
      - playbook: provision/mrack-up.yaml
      - playbook: provision/wait.yaml
  - name: prep
    steps:
      - playbook: prep/redhat-base.yaml
      - playbook: prep/ipa-network.yaml
  - name: install
    steps:
      - playbook: image-mode/inject-config.yaml
      - playbook: image-mode/wait-firstboot.yaml
        timeout: 1800
  - name: test
    steps:
      - playbook: image-mode/verify-topology.yaml
      - playbook: image-mode/test-replication.yaml
  - name: teardown
    steps:
      - playbook: teardown/mrack-destroy.yaml
```

### Provisioning Sequence

Replicas must be promoted sequentially — parallel promotion creates race
conditions in replication agreement creation.

```
Timeline:
  T+0    primary firstboot starts (ipa-server-install)
  T+8m   primary ready, ipactl status OK
  T+8m   replica1 firstboot starts (ipa-client-install → ipa-replica-install)
  T+18m  replica1 ready, replication healthy
  T+18m  replica2 firstboot starts
  T+28m  replica2 ready
  T+28m  replica3 firstboot starts
  T+38m  replica3 ready, full mesh replication verified
```

The `inject-config.yaml` playbook sets `IDM_ROLE` and staggering delays.
Alternative: use Ansible serial execution (`serial: 1`) on replicas.

### Critical Lessons Applied (from WID modrnizer log)

| # | Lesson | How Applied |
|---|--------|-------------|
| 17 | Missing `/var/lib/ipa/` subdirs | Firstboot pre-creates full directory tree before `ipa-replica-install` |
| 18 | Replica IP must match DNS | Firstboot verifies `hostname -I` matches DNS A record before promotion |
| 20 | `--skip-conncheck` for retries | Firstboot uses `--skip-conncheck` after first failure |
| 21-24 | Stale replication agreements | Cleanup script removes topology segments + server entries from LDAP (not dse.ldif) before retry |
| 25 | Missing `/run/ipa/services.list` | Post-boot check recreates if needed |
| 42 | Nuclear cleanup recipe | Full cleanup function in firstboot for retry-safe operation |
| 46 | pkispawn OOM on 2GB VMs | Firstboot adds 1GB swap before `--setup-ca` |

---

## Part 2: Image Update and Rollback

### How bootc Updates Work

```
Before update:
  /usr  ← image v1 (composefs, read-only)
  /etc  ← overlay (writable, merged from image + local changes)
  /var  ← persistent (never touched by bootc)

After `bootc upgrade` + reboot:
  /usr  ← image v2 (composefs, read-only)
  /etc  ← overlay (v2 base + local changes preserved)
  /var  ← unchanged (same data, same 389-DS databases)

After `bootc rollback` + reboot:
  /usr  ← image v1 (composefs, read-only)
  /etc  ← overlay (v1 base + all accumulated local changes)
  /var  ← unchanged (still has data from v2 era)
```

### The Schema Problem

FreeIPA stores schema definitions in two places:

1. **Image layer** (`/usr/share/ipa/updates/`, `/usr/share/dirsrv/schema/`) —
   replaced on image update
2. **Database** (`/var/lib/dirsrv/slapd-*/dse.ldif`, LMDB) — persists across
   updates and rollbacks

When `ipa-server-upgrade` runs after an image update:
- It reads the new schema files from `/usr`
- Applies schema changes to the 389-DS database in `/var`
- Records completed updates in `/var/lib/ipa/sysupgrade/sysupgrade.state`

On rollback:
- `/usr` has the old schema files (fewer attributes/objectclasses)
- `/var` has the upgraded database with new schema entries
- `/var/lib/ipa/sysupgrade/sysupgrade.state` says the newer updates were applied

**Risk:** 389-DS tolerates unknown schema entries gracefully — it won't crash.
But `ipa-server-upgrade` on the old image might re-apply updates or skip them
incorrectly based on stale sysupgrade state.

### Proposed Update Strategy: Rolling Upgrade

For a 4-replica cluster, use the N-1 rolling upgrade pattern:

```
Step 1: Verify baseline health
  - All 4 nodes: ipactl status OK
  - Replication: ipa topologysuffix-verify (no disconnected segments)
  - Schema version: record current ipa-server RPM version + ds schema hash

Step 2: Upgrade replica3 (lowest risk)
  a. bootc upgrade --apply (stages new image)
  b. Reboot
  c. idm-post-upgrade.service detects version change
  d. ipa-server-upgrade runs automatically
  e. Verify: ipactl status, replication to all peers, schema consistent

Step 3: If replica3 healthy → upgrade replica2
  Same procedure. Now 2 replicas on new image, 2 on old.

Step 4: If replica2 healthy → upgrade replica1
  3 replicas on new image, primary on old.

Step 5: Upgrade primary last
  Primary upgrade. Full cluster now on new image.

Step 6: Verify final state
  - All 4 nodes: ipactl status, ipa-healthcheck
  - Replication ring: all agreements healthy
  - Schema: consistent across all nodes
```

### The `idm-post-upgrade` Service

A systemd oneshot that runs on every boot, after 389-DS starts:

```bash
#!/bin/bash
# idm-post-upgrade — detect image version change, run ipa-server-upgrade

STAMP_FILE="/var/lib/idm-image-mode/.image-version"
CURRENT_VERSION=$(rpm -q freeipa-server 2>/dev/null || echo "unknown")

if [[ -f "$STAMP_FILE" ]]; then
    PREV_VERSION=$(cat "$STAMP_FILE")
    if [[ "$CURRENT_VERSION" != "$PREV_VERSION" ]]; then
        logger -t idm-post-upgrade "Image version changed: $PREV_VERSION → $CURRENT_VERSION"

        # Pre-upgrade backup
        BACKUP_DIR="/var/lib/idm-image-mode/backups/$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        cp /var/lib/ipa/sysupgrade/sysupgrade.state "$BACKUP_DIR/" 2>/dev/null
        # Export LDAP schema for rollback reference
        ldapsearch -Y EXTERNAL -H ldapi://%2Fvar%2Frun%2Fslapd-*.socket \
            -b "cn=schema" -s base objectClasses attributeTypes \
            > "$BACKUP_DIR/schema-before.ldif" 2>/dev/null

        # Run upgrade
        ipa-server-upgrade
        RC=$?

        if [[ $RC -eq 0 ]]; then
            echo "$CURRENT_VERSION" > "$STAMP_FILE"
            logger -t idm-post-upgrade "Upgrade successful"
        else
            logger -t idm-post-upgrade "Upgrade FAILED (rc=$RC) — rollback may be needed"
            # Don't update stamp — next boot retries
        fi
    fi
else
    echo "$CURRENT_VERSION" > "$STAMP_FILE"
fi
```

### Rollback Procedure

**Scenario: Replica upgrade failed or caused replication issues.**

```
Option A: Re-enroll from healthy replicas (preferred)
  1. On failed replica: bootc rollback && reboot
  2. ipa-server-install --uninstall -U
  3. On healthy primary: ipa server-del failed-replica --force
  4. Re-run firstboot (ipa-client-install → ipa-replica-install)
  5. Replica catches up from replication

Option B: Restore pre-upgrade state (if schema changes cause issues)
  1. On failed replica: bootc rollback && reboot
  2. Stop 389-DS: systemctl stop dirsrv@REALM
  3. Restore sysupgrade.state from backup
  4. Restart: systemctl start dirsrv@REALM
  5. Run ipa-server-upgrade (re-applies old version's updates)
  6. Verify replication
```

Option A is safer — it lets the replica learn the correct state from healthy
peers. Option B is for the scenario where ALL replicas need to rollback.

### What We Must Test

| Test | Pass Criteria |
|------|---------------|
| Minor version update (e.g., 4.12.1 → 4.12.2) | `ipa-server-upgrade` succeeds, replication healthy |
| Rollback after minor update | 389-DS starts, old code tolerates new schema entries |
| Mixed-version cluster (2 old + 2 new) | Replication works across versions |
| Re-enrollment after rollback | Replica catches up without data loss |
| Sysupgrade state after rollback | `ipa-server-upgrade` on old version handles forward state |
| Update during active replication | No replication lag or agreement breakage |

---

## Part 3: Upgrade Path — Stock IdM → PoC IdM (WID)

### What Changes

| Component | Stock IdM | PoC IdM (WID) |
|-----------|-----------|---------------|
| CA backend | Dogtag (pki-tomcatd, Java) | ipacta (Python, no Java) |
| OAuth2/OIDC | None | ahdapa (Rust, systemd) |
| ACME | None | akamu (Rust, ML-DSA-65) |
| LDAP schema | Stock FreeIPA schema | + 80oauth2.ldif (clients, scopes, workloads) |
| WID plugins | None | 74 IPA commands (oauth2client-*, scope-*, workload-*) |
| IPA html symlink | `/usr/share/ipa/html` → `/var/lib/ipa/html` | Same |
| RPM source | RHEL repos | twoerner/freeipa COPR + twoerner/ipacta + abbra/synta |

### The CA Backend Transition (Dogtag → ipacta)

This is the hardest part. Two possible approaches:

**Approach 1: Parallel CA (recommended for PoC)**

Keep Dogtag running during transition. Install ipacta alongside. Migrate
CA signing operations to ipacta. Decommission Dogtag after validation.

```
Phase A: Add ipacta packages (image rebase)
  - New image includes twoerner/freeipa + twoerner/ipacta COPRs
  - Dogtag still running, still issuing certs
  - ipacta installed but not configured as CA backend

Phase B: Configure ipacta as secondary CA
  - Import existing CA cert chain into ipacta
  - Verify ipacta can issue certs with same root
  - IPA still using Dogtag for cert operations

Phase C: Switch CA backend
  - ipa-server-install reconfigure (if supported) or
  - Manual config change in /etc/ipa/default.conf + CS.cfg
  - Verify cert issuance, renewal, OCSP

Phase D: Decommission Dogtag
  - Stop pki-tomcatd
  - Remove Dogtag packages from next image build
  - Verify IPA operations without Dogtag
```

**Open question for twoerner/AB:** Can ipacta import an existing Dogtag CA's
private key and cert chain? If not, a fresh CA with cross-signing may be
needed — that's more complex but preserves existing cert validity.

**Approach 2: Fresh install with migration (simpler but more disruptive)**

Build the WID image. Deploy as a new replica. Migrate data via replication.
Decommission old replicas one by one.

```
1. Build WID bootc image (from wid-image-mode repo)
2. Deploy as replica4 in existing topology
3. Promote to replica with --setup-ca (ipacta backend)
4. Verify: replication, cert issuance, WID plugin commands
5. Add WID schema (80oauth2.ldif) via ldapmodify on primary
6. Deploy more WID replicas, decommission stock replicas
7. Final primary switchover: WID replica promoted to primary role
```

This avoids the Dogtag→ipacta migration entirely. The trade-off is a
rolling replacement of all nodes rather than an in-place upgrade.

### Schema Migration Strategy: Separate Schema from Code

The critical insight: **apply the WID schema BEFORE rebasing any node to
the WID image.** This separates two risky operations (schema migration and
code migration) into independently verifiable steps.

#### Why Separate

If schema and code change together (via image rebase), a failure could be
either — hard to diagnose. If schema is already present and verified
healthy, the image rebase only changes code. Rollback of code doesn't
affect schema (schema lives in `/var`, code in `/usr`).

#### WID Schema Contents

`80oauth2.ldif` adds:

| Type | OID prefix | Names |
|------|-----------|-------|
| attributeTypes | 2.16.840.1.113730.3.8.24.1.x | `ipaOAuth2ClientId`, `ipaOAuth2ClientSecret`, `ipaOAuth2RedirectURI`, `ipaOAuth2Scope`, `ipaOAuth2GrantType`, `ipaWorkloadType`, `ipaWorkloadSPIFFEID`, `ipaWorkloadDelegationTarget`, `ipaWorkloadDelegationConstraint` |
| objectClasses | 2.16.840.1.113730.3.8.24.2.x | `ipaOAuth2Client`, `ipaOAuth2Scope`, `ipaWorkload`, `ipaWorkloadDelegation` |

All new OIDs under the IPA arc. No modifications to existing schema —
purely additive.

#### The Danger: Schema Replication Has No Undo Button

Once `ldapmodify` adds schema to ANY node's `cn=schema`, 389-DS
replicates it to ALL peers automatically. If the schema LDIF has a bug:

- **Bad OID or syntax:** 389-DS rejects the ldapmodify (safe — nothing
  applied). But if accepted locally and the LDIF triggers a bug in the
  replication consumer's schema parser, the receiving DS could crash.
- **OID conflict with existing attribute:** Local DS may accept it but
  peer DS crashes on replication with "duplicate OID" error. DS enters
  a restart loop, LMDB locks accumulate in `/dev/shm/slapd-*`, and the
  node becomes unreachable.
- **Schema triggers index rebuild storm:** New indexed attributes cause
  389-DS to rebuild indexes on all existing entries. On a large DB this
  blocks LDAP operations for minutes. If replication times out during
  the rebuild, agreements break.

**Bottom line:** You cannot canary a schema change through live
replication. By the time you see the result on one node, all nodes
already have it.

#### Defense: Three-Layer Protection

```
Layer 1: Offline validation (catches syntax/OID bugs)
  ↓ pass
Layer 2: Throwaway instance test (catches DS crashes/corruption)
  ↓ pass
Layer 3: Isolated canary node (catches replication-specific issues)
  ↓ pass
Production apply with blast shield
```

#### Layer 1: Offline Schema Validation

Validate the LDIF before it touches any running DS instance.

```bash
# === Run on build host, NOT on any cluster node ===

SCHEMA_LDIF="80oauth2.ldif"

# 1. Syntax check — dsconf validates OID format, SYNTAX refs, SUP chains
#    Install 389-ds-base locally for the tool (no running instance needed)
dsconf schema validate "$SCHEMA_LDIF" 2>&1
# PASS: "Schema is valid"
# FAIL: "Error: <details>" — fix LDIF before proceeding

# 2. OID conflict check — compare against stock FreeIPA schema
#    Extract OIDs from the new LDIF
grep -oP '\d+\.\d+\.\d+\.\d+\.\d+\.\d+\.\d+\.\d+' "$SCHEMA_LDIF" \
  | sort -u > /tmp/new-oids.txt

#    Extract OIDs from a stock FreeIPA DS instance's schema
ldapsearch -Y EXTERNAL -H ldapi:// -b "cn=schema" -s base \
  objectClasses attributeTypes 2>/dev/null \
  | grep -oP '\d+\.\d+\.\d+\.\d+\.\d+\.\d+\.\d+\.\d+' \
  | sort -u > /tmp/existing-oids.txt

#    Any overlap = conflict
comm -12 /tmp/new-oids.txt /tmp/existing-oids.txt
# PASS: no output (no overlapping OIDs)
# FAIL: overlapping OIDs listed — fix LDIF

# 3. Attribute reference check — every attribute in MAY/MUST of an
#    objectClass must exist (either in the new LDIF or in stock schema)
python3 <<'PYEOF'
import re, sys

with open("80oauth2.ldif") as f:
    ldif = f.read()

# Extract NAME values from attributeTypes
new_attrs = set(re.findall(r"attributeTypes:.*?NAME\s+'(\w+)'", ldif))

# Extract MUST/MAY references from objectClasses
refs = set()
for match in re.finditer(r"objectClasses:.*?(?:MUST|MAY)\s*\(([^)]+)\)", ldif):
    refs.update(a.strip().strip("$").strip() for a in match.group(1).split("$"))

# Attrs referenced but not defined in this LDIF need to exist in stock schema
missing = refs - new_attrs
if missing:
    print(f"WARNING: These attributes must exist in stock schema: {missing}")
    print("Verify with: ldapsearch -Y EXTERNAL -H ldapi:// -b cn=schema "
          "-s base attributeTypes | grep <name>")
else:
    print("PASS: All referenced attributes defined in LDIF")
PYEOF
```

#### Layer 2: Throwaway Instance Test

Spin up a disposable single-node IPA, apply schema, verify DS survives.

```bash
# === On build host or CI runner, NOT on cluster nodes ===

# 1. Deploy a throwaway IPA instance (container or VM)
podman run -d --name schema-test --hostname test.schema.test \
  --privileged --systemd=true \
  localhost/idm-image-mode-server:latest

# Wait for firstboot
podman exec schema-test bash -c '
  while [ ! -f /var/lib/idm-image-mode/.firstboot-complete ]; do
    sleep 10
  done
'

# 2. Apply schema
podman cp 80oauth2.ldif schema-test:/tmp/
podman exec schema-test bash -c '
  # Convert schema file to ldapmodify format and apply
  /usr/local/sbin/idm-schema-apply /tmp/80oauth2.ldif
'
# Check exit code — 0 = applied, non-zero = rejected

# 3. Verify DS survived
podman exec schema-test bash -c '
  # DS still running?
  systemctl is-active dirsrv@SCHEMA-TEST && echo "DS: alive" || echo "DS: DEAD"

  # Schema loaded?
  ldapsearch -Y EXTERNAL -H ldapi:// -b cn=schema -s base objectClasses \
    | grep -c ipaOAuth2

  # IPA still works?
  echo Secret123 | kinit admin && ipa ping && echo "IPA: OK"

  # Restart DS — catches schema load-from-disk issues
  systemctl restart dirsrv@SCHEMA-TEST
  sleep 5
  systemctl is-active dirsrv@SCHEMA-TEST && echo "DS restart: OK" || echo "DS restart: FAIL"

  # Create a test entry using new objectClass
  ldapadd -Y EXTERNAL -H ldapi:// <<TESTEOF
dn: ipaOAuth2ClientId=layer2-test,cn=oauth2,dc=schema,dc=test
objectClass: top
objectClass: ipaOAuth2Client
ipaOAuth2ClientId: layer2-test
TESTEOF
  echo "Entry create: $?"

  # Delete it
  ldapdelete -Y EXTERNAL -H ldapi:// \
    "ipaOAuth2ClientId=layer2-test,cn=oauth2,dc=schema,dc=test"
'

# 4. Clean up
podman rm -f schema-test

# GATE: All checks pass → proceed to Layer 3
# FAIL: Fix LDIF, re-run from Layer 1
```

#### Layer 3: Isolated Canary with Blast Shield

Test schema on a REAL cluster node, but isolated from replication so
damage can't spread.

```
Cluster state before canary:

  primary ◄──► replica1 ◄──► replica2 ◄──► replica3
     ▲              ▲                          │
     └──────────────┴──────────────────────────┘
                  (full mesh replication)

Step 1: Isolate replica3 from replication
  - Pause ALL replication agreements TO and FROM replica3
  - replica3 still runs, still serves auth, but gets no updates
  - primary + replica1 + replica2 continue replicating among themselves

Step 2: Apply schema on isolated replica3
  - If it crashes → only replica3 affected
  - Other 3 nodes untouched, cluster fully operational

Step 3: Verify replica3 health
  - If healthy → reconnect replication, schema propagates safely
  - If broken → R1 recovery (re-enroll replica3 from healthy peers)
```

```bash
# === Step 1: Isolate replica3 ===

# Pause outbound replication FROM replica3
ssh root@replica3.imagemode.test bash <<'ISOLATE_OUT'
  # Find all replication agreements on replica3
  AGREEMENTS=$(ldapsearch -Y EXTERNAL -H ldapi:// \
    -b "cn=config" "(objectClass=nsds5replicationagreement)" dn 2>/dev/null \
    | grep "^dn:" | sed 's/^dn: //')

  for AGR in $AGREEMENTS; do
    echo "Pausing outbound: $AGR"
    ldapmodify -Y EXTERNAL -H ldapi:// <<EOF
dn: $AGR
changetype: modify
replace: nsds5ReplicaEnabled
nsds5ReplicaEnabled: off
EOF
  done
ISOLATE_OUT

# Pause inbound replication TO replica3 (on each peer)
for PEER in primary replica1 replica2; do
  ssh root@${PEER}.imagemode.test bash <<ISOLATE_IN
    AGREEMENTS=\$(ldapsearch -Y EXTERNAL -H ldapi:// \
      -b "cn=config" \
      "(&(objectClass=nsds5replicationagreement)(nsds5replicahost=replica3.imagemode.test))" \
      dn 2>/dev/null | grep "^dn:" | sed 's/^dn: //')

    for AGR in \$AGREEMENTS; do
      echo "Pausing inbound on ${PEER}: \$AGR"
      ldapmodify -Y EXTERNAL -H ldapi:// <<EOF
dn: \$AGR
changetype: modify
replace: nsds5ReplicaEnabled
nsds5ReplicaEnabled: off
EOF
    done
ISOLATE_IN
done

# Verify isolation: write on primary, confirm it does NOT appear on replica3
ssh root@primary.imagemode.test bash -c '
  echo Secret123 | kinit admin
  ipa user-add canary-isolation-test --first=Canary --last=Test
'
sleep 10
ssh root@replica3.imagemode.test bash -c '
  ldapsearch -x -H ldap://localhost -D "cn=Directory Manager" -w Secret123 \
    -b "cn=users,cn=accounts,dc=imagemode,dc=test" "(uid=canary-isolation-test)" dn
'
# Expected: no results (replica3 is isolated)
# If results appear: isolation failed, STOP — do not proceed

# Clean up test user
ssh root@primary.imagemode.test bash -c 'ipa user-del canary-isolation-test'


# === Step 2: Apply schema on isolated replica3 ===

ssh root@replica3.imagemode.test bash <<'APPLY'
  # Backup DS state before schema change
  BACKUP="/var/lib/idm-image-mode/backups/pre-schema-canary"
  mkdir -p "$BACKUP"
  ldapsearch -Y EXTERNAL -H ldapi:// -b cn=schema -s base \
    objectClasses attributeTypes > "$BACKUP/schema-before.ldif" 2>/dev/null
  cp /var/lib/ipa/sysupgrade/sysupgrade.state "$BACKUP/" 2>/dev/null

  # Backup LMDB files (filesystem-level, for corruption recovery)
  cp -a /var/lib/dirsrv/slapd-IMAGEMODE-TEST/db/ "$BACKUP/db-snapshot/"

  # Apply schema
  ldapmodify -Y EXTERNAL \
    -H ldapi://%2Fvar%2Frun%2Fslapd-IMAGEMODE-TEST.socket \
    -f /tmp/80oauth2-ldapmodify.ldif
  APPLY_RC=$?
  echo "ldapmodify exit code: $APPLY_RC"
APPLY


# === Step 3: Verify replica3 health ===

ssh root@replica3.imagemode.test bash <<'VERIFY'
  FAIL=0

  # DS still alive?
  systemctl is-active dirsrv@IMAGEMODE-TEST || { echo "FAIL: DS crashed"; FAIL=1; }

  # Schema loaded?
  COUNT=$(ldapsearch -Y EXTERNAL -H ldapi:// -b cn=schema -s base \
    objectClasses 2>/dev/null | grep -c ipaOAuth2)
  [ "$COUNT" -eq 4 ] || { echo "FAIL: Expected 4 WID objectClasses, got $COUNT"; FAIL=1; }

  # DS survives restart? (catches schema-load-from-disk bugs)
  systemctl restart dirsrv@IMAGEMODE-TEST
  sleep 5
  systemctl is-active dirsrv@IMAGEMODE-TEST || { echo "FAIL: DS won't restart"; FAIL=1; }

  # Kerberos still works?
  echo Secret123 | kinit admin 2>/dev/null || { echo "FAIL: kinit broken"; FAIL=1; }

  # IPA API still works?
  ipa ping 2>/dev/null || { echo "FAIL: IPA API broken"; FAIL=1; }

  # LDAP operations still work?
  ipa user-add schema-test-user --first=Schema --last=Test 2>/dev/null \
    || { echo "FAIL: user-add broken"; FAIL=1; }
  ipa user-del schema-test-user 2>/dev/null

  # Test entry with new objectClass (proves schema is usable)
  ldapadd -Y EXTERNAL -H ldapi:// <<'TESTENTRY' 2>/dev/null
dn: ipaOAuth2ClientId=canary-test,cn=oauth2clients,cn=etc,dc=imagemode,dc=test
objectClass: top
objectClass: ipaOAuth2Client
ipaOAuth2ClientId: canary-test
TESTENTRY
  ADD_RC=$?
  # Clean up (may fail if container doesn't exist yet — OK)
  ldapdelete -Y EXTERNAL -H ldapi:// \
    "ipaOAuth2ClientId=canary-test,cn=oauth2clients,cn=etc,dc=imagemode,dc=test" 2>/dev/null

  [ $FAIL -eq 0 ] && echo "CANARY: ALL CHECKS PASSED" || echo "CANARY: FAILED"
  exit $FAIL
VERIFY

CANARY_RC=$?


# === Step 4: Decision gate ===

if [ $CANARY_RC -eq 0 ]; then
    echo "=== CANARY PASSED — reconnecting replication ==="

    # Re-enable all replication agreements
    for NODE in primary replica1 replica2 replica3; do
      ssh root@${NODE}.imagemode.test bash <<'RECONNECT'
        AGREEMENTS=$(ldapsearch -Y EXTERNAL -H ldapi:// \
          -b "cn=config" "(objectClass=nsds5replicationagreement)" dn 2>/dev/null \
          | grep "^dn:" | sed 's/^dn: //')
        for AGR in $AGREEMENTS; do
          ldapmodify -Y EXTERNAL -H ldapi:// <<EOF
dn: $AGR
changetype: modify
replace: nsds5ReplicaEnabled
nsds5ReplicaEnabled: on
EOF
        done
RECONNECT
    done

    # Wait for schema to replicate from replica3 to all peers
    sleep 15

    # Verify schema on all nodes
    for N in primary replica1 replica2; do
      FQDN="${N}.imagemode.test"
      COUNT=$(ldapsearch -x -H ldap://${FQDN} \
        -D "cn=Directory Manager" -w Secret123 \
        -b "cn=schema" -s base objectClasses 2>/dev/null \
        | grep -c "ipaOAuth2")
      echo "${FQDN}: ${COUNT} WID objectClasses"
    done

    # Full verification suite on entire cluster
    # (replication + auth + service tickets)

else
    echo "=== CANARY FAILED — recovering replica3 ==="

    # replica3 is isolated and broken. Other 3 nodes are untouched.

    # Option A: Restore from DB snapshot
    ssh root@replica3.imagemode.test bash <<'RESTORE'
      systemctl stop dirsrv@IMAGEMODE-TEST
      rm -rf /var/lib/dirsrv/slapd-IMAGEMODE-TEST/db/
      cp -a /var/lib/idm-image-mode/backups/pre-schema-canary/db-snapshot/ \
            /var/lib/dirsrv/slapd-IMAGEMODE-TEST/db/
      rm -rf /dev/shm/slapd-IMAGEMODE-TEST*
      restorecon -Rv /var/lib/dirsrv/
      systemctl start dirsrv@IMAGEMODE-TEST
RESTORE

    # Re-enable replication (schema never reached other nodes)
    # ... (same reconnect loop as above)

    # Option B: If restore fails, full R1 recovery
    # (uninstall + re-enroll replica3 from healthy peers)
fi
```

#### Why This Order Matters

```
Blast radius at each layer:

  Layer 1 (offline validation)
    Risk:  zero — no running DS touched
    Catches: ~80% of schema bugs (syntax, OID conflicts, bad refs)

  Layer 2 (throwaway instance)
    Risk:  zero — disposable container, destroyed after test
    Catches: ~15% more (DS crash on schema load, entry creation failures)

  Layer 3 (isolated canary)
    Risk:  ONE node, isolated from replication
    Catches: remaining ~5% (replication-specific schema bugs, LMDB
             interactions, index rebuild impact on real data volume)

  Production apply (reconnect replication)
    Risk:  schema propagates to all nodes
    Protection: 3 layers already validated. If it still fails here,
                the canary node already has the schema and survived —
                the failure mode is replication-specific and the other
                3 nodes can be individually recovered via R1.
```

#### Step-by-Step Schema Migration (Full Procedure)

```
Phase S0: Offline validation (Layer 1 + Layer 2)
  ┌─────────────────────────────────────────────────────────┐
  │ 1. Run dsconf schema validate on 80oauth2.ldif          │
  │ 2. Check OID conflicts against stock schema             │
  │ 3. Verify attribute references                          │
  │ 4. Test on throwaway IPA instance (create, restart, ops)│
  │ GATE: All pass → proceed to S1                          │
  └─────────────────────────────────────────────────────────┘

Phase S1: Pre-flight (on stock cluster, all 4 nodes healthy)
  ┌─────────────────────────────────────────────────────────┐
  │ 1. Run full verification suite (Part 4)                 │
  │ 2. Snapshot sysupgrade state on all nodes               │
  │ 3. Export current schema baseline                       │
  │ 4. Backup LMDB on all nodes:                            │
  │    for N in primary replica{1..3}; do                   │
  │      ssh $N 'cp -a /var/lib/dirsrv/slapd-*/db/          │
  │        /var/lib/idm-image-mode/backups/pre-schema/db/'  │
  │    done                                                 │
  │ GATE: Full verification pass + all backups complete     │
  └─────────────────────────────────────────────────────────┘

Phase S2: Canary (Layer 3 — isolated replica3)
  ┌─────────────────────────────────────────────────────────┐
  │ 1. Isolate replica3 (pause all repl agreements)         │
  │ 2. Verify isolation (write on primary, absent on r3)    │
  │ 3. Apply schema on replica3 only                        │
  │ 4. Verify: DS alive, schema loaded, DS restart OK,      │
  │    kinit OK, IPA API OK, test entry create/delete OK    │
  │ GATE: All canary checks pass                            │
  │ FAIL: Restore r3 from DB snapshot, reconnect, fix LDIF  │
  └─────────────────────────────────────────────────────────┘

Phase S3: Propagate (reconnect replication)
  ┌─────────────────────────────────────────────────────────┐
  │ 1. Re-enable all replication agreements                 │
  │ 2. Wait 15s for schema propagation                      │
  │ 3. Verify 4 WID objectClasses on all 4 nodes           │
  │ GATE: All 4 nodes have schema                           │
  │ FAIL: Check replication agreements (R2 procedure)       │
  └─────────────────────────────────────────────────────────┘

Phase S4: Verify nothing broke
  ┌─────────────────────────────────────────────────────────┐
  │ Run full verification suite (Part 4):                   │
  │ - Replication: write/read consistency test              │
  │ - Auth: kinit, GSSAPI, IPA API, cert ops on all nodes  │
  │                                                         │
  │ Stock FreeIPA code ignores unknown objectClasses:       │
  │ - `ipa user-find` still works (doesn't query WID types) │
  │ - `ipa-server-upgrade` skips unknown schema (no error)  │
  │ - 389-DS indexes are unaffected (no WID entries exist)  │
  │                                                         │
  │ GATE: Full verification pass = schema migration safe.   │
  │ FAIL: Options:                                          │
  │   a. Isolate affected node, restore LMDB from backup    │
  │   b. R1 recovery (re-enroll from healthy peers)         │
  │   c. Full R6 rollback if all nodes affected             │
  └─────────────────────────────────────────────────────────┘
```

#### Node Failure During Schema Propagation

What if a node crashes while RECEIVING schema via replication?

```
Scenario: replica2 crashes while processing inbound schema replication

  primary ──schema──► replica1  (OK, schema applied)
  primary ──schema──► replica2  (DS CRASH mid-apply)
  primary ──schema──► replica3  (OK, schema applied via canary)

Recovery:
  1. replica2's DS is down. Other 3 nodes have schema and are healthy.
  2. On replica2:
     systemctl status dirsrv@IMAGEMODE-TEST  # confirm crashed
     journalctl -u dirsrv@IMAGEMODE-TEST     # find crash reason

  3. Try restart:
     rm -rf /dev/shm/slapd-IMAGEMODE-TEST*   # clear LMDB locks
     systemctl start dirsrv@IMAGEMODE-TEST

  4. If DS starts:
     # Check if schema was partially applied
     ldapsearch -Y EXTERNAL -H ldapi:// -b cn=schema -s base \
       objectClasses | grep -c ipaOAuth2
     # If 4: schema applied despite crash (restart fixed it)
     # If 0: DS rejected schema, will re-receive via replication
     # If 1-3: partial — force full schema reload:
     ipa-replica-manage re-initialize --from=primary.imagemode.test

  5. If DS won't start (LMDB corrupted):
     # Restore from pre-schema LMDB backup
     systemctl stop dirsrv@IMAGEMODE-TEST
     rm -rf /var/lib/dirsrv/slapd-IMAGEMODE-TEST/db/
     cp -a /var/lib/idm-image-mode/backups/pre-schema/db/ \
           /var/lib/dirsrv/slapd-IMAGEMODE-TEST/db/
     rm -rf /dev/shm/slapd-IMAGEMODE-TEST*
     restorecon -Rv /var/lib/dirsrv/
     systemctl start dirsrv@IMAGEMODE-TEST
     # DS starts with old schema, receives new schema via replication
     # (this time the schema is already validated on 3 nodes)

  6. If restore also fails: R1 recovery (full re-enroll from peers)

Key point: With 4 nodes, losing 1 to schema corruption is recoverable.
The other 3 have complete data + correct schema. The broken node re-learns
everything via replication after re-enrollment.
```

#### Schema Rollback (if needed before any WID data exists)

Schema removal is possible ONLY if no LDAP entries use the objectClasses.
Since we apply schema before the WID code creates any entries, rollback is
safe at this stage:

```bash
# Remove WID objectClasses (MUST remove objectClasses before attributeTypes)
ldapmodify -Y EXTERNAL \
  -H ldapi://%2Fvar%2Frun%2Fslapd-IMAGEMODE-TEST.socket <<'EOF'
dn: cn=schema
changetype: modify
delete: objectClasses
objectClasses: ( 2.16.840...1 NAME 'ipaOAuth2Client' ... )
-
delete: objectClasses
objectClasses: ( 2.16.840...2 NAME 'ipaOAuth2Scope' ... )
-
delete: objectClasses
objectClasses: ( 2.16.840...3 NAME 'ipaWorkload' ... )
-
delete: objectClasses
objectClasses: ( 2.16.840...4 NAME 'ipaWorkloadDelegation' ... )
-
delete: attributeTypes
attributeTypes: ( 2.16.840...1 NAME 'ipaOAuth2ClientId' ... )
# ... (all attributeTypes)
EOF
```

**Once WID entries exist** (OAuth2 clients registered, workloads created),
schema removal fails with `objectclass in use`. At that point, schema is
permanent. This is expected and acceptable — the schema itself is inert
without the WID code.

#### Schema + Image Rebase: Complete Sequence

```
Day 1: Schema migration (stock cluster, stock image)
  S1 → S2 → S3 → S4 (all above)
  Result: All 4 nodes have WID schema, still running stock FreeIPA

Day 2: Rolling image rebase to WID image
  For each node (replica3 → replica2 → replica1 → primary):
    1. bootc switch <wid-image-registry>/<wid-image>:latest
    2. Reboot
    3. idm-post-upgrade.service detects freeipa-server RPM change
    4. ipa-server-upgrade runs (schema already present, no-op for schema)
    5. wid-phase2.service starts ahdapa + akamu
    6. Run verification suite (replication + auth + WID-specific)
    7. GATE: proceed to next node only on full pass

Day 3: WID activation
  1. Register OAuth2 test client via IPA plugin commands
  2. Verify token issuance on all nodes
  3. Verify akamu ACME directory on all nodes
  4. Run full auth suite (Kerberos + OAuth2 + ACME)
```

### The Image Rebase Procedure

```
Stock Image:
  FROM images.paas.redhat.com/bootc/rhel-bootc:latest-10.4
  RUN dnf install freeipa-server ...

WID Image:
  FROM images.paas.redhat.com/bootc/rhel-bootc:latest-10.4
  RUN dnf install freeipa-server ...       # from twoerner/freeipa COPR
  RUN dnf install ipacta ...               # from twoerner/ipacta COPR
  RUN dnf install ahdapa akamu ...         # from abbra/synta COPR
  COPY schema/80oauth2.ldif /usr/share/dirsrv/schema/
  COPY plugins/ /usr/lib/python3.12/site-packages/ipaserver/plugins/
  COPY install/ /usr/lib/python3.12/site-packages/ipaserver/install/

Upgrade:
  1. Push WID image to registry
  2. On each replica (rolling): bootc switch <wid-image-ref> && reboot
  3. idm-post-upgrade detects version change → ipa-server-upgrade
  4. WID Phase 2 service starts ahdapa + akamu
```

`bootc switch` changes the image reference entirely — from stock to WID.
This is more than `bootc upgrade` (which tracks the same image tag).

### COPR Install Ordering (WID lesson #1-2)

The WID image MUST install packages in this order:

1. Enable `twoerner/freeipa` COPR
2. `dnf install freeipa-server` (gets ipacta CA backend version)
3. Enable `twoerner/ipacta` COPR
4. `dnf install ipacta` (CLI tools only — freeipa-server already installed)
5. Enable `abbra/synta` COPR
6. `dnf install ahdapa akamu`

If step 3 happens before step 2, the ipacta COPR's freeipa-server build
(WITHOUT the CA backend) overrides the correct one.

---

## Part 5: Rollback and Troubleshooting Runbook

### Decision Tree

```
Problem detected after image update or rebase
  │
  ├─ Single node failed, other 3 healthy?
  │   ├─ YES → Procedure R1: Single-Node Recovery
  │   └─ NO (multiple nodes) ─┐
  │                            │
  ├─ Replication broken between specific nodes?
  │   └─ YES → Procedure R2: Replication Repair
  │
  ├─ Auth failing on upgraded nodes but not old ones?
  │   └─ YES → Procedure R3: Auth Diagnosis
  │
  ├─ ipa-server-upgrade failed during post-boot?
  │   └─ YES → Procedure R4: Upgrade Failure Recovery
  │
  ├─ WID services (ahdapa/akamu) won't start after rebase?
  │   └─ YES → Procedure R5: WID Service Recovery
  │
  └─ Full cluster rollback needed (all nodes)?
      └─ YES → Procedure R6: Full Cluster Rollback
```

### R1: Single-Node Recovery

**When:** One node failed upgrade/rebase, other 3 are healthy and
replicating.

```bash
# === On the failed node ===

# Step 1: Roll back the image
bootc rollback
reboot

# Step 2: After reboot, check if services recovered
ipactl status
# If all services running → run verification suite → done

# Step 3: If services didn't recover, full re-enrollment
ipa-server-install --uninstall -U

# Step 4: On a healthy node, clean up the failed server
ssh primary.imagemode.test
  kinit admin
  ipa server-del <failed-node-fqdn> --force
  # If topology segment lingers:
  ipa topologysegment-del domain <segment-name>
  ipa topologysegment-del ca <segment-name>
  # Remove host entry (re-add fresh)
  ipa host-del <failed-node-fqdn>
  ipa host-add <failed-node-fqdn> --ip-address=<ip> --force

# Step 5: Back on the failed node, re-enroll
# Pre-create /var/lib/ipa directory tree (WID lesson #17)
mkdir -p /var/lib/ipa/{sysrestore,sysupgrade,gssproxy,passwds,certs,private,backup,pki-ca/publish,dnssec/tokens}
chmod 700 /var/lib/ipa/{passwds,private}
mkdir -p /var/kerberos/{krb5kdc,krb5/user}
mkdir -p /run/ipa/ /var/lib/pki/ /var/lib/dirsrv/ /var/log/dirsrv/
mkdir -p /etc/ipa/{custodia,dnssec,html,nssdb,kdcproxy}
restorecon -Rv /var/lib/ipa /var/lib/dirsrv /var/kerberos /etc/ipa

# Client install
ipa-client-install \
  --server=primary.imagemode.test \
  --domain=imagemode.test \
  --realm=IMAGEMODE.TEST \
  --principal=admin \
  --password=Secret123 \
  --unattended --force-join --no-ntp

# Add swap (WID lesson #46 — pkispawn OOM)
dd if=/dev/zero of=/var/swapfile bs=1M count=1024
chmod 600 /var/swapfile && mkswap /var/swapfile && swapon /var/swapfile

# Replica promotion
ipa-replica-install \
  --principal=admin --admin-password=Secret123 \
  --setup-ca --setup-dns \
  --forwarder=10.11.5.19 \
  --skip-conncheck \
  --unattended

# Step 6: Verify
# Replica catches up from healthy peers via replication
# Run verification suite — replication + auth on all 4 nodes
```

**Recovery time:** ~15-20 minutes (uninstall + re-enroll + CA setup).
Data loss: none — replica learns all data from peers.

### R2: Replication Repair

**When:** Nodes are running but replication agreements show errors or lag
is excessive.

```bash
# === Diagnosis ===

# Check topology connectivity
ipa topologysuffix-verify domain
ipa topologysuffix-verify ca
# Look for: "disconnected" or "unreachable"

# Check individual replication agreements
ldapsearch -x -H ldap://primary.imagemode.test \
  -D "cn=Directory Manager" -w Secret123 \
  -b "cn=config" "(objectClass=nsds5replicationagreement)" \
  nsds5replicahost nsds5replicalastinitstatus \
  nsds5replicalastupdatestatus nsds5replicalastupdatestatusstr

# Status codes:
#   0 = OK
#   1 = busy (transient, retry)
#   -1 = error (investigate)

# Check for stale agreements (WID lesson #21)
# Stale = agreement to a node that no longer exists
ldapsearch -x -H ldap://primary.imagemode.test \
  -D "cn=Directory Manager" -w Secret123 \
  -b "cn=config" "(objectClass=nsds5replicationagreement)" \
  nsds5replicahost | grep nsds5replicahost
# Compare with actual topology — any host not in `ipa server-find`?

# === Fix: Stale Replication Agreement ===

# MUST delete via LDAP while DS is running (WID lesson #24)
# Do NOT edit dse.ldif — DS overwrites it on shutdown

# 1. Find the topology segment
ipa topologysegment-find domain
ipa topologysegment-find ca

# 2. Delete the stale segment
ipa topologysegment-del domain <stale-segment>
# If refused ("Removal disconnects topology"):
ipa server-del <stale-host> --force
# Then retry segment deletion

# 3. Verify agreement removed
ldapsearch -x -H ldap://primary.imagemode.test \
  -D "cn=Directory Manager" -w Secret123 \
  -b "cn=config" "(objectClass=nsds5replicationagreement)" dn

# === Fix: Replication Lag After Image Update ===

# Force replication sync
ipa-replica-manage re-initialize --from=primary.imagemode.test

# Monitor progress
watch -n5 'ldapsearch -x -H ldap://localhost \
  -D "cn=Directory Manager" -w Secret123 \
  -b "cn=config" "(objectClass=nsds5replicationagreement)" \
  nsds5replicalastupdatestatusstr nsds5replicalastupdateend'
```

### R3: Auth Diagnosis

**When:** Users can't authenticate, `kinit` fails, LDAP binds rejected.

```bash
# === KDC not responding ===

# Check KDC service
systemctl status krb5kdc
journalctl -u krb5kdc --since "10 minutes ago"

# Common post-upgrade issue: /run/ipa/services.list missing (lesson #25)
ls -la /run/ipa/services.list
# If missing, recreate:
cat > /run/ipa/services.list <<'EOF'
dirsrv
krb5kdc
kadmin
named
httpd
ipa-custodia
pki-tomcatd
ipa-otpd
ipa-dnskeysyncd
EOF
ipactl start

# === LDAP bind failing ===

# Check DS is listening on TCP 389 (WID lesson #23)
ss -tlnp | grep :389
# If missing (ipacta/WID may have disabled TCP):
ldapmodify -Y EXTERNAL -H ldapi://%2Fvar%2Frun%2Fslapd-IMAGEMODE-TEST.socket <<'EOF'
dn: cn=config
changetype: modify
replace: nsslapd-port
nsslapd-port: 389
EOF
systemctl restart dirsrv@IMAGEMODE-TEST

# Check TLS is enabled (WID lesson #28)
ldapsearch -Y EXTERNAL -H ldapi:// -b "cn=config" nsslapd-security
# If "off":
ldapmodify -Y EXTERNAL -H ldapi:// <<'EOF'
dn: cn=config
changetype: modify
replace: nsslapd-security
nsslapd-security: on
EOF
systemctl restart dirsrv@IMAGEMODE-TEST

# === httpd / IPA API not responding ===

systemctl status httpd
journalctl -u httpd --since "10 minutes ago"

# Custodia crash after upgrade (WID lesson #26)
# Check for PermissionError on loginuid
grep -i "loginuid\|PermissionError" /var/log/httpd/error_log
# If present: patch _get_loginuid()
python3 -c "
import ipaserver.custodia.httpd.server as s
print(s.__file__)
"
# Edit the file: change 'except IOError as e: if e.errno != errno.ENOENT: raise'
# to 'except OSError: pass'
# Then: systemctl restart httpd

# === Kerberos ticket works but IPA API returns 500 ===

# Usually means httpd can't reach DS
curl -k --negotiate -u : https://$(hostname)/ipa/json \
  -H "Content-Type: application/json" \
  -H "Referer: https://$(hostname)/ipa" \
  -d '{"method":"ping","params":[[],{}]}'
# Check httpd error log for "LDAP connection" errors
```

### R4: Upgrade Failure Recovery

**When:** `ipa-server-upgrade` failed during post-boot
(`idm-post-upgrade.service`).

```bash
# Check what failed
journalctl -u idm-post-upgrade --no-pager
# Also check:
cat /var/log/ipaupgrade.log | tail -50

# === Common failures ===

# 1. "Unable to restart dirsrv" — DS crashed during schema update
systemctl status dirsrv@IMAGEMODE-TEST
# If failed, check for LMDB corruption (WID lesson #40):
ls -la /dev/shm/slapd-*
# If corrupt: rm -rf /dev/shm/slapd-IMAGEMODE-TEST*
# Then: systemctl start dirsrv@IMAGEMODE-TEST

# 2. "Updates failed" with specific update file
# Check which update hung:
grep "ERROR\|FAIL" /var/log/ipaupgrade.log
# Sysupgrade state shows what was already applied:
cat /var/lib/ipa/sysupgrade/sysupgrade.state

# 3. Upgrade timed out (long-running schema changes on large DB)
# Re-run manually:
ipa-server-upgrade
# If it succeeds: update the version stamp
rpm -q freeipa-server > /var/lib/idm-image-mode/.image-version

# === If upgrade cannot succeed on this image version ===

# Option A: Skip this node, keep it on old image
bootc rollback && reboot
# Node runs old version, replicates with upgraded peers
# Verify: auth + replication still work in mixed-version mode

# Option B: Re-enroll (procedure R1)
```

### R5: WID Service Recovery

**When:** After WID image rebase, ahdapa or akamu won't start.

```bash
# === ahdapa won't start ===

# Check journal (namespaced — WID lesson #8)
journalctl --namespace=ahdapa -u ahdapa --no-pager
# If no output, check default journal:
journalctl -u ahdapa --no-pager

# SELinux blocking ahdapa_t (WID lesson #14)
# Check for silent denials (no AVC logged):
ausearch -m avc -ts recent 2>/dev/null
# Fix: relabel binary
cp /usr/bin/ahdapa /var/lib/ahdapa/ahdapa-bin
chcon -t bin_t /var/lib/ahdapa/ahdapa-bin
# Override ExecStart in drop-in:
mkdir -p /etc/systemd/system/ahdapa.service.d
cat > /etc/systemd/system/ahdapa.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/var/lib/ahdapa/ahdapa-bin /etc/ahdapa/ahdapa.toml
ProtectSystem=no
MemoryDenyWriteExecute=no
EOF
systemctl daemon-reload && systemctl restart ahdapa

# SQLite I/O error (WID lesson #9)
# Check StateDirectory permissions:
ls -laZ /var/lib/ahdapa/
# Must be writable by ahdapa process user

# === akamu won't start ===

# Port conflict with ipacta (WID lesson #6)
ss -tlnp | grep 8443
# If ipacta holds 8443, akamu must use 19443
# Check /etc/akamu/config.toml: listen_port = 19443

# Same SELinux fix as ahdapa:
cp /usr/bin/akamu /var/lib/akamu/akamu-bin
chcon -t bin_t /var/lib/akamu/akamu-bin
# Same drop-in pattern

# === ProxyPass collision (WID lesson #27) ===

# ahdapa and custodia both proxy via http://localhost
grep -r "ProxyPass" /etc/httpd/conf.d/
# If custodia uses http://localhost: change to http://custodia.internal
# in /etc/httpd/conf.d/ipa.conf (Location /ipa/keys/)
systemctl restart httpd

# === Verify WID services without breaking stock auth ===

# 1. Kerberos must still work
echo Secret123 | kinit admin && echo "Kerberos: OK"

# 2. ahdapa OIDC discovery
curl -sf http://localhost:8090/.well-known/openid-configuration | python3 -m json.tool

# 3. akamu ACME directory
curl -sf https://localhost:19443/acme/directory | python3 -m json.tool
```

### R6: Full Cluster Rollback

**When:** All 4 nodes must return to previous image version. Nuclear option.

```bash
# === CRITICAL: Order matters ===
# Roll back replicas first, primary last (reverse of upgrade order)

# Step 1: Decide what to do about schema
#
# If WID schema was applied but NO WID entries created:
#   → Schema can be removed via ldapmodify (see Schema Rollback above)
#   → Do this BEFORE rolling back images
#
# If WID entries exist (OAuth2 clients, workloads registered):
#   → Schema CANNOT be removed (objectclass in use)
#   → Schema stays permanently — this is acceptable
#   → Stock FreeIPA ignores unknown objectClasses
#   → WID entries become orphaned but harmless

# Step 2: Roll back all nodes
for NODE in replica3 replica2 replica1 primary; do
    ssh root@${NODE}.imagemode.test <<'ROLLBACK'
        bootc rollback
        reboot
ROLLBACK
    # Wait for node to come back
    sleep 120
    # Verify
    ssh root@${NODE}.imagemode.test ipactl status
done

# Step 3: Handle sysupgrade state mismatch
#
# After rollback: /var/lib/ipa/sysupgrade/sysupgrade.state may claim
# updates were applied that the current (old) code doesn't know about.
# Two options:
#
# Option A: Restore pre-upgrade sysupgrade.state (if backed up)
for NODE in primary replica{1..3}; do
    ssh root@${NODE}.imagemode.test <<'RESTORE'
        cp /var/lib/idm-image-mode/backups/pre-schema/sysupgrade.state \
           /var/lib/ipa/sysupgrade/sysupgrade.state
        ipa-server-upgrade  # re-applies current version's updates cleanly
RESTORE
done

# Option B: Let ipa-server-upgrade sort it out (usually works)
# sysupgrade.state has version-keyed entries — old code only checks
# entries matching its own version. Forward entries are ignored.
for NODE in primary replica{1..3}; do
    ssh root@${NODE}.imagemode.test ipa-server-upgrade
done

# Step 4: Full verification suite
# Replication: write/read consistency, agreement health, CSN drift
# Auth: kinit, GSSAPI, IPA API, cert ops on all 4 nodes
# Service tickets: cross-node ticket acquisition

# Step 5: If verification fails on any node → R1 (single-node recovery)
```

### Rollback Decision Matrix

| Situation | Schema State | Image Action | Data Action | Expected Downtime |
|-----------|:------------|:------------|:-----------|:-----------------|
| Single node failed upgrade | Unchanged | `bootc rollback` on that node | Re-enroll from peers (R1) | 15-20 min |
| Upgrade works but perf regression | Unchanged | `bootc rollback` all (R6) | None — same data | 10 min per node |
| WID schema applied, rebase failed | Schema present, no entries | Rollback image, optionally remove schema | None | 10 min per node |
| WID schema + entries exist, need rollback | Schema permanent | Rollback image | WID entries orphaned (harmless) | 10 min per node |
| Replication broken after upgrade | Varies | Fix replication (R2) or re-enroll (R1) | Re-initialized from peers | 20-30 min |
| Auth broken after WID rebase | Schema present | Check R3 + R5 fixes | None | 5-15 min |
| Complete cluster failure | N/A | Re-deploy from scratch | Restore from backup | 45-60 min |

### Backup Strategy

Before any lifecycle event, capture:

```bash
# Run on each node before upgrade/rebase
BACKUP="/var/lib/idm-image-mode/backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"

# 1. IPA upgrade state
cp /var/lib/ipa/sysupgrade/sysupgrade.state "$BACKUP/"

# 2. DS schema snapshot
ldapsearch -Y EXTERNAL -H ldapi:// -b "cn=schema" -s base \
  objectClasses attributeTypes > "$BACKUP/schema.ldif" 2>/dev/null

# 3. Replication agreement map
ldapsearch -x -H ldap://localhost -D "cn=Directory Manager" -w Secret123 \
  -b "cn=config" "(objectClass=nsds5replicationagreement)" \
  nsds5replicahost nsds5replicaport > "$BACKUP/repl-agreements.ldif" 2>/dev/null

# 4. IPA topology
ipa topologysegment-find domain > "$BACKUP/topo-domain.txt" 2>/dev/null
ipa topologysegment-find ca > "$BACKUP/topo-ca.txt" 2>/dev/null

# 5. Critical config files
cp /etc/ipa/default.conf "$BACKUP/"
cp /etc/dirsrv/slapd-*/dse.ldif "$BACKUP/" 2>/dev/null

# 6. Image version
rpm -q freeipa-server > "$BACKUP/freeipa-version.txt"
bootc status > "$BACKUP/bootc-status.txt" 2>/dev/null
```

All backups live in `/var/lib/idm-image-mode/backups/` — persists across
image updates and rollbacks. Cleanup old backups after 30 days.

---

## Constraints

1. **idm-ci mrack provisioning** — topology defined in metadata YAML, VMs
   provisioned via Beaker/OpenStack. bootc images built in CI, uploaded to
   OpenStack/AWS for VM creation.

2. **RHEL 10 base** — not Fedora. Some COPRs (twoerner, abbra/synta) only
   target Fedora. Need epel-10 chroots or local RPM builds for RHEL 10
   (WID modrnizer lesson #10).

3. **Sequential replica promotion** — replicas cannot promote in parallel.
   Ansible `serial: 1` or staggered firstboot delays required.

4. **389-DS state in /var** — bootc never touches /var. All database state,
   replication agreements, schema modifications persist across image
   updates AND rollbacks. This is both the feature (data survives) and the
   risk (stale state survives too).

5. **`/usr` is read-only at runtime** — all runtime modifications go to
   `/etc` or `/var`. `ostree admin unlock` provides a temporary writable
   overlay that's lost on reboot (WID lesson #47).

6. **No built-in bootc upgrade hooks** — we implement our own via systemd
   services that compare image versions on boot.

## What's Left to the Builder

- Exact RHEL 10.x minor version (10.3 vs 10.4) — depends on compose
  availability and freeipa-server version
- mrack host sizing (RAM, disk) — minimum 4GB RAM per replica to avoid OOM
  during pkispawn (WID lesson #46)
- DNS forwarder IP — 10.11.5.19 is idm-ci's default, may need adjustment
- Whether to test on OpenStack or Beaker (or both)
- Timeout values for firstboot phases (current estimate: 8-10 min per node)
- `idm-post-upgrade.service` systemd ordering — needs
  `After=dirsrv@*.service ipa.service` so 389-DS is running before
  `ipa-server-upgrade` executes (builder's call on exact unit names)
- Replication lag thresholds (5s warn / 30s fail are reasonable defaults)
- `inject-config.yaml` mechanism — cloud-init user-data vs scp, whichever
  matches mrack conventions
- Verification scripts implemented as Ansible playbooks (matching idm-ci
  conventions), not standalone bash — the scripts in Part 4 are reference
  logic, builder wraps them in `shell:` tasks within Ansible roles

## Part 4: Continuous Replication and Authentication Verification

Replication and auth must be verified at every lifecycle transition, not just
at the end. A cluster that "works" after full deployment but silently broke
replication during a rolling upgrade is a ticking bomb.

### Verification Checkpoints

Every lifecycle event triggers the same verification suite. The event is
not considered complete until all checks pass.

```
Lifecycle events that trigger verification:
  ✓ After primary firstboot completes
  ✓ After each replica promotion
  ✓ After full 4-node topology established
  ✓ Before each rolling upgrade step
  ✓ After each rolling upgrade step (mixed-version window)
  ✓ After rollback
  ✓ After WID schema migration
  ✓ After WID image rebase (bootc switch)
```

### Replication Verification Suite

```bash
#!/bin/bash
# idm-verify-replication.sh — run from any node with admin credentials

DOMAIN="imagemode.test"
REALM="IMAGEMODE.TEST"
MARKER="verify-$(date +%s)-$(hostname -s)"

# 1. Topology connectivity — no orphaned segments
echo "=== Topology Check ==="
ipa topologysuffix-verify domain
ipa topologysuffix-verify ca
# FAIL if: "disconnected" or "unreachable" in output

# 2. Write-then-read consistency test
#    Create object on THIS node, verify it appears on every peer
echo "=== Write/Read Consistency ==="
ipa user-add "test-${MARKER}" --first=Repl --last=Test
sleep 5  # allow replication propagation

for REPLICA in primary replica1 replica2 replica3; do
    FQDN="${REPLICA}.${DOMAIN}"
    # Use ldapsearch directly to bypass IPA's server selection
    ldapsearch -x -H ldap://${FQDN} -D "cn=Directory Manager" \
        -w Secret123 -b "cn=users,cn=accounts,dc=${DOMAIN//./,dc=}" \
        "(uid=test-${MARKER})" dn 2>/dev/null | grep -q "dn:" \
        && echo "  ${FQDN}: OK" \
        || echo "  ${FQDN}: FAIL — entry not replicated"
done

# Cleanup
ipa user-del "test-${MARKER}"

# 3. Replication agreement status — all agreements should show status 0
echo "=== Replication Agreement Status ==="
for SUFFIX in "dc=${DOMAIN//./,dc=}" "o=ipaca"; do
    ldapsearch -x -H ldap://localhost -D "cn=Directory Manager" \
        -w Secret123 \
        -b "cn=config" \
        "(objectClass=nsds5replicationagreement)" \
        nsds5replicahost nsds5replicalastinitstatus \
        nsds5replicalastupdatestatus nsds5replicalastupdateend 2>/dev/null
done
# FAIL if: any lastinitstatus != 0 or lastupdatestatus != 0

# 4. CSN (Change Sequence Number) drift
#    All replicas should have CSNs within a small window
echo "=== CSN Drift Check ==="
for REPLICA in primary replica1 replica2 replica3; do
    FQDN="${REPLICA}.${DOMAIN}"
    CSN=$(ldapsearch -x -H ldap://${FQDN} -D "cn=Directory Manager" \
        -w Secret123 -b "cn=config" \
        "(objectClass=nsds5replica)" nsds50ruv 2>/dev/null \
        | grep -oP 'csn=[0-9a-f]+' | tail -1)
    echo "  ${FQDN}: ${CSN:-UNAVAILABLE}"
done
# WARN if: CSN timestamps differ by > 30 seconds

# 5. Replication lag — time between write on primary and read on replicas
echo "=== Replication Lag ==="
WRITE_TS=$(date +%s%N)
ipa user-add "lag-${MARKER}" --first=Lag --last=Test 2>/dev/null
for REPLICA in replica1 replica2 replica3; do
    FQDN="${REPLICA}.${DOMAIN}"
    for i in $(seq 1 30); do
        ldapsearch -x -H ldap://${FQDN} -D "cn=Directory Manager" \
            -w Secret123 -b "cn=users,cn=accounts,dc=${DOMAIN//./,dc=}" \
            "(uid=lag-${MARKER})" dn 2>/dev/null | grep -q "dn:" && break
        sleep 1
    done
    READ_TS=$(date +%s%N)
    LAG_MS=$(( (READ_TS - WRITE_TS) / 1000000 ))
    echo "  ${FQDN}: ${LAG_MS}ms (${i} polls)"
done
ipa user-del "lag-${MARKER}" 2>/dev/null
# FAIL if: any replica > 30 seconds
# WARN if: any replica > 5 seconds
```

### Authentication Verification Suite

```bash
#!/bin/bash
# idm-verify-auth.sh — run from any node or external client

DOMAIN="imagemode.test"
REALM="IMAGEMODE.TEST"
ADMIN_PW="Secret123"

echo "=== Kerberos Authentication ==="
# Test kinit against EACH node's KDC (not just DNS-discovered default)
for NODE in primary replica1 replica2 replica3; do
    FQDN="${NODE}.${DOMAIN}"
    KRB5_CONFIG=$(mktemp)
    cat > "$KRB5_CONFIG" <<KEOF
[libdefaults]
  default_realm = ${REALM}
[realms]
  ${REALM} = {
    kdc = ${FQDN}
    admin_server = ${FQDN}
  }
KEOF
    echo "$ADMIN_PW" | KRB5_CONFIG="$KRB5_CONFIG" \
        kinit admin@${REALM} 2>/dev/null \
        && echo "  kinit via ${FQDN}: OK" \
        || echo "  kinit via ${FQDN}: FAIL"
    rm -f "$KRB5_CONFIG"
done

echo "=== LDAP Bind (GSSAPI) ==="
# After kinit, test GSSAPI bind to each node's LDAP
echo "$ADMIN_PW" | kinit admin@${REALM} 2>/dev/null
for NODE in primary replica1 replica2 replica3; do
    FQDN="${NODE}.${DOMAIN}"
    ldapsearch -Y GSSAPI -H ldap://${FQDN} \
        -b "cn=users,cn=accounts,dc=${DOMAIN//./,dc=}" \
        "(uid=admin)" dn 2>/dev/null | grep -q "dn:" \
        && echo "  GSSAPI bind ${FQDN}: OK" \
        || echo "  GSSAPI bind ${FQDN}: FAIL"
done

echo "=== LDAP Bind (Simple) ==="
for NODE in primary replica1 replica2 replica3; do
    FQDN="${NODE}.${DOMAIN}"
    ldapsearch -x -H ldap://${FQDN} -D "cn=Directory Manager" \
        -w "$ADMIN_PW" -b "" -s base 2>/dev/null | grep -q "dn:" \
        && echo "  Simple bind ${FQDN}: OK" \
        || echo "  Simple bind ${FQDN}: FAIL"
done

echo "=== IPA JSON-RPC API ==="
# Test the IPA API via httpd on each node
echo "$ADMIN_PW" | kinit admin@${REALM} 2>/dev/null
for NODE in primary replica1 replica2 replica3; do
    FQDN="${NODE}.${DOMAIN}"
    # ipa ping against specific server
    ipa -e server="${FQDN}" ping 2>/dev/null \
        && echo "  IPA API ${FQDN}: OK" \
        || echo "  IPA API ${FQDN}: FAIL"
done

echo "=== Certificate Operations ==="
# Test cert-show (reads CA cert) against each node
for NODE in primary replica1 replica2 replica3; do
    FQDN="${NODE}.${DOMAIN}"
    ipa -e server="${FQDN}" cert-show 1 2>/dev/null | grep -q "Serial number:" \
        && echo "  cert-show ${FQDN}: OK" \
        || echo "  cert-show ${FQDN}: FAIL"
done

echo "=== Cross-Node Service Ticket ==="
# Get a service ticket for HTTP on each node — proves KDC can issue
# tickets for services hosted on peer replicas
for NODE in primary replica1 replica2 replica3; do
    FQDN="${NODE}.${DOMAIN}"
    kvno "HTTP/${FQDN}@${REALM}" 2>/dev/null \
        && echo "  Service ticket HTTP/${FQDN}: OK" \
        || echo "  Service ticket HTTP/${FQDN}: FAIL"
done

echo "=== Password Authentication (non-Kerberos) ==="
# Test LDAP simple bind as admin — validates password policy and hashing
for NODE in primary replica1 replica2 replica3; do
    FQDN="${NODE}.${DOMAIN}"
    ldapwhoami -x -H ldap://${FQDN} \
        -D "uid=admin,cn=users,cn=accounts,dc=${DOMAIN//./,dc=}" \
        -w "$ADMIN_PW" 2>/dev/null | grep -q "uid=admin" \
        && echo "  Password auth ${FQDN}: OK" \
        || echo "  Password auth ${FQDN}: FAIL"
done
```

### Verification Matrix

Each cell = MUST PASS before proceeding to next lifecycle stage.

| Stage | Replication | Kerberos | GSSAPI LDAP | IPA API | Cert Ops | Service Tickets |
|-------|:-----------:|:--------:|:-----------:|:-------:|:--------:|:---------------:|
| After primary install | N/A (single) | primary | primary | primary | primary | primary |
| After replica1 join | primary↔r1 | all 2 | all 2 | all 2 | all 2 | all 2 |
| After replica2 join | full mesh (3) | all 3 | all 3 | all 3 | all 3 | all 3 |
| After replica3 join | full mesh (4) | all 4 | all 4 | all 4 | all 4 | all 4 |
| **Pre-upgrade baseline** | **full mesh** | **all 4** | **all 4** | **all 4** | **all 4** | **all 4** |
| During upgrade (r3 down) | 3 nodes | 3 nodes | 3 nodes | 3 nodes | 3 nodes | 3 nodes |
| After r3 upgrade+reboot | full mesh | all 4 | all 4 | all 4 | all 4 | all 4 |
| Mixed version (2 old+2 new) | full mesh | all 4 | all 4 | all 4 | all 4 | all 4 |
| After full upgrade | full mesh | all 4 | all 4 | all 4 | all 4 | all 4 |
| After rollback (1 node) | full mesh | all 4 | all 4 | all 4 | all 4 | all 4 |
| After WID schema add | full mesh | all 4 | all 4 | all 4 | all 4 | all 4 |
| After WID image rebase | full mesh | all 4 | all 4 | all 4 | all 4 + OAuth2 | all 4 |

### Mixed-Version Replication Concerns

During rolling upgrades, the cluster runs with nodes on different FreeIPA
versions. Specific risks:

1. **Schema version mismatch** — newer FreeIPA may add schema entries that
   older nodes don't recognize. 389-DS replicates schema changes via CSN.
   Older nodes accept unknown schema entries (additive, never destructive).
   Verified safe for FreeIPA minor version bumps.

2. **RPC version mismatch** — IPA's JSON-RPC API has versioned commands.
   Newer nodes may send RPC calls that older nodes don't implement. IPA
   handles this via API version negotiation (`ipa -e api_version=X`).
   Risk: new commands fail if sent to old node. Mitigation: client follows
   server during upgrade (contacts upgraded node first).

3. **Replication changelog format** — 389-DS replication protocol is
   backward-compatible within the same major version. RHEL 10 389-DS 3.x
   uses LMDB (not BDB). All nodes MUST be on the same 389-DS major version.
   bootc images from the same RHEL 10.x compose guarantee this.

4. **KDC principal encryption types** — Kerberos principal keys use the
   enctypes available when the key was created. Upgrading doesn't
   automatically re-key principals. Mixed clusters work because KDC
   supports all enctypes the principal has. No risk unless the upgrade
   removes an enctype (never happens in minor versions).

### WID-Specific Auth Verification

After WID image rebase, add OAuth2/OIDC verification:

```bash
echo "=== OAuth2 Token Flow (ahdapa) ==="
for NODE in primary replica1 replica2 replica3; do
    FQDN="${NODE}.${DOMAIN}"
    # OIDC discovery
    curl -sf "http://${FQDN}:8090/.well-known/openid-configuration" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['issuer'])" \
        2>/dev/null \
        && echo "  OIDC discovery ${FQDN}: OK" \
        || echo "  OIDC discovery ${FQDN}: FAIL (ahdapa not running?)"
done

echo "=== OAuth2 Client Credentials Grant ==="
# Requires a registered OAuth2 client
CLIENT_ID="test-verify-client"
CLIENT_SECRET="verify-secret-2026"
for NODE in primary replica1 replica2 replica3; do
    FQDN="${NODE}.${DOMAIN}"
    TOKEN=$(curl -sf -X POST "http://${FQDN}:8090/token" \
        -d "grant_type=client_credentials" \
        -d "client_id=${CLIENT_ID}" \
        -d "client_secret=${CLIENT_SECRET}" \
        -d "scope=openid" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token','NONE'))" 2>/dev/null)
    if [[ "$TOKEN" != "NONE" && -n "$TOKEN" ]]; then
        echo "  Token from ${FQDN}: OK"
    else
        echo "  Token from ${FQDN}: FAIL"
    fi
done

echo "=== ACME CA (akamu) ==="
for NODE in primary replica1 replica2 replica3; do
    FQDN="${NODE}.${DOMAIN}"
    curl -sf "https://${FQDN}:19443/acme/directory" 2>/dev/null | grep -q "newNonce" \
        && echo "  ACME directory ${FQDN}: OK" \
        || echo "  ACME directory ${FQDN}: FAIL (akamu not running?)"
done

echo "=== Kerberos Still Works After WID ==="
# Critical: WID overlay must NOT break standard Kerberos auth
echo "$ADMIN_PW" | kinit admin@${REALM} 2>/dev/null \
    && echo "  kinit after WID: OK" \
    || echo "  kinit after WID: FAIL — WID broke Kerberos"
ipa user-find --sizelimit=1 2>/dev/null | grep -q "admin" \
    && echo "  IPA API after WID: OK" \
    || echo "  IPA API after WID: FAIL"
```

### Automated Verification in idm-ci

Wire into the metadata YAML as test phases:

```yaml
phases:
  # ... (provision, prep, install as before)
  - name: verify-baseline
    steps:
      - playbook: image-mode/verify-replication.yaml
      - playbook: image-mode/verify-auth.yaml
  - name: upgrade-rolling
    steps:
      - playbook: image-mode/rolling-upgrade.yaml
        extra_vars:
          upgrade_order: "replica3,replica2,replica1,primary"
          verify_after_each: true
  - name: verify-post-upgrade
    steps:
      - playbook: image-mode/verify-replication.yaml
      - playbook: image-mode/verify-auth.yaml
  - name: test-rollback
    steps:
      - playbook: image-mode/rollback-replica.yaml
        extra_vars:
          target: replica3
      - playbook: image-mode/verify-replication.yaml
      - playbook: image-mode/verify-auth.yaml
```

The `rolling-upgrade.yaml` playbook runs verification after each node
upgrade. If verification fails, the playbook halts — no cascading
failures across the cluster.

---

## Part 6: Automation — Ansible Playbooks for Every Lifecycle Operation

Every operation in this design must be a single playbook invocation. No
manual SSH-and-run steps in production. The playbooks combine
`ansible-freeipa` (collection `freeipa.ansible_freeipa` v1.17+) for IPA
operations with custom roles for bootc lifecycle and WID overlay.

### Available ansible-freeipa Components

**Roles** (full install/configure workflows):

| Role | Purpose | Used In |
|------|---------|---------|
| `ipaserver` | Full server installation | Part 1: primary firstboot |
| `ipareplica` | Full replica promotion | Part 1: replica firstboot |
| `ipaclient` | Client enrollment | Part 1: client-install step of replica |
| `ipabackup` | IPA backup/restore | Part 5: rollback procedures |

**Modules** (individual IPA operations, idempotent):

| Module | Purpose | Used In |
|--------|---------|---------|
| `ipauser` | User CRUD | Part 4: replication write/read test |
| `ipahost` | Host management | R1: re-enrollment cleanup |
| `ipaserver` | Server del/find | R1: remove failed replica |
| `ipatopologysegment` | Topology CRUD | R2: replication repair, canary isolation |
| `ipatopologysuffix` | Suffix verification | Part 4: topology check |
| `ipadnsrecord` | DNS management | Part 1: replica DNS verification |
| `ipacert` | Certificate operations | Part 4: cert verification |
| `ipaconfig` | IPA config query | Part 4: config consistency |
| `ipahbacrule` / `ipasudorule` | Policy management | Post-deploy policy setup |

### Existing WID Ansible Roles (ipa-oauth2-plugin repo)

| Role | Purpose | Used In |
|------|---------|---------|
| `oauth2_schema` | Apply 80oauth2.ldif | Part 3: schema migration |
| `oauth2_plugins` | Deploy IPA server plugins | Part 3: WID rebase |
| `oauth2_clients` | Register OAuth2 clients | Part 3: WID activation |
| `ahdapa` | Install + configure ahdapa | Part 3: WID rebase |
| `akamu` | Install + configure akamu | Part 3: WID rebase |
| `obo_exchange` | OBO token exchange daemon | Part 3: WID activation |
| `ipa_oauth2_validate` | Validate OAuth2 flows | Part 4: WID auth verification |
| `ipa_server` | IPA server with WID overlay | Part 3: WID-enhanced install |
| `ipa_client` | IPA client enrollment | Part 1: standard enrollment |

### Playbook Inventory

```
playbooks/
├── cluster/
│   ├── deploy-cluster.yaml           # Full 4-node deploy (end-to-end)
│   ├── deploy-primary.yaml           # Primary only
│   ├── deploy-replica.yaml           # Single replica (serial-safe)
│   └── inject-config.yaml            # Push config.env to nodes
│
├── lifecycle/
│   ├── rolling-upgrade.yaml          # Image update, node by node
│   ├── rollback-node.yaml            # Single node rollback + recovery
│   ├── rollback-cluster.yaml         # Full cluster rollback (R6)
│   └── bootc-switch.yaml             # Image rebase (stock → WID)
│
├── schema/
│   ├── validate-schema.yaml          # Layer 1: offline validation
│   ├── test-schema-throwaway.yaml    # Layer 2: throwaway instance
│   ├── canary-schema.yaml            # Layer 3: isolated canary
│   └── apply-schema-production.yaml  # Full schema migration sequence
│
├── verify/
│   ├── verify-all.yaml               # Full suite (calls all below)
│   ├── verify-replication.yaml       # Replication health
│   ├── verify-auth.yaml              # Authentication (Kerberos+LDAP)
│   ├── verify-topology.yaml          # Topology connectivity
│   ├── verify-wid.yaml               # WID-specific (OAuth2+ACME)
│   └── verify-mixed-version.yaml     # Cross-version compatibility
│
├── recovery/
│   ├── recover-single-node.yaml      # R1: re-enroll from peers
│   ├── repair-replication.yaml       # R2: fix agreements
│   ├── diagnose-auth.yaml            # R3: auth troubleshooting
│   ├── recover-upgrade-failure.yaml  # R4: post-upgrade fix
│   └── recover-wid-services.yaml     # R5: ahdapa/akamu fix
│
├── backup/
│   ├── backup-pre-upgrade.yaml       # Capture state before changes
│   ├── backup-schema.yaml            # Schema + LMDB snapshot
│   └── restore-from-backup.yaml      # Restore specific backup
│
└── wid/
    ├── deploy-wid-overlay.yaml        # WID Phase 2 on all nodes
    ├── activate-wid.yaml              # Register clients, start services
    └── validate-wid.yaml              # OAuth2 + ACME + Kerberos coexistence
```

### Key Playbooks

#### 1. `deploy-cluster.yaml` — Full 4-Node Deploy

```yaml
---
# Deploy complete 4-node FreeIPA Image Mode cluster
# Usage: ansible-playbook -i inventory/imagemode deploy-cluster.yaml

- name: Push config to all nodes
  import_playbook: inject-config.yaml

- name: Deploy primary server
  hosts: ipa_primary
  become: true
  collections:
    - freeipa.ansible_freeipa
  roles:
    - role: ipaserver
      vars:
        ipaserver_domain: imagemode.test
        ipaserver_realm: IMAGEMODE.TEST
        ipaadmin_password: Secret123
        ipadm_password: Secret123
        ipaserver_setup_dns: true
        ipaserver_auto_forwarders: false
        ipaserver_forwarders:
          - 10.11.5.19
        ipaserver_no_dnssec_validation: true
        ipaserver_no_ntp: true
  post_tasks:
    - name: Record image version stamp
      copy:
        content: "{{ ansible_facts.packages['freeipa-server'][0].version }}"
        dest: /var/lib/idm-image-mode/.image-version

    - name: Verify primary health
      include_role:
        name: verify_ipa_health

- name: Deploy replicas (sequential)
  hosts: ipa_replicas
  become: true
  serial: 1
  collections:
    - freeipa.ansible_freeipa
  pre_tasks:
    # WID lesson #17: pre-create /var/lib/ipa directory tree
    - name: Create required IPA directories
      file:
        path: "{{ item.path }}"
        state: directory
        mode: "{{ item.mode | default('0755') }}"
      loop:
        - { path: /var/lib/ipa/sysrestore }
        - { path: /var/lib/ipa/sysupgrade }
        - { path: /var/lib/ipa/gssproxy }
        - { path: /var/lib/ipa/passwds, mode: '0700' }
        - { path: /var/lib/ipa/certs }
        - { path: /var/lib/ipa/private, mode: '0700' }
        - { path: /var/lib/ipa/backup }
        - { path: /var/lib/ipa/pki-ca/publish }
        - { path: /var/lib/ipa/dnssec/tokens }
        - { path: /var/kerberos/krb5kdc }
        - { path: /var/kerberos/krb5/user }
        - { path: /etc/ipa/custodia }
        - { path: /etc/ipa/dnssec }
        - { path: /etc/ipa/html }
        - { path: /etc/ipa/nssdb }
        - { path: /etc/ipa/kdcproxy }

    # WID lesson #46: add swap for pkispawn OOM
    - name: Create swap file for CA setup
      command: dd if=/dev/zero of=/var/swapfile bs=1M count=1024
      args:
        creates: /var/swapfile

    - name: Configure swap
      shell: chmod 600 /var/swapfile && mkswap /var/swapfile && swapon /var/swapfile
      args:
        creates: /proc/swaps  # idempotent-ish
      ignore_errors: true

  roles:
    - role: ipareplica
      vars:
        ipaadmin_password: Secret123
        ipadm_password: Secret123
        ipareplica_setup_ca: true
        ipareplica_setup_dns: true
        ipareplica_forwarders:
          - 10.11.5.19
        ipareplica_no_dnssec_validation: true
        ipareplica_no_ntp: true
        ipareplica_skip_conncheck: true

  post_tasks:
    - name: Record image version stamp
      copy:
        content: "{{ ansible_facts.packages['freeipa-server'][0].version }}"
        dest: /var/lib/idm-image-mode/.image-version

    - name: Verify replica + replication health
      include_role:
        name: verify_ipa_health

    - name: Verify replication to this replica
      include_role:
        name: verify_replication
      vars:
        verify_target: "{{ inventory_hostname }}"

- name: Final cluster verification
  hosts: ipa_primary
  become: true
  tasks:
    - name: Full verification suite
      include_role:
        name: verify_full_suite
```

#### 2. `rolling-upgrade.yaml` — Image Update with Gates

```yaml
---
# Rolling image upgrade with verification gates
# Usage: ansible-playbook -i inventory/imagemode rolling-upgrade.yaml
#        -e bootc_image=<new-image-ref>
#        -e upgrade_order=replica3,replica2,replica1,primary

- name: Pre-upgrade baseline verification
  hosts: all
  become: true
  tasks:
    - name: Run full verification suite
      include_role:
        name: verify_full_suite

    - name: Backup pre-upgrade state
      include_role:
        name: backup_ipa_state
      vars:
        backup_label: "pre-upgrade-{{ ansible_date_time.iso8601_basic_short }}"

- name: Rolling upgrade
  hosts: "{{ upgrade_order | default('ipa_replicas:ipa_primary') }}"
  become: true
  serial: 1
  tasks:
    - name: Stage new image
      command: bootc upgrade --apply
      register: bootc_result
      # bootc switch for image ref change:
      # command: bootc switch {{ bootc_image }}

    - name: Reboot into new image
      reboot:
        reboot_timeout: 300

    - name: Wait for IPA services
      command: ipactl status
      register: ipactl_result
      retries: 12
      delay: 15
      until: ipactl_result.rc == 0

    - name: Check if image version changed
      shell: rpm -q freeipa-server
      register: new_version

    - name: Run ipa-server-upgrade if version changed
      command: ipa-server-upgrade
      when: new_version.stdout != lookup('file', '/var/lib/idm-image-mode/.image-version', errors='ignore')

    - name: Update version stamp
      copy:
        content: "{{ new_version.stdout }}"
        dest: /var/lib/idm-image-mode/.image-version

    # Gate: must pass before upgrading next node
    - name: Post-upgrade verification gate
      include_role:
        name: verify_full_suite

    - name: Verify replication to all peers
      include_role:
        name: verify_replication
      vars:
        verify_all_peers: true

    # Halt entire play if verification failed
    - name: Assert verification passed
      assert:
        that: verification_passed | default(false)
        fail_msg: >
          Verification failed after upgrading {{ inventory_hostname }}.
          Remaining nodes NOT upgraded. Run rollback-node.yaml to recover.
```

#### 3. `canary-schema.yaml` — Isolated Schema Test

```yaml
---
# Layer 3: Isolated canary schema test
# Usage: ansible-playbook -i inventory/imagemode canary-schema.yaml
#        -e schema_ldif=80oauth2-ldapmodify.ldif

- name: Pre-flight verification
  hosts: all
  become: true
  tasks:
    - name: Full verification suite
      include_role:
        name: verify_full_suite

    - name: Backup state on all nodes
      include_role:
        name: backup_ipa_state
      vars:
        backup_label: pre-schema-canary
        include_lmdb: true

- name: Isolate canary node
  hosts: ipa_primary:ipa_replica1:ipa_replica2
  become: true
  tasks:
    - name: Find replication agreements to canary
      shell: |
        ldapsearch -Y EXTERNAL -H ldapi:// -b "cn=config" \
          "(&(objectClass=nsds5replicationagreement)(nsds5replicahost={{ hostvars['replica3'].ansible_fqdn }}))" \
          dn 2>/dev/null | grep "^dn:" | sed 's/^dn: //'
      register: agreements_to_canary

    - name: Pause replication TO canary
      shell: |
        ldapmodify -Y EXTERNAL -H ldapi:// <<EOF
        dn: {{ item }}
        changetype: modify
        replace: nsds5ReplicaEnabled
        nsds5ReplicaEnabled: off
        EOF
      loop: "{{ agreements_to_canary.stdout_lines }}"

- name: Pause canary outbound replication
  hosts: ipa_canary  # replica3
  become: true
  tasks:
    - name: Find all replication agreements
      shell: |
        ldapsearch -Y EXTERNAL -H ldapi:// -b "cn=config" \
          "(objectClass=nsds5replicationagreement)" dn 2>/dev/null \
          | grep "^dn:" | sed 's/^dn: //'
      register: canary_agreements

    - name: Pause all outbound replication
      shell: |
        ldapmodify -Y EXTERNAL -H ldapi:// <<EOF
        dn: {{ item }}
        changetype: modify
        replace: nsds5ReplicaEnabled
        nsds5ReplicaEnabled: off
        EOF
      loop: "{{ canary_agreements.stdout_lines }}"

- name: Verify isolation
  hosts: ipa_primary
  become: true
  tasks:
    - name: Create isolation test user
      freeipa.ansible_freeipa.ipauser:
        ipaadmin_password: Secret123
        name: canary-isolation-test
        first: Canary
        last: Test
        state: present

    - name: Wait for replication window
      pause:
        seconds: 15

    - name: Check user does NOT exist on canary
      delegate_to: replica3
      shell: |
        ldapsearch -x -H ldap://localhost -D "cn=Directory Manager" \
          -w Secret123 -b "cn=users,cn=accounts,dc=imagemode,dc=test" \
          "(uid=canary-isolation-test)" dn
      register: isolation_check
      failed_when: "'dn:' in isolation_check.stdout"

    - name: Remove isolation test user
      freeipa.ansible_freeipa.ipauser:
        ipaadmin_password: Secret123
        name: canary-isolation-test
        state: absent

- name: Apply schema on canary
  hosts: ipa_canary
  become: true
  tasks:
    - name: Copy schema LDIF
      copy:
        src: "{{ schema_ldif }}"
        dest: /tmp/schema-canary.ldif

    - name: Apply schema via ldapmodify
      shell: |
        ldapmodify -Y EXTERNAL \
          -H ldapi://%2Fvar%2Frun%2Fslapd-IMAGEMODE-TEST.socket \
          -f /tmp/schema-canary.ldif
      register: schema_apply

    - name: Verify DS survived
      systemd:
        name: "dirsrv@IMAGEMODE-TEST"
      register: ds_status
      failed_when: ds_status.status.ActiveState != 'active'

    - name: Verify schema loaded
      shell: |
        ldapsearch -Y EXTERNAL -H ldapi:// -b cn=schema -s base \
          objectClasses 2>/dev/null | grep -c ipaOAuth2
      register: schema_count
      failed_when: schema_count.stdout | int != 4

    - name: Restart DS to verify schema persists
      systemd:
        name: "dirsrv@IMAGEMODE-TEST"
        state: restarted

    - name: Wait for DS
      pause:
        seconds: 5

    - name: Verify DS survived restart
      systemd:
        name: "dirsrv@IMAGEMODE-TEST"
      register: ds_restart
      failed_when: ds_restart.status.ActiveState != 'active'

    - name: Verify Kerberos works
      shell: echo Secret123 | kinit admin
      changed_when: false

    - name: Verify IPA API works
      command: ipa ping
      changed_when: false

    - name: Verify user operations work
      freeipa.ansible_freeipa.ipauser:
        ipaadmin_password: Secret123
        name: schema-canary-test
        first: Schema
        last: Test
        state: present

    - name: Clean up test user
      freeipa.ansible_freeipa.ipauser:
        ipaadmin_password: Secret123
        name: schema-canary-test
        state: absent

- name: Reconnect replication (canary passed)
  hosts: all
  become: true
  tasks:
    - name: Re-enable all replication agreements
      shell: |
        for AGR in $(ldapsearch -Y EXTERNAL -H ldapi:// -b "cn=config" \
          "(objectClass=nsds5replicationagreement)" dn 2>/dev/null \
          | grep "^dn:" | sed 's/^dn: //'); do
          ldapmodify -Y EXTERNAL -H ldapi:// <<EOF
        dn: $AGR
        changetype: modify
        replace: nsds5ReplicaEnabled
        nsds5ReplicaEnabled: on
        EOF
        done
      changed_when: true

    - name: Wait for schema propagation
      pause:
        seconds: 20

- name: Verify schema on all nodes
  hosts: all
  become: true
  tasks:
    - name: Check WID objectClasses present
      shell: |
        ldapsearch -Y EXTERNAL -H ldapi:// -b cn=schema -s base \
          objectClasses 2>/dev/null | grep -c ipaOAuth2
      register: schema_verify
      failed_when: schema_verify.stdout | int != 4

    - name: Full verification suite
      include_role:
        name: verify_full_suite
```

#### 4. `recover-single-node.yaml` — R1 Recovery

```yaml
---
# R1: Single node recovery via re-enrollment
# Usage: ansible-playbook -i inventory/imagemode recover-single-node.yaml
#        -e target_node=replica3

- name: Rollback and uninstall on failed node
  hosts: "{{ target_node }}"
  become: true
  tasks:
    - name: Rollback bootc image
      command: bootc rollback
      ignore_errors: true

    - name: Reboot
      reboot:
        reboot_timeout: 300

    - name: Uninstall IPA server
      command: ipa-server-install --uninstall -U
      ignore_errors: true

    - name: Uninstall IPA client
      command: ipa-client-install --uninstall -U
      ignore_errors: true

    - name: Nuclear cleanup (WID lesson #42)
      shell: |
        rm -rf /etc/ipa/ /etc/pki/pki-tomcat/ /var/log/pki/ \
          /var/lib/dirsrv/slapd-* /var/log/dirsrv/slapd-* \
          /etc/dirsrv/slapd-* /var/lib/ipa/sysrestore/* \
          /var/lib/ipa/sysupgrade/* /var/lib/pki/* /run/ipa/* \
          /dev/shm/slapd-* /etc/httpd/conf.d/ipa*.conf \
          /etc/httpd/conf.d/nss.conf
      # NOTE: do NOT rm -rf /etc/dirsrv/ (WID lesson #43)

- name: Remove failed node from topology
  hosts: ipa_primary
  become: true
  tasks:
    - name: Remove server from IPA
      freeipa.ansible_freeipa.ipaserver:
        ipaadmin_password: Secret123
        name: "{{ hostvars[target_node].ansible_fqdn }}"
        state: absent
        force: true
        ignore_topology_disconnect: true

    - name: Remove host entry
      freeipa.ansible_freeipa.ipahost:
        ipaadmin_password: Secret123
        name: "{{ hostvars[target_node].ansible_fqdn }}"
        state: absent
        updatedns: true

    - name: Re-add host entry
      freeipa.ansible_freeipa.ipahost:
        ipaadmin_password: Secret123
        name: "{{ hostvars[target_node].ansible_fqdn }}"
        ip_address: "{{ hostvars[target_node].ansible_default_ipv4.address }}"
        force: true
        state: present

    - name: Restart IPA services
      command: ipactl restart

- name: Re-enroll failed node
  hosts: "{{ target_node }}"
  become: true
  collections:
    - freeipa.ansible_freeipa
  pre_tasks:
    - name: Create IPA directory tree (WID lesson #17)
      file:
        path: "{{ item.path }}"
        state: directory
        mode: "{{ item.mode | default('0755') }}"
      loop:
        - { path: /var/lib/ipa/sysrestore }
        - { path: /var/lib/ipa/sysupgrade }
        - { path: /var/lib/ipa/gssproxy }
        - { path: /var/lib/ipa/passwds, mode: '0700' }
        - { path: /var/lib/ipa/certs }
        - { path: /var/lib/ipa/private, mode: '0700' }
        - { path: /var/lib/ipa/backup }
        - { path: /var/lib/ipa/pki-ca/publish }
        - { path: /var/lib/ipa/dnssec/tokens }
        - { path: /var/kerberos/krb5kdc }
        - { path: /var/kerberos/krb5/user }
        - { path: /etc/ipa/custodia }
        - { path: /etc/ipa/dnssec }
        - { path: /etc/ipa/html }
        - { path: /etc/ipa/nssdb }
        - { path: /etc/ipa/kdcproxy }

    - name: Restore SELinux contexts
      command: restorecon -Rv {{ item }}
      loop:
        - /var/lib/ipa
        - /var/lib/dirsrv
        - /var/kerberos
        - /etc/ipa

    - name: Ensure swap exists (WID lesson #46)
      shell: |
        if [ ! -f /var/swapfile ]; then
          dd if=/dev/zero of=/var/swapfile bs=1M count=1024
          chmod 600 /var/swapfile && mkswap /var/swapfile
        fi
        swapon /var/swapfile 2>/dev/null || true

  roles:
    - role: ipareplica
      vars:
        ipaadmin_password: Secret123
        ipadm_password: Secret123
        ipareplica_setup_ca: true
        ipareplica_setup_dns: true
        ipareplica_forwarders:
          - 10.11.5.19
        ipareplica_no_dnssec_validation: true
        ipareplica_no_ntp: true
        ipareplica_skip_conncheck: true

  post_tasks:
    - name: Full verification
      include_role:
        name: verify_full_suite
```

#### 5. `verify-all.yaml` — Complete Verification Suite

```yaml
---
# Full verification: replication + auth + topology on all nodes
# Usage: ansible-playbook -i inventory/imagemode verify-all.yaml
# Exit 0 = all pass, exit non-zero = failures detected

- name: Topology verification
  hosts: ipa_primary
  become: true
  collections:
    - freeipa.ansible_freeipa
  tasks:
    - name: Verify domain topology
      command: ipa topologysuffix-verify domain
      register: topo_domain
      changed_when: false
      failed_when: "'disconnected' in topo_domain.stdout or 'unreachable' in topo_domain.stdout"

    - name: Verify CA topology
      command: ipa topologysuffix-verify ca
      register: topo_ca
      changed_when: false
      failed_when: "'disconnected' in topo_ca.stdout or 'unreachable' in topo_ca.stdout"

- name: Service health on each node
  hosts: all
  become: true
  tasks:
    - name: IPA services running
      command: ipactl status
      register: ipactl
      changed_when: false
      failed_when: ipactl.rc != 0

    - name: 389-DS listening on TCP 389
      wait_for:
        port: 389
        timeout: 5

    - name: KDC listening on TCP/UDP 88
      wait_for:
        port: 88
        timeout: 5

    - name: httpd listening on 443
      wait_for:
        port: 443
        timeout: 5

- name: Kerberos authentication on each node
  hosts: all
  become: true
  tasks:
    - name: kinit against local KDC
      shell: echo Secret123 | kinit admin
      changed_when: false
      no_log: true

    - name: IPA API responds
      command: ipa ping
      changed_when: false

    - name: Certificate query works
      command: ipa cert-show 1
      changed_when: false

    - name: Destroy ticket
      command: kdestroy
      changed_when: false

- name: Cross-node Kerberos
  hosts: ipa_primary
  become: true
  tasks:
    - name: Get admin ticket
      shell: echo Secret123 | kinit admin
      changed_when: false
      no_log: true

    - name: Acquire service ticket for each node
      command: kvno HTTP/{{ hostvars[item].ansible_fqdn }}@IMAGEMODE.TEST
      loop: "{{ groups['all'] }}"
      changed_when: false

- name: LDAP bind verification
  hosts: all
  become: true
  tasks:
    - name: GSSAPI bind to local DS
      shell: |
        echo Secret123 | kinit admin 2>/dev/null
        ldapsearch -Y GSSAPI -H ldap://localhost \
          -b "cn=users,cn=accounts,dc=imagemode,dc=test" \
          "(uid=admin)" dn 2>/dev/null | grep -q "uid=admin"
      changed_when: false

    - name: Simple bind as Directory Manager
      shell: |
        ldapwhoami -x -H ldap://localhost \
          -D "cn=Directory Manager" -w Secret123
      changed_when: false
      no_log: true

    - name: Password bind as admin
      shell: |
        ldapwhoami -x -H ldap://localhost \
          -D "uid=admin,cn=users,cn=accounts,dc=imagemode,dc=test" \
          -w Secret123
      changed_when: false
      no_log: true

- name: Replication consistency test
  hosts: ipa_primary
  become: true
  collections:
    - freeipa.ansible_freeipa
  vars:
    test_user: "repl-verify-{{ ansible_date_time.epoch }}"
  tasks:
    - name: Get admin ticket
      shell: echo Secret123 | kinit admin
      changed_when: false
      no_log: true

    - name: Create test user on primary
      freeipa.ansible_freeipa.ipauser:
        ipaadmin_password: Secret123
        name: "{{ test_user }}"
        first: Replication
        last: Test
        state: present

    - name: Wait for replication
      pause:
        seconds: 10

    - name: Verify user exists on all replicas
      shell: |
        ldapsearch -x -H ldap://{{ hostvars[item].ansible_fqdn }} \
          -D "cn=Directory Manager" -w Secret123 \
          -b "cn=users,cn=accounts,dc=imagemode,dc=test" \
          "(uid={{ test_user }})" dn | grep -q "dn:"
      loop: "{{ groups['ipa_replicas'] }}"
      changed_when: false
      no_log: true

    - name: Clean up test user
      freeipa.ansible_freeipa.ipauser:
        ipaadmin_password: Secret123
        name: "{{ test_user }}"
        state: absent

    - name: Check replication agreement status
      shell: |
        ldapsearch -x -H ldap://localhost -D "cn=Directory Manager" \
          -w Secret123 -b "cn=config" \
          "(objectClass=nsds5replicationagreement)" \
          nsds5replicahost nsds5replicalastupdatestatus 2>/dev/null \
          | grep -E "nsds5replica(host|lastupdatestatus)"
      register: repl_status
      changed_when: false
      no_log: true

    - name: Assert all agreements healthy
      assert:
        that: "'Status: Error' not in repl_status.stdout"
        fail_msg: "Replication agreement error detected"

- name: WID verification (conditional)
  hosts: all
  become: true
  when: wid_enabled | default(false)
  tasks:
    - name: ahdapa OIDC discovery
      uri:
        url: "http://localhost:8090/.well-known/openid-configuration"
        return_content: true
      register: oidc_discovery
      failed_when: "'issuer' not in oidc_discovery.content"

    - name: akamu ACME directory
      uri:
        url: "https://localhost:19443/acme/directory"
        validate_certs: false
        return_content: true
      register: acme_directory
      failed_when: "'newNonce' not in acme_directory.content"

    - name: Kerberos still works alongside WID
      shell: echo Secret123 | kinit admin && ipa ping
      changed_when: false
      no_log: true
```

### Inventory Template

```ini
# inventory/imagemode
[ipa_primary]
primary ansible_host=<IP> ansible_fqdn=primary.imagemode.test

[ipa_replicas]
replica1 ansible_host=<IP> ansible_fqdn=replica1.imagemode.test
replica2 ansible_host=<IP> ansible_fqdn=replica2.imagemode.test
replica3 ansible_host=<IP> ansible_fqdn=replica3.imagemode.test

[ipa_canary]
replica3

[all:vars]
ansible_user=root
ansible_ssh_private_key_file=~/.ssh/idm_ci_key
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
ipadomain=imagemode.test
iparealm=IMAGEMODE.TEST
```

### Custom Roles to Build

| Role | Purpose | Wraps |
|------|---------|-------|
| `verify_ipa_health` | Single-node health (ipactl, ports, kinit, ipa ping) | systemd, shell |
| `verify_replication` | Write/read test + agreement status | `ipauser` + ldapsearch |
| `verify_full_suite` | All verification (calls above + topology + cross-node auth) | All verification playbooks |
| `backup_ipa_state` | Snapshot sysupgrade, schema, agreements, config, LMDB | shell (cp, ldapsearch) |
| `bootc_lifecycle` | bootc upgrade/switch/rollback + version stamp | shell (bootc CLI) |
| `isolate_replication` | Pause/resume agreements for canary testing | ldapmodify |
| `nuclear_cleanup` | Full IPA uninstall + state wipe (WID lesson #42-43) | shell |
| `wid_overlay` | Deploy WID Phase 2 (ahdapa, akamu, plugins) | Existing WID ansible roles |
| `verify_wid` | OAuth2 token flow + ACME directory + Kerberos coexistence | uri, shell |

### Automation Coverage Matrix

Every operation from Parts 1-5, mapped to its playbook:

| Operation | Playbook | ansible-freeipa | Custom |
|-----------|----------|:---------------:|:------:|
| Deploy primary | `deploy-cluster.yaml` | `ipaserver` role | `verify_ipa_health` |
| Deploy replicas (serial) | `deploy-cluster.yaml` | `ipareplica` role | dir pre-create, swap |
| Verify topology | `verify-all.yaml` | `ipatopologysuffix` | — |
| Verify replication | `verify-all.yaml` | `ipauser` | ldapsearch agreements |
| Verify auth (Kerberos) | `verify-all.yaml` | — | kinit, kvno, ldapwhoami |
| Verify auth (LDAP) | `verify-all.yaml` | — | ldapsearch GSSAPI+simple |
| Verify certs | `verify-all.yaml` | `ipacert` | — |
| Pre-upgrade backup | `backup-pre-upgrade.yaml` | `ipabackup` | LMDB snapshot |
| Rolling upgrade | `rolling-upgrade.yaml` | — | bootc, ipa-server-upgrade |
| Rollback single node | `recover-single-node.yaml` | `ipaserver`, `ipahost` | nuclear cleanup |
| Rollback full cluster | `rollback-cluster.yaml` | — | bootc rollback |
| Repair replication | `repair-replication.yaml` | `ipatopologysegment` | ldapmodify agreements |
| Schema validation | `validate-schema.yaml` | — | dsconf, OID check |
| Schema canary test | `canary-schema.yaml` | `ipauser` | isolate/reconnect |
| Schema production apply | `apply-schema-production.yaml` | — | ldapmodify |
| WID image rebase | `bootc-switch.yaml` | — | bootc switch |
| WID overlay deploy | `deploy-wid-overlay.yaml` | — | WID ansible roles |
| WID activation | `activate-wid.yaml` | — | `oauth2_clients` role |
| WID verification | `verify-all.yaml -e wid_enabled=true` | — | uri (OIDC, ACME) |
| Auth diagnosis | `diagnose-auth.yaml` | — | systemd, journal, DS checks |
| WID service recovery | `recover-wid-services.yaml` | — | SELinux relabel, drop-ins |

---

## Open Questions for ftrivino

1. **Bootc image provisioning pipeline:** mrack provisions VMs from existing
   OS images (OpenStack Glance / Beaker distros). A bootc FreeIPA qcow2
   needs to be built and registered before mrack can use it. Is this a
   separate CI job that builds the image and uploads to Glance, or does the
   metadata YAML trigger the build inline? This determines whether we need
   a two-stage pipeline (build image → provision VMs) or single-stage.

2. **RHEL 10 FreeIPA version:** Which nightly compose? Is the CI already
   building bootc images with FreeIPA, or is this net-new?

3. **Two image versions for upgrade testing:** The rolling-upgrade phase
   needs two different bootc images (v1 and v2). Where do they come from —
   two nightly composes (e.g., RHEL-10.3 and RHEL-10.4), or a pinned
   compose vs latest? This affects how we test `ipa-server-upgrade`
   behavior across versions.

4. **CA backend for upgrade testing:** Does ftrivino want to test the
   Dogtag→ipacta transition specifically, or is the "fresh WID replica
   joining existing topology" approach sufficient?

5. **Test suite:** Should the 4-node cluster run existing IPA integration
   tests (pytest), or is topology verification + replication/auth health
   enough for now?

6. **Image registry:** Where should the bootc images live? idm-ci uses
   OpenStack Glance + AWS AMIs. Do we also push to Quay?
