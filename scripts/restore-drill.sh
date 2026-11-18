#!/usr/bin/env bash
# Restore drill (PLAN.md phase 5): proves that an instance can be restored, end to end.
#
#   scripts/restore-drill.sh <instance> [target-time]
#   scripts/restore-drill.sh --all            every instance with point in time recovery
#
# For each instance: restores to target-time (default: the newest recoverable time),
# checks that the marker table holds rows, deletes the throwaway instance and exits 0.
# Any failure leaves the throwaway in place for inspection and exits non-zero.
#
# The marker table is MARKER_TABLE (default dbaas_drill.marker). It is created by the
# application team that owns the instance, and it must hold rows the drill can count.
#
# Runs on a workstation (KUBE_CONTEXT selects the context) and in the weekly CronJob of
# charts/db-restore-drill, where the script is mounted and the service account has the
# rights it needs. Needs kubectl, jq and the restore-instance.sh next to this script.
set -euo pipefail

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
restore_instance="${RESTORE_INSTANCE:-${here}/restore-instance.sh}"
marker_table="${MARKER_TABLE:-dbaas_drill.marker}"

kc() {
  if [[ -n "${KUBE_CONTEXT:-}" ]]; then
    kubectl --context "${KUBE_CONTEXT}" "$@"
  else
    kubectl "$@"
  fi
}

# drill_one <instance> [target-time]
drill_one() {
  local instance="$1" target="${2:-}" ns restore primary password rows
  ns="db-${instance}"
  restore="${instance}-drill"

  if [[ -z "${target}" ]]; then
    target="$(kc -n "${ns}" get pointintimerecovery "${instance}" -o jsonpath='{.status.lastRecoverableTime}')"
    [[ -n "${target}" ]] || die "${instance}: no recoverable time yet (the first archive has not completed)"
  fi

  cleanup() {
    kc -n "${ns}" delete mariadb "${restore}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kc -n "${ns}" delete pvc -l "app.kubernetes.io/instance=${restore}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kc -n "${ns}" delete secret "${restore}-root" --ignore-not-found >/dev/null 2>&1 || true
  }
  # Only a passing drill deletes its throwaway. A failed one is left for inspection.
  kc -n "${ns}" delete mariadb "${restore}" --ignore-not-found --wait=true >/dev/null 2>&1 || true

  "${restore_instance}" "${instance}" "${target}" "${restore}" || {
    die "${instance}: restore to ${target} failed; ${ns}/${restore} is left for inspection"
  }

  primary="$(kc -n "${ns}" get mariadb "${restore}" -o jsonpath='{.status.currentPrimary}')"
  password="$(kc -n "${ns}" get secret "${restore}-root" -o jsonpath='{.data.password}' | base64 -d)"
  rows="$(kc -n "${ns}" exec "${primary}" -c mariadb -- env MYSQL_PWD="${password}" \
    mariadb --ssl -uroot -N -B -e "SELECT COUNT(*) FROM ${marker_table}")" ||
    die "${instance}: the marker table ${marker_table} could not be read from ${ns}/${restore}"

  if ((rows < 1)); then
    die "${instance}: the marker table ${marker_table} is empty after the restore"
  fi
  cleanup
  echo "restore drill passed: ${instance} restored to ${target}, ${rows} marker rows"
}

case "${1:-}" in
  "")
    die "usage: $0 <instance> [target-time] | --all"
    ;;
  --all)
    instances="$(kc get mariadb -A -l dbaas.local/engine=mariadb -o json |
      jq -r '.items[] | select(.spec.pointInTimeRecoveryRef != null) | .metadata.namespace | sub("^db-"; "")')"
    [[ -n "${instances}" ]] || die "no instance has point in time recovery: nothing to drill"
    failures=0
    while read -r instance; do
      drill_one "${instance}" || failures=$((failures + 1))
    done <<<"${instances}"
    ((failures == 0)) || die "${failures} restore drill(s) failed"
    ;;
  *)
    drill_one "$1" "${2:-}"
    ;;
esac
