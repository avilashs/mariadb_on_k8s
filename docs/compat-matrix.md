# Compatibility matrix

Versions this platform is built and tested against. PLAN.md phase 2 requires that
every pinned component has a row here, with the source of each claim, and that
upgrades consult this page first. "Tested" means the version runs in this
repository's acceptance suites; "upstream" means the vendor states it and this
repository has not yet exercised it.

Pins live in `versions.yaml`. Changing a pin without updating this page fails review.

## Kubernetes

| Component | Pin | Kubernetes | Status | Source |
|---|---|---|---|---|
| Test cluster (kind node image) | `v1.36.4` | 1.36 | tested by `make e2e` | `versions.yaml` |
| mariadb-operator | `26.10.2` | 1.31 and later | upstream; 1.36.4 tested in phase 2 | [README](https://github.com/mariadb-operator/mariadb-operator/blob/main/README.md) |
| CloudNativePG | `1.30.1` | 1.34, 1.35, 1.36 | upstream; not yet installed here (phase 10) | [supported releases](https://github.com/cloudnative-pg/cloudnative-pg/blob/main/docs/src/supported_releases.md) |
| cert-manager | `v1.21.3` | not stated in the pinned release | not verified | [releases](https://github.com/cert-manager/cert-manager/releases) |
| kube-prometheus-stack | `82.16.0` (Prometheus Operator v0.89.0) | not stated | not verified | [chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) |

The mariadb-operator README also lists OpenShift 4.18 and later. This platform does
not target OpenShift.

## Database engines

| Component | Pin | Engine versions | Source |
|---|---|---|---|
| mariadb-operator | `26.10.2` | MariaDB Community 10.6 and later; MaxScale 23.08 and later (when MaxScale is enabled) | [README](https://github.com/mariadb-operator/mariadb-operator/blob/main/README.md) |
| MariaDB server | `11.8` (LTS) | point-in-time recovery needs 10.8 and later | [PITR](https://github.com/mariadb-operator/mariadb-operator/blob/main/docs/pitr.md) |
| CloudNativePG | `1.30.1` | PostgreSQL 15 to 18 | [supported releases](https://github.com/cloudnative-pg/cloudnative-pg/blob/main/docs/src/supported_releases.md) |
| PostgreSQL | `18` | per CloudNativePG row above | as above |

## Operator upgrade rules

- **mariadb-operator:** upgrade one release at a time and never skip a release.
  Release `26.10.0` is to be skipped; upstream says to upgrade to `26.10.1` instead.
  Upstream also says to upgrade through each release in turn.
  Source: [releases](https://github.com/mariadb-operator/mariadb-operator/releases).
- **Barman Cloud Plugin:** needs cert-manager. Built-in Barman support in CloudNativePG
  is removed in 1.32; the plugin is used from the start.
  Source: [supported releases](https://github.com/cloudnative-pg/cloudnative-pg/blob/main/docs/src/supported_releases.md).

## Verified in this repository

| Date | Change | Result |
|---|---|---|
| 2026-11-18 | mariadb-operator `26.10.2` installed on the kind test cluster (Kubernetes 1.36.4) | 7 of 7 phase 2 checks pass, including leader loss |

## Add-ons

| Component | Pin | Notes | Source |
|---|---|---|---|
| Query optimizer | commit `8f5454d93271` of `avilashs/query_optimizer` (`versions.yaml`, `queryOptimizer`) | Python 3.12 image built offline by `hack/build-query-optimizer.sh`; connectors for MariaDB, MySQL and PostgreSQL are installed. Tested here by `make unit` (chart tests) and `tests/e2e/query-optimizer.sh` | [repository](https://github.com/avilashs/query_optimizer) |
