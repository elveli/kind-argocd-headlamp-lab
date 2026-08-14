#!/usr/bin/env bash
# Checks the tools this lab needs are present before touching anything.
set -euo pipefail

missing=0

check_bin() {
  local bin="$1" hint="$2"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "MISSING: $bin — $hint" >&2
    missing=1
  fi
}

check_bin docker   "install Docker Desktop (macOS) or Docker Engine (Linux): https://docs.docker.com/get-docker/"
check_bin kind     "brew install kind  (or) go install sigs.k8s.io/kind@latest  — https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
check_bin kubectl  "brew install kubectl  (or) https://kubernetes.io/docs/tasks/tools/#kubectl"
check_bin helm     "brew install helm  (or) https://helm.sh/docs/intro/install/"
check_bin jq       "brew install jq  (or) apt-get install jq"
check_bin envsubst "brew install gettext && brew link --force gettext  (or) apt-get install gettext-base"

if [[ "$missing" -ne 0 ]]; then
  echo "" >&2
  echo "Install the missing tools above, then re-run." >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "MISSING: Docker daemon is not reachable — start Docker Desktop (macOS) or 'sudo systemctl start docker' (Linux), then re-run." >&2
  exit 1
fi

echo "preflight: all required tools present, Docker daemon reachable."
