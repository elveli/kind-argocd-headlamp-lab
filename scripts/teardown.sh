#!/usr/bin/env bash
# Deletes the kind cluster. Deliberately does NOT run `docker network prune`
# or `docker volume prune` — kind's "kind" bridge network is shared across
# every kind cluster on this host, and a blanket prune would take out
# unrelated clusters. `kind delete cluster` already removes this cluster's
# containers/volumes and drops the shared network only when it's the last
# cluster using it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

set -a
# shellcheck disable=SC1091
source versions.env
set +a

if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  kind delete cluster --name "${CLUSTER_NAME}"
  echo "==> deleted kind cluster ${CLUSTER_NAME}"
else
  echo "==> no kind cluster named ${CLUSTER_NAME}, nothing to do"
fi
