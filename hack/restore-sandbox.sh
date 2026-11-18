#!/usr/bin/env bash
# Brings the local kind test environment back after the sandbox restarts (the SessionStart
# hook in .claude/settings.json runs this). Idempotent and quiet: it does nothing that a
# healthy environment does not already have, and it never fails the session. Progress goes
# to .cache/restore-sandbox.log.
#
# Steps, each skipped when it is not needed:
#   1. inotify limits (kind nodes exhaust the kernel default; the reset makes kube-proxy fail)
#   2. the Docker daemon
#   3. the kind cluster and the proxy relay (hack/kind-up.sh, which is idempotent)
#   4. pods stuck in Unknown after a node restart (recreated by their controllers)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="${ROOT}/.cache/restore-sandbox.log"
mkdir -p "${ROOT}/.cache"
exec >>"${LOG}" 2>&1
export PATH="${ROOT}/.bin:${PATH}"
echo "== restore-sandbox $(date -u +%FT%TZ)"

log() { printf '==> %s\n' "$*"; }

# 1. Kernel limits: they reset on every boot.
if [[ $(id -u) == 0 ]]; then
  sysctl -w fs.inotify.max_user_instances=8192 >/dev/null 2>&1
  sysctl -w fs.inotify.max_user_watches=524288 >/dev/null 2>&1
  log "inotify limits set"
fi

# 2. Docker. A restarted sandbox has no daemon.
if ! timeout 15 docker info >/dev/null 2>&1; then
  if command -v dockerd >/dev/null && [[ $(id -u) == 0 ]]; then
    log "starting dockerd"
    nohup dockerd >"${ROOT}/.cache/dockerd.log" 2>&1 &
    for _ in $(seq 1 30); do timeout 5 docker info >/dev/null 2>&1 && break; sleep 2; done
  fi
fi
if ! timeout 15 docker info >/dev/null 2>&1; then
  log "docker is not reachable: nothing else can be restored"
  exit 0
fi

# 3. The cluster and the relay. kind-up.sh is idempotent; it starts the relay on the
# sandbox's current proxy port. It needs the API server, which takes minutes to come up
# after a restart, so wait for its readiness endpoint first.
if kind get clusters 2>/dev/null | grep -qx dbaas; then
  log "kind cluster present: waiting for the API server"
  api_up=0
  for _ in $(seq 1 90); do
    if timeout 10 kubectl --context kind-dbaas get --raw /readyz >/dev/null 2>&1; then api_up=1; break; fi
    sleep 5
  done
  if ((api_up)); then
    log "API server ready: running kind-up.sh (idempotent)"
    timeout 600 "${ROOT}/hack/kind-up.sh" || log "kind-up.sh did not finish: see the log above"
  else
    log "API server not ready after 7.5 minutes: kind-up.sh skipped"
  fi
else
  log "no kind cluster dbaas: create it with make kind-up, then make platform-up and make instances-up"
  exit 0
fi

# 4. Pods left in Unknown by a node restart: delete them so the controllers recreate them.
# Only once the nodes are Ready: deleting pods on a node that is not back yet does nothing.
if timeout 20 kubectl --context kind-dbaas get nodes >/dev/null 2>&1; then
  for _ in $(seq 1 60); do
    notready="$(timeout 20 kubectl --context kind-dbaas get nodes --no-headers 2>/dev/null | awk '$2 != "Ready"' | wc -l)"
    [[ "${notready}" == "0" ]] && break
    sleep 10
  done
  timeout 60 kubectl --context kind-dbaas get pods -A --no-headers 2>/dev/null |
    awk '$4 == "Unknown" {print $1, $2}' |
    while read -r ns pod; do
      log "recreating ${ns}/${pod} (Unknown)"
      timeout 30 kubectl --context kind-dbaas -n "${ns}" delete pod "${pod}" --force --grace-period=0 >/dev/null 2>&1
    done
  log "pods checked"
else
  log "the API server is not reachable: pods not checked"
fi

log "done"
exit 0
