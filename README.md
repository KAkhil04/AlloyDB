# AlloyDB Omni Kubernetes CRD Reference
## On-Premises OpenShift Deployment

**Operator Version:** fleet-controller-manager & local-controller-manager `v1.6.0`
**AlloyDB Omni Version:** `v17.5.0`
**Target Platform:** Red Hat OpenShift Container Platform (on-premises)
**API Groups:** `alloydbomni.dbadmin.goog/v1` · `alloydbomni.internal.dbadmin.goog/v1`

---

## OpenShift On-Premises Prerequisites

Before deploying AlloyDB Omni CRDs on an on-prem OpenShift cluster, ensure the following are in place:

### Operator Installation (OLM / Helm)

AlloyDB Omni is installed via Helm into the `alloydb-omni-system` namespace (OpenShift project). If installing through OLM, install the operator from OperatorHub or a mirrored catalog index.

```bash
# Create the operator namespace as an OpenShift project
oc new-project alloydb-omni-system

# Install via Helm (adjust registry mirror as needed)
helm install alloydbomni-operator \
  oci://<your-mirror-registry>/alloydb-omni/helm-chart/alloydbomni-operator \
  --version 1.6.0 \
  --namespace alloydb-omni-system
```

### Security Context Constraints (SCC)

OpenShift enforces Security Context Constraints (SCCs) instead of Kubernetes PodSecurityAdmission. AlloyDB Omni database pods require elevated privileges for managing disk I/O, shared memory (`/dev/shm`), and PostgreSQL-specific capabilities.

```yaml
# Grant the alloydb-omni service account the required SCC
# Option A — use the built-in 'privileged' SCC (simplest, less restrictive)
oc adm policy add-scc-to-user privileged \
  -z alloydb-omni-sa -n alloydb-omni-system

# Option B — create a custom SCC (recommended for production)
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: alloydb-omni-scc
allowPrivilegeEscalation: false
allowPrivilegedContainer: false
allowedCapabilities:
  - IPC_LOCK
  - SYS_RESOURCE
fsGroup:
  type: MustRunAs
  ranges:
    - min: 999
      max: 999
runAsUser:
  type: MustRunAsRange
  uidRangeMin: 999
  uidRangeMax: 999
seLinuxContext:
  type: MustRunAs
supplementalGroups:
  type: RunAsAny
volumes:
  - persistentVolumeClaim
  - emptyDir
  - secret
  - configMap
  - projected
users:
  - system:serviceaccount:alloydb-omni-system:alloydb-omni-sa
```

> **Important:** OpenShift assigns a random UID from the namespace's allowed UID range by default. AlloyDB Omni pods may need a fixed UID (typically `999` for postgres). Set `runAsUser` explicitly in the SCC or annotate the namespace accordingly.

### Image Registry Mirroring

On-prem OpenShift clusters typically have no direct internet access. Mirror the required images to your internal registry (Quay, Harbor, Nexus, etc.) and configure an `ImageContentSourcePolicy` or `ImageDigestMirrorSet`.

```yaml
# OpenShift 4.13+ — ImageDigestMirrorSet
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: alloydb-omni-mirror
spec:
  imageDigestMirrors:
    - mirrors:
        - <your-internal-registry>/alloydb-omni
      source: us-docker.pkg.dev/alloydb-omni/release
```

Required images to mirror:
- `us-docker.pkg.dev/alloydb-omni/release/operator:1.6.0`
- `us-docker.pkg.dev/alloydb-omni/release/database:17.5.0`
- `us-docker.pkg.dev/alloydb-omni/release/pgbouncer:<tag>`
- `us-docker.pkg.dev/alloydb-omni/release/fluent-bit:<tag>` *(if using sidecar log shipping)*

### Storage Classes (OpenShift / ODF)

On-prem OpenShift typically uses one of the following backends. Use **RWO (ReadWriteOnce)** storage for all AlloyDB Omni disk types.

| Storage Backend | StorageClass Name | Notes |
|---|---|---|
| OpenShift Data Foundation (ODF/OCS) — Ceph RBD | `ocs-storagecluster-ceph-rbd` | Recommended for production |
| OpenShift Data Foundation — CephFS | `ocs-storagecluster-cephfs` | For shared/multi-read volumes only; not for DB data |
| VMware vSphere CSI | `thin-csi` | Common on vSphere-based on-prem clusters |
| Local Storage Operator | `local-storage` | High performance; no live migration |
| NFS (via NFS CSI driver) | `nfs-csi` | Avoid for DataDisk/LogDisk; acceptable for BackupDisk |

> **Recommendation:** Use `ocs-storagecluster-ceph-rbd` (or `thin-csi` on vSphere) for `DataDisk` and `LogDisk`. `BackupDisk` may use NFS or an S3-compatible store (MinIO/Ceph RGW) via `backupLocation`.

### Networking: No Cloud Load Balancers

On-prem OpenShift does not have a cloud-managed load balancer. For external database access, use one of:

| Approach | How |
|---|---|
| **OpenShift Route** | Expose the DB service via a passthrough Route (TLS only). Suitable for JDBC clients that support TLS SNI. |
| **MetalLB** | Install MetalLB operator; use `type: LoadBalancer` with IP address pools from your on-prem subnet. |
| **NodePort** | Expose on a static port on every node. Simple but less flexible. |
| **ClusterIP** | Internal-only access from within the cluster. Recommended for app-to-DB connectivity. |

### Connected Mode vs Isolated Mode

AlloyDB Omni's **connected mode** (`connectedModeSpec` in DBCluster) requires outbound connectivity to `metadata.google.internal` and Google Cloud APIs. This is **not available** on air-gapped or on-premises deployments. All examples in this document use **isolated mode** (no `connectedModeSpec`).

---

## Architecture Overview

The AlloyDB Omni Kubernetes operator deploys two controllers in the `alloydb-omni-system` project/namespace:

| Controller | Role |
|---|---|
| **fleet-controller-manager** | Handles public-facing CRDs (`alloydbomni.dbadmin.goog`). Reconciles user-intent resources such as `DBCluster`, `BackupPlan`, `Failover`, `Replication`, etc. |
| **local-controller-manager** | Handles internal CRDs (`alloydbomni.internal.dbadmin.goog`). Manages low-level per-instance workflows: standby jobs, instance backup/restore, LRO jobs, replication configs, and instance lifecycle. |

> **OpenShift note:** OpenShift Projects are Kubernetes Namespaces with additional RBAC and SCC enforcement. All `namespace` references below apply equally to OpenShift projects.

> **Note on OCR corrections:** Several names in the original list contained OCR artefacts (`-goog` → `.goog`, `go0g` → `goog`, `.gov` → `.goog`, `1rojobs` → `lrojobs`). Corrected names are used throughout this document.

---

## CRD Summary Table

| # | CRD Name | API Group | Scope | Controller | Category | Purpose |
|---|---|---|---|---|---|---|
| 1 | `backupplans` | `alloydbomni.dbadmin.goog` | Namespaced | fleet | Backup | Defines automated backup schedules and retention for a DBCluster |
| 2 | `backuprepositories` | `alloydbomni.internal.dbadmin.goog` | Namespaced | local | Backup | Internal: configures the pgBackRest backup repository storage location |
| 3 | `backups` | `alloydbomni.dbadmin.goog` | Namespaced | fleet | Backup | Represents a single backup execution (manual or scheduled) |
| 4 | `createstandbyjobs` | `alloydbomni.internal.dbadmin.goog` | Namespaced | local | HA / Replication | Internal workflow object tracking standby instance initialisation |
| 5 | `dbclusters` | `alloydbomni.dbadmin.goog` | Namespaced | fleet | Core | Primary resource — declares and manages a full PostgreSQL database cluster |
| 6 | `dbinstances` | `alloydbomni.dbadmin.goog` | Namespaced | fleet | Core | Declares a read-pool or additional instance group within a DBCluster |
| 7 | `deletestandbyjobs` | `alloydbomni.internal.dbadmin.goog` | Namespaced | local | HA / Replication | Internal workflow object tracking standby instance deletion |
| 8 | `failovers` (public) | `alloydbomni.dbadmin.goog` | Namespaced | fleet | HA | Triggers an unplanned failover, promoting a standby to primary |
| 9 | `failovers` (internal) | `alloydbomni.internal.dbadmin.goog` | Namespaced | local | HA | Internal: low-level failover workflow and state machine |
| 10 | `instancebackupplans` | `alloydbomni.internal.dbadmin.goog` | Namespaced | local | Backup | Internal: per-instance backup schedule derived from BackupPlan |
| 11 | `instancebackups` | `alloydbomni.internal.dbadmin.goog` | Namespaced | local | Backup | Internal: tracks backup execution state per database instance |
| 12 | `instancerestores` | `alloydbomni.internal.dbadmin.goog` | Namespaced | local | Backup | Internal: tracks restore execution state per database instance |
| 13 | `instances` | `alloydbomni.internal.dbadmin.goog` | Namespaced | local | Core | Internal: low-level representation of a single database pod/node |
| 14 | `instanceswitchovers` | `alloydbomni.internal.dbadmin.goog` | Namespaced | local | HA | Internal: per-instance switchover workflow and state tracking |
| 15 | `instanceuserdefinedauthentications` | `alloydbomni.internal.dbadmin.goog` | Namespaced | local | Security | Internal: applies Kerberos/AD auth config to an individual instance |
| 16 | `lrojobs` | `alloydbomni.internal.dbadmin.goog` | Namespaced | local | Operations | Internal: tracks Long Running Operations (async multi-step workflows) |
| 17 | `pgbouncers` | `alloydbomni.dbadmin.goog` | Namespaced | fleet | Connectivity | Deploys and manages a PgBouncer connection pooler for a DBCluster |
| 18 | `replicationconfigs` | `alloydbomni.internal.dbadmin.goog` | Namespaced | local | Replication | Internal: stores derived replication settings for each instance |
| 19 | `replications` | `alloydbomni.dbadmin.goog` | Namespaced | fleet | Replication | Configures physical or logical streaming replication between clusters |
| 20 | `restores` | `alloydbomni.dbadmin.goog` | Namespaced | fleet | Backup | Initiates a cluster restore from a Backup or a point-in-time |
| 21 | `sidecars` (public) | `alloydbomni.dbadmin.goog` | Namespaced | fleet | Extensibility | Injects custom sidecar containers into database pods |
| 22 | `sidecars` (internal) | `alloydbomni.internal.dbadmin.goog` | Namespaced | local | Extensibility | Internal: tracks sidecar injection state per instance |
| 23 | `switchovers` | `alloydbomni.dbadmin.goog` | Namespaced | fleet | HA | Triggers a graceful planned role switch between primary and standby |
| 24 | `tdeconfigs` | `alloydbomni.dbadmin.goog` | Namespaced | fleet | Security | Configures Transparent Data Encryption (TDE) using a KMS key |
| 25 | `userdefinedauthentications` | `alloydbomni.dbadmin.goog` | Namespaced | fleet | Security | Configures Kerberos/Active Directory authentication via pg_hba.conf |

---

## Detailed CRD Reference

---

### 1. `backupplans.alloydbomni.dbadmin.goog`

**Kind:** `BackupPlan` · **API Version:** `alloydbomni.dbadmin.goog/v1`

Defines automated backup schedules (full, differential, incremental) and retention policy for a `DBCluster`. Uses pgBackRest internally. The fleet-controller-manager reconciles `InstanceBackupPlan` objects for each backing instance.

**On-prem OpenShift:** Use `type: S3` with a MinIO or Ceph RGW endpoint for remote backup storage. GCS is not available on-premises. For local storage, omit `backupLocation` entirely — pgBackRest will use the pod's `BackupDisk` PVC.

**Spec:**

```yaml
apiVersion: alloydbomni.dbadmin.goog/v1
kind: BackupPlan
metadata:
  name: my-backupplan
  namespace: my-db-project          # OpenShift project (= Kubernetes namespace)
spec:
  dbclusterRef: "my-dbcluster"      # (required, immutable) Target DBCluster name
  backupRetainDays: 14              # (optional) Retention in days, range 1–90, default 14
  paused: false                     # (optional) Suspend scheduling without deleting plan
  PITREnabled: true                 # (optional) Enable point-in-time recovery
  backupSourceStrategy: primary     # (optional) "primary" | "standby", default primary
  backupSchedules:
    full: "0 0 * * 0"              # Cron: full backup — every Sunday midnight
    differential: "0 2 * * 1-6"    # Cron: differential — Mon–Sat at 02:00
    incremental: "0 21 * * *"      # Cron: incremental — daily at 21:00
  backupLocation:                   # (optional) Omit to use local BackupDisk PVC
    type: S3                        # On-prem: use S3-compatible (MinIO / Ceph RGW)
    s3Options:
      bucket: "alloydb-backups"
      key: "clusters/my-dbcluster/"
      endpoint: "https://minio.storage.internal:9000"   # Internal MinIO/Ceph RGW URL
      region: "us-east-1"                               # Can be any string for MinIO
      caBundle: |                                        # PEM CA cert for self-signed TLS
        -----BEGIN CERTIFICATE-----
        <your-internal-CA-cert>
        -----END CERTIFICATE-----
      secretRef:
        name: minio-s3-credentials   # K8s Secret with 'access-key' and 'secret-key'
        namespace: my-db-project
```

**Secret format for MinIO/Ceph RGW credentials:**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: minio-s3-credentials
  namespace: my-db-project
type: Opaque
stringData:
  access-key: "<MINIO_ACCESS_KEY>"
  secret-key: "<MINIO_SECRET_KEY>"
```

**Status fields:** `phase`, `lastBackupTime`, `nextBackupTime`, `recoveryWindow.begin/end`, `conditions[]`, `criticalIncidents[]`, `reconciled`, `observedGeneration`

---

### 2. `backuprepositories.alloydbomni.internal.dbadmin.goog`

**Kind:** `BackupRepository` · **API Version:** `alloydbomni.internal.dbadmin.goog/v1`

**Internal — do not create or modify directly.** Generated by the fleet-controller-manager from a `BackupPlan`. Represents the pgBackRest repository configuration (`repo1`, `repo2`, etc.) on the individual database instance. Consumed by the local-controller-manager to configure the pgBackRest stanza on each pod.

```yaml
# Internal resource — managed by the operator
apiVersion: alloydbomni.internal.dbadmin.goog/v1
kind: BackupRepository
metadata:
  name: backuprepository-sample
  namespace: my-db-project
spec:
  # Derived from BackupPlan.spec.backupLocation
  # Contains repository type, path, storage credentials
```

**Status fields:** `phase`, `conditions[]`, `reconciled`

---

### 3. `backups.alloydbomni.dbadmin.goog`

**Kind:** `Backup` · **API Version:** `alloydbomni.dbadmin.goog/v1`

Represents a single backup execution — created automatically by a `BackupPlan` schedule or triggered manually. Tracks lifecycle from creation through completion and expiry.

**Spec:**

```yaml
spec:
  dbclusterRef: "my-dbcluster"     # (required) Target DBCluster
  backupPlanRef: "my-backupplan"   # (required) Parent BackupPlan
  manual: false                    # (optional) true = manually triggered, default false
  backupSourceRole: primary        # (optional) "primary" | "standby"
  physicalbackupSpec:
    backuptype: full               # (optional) "full" | "differential" | "incremental"
```

**Trigger a manual backup (on-prem):**

```yaml
apiVersion: alloydbomni.dbadmin.goog/v1
kind: Backup
metadata:
  name: manual-backup-20260329
  namespace: my-db-project
spec:
  dbclusterRef: my-dbcluster
  backupPlanRef: my-backupplan
  manual: true
  physicalbackupSpec:
    backuptype: full
```

```bash
oc apply -f manual-backup.yaml -n my-db-project
oc get backup manual-backup-20260329 -n my-db-project -w
```

**Status fields:** `phase`, `createTime`, `completeTime`, `retainExpireTime`, `physicalbackupStatus.backupId`, `conditions[]`, `criticalIncidents[]`, `reconciled`

---

### 4. `createstandbyjobs.alloydbomni.internal.dbadmin.goog`

**Kind:** `CreateStandbyJob` · **API Version:** `alloydbomni.internal.dbadmin.goog/v1`

**Internal — do not create or modify directly.** Workflow tracking object created by the local-controller-manager when a new standby instance needs to be initialised (e.g., when a `DBCluster` increases its `availability.standbys` count). Tracks multi-step provisioning: PVC creation, base backup, WAL catchup, and readiness verification.

**On-prem OpenShift:** PVC creation uses your configured OpenShift StorageClass (e.g., `ocs-storagecluster-ceph-rbd`). If dynamic provisioning is unavailable, pre-provision PVs before scaling standbys.

```yaml
# Internal resource — managed by the operator
apiVersion: alloydbomni.internal.dbadmin.goog/v1
kind: CreateStandbyJob
metadata:
  name: createstandbyjob-sample
  namespace: my-db-project
spec:
  # WorkflowSpec: contains instanceRef, phase, attempt counter
```

**Status fields:** `state` (`InProgress` | `Succeeded` | `Failed`), `phase`, `startTime`, `endTime`, `conditions[]`, `criticalIncidents[]`

---

### 5. `dbclusters.alloydbomni.dbadmin.goog`

**Kind:** `DBCluster` · **API Version:** `alloydbomni.dbadmin.goog/v1`

The **primary user-facing resource**. Declares a complete PostgreSQL cluster including the primary instance, optional standbys for HA, compute resources, disk layout, TLS configuration, and database parameters. All other resources reference this.

**On-prem OpenShift notes:**
- Do **not** include `connectedModeSpec` — it requires Google Cloud connectivity unavailable on-premises.
- Use `type: ClusterIP` for services; expose externally via OpenShift Route (passthrough TLS) or MetalLB.
- StorageClass must match your OCP storage backend (ODF/Ceph RBD, thin-csi, local-storage).
- Set `schedulingConfig` to target worker nodes labelled for database workloads, avoiding scheduling on control-plane or infra nodes.
- The operator namespace UID range is enforced by OpenShift; ensure your SCC permits the postgres UID (`999`).

**Spec:**

```yaml
apiVersion: alloydbomni.dbadmin.goog/v1
kind: DBCluster
metadata:
  name: my-dbcluster
  namespace: my-db-project
spec:
  databaseVersion: "17.5.0"              # (required) PostgreSQL version
  controlPlaneAgentsVersion: "1.6.0"     # (required) Operator agent version
  primarySpec:
    adminUser:
      passwordRef:
        name: db-admin-secret            # OCP Secret in same namespace, key: 'password'
    resources:
      cpu: "4"
      memory: "16Gi"
      disks:
        - name: DataDisk
          size: "100Gi"
          storageClass: ocs-storagecluster-ceph-rbd   # ODF Ceph RBD (recommended)
          # storageClass: thin-csi                    # vSphere alternative
          # storageClass: local-storage               # Local NVMe (high perf, no live migration)
        - name: LogDisk
          size: "20Gi"
          storageClass: ocs-storagecluster-ceph-rbd
        - name: BackupDisk
          size: "50Gi"
          storageClass: ocs-storagecluster-ceph-rbd
        - name: ObsDisk
          size: "10Gi"
          storageClass: ocs-storagecluster-ceph-rbd
    databaseParameters:
      max_connections: "200"
      work_mem: "64MB"
      shared_buffers: "4GB"
    services:
      primary:
        type: ClusterIP                  # Use ClusterIP on-prem; expose via Route or MetalLB
        # type: LoadBalancer             # Use only if MetalLB is installed and configured
    schedulingConfig:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
                - key: node-role.kubernetes.io/worker
                  operator: Exists
                - key: db-workload
                  operator: In
                  values: ["true"]       # Label your DB nodes: oc label node <node> db-workload=true
      tolerations:
        - key: "db-dedicated"
          operator: "Equal"
          value: "true"
          effect: "NoSchedule"
  availability:
    standbys: 1                          # Number of HA standby replicas (0 for single-node)
    autoFailover: true
  mode: ""                               # "" (default) | "disasterRecovery"
  allowExternalIncomingTraffic: false    # Set true only with MetalLB or NodePort
  tls:
    certSecretRef:
      name: my-tls-secret               # OCP Secret with tls.crt and tls.key
  isDeleted: false                       # Set true to trigger cluster deletion
```

**Expose via OpenShift Route (passthrough TLS):**

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: my-dbcluster-route
  namespace: my-db-project
spec:
  port:
    targetPort: 5432
  tls:
    termination: passthrough             # DB handles TLS — passthrough at the router
  to:
    kind: Service
    name: my-dbcluster                   # ClusterIP service created by the operator
```

**Status fields:** `phase`, `primary.endpoint`, `primary.version`, `conditions[]`, `latestFailoverStatus`, `certificateReference`, `registrationStatus`, `restoredFrom`, `criticalIncidents[]`

---

### 6. `dbinstances.alloydbomni.dbadmin.goog`

**Kind:** `DBInstance` · **API Version:** `alloydbomni.dbadmin.goog/v1`

Defines an additional instance group (e.g., a **read pool**) attached to an existing `DBCluster`. Allows horizontal scale-out of read traffic independently from the primary. Each `DBInstance` spawns one or more `DBNode` pods.

**On-prem OpenShift:** Use the same StorageClass as your primary DBCluster. Read pool pods are scheduled on worker nodes; apply the same node affinity/toleration pattern used for the primary.

**Spec:**

```yaml
apiVersion: alloydbomni.dbadmin.goog/v1
kind: DBInstance
metadata:
  name: my-readpool
  namespace: my-db-project
spec:
  nodeCount: 2                           # (required) Number of read-pool nodes
  instanceType: ReadPool
  dbcParent: "my-dbcluster"
  isStopped: false
  progressTimeout: 600
  resources:
    cpu: "2"
    memory: "8Gi"
    disks:
      - name: DataDisk
        size: "50Gi"
        storageClass: ocs-storagecluster-ceph-rbd
      - name: LogDisk
        size: "10Gi"
        storageClass: ocs-storagecluster-ceph-rbd
  schedulingConfig:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: node-role.kubernetes.io/worker
                operator: Exists
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            labelSelector:
              matchLabels:
                alloydbomni.dbadmin.goog/dbcluster: my-dbcluster
            topologyKey: kubernetes.io/hostname
    tolerations: []
```

**Status fields:** `conditions[]`, `endpoints[]`, `criticalIncidents[]`, `reconciled`, `observedGeneration`

---

### 7. `deletestandbyjobs.alloydbomni.internal.dbadmin.goog`

**Kind:** `DeleteStandbyJob` · **API Version:** `alloydbomni.internal.dbadmin.goog/v1`

**Internal — do not create or modify directly.** Mirror of `CreateStandbyJob` for the teardown path. Created when the `DBCluster` decreases its standby count or a standby is decommissioned. Manages orderly shutdown, replication slot cleanup, and PVC release.

```yaml
# Internal resource — managed by the operator
apiVersion: alloydbomni.internal.dbadmin.goog/v1
kind: DeleteStandbyJob
metadata:
  name: deletestandbyjob-sample
  namespace: my-db-project
spec:
  # WorkflowSpec: instanceRef, attempt counter
```

**Status fields:** `state`, `phase`, `startTime`, `endTime`, `conditions[]`, `criticalIncidents[]`

---

### 8. `failovers.alloydbomni.dbadmin.goog` (Public)

**Kind:** `Failover` · **API Version:** `alloydbomni.dbadmin.goog/v1`

Triggers an **unplanned failover** — promotes a standby to primary without waiting for the current primary to cleanly shut down. Used when the primary is unavailable or unhealthy. Creates an internal `failovers.alloydbomni.internal.dbadmin.goog` object to execute the state machine.

**Spec:**

```yaml
apiVersion: alloydbomni.dbadmin.goog/v1
kind: Failover
metadata:
  name: failover-20260329
  namespace: my-db-project
spec:
  dbclusterRef: "my-dbcluster"          # (required) Target cluster (same namespace/project)
  newPrimary: "my-dbcluster-standby-0"  # (optional) Specific standby to promote;
                                         # omit to let the operator auto-select
```

```bash
# Trigger failover
oc apply -f failover.yaml -n my-db-project

# Watch the failover progress
oc get failover failover-20260329 -n my-db-project -w

# Verify new primary
oc get dbcluster my-dbcluster -n my-db-project -o jsonpath='{.status.primary.endpoint}'
```

**Status fields:** `state` (`InProgress` | `Success` | `Failed_RollbackInProgress` | `Failed_RollbackSuccess` | `Failed_RollbackFailed`), `startTime`, `endTime`, `createTime`, `conditions[]`, `criticalIncidents[]`, `internal.oldPrimary`, `internal.newPrimary`, `internal.attemptNumber`

---

### 9. `failovers.alloydbomni.internal.dbadmin.goog` (Internal)

**Kind:** `Failover` · **API Version:** `alloydbomni.internal.dbadmin.goog/v1`

**Internal — do not create or modify directly.** The low-level state machine created by the fleet-controller-manager in response to a public `Failover`. The local-controller-manager executes per-instance steps: fencing the old primary, promoting the standby, updating replication configs, and health-checking the new primary.

```yaml
# Internal resource — managed by the operator
apiVersion: alloydbomni.internal.dbadmin.goog/v1
kind: Failover
metadata:
  name: failover-internal-sample
  namespace: my-db-project
```

**Status fields:** `state`, `phase`, `startTime`, `endTime`, `conditions[]`, `criticalIncidents[]`

---

### 10. `instancebackupplans.alloydbomni.internal.dbadmin.goog`

**Kind:** `InstanceBackupPlan` · **API Version:** `alloydbomni.internal.dbadmin.goog/v1`

**Internal — do not create or modify directly.** Created automatically for each instance covered by a public `BackupPlan`. Carries the resolved backup schedule, retention, and S3/local storage config down to the local-controller-manager, which configures pgBackRest on that specific pod.

```yaml
# Internal resource — managed by the operator
apiVersion: alloydbomni.internal.dbadmin.goog/v1
kind: InstanceBackupPlan
metadata:
  name: instancebackupplan-sample
  namespace: my-db-project
spec:
  # Derived from BackupPlan — full/incremental/differential schedules, retention, storageRef
```

**Status fields:** `phase`, `lastBackupTime`, `nextBackupTime`, `conditions[]`, `reconciled`

---

### 11. `instancebackups.alloydbomni.internal.dbadmin.goog`

**Kind:** `InstanceBackup` · **API Version:** `alloydbomni.internal.dbadmin.goog/v1`

**Internal — do not create or modify directly.** Represents the execution of a single backup job on a specific instance. Created when a schedule fires or a manual `Backup` is requested. Tracks pgBackRest job progress (stanza init, backup run, catalog update) within the pod.

```yaml
# Internal resource — managed by the operator
apiVersion: alloydbomni.internal.dbadmin.goog/v1
kind: InstanceBackup
metadata:
  name: instancebackup-sample
  namespace: my-db-project
```

**Status fields:** `phase`, `createTime`, `completeTime`, `backupId`, `conditions[]`, `criticalIncidents[]`

---

### 12. `instancerestores.alloydbomni.internal.dbadmin.goog`

**Kind:** `InstanceRestore` · **API Version:** `alloydbomni.internal.dbadmin.goog/v1`

**Internal — do not create or modify directly.** Tracks the restore operation on a specific instance, created in response to a public `Restore` resource. Manages pgBackRest restore execution, WAL replay to the target time, and instance readiness signalling.

```yaml
# Internal resource — managed by the operator
apiVersion: alloydbomni.internal.dbadmin.goog/v1
kind: InstanceRestore
metadata:
  name: instancerestore-sample
  namespace: my-db-project
```

**Status fields:** `phase`, `createTime`, `completeTime`, `conditions[]`, `criticalIncidents[]`, `reconciled`

---

### 13. `instances.alloydbomni.internal.dbadmin.goog`

**Kind:** `Instance` · **API Version:** `alloydbomni.internal.dbadmin.goog/v1`

**Internal — do not create or modify directly.** The low-level representation of a single database pod (primary or standby). Created, updated, and deleted as `DBCluster` topology changes. Carries pod scheduling, resource allocation, and connectivity info at the node level.

**On-prem OpenShift:** Inspect these objects when diagnosing pod scheduling failures, SCC violations, or PVC binding issues. The `criticalIncidents` field will surface errors such as `ImagePullBackOff` (mirror config issue) or `Forbidden: unable to validate against any security context constraint` (SCC mismatch).

```yaml
# Internal resource — managed by the operator
apiVersion: alloydbomni.internal.dbadmin.goog/v1
kind: Instance
metadata:
  name: my-dbcluster-primary-0
  namespace: my-db-project
```

**Status fields:** `phase`, `endpoint`, `role` (`primary` | `standby`), `conditions[]`, `criticalIncidents[]`, `reconciled`

---

### 14. `instanceswitchovers.alloydbomni.internal.dbadmin.goog`

**Kind:** `InstanceSwitchover` · **API Version:** `alloydbomni.internal.dbadmin.goog/v1`

**Internal — do not create or modify directly.** The per-instance workflow for a planned switchover, created in response to a public `Switchover`. Executes the graceful handoff: confirms standby WAL sync, pauses writes on primary, promotes standby, demotes old primary, restores replication.

```yaml
# Internal resource — managed by the operator
apiVersion: alloydbomni.internal.dbadmin.goog/v1
kind: InstanceSwitchover
metadata:
  name: instanceswitchover-sample
  namespace: my-db-project
```

**Status fields:** `state`, `phase`, `startTime`, `endTime`, `conditions[]`, `criticalIncidents[]`

---

### 15. `instanceuserdefinedauthentications.alloydbomni.internal.dbadmin.goog`

**Kind:** `InstanceUserDefinedAuthentication` · **API Version:** `alloydbomni.internal.dbadmin.goog/v1`

**Internal — do not create or modify directly.** Propagates Kerberos/AD authentication config from the public `UserDefinedAuthentication` to each individual instance pod. The local-controller-manager updates `pg_hba.conf`, `pg_ident.conf`, installs the keytab file, and applies LDAP group-mapping settings.

```yaml
# Internal resource — managed by the operator
apiVersion: alloydbomni.internal.dbadmin.goog/v1
kind: InstanceUserDefinedAuthentication
metadata:
  name: instanceuserdefinedauth-sample
  namespace: my-db-project
```

**Status fields:** `state`, `conditions[]`, `criticalIncidents[]`, `reconciled`

---

### 16. `lrojobs.alloydbomni.internal.dbadmin.goog`

**Kind:** `LROJob` · **API Version:** `alloydbomni.internal.dbadmin.goog/v1`

> **Note:** Appears as `1rojobs` in OCR-scanned outputs — corrected to `lrojobs` (Long Running Operation Jobs).

**Internal — do not create or modify directly.** Generic async workflow tracker for **Long Running Operations** (LROs). Rather than blocking the reconciliation loop, the operator spawns an `LROJob` for any multi-step async operation — cluster provisioning, major version upgrades, instance scaling, or complex recovery workflows. The local-controller-manager drives the job through its state machine and reports progress back via the status subresource. Jobs are retained briefly after completion for auditability before garbage collection.

**On-prem OpenShift:** `LROJob` objects are your first place to look when a `DBCluster` is stuck in `Provisioning` or an upgrade appears stalled — they surface the exact step and error message.

```yaml
# Internal resource — managed by the operator
apiVersion: alloydbomni.internal.dbadmin.goog/v1
kind: LROJob
metadata:
  name: lrojob-sample
  namespace: my-db-project
spec:
  # operationType: e.g. ClusterProvision, InstanceUpgrade, PITRRestore
  # ownerRef: reference to the triggering resource
  # attemptNumber: int
```

**Status fields:** `phase` (`Pending` | `Running` | `Succeeded` | `Failed`), `startTime`, `endTime`, `operationType`, `conditions[]`, `criticalIncidents[]`, `reconciled`

---

### 17. `pgbouncers.alloydbomni.dbadmin.goog`

**Kind:** `PgBouncer` · **API Version:** `alloydbomni.dbadmin.goog/v1`

Deploys and manages a [PgBouncer](https://www.pgbouncer.org/) connection pooler for a `DBCluster`. Supports read-write (`rw`) or read-only (`ro`) modes, multiple replicas, and TLS for encrypted connections.

**On-prem OpenShift notes:**
- Use `type: ClusterIP` — cloud load balancers are not available. Expose PgBouncer externally via an OpenShift Route (passthrough TLS) or MetalLB.
- Remove any `cloud.google.com/` annotations — they have no effect on-prem.
- Mirror the PgBouncer image to your internal registry and update `podSpec.image` accordingly.
- SCC must allow the PgBouncer container's UID.

**Spec:**

```yaml
apiVersion: alloydbomni.dbadmin.goog/v1
kind: PgBouncer
metadata:
  name: my-pgbouncer
  namespace: my-db-project
spec:
  dbclusterRef: "my-dbcluster"          # (required) Target DBCluster
  accessMode: rw                         # (optional) "rw" | "ro", default ro
  replicaCount: 2                        # (optional) Number of PgBouncer replicas
  allowSuperUserAccess: false
  parameters:
    pool_mode: "transaction"
    max_client_conn: "1000"
    default_pool_size: "20"
    min_pool_size: "5"
    server_tls_sslmode: "require"        # Enforce TLS to backend DB
  podSpec:
    image: "<internal-registry>/alloydb-omni/release/pgbouncer:latest"
    resources:
      requests:
        cpu: "250m"
        memory: "256Mi"
      limits:
        cpu: "1"
        memory: "512Mi"
    schedulingConfig:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
                - key: node-role.kubernetes.io/worker
                  operator: Exists
      tolerations: []
  serviceOptions:
    type: ClusterIP                      # On-prem: ClusterIP; expose via Route or MetalLB
    # type: LoadBalancer                 # Use only if MetalLB operator is installed
    annotations: {}                      # No cloud-specific annotations on-prem
  serverTLS:
    certSecretRef:
      name: pgbouncer-tls-secret
```

**Expose PgBouncer externally via OpenShift Route:**

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: my-pgbouncer-route
  namespace: my-db-project
spec:
  port:
    targetPort: 5432
  tls:
    termination: passthrough
  to:
    kind: Service
    name: my-pgbouncer
```

**Status fields:** `ipAddress`, `phase` (`WaitingForDeploymentReady` | `AcquiringIP` | `Ready`)

---

### 18. `replicationconfigs.alloydbomni.internal.dbadmin.goog`

**Kind:** `ReplicationConfig` · **API Version:** `alloydbomni.internal.dbadmin.goog/v1`

**Internal — do not create or modify directly.** Stores resolved replication settings for each instance, derived from a public `Replication` resource or from the DBCluster's HA standby config. The local-controller-manager reads this to configure `pg_hba.conf`, `postgresql.auto.conf`, and replication slots on the PostgreSQL instance.

```yaml
# Internal resource — managed by the operator
apiVersion: alloydbomni.internal.dbadmin.goog/v1
kind: ReplicationConfig
metadata:
  name: replicationconfig-sample
  namespace: my-db-project
spec:
  # Derived from Replication spec:
  # upstreamHost, replicationSlotName, username, synchronous mode
```

**Status fields:** `conditions[]`, `downstreamStatus.setupStrategy`, `upstreamStatus.host`, `upstreamStatus.replicationSlotName`, `criticalIncidents[]`

---

### 19. `replications.alloydbomni.dbadmin.goog`

**Kind:** `Replication` · **API Version:** `alloydbomni.dbadmin.goog/v1`

Configures streaming replication between a downstream `DBCluster` and an upstream PostgreSQL database. Supports **physical replication** (full cluster copy, for DR) and **logical replication** (selective sync). Credentials are stored in OpenShift Secrets.

**On-prem use case:** Replicate between two on-prem OpenShift clusters (primary data centre → DR site), or from an existing on-prem PostgreSQL instance into AlloyDB Omni.

**Spec:**

```yaml
apiVersion: alloydbomni.dbadmin.goog/v1
kind: Replication
metadata:
  name: my-replication
  namespace: my-db-project
spec:
  dbcluster:
    name: "my-downstream-dbcluster"
  downstream:
    control: setup                        # (required) "setup" | "promote" | "rewind"
    host: "10.10.1.50"                    # On-prem upstream DB IP or hostname
    port: 5432
    username: "replicator"
    password:
      name: replication-secret            # OCP Secret in same namespace
    replicationslotname: "slot_primary"
  upstream:
    username: "standby_user"              # Auto-generated if omitted
    password:
      name: upstream-secret
    replicationslotname: "slot_standby"   # Auto-generated if omitted
    applicationName: "my-dr-standby"
    synchronous: "false"                  # Set "true" for zero-RPO (impacts latency)
    logReplicationSlot: false
    logicalReplication:                   # Omit for physical replication
      plugin: "pgoutput"
      database: "mydb"
```

**Status fields:** `conditions[]`, `downstreamStatus.setupStrategy.state`, `downstreamStatus.setupStrategy.retries`, `upstreamStatus.host`, `upstreamStatus.replicationSlotName`, `criticalIncidents[]`

---

### 20. `restores.alloydbomni.dbadmin.goog`

**Kind:** `Restore` · **API Version:** `alloydbomni.dbadmin.goog/v1`

Initiates a database restore. Can restore from a named `Backup` (full/incremental chain) or to a specific `pointInTime` using WAL replay. A PITR restore always creates a new `DBCluster`. Specify either `backup` **or** `pointInTime`, not both.

**On-prem:** Ensure the `BackupPlan` had `PITREnabled: true` and a valid S3/local repository for PITR restores. The new cluster created by PITR will need its own PVCs — verify sufficient storage capacity before initiating.

**Spec:**

```yaml
# Option A — Restore from a named Backup
apiVersion: alloydbomni.dbadmin.goog/v1
kind: Restore
metadata:
  name: restore-from-backup
  namespace: my-db-project
spec:
  sourceDBCluster: "my-dbcluster"
  backup: "manual-backup-20260329"       # Name of Backup object

---

# Option B — Point-in-time restore (creates a new DBCluster)
apiVersion: alloydbomni.dbadmin.goog/v1
kind: Restore
metadata:
  name: restore-pitr
  namespace: my-db-project
spec:
  sourceDBCluster: "my-dbcluster"
  pointInTime: "2026-03-29T10:00:00Z"    # ISO 8601 UTC timestamp
  clonedDBClusterConfig:
    dbclusterName: "my-dbcluster-restored"  # (required) Name of the new DBCluster
```

**Status fields:** `phase`, `createTime`, `completeTime`, `conditions[]`, `criticalIncidents[]`, `reconciled`

---

### 21. `sidecars.alloydbomni.dbadmin.goog` (Public)

**Kind:** `Sidecar` · **API Version:** `alloydbomni.dbadmin.goog/v1`

Injects custom sidecar containers into the database pod. Common on-prem use cases: log shipping to Splunk/ELK, Prometheus exporters, audit log collectors, or corporate security agents.

**On-prem OpenShift notes:**
- Sidecar containers share the pod's SCC. If your sidecar requires a different UID than the DB pod, you may need to explicitly set `runAsUser` and ensure the SCC permits it.
- Use images from your internal mirror registry, not public Docker Hub.
- OpenShift's default SCC (`restricted-v2`) disallows privilege escalation — set `allowPrivilegeEscalation: false` and `runAsNonRoot: true` in `securityContext`.

**Spec:**

```yaml
apiVersion: alloydbomni.dbadmin.goog/v1
kind: Sidecar
metadata:
  name: my-log-shipper
  namespace: my-db-project
spec:
  additionalVolumes:
    - name: shared-logs
      emptyDir: {}
  sidecars:
    - name: log-shipper
      image: "<internal-registry>/fluent/fluent-bit:latest"
      imagePullPolicy: IfNotPresent
      command: ["/fluent-bit/bin/fluent-bit"]
      args: ["-c", "/etc/fluent-bit/config.conf"]
      env:
        - name: LOG_LEVEL
          value: "info"
        - name: SPLUNK_HOST
          value: "splunk-hec.internal.corp:8088"
        - name: DB_HOST
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
      resources:
        requests:
          cpu: "100m"
          memory: "128Mi"
        limits:
          cpu: "200m"
          memory: "256Mi"
      volumeMounts:
        - name: shared-logs
          mountPath: /var/log/db
      livenessProbe:
        exec:
          command: ["pgrep", "fluent-bit"]
        initialDelaySeconds: 10
        periodSeconds: 30
      securityContext:
        runAsNonRoot: true             # Required for OpenShift restricted-v2 SCC
        allowPrivilegeEscalation: false
        runAsUser: 1000                # Must be within namespace UID range
        capabilities:
          drop: ["ALL"]
```

**Status fields:** *(Managed implicitly via pod status — no separate CRD status subresource)*

---

### 22. `sidecars.alloydbomni.internal.dbadmin.goog` (Internal)

**Kind:** `Sidecar` · **API Version:** `alloydbomni.internal.dbadmin.goog/v1`

**Internal — do not create or modify directly.** The internal representation of a sidecar configuration scoped to a specific `Instance`. Created by the fleet-controller-manager from the public `Sidecar` resource and consumed by the local-controller-manager to patch the pod spec of individual database pods.

---

### 23. `switchovers.alloydbomni.dbadmin.goog`

**Kind:** `Switchover` · **API Version:** `alloydbomni.dbadmin.goog/v1`

Triggers a **planned, graceful role switch**. Unlike a failover, a switchover confirms the standby has fully replicated the primary's WAL before promoting — zero data loss. Use for planned maintenance windows, node drains, or rolling upgrades.

**On-prem tip:** Before a switchover, cordon the primary's worker node (`oc adm cordon <node>`) to prevent the old primary from being re-scheduled there immediately after demotion.

**Spec:**

```yaml
apiVersion: alloydbomni.dbadmin.goog/v1
kind: Switchover
metadata:
  name: switchover-maintenance
  namespace: my-db-project
spec:
  dbclusterRef: "my-dbcluster"
  newPrimary: "my-dbcluster-standby-0"   # (optional) Standby to promote; auto-selected if omitted
  primaryHost: "10.10.1.50"              # (optional) IP that always resolves to current primary
```

```bash
# Trigger switchover
oc apply -f switchover.yaml -n my-db-project

# Monitor until Success
oc get switchover switchover-maintenance -n my-db-project -w
```

**Status fields:** `state` (`InProgress` | `Success` | `Failed_RollbackInProgress` | `Failed_RollbackSuccess` | `Failed_RollbackFailed`), `startTime`, `endTime`, `createTime`, `conditions[]`, `criticalIncidents[]`, `internal.oldPrimary`, `internal.newPrimary`

---

### 24. `tdeconfigs.alloydbomni.dbadmin.goog`

**Kind:** `TDEConfig` · **API Version:** `alloydbomni.dbadmin.goog/v1`

Configures **Transparent Data Encryption (TDE)** for a `DBCluster`. All data files, WAL segments, and temporary files are encrypted at rest using AES-256. Key material is managed through an external KMS.

**On-prem OpenShift:** Google Cloud KMS is **not available** on-premises. Use **HashiCorp Vault** (widely deployed in enterprise on-prem environments) or a **PKCS#11-compatible HSM** (e.g., Thales, Utimaco, nCipher). HashiCorp Vault is the most common choice in OpenShift environments.

**Spec (HashiCorp Vault — recommended for on-prem):**

```yaml
apiVersion: alloydbomni.dbadmin.goog/v1
kind: TDEConfig
metadata:
  name: my-tdeconfig
  namespace: my-db-project
spec:
  dbclusterRef: "my-dbcluster"
  keyManagementServiceSpec:
    serviceType: Vault                    # Use Vault on-prem (not GoogleCloudKMS)
    vaultSpec:
      address: "https://vault.internal.corp:8200"
      keyPath: "secret/data/alloydb/tde-key"
      tokenSecretRef:
        name: vault-token-secret          # OCP Secret with 'token' key
      # OR use Kubernetes auth method (preferred for OpenShift):
      # kubernetesAuthPath: "auth/kubernetes"
      # role: "alloydb-omni-tde"
      caCertSecretRef:
        name: vault-ca-cert              # OCP Secret with Vault CA cert (if self-signed)
```

**Vault policy required:**

```hcl
# Vault policy: allow AlloyDB Omni to read/write the TDE key
path "secret/data/alloydb/tde-key" {
  capabilities = ["create", "read", "update"]
}
```

**Vault Kubernetes auth setup (on OpenShift):**

```bash
# Enable Kubernetes auth in Vault
vault auth enable kubernetes

# Configure with OCP service account JWT
vault write auth/kubernetes/config \
  kubernetes_host="https://api.<ocp-cluster>:6443" \
  kubernetes_ca_cert=@/path/to/ocp-ca.crt

# Create role bound to alloydb-omni service account
vault write auth/kubernetes/role/alloydb-omni-tde \
  bound_service_account_names=alloydb-omni-sa \
  bound_service_account_namespaces=alloydb-omni-system \
  policies=alloydb-tde-policy \
  ttl=1h
```

**Status fields:** `phase`, `conditions[]`, `criticalIncidents[]`, `reconciled`

---

### 25. `userdefinedauthentications.alloydbomni.dbadmin.goog`

**Kind:** `UserDefinedAuthentication` · **API Version:** `alloydbomni.dbadmin.goog/v1`

Configures **Kerberos / Active Directory** authentication for a `DBCluster`. Applies custom `pg_hba.conf` rules, mounts a Kerberos keytab, and optionally configures LDAP-based AD group mapping. Highly applicable in on-prem enterprise environments with existing AD/LDAP infrastructure.

**On-prem OpenShift notes:**
- The keytab Secret must be created in the same namespace (project) as the DBCluster.
- Use your internal AD/LDAP server hostname — no dependency on cloud identity providers.
- LDAPS certificate must be trusted; provide the internal CA bundle via `ldapsCertificateSecretRef`.

**Spec:**

```yaml
apiVersion: alloydbomni.dbadmin.goog/v1
kind: UserDefinedAuthentication
metadata:
  name: my-ad-auth
  namespace: my-db-project
spec:
  dbclusterRef:
    name: "my-dbcluster"
  keytabSecretRef:
    name: kerberos-keytab-secret          # OCP Secret with key 'krb5.keytab'
  pgHbaEntries:                           # pg_hba.conf lines
    - "host all all 0.0.0.0/0 gss include_realm=0 krb_realm=CORP.INTERNAL"
    - "host all all ::0/0    gss include_realm=0 krb_realm=CORP.INTERNAL"
  pgIdentEntries:                         # pg_ident.conf user-name maps (optional)
    - "admap  /^(.*)@CORP\\.INTERNAL$  \\1"
  ldapConfiguration:                      # AD group sync via LDAP (optional)
    enableGroupMapping: true
    ldapURI: "ldaps://ad.corp.internal:636"
    ldapBaseDN: "DC=corp,DC=internal"
    ldapBindDN: "CN=svc-alloydb,OU=ServiceAccounts,DC=corp,DC=internal"
    ldapBindPasswordSecretRef:
      name: ldap-bind-secret              # OCP Secret with 'password' key
    ldapsCertificateSecretRef:
      name: internal-ca-cert              # OCP Secret with 'ca.crt' key (internal CA)
    cacheTTLSeconds: 300
    enableLdapOptReferrals: false
```

**Create the keytab secret:**

```bash
# Generate keytab for the AlloyDB Omni service principal on your AD server
# Then load it into OpenShift as a secret
oc create secret generic kerberos-keytab-secret \
  --from-file=krb5.keytab=/path/to/postgres.keytab \
  -n my-db-project
```

**Status fields:** `state` (`Processing` | `Ready` | `Failed` | `Unknown`), `message`, `conditions[]`, `criticalIncidents[]`, `observedGeneration`, `reconciled`

---

## Quick Reference: Failover vs Switchover

| Attribute | `Failover` | `Switchover` |
|---|---|---|
| Use case | Primary is down / unresponsive | Planned maintenance / upgrade / node drain |
| Data safety | Possible data loss if WAL not synced | Zero data loss (WAL sync confirmed) |
| Speed | Faster (no wait for sync) | Slightly slower (waits for WAL flush) |
| Rollback | Attempted automatically on failure | Attempted automatically on failure |
| Trigger | `oc apply -f failover.yaml` | `oc apply -f switchover.yaml` |

---

## Quick Reference: Public vs Internal CRDs

| Type | API Group | Created by | Modified by | When to inspect |
|---|---|---|---|---|
| **Public** | `alloydbomni.dbadmin.goog` | Users / GitOps / ArgoCD | Users / fleet-controller | Day-to-day operations |
| **Internal** | `alloydbomni.internal.dbadmin.goog` | fleet/local-controller | Operator only | Debugging / troubleshooting only |

> **Never modify internal resources directly** — changes will be overwritten immediately by the operator.

---

## Quick Reference: On-Prem Storage Selection

| Disk Type | Recommended StorageClass | Notes |
|---|---|---|
| `DataDisk` | `ocs-storagecluster-ceph-rbd` / `thin-csi` | Must be RWO; high IOPS |
| `LogDisk` | `ocs-storagecluster-ceph-rbd` / `thin-csi` | Sequential writes; separate from DataDisk |
| `BackupDisk` | `ocs-storagecluster-ceph-rbd` / `nfs-csi` | Can use NFS; or omit and use S3 `backupLocation` |
| `ObsDisk` | `ocs-storagecluster-ceph-rbd` | Observability/metrics scratch space |

---

## Common OpenShift (`oc`) Commands

```bash
# Use 'oc' or 'kubectl' interchangeably — oc is preferred on OpenShift
# Switch to your database project
oc project my-db-project

# List all AlloyDB Omni CRDs installed on the cluster
oc get crds | grep alloydbomni

# --- DBCluster operations ---
oc get dbcluster -n my-db-project
oc describe dbcluster my-dbcluster -n my-db-project
oc get dbcluster my-dbcluster -n my-db-project -o jsonpath='{.status.phase}'

# --- Backup operations ---
oc get backupplan -n my-db-project
oc describe backupplan my-backupplan -n my-db-project
oc apply -f manual-backup.yaml -n my-db-project
oc get backup -n my-db-project -w

# --- HA operations ---
oc apply -f switchover.yaml -n my-db-project
oc get switchover -n my-db-project -w
oc apply -f failover.yaml -n my-db-project
oc get failover -n my-db-project -w

# --- Restore ---
oc apply -f restore-pitr.yaml -n my-db-project
oc get restore -n my-db-project -w

# --- Inspect internal workflow objects (for troubleshooting) ---
oc get createstandbyjobs -n my-db-project
oc get deletestandbyjobs -n my-db-project
oc get lrojobs -n my-db-project
oc get instances.alloydbomni.internal.dbadmin.goog -n my-db-project
oc get instancebackups -n my-db-project
oc get replicationconfigs -n my-db-project

# --- Operator logs ---
oc logs -n alloydb-omni-system deployment/fleet-controller-manager --tail=100
oc logs -n alloydb-omni-system deployment/local-controller-manager --tail=100
oc logs -n alloydb-omni-system deployment/fleet-controller-manager -f

# --- OpenShift-specific: check SCC violations ---
oc get events -n my-db-project | grep -i scc
oc get events -n my-db-project | grep -i "unable to validate"

# --- OpenShift-specific: verify image pull from internal registry ---
oc get events -n my-db-project | grep -i "imagepull"
oc describe pod <db-pod-name> -n my-db-project | grep -A5 "Events:"

# --- Check PVC binding (storage) ---
oc get pvc -n my-db-project
oc describe pvc <pvc-name> -n my-db-project

# --- Check Routes ---
oc get route -n my-db-project
```

---

## References

- [AlloyDB Omni for Kubernetes — current docs](https://docs.cloud.google.com/alloydb/omni/kubernetes/current/docs)
- [BackupPlan CRD v1.5.0 reference](https://docs.cloud.google.com/alloydb/omni/kubernetes/current/docs/reference/kubernetes-crds-1.5.0/backupplan)
- [Back up and restore in Kubernetes](https://docs.cloud.google.com/alloydb/omni/kubernetes/current/docs/backup-kubernetes)
- [Configuration samples](https://docs.cloud.google.com/alloydb/omni/kubernetes/current/docs/samples)
- [Troubleshoot the Kubernetes operator](https://docs.cloud.google.com/alloydb/omni/kubernetes/16.9.0/docs/troubleshoot-kubernetes-operator)
- [KRM API reference (GDC air-gapped)](https://cloud.google.com/distributed-cloud/hosted/docs/latest/gdch/apis/service/dbs/v1/alloydbomni-v1)
- [OpenShift Security Context Constraints](https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html)
- [OpenShift Image Mirror Sets](https://docs.openshift.com/container-platform/latest/openshift_images/image-configuration.html)
- [MetalLB Operator on OpenShift](https://docs.openshift.com/container-platform/latest/networking/metallb/about-metallb.html)
- [OpenShift Data Foundation (ODF)](https://access.redhat.com/documentation/en-us/red_hat_openshift_data_foundation)
