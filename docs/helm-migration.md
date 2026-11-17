# Migrating from Kustomize to Helm

How to move all three services from `k8s/<svc>-service/` (plain YAML + Kustomize, applied with
`kubectl apply -k`) to one shared Helm chart, **without recreating anything that is live**.

Read §1–§2 once, then do §3 per service, then §4 once.

---

## 1. What changes

### Before

```
k8s/auth-service/             7 files  ─┐
k8s/recommendations-service/  7 files   ├─ ~90% identical, edited in three places
k8s/league-service/           7 files  ─┘
```

### After

```
helm/
  mini-app-service/           ONE chart, shared by all three services
    Chart.yaml
    values.yaml               shared defaults (proxy image, resource defaults, 1/0 strategy)
    templates/
      _helpers.tpl            labels; selector stays exactly `app: <name>`
      serviceaccount.yaml
      configmap.yaml
      deployment.yaml         app + cloud-sql-proxy native sidecar, probes
      service.yaml
      ingress.yaml
  values/
    auth.yaml                 only what differs per service
    recommendations.yaml
    league.yaml
```

| Per-service value | auth | recommendations | league |
| --- | --- | --- | --- |
| Release name = every object's name | `auth-service` | `recommendations-service` | `league-service` |
| Namespace (`-n`) | `auth` | `recommendations` | `league` |
| Cluster | `vincent-cluster` | `vincent-cluster` | `league-cluster` |
| `containerPort` (also renders `PORT`) | 9999 | 9998 | 9200 |
| `strategy` (maxUnavailable/maxSurge) | 1/0 (default) | 1/0 (default) | **0/1** |
| App CPU request | **100m** | 50m (default) | 50m (default) |
| Proxy CPU request | **50m** | 25m (default) | 25m (default) |
| Cloud SQL instance | `recommendations-app-instance` | `recommendations-app-instance` | `league-app-instance` |
| GSA | `auth-sql` | `recommendations-sql` | `league-sql` |
| Ingress host / static IP | `auth.vincentn.dev` / `auth-service-ip` | `recommendations-be.vincentn.dev` / `recommendations-service-ip` | `be.mvip-league.com` / `league-service-ip` |

### What deliberately did NOT change

| | Why |
| --- | --- |
| Object names, namespaces, selectors | `spec.selector` is immutable, and the KSA name is part of the Workload Identity member `…svc.id.goog[<ns>/<name>]`. Renaming either breaks a live service. |
| Secrets `<svc>-secrets` and `<svc>-origin-tls` | Still created imperatively with `kubectl create secret`. The chart only *references* them, so no credential enters git or Helm's release history. |
| Namespace objects | Not in the chart. A Helm-owned Namespace is deleted on `helm uninstall`, and everything in it goes with it. Existing namespaces stay; a new one is created with `kubectl create namespace` before its Secrets (§3.3). |

### What changed on purpose

| Change | Effect |
| --- | --- |
| Helm standard labels on every object's metadata (`managed-by`, `instance`, `helm.sh/chart`) | Metadata only; never added to selectors or pod labels. |
| `checksum/config` annotation on the pod template | A hash of the ConfigMap's `data`, so editing `config:` or `containerPort` in a values file now rolls the pods by itself — a chart version bump alone does not. `make apply-config` and its explicit restart are no longer needed. **Side effect: the first Helm upgrade restarts each service once** (§3.6). |
| `PORT` rendered from `containerPort` | One number per service instead of two hand-kept copies; the render fails if a values file sets `config.PORT` anyway. |
| Shared env in the chart's `values.yaml` | `APP_ENV`, `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_SSLMODE` were identical in all three services; values files now hold only what differs. The rendered ConfigMaps are unchanged. |
| `config:` values must be strings | An unquoted number would render as e.g. `"1e+06"`; the render now fails instead. |

The render was checked field by field against `kubectl kustomize k8s/<svc>-service` for all three
services: Helm's labels and `checksum/config` are the **only** differences in the output — the
other rows change how the values are written, not what is rendered.

---

## 2. Prerequisites (once)

```bash
helm version            # v3.14+ or v4.x — this repo was verified with v4.3.1
kubectl version --client
gcloud config get account
```

No Helm plugins are needed. Live previews use `kubectl diff`, which ships with kubectl.

Check the chart renders for every service before touching a cluster:

```bash
for s in auth recommendations league; do
  helm lint     helm/mini-app-service -f helm/values/$s.yaml
  helm template $s-service helm/mini-app-service -n $s -f helm/values/$s.yaml > /dev/null
done
```

A missing required value fails here with a clear message (`image.digest is required`, …).

---

## 3. Migrate one service

Do **`league` first**: its `0/1` strategy makes the one-time roll gapless, and it sits on its own
cluster. Then `recommendations`, then `auth` (both take ~30–60 s of 502s, §3.6). As of
2026-11-17 `vincent-cluster`'s node pool is scaled to **0 nodes**, so those two are already down
and `helm --wait` would time out — scale it back to 1 first.
Every block below uses these variables; set them for the service you are migrating:

```bash
SVC=league                      # auth | recommendations | league
NS=$SVC
REL=$SVC-service                # the release name — must be exactly this
CLUSTER=league-cluster          # vincent-cluster for auth and recommendations
```

### 3.1 Point kubectl at the right cluster

```bash
gcloud container clusters get-credentials $CLUSTER --zone asia-southeast1-a
kubectl config current-context        # must end in _$CLUSTER
kubectl get nodes                     # one Ready node
```

Same rule as the Makefile guard: auth and recommendations live on `vincent-cluster`, league on
`league-cluster`. Helm has no guard of its own and will install into whatever context is current.

### 3.2 Check the Secrets exist

The chart does not create them; the pod will not start without them.

```bash
kubectl -n $NS get secret $REL-secrets $REL-origin-tls
```

If either is missing, create it the same way as before (`kubectl create secret …`, see
`docs/<svc>/deploy.md` or `cmd/quick-deploy.sh`). Nothing about this step changes with Helm.

### 3.3 Is the service already live?

```bash
kubectl -n $NS get deploy,svc,ingress,sa,configmap -l app.kubernetes.io/name=$REL
```

- **Objects listed** → it was deployed with `kubectl apply -k`. Continue to 3.4 (adopt).
- **Nothing listed** (a first-ever deploy) → there is nothing to adopt, but the namespace and the
  Secrets must exist before anything else works:
  1. `kubectl create namespace $NS` (if absent) — created outside Helm on purpose (§1).
  2. Create both Secrets (go back to 3.2) — pods without them fail with
     `CreateContainerConfigError`.
  3. Skip 3.4. In 3.5 every object shows as new rather than as a few added lines.

  Do not lean on `helm install --create-namespace` instead: it would create the namespace *after*
  the point where the Secrets had to be in it.

### 3.4 Hand the existing objects to Helm (adopt, do not recreate)

`helm install` on objects it did not create fails with *"invalid ownership metadata"*. The fix is
**not** to delete them — deleting the Ingress releases its load-balancer wiring and the Deployment
causes an outage. Instead, mark each object as owned by the release. Helm then adopts it in place.

```bash
for obj in serviceaccount/$REL configmap/$REL-config deployment/$REL service/$REL ingress/$REL; do
  kubectl -n $NS label    $obj app.kubernetes.io/managed-by=Helm --overwrite
  kubectl -n $NS annotate $obj meta.helm.sh/release-name=$REL \
                               meta.helm.sh/release-namespace=$NS --overwrite
done
```

These are metadata-only edits: no pod restarts, no traffic impact.

Verify all five carry the marks:

```bash
kubectl -n $NS get sa,cm,deploy,svc,ingress \
  -o custom-columns='KIND:.kind,NAME:.metadata.name,RELEASE:.metadata.annotations.meta\.helm\.sh/release-name' \
  | grep -v '<none>'
```

The `Namespace` and both Secrets are left unmarked on purpose (§1) and must stay that way.

### 3.5 Preview against the live cluster

```bash
helm template $REL helm/mini-app-service -n $NS -f helm/values/$SVC.yaml \
  | kubectl diff -f -
```

`kubectl diff` dry-runs on the API server and shows what would actually change. For an adopted
service, **expect exactly**, on each of the five objects:

- `+` two labels: `app.kubernetes.io/instance` and `helm.sh/chart` (`managed-by` was added in
  3.4, and `app.kubernetes.io/name` / `part-of` were already set by Kustomize);
- a changed `kubectl.kubernetes.io/last-applied-configuration` annotation — `kubectl diff`
  previews a client-side apply, which rewrites this record of the last applied manifest every
  time; it is bookkeeping, not a spec change;

and on the Deployment only:

- `+ checksum/config` under `spec.template.metadata.annotations`.

**Stop if you see anything else** — an image, port, env value, resource or selector change means
the values file has drifted from what is live. Fix the values file, not the cluster.

### 3.6 Install

```bash
helm upgrade --install $REL helm/mini-app-service \
  -n $NS -f helm/values/$SVC.yaml \
  --wait --timeout 5m
kubectl -n $NS rollout status deploy/$REL --timeout=5m
```

The new `checksum/config` annotation changes the pod template, so this rolls the pods **once**:

| Service | What the one-time roll looks like |
| --- | --- |
| auth, recommendations | `maxUnavailable: 1` / `maxSurge: 0` — the old pod stops before the new one starts. **Expect ~30–60 s of 502s from Cloudflare.** Do it at a quiet moment. Unavoidable on the full node, same as any image deploy there. |
| league | `maxUnavailable: 0` / `maxSurge: 1` — no gap. |

If Helm 4 reports a server-side-apply **field conflict**, nothing was changed. Re-run the
`kubectl diff` in 3.5 to see which field; if it only concerns values identical to the chart's,
re-run the install with `--force-conflicts`.

### 3.7 Verify

```bash
helm -n $NS list                                    # STATUS deployed, REVISION 1
helm -n $NS get manifest $REL | head                # what Helm now owns
kubectl -n $NS get pods                             # 2/2 Running
kubectl -n $NS logs deploy/$REL -c $REL --tail=20   # "database connected" + listening
make health SVC=$SVC                                # {"ok":true,...}

# The Ingress kept its address — the static IP did not change, so Cloudflare needs nothing
kubectl -n $NS get ingress $REL -o wide
```

Then repeat §3 for the next service.

### 3.8 If something goes wrong

| Situation | Do this |
| --- | --- |
| A later `helm upgrade` broke the service | `helm -n $NS rollback $REL` (to the previous revision). Use this instead of `kubectl rollout undo`, which rolls back the pods but leaves Helm's record pointing at the bad revision. Once CD is enabled, follow it with a `git revert` of the values change, or the next deploy re-applies it. |
| You want to abandon Helm for this service and go back to Kustomize | Delete only Helm's **record**, never the objects: `kubectl -n $NS delete secret -l owner=helm,name=$REL`. Then restore the manifests from before the cutover (`git checkout 3b5c115 -- k8s/$SVC-service`, the last commit with `k8s/`) and `kubectl apply -k k8s/$SVC-service` works as before. |
| **Never** | `helm uninstall $REL` on a live service to "undo" the migration. It deletes the Deployment, Service and Ingress it adopted — a full outage plus the Ingress losing its load balancer. |

---

## 4. Cut over the tooling (once, after all three are on Helm)

**Already made in the `feat/config-helm` branch** — 4.1–4.3 below record what changed. The
ordering rule still applies to *merging* it: do §3 for all three services first. §3 itself needs
nothing from `k8s/` or the old Makefile (only `kubectl` and `helm`), so it can run from this
branch before merge.

Until the cutover, `kubectl apply -k` still works, so the two paths can coexist during migration.
Afterwards Helm must be the **only** writer; a stray `kubectl apply -k` would be overwritten on
the next `helm upgrade` and make `helm rollback` lie.

### 4.1 Makefile

Replace the Kustomize-specific parts. `DEPLOY` already equals the release name.

```make
CHART  := helm/mini-app-service
VALUES := helm/values/$(SVC).yaml
HELM   := helm -n $(NS)

ifeq ($(wildcard $(VALUES)),)
  $(error unknown SVC "$(SVC)" -- try recommendations, auth or league)
endif

.PHONY: diff
diff: check-context ## Preview changes against the live cluster
	helm template $(DEPLOY) $(CHART) -n $(NS) -f $(VALUES) | kubectl diff -f - || true

.PHONY: apply
apply: check-context ## helm upgrade --install and wait
	$(HELM) upgrade --install $(DEPLOY) $(CHART) -f $(VALUES) --wait --timeout 5m
	$(KNS) rollout status deploy/$(DEPLOY) --timeout=5m

.PHONY: rollback
rollback: check-context ## Roll back to the previous Helm revision
	$(HELM) rollback $(DEPLOY) --wait --timeout 5m

.PHONY: history
history: check-context ## Helm revisions for this service
	$(HELM) history $(DEPLOY)
```

- Delete `DIR`, and the `apply-config` target — `checksum/config` makes `apply` roll pods on a
  config change by itself.
- Keep `check-context`, `restart`, `status`, `ps`, `logs`, `logs-proxy`, `events`, `health`
  unchanged; they talk to kubectl, not to the manifests.
- (`|| true` on `diff`: `kubectl diff` exits 1 whenever there *is* a difference.)

### 4.2 `cmd/quick-deploy.sh`

Replace these two lines in step 7:

```bash
kubectl apply -f "k8s/${NAME_SERVICE}/namespace.yaml"
...
kubectl apply -k "k8s/${NAME_SERVICE}"
```

with a namespace that is not Helm-owned, and a Helm install:

```bash
kubectl create namespace "$NAMESPACE_SERVICE" --dry-run=client -o yaml | kubectl apply -f -
...
helm upgrade --install "$NAME_SERVICE" helm/mini-app-service \
    -n "$NAMESPACE_SERVICE" -f "helm/values/${NAMESPACE_SERVICE}.yaml"
```

The `kubectl annotate serviceaccount … iam.gke.io/gcp-service-account` line after it can go: the
chart already sets that annotation from `gcpServiceAccount`, and Helm would revert any drift anyway.

The same change moved the OIDC provider's condition and mapping into `cmd/wif-config.sh`, shared
with `cmd/setup-cd-access.sh`, and corrected the repository owner to `mini-apps-org` — the old
inline `tanvinhnguyen2504/…` condition would have overwritten the live one and broken every
image build.

### 4.3 Remove the Kustomize tree

`k8s/` is deleted. Every reference to it was updated: `README.md` (table, Layout, Quick reference,
the old "Plain YAML + Kustomize, not Helm" paragraph), `docs/gke-parameters.md`,
`docs/troubleshooting.md`, and each service's `prerequisites.md` / `deploy.md` (`kubectl apply -k`
→ `make apply`, `kubectl kustomize` → `helm template` / `make diff`, `rollout undo` →
`make rollback`). The last commit that still has `k8s/` is `3b5c115`.

---

## 5. Day-2: how common changes look now

| Task | Before (Kustomize) | After (Helm) |
| --- | --- | --- |
| Ship a new image | Edit image line in `k8s/<svc>/deployment.yaml`, `make apply` | Edit `image.tag` + `image.digest` in `helm/values/<svc>.yaml`, `make diff`, `make apply` |
| Change an env value | Edit `configmap.yaml`, `make apply-config` (manual restart) | Edit `config:` in the values file, `make apply` (rolls automatically) |
| Undo a bad deploy | `make rollback` (`kubectl rollout undo`) | `make rollback` (`helm rollback`, also restores the ConfigMap) |
| See what is deployed | Read the YAML and hope it was applied | `helm -n <ns> get values <svc>-service` / `make history` |
| Change something for all three services (probe, proxy version, securityContext) | Edit three `deployment.yaml` files | Edit the template or `values.yaml` once |
| Add a fourth service | Copy seven files, rename everything | Add `helm/values/<svc>.yaml`, create its Secrets, `make apply SVC=<svc>` |

### Next step: deploy from CI

A deploy is now "a values file in git + one command", so it can move into GitHub Actions: a
merge to `master` that changes `helm/values/<svc>.yaml` runs `helm upgrade --install` for that
service. The design, the access it needs (a deployer identity, the clusters' DNS endpoint) and
the rollout plan are in [../deployment-workflow-context.md](../deployment-workflow-context.md).
Finish §3 for a service before enabling its deploy workflow — CI cannot do the adoption step.

Argo CD (pull-based) remains the alternative if a controller in each cluster ever fits the CPU
budget; the chart and values files work unchanged with it.
