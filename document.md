# AlloyDB Omni Operator on Red Hat OpenShift

**Comprehensive Architecture & Operations Documentation**

|                     |                                 |
|---------------------|---------------------------------|
|**Operator Version** |1.6.0 (Helm Chart)               |
|**Database Version** |17.5.0 (PostgreSQL 17-compatible)|
|**OpenShift Version**|4.16.46                          |
|**Classification**   |CONFIDENTIAL                     |
|**Last Updated**     |March 2026                       |

-----

## Table of Contents

- [1. Document Overview](#1-document-overview)
- [2. Platform & Version Matrix](#2-platform--version-matrix)
- [3. AlloyDB Omni Operator Architecture](#3-alloydb-omni-operator-architecture)
- [4. Operator Components & Container Images](#4-operator-components--container-images)
- [5. Custom Resource Definitions (CRDs)](#5-custom-resource-definitions-crds)
- [6. Resource Lifecycle & Reconciliation](#6-resource-lifecycle--reconciliation)
- [7. Network Architecture & Service Flows](#7-network-architecture--service-flows)
- [8. High Availability Architecture](#8-high-availability-architecture)
- [9. Backup & Disaster Recovery](#9-backup--disaster-recovery)
- [10. Monitoring & Observability](#10-monitoring--observability)
- [11. OpenShift-Specific Considerations](#11-openshift-specific-considerations)
- [12. Operational Workflows](#12-operational-workflows)
- [13. Security Architecture](#13-security-architecture)
- [14. References](#14-references)

-----

## 1. Document Overview

This document provides comprehensive architectural and operational documentation for Google AlloyDB Omni Operator version 1.6.0 deployed on Red Hat OpenShift Container Platform version 4.16.46, managing AlloyDB Omni database clusters running version 17.5.0. The operator follows a cluster-scoped deployment model where it is installed into the `alloydb-omni-system` namespace and manages DBCluster resources and their associated components across multiple tenant namespaces.

AlloyDB Omni is a downloadable, self-managed edition of Google AlloyDB for PostgreSQL. It delivers the high-performance AlloyDB engine — offering more than twice the transactional throughput and up to 100 times faster analytical query performance compared to standard PostgreSQL — packaged as containers managed by a Kubernetes operator. This approach enables automated deployment, lifecycle management, high availability, backup and restore, and monitoring of database instances within enterprise Kubernetes environments.

This document is intended for platform engineers, database administrators, and DevOps teams responsible for deploying, operating, and maintaining AlloyDB Omni on OpenShift. It covers the operator’s internal architecture, the container images it deploys, the Custom Resource Definitions (CRDs) it introduces, the network flows between components, the high availability model, backup and disaster recovery strategies, and the OpenShift-specific considerations that affect deployment and security.

-----

## 2. Platform & Version Matrix

|Component                   |Version                             |Notes                                              |
|----------------------------|------------------------------------|---------------------------------------------------|
|AlloyDB Omni Operator       |1.6.0                               |Cluster-scoped Kubernetes operator (GA release)    |
|Helm Chart                  |1.6.0                               |Bank-compliant custom chart from Google vendor team|
|AlloyDB Omni Database       |17.5.0                              |PostgreSQL 17-compatible database engine           |
|OpenShift Container Platform|4.16.46                             |Red Hat enterprise Kubernetes distribution         |
|Kubernetes API Version      |1.29.x                              |OpenShift 4.16 ships Kubernetes 1.29               |
|CRD API Group               |`alloydbomni.dbadmin.goog/v1`       |Custom resource API group for all CRDs             |
|Operator Namespace          |`alloydb-omni-system`               |Dedicated namespace for operator controllers       |
|Container Base Image        |UBI 9 (Red Hat Universal Base Image)|Since operator version 1.5.0                       |
|cert-manager                |1.x (OpenShift Operator)            |Pre-deployed, integrated with enterprise Venafi    |
|PgBouncer                   |1.23.x                              |Connection pooling sidecar                         |


> **Note:** The operator version 1.6.0 release includes several important fixes: a memory leak in the local operator that could cause out-of-memory crashes has been resolved, a cache bug that could prevent database startup after a restart has been fixed, and new metrics for Backup and BackupPlan custom resources have been added for improved visibility into backup operations.

### 2.1 Environment Context

This deployment operates in a fully disconnected (air-gapped) OpenShift environment with no direct internet egress. All vendor container images from Google Container Registry (`gcr.io/alloydb-omni/`) are pulled through an ATAAS-based Quarantine pipeline, scanned with Aqua Security for vulnerabilities and compliance, and published to the company’s internal Artifactory registry. All Kubernetes resource manifests, Helm chart values, and DBCluster specifications reference images from the internal Artifactory registry rather than the upstream Google registry.

|Integration       |Technology                 |Scope                                                       |
|------------------|---------------------------|------------------------------------------------------------|
|Authentication    |Kerberos / Keytab          |Enterprise SSO for database client authentication           |
|Secrets Management|HashiCorp Vault (VPM Model)|All tenant namespaces reference DB Ops vault secrets        |
|Backup Storage    |NetApp StorageGRID (S3)    |S3-compatible object storage for pgBackRest backups         |
|Log Aggregation   |Splunk                     |Centralized log forwarding from database pods               |
|APM / Monitoring  |Dynatrace                  |Application performance monitoring (in progress with Google)|
|Container Registry|JFrog Artifactory          |Internal registry for all operator and database images      |

-----

## 3. AlloyDB Omni Operator Architecture

### 3.1 Cluster-Scoped Operator Model

The AlloyDB Omni Operator is deployed as a cluster-scoped operator. This means the operator’s controller deployments and associated webhook services run in a single, dedicated namespace (`alloydb-omni-system`), but the operator watches and manages Custom Resources (CRs) across all namespaces in the cluster. When a user creates a DBCluster resource in any tenant namespace, the operator’s reconciliation loop detects this resource and provisions all the necessary Kubernetes objects — StatefulSets, Services, PersistentVolumeClaims, Secrets, ConfigMaps — in that same tenant namespace.

This cluster-scoped model provides several advantages. A single operator installation serves the entire OpenShift cluster, eliminating the need for per-namespace operator deployments. The operator’s ClusterRole and ClusterRoleBindings grant it the permissions necessary to manage resources across namespace boundaries. The webhook services (`fleet-webhook-service` and `local-webhook-service`) validate and mutate CRD resources regardless of which namespace they are created in.

### 3.2 Operator Namespace (alloydb-omni-system)

The `alloydb-omni-system` namespace is the operator’s control plane. It contains the following key resources:

- **Fleet Controller Deployment:** The primary operator controller that watches for DBCluster and other CRD resources across all namespaces. It runs the global reconciliation logic that translates declarative CRD specifications into Kubernetes-native resources.
- **Local Controller Deployment:** A companion controller that handles node-local operations, including direct interactions with database instances running on the same node. The version 1.6.0 release fixed a memory leak in this component.
- **Webhook Services:** Admission webhooks (`fleet-webhook-service` and `local-webhook-service`) that intercept API server requests to validate and mutate AlloyDB Omni custom resources before they are persisted to etcd. These webhooks enforce schema validation, default values, and cross-resource consistency checks.
- **cert-manager Certificates:** TLS certificates issued by cert-manager (backed by enterprise Venafi) for securing webhook endpoints and internal operator communications. These include `fleet-serving-cert` and `local-serving-cert`, each with DNS names scoped to the `alloydb-omni-system` namespace.
- **ClusterIssuer:** The `alloydbomni-selfsigned-cluster-issuer` ClusterIssuer resource provides a self-signed certificate authority used to bootstrap trust for the operator’s internal TLS infrastructure.
- **ServiceAccount & RBAC:** Dedicated ServiceAccounts with ClusterRole bindings that grant the operator permission to create, read, update, and delete resources across namespaces including Pods, Services, StatefulSets, PVCs, Secrets, ConfigMaps, and all AlloyDB Omni CRDs.

### 3.3 Tenant Namespace Model

Google recommends creating database clusters in namespaces separate from `alloydb-omni-system`. This separation improves isolation and security and prevents conflicts between the operator, the resources it manages, and user application components. Each tenant namespace contains the actual database workloads:

- **Database Pods:** StatefulSet-managed pods running the AlloyDB Omni database engine along with sidecar containers for log rotation, memory management, and monitoring.
- **Kubernetes Services:** ClusterIP or LoadBalancer services providing read-write (RW) and read-only (RO) endpoints for database connectivity.
- **PersistentVolumeClaims:** Storage claims for database data directories, WAL logs, and observability data.
- **Secrets:** Database admin passwords (sourced from Vault), TLS certificates, Kerberos keytabs, and backup storage credentials.
- **Custom Resources:** DBCluster, BackupPlan, Backup, Restore, Failover, PgBouncer, Sidecar, and other CRDs that declare the desired state of the database infrastructure.

-----

## 4. Operator Components & Container Images

### 4.1 Operator Controller Pods

The operator deploys two primary controller pods within the `alloydb-omni-system` namespace. These controllers implement the Kubernetes operator pattern: they run continuous reconciliation loops that compare the desired state declared in CRD resources against the actual state of Kubernetes objects and take corrective action to converge the two.

The fleet controller is responsible for global lifecycle management — creating and scaling StatefulSets, managing Services, handling upgrades, and coordinating multi-instance HA topologies. The local controller handles node-level operations and direct database instance management, including health checks and local configuration updates.

### 4.2 Database Pod Containers

Each database pod provisioned by the operator runs multiple containers. The pod follows Kubernetes multi-container patterns with an init container for initialization and several sidecar containers for auxiliary functions.

|Container        |Role          |Description                                                                                                                                                                                                                                                                                  |
|-----------------|--------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
|`database`       |Primary       |The main AlloyDB Omni database engine container running PostgreSQL 17.5.0-compatible AlloyDB. Hosts the database server process, buffer pool, columnar engine, query processing, and storage layers.                                                                                         |
|`dbinit`         |Init Container|Runs once before the database container starts. Performs initial database cluster setup including running initdb, configuring pg_hba.conf, setting up data directories on persistent volumes, and preparing the environment for the database engine.                                         |
|`logrotate-agent`|Sidecar       |Manages rotation of PostgreSQL diagnostic logs including postgresql.log and postgresql.audit. Archives rotated logs to `/obs/diagnostic/archive/` with configurable size-based (default 200 MB) and time-based rotation thresholds. Supports gzip compression with a default 7-day retention.|
|`memoryagent`    |Sidecar       |Monitors and manages memory utilization within the database pod. Tracks memory consumption and provides the `alloydb_omni_memory_used_byte` metric. Helps prevent out-of-memory conditions.                                                                                                  |
|`alloydb-monitor`|Sidecar       |Collects and exposes database performance metrics in Prometheus format. Monitors database health, replication status, query performance, and resource utilization. Integrates with the operator’s health check framework for automated failover decisions.                                   |

### 4.3 Supporting Component Images

Beyond the core database pod, the operator manages additional component images for connection pooling and control plane functions. All images are sourced from the internal Artifactory registry after passing through the ATAAS-based Quarantine pipeline with Aqua Security scanning.

|Image / Component                 |Purpose                                                         |Registry Source                               |
|----------------------------------|----------------------------------------------------------------|----------------------------------------------|
|AlloyDB Omni Database (pg-service)|Core database engine with AlloyDB enhancements                  |Artifactory (quarantined from gcr.io)         |
|Operator Fleet Controller         |Global reconciliation controller                                |Artifactory (quarantined from gcr.io)         |
|Operator Local Controller         |Node-local database management                                  |Artifactory (quarantined from gcr.io)         |
|PgBouncer (1.23.x)                |Connection pooling proxy deployed via PgBouncer CRD             |Artifactory (quarantined from gcr.io)         |
|Control Plane Agents              |Per-instance control plane managing HA, replication, and Patroni|Artifactory (quarantined from gcr.io)         |
|kube-state-metrics                |Exposes CRD metrics in Prometheus format (from operator 1.3.0+) |Artifactory (quarantined from registry.k8s.io)|


> **Note:** Starting with operator version 1.5.0, all AlloyDB Omni Kubernetes images are built upon Red Hat’s Universal Base Image (UBI) 9, ensuring compatibility with OpenShift’s security requirements and Red Hat’s container certification standards.

-----

## 5. Custom Resource Definitions (CRDs)

The AlloyDB Omni Operator extends the Kubernetes API by registering 25 Custom Resource Definitions across two API groups. These CRDs fall into two distinct categories: user-facing CRDs that platform teams and DBAs interact with directly, and internal CRDs that the operator creates and manages autonomously as part of its reconciliation logic. Users should never create or modify internal CRDs directly; they are implementation details of the operator’s control plane.

### 5.1 CRD Inventory & Classification

|# |CRD Name                            |API Group                          |Scope      |
|--|------------------------------------|-----------------------------------|-----------|
|1 |`backupplans`                       |`alloydbomni.dbadmin.goog`         |User-Facing|
|2 |`backups`                           |`alloydbomni.dbadmin.goog`         |User-Facing|
|3 |`dbclusters`                        |`alloydbomni.dbadmin.goog`         |User-Facing|
|4 |`dbinstances`                       |`alloydbomni.dbadmin.goog`         |User-Facing|
|5 |`failovers`                         |`alloydbomni.dbadmin.goog`         |User-Facing|
|6 |`pgbouncers`                        |`alloydbomni.dbadmin.goog`         |User-Facing|
|7 |`replications`                      |`alloydbomni.dbadmin.goog`         |User-Facing|
|8 |`restores`                          |`alloydbomni.dbadmin.goog`         |User-Facing|
|9 |`sidecars`                          |`alloydbomni.dbadmin.goog`         |User-Facing|
|10|`switchovers`                       |`alloydbomni.dbadmin.goog`         |User-Facing|
|11|`tdeconfigs`                        |`alloydbomni.dbadmin.goog`         |User-Facing|
|12|`userdefinedauthentications`        |`alloydbomni.dbadmin.goog`         |User-Facing|
|13|`backuprepositories`                |`alloydbomni.internal.dbadmin.goog`|Internal   |
|14|`createstandbyjobs`                 |`alloydbomni.internal.dbadmin.goog`|Internal   |
|15|`deletestandbyjobs`                 |`alloydbomni.internal.dbadmin.goog`|Internal   |
|16|`failovers`                         |`alloydbomni.internal.dbadmin.goog`|Internal   |
|17|`instancebackupplans`               |`alloydbomni.internal.dbadmin.goog`|Internal   |
|18|`instancebackups`                   |`alloydbomni.internal.dbadmin.goog`|Internal   |
|19|`instancerestores`                  |`alloydbomni.internal.dbadmin.goog`|Internal   |
|20|`instances`                         |`alloydbomni.internal.dbadmin.goog`|Internal   |
|21|`instanceswitchovers`               |`alloydbomni.internal.dbadmin.goog`|Internal   |
|22|`instanceuserdefinedauthentications`|`alloydbomni.internal.dbadmin.goog`|Internal   |
|23|`lrojobs`                           |`alloydbomni.internal.dbadmin.goog`|Internal   |
|24|`replicationconfigs`                |`alloydbomni.internal.dbadmin.goog`|Internal   |
|25|`sidecars`                          |`alloydbomni.internal.dbadmin.goog`|Internal   |

The `alloydbomni.dbadmin.goog` group contains the user-facing contract — these are the CRDs documented by Google and intended for direct manipulation by cluster operators and DBAs. The `alloydbomni.internal.dbadmin.goog` group contains internal implementation resources created and managed solely by the operator’s controllers. Modifying internal CRDs directly may corrupt operator state and is unsupported.

### 5.2 User-Facing CRDs (alloydbomni.dbadmin.goog)

These 12 CRDs constitute the operator’s public API. Users create and manage these resources in tenant namespaces to declare the desired state of their database infrastructure.

#### dbclusters

The primary resource that declares an AlloyDB Omni database cluster. A DBCluster encapsulates the complete specification for a database instance including compute resources (CPU, memory), storage disks, database version (17.5.0), control plane agents version, HA configuration, admin user credentials, database parameters, scheduling constraints (node affinity, tolerations, pod anti-affinity), and feature flags (AlloyDB AI, memory agent).

Key specification fields:

- **`databaseVersion`:** Target database version string (e.g., `"17.5.0"`).
- **`controlPlaneAgentsVersion`:** Version of per-instance control plane agents.
- **`primarySpec`:** Defines resources (CPU/memory), disks, `adminUser.passwordRef`, parameters (PostgreSQL GUCs), `schedulingconfig`, services, `dbLoadBalancerOptions`, and `sidecarRef`.
- **`availability`:** HA settings: `numberOfStandbys`, `enableAutoFailover`, `enableAutoHeal`, `autoFailoverTriggerThreshold`, `healthcheckPeriodSeconds`, `enableStandbyAsReadReplica`.
- **`allowExternalIncomingTraffic`:** Boolean controlling external service exposure.
- **`mode`:** Cluster mode for DR scenarios (primary/standby).
- **`connectedModeSpec`:** Optional GCP project binding for connected-mode features.

#### dbinstances

Represents an individual database instance within a cluster. In an HA cluster with one primary and two standbys, there would be three DBInstance resources. Provides per-instance visibility into health, role (primary/standby), and configuration.

#### backupplans

Defines continuous backup configuration for a DBCluster. Specifies backup storage location (local PV, GCS, or S3-compatible via `s3Options`), cron-based schedules for full, incremental, and differential backups, retention period in days, and a `paused` flag. In this environment, backups target NetApp StorageGRID via `s3Options`.

#### backups

Represents an individual backup, either scheduled by a BackupPlan or created manually. Manual backups set `manual: true` and can specify `backupType` as `"full"`, `"diff"`, or `"incr"`.

#### restores

Triggers restoration from a backup or point-in-time recovery to a specific timestamp using continuous WAL archives. The `clonedDBClusterConfig` field enables non-destructive recovery into a new DBCluster.

#### failovers

Triggers unplanned failover, promoting a standby to primary. Metrics exposed via kube-state-metrics with `alloydb_omni_failover_` prefix.

#### switchovers

Triggers planned, controlled switchover for maintenance — zero data loss, minimal downtime.

#### pgbouncers

Deploys PgBouncer connection pooling proxy. Container image must point to Artifactory.

#### replications

Configures cross-cluster or cross-region replication for disaster recovery.

#### sidecars

Attaches custom sidecar containers (e.g., Splunk forwarder) to database pods via `obsdisk` volume mount.

#### tdeconfigs

Configures Transparent Data Encryption (TDE) for data-at-rest encryption.

#### userdefinedauthentications

Configures Kerberos/GSSAPI authentication rules for enterprise SSO integration.

### 5.3 Internal Operator CRDs (alloydbomni.internal.dbadmin.goog)

> ⚠️ **Warning:** Never create, modify, or delete internal CRDs directly. They are managed exclusively by the operator controllers. Tampering may corrupt operator state.

|Internal CRD                        |Created By            |Purpose                                                                             |
|------------------------------------|----------------------|------------------------------------------------------------------------------------|
|`instances`                         |DBCluster controller  |Per-pod instance tracking: role, health, replication state                          |
|`createstandbyjobs`                 |HA controller         |Multi-step standby creation: base backup, WAL catch-up, replication slot, sync setup|
|`deletestandbyjobs`                 |HA controller         |Standby teardown: slot removal, disconnection, PVC cleanup                          |
|`failovers` (internal)              |Failover controller   |Failover execution: primary detection, standby selection, WAL replay, promotion     |
|`instancebackupplans`               |Backup controller     |Per-instance backup schedule management                                             |
|`instancebackups`                   |Backup controller     |Per-instance backup execution (pgBackRest, WAL archiving)                           |
|`instancerestores`                  |Restore controller    |Per-instance restore execution: backup retrieval, WAL replay, data swap             |
|`instanceswitchovers`               |Switchover controller |Per-instance switchover coordination                                                |
|`instanceuserdefinedauthentications`|Auth controller       |Per-instance Kerberos/GSSAPI pg_hba.conf rules                                      |
|`backuprepositories`                |Backup controller     |pgBackRest repository config, StorageGRID connectivity                              |
|`replicationconfigs`                |Replication controller|Streaming replication config: primary host, sync/async mode                         |
|`lrojobs`                           |Operator controller   |Long-Running Operation tracker (major upgrades, large restores)                     |
|`sidecars` (internal)               |Sidecar controller    |Per-instance sidecar injection state                                                |

### 5.4 CRD Relationship Map

The two-tier architecture (user-facing declaration + internal execution) allows the operator to present a simple cluster-level API while managing complex instance-level orchestration internally. If a backup appears stuck at the DBCluster level, inspect corresponding `instancebackups` to identify the failing instance and step.

```bash
# List all CRDs registered by the operator
oc get crds | grep alloydbomni

# Inspect internal instance resources for troubleshooting
oc get instances.alloydbomni.internal.dbadmin.goog -n <tenant-namespace> -o yaml

# Inspect standby creation job status
oc get createstandbyjobs.alloydbomni.internal.dbadmin.goog -n <tenant-namespace> -o yaml
```

-----

## 6. Resource Lifecycle & Reconciliation

### Provisioning Flow

When a user applies a DBCluster manifest to a tenant namespace:

1. The fleet webhook validates the DBCluster specification against schema constraints.
1. The fleet controller detects the new DBCluster and begins reconciliation.
1. PersistentVolumeClaims are created for data disk, WAL disk, and observability disk.
1. A StatefulSet is created with the database pod template including `dbinit` init container and all sidecars.
1. Kubernetes Services are created: read-write (RW) for primary, read-only (RO) for replicas.
1. The `dbinit` container runs `initdb` to initialize the PostgreSQL data directory.
1. The database container starts and control plane agents configure the instance.
1. The operator updates DBCluster status to `DBClusterReady` when all components are healthy.

### Upgrade & Update Flow

For minor version upgrades, the operator updates the database container image and triggers a controlled restart. For major version upgrades (e.g., 15.x to 17.x), manual `pg_upgrade` steps may be required. HA clusters may need `numberOfStandbys` set to 0 during upgrade and re-enabled afterward. Starting with operator 1.6.0, scheduling configuration changes are applied immediately and trigger a restart.

-----

## 7. Network Architecture & Service Flows

### 7.1 Network Flow Matrix

|Source                  |Destination           |Protocol / Port|Purpose                                 |
|------------------------|----------------------|---------------|----------------------------------------|
|Client Application      |RW Service (ClusterIP)|TCP/5432       |Read-write connections to primary       |
|Client Application      |RO Service (ClusterIP)|TCP/5432       |Read-only connections to standbys       |
|Client Application      |PgBouncer Service     |TCP/5432       |Pooled connections via PgBouncer        |
|PgBouncer Pod           |RW / RO Service       |TCP/5432       |Proxied database connections            |
|Primary Pod             |Standby Pod(s)        |TCP/5432       |Streaming replication (WAL shipping)    |
|Standby Pod(s)          |Primary Pod           |TCP/5432       |Replication slot management             |
|Operator Controllers    |Kubernetes API Server |TCP/6443       |Resource watch/list/create/update/delete|
|Webhook Services        |Kubernetes API Server |TCP/443 (TLS)  |Admission webhook callbacks             |
|alloydb-monitor         |Prometheus Endpoint   |TCP/9187       |Metrics scraping                        |
|Splunk Forwarder Sidecar|Splunk HEC / Indexer  |TCP/8088 (TLS) |Log forwarding                          |
|Vault Agent / VSO       |HashiCorp Vault       |TCP/8200 (TLS) |Secret retrieval                        |
|Database Pod            |Kerberos KDC          |TCP+UDP/88     |Kerberos ticket exchange                |
|Operator                |Artifactory Registry  |TCP/443 (TLS)  |Container image pulls                   |
|Backup (pgBackRest)     |StorageGRID S3        |TCP/18082 (TLS)|Backup write/read                       |

### 7.2 Kubernetes Services

- **Read-Write (RW) Service** (`<prefix>-<dbcluster>-rw-ilb`): Routes to current primary via `dbs.internal.dbadmin.goog/ha-role=Primary` selector. Auto-updates on failover.
- **Read-Only (RO) Service** (`<prefix>-<dbcluster>-ro-ilb`): Distributes read traffic across standbys when `enableStandbyAsReadReplica` is true.

### 7.3 PgBouncer Connection Pooling

PgBouncer Deployment connects to the database through the RW service and supports session, transaction, and statement pool modes. Statistics accessible via `statsuser` on the `pgbouncer` virtual database.

### 7.4 TLS & Certificate Management

cert-manager (integrated with enterprise Venafi) manages TLS certificates. The operator creates ClusterIssuer (`alloydbomni-selfsigned-cluster-issuer`), namespace Issuers, and Certificates for webhook endpoints. Database connections use TLS 1.3 (AES-256-GCM-SHA384) by default.

-----

## 8. High Availability Architecture

### 8.1 Patroni-Based HA

AlloyDB Omni uses Patroni for HA, leveraging the Kubernetes API as its distributed configuration store (DCS) — no external etcd or ZooKeeper required.

### 8.2 Streaming Replication

- **Synchronous (default):** RPO of zero — every transaction synchronously replicated before client acknowledgment.
- **Asynchronous:** Lower latency but potential data loss. Used for cross-region DR.

Verify replication via `pg_replication_slots` and `pg_stat_replication` system views.

### 8.3 Automatic Failover

|Parameter                     |Description                                                |
|------------------------------|-----------------------------------------------------------|
|`enableAutoFailover`          |Enable/disable automatic failover                          |
|`autoFailoverTriggerThreshold`|Consecutive health check failures before failover (e.g., 3)|
|`healthcheckPeriodSeconds`    |Health check interval (default 30s, range 1–86400)         |
|`enableAutoHeal`              |Auto-recovery of failed instances                          |

Typical RTO: less than 60 seconds.

-----

## 9. Backup & Disaster Recovery

### StorageGRID S3 Integration

All backups target NetApp StorageGRID via S3-compatible API:

- **S3 Credentials:** Kubernetes Secret with `access-key-id` and `access-key`, provisioned from HashiCorp Vault via VSO.
- **StorageGRID Endpoint:** Internal S3 API URL in `s3Options.endpoint` with CA bundle for TLS trust.
- **Bucket Isolation:** Each DBCluster isolated by bucket or key prefix.

```yaml
apiVersion: alloydbomni.dbadmin.goog/v1
kind: BackupPlan
metadata:
  name: backupplan-sample
  namespace: <tenant-namespace>
spec:
  dbclusterRef: <dbcluster-name>
  backupRetainDays: 14
  backupSchedules:
    full: "0 0 * * 0"          # Weekly full (Sunday midnight)
    incremental: "0 21 * * *"   # Daily incremental (9 PM)
  backupLocation:
    type: S3
    s3Options:
      bucket: alloydb-backups
      region: us-east-1
      endpoint: https://storagegrid.internal.company.com:18082
      key: <dbcluster-name>/backups
      secretRef:
        name: storagegrid-s3-credentials
        namespace: <tenant-namespace>
```

### Point-in-Time Recovery

Restore CRD supports PITR to any second within the retention window using continuous WAL archives on StorageGRID.

### Cross-Region Disaster Recovery

Asynchronous streaming replication to secondary DBCluster in a remote region. StorageGRID’s native cross-site replication provides backup data availability independently of database replication.

-----

## 10. Monitoring & Observability

### Database-Level Metrics (Prometheus)

|Metric                                               |Description                             |
|-----------------------------------------------------|----------------------------------------|
|`alloydb_omni_memory_used_byte`                      |Database container memory consumption   |
|`alloydb_omni_instance_postgresql_wait_time_us_total`|PostgreSQL wait event times             |
|`alloydb_omni_dbcluster_*`                           |DBCluster HA readiness, phase, version  |
|`alloydb_omni_failover_*`                            |Failover counts, duration, status       |
|Backup/BackupPlan metrics                            |Completion status, timing (new in 1.6.0)|

### Splunk Log Aggregation

|Log Stream        |Source               |Description                                       |
|------------------|---------------------|--------------------------------------------------|
|`postgresql.log`  |Database container   |Server activity, errors, slow queries, checkpoints|
|`postgresql.audit`|pgaudit extension    |DDL, DML audit trails for compliance              |
|Controller logs   |`alloydb-omni-system`|Reconciliation events, errors, lifecycle ops      |

The `logrotate-agent` sidecar manages on-pod rotation (200 MB default, gzip, 7-day retention). Splunk forwarder sidecar streams logs in real-time.

### Dynatrace APM

> **Note:** Dynatrace integration is currently being developed with Google. Target: OneAgent sidecar for infrastructure monitoring, database performance analysis, and end-to-end tracing. Details will be updated in a future revision.

-----

## 11. OpenShift-Specific Considerations

### 11.1 Helm Chart Installation

Bank-compliant custom Helm charts are provided directly by the Google vendor team. These are ingested through the ATAAS-based Quarantine pipeline, scanned with Aqua Security, and published to internal Artifactory.

1. Receive bank-compliant Helm chart from Google vendor team → ingest through ATAAS Quarantine into Artifactory.
1. cert-manager is already deployed and integrated with enterprise Venafi — no installation required.
1. Create `alloydb-omni-system` namespace and apply AlloyDB Omni cert-manager resources integrating with existing Venafi-backed deployment.
1. Configure Helm values to override all image references to internal Artifactory paths.
1. Run `helm install` with the modified values file.
1. Verify operator pods reach Running state.

```bash
helm install alloydb-omni-operator ./alloydbomni-operator-1.6.0.tgz \
  --namespace alloydb-omni-system \
  --create-namespace \
  -f values-disconnected.yaml
```

### 11.2 Disconnected Environment & Image Pipeline

#### ATAAS Quarantine Pipeline

1. **Image Request:** Platform team identifies required images from bank-compliant Helm chart.
1. **ATAAS Quarantine Pull:** Automated quarantine job in DMZ pulls images from `gcr.io/alloydb-omni/`.
1. **Aqua Security Scanning:** CVE analysis, malware detection, CIS benchmark compliance, license risk assessment.
1. **Approval & Promotion:** Passing images promoted from ATAAS staging to production Artifactory.
1. **Registry Path Mapping:** Published under `artifactory.internal.company.com/alloydb-omni/` mirroring upstream structure.

#### Required Images

|Image                |Component                |Versioned By                |
|---------------------|-------------------------|----------------------------|
|Fleet controller     |Operator control plane   |Helm chart (1.6.0)          |
|Local controller     |Operator node agent      |Helm chart (1.6.0)          |
|AlloyDB Omni database|Database engine          |`databaseVersion` (17.5.0)  |
|Control plane agents |Per-instance management  |`controlPlaneAgentsVersion` |
|dbinit               |Init container           |Database version            |
|logrotate-agent      |Log rotation sidecar     |Operator version            |
|memoryagent          |Memory monitoring sidecar|Operator version            |
|alloydb-monitor      |Metrics exporter sidecar |Operator version            |
|PgBouncer            |Connection pooler        |PgBouncer CRD image (1.23.x)|
|kube-state-metrics   |CRD metrics exporter     |Operator dependency         |

Each namespace requires an **ImagePullSecret** for Artifactory authentication.

### 11.3 Security Context Constraints (SCC)

```bash
oc annotate dbclusters.alloydbomni.dbadmin.goog <n> -n <namespace> openshift.io/scc=anyuid
```

When installing via Helm, explicitly bind the operator’s ServiceAccount to the `anyuid` SCC through a ClusterRoleBinding.

### 11.4 UBI-Based Images

All images use Red Hat UBI 9, compatible with CRI-O, RHEL CoreOS, cgroup v2, and the ATAAS Quarantine pipeline with Aqua Security scanning.

-----

## 12. Operational Workflows

All commands use the `oc` CLI consistent with the OpenShift environment.

### 12.1 Cluster Health & Status Verification

```bash
# List all DBClusters across all tenant namespaces
oc get dbclusters.alloydbomni.dbadmin.goog --all-namespaces

# Detailed status for a specific cluster
oc get dbclusters.alloydbomni.dbadmin.goog <dbcluster-name> -n <namespace> -o yaml

# Quick phase check (expect: DBClusterReady)
oc get dbclusters.alloydbomni.dbadmin.goog <dbcluster-name> -n <namespace> \
  -o jsonpath='{.status.phase}'

# Current database version
oc get dbclusters.alloydbomni.dbadmin.goog <dbcluster-name> -n <namespace> \
  -o jsonpath='{.status.primary.currentDatabaseVersion}'

# Current operator version
oc get dbclusters.alloydbomni.dbadmin.goog <dbcluster-name> -n <namespace> \
  -o jsonpath='{.status.primary.currentControlPlaneAgentsVersion}'

# Verify operator pods
oc get pods -n alloydb-omni-system

# Operator controller logs
oc logs -n alloydb-omni-system deployment/fleet-controller --tail=100
oc logs -n alloydb-omni-system deployment/local-controller --tail=100

# List database pods and verify container status (expect 3/3)
oc get pods -l alloydbomni.internal.dbadmin.goog/dbcluster=<dbcluster-name> -n <namespace> -o wide

# Verify container images are from Artifactory
oc get pod <pod-name> -n <namespace> \
  -o jsonpath='{range .spec.containers[*]}{.name}: {.image}{"\n"}{end}'
```

### 12.2 Database Connectivity

```bash
# Exec into database container
oc exec -ti <pod-name> -c database -n <namespace> -- /bin/bash

# Connect to PostgreSQL
psql -h localhost -U postgres

# Quick query without interactive shell
oc exec -ti <pod-name> -c database -n <namespace> -- \
  psql -h localhost -U postgres -c "SELECT version();"

# Get RW and RO service endpoints
oc get svc -l alloydbomni.internal.dbadmin.goog/dbcluster=<dbcluster-name> -n <namespace>

# Port-forward for local debugging
oc port-forward svc/<rw-service-name> 5432:5432 -n <namespace>
```

#### Verify Kerberos Authentication

```bash
# Verify keytab is mounted
oc exec -ti <pod-name> -c database -n <namespace> -- ls -la /etc/krb5/

# Check pg_hba.conf for GSSAPI entries
oc exec -ti <pod-name> -c database -n <namespace> -- \
  cat /mnt/disks/pgsql/data/pg_hba.conf | grep -i gss

# Test Kerberos auth from client pod
kinit <principal>@<REALM>
psql -h <rw-service> -U <kerberos-user> -d postgres
```

### 12.3 High Availability Operations

```bash
# Check HA configuration
oc get dbclusters.alloydbomni.dbadmin.goog <dbcluster-name> -n <namespace> \
  -o jsonpath='{.spec.availability}'

# Identify primary and standby roles
oc get pods -l alloydbomni.internal.dbadmin.goog/dbcluster=<dbcluster-name> \
  -l dbs.internal.dbadmin.goog/ha-role -n <namespace> --show-labels

# Verify streaming replication
oc exec -ti <primary-pod> -c database -n <namespace> -- \
  psql -h localhost -U postgres -c "SELECT * FROM pg_stat_replication;"

# Check replication slots
oc exec -ti <primary-pod> -c database -n <namespace> -- \
  psql -h localhost -U postgres -c "SELECT slot_name, active, restart_lsn FROM pg_replication_slots;"

# Check replication lag (on standby)
oc exec -ti <standby-pod> -c database -n <namespace> -- \
  psql -h localhost -U postgres -c "SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;"
```

#### Manual Failover (Unplanned)

```bash
cat <<EOF | oc apply -f -
apiVersion: alloydbomni.dbadmin.goog/v1
kind: Failover
metadata:
  name: failover-$(date +%Y%m%d%H%M%S)
  namespace: <tenant-namespace>
spec:
  dbclusterRef: <dbcluster-name>
EOF

# Monitor
oc get failovers.alloydbomni.dbadmin.goog -n <namespace> -w
oc get failovers.alloydbomni.internal.dbadmin.goog -n <namespace> -o yaml
```

#### Planned Switchover

```bash
cat <<EOF | oc apply -f -
apiVersion: alloydbomni.dbadmin.goog/v1
kind: Switchover
metadata:
  name: switchover-$(date +%Y%m%d%H%M%S)
  namespace: <tenant-namespace>
spec:
  dbclusterRef: <dbcluster-name>
EOF

oc get switchovers.alloydbomni.dbadmin.goog -n <namespace> -w
```

#### Scale Standbys

```bash
# Scale up
oc patch dbclusters.alloydbomni.dbadmin.goog <dbcluster-name> -n <namespace> \
  --type=merge -p '{"spec":{"availability":{"numberOfStandbys":2}}}'

# Scale down
oc patch dbclusters.alloydbomni.dbadmin.goog <dbcluster-name> -n <namespace> \
  --type=merge -p '{"spec":{"availability":{"numberOfStandbys":1}}}'

# Monitor standby jobs
oc get createstandbyjobs.alloydbomni.internal.dbadmin.goog -n <namespace>
oc get deletestandbyjobs.alloydbomni.internal.dbadmin.goog -n <namespace>
```

### 12.4 Backup & Restore Operations

```bash
# List backups and backup plans
oc get backups.alloydbomni.dbadmin.goog -n <namespace>
oc get backupplans.alloydbomni.dbadmin.goog -n <namespace>

# Check StorageGRID repository connectivity
oc get backuprepositories.alloydbomni.internal.dbadmin.goog -n <namespace> -o yaml

# Instance-level backup status (troubleshooting)
oc get instancebackups.alloydbomni.internal.dbadmin.goog -n <namespace>
```

#### Manual Backup

```bash
cat <<EOF | oc apply -f -
apiVersion: alloydbomni.dbadmin.goog/v1
kind: Backup
metadata:
  name: manual-backup-$(date +%Y%m%d%H%M%S)
  namespace: <tenant-namespace>
spec:
  dbclusterRef: <dbcluster-name>
  backupPlanRef: <backupplan-name>
  manual: true
  physicalBackupSpec:
    backupType: full    # Options: full, diff, incr
EOF

oc get backups.alloydbomni.dbadmin.goog -n <namespace> -w
```

#### Pause / Resume Scheduled Backups

```bash
# Pause
oc patch backupplans.alloydbomni.dbadmin.goog <plan-name> -n <namespace> \
  --type=merge -p '{"spec":{"paused":true}}'

# Resume
oc patch backupplans.alloydbomni.dbadmin.goog <plan-name> -n <namespace> \
  --type=merge -p '{"spec":{"paused":false}}'
```

#### Restore from Backup / Point-in-Time Recovery

```bash
# Restore from named backup (non-destructive, creates new cluster)
cat <<EOF | oc apply -f -
apiVersion: alloydbomni.dbadmin.goog/v1
kind: Restore
metadata:
  name: restore-$(date +%Y%m%d%H%M%S)
  namespace: <tenant-namespace>
spec:
  sourceDBCluster: <original-dbcluster-name>
  backup: <backup-name>
  clonedDBClusterConfig:
    dbclusterName: <new-dbcluster-name>
EOF

# Point-in-time recovery
cat <<EOF | oc apply -f -
apiVersion: alloydbomni.dbadmin.goog/v1
kind: Restore
metadata:
  name: pitr-$(date +%Y%m%d%H%M%S)
  namespace: <tenant-namespace>
spec:
  sourceDBCluster: <original-dbcluster-name>
  pointInTime: "2026-03-30T14:30:00Z"
  clonedDBClusterConfig:
    dbclusterName: <recovered-dbcluster-name>
EOF

# Monitor
oc get restores.alloydbomni.dbadmin.goog -n <namespace> -w
oc get dbclusters.alloydbomni.dbadmin.goog -n <namespace> -w
```

### 12.5 PgBouncer Operations

```bash
oc get pgbouncers.alloydbomni.dbadmin.goog -n <namespace>
oc get pods -l app=pgbouncer -n <namespace>

# Pool statistics
oc exec -ti <pgbouncer-pod> -n <namespace> -- \
  psql -h 127.0.0.1 -p 5432 -U statsuser -d pgbouncer -c "SHOW POOLS;"

# Scale replicas
oc patch pgbouncers.alloydbomni.dbadmin.goog <pgbouncer-name> -n <namespace> \
  --type=merge -p '{"spec":{"replicaCount":3}}'
```

### 12.6 Log & Diagnostic Operations

```bash
# Live PostgreSQL logs
oc exec -ti <pod-name> -c database -n <namespace> -- tail -f /obs/diagnostic/postgresql.log

# Audit logs
oc exec -ti <pod-name> -c database -n <namespace> -- tail -f /obs/diagnostic/postgresql.audit

# Current audit log file path
oc exec -ti <pod-name> -c database -n <namespace> -- \
  psql -h localhost -U postgres -c "SELECT alloydb_audit_current_logfile();"

# Archived/rotated logs
oc exec -ti <pod-name> -c database -n <namespace> -- ls -lah /obs/diagnostic/archive/

# Sidecar logs
oc logs <pod-name> -c logrotate-agent -n <namespace> --tail=50
oc logs <pod-name> -c memoryagent -n <namespace> --tail=50
oc logs <pod-name> -c alloydb-monitor -n <namespace> --tail=50
```

### 12.7 Vault & Secrets Operations

```bash
# Verify Vault-synced secrets
oc get secrets -n <namespace> | grep -E "(db-pw|storagegrid|keytab|tls)"

# VSO sync status
oc get vaultstaticsecrets -n <namespace>

# Verify StorageGRID credentials
oc get secret storagegrid-s3-credentials -n <namespace> \
  -o jsonpath='{.data.access-key-id}' | base64 -d

# Verify Kerberos keytab
oc exec -ti <pod-name> -c database -n <namespace> -- \
  klist -kt /etc/krb5/postgres.keytab
```

### 12.8 CRD Inspection & Troubleshooting

```bash
# All AlloyDB CRDs
oc get crds | grep alloydbomni

# All user-facing resources in a namespace
oc get dbclusters,dbinstances,backupplans,backups,restores,failovers,switchovers,pgbouncers,sidecars,replications,tdeconfigs,userdefinedauthentications -n <namespace>

# All internal resources
oc get instances.alloydbomni.internal.dbadmin.goog,createstandbyjobs.alloydbomni.internal.dbadmin.goog,backuprepositories.alloydbomni.internal.dbadmin.goog,replicationconfigs.alloydbomni.internal.dbadmin.goog -n <namespace>
```

#### Troubleshoot Stuck DBCluster

```bash
oc get dbclusters.alloydbomni.dbadmin.goog <n> -n <namespace> \
  -o jsonpath='{.status.conditions}' | python3 -m json.tool
oc get instances.alloydbomni.internal.dbadmin.goog -n <namespace> -o yaml
oc get events -n <namespace> --sort-by='.lastTimestamp' | grep -i alloydb
oc get pvc -l alloydbomni.internal.dbadmin.goog/dbcluster=<n> -n <namespace>
```

#### Troubleshoot HA / Standby Issues

```bash
oc get createstandbyjobs.alloydbomni.internal.dbadmin.goog -n <namespace> \
  -o jsonpath='{range .items[*]}{.metadata.name}: Step={.spec.currentStep} Error={.spec.retryError}{"\n"}{end}'
oc get replicationconfigs.alloydbomni.internal.dbadmin.goog -n <namespace> -o yaml
```

#### Troubleshoot Backup Failures

```bash
oc get backups.alloydbomni.dbadmin.goog -n <namespace> -o yaml
oc get instancebackups.alloydbomni.internal.dbadmin.goog -n <namespace> -o yaml
oc get backuprepositories.alloydbomni.internal.dbadmin.goog -n <namespace> -o yaml
oc get secret storagegrid-s3-credentials -n <namespace>

# Test StorageGRID connectivity
oc exec -ti <pod-name> -c database -n <namespace> -- \
  curl -sSk https://storagegrid.internal.company.com:18082
```

### 12.9 Lifecycle Operations

```bash
# Stop database
oc patch dbclusters.alloydbomni.dbadmin.goog <n> -n <namespace> \
  --type=merge -p '{"spec":{"primarySpec":{"isStopped":true}}}'

# Start database
oc patch dbclusters.alloydbomni.dbadmin.goog <n> -n <namespace> \
  --type=merge -p '{"spec":{"primarySpec":{"isStopped":false}}}'

# Update database parameters
oc patch dbclusters.alloydbomni.dbadmin.goog <n> -n <namespace> \
  --type=merge -p '{"spec":{"primarySpec":{"parameters":{"max_connections":"200","shared_buffers":"4GB"}}}}'

# Scale compute resources (triggers restart)
oc patch dbclusters.alloydbomni.dbadmin.goog <n> -n <namespace> \
  --type=merge -p '{"spec":{"primarySpec":{"resources":{"cpu":"4","memory":"16Gi"}}}}'

# Apply OpenShift SCC annotation
oc annotate dbclusters.alloydbomni.dbadmin.goog <n> -n <namespace> openshift.io/scc=anyuid
```

#### Delete a Database Cluster

> ⚠️ **Warning:** Deleting a DBCluster is destructive and removes all associated pods, PVCs, and data. Ensure backups exist on StorageGRID before proceeding. This action cannot be undone.

```bash
# Verify backups exist first
oc get backups.alloydbomni.dbadmin.goog -n <namespace>

# Delete
oc delete dbclusters.alloydbomni.dbadmin.goog <n> -n <namespace>

# Verify cleanup
oc get pods,svc,pvc -l alloydbomni.internal.dbadmin.goog/dbcluster=<n> -n <namespace>
```

-----

## 13. Security Architecture

### 13.1 Network Security

- **TLS Encryption:** All database connections use TLS 1.3 (AES-256-GCM-SHA384). Webhook TLS managed by Venafi-backed cert-manager. Inter-pod replication encrypted.
- **Network Policies:** OpenShift SDN enforces NetworkPolicy to restrict database pod access.
- **Service Exposure Control:** `allowExternalIncomingTraffic` flag controls external access.
- **Air-Gap Boundary:** No internet egress. All images, certificates, and configuration pre-staged internally.

### 13.2 Kerberos Authentication & Keytab Integration

- **Kerberos Principal Mapping:** Database users mapped to AD/Kerberos principals. pg_hba.conf configured with GSSAPI entries.
- **Keytab Provisioning:** Keytab files provisioned as Kubernetes Secrets from Vault, mounted into database pods for non-interactive KDC authentication.
- **pg_hba.conf Configuration:** `UserDefinedAuthentication` CRD applies GSSAPI rules specifying Kerberos realm, keytab path, and user mapping.
- **Client Requirements:** Clients must obtain Kerberos ticket (`kinit` or SSPI) before connecting. libpq handles GSSAPI negotiation.

### 13.3 HashiCorp Vault Integration (VPM Model)

- **Vault Secrets Operator (VSO):** Syncs `VaultStaticSecret`/`VaultDynamicSecret` CRs to native Kubernetes Secrets for DBCluster `adminUser.passwordRef`, S3 credentials, and TLS.
- **Vault Agent Sidecar:** Alternative pattern for Kerberos keytab files requiring specific mount paths.
- **Vault Policy Scoping:** Each tenant namespace’s ServiceAccount bound to a Vault role scoped to only its DB Ops secrets path.

> **Secrets Lifecycle:** Vault → VSO sync → Kubernetes Secrets → AlloyDB Omni Operator references in DBCluster/BackupPlan/PgBouncer specs. Password rotation in Vault propagates automatically.

### 13.4 Container Security & Audit

- **UBI 9 Base Images:** Red Hat UBI 9 with CVE patches. Scanned with Aqua Security in ATAAS quarantine.
- **OpenShift SCC:** `openshift.io/scc=anyuid` annotation for predictable UID behavior.
- **Image Provenance:** Artifactory-only. No external registry access. All images pass Aqua scanning.
- **PostgreSQL Audit:** pgaudit extension → `postgresql.audit` → Splunk forwarding.
- **Kubernetes Audit:** OpenShift API server captures all `oc` operations against AlloyDB CRDs.
- **Vault Audit:** All secret access operations logged in Vault’s audit backend.

-----

## 14. References

|Source                                |URL                                                                                                                    |
|--------------------------------------|-----------------------------------------------------------------------------------------------------------------------|
|AlloyDB Omni for Kubernetes Overview  |https://cloud.google.com/alloydb/omni/kubernetes/current/docs/overview                                                 |
|Install AlloyDB Omni on Kubernetes    |https://cloud.google.com/alloydb/omni/current/docs/deploy-kubernetes                                                   |
|AlloyDB Omni Release Notes            |https://docs.cloud.google.com/alloydb/omni/docs/release-notes                                                          |
|DBCluster CRD Reference (v1.4.0)      |https://docs.cloud.google.com/alloydb/omni/kubernetes/current/docs/reference/kubernetes-crds-1.4.0/dbcluster           |
|High Availability and Data Resilience |https://cloud.google.com/alloydb/omni/kubernetes/16.8.0/docs/high-availability/overview                                |
|PgBouncer Connection Pooler           |https://docs.cloud.google.com/alloydb/omni/containers/15.7.0/docs/use-connection-pooler-kubernetes                     |
|Backup and Restore in Kubernetes      |https://cloud.google.com/alloydb/omni/16.3.0/docs/backup-kubernetes                                                    |
|Custom Resource Metrics Reference     |https://docs.cloud.google.com/alloydb/omni/kubernetes/16.8.0/docs/reference/custom-resource-metrics-kubernetes-operator|
|Sidecar Containers in Kubernetes      |https://docs.cloud.google.com/alloydb/omni/containers/16.3.0/docs/kubernetes-sidecar-container                         |
|Configure Log Rotation                |https://cloud.google.com/alloydb/omni/current/docs/configure-log-rotation                                              |
|Configuration Samples                 |https://docs.cloud.google.com/alloydb/omni/kubernetes/current/docs/samples                                             |
|OperatorHub.io - AlloyDB Omni Operator|https://operatorhub.io/operator/alloydb-omni-operator                                                                  |
|OpenShift cert-manager Operator       |https://docs.openshift.com/container-platform/4.14/security/cert_manager_operator/cert-manager-operator-install.html   |

-----

*This document is based on publicly available Google Cloud documentation and internal environment specifications as of March 2026. For the most current information, consult the official Google Cloud documentation at cloud.google.com/alloydb/omni.*