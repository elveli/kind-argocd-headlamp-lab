SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

include versions.env
export

.PHONY: up down status urls argocd-password headlamp-token argocd-login sync verify logs help

up: ## Bring up kind + ingress-nginx + Argo CD, apply the root Application
	@./scripts/bootstrap.sh

down: ## Delete the kind cluster (no leftovers)
	@./scripts/teardown.sh

status: ## Show node, ingress-nginx, and Argo CD Application status
	@echo "--- nodes ---"; kubectl get nodes 2>/dev/null || echo "no cluster"
	@echo "--- ingress-nginx ---"; kubectl -n ingress-nginx get pods 2>/dev/null || true
	@echo "--- applications ---"; kubectl get applications -n argocd 2>/dev/null || true

urls: ## Print URLs and how to authenticate to each UI
	@echo "Argo CD:  http://$(ARGOCD_HOST)"
	@echo "  user: admin   password: make argocd-password"
	@echo "Headlamp: http://$(HEADLAMP_HOST)"
	@echo "  token (read-only, default): make headlamp-token"
	@echo "  token (cluster-admin):      SA=headlamp-admin make headlamp-token"

argocd-password: ## Print the Argo CD initial admin password
	@kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

headlamp-token: ## Print a short-lived Headlamp login token (SA=headlamp-viewer by default)
	@kubectl -n headlamp create token $${SA:-headlamp-viewer}

argocd-login: ## Log the argocd CLI in against the local ingress (requires the argocd CLI)
	@command -v argocd >/dev/null 2>&1 || { echo "argocd CLI not found: https://argo-cd.readthedocs.io/en/stable/cli_installation/"; exit 1; }
	@argocd login $(ARGOCD_HOST) --insecure --grpc-web --username admin \
	  --password "$$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"

sync: ## Force an immediate refresh+sync of all Applications (auto-sync is already on; this skips the poll interval)
	@for a in root argocd-ingress headlamp-rbac headlamp; do \
	  kubectl -n argocd annotate application $$a argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true; \
	done
	@echo "requested hard refresh on all Applications"

verify: ## Run scripts/verify.sh
	@./scripts/verify.sh

logs: ## Tail Argo CD server and Headlamp logs together (Ctrl-C to stop)
	@trap 'kill 0' EXIT INT TERM; \
	kubectl -n argocd logs deploy/argocd-server -f --prefix=true & \
	kubectl -n headlamp logs deploy/headlamp -f --prefix=true & \
	wait

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*##"}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
