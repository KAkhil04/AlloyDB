# AlloyDB Omni Kubernetes CRD Reference

**Operator Version:** fleet-controller-manager & local-controller-manager `v1.6.0`
**AlloyDB Omni Version:** `v17.5.0`
**API Groups:** `alloydbomni.dbadmin.goog/v1` · `alloydbomni.internal.dbadmin.goog/v1`

---

## Architecture Overview

The AlloyDB Omni Kubernetes operator deploys two controllers in the `alloydb-omni-system` namespace:

| Controller | Role |
|---|---|
| **fleet-controller-manager** | Handles public-facing CRDs (`alloydbomni.dbadmin.goog`). Reconciles user-intent resources such as `DBCluster`, `BackupPlan`, `Failover`, `Replication`, etc. |
| **local-controller-manager** | Handles internal CRDs (`alloydbomni.internal.dbadmin.goog`). Manages low-level per-instance workflows: standby jobs, instance backup/restore, LRO jobs, replication configs, and instance lifecycle. |

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

Defines automated backup schedules (full, differential, incremental) and retention policy for a `DBCluster`. The fleet-controller-manager reads this resource and reconciles `InstanceBackupPlan` objects for each backing instance. Internally uses pgBackRest.

**Spec:**

```yaml
spec:
  dbclusterRef: "my-dbcluster"        # (required, immutable) Target DBCluster name
  backupRetainDays: 14                 # (optional) Retention in days, range 1–90, default 14
  paused: false                        # (optional) Suspend scheduling without deleting plan
  PITREnabled: false                   # (optional) Enable point-in-time recovery
  backupSourceStrategy: primary        # (optional) "primary" | "standby", default primary
  backupSchedules:
    full: "0 0 * * 0"                 # (optional) Cron: full backup — weekly Sunday midnight
    differential: "0 2 * * 1-6"       # (optional) Cron: differential backup
    incremental: "0 21 * * *"         # (optional) Cron: incremental — daily 21:00
  backupLocation:                      # (optional) Remote storage; omit for local storage
    type: GCS                          # "GCS" | "S3"
    gcsOptions:
      bucket: "my-backup-bucket"
      key: "alloydb/backups/"
      secretRef:
        name: gcs-secret
        namespace: default
    # OR
    s3Options:
      bucket: "my-s3-bucket"
      key: "alloydb/backups/"
      endpoint: "https://s3.amazonaws.com"
      region: "us-east-1"
      caBundle: "<PEM string>"
      secretRef:
        name: s3-secret
        namespace: default
```

**Status fields:** `phase`, `lastBackupTime`, `nextBackupTime`, `recoveryWindow.begin/end`, `conditions[]`, `criticalIncidents[]`, `reconciled`, `observedGeneration`

---

### 2. `backuprepositories.alloydbomni.internal.dbadmin.goog`

**Kind:** `BackupRepository` · **API Version:** `alloydbomni.internal.dbadmin.goog/v1`

**Internal — do not create or modify directly.** Generated by the fleet-controller-manager from a `BackupPlan`. Represents the pgBackRest repository configuration (`repo1`, `repo2`, etc.) on the individual database instance. Consumed by the local-controller-manager to configure the pgBackRest stanza on each instance.

```yaml
# Internal resource — managed by the operator
apiVersion: alloydbomni.internal.dbadmin.goog/v1
kind: BackupRepository
metadata:
  name: backuprepository-sample
spec:
  # Derived from BackupPlan.spec.backupLocation
  # Contains repository type, path, storage credentials
```

**Status fields:** `phase`, `conditions[]`, `reconciled`

---

### 3. `backups.alloydbomni.dbadmin.goog`

**Kind:** `Backup` · **API Version:** `alloydbomni.dbadmin.goog/v1`

Represents a single backup execution — either created automatically by a `BackupPlan` schedule or triggered manually by the user. Tracks lifecycle from creation through completion and expiry.

**Spec:**

```yaml
spec:
  dbclusterRef: "my-dbcluster"        # (required) Target DBCluster
  backupPlanRef: "my-backupplan"      # (required) Parent BackupPlan
  manual: false                        # (optional) true = manually triggered, default false
  backupSourceRole: primary            # (optional) "primary" | "standby"
  physicalbackupSpec:
    backuptype: full                   # (optional) "full" | "differential" | "incremental"
```

**Trigger a manual backup:**

```yaml
apiVersion: alloydbomni.dbadmin.goog/v1
kind: Backup
metadata:
  name: manual-backup-20260329
spec:
  dbclusterRef: my-dbcluster
  backupPlanRef: my-backupplan
  manual: true
  physicalbackupSpec:
    backuptype: full
```

**Status fields:** `phase`, `createTime`, `completeTime`, `retainExpireTime`, `physicalbackupStatus.backupId`, `conditions[]`, `criticalIncidents[]`, `reconciled`

---

### 4. `createstandbyjobs.alloydbomni.internal.dbadmin.goog`

**Kind:** `CreateStandbyJob` · **API Version:** `alloydbomni.internal.dbadmin.goog/v1`

**Internal — do not create or modify directly.** Workflow tracking object created by the local-controller-manager when a new standby instance needs to be initialised (e.g., when a `DBCluster` increases its `availability.standbys` count). Tracks multi-step provisioning: volume creation, base backup, WAL catchup, and readiness verification.

```yaml
# Internal resource — managed by the operator
apiVersion: alloydbomni.internal.dbadmin.goog/v1
kind: CreateStandbyJob
metadata:
  name: createstandbyjob-sample
spec:
  # WorkflowSpec: contains instanceRef, phase, attempt counter
```

**Status fields:** `state` (`InProgress` | `Succeeded` | `Failed`), `phase`, `startTime`, `endTime`, `conditions[]`, `criticalIncidents[]`

---

### 5. `dbclusters.alloydbomni.dbadmin.goog`

**Kind:** `DBCluster` · **API Version:** `alloydbomni.dbadmin.goog/v1`

The **primary user-facing resource**. Declares a complete PostgreSQL cluster including the primary instance, optional standbys for HA, compute resources, disk layout, TLS configuration, and database parameters. All other resources (DBInstance, BackupPlan, Replication, etc.) reference this resource.

**Spec:**

```yaml
spec:
  databaseVersion: "17.5.0"               # (required) PostgreSQL version
  controlPlaneAgentsVersion: "1.6.0"      # (required) Operator control agent version
  primarySpec:
    adminUser:
      passwordRef:
        name: db-admin-secret              # K8s Secret containing 'password' key
    resources:
      cpu: "4"
      memory: "16Gi"
      disks:
        - name: DataDisk
          size: "100Gi"
          storageClass: standard-rwo
        - name: LogDisk
          size: "20Gi"
        - name: BackupDisk
          size: "50Gi"
        - name: ObsDisk
          size: "10Gi"
    databaseParameters:
      max_connections: "200"
      work_mem: "64MB"
    services:
      primary:
        type: LoadBalancer
  availability:
    standbys: 1                            # Number of HA standby replicas
    autoFailover: true
  mode: ""                                 # "" (default) | "disasterRecovery"
  allowExternalIncomingTraffic: true
  tls:
    certSecretRef:
      name: my-tls-secret
  isDeleted: false                         # Set true to trigger cluster deletion
```

**Status fields:** `phase`, `primary.endpoint`, `primary.version`, `conditions[]`, `latestFailoverStatus`, `certificateReference`, `registrationStatus`, `restoredFrom`, `criticalIncidents[]`

---

### 6. `dbinstances.alloydbomni.dbadmin.goog`

**Kind:** `DBInstance` · **API Version:** `alloydbomni.dbadmin.goog/v1`

Defines an additional instance group (e.g., a **read pool**) attached to an existing `DBCluster`. Allows horizontal scale-out of read traffic independently from the primary. Each `DBInstance` spawns one or more `DBNode` pods managed by the local-controller-manager.

**Spec:**

```yaml
spec:
  nodeCount: 2                            # (required) Number of nodes in this instance group
  instanceType: ReadPool                  # Currently supports "ReadPool"
  dbcParent: "my-dbcluster"              # (optional) DBCluster this instance replicates from
  isStopped: false                        # (optional) Pause all nodes in this instance
  progressTimeout: 600                    # (optional) Provisioning timeout in seconds
  resources:
    cpu: "2"
    memory: "8Gi"
    disks:
      - name: DataDisk
        size: "50Gi"
        storageClass: standard-rwo
      - name: LogDisk
        size: "10Gi"
  schedulingConfig:
    nodeAffinity: {}
    podAntiAffinity: {}
    tolerations: []
```

**Status fields:** `conditions[]`, `endpoints[]`, `criticalIncidents[]`, `reconciled`, `observedGeneration`

---

### 7. `deletestandbyjobs.alloydbomni.internal.dbadmin.goog`

**Kind:** `DeleteStandbyJob` · **API Version:** `alloydbomni.internal.dbadmin.goog/v1`

**Internal — do not create or modify directly.** Mirror of `CreateStandbyJob` for the teardown path. Created automatically when the `DBCluster` decreases its standby count or a standby is being decommissioned. Manages orderly shutdown, replication slot cleanup, and storage release.

```yaml
# Internal resource — managed by the operator
apiVersion: alloydbomni.internal.dbadmin.goog/v1
kind: DeleteStandbyJob
metadata:
  name: deletestandbyjob-sample
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
spec:
  dbclusterRef: "my-dbcluster"           # (required) Target cluster (same namespace)
  newPrimary: "my-dbcluster-standby-0"   # (optional) Specific standby to promote;
                                          # omit to let the operator auto-select
```

**Status fields:** `state` (`InProgress` | `Success` | `Failed_RollbackInProgress` | `Failed_RollbackSuccess` | `Failed_RollbackFailed`), `startTime`, `endTime`, `createTime`, `conditions[]`, `criticalIncidents[]`, `internal.oldPrimary`, `internal.newPrimary`, `internal.attemptNumber`

---

### 9. `failovers.alloydbomni.internal.dbadmin.goog` (Internal)

**Kind:** `Failover` · **API Version:** `alloydbomni.internal.dbadmin.goog/v1`

**Internal — do not create or modify directly.** The low-level state machine created by the fleet-controller-manager in response to a public `Failover` resource. The local-controller-manager executes the per-instance steps: fencing the old primary, promoting the standby, updating replication configs, and health-checking the new primary.

```yaml
# Internal resource — managed by the operator
apiVersion: alloydbomni.internal.dbadmin.goog/v1
kind: Failover
metadata:
  name: failover-internal-sample
```

**Status fields:** `state`, `phase`, `startTime`, `endTime`, `conditions[]`, `criticalIncidents[]`

---

### 10. `instancebackupplans.alloydbomni.internal.dbadmin.goog`

**Kind:** `InstanceBackupPlan` · **API Version:** `alloydbomni.internal.dbadmin.goog/v1`

**Internal — do not create or modify directly.** Created automatically for each instance covered by a public `BackupPlan`. Carries the resolved backup schedule (cron strings), retention, and storage config down to the local-controller-manager, which configures pgBackRest on that specific pod.

```yaml
# Internal resource — managed by the operator
apiVersion: alloydbomni.internal.dbadmin.goog/v1
kind: InstanceBackupPlan
metadata:
  name: instancebackupplan-sample
spec:
  # Derived from BackupPlan — full/incremental/differential schedules, retention, storageRef
```

**Status fields:** `phase`, `lastBackupTime`, `nextBackupTime`, `conditions[]`, `reconciled`

---

### 11. `instancebackups.alloydbomni.internal.dbadmin.goog`

**Kind:** `InstanceBackup` · **API Version:** `alloydbomni.internal.dbadmin.goog/v1`

**Internal — do not create or modify directly.** Represents the execution of a single backup job on a specific instance. Created by the local-controller-manager when a schedule fires or a manual `Backup` is requested. Tracks pgBackRest job progress (stanza init, backup run, catalog update).

```yaml
# Internal resource — managed by the operator
apiVersion: alloydbomni.internal.dbadmin.goog/v1
kind: InstanceBackup
metadata:
  name: instancebackup-sample
```

**Status fields:** `phase`, `createTime`, `completeTime`, `backupId`, `conditions[]`, `criticalIncidents[]`

---

### 12. `instancerestores.alloydbomni.internal.dbadmin.goog`

**Kind:** `InstanceRestore` · **API Version:** `alloydbomni.internal.dbadmin.goog/v1`

**Internal — do not create or modify directly.** Tracks the restore operation on a specific database instance, created in response to a public `Restore` resource. Manages pgBackRest restore execution, WAL replay to the target time, and instance readiness signalling.

```yaml
# Internal resource — managed by the operator
apiVersion: alloydbomni.internal.dbadmin.goog/v1
kind: InstanceRestore
metadata:
  name: instancerestore-sample
```

**Status fields:** `phase`, `createTime`, `completeTime`, `conditions[]`, `criticalIncidents[]`, `reconciled`

---

### 13. `instances.alloydbomni.internal.dbadmin.goog`

**Kind:** `Instance` · **API Version:** `alloydbomni.internal.dbadmin.goog/v1`

**Internal — do not create or modify directly.** The low-level representation of a single database pod (primary or standby). The local-controller-manager creates, updates, and deletes these objects as `DBCluster` topology changes. Carries pod scheduling, resource allocation, and connectivity info at the node level.

```yaml
# Internal resource — managed by the operator
apiVersion: alloydbomni.internal.dbadmin.goog/v1
kind: Instance
metadata:
  name: my-dbcluster-primary-0
```

**Status fields:** `phase`, `endpoint`, `role` (`primary` | `standby`), `conditions[]`, `criticalIncidents[]`, `reconciled`

---

### 14. `instanceswitchovers.alloydbomni.internal.dbadmin.goog`

**Kind:** `InstanceSwitchover` · **API Version:** `alloydbomni.internal.dbadmin.goog/v1`

**Internal — do not create or modify directly.** The per-instance workflow object for a planned switchover, created in response to a public `Switchover`. Executes the graceful handoff: confirms standby is caught up, pauses writes on primary, promotes standby, demotes old primary to standby, and restores replication.

```yaml
# Internal resource — managed by the operator
apiVersion: alloydbomni.internal.dbadmin.goog/v1
kind: InstanceSwitchover
metadata:
  name: instanceswitchover-sample
```

**Status fields:** `state`, `phase`, `startTime`, `endTime`, `conditions[]`, `criticalIncidents[]`

---

### 15. `instanceuserdefinedauthentications.alloydbomni.internal.dbadmin.goog`

**Kind:** `InstanceUserDefinedAuthentication` · **API Version:** `alloydbomni.internal.dbadmin.goog/v1`

**Internal — do not create or modify directly.** Propagates the Kerberos/Active Directory authentication configuration from the public `UserDefinedAuthentication` to each individual instance. The local-controller-manager updates `pg_hba.conf` and `pg_ident.conf`, installs the keytab, and applies LDAP group-mapping settings on the target pod.

```yaml
# Internal resource — managed by the operator
apiVersion: alloydbomni.internal.dbadmin.goog/v1
kind: InstanceUserDefinedAuthentication
metadata:
  name: instanceuserdefinedauth-sample
```

**Status fields:** `state`, `conditions[]`, `criticalIncidents[]`, `reconciled`

---

### 16. `lrojobs.alloydbomni.internal.dbadmin.goog`

**Kind:** `LROJob` · **API Version:** `alloydbomni.internal.dbadmin.goog/v1`

> **Note:** Appears as `1rojobs` in OCR-scanned outputs — corrected to `lrojobs` (Long Running Operation Jobs).

**Internal — do not create or modify directly.** Generic async workflow tracker for **Long Running Operations** (LROs) initiated by the AlloyDB Omni operator. Rather than blocking the reconciliation loop, the operator spawns an `LROJob` object to represent the execution of any multi-step async operation — such as cluster provisioning, major version upgrades, instance scaling, or complex recovery workflows. The local-controller-manager drives the job through its state machine and reports progress back via the status subresource.

Each `LROJob` carries a reference to the triggering resource (e.g., a `DBCluster` or `Restore`), the operation type, attempt count, and the current execution phase. When completed (successfully or not), the job is retained briefly for auditability before garbage collection.

```yaml
# Internal resource — managed by the operator
apiVersion: alloydbomni.internal.dbadmin.goog/v1
kind: LROJob
metadata:
  name: lrojob-sample
spec:
  # operationType: e.g. ClusterProvision, InstanceUpgrade, PITRRestore
  # ownerRef: reference to the triggering resource
  # attemptNumber: int
```

**Status fields:** `phase` (`Pending` | `Running` | `Succeeded` | `Failed`), `startTime`, `endTime`, `operationType`, `conditions[]`, `criticalIncidents[]`, `reconciled`

---

### 17. `pgbouncers.alloydbomni.dbadmin.goog`

**Kind:** `PgBouncer` · **API Version:** `alloydbomni.dbadmin.goog/v1`

Deploys and manages a [PgBouncer](https://www.pgbouncer.org/) connection pooler for a `DBCluster`. Routes client connections through session/transaction/statement pooling modes. Supports read-write (`rw`) or read-only (`ro`) access modes, multiple replicas, and TLS for encrypted connections to the database.

**Spec:**

```yaml
apiVersion: alloydbomni.dbadmin.goog/v1
kind: PgBouncer
metadata:
  name: my-pgbouncer
spec:
  dbclusterRef: "my-dbcluster"           # (required) Target DBCluster
  accessMode: rw                          # (optional) "rw" | "ro", default ro
  replicaCount: 2                         # (optional) Number of PgBouncer replicas
  allowSuperUserAccess: false             # (optional) Allow superuser connections
  parameters:                             # (optional) pgbouncer.ini key-value settings
    pool_mode: "transaction"
    max_client_conn: "1000"
    default_pool_size: "20"
    min_pool_size: "5"
  podSpec:
    image: "us-docker.pkg.dev/alloydb-omni/release/pgbouncer:latest"
    resources:
      requests:
        cpu: "250m"
        memory: "256Mi"
      limits:
        cpu: "1"
        memory: "512Mi"
    schedulingConfig:
      nodeAffinity: {}
      tolerations: []
  serviceOptions:
    type: LoadBalancer                    # "LoadBalancer" | "ClusterIP"
    annotations:
      cloud.google.com/load-balancer-type: "Internal"
    loadBalancerSourceRanges:
      - "10.0.0.0/8"
  serverTLS:
    certSecretRef:
      name: pgbouncer-tls-secret
```

**Status fields:** `ipAddress`, `phase` (`WaitingForDeploymentReady` | `AcquiringIP` | `Ready`)

---

### 18. `replicationconfigs.alloydbomni.internal.dbadmin.goog`

**Kind:** `ReplicationConfig` · **API Version:** `alloydbomni.internal.dbadmin.goog/v1`

**Internal — do not create or modify directly.** Stores the resolved replication settings for each instance — derived from a public `Replication` resource or from the DBCluster's HA standby configuration. The local-controller-manager reads this to configure `pg_hba.conf`, `recovery.conf`/`postgresql.auto.conf`, and replication slots on the PostgreSQL instance.

```yaml
# Internal resource — managed by the operator
apiVersion: alloydbomni.internal.dbadmin.goog/v1
kind: ReplicationConfig
metadata:
  name: replicationconfig-sample
spec:
  # Derived from Replication spec:
  # upstreamHost, replicationSlotName, username, synchronous mode
```

**Status fields:** `conditions[]`, `downstreamStatus.setupStrategy`, `upstreamStatus.host`, `upstreamStatus.replicationSlotName`, `criticalIncidents[]`

---

### 19. `replications.alloydbomni.dbadmin.goog`

**Kind:** `Replication` · **API Version:** `alloydbomni.dbadmin.goog/v1`

Configures streaming replication between a downstream `DBCluster` and an upstream PostgreSQL database. Supports both **physical replication** (full cluster copy, used for disaster recovery) and **logical replication** (table/database level, used for selective sync). Credentials are stored in Kubernetes Secrets.

**Spec:**

```yaml
apiVersion: alloydbomni.dbadmin.goog/v1
kind: Replication
metadata:
  name: my-replication
spec:
  dbcluster:
    name: "my-downstream-dbcluster"       # Target DBCluster for replication
  downstream:
    control: setup                         # (required) "setup" | "promote" | "rewind"
    host: "10.1.2.3"                       # (required) Upstream DB host
    port: 5432                             # (optional) default 5432
    username: "replicator"                 # (required) Replication user on upstream
    password:
      name: replication-secret             # (required) K8s Secret with password
    replicationslotname: "slot_primary"    # (required) Replication slot on upstream
  upstream:
    username: "standby_user"               # (optional) Auto-generated if not set
    password:
      name: upstream-secret                # (required) K8s Secret for upstream credentials
    replicationslotname: "slot_standby"    # (optional) Auto-generated if not set
    applicationName: "my-standby"          # (optional) Required for synchronous replication
    synchronous: "false"                   # (optional) Enables synchronous replication
    logReplicationSlot: false              # (optional) Enable WAL file writing
    logicalReplication:                    # (optional) Configure logical replication
      plugin: "pgoutput"
      database: "mydb"
```

**Status fields:** `conditions[]`, `downstreamStatus.setupStrategy.state`, `downstreamStatus.setupStrategy.retries`, `upstreamStatus.host`, `upstreamStatus.replicationSlotName`, `criticalIncidents[]`

---

### 20. `restores.alloydbomni.dbadmin.goog`

**Kind:** `Restore` · **API Version:** `alloydbomni.dbadmin.goog/v1`

Initiates a database restore operation. Can restore from a named `Backup` object (full/incremental chain) or to a specific `pointInTime` using WAL replay. A point-in-time restore always creates a new `DBCluster` (specified in `clonedDBClusterConfig`). You must specify either `backup` **or** `pointInTime`, but not both.

**Spec:**

```yaml
# Option A — Restore from a named Backup
apiVersion: alloydbomni.dbadmin.goog/v1
kind: Restore
metadata:
  name: restore-from-backup
spec:
  sourceDBCluster: "my-dbcluster"         # (required) Source cluster
  backup: "manual-backup-20260329"        # Backup object name (mutually exclusive with pointInTime)

---

# Option B — Point-in-time restore (creates a new cluster)
apiVersion: alloydbomni.dbadmin.goog/v1
kind: Restore
metadata:
  name: restore-pitr
spec:
  sourceDBCluster: "my-dbcluster"
  pointInTime: "2026-03-29T10:00:00Z"     # (optional) ISO 8601 timestamp
  clonedDBClusterConfig:
    dbclusterName: "my-dbcluster-restored" # (required with pointInTime)
```

**Status fields:** `phase`, `createTime`, `completeTime`, `conditions[]`, `criticalIncidents[]`, `reconciled`

---

### 21. `sidecars.alloydbomni.dbadmin.goog` (Public)

**Kind:** `Sidecar` · **API Version:** `alloydbomni.dbadmin.goog/v1`

Injects custom sidecar containers into the database pod of a `DBCluster`. Common use cases include log shippers, monitoring exporters, security agents, or custom health-check processes that need to run alongside the database.

**Spec:**

```yaml
apiVersion: alloydbomni.dbadmin.goog/v1
kind: Sidecar
metadata:
  name: my-log-shipper
spec:
  additionalVolumes:                       # (optional) Existing volumes to mount into sidecars
    - name: shared-logs
      emptyDir: {}
  sidecars:
    - name: log-shipper
      image: "fluent/fluent-bit:latest"
      imagePullPolicy: IfNotPresent
      command: ["/fluent-bit/bin/fluent-bit"]
      args: ["-c", "/etc/fluent-bit/config.conf"]
      env:
        - name: LOG_LEVEL
          value: "info"
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
        runAsNonRoot: true
        runAsUser: 1000
```

**Status fields:** *(Managed implicitly via pod status — no separate CRD status subresource)*

---

### 22. `sidecars.alloydbomni.internal.dbadmin.goog` (Internal)

**Kind:** `Sidecar` · **API Version:** `alloydbomni.internal.dbadmin.goog/v1`

**Internal — do not create or modify directly.** The internal representation of a sidecar configuration scoped to a specific `Instance`. Created by the fleet-controller-manager from the public `Sidecar` resource and consumed by the local-controller-manager to patch the pod spec of individual database pods.

---

### 23. `switchovers.alloydbomni.dbadmin.goog`

**Kind:** `Switchover` · **API Version:** `alloydbomni.dbadmin.goog/v1`

Triggers a **planned, graceful role switch** between the current primary and a designated standby. Unlike a failover, a switchover ensures the primary has fully flushed its WAL to the standby before handing over — resulting in zero data loss. Used for maintenance, upgrades, or workload rebalancing.

**Spec:**

```yaml
apiVersion: alloydbomni.dbadmin.goog/v1
kind: Switchover
metadata:
  name: switchover-maintenance
spec:
  dbclusterRef: "my-dbcluster"             # (optional) Target DBCluster (same namespace)
  newPrimary: "my-dbcluster-standby-0"     # (optional) Standby to promote; auto-selected if omitted
  primaryHost: "10.1.2.3"                  # (optional) IP that always points to the primary
```

**Status fields:** `state` (`InProgress` | `Success` | `Failed_RollbackInProgress` | `Failed_RollbackSuccess` | `Failed_RollbackFailed`), `startTime`, `endTime`, `createTime`, `conditions[]`, `criticalIncidents[]`, `internal.oldPrimary`, `internal.newPrimary`

---

### 24. `tdeconfigs.alloydbomni.dbadmin.goog`

**Kind:** `TDEConfig` · **API Version:** `alloydbomni.dbadmin.goog/v1`

Configures **Transparent Data Encryption (TDE)** for a `DBCluster`. When applied, all data files, WAL segments, and temporary files are encrypted at rest using AES-256. Key material is managed through an external Key Management Service (KMS) — supported providers include Google Cloud KMS, HashiCorp Vault, and PKCS#11-compatible HSMs.

**Spec:**

```yaml
apiVersion: alloydbomni.dbadmin.goog/v1
kind: TDEConfig
metadata:
  name: my-tdeconfig
spec:
  dbclusterRef: "my-dbcluster"             # (required) Target DBCluster
  keyManagementServiceSpec:
    serviceType: GoogleCloudKMS             # KMS provider type
    googleCloudKmsSpec:
      keyResourceId: >
        projects/my-project/locations/us-central1/
        keyRings/my-keyring/cryptoKeys/my-key
      credentialSecretRef:
        name: gcp-kms-secret               # K8s Secret with GCP service account JSON
    # OR for HashiCorp Vault:
    # vaultSpec:
    #   address: "https://vault.example.com"
    #   keyPath: "secret/data/tde-key"
    #   tokenSecretRef:
    #     name: vault-token-secret
```

**Status fields:** `phase`, `conditions[]`, `criticalIncidents[]`, `reconciled`

---

### 25. `userdefinedauthentications.alloydbomni.dbadmin.goog`

**Kind:** `UserDefinedAuthentication` · **API Version:** `alloydbomni.dbadmin.goog/v1`

Configures **Kerberos / Active Directory** authentication for a `DBCluster`. Applies custom `pg_hba.conf` rules, mounts a Kerberos keytab, and optionally configures LDAP-based AD group mapping. The fleet-controller-manager propagates this to each instance via `InstanceUserDefinedAuthentication` internal objects.

**Spec:**

```yaml
apiVersion: alloydbomni.dbadmin.goog/v1
kind: UserDefinedAuthentication
metadata:
  name: my-ad-auth
spec:
  dbclusterRef:
    name: "my-dbcluster"                   # (required) Target DBCluster reference
  keytabSecretRef:
    name: kerberos-keytab-secret           # (required) K8s Secret with 'krb5.keytab' key
  pgHbaEntries:                            # (required) pg_hba.conf lines to apply
    - "host all all 0.0.0.0/0 gss include_realm=0 krb_realm=EXAMPLE.COM"
    - "host all all ::0/0 gss include_realm=0 krb_realm=EXAMPLE.COM"
  pgIdentEntries:                          # (optional) pg_ident.conf user-name maps
    - "mymap  /^(.*)@EXAMPLE.COM$  \\1"
  ldapConfiguration:                       # (optional) AD group sync via LDAP
    enableGroupMapping: true
    ldapURI: "ldaps://ldap.example.com:636"
    ldapBaseDN: "DC=example,DC=com"
    ldapBindDN: "CN=svc-alloydb,OU=ServiceAccounts,DC=example,DC=com"
    ldapBindPasswordSecretRef:
      name: ldap-bind-secret
    ldapsCertificateSecretRef:
      name: ldaps-ca-cert-secret
    cacheTTLSeconds: 300
    enableLdapOptReferrals: false
```

**Status fields:** `state` (`Processing` | `Ready` | `Failed` | `Unknown`), `message`, `conditions[]`, `criticalIncidents[]`, `observedGeneration`, `reconciled`

---

## Quick Reference: Failover vs Switchover

| Attribute | `Failover` | `Switchover` |
|---|---|---|
| Use case | Primary is down / unresponsive | Planned maintenance / upgrade |
| Data safety | Possible data loss if WAL not synced | Zero data loss (WAL sync confirmed) |
| Speed | Faster (no wait for sync) | Slightly slower (waits for WAL flush) |
| Rollback | Attempted automatically on failure | Attempted automatically on failure |
| Trigger | User creates `Failover` resource | User creates `Switchover` resource |

---

## Quick Reference: Public vs Internal CRDs

| Type | API Group | Created by | Modified by | When to inspect |
|---|---|---|---|---|
| **Public** | `alloydbomni.dbadmin.goog` | Users / GitOps | Users / fleet-controller | Day-to-day operations |
| **Internal** | `alloydbomni.internal.dbadmin.goog` | fleet/local-controller | Operator only | Debugging / troubleshooting only |

> To inspect internal resources: `kubectl get <crd-name> -n <namespace> -o yaml`
> Never modify internal resources directly — changes will be overwritten by the operator.

---

## Common kubectl Commands

```bash
# List all CRDs in the alloydbomni groups
kubectl get crds | grep alloydbomni

# Check cluster health
kubectl get dbcluster -n <namespace>

# View backup plan status
kubectl get backupplan -n <namespace>
kubectl describe backupplan <name> -n <namespace>

# Trigger a manual backup
kubectl apply -f manual-backup.yaml

# Monitor a failover
kubectl get failover -n <namespace> -w

# Inspect internal workflow objects
kubectl get createstandbyjobs -n <namespace>
kubectl get instances.alloydbomni.internal.dbadmin.goog -n <namespace>
kubectl get lrojobs -n <namespace>

# View operator logs
kubectl logs -n alloydb-omni-system deployment/fleet-controller-manager
kubectl logs -n alloydb-omni-system deployment/local-controller-manager
```

---

## References

- [AlloyDB Omni for Kubernetes — current docs](https://docs.cloud.google.com/alloydb/omni/kubernetes/current/docs)
- [BackupPlan CRD v1.5.0 reference](https://docs.cloud.google.com/alloydb/omni/kubernetes/current/docs/reference/kubernetes-crds-1.5.0/backupplan)
- [Back up and restore in Kubernetes](https://docs.cloud.google.com/alloydb/omni/kubernetes/current/docs/backup-kubernetes)
- [Configuration samples](https://docs.cloud.google.com/alloydb/omni/kubernetes/current/docs/samples)
- [Troubleshoot the Kubernetes operator](https://docs.cloud.google.com/alloydb/omni/kubernetes/16.9.0/docs/troubleshoot-kubernetes-operator)
- [KRM API reference (GDC air-gapped)](https://cloud.google.com/distributed-cloud/hosted/docs/latest/gdch/apis/service/dbs/v1/alloydbomni-v1)
