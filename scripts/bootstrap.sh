#!/usr/bin/env bash
# Brings up the kind cluster, ingress-nginx, and Argo CD, then applies the
# single root Application. Everything after that is GitOps — this script
# never touches Headlamp directly.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

set -a
# shellcheck disable=SC1091
source versions.env
set +a

"$ROOT_DIR/scripts/preflight.sh"

echo "==> kind cluster: ${CLUSTER_NAME}"
if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  echo "    already exists, reusing"
else
  envsubst < kind/kind-config.yaml | kind create cluster --config -
fi
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
kubectl wait --for=condition=Ready nodes --all --timeout=180s

echo "==> ingress-nginx: ${INGRESS_NGINX_VERSION}"
kubectl apply -f "${INGRESS_NGINX_MANIFEST}"
# Upstream's kind manifest only constrains scheduling to
# kubernetes.io/os=linux — it no longer pins the controller to the
# ingress-ready=true node. Without that pin the pod can land on a worker,
# which has no hostPort 80/443 published by Docker (only the control-plane
# node does, per kind/kind-config.yaml's extraPortMappings), so the
# ingress silently never reaches localhost. Patch it back in.
kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type merge \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"ingress-ready":"true"}}}}}'
# ingress-nginx's kind manifest sets ttlSecondsAfterFinished: 0 on these
# jobs, so they can complete AND get garbage-collected before `kubectl
# wait` finishes confirming it, which surfaces as a NotFound error rather
# than success. A retry is enough — the vanish race is a sub-second
# window, so a real failure (webhook never completing) still fails loudly.
kubectl -n ingress-nginx wait --for=condition=Complete job -l app.kubernetes.io/component=admission-webhook --timeout=180s \
  || kubectl -n ingress-nginx wait --for=condition=Complete job -l app.kubernetes.io/component=admission-webhook --timeout=30s
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s

echo "==> Argo CD: ${ARGOCD_VERSION} (the one imperative install in this lab)"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side --force-conflicts -f "${ARGOCD_INSTALL_MANIFEST}"
kubectl -n argocd wait --for=condition=Available deployment --all --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

echo "==> Argo CD: switching API server to --insecure (terminates TLS at ingress instead)"
kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge \
  -p '{"data":{"server.insecure":"true"}}'
kubectl -n argocd rollout restart deployment/argocd-server
kubectl -n argocd rollout status deployment/argocd-server --timeout=180s

# Argo CD's default Ingress health check waits for .status.loadBalancer.ingress
# to be populated, which never happens on kind (no cloud LB) — Ingress-owning
# Applications (argocd-ingress, headlamp) would sit at "Progressing" forever
# despite working fine. Override it: an Ingress that exists is healthy here.
# argocd-cm is watched and reloaded live, no restart needed.
echo "==> Argo CD: overriding Ingress health check for non-cloud (no LoadBalancer) clusters"
kubectl -n argocd patch configmap argocd-cm --type merge -p "$(cat <<'PATCH'
data:
  resource.customizations.health.networking.k8s.io_Ingress: |
    hs = {}
    hs.status = "Healthy"
    hs.message = "Ingress considered healthy once created (kind has no cloud LB to populate .status.loadBalancer)"
    return hs
PATCH
)"

echo "==> applying root Application (app-of-apps) — REPO_URL=${REPO_URL} TARGET_REVISION=${TARGET_REVISION}"
envsubst < bootstrap/root-app.yaml | kubectl apply -f -

cat <<EOF

==> bootstrap complete.

Argo CD and ingress-nginx are up. Headlamp, its RBAC, and the Argo CD
ingress are now owned by GitOps and will appear once Argo CD can reach:

  ${REPO_URL} (revision: ${TARGET_REVISION})

If that repo isn't pushed yet, 'kubectl get applications -n argocd' will
show the root app as ComparisonError/Unknown until it is — see README
troubleshooting. Run 'make status' to check, 'make urls' for endpoints.
EOF
