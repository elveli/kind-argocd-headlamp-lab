# kind-argocd-headlamp-lab

A local, Docker-only GitOps lab: a 3-node [kind](https://kind.sigs.k8s.io/)
cluster, [Argo CD](https://argo-cd.readthedocs.io/) bootstrapped onto it, and
[Headlamp](https://headlamp.dev/) deployed as the one and only workload —
**exclusively through Argo CD**, never with a direct `kubectl apply` or
`helm install`. The point of the lab is that last part: everything past the
Argo CD install itself is declared in Git and reconciled by Argo CD, with
`prune` and `selfHeal` on, using the app-of-apps pattern.

No cloud resources, no cost beyond local CPU/RAM/disk. Runs entirely in
Docker containers on your machine.

## Table of contents

- [What this demonstrates](#what-this-demonstrates)
- [Prerequisites](#prerequisites)
- [Repo-source note (read this before `make up`)](#repo-source-note-read-this-before-make-up)
- [Quickstart](#quickstart)
- [Architecture](#architecture)
- [Logging in](#logging-in)
- [Demos](#demos)
- [Verification](#verification)
- [Troubleshooting](#troubleshooting)
- [Teardown](#teardown)
- [Repo layout](#repo-layout)

## What this demonstrates

- Bootstrapping Argo CD with one imperative install, then handing off to
  GitOps for everything else (app-of-apps: a single root `Application` owns
  three child `Application`s).
- `syncPolicy.automated` with `prune: true` and `selfHeal: true` — delete a
  resource by hand and watch Argo CD put it back; remove it from Git and
  watch Argo CD delete it from the cluster.
- Sync waves ordering namespace/RBAC prerequisites before the workload that
  needs them.
- A Helm chart (Headlamp) pulled directly from its upstream chart repo by
  Argo CD, with chart values kept in a separate, reviewable Git file via a
  multi-source `Application` — not inlined, not applied by hand.
- Two comparable RBAC identities (`cluster-admin` vs `view`) for logging
  into the same UI, to make the tradeoff visible instead of defaulting to
  `cluster-admin` everywhere.

## Prerequisites

| Tool | Tested version | Notes |
|---|---|---|
| Docker | 29.x (Docker Desktop on macOS, Docker Engine on Linux) | **daemon must be running** before `make up` |
| [kind](https://kind.sigs.k8s.io/) | 0.32.0+ | |
| kubectl | 1.34+ | |
| Helm | v3 or v4 | only used by `helm template` for local review — Argo CD does the real chart rendering in-cluster |
| jq | 1.7+ | used by `scripts/verify.sh` |
| `envsubst` (gettext) | any | templates `kind-config.yaml` and `bootstrap/root-app.yaml`; not preinstalled on macOS — `brew install gettext && brew link --force gettext` |

`scripts/preflight.sh` (run automatically by `make up`) checks all of the
above and fails with an install hint if anything's missing or Docker isn't
reachable.

Every pinned version (kind node image, ingress-nginx, Argo CD, Headlamp
chart) lives in [`versions.env`](versions.env) — bump one there and re-run
`make up`.

## Repo-source note (read this before `make up`)

Argo CD's root `Application` points at a **public GitHub repo**
(`REPO_URL` / `TARGET_REVISION` in `versions.env`, default
`https://github.com/elveli/kind-argocd-headlamp-lab.git` @ `main`) — not an
in-cluster git server. That means:

- `make up` brings up the cluster, ingress-nginx, and Argo CD regardless.
- The root `Application` (and everything under it) will show
  `ComparisonError` / `Unknown` until this repo is actually pushed to that
  URL and publicly reachable. That's expected, not a bug — see
  [Troubleshooting](#troubleshooting).
- If you fork this, update `REPO_URL` in `versions.env` before pushing.

## Quickstart

```sh
git clone https://github.com/elveli/kind-argocd-headlamp-lab.git
cd kind-argocd-headlamp-lab
make up        # kind cluster -> ingress-nginx -> Argo CD -> root Application
make verify    # fails loudly if anything isn't actually healthy
make urls      # prints both UIs' URLs and how to authenticate
```

`make up` is idempotent — re-running it against an existing cluster
converges rather than erroring.

## Architecture

```
  Docker host (macOS/Linux)
  localhost:80/:443
        |
        v
  +------------------------------------------------------------+
  | kind network                                                |
  |                                                              |
  |  control-plane node (hostPort 80/443 -> containerPort 80/443)|
  |  +--------------------------------------------------------+ |
  |  | ingress-nginx controller (IngressClass: nginx)         | |
  |  +-------------------------+------------------------------+ |
  |     host: argocd.localtest.me   host: headlamp.localtest.me |
  |              |                          |                   |
  |              v                          v                   |
  |     +----------------+          +----------------+          |
  |     | argocd-server  |          |    headlamp    |          |
  |     | ns: argocd     |          |   ns: headlamp  |          |
  |     | (--insecure)   |          +--------^-------+          |
  |     +-------+--------+                    |                  |
  |             | app-of-apps                 | Helm chart +     |
  |             | watches & syncs             | values.yaml      |
  |             v                              | (from Git)       |
  |     Applications: root -> argocd-ingress, headlamp-rbac, --+ |
  |                    headlamp -----------------------------/  |
  |                                                              |
  |  worker node 1                    worker node 2              |
  +------------------------------------------------------------+
                              ^
                              | git clone / poll (REPO_URL @ TARGET_REVISION)
                              |
                 github.com/elveli/kind-argocd-headlamp-lab
```

## Logging in

**Argo CD** — http://argocd.localtest.me

```sh
make argocd-password   # prints the initial admin password
```
Username `admin`. The Argo CD API server runs with `--insecure` (plain HTTP
behind the ingress) — see [docs/gitops-notes.md](docs/gitops-notes.md) for
why that's fine for a local lab and not for anything else.

**Headlamp** — http://headlamp.localtest.me

```sh
make headlamp-token                    # read-only (view) token — documented default
SA=headlamp-admin make headlamp-token  # cluster-admin token, for when you need to edit something
```
Paste the token into Headlamp's token login screen. Tokens are short-lived
(`kubectl create token` defaults to ~1h) — re-run the command when it
expires rather than trying to refresh in place.

## Demos

**Self-heal** — delete Headlamp's Deployment by hand and watch Argo CD put
it back within a few seconds (`selfHeal: true` reacts to drift without
waiting for the next poll):
```sh
kubectl -n headlamp delete deployment headlamp
kubectl -n headlamp get deployment headlamp -w   # recreated automatically
```

**Prune** — remove one of the two ClusterRoleBindings from
`manifests/headlamp/rbac/clusterrolebindings.yaml`, commit, push, and watch
Argo CD delete the corresponding cluster object (`prune: true`):
```sh
kubectl get clusterrolebinding headlamp-admin headlamp-viewer
# edit + commit + push the removal, then:
make sync
kubectl get clusterrolebinding headlamp-admin headlamp-viewer   # one is gone
```

## Verification

`make verify` (`scripts/verify.sh`) checks, and fails loudly if any of
these don't hold: kind cluster exists and all nodes `Ready`; ingress-nginx
controller rolled out; root + all 3 child Applications `Synced` and
`Healthy`; Headlamp pod `Running` and Deployment available;
`http://headlamp.localtest.me/` and `http://argocd.localtest.me/` both
answer `200` through the ingress. Wired into CI — see
[.github/workflows/ci.yaml](.github/workflows/ci.yaml).

## Troubleshooting

**Port 80/443 already in use on the host.** Something else (another
ingress controller, a local dev proxy) is bound to 80/443. Stop it, or
change the `hostPort` values in `kind/kind-config.yaml` and the URLs you
use accordingly — `*.localtest.me` always resolves to 127.0.0.1, so you'd
hit it as `http://argocd.localtest.me:8080` etc.

**`*.localtest.me` doesn't resolve.** It's a public wildcard DNS record
(`*.localtest.me -> 127.0.0.1`) maintained outside this repo — if your
network blocks external DNS or hijacks it, resolution will fail. Test with
`dig +short argocd.localtest.me`; if that doesn't return `127.0.0.1`, add
entries to `/etc/hosts` manually as a workaround.

**Argo CD shows `ComparisonError` on the root or child Applications.**
Almost always means Argo CD can't reach `REPO_URL`@`TARGET_REVISION` from
`versions.env` — either it isn't pushed yet, the repo is private, or the
branch name doesn't match. Check:
```sh
kubectl -n argocd get application root -o jsonpath='{.status.conditions}'
```
Push the repo (or fix `REPO_URL`/`TARGET_REVISION`) and re-run `make sync`.

**Want the detail behind an Application's Summary/Sources/Events tabs in
the Argo CD UI, from the CLI instead?**
```sh
RES=application/headlamp NS=argocd make describe
```
`describe` defaults `NS` to `headlamp` (for workload resources), so
Applications — which live in `argocd` — need `NS=argocd` explicitly. Covers
annotations, sources, sync policy, health/sync status, and Events in one
shot. For raw untruncated fields (e.g. full annotation values) or the
Manifest tab's target state: `kubectl get application headlamp -n argocd -o
yaml`.

**Headlamp token stopped working.** `kubectl create token` tokens expire
(~1h default). Re-run `make headlamp-token`; there's no persistent
credential by design.

**`make up` hangs on the Argo CD or ingress-nginx wait steps.** Check
`docker stats` — kind clusters need real CPU/RAM; if Docker Desktop's
resource limits are too low, pods will sit `Pending`. Check with
`kubectl get pods -A` and `kubectl describe pod <name> -n <ns>`.

## Teardown

```sh
make down   # kind delete cluster — removes this cluster's containers/volumes
```
`make down` deliberately does **not** run `docker network prune` / `docker
volume prune`: kind's `kind` bridge network is shared across every kind
cluster on your machine, and a blanket prune would take out unrelated
clusters. `kind delete cluster` already scopes correctly to just this one.

## Repo layout

```
kind-argocd-headlamp-lab/
├── Makefile                    # up/down/status/urls/verify/... entrypoints
├── versions.env                # every pinned version + REPO_URL/TARGET_REVISION
├── kind/kind-config.yaml       # 1 control-plane + 2 workers, envsubst'd at bootstrap
├── scripts/
│   ├── preflight.sh            # tool + Docker daemon checks
│   ├── bootstrap.sh            # kind -> ingress-nginx -> Argo CD -> root Application
│   ├── teardown.sh             # kind delete cluster
│   └── verify.sh               # make verify
├── bootstrap/
│   ├── root-app.yaml           # the ONE Application applied by script
│   └── argocd-ingress/         # Ingress for argocd.localtest.me (GitOps-owned)
├── apps/                       # Helm chart rendering the 3 child Applications
├── manifests/headlamp/
│   ├── rbac/                   # 2 ServiceAccounts + 2 ClusterRoleBindings
│   └── values.yaml             # Helm values for the upstream Headlamp chart
├── docs/gitops-notes.md
└── .github/workflows/ci.yaml   # make up -> verify -> down on a Linux runner
```
