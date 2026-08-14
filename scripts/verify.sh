#!/usr/bin/env bash
# Fails loudly if the lab isn't actually in the state it claims to be.
# Runs every check and reports all failures at the end, rather than
# stopping at the first one.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

set -a
# shellcheck disable=SC1091
source versions.env
set +a

fail=0
ok()   { echo "  OK   $*"; }
bad()  { echo "  FAIL $*" >&2; fail=1; }

echo "==> kind cluster"
if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  ok "cluster ${CLUSTER_NAME} exists"
else
  bad "cluster ${CLUSTER_NAME} does not exist"
fi

not_ready="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {print $1}')"
if [[ -z "${not_ready}" && -n "$(kubectl get nodes --no-headers 2>/dev/null)" ]]; then
  ok "all nodes Ready"
else
  bad "node(s) not Ready: ${not_ready:-<no nodes found>}"
fi

echo "==> ingress-nginx"
if kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=10s >/dev/null 2>&1; then
  ok "ingress-nginx-controller rolled out"
else
  bad "ingress-nginx-controller not rolled out"
fi

echo "==> Argo CD applications"
apps_json="$(kubectl get applications -n argocd -o json 2>/dev/null || echo '{"items":[]}')"
app_count="$(echo "${apps_json}" | jq '.items | length')"
if [[ "${app_count}" -lt 4 ]]; then
  bad "expected 4 Applications (root, argocd-ingress, headlamp-rbac, headlamp), found ${app_count}"
else
  ok "found ${app_count} Applications"
fi
while IFS=$'\t' read -r name sync health; do
  if [[ "${sync}" == "Synced" && "${health}" == "Healthy" ]]; then
    ok "Application/${name}: Synced, Healthy"
  else
    bad "Application/${name}: sync=${sync:-<none>} health=${health:-<none>} (expected Synced/Healthy — repo pushed? see README troubleshooting)"
  fi
done < <(echo "${apps_json}" | jq -r '.items[] | [.metadata.name, .status.sync.status, .status.health.status] | @tsv')

echo "==> Headlamp workload"
if kubectl -n headlamp get deployment -l app.kubernetes.io/name=headlamp -o json 2>/dev/null | jq -e '.items[0].status.availableReplicas >= 1' >/dev/null 2>&1; then
  ok "headlamp Deployment available"
else
  bad "headlamp Deployment not available"
fi
if kubectl -n headlamp get pods -l app.kubernetes.io/name=headlamp --no-headers 2>/dev/null | awk '{print $3}' | grep -qx Running; then
  ok "headlamp pod Running"
else
  bad "headlamp pod not Running"
fi

echo "==> HTTP endpoints (via ingress-nginx on localhost:80)"
headlamp_code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${HEADLAMP_HOST}" http://localhost/ || echo '000')"
if [[ "${headlamp_code}" == "200" ]]; then
  ok "http://${HEADLAMP_HOST}/ -> 200"
else
  bad "http://${HEADLAMP_HOST}/ -> ${headlamp_code} (expected 200)"
fi

argocd_code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${ARGOCD_HOST}" http://localhost/ || echo '000')"
if [[ "${argocd_code}" == "200" ]]; then
  ok "http://${ARGOCD_HOST}/ -> 200"
else
  bad "http://${ARGOCD_HOST}/ -> ${argocd_code} (expected 200)"
fi

echo ""
if [[ "${fail}" -eq 0 ]]; then
  echo "verify: all checks passed."
else
  echo "verify: one or more checks FAILED (see above)." >&2
fi
exit "${fail}"
