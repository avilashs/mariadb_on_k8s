# Architecture

This page describes the platform layer that every database instance sits on.
The design decisions are in PLAN.md section 2; this page covers what the code
does and what a real environment must provide.

## Layers

| Layer | Chart or file | Installed by | Scope |
|---|---|---|---|
| Node classes and pools | `environments/<env>/platform.yaml` (catalogue); node pools created outside this repository | Human, per cloud | Cluster |
| Platform base | `charts/db-platform-base` | `make platform-up` | Cluster |
| Certificates | cert-manager (pinned chart) | `make platform-up` | Cluster |
| Monitoring | kube-prometheus-stack (pinned chart), `helmfile.d/values/`, `environments/<env>/kube-prometheus-stack.yaml` | `make platform-up` | Cluster |
| Test object store | `charts/test-object-store` | `make platform-up`, kind only | Cluster |
| Instances | `charts/mariadb-instance`, `charts/postgres-instance` (phases 3 and 10) | `make instances-up` (phase 4) | One namespace per instance |

`helmfile.d/00-platform.yaml.gotmpl` orders the layers with `needs`. The
platform base comes first because it creates the priority classes and the
namespaces the others use.

## Node classes

A node class is one VM size with one storage tier. Each node class is realised
as one pool per availability zone, and every node carries:

- `workload=database`, the taint `workload=database:NoSchedule`
- `dbaas.local/node-class=<class>`
- `dbaas.local/storage-tier=<tier>`
- `topology.kubernetes.io/zone=<zone>`

Platform components run on nodes labelled `pool=system` and never tolerate the
database taint. `tests/e2e/platform.sh` checks both properties.

## What a production storage class must provide

`db-platform-base` renders one StorageClass per entry of `storageClasses`. The
provisioner and parameters come from the tier, so a real environment only
changes `storageTiers`. Every class must have:

| Property | Value | Why |
|---|---|---|
| `volumeBindingMode` | `WaitForFirstConsumer` | The volume is created in the zone the pod lands in, so zonal disks work with anti-affinity |
| `reclaimPolicy` | `Retain` | A PersistentVolume outlives its claim; deleting data is a deliberate step |
| `allowVolumeExpansion` | `true` | Volumes grow in place |

On AKS, the `premium-ssd-v2` tier uses `disk.csi.azure.com` with
`skuName: PremiumV2_LRS` and `cachingMode: None`; `iops` and `throughputMbps`
map to `DiskIOPSReadWrite` and `DiskMBpsReadWrite`. The `local-nvme` tier uses
`localdisk.csi.acstor.io`. Its volume claims need the annotation
`localdisk.csi.acstor.io/accept-ephemeral-storage: "true"`, which the instance
chart adds in phase 3.

In kind both tiers use the local-path provisioner. The names, binding rules and
reclaim policy are the same, so charts above this layer are written once.

## Validation

`db-platform-base` refuses to render when a node class names an unknown tier or
storage class, or when its storage class belongs to another tier. Its values
schema rejects unknown keys and wrong types.

## Test environment

`make kind-up` creates a nine-node cluster (control plane, two system workers,
six database workers in two node classes, one per zone) from
`environments/kind/kind-cluster.yaml`. `make platform-up` installs the platform
into it. `make e2e-platform` is the phase 1 acceptance suite.
