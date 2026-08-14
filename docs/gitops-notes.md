# GitOps notes

Things worth knowing about the choices in this repo, for anyone using it to
learn the pattern rather than just running it.

## Why app-of-apps instead of a flat list of Applications

The alternative to app-of-apps is applying each child `Application`
(`argocd-ingress`, `headlamp-rbac`, `headlamp`) directly with `kubectl` in
`scripts/bootstrap.sh`. That works, but it means the script is the source of
truth for *which Applications exist* — adding a fourth app means editing the
script, not just adding a file to Git. It also means there's no single
object Argo CD's UI can show you to answer "is the whole lab healthy," and
no single thing to `prune` if you remove an app's manifest from Git.

App-of-apps fixes both: `bootstrap/root-app.yaml` is the only thing applied
by script, and it's just another `Application` — Argo CD manages the child
`Application` objects the same way it manages any other resource, including
pruning one if you delete its template from `apps/templates/`. The
`apps/` chart in this repo happens to render exactly three of them; the
pattern doesn't change if that becomes ten.

## What the sync waves in this repo actually order

`argocd.argoproj.io/sync-wave` on an `Application` object controls the order
in which an app-of-apps *parent* creates/syncs its *children* — it's not
specific to Kubernetes resources within one Application, though it works
the same way there too.

Here, `argocd-ingress` and `headlamp-rbac` are wave `"0"`, `headlamp` is
wave `"1"`. In practice this lab doesn't have a hard runtime dependency
that would break if they synced in the wrong order — the Headlamp Helm
chart creates its own namespace (`CreateNamespace=true`) and its own pod
`ServiceAccount` regardless of what `headlamp-rbac` does. The wave ordering
exists to make the *intent* explicit (prerequisites before workload) and to
demonstrate the mechanism, not because skipping it would break the cluster
today. If a future addition to this lab *does* have a real dependency
(e.g., a `ConfigMap` a chart's `postStart` hook reads), waves are how you'd
enforce that ordering for real.

## What `selfHeal: true` does and doesn't catch

`selfHeal` reverts drift *between what's in Git and what Argo CD's live
state cache says is running* — delete a Deployment, edit a field a
container's image tag, remove a label Argo CD tracks: all reverted, usually
within seconds of the next state-cache update.

What it does **not** catch:

- **Anything not tracked by an `Application`.** If you `kubectl apply` a
  resource that isn't part of any synced `Application`'s manifests, Argo CD
  has no opinion about it — it's simply not in scope. This is why the whole
  point of this lab is *never* running `kubectl apply`/`helm install` for
  Headlamp directly: doing so wouldn't get reverted, it would just create an
  untracked, unmanaged resource.
- **Changes inside a live object that Argo CD doesn't diff.** Some fields
  (certain defaulted/mutated fields, status subresources, fields set by
  other controllers/admission webhooks) aren't part of the sync comparison,
  so drift in them isn't "drift" as far as `selfHeal` is concerned.
- **Out-of-band changes to the Git repo itself.** `selfHeal` reverts the
  *cluster* to match Git — if Git itself is wrong (bad commit merged,
  compromised `REPO_URL`), Argo CD will faithfully apply the wrong thing.
  It's a reconciler, not a policy check; `prune`/`selfHeal` together
  guarantee cluster == Git, not cluster == correct.
- **Timing.** `selfHeal` isn't instantaneous — it reacts on the controller's
  poll/watch cycle, not synchronously with the drift-causing change. For a
  few seconds after `kubectl delete`, the resource is genuinely gone.

## How this differs from Flux (`Kustomization`/`HelmRelease`)

Both land in roughly the same place — declarative, Git-sourced, reconciled,
self-healing — but structure the same ideas differently:

| | Argo CD (this repo) | Flux |
|---|---|---|
| Unit of sync | `Application` (CRD) bundles source + destination + policy | `Kustomization`/`HelmRelease` (separate CRDs), usually paired with a `GitRepository`/`HelmRepository` source object |
| Helm handling | Argo CD renders the chart itself; a `HelmRelease` in this lab would be one `Application` with `sources: [...]` (as `headlamp` here does) | `HelmRelease` delegates to Flux's `helm-controller`, which itself invokes Helm — closer to "real" `helm upgrade` semantics (including Helm's own rollback-on-failure) |
| App-of-apps equivalent | An `Application` whose source is a directory/chart of other `Application` manifests (this repo's `apps/`) | A `Kustomization` whose path contains other `Kustomization`/`HelmRelease` manifests — same idea, no special name for it |
| UI | Built-in web UI (what you're logging into at `argocd.localtest.me`) | No built-in UI; typically paired with something external (Headlamp's Flux plugin, Weave GitOps, etc.) |
| Multi-source values | `sources: [...]` with a `ref:` alias (used here to keep Headlamp's `values.yaml` in Git while pulling the chart from its own repo) | Native: a `HelmRelease` references a `HelmRepository`/`GitRepository` for the chart and a separate `valuesFrom` for values — this is closer to Flux's default shape than Argo CD's |

Neither is "more GitOps" than the other; the practical difference in this
repo would mostly be YAML shape, not behavior.
