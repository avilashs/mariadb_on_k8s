#!/usr/bin/env bash
# Creates the kind test cluster from environments/kind/kind-cluster.yaml and
# applies the node-class labels and taints of PLAN.md section 7.5.
#
# Idempotent: an existing cluster is kept, and labels and taints are applied
# with --overwrite, so a second run changes nothing.
#
# Sandboxes whose egress goes through a loopback proxy (HTTPS_PROXY pointing at
# 127.0.0.1) get a relay on the kind network, so the node containers can pull
# images through it. CI runners do not need this and skip it.

set -euo pipefail
# shellcheck source=hack/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLUSTER="${KIND_CLUSTER_NAME:-dbaas}"
CONTEXT="kind-${CLUSTER}"
CONFIG="${ROOT}/environments/kind/kind-cluster.yaml"
RELAY_PORT="${KIND_PROXY_RELAY_PORT:-3128}"
export KIND_EXPERIMENTAL_DOCKER_NETWORK="${KIND_EXPERIMENTAL_DOCKER_NETWORK:-kind}"

# Node-class catalogue for the kind environment. Keep in step with
# environments/kind/platform.yaml.
# node name suffix : class : zone
DATABASE_NODES=(
  "kind-pv2:zone-a:pv2"
  "kind-pv2:zone-b:pv2"
  "kind-pv2:zone-c:pv2"
  "kind-nvme:zone-a:nvme"
  "kind-nvme:zone-b:nvme"
  "kind-nvme:zone-c:nvme"
)
SYSTEM_NODE_COUNT=2

start_proxy_relay() {
  local proxy="${HTTPS_PROXY:-${https_proxy:-}}"
  [[ "${proxy}" =~ ^https?://127\.0\.0\.1:([0-9]+)/?$ ]] || return 0
  local upstream="${BASH_REMATCH[1]}"
  local gateway
  gateway="$(docker network inspect "${KIND_EXPERIMENTAL_DOCKER_NETWORK}" \
    -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || true)"
  [[ -n "${gateway}" ]] || return 0
  if ! pgrep -f "proxy-relay.py .* ${RELAY_PORT} ${upstream}" >/dev/null; then
    log "starting proxy relay ${gateway}:${RELAY_PORT} -> 127.0.0.1:${upstream}"
    nohup python3 "${ROOT}/hack/proxy-relay.py" 0.0.0.0 "${RELAY_PORT}" "${upstream}" \
      >"${CACHE}/proxy-relay.log" 2>&1 &
    sleep 1
  fi
  # Nodes must trust the session's proxy CA, and must send their traffic to the
  # relay. Restart containerd only when the drop-in actually changes, so a second
  # run leaves running nodes alone.
  local ca="${CA_BUNDLE:-/root/.ccr/ca-bundle.crt}"
  local dropin wanted node
  dropin="[Service]
Environment=HTTPS_PROXY=http://${gateway}:${RELAY_PORT}
Environment=NO_PROXY=localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,.svc,.cluster.local"
  for node in $(kind get nodes --name "${CLUSTER}"); do
    if [[ -f "${ca}" ]] && ! docker exec "${node}" cmp -s "${ca}" /usr/local/share/ca-certificates/session-proxy.crt 2>/dev/null; then
      docker cp "${ca}" "${node}:/usr/local/share/ca-certificates/session-proxy.crt" >/dev/null
      docker exec "${node}" update-ca-certificates >/dev/null 2>&1 || true
    fi
    wanted="$(printf '%s\n' "${dropin}")"
    if [[ "$(docker exec "${node}" cat /etc/systemd/system/containerd.service.d/proxy.conf 2>/dev/null)" != "${wanted}" ]]; then
      log "routing ${node} through the relay"
      docker exec -i "${node}" sh -c 'mkdir -p /etc/systemd/system/containerd.service.d && cat >/etc/systemd/system/containerd.service.d/proxy.conf && systemctl daemon-reload && systemctl restart containerd' <<<"${wanted}"
    fi
  done
}

# kind runs one kubelet per node, and each kubelet holds inotify instances. The
# kernel defaults are too low for ten nodes; kind's own documentation asks for
# these values. Raise them when we can, and say so when we cannot.
check_inotify_limits() {
  local instances watches
  instances="$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)"
  watches="$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)"
  if ((instances >= 1024 && watches >= 524288)); then
    return 0
  fi
  if [[ "$(id -u)" == "0" ]]; then
    log "raising inotify limits for kind (instances ${instances} -> 1024, watches ${watches} -> 524288)"
    sysctl -w fs.inotify.max_user_instances=1024 fs.inotify.max_user_watches=524288 >/dev/null
  else
    warn "inotify limits are low (instances ${instances}, watches ${watches}); kind nodes may fail with 'too many open files'. Run as root or raise them: sudo sysctl -w fs.inotify.max_user_instances=1024 fs.inotify.max_user_watches=524288"
  fi
}

check_inotify_limits

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  log "kind cluster '${CLUSTER}' exists; keeping it"
else
  log "creating kind cluster '${CLUSTER}'"
  kind create cluster --name "${CLUSTER}" --image "kindest/node:$(pin .kubernetes)" \
    --config "${CONFIG}" --wait 300s
fi

start_proxy_relay

kubectl --context "${CONTEXT}" wait --for=condition=Ready nodes --all --timeout=300s >/dev/null

# Workers in kind are named <cluster>-worker, <cluster>-worker2, ... in creation order.
mapfile -t workers < <(kubectl --context "${CONTEXT}" get nodes \
  -l '!node-role.kubernetes.io/control-plane' -o name | sed 's|^node/||' | sort -V)
((${#workers[@]} == SYSTEM_NODE_COUNT + ${#DATABASE_NODES[@]})) ||
  die "expected $((SYSTEM_NODE_COUNT + ${#DATABASE_NODES[@]})) workers, found ${#workers[@]}"

for i in "${!workers[@]}"; do
  node="${workers[$i]}"
  if ((i < SYSTEM_NODE_COUNT)); then
    kubectl --context "${CONTEXT}" label node "${node}" --overwrite \
      pool=system node-role.kubernetes.io/system= >/dev/null
    continue
  fi
  IFS=: read -r _ zone tier <<<"${DATABASE_NODES[$((i - SYSTEM_NODE_COUNT))]}"
  class="${DATABASE_NODES[$((i - SYSTEM_NODE_COUNT))]%%:*}"
  class="${class#kind-}"
  case "${tier}" in
    pv2) node_class="kind-pv2"; storage_tier="premium-ssd-v2" ;;
    nvme) node_class="kind-nvme"; storage_tier="local-nvme" ;;
    *) die "unknown tier ${tier}" ;;
  esac
  kubectl --context "${CONTEXT}" label node "${node}" --overwrite \
    workload=database \
    "dbaas.local/node-class=${node_class}" \
    "dbaas.local/storage-tier=${storage_tier}" \
    "topology.kubernetes.io/zone=${zone}" \
    "pool=database" >/dev/null
  kubectl --context "${CONTEXT}" taint node "${node}" --overwrite \
    workload=database:NoSchedule >/dev/null
done

log "cluster '${CLUSTER}' is ready: $(kubectl --context "${CONTEXT}" get nodes --no-headers | wc -l | tr -d ' ') nodes"
