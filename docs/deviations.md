# Deviations from PLAN.md

Every place where the implementation differs from the plan, with the reason.
An empty table means the implementation follows the plan as written. A change
to the plan itself is recorded in the plan's own change log (section 11), not
here.

| Date | Phase | What the plan said | What was done | Why |
|---|---|---|---|---|
| 2026-11-17 | 1 | Create the test cluster with the kind defaults | `kind-cluster.yaml` sets `failCgroupV1: false` and `restrict_oom_score_adj = true` | This sandbox runs cgroup v1 and rootful nodes cannot lower their own oom_score_adj; both settings are harmless on cgroup v2 hosts |
| 2026-11-17 | 1 | Nothing about host settings | `kind-up.sh` raises `fs.inotify.max_user_instances` and `max_user_watches` when it runs as root, and warns otherwise | Ten kind nodes exhaust the kernel default of 128 instances; kind's own documentation asks for these values |
| 2026-11-17 | 1 | Nodes pull images directly | `kind-up.sh` runs `hack/proxy-relay.py` and points node containerd at it when `HTTPS_PROXY` is a loopback address | This sandbox's egress proxy listens on 127.0.0.1 only; CI runners skip the relay |
| 2026-11-17 | 1 | Test object store: MinIO | SeaweedFS 3.99 (S3 gateway), kind only | MinIO's community distribution changed in 2025 (plan change log); SeaweedFS is Apache-2.0 and has a published image |
| 2026-11-17 | 1 | The `local-nvme` tier is backed by local NVMe in kind | Both tiers use the local-path provisioner in kind; the local-csi-driver chart is installed only when `localNvme.driver: helm` | kind has no NVMe devices; the real driver needs AKS |
| 2026-11-17 | 1 | Pins and charts follow the plan | `helm show chart` confirmed the pinned cert-manager chart (`v1.21.3`) and kube-prometheus-stack (`82.16.0`); the local-csi-driver chart and version are not verified (its registry is unreachable from here) | The driver is off in kind; its pin must be checked before the AKS phase |
| 2026-11-17 | 1 | `db-platform-base` creates its own namespaces | Its Helm release record lives in `default` | Helm cannot store a release in a namespace that does not exist yet, and this chart creates `dbaas-system` and `monitoring` |
| 2026-11-17 | 1 | Pod security levels not specified in the plan | `dbaas-system` is `baseline` and `monitoring` is `privileged` | node-exporter needs host namespaces, which `baseline` forbids |
| 2026-11-17 | 1 | Monitoring scrapes every target | kind disables scraping of controller-manager, scheduler, etcd and kube-proxy (`environments/kind/kube-prometheus-stack.yaml`) | These bind to localhost inside kind, so they cannot be scraped; the absence is expected in kind only |
| 2026-11-17 | 1 | Node exporter on every node | node-exporter has `tolerations: []`, so it never runs on database nodes | PLAN section 6 phase 1: nothing but databases tolerates the database taint |
| 2026-11-17 | 1 | CRD schemas for every rendered kind come from upstream | `hack/schemas/apiextensions.k8s.io_CustomResourceDefinition_v1.json` is a hand-written strict schema for the CRD kind | Upstream Kubernetes ships no schema for it at the pinned version, and kubeconform must not skip it |
| 2026-11-17 | 1 | Idempotency is checked by comparing resourceVersions | `tests/e2e/platform.sh` compares declared state (spec, labels, annotations, generation, data), not resourceVersion | Controllers update status and managed fields on their own schedule; a resourceVersion check would fail for reasons that are not configuration changes |
| 2026-11-17 | 1 | cert-manager uses `installCRDs` | It uses `crds.enabled` | cert-manager deprecated `installCRDs` |
| 2026-11-17 | 1 | Helmfile reads the chart version from the environment | Every pin comes from `versions.yaml` through `helmfile.d/00-platform.yaml.gotmpl` | Single source of truth, as PLAN section 0.3 requires |
| 2026-11-18 | 1 | Test-only credentials live under `environments/kind/` | The kind test object store's fixed credentials are the defaults of `charts/test-object-store/values.yaml`, marked TEST ONLY | They are public test values and the chart is never installed outside kind; moving them is a follow-up, not a risk |
| 2026-11-18 | 1 | Chart-generated Grafana admin password | `platform-up.sh` creates `dbaas-grafana-admin` once (if absent) and kube-prometheus-stack reads it | The chart regenerates the password on every apply when it cannot look up the existing Secret; a re-apply rotated the admin password |
| 2026-11-18 | 1 | `platform-up` is one `helmfile sync` | It syncs `db-platform-base` first, then creates the Grafana secret, then syncs the rest | The monitoring namespace must exist before its secret, and the base creates that namespace |
| 2026-11-18 | 2 | Operator control plane runs three replicas (plan section 3 for HA) | Two replicas per component in kind; `values/mariadb-operator.yaml` documents the production value of three | kind has two system nodes; required anti-affinity cannot place three |
| 2026-11-18 | 2 | Operator CRDs installed by the operator chart | Installed by the separate `mariadb-operator-crds` release (`crds.enabled: false`) | Upstream recommends it: uninstalling a chart that owns CRDs deletes every MariaDB instance |
