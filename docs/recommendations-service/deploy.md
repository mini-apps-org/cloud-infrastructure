# Deploying `recommendations-service` — step by step

One linear path from nothing to a pod serving `GET /api/v1/health` and `GET /api/v1/places` over
a public HTTPS host — see [edge-architecture.md](../edge-architecture.md).

Unlike auth-service, **nothing here is pre-done**. There is no GSA, no Artifact Registry repo, no
image, no Secret — and the cluster has no room for the pod. Steps 1–5 are all first-time work.

**Prerequisites and every parameter:** [prerequisites.md](./prerequisites.md).
**When something breaks:** [troubleshooting.md](../troubleshooting.md).
**Field-by-field manifest rationale:** [prerequisites.md §7](./prerequisites.md#7-every-deployment-parameter).

| | |
| --- | --- |
| **Goal** | `2/2 Running`, `database connected`, health 200 and `/places` 200 |
| **Time** | ~25 min (step 1 ~2 min, step 4 ~5 min, the rest is fast) |
| **Image** | built here — none exists yet |
| **Destructive** | step 1 resizes the node pool (additive, non-destructive). Nothing else touches existing infrastructure |
| **Source** | `../recommendations-be` |

> ### What this deploy does and does not prove
> A green `/api/v1/health` validates Workload Identity, the Cloud SQL proxy, the Secret, the
> probes and the networking — but **not the schema**. `healthCheck` marshals two config strings
> and never touches the pool, so the pod goes `Ready` whether or not `gm_places` exists. Step 7
> therefore ends on `GET /api/v1/places`, which is the first request that actually needs the
> database to contain something.

---

## Step 0 — Preflight

Never skip this. `kubectl`'s token comes from the **active gcloud configuration**, so a context
pointing at `vincent-cluster` is not sufficient on its own.

```bash
kubectl config current-context    # gke_vincent-mini-apps-project_asia-southeast1-a_vincent-cluster
gcloud config get account         # vinhnguyentan99@gmail.com
gcloud config get project         # vincent-mini-apps-project
kubectl get nodes
```

If `kubectl` returns `Forbidden`, the account is wrong — not the context.

---

## Step 1 — CPU budget ✅ resolved, nothing to run

This pod fits on the single node, but only because its requests were shrunk to **50m app + 25m
proxy** (auth-service uses 100m + 50m). The node is now at **926m of 940m** requested — 98%.

```bash
kubectl describe node -l cloud.google.com/gke-nodepool=minimal-pool \
  | sed -n '/Allocated resources/,/^Events/p'
# cpu  926m (98%)
```

That was the cheapest of three options, not the best one: it leaves no room for anything else
(which is why `league-service` cannot be deployed) and a Go HTTP server paging a large table on
50m will throttle. Adding a second node, or moving to `e2-standard-2`, is still the real fix —
[cpu-capacity-options.md](./cpu-capacity-options.md) has the commands and the tradeoffs.

---

## Step 2 — Artifact Registry repository

```bash
gcloud artifacts repositories create recommendations-repository \
  --repository-format=docker \
  --location=asia-southeast1 \
  --description="recommendations-service images"

gcloud artifacts repositories list --format='table(name,format,location)'
```

`asia-southeast1` matters: it is where the cluster is, and a cross-region pull is slower and
billed as egress. A separate repo per service keeps retention policies independent.

---

## Step 3 — Workload Identity for this service

Links 1 and 2 (cluster identity pool, node pool `GKE_METADATA`) are **cluster-wide and already
done** for auth-service — do not re-run them, the metadata-mode change recreates nodes. Links 3
and 4 are per-service and new:

```bash
P=vincent-mini-apps-project
GSA="recommendations-sql@${P}.iam.gserviceaccount.com"

gcloud iam service-accounts create recommendations-sql \
  --display-name="recommendations-service Cloud SQL client"

# GSA -> Cloud SQL: this identity may connect
gcloud projects add-iam-policy-binding "$P" \
  --member="serviceAccount:${GSA}" \
  --role="roles/cloudsql.client"

# KSA -> GSA: this pod may act as that identity.
# "recommendations" is the namespace, "recommendations-service" the KSA --
# both from k8s/recommendations-service/.
gcloud iam service-accounts add-iam-policy-binding "$GSA" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${P}.svc.id.goog[recommendations/recommendations-service]"
```

```bash
# verify both, because they fail independently
gcloud projects get-iam-policy "$P" --flatten='bindings[].members' \
  --filter="bindings.members:${GSA}" --format='table(bindings.role)'   # => roles/cloudsql.client
gcloud iam service-accounts get-iam-policy "$GSA" --format=json | grep workloadIdentityUser
```

The two bindings point in **opposite directions** and this is the part that is easy to
half-finish. Missing the second one is silent: the proxy falls back to the node's identity rather
than erroring at startup, and the failure surfaces much later as a Cloud SQL rejection naming
`225614846438-compute@…`.

Step 7 check 6 verifies which identity the pod *actually* got, which is the only check that
matters.

---

## Step 4 — Build and push the image

`recommendations-be` has **no `image-push` Makefile target**, so this is explicit.

```bash
cd ../recommendations-be

gcloud auth configure-docker asia-southeast1-docker.pkg.dev

AR_IMAGE=asia-southeast1-docker.pkg.dev/vincent-mini-apps-project/recommendations-repository/recommendations-service

docker buildx build --platform linux/amd64 --target runtime \
  -t $AR_IMAGE:0.0.1 --push .

cd ../cloud-infrastructure
```

### ⚠️ `--platform linux/amd64` is the one flag you cannot forget

This laptop is arm64; the GKE nodes are amd64. A natively built image pushes and pulls without
complaint, then fails on the node with **`exec format error`** — which looks nothing like an
architecture problem. `--target runtime` selects the distroless stage rather than the builder.

```bash
# verify the architecture BEFORE deploying
gcloud artifacts docker images describe $AR_IMAGE:0.0.1 \
  --format='value(image_summary.digest)'
docker buildx imagetools inspect $AR_IMAGE:0.0.1 | grep -i platform
# want: linux/amd64
```

<details>
<summary>Worth adding to <code>recommendations-be/Makefile</code> — expand</summary>

So the flag stops being something to remember. This mirrors what `auth-be` already has:

```makefile
# +-------------------+
# | image / registry  |
# +-------------------+
# --platform linux/amd64 is required, not optional: this machine is arm64 and
# the GKE nodes are e2-medium (amd64). A natively-built image would fail on the
# node with "exec format error".
DOCKER    := $(shell which docker)
AR_HOST   := asia-southeast1-docker.pkg.dev
AR_IMAGE  := $(AR_HOST)/vincent-mini-apps-project/recommendations-repository/recommendations-service
TAG       ?= $(shell git rev-parse --short HEAD)

.PHONY: ar-login
ar-login:
	gcloud auth configure-docker $(AR_HOST)

.PHONY: image-push
image-push:
	$(DOCKER) buildx build --platform linux/amd64 --target runtime \
	  -t $(AR_IMAGE):$(TAG) --push .

# Same build, kept local, to inspect before pushing.
.PHONY: image
image:
	$(DOCKER) buildx build --platform linux/amd64 --target runtime \
	  -t $(AR_IMAGE):$(TAG) --load .
```

`auth-be` tags by commit SHA by default rather than `:latest` — a mutable tag makes a rollout
non-deterministic and `kubectl rollout undo` meaningless.

</details>

---

## Step 5 — Secret

The namespace must exist first, because the Secret is created imperatively and is deliberately
**not** in `kustomization.yaml` — that is what keeps credentials out of this repo.

```bash
kubectl apply -f k8s/recommendations-service/namespace.yaml

kubectl -n recommendations create secret generic recommendations-service-secrets \
  --from-literal=DB_PASSWORD='<the postgres password for recommendations-app-instance>' \
  --from-literal=GOOGLE_OAUTH_CLIENT_ID='<from GCP console>' \
  --from-literal=GOOGLE_OAUTH_CLIENT_SECRET='<from GCP console>' \
  --from-literal=ENCRYPTION_KEY="$(openssl rand -base64 32)"
```

```bash
# verify all four keys are present
kubectl -n recommendations get secret recommendations-service-secrets \
  -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
```

### Why a recommendations service needs three OAuth values it never uses

`config.Load()` ends with a validation loop over `GOOGLE_OAUTH_CLIENT_ID`,
`GOOGLE_OAUTH_CLIENT_SECRET`, `google_oauth_redirect_url` and `ENCRYPTION_KEY`, returning
`config: <NAME> is required` for any empty one. It runs unconditionally — before anything asks
whether this build has auth routes, and `router.go` registers only `/health` and `/places`. So
the values are inert but mandatory. `main.go` turns the error into `log.Fatalf`, i.e.
**CrashLoopBackOff**; a *missing Secret* fails earlier and differently, as
`CreateContainerConfigError`.

`google_oauth_redirect_url` is the fourth required value and is not an environment variable: it
comes from the embedded `production.yaml` and is already non-empty.

`ENCRYPTION_KEY` only needs to be non-empty here — `secret.NewBox`, which enforces the 32-byte
AES-256 length, is never called by this service. Generate a real one anyway; it costs nothing and
a placeholder would fail at request time rather than boot time the day a route starts using it.

<details>
<summary>Rotating a value later — expand</summary>

Editing a Secret does **not** roll the pod. Replace, then restart:

```bash
kubectl -n recommendations create secret generic recommendations-service-secrets \
  --from-literal=... --dry-run=client -o yaml | kubectl apply -f -
kubectl -n recommendations rollout restart deploy/recommendations-service
```

Rotating the `postgres` password affects **auth-service too** — it is the same instance
superuser. A dedicated `recommendations_app` user avoids that; see
[prerequisites.md §6.2](./prerequisites.md#62-the-gm_places-table-must-already-exist).

</details>

---

## Step 6 — Pin the image digest

The manifest ships with a tag-only reference because no image existed when it was written. Now
one does, so pin it — `imagePullPolicy: IfNotPresent` is only safe while the reference cannot
change meaning:

```bash
gcloud artifacts docker images describe \
  asia-southeast1-docker.pkg.dev/vincent-mini-apps-project/recommendations-repository/recommendations-service:0.0.1 \
  --format='value(image_summary.digest)'
```

Then edit `k8s/recommendations-service/deployment.yaml`, keeping **both** tag and digest — the
digest resolves, the tag documents:

```yaml
image: asia-southeast1-docker.pkg.dev/.../recommendations-service:0.0.1@sha256:<digest>
```

Without this, a re-pushed `0.0.1` plus `IfNotPresent` means some pods run old bytes and
`kubectl rollout undo` means nothing — undo would re-pull whatever the tag points at today.

---

## Step 7 — Apply

```bash
# dry read: see exactly what will be sent
kubectl kustomize k8s/recommendations-service

# sanity-check the invariants in that output before sending it
kubectl kustomize k8s/recommendations-service \
  | grep -E 'containerPort|targetPort|PORT:|maxUnavailable|DATABASE_URL'
# want: PORT: "9998" / containerPort: 9998 / targetPort: http / maxUnavailable: 1
# and NO DATABASE_URL line at all (invariant 7)

kubectl apply -k k8s/recommendations-service
kubectl -n recommendations rollout status deploy/recommendations-service --timeout=5m
```

Use `kubectl kustomize`, not `kubectl apply --dry-run=server`: server-side dry-run never persists
the Namespace, so every namespaced object fails with `namespaces "recommendations" not found`.
That is an artifact of the dry run, not a manifest bug.

### If you changed only `configmap.yaml`

There is no `configMapGenerator`, so the ConfigMap has no name hash and editing it does **not**
roll the Deployment — the running pod keeps the old environment. This is required:

```bash
kubectl -n recommendations rollout restart deploy/recommendations-service
```

### What gets applied

| File | Role |
| --- | --- |
| `namespace.yaml` | namespace `recommendations` |
| `service-account.yml` | KSA `recommendations-service`, annotated with the `recommendations-sql` GSA — the Workload Identity link |
| `configmap.yaml` | non-secret env: `APP_ENV`, `PORT=9998`, `DB_*`, URLs |
| `deployment.yaml` | app container + `cloud-sql-proxy` **native sidecar** |
| `service.yaml` | `ClusterIP` :80 → :9998 (by port name `http`), NEG-annotated |
| `ingress.yaml` | `gce` Ingress: `recommendations-be.vincentn.dev`, global static IP, Origin CA TLS |

Five parameters each prevent a specific failure, four of them already observed on auth-service:

1. **The proxy is a native sidecar** (`initContainers` + `restartPolicy: Always`). `db.Connect`
   Pings the pool and `main.go` `log.Fatalf`s on failure, so the app exits rather than retrying;
   an ordinary sidecar starts *in parallel* and lets the app lose that race.
2. **The proxy's startup probe is `httpGet /startup` on 9090**, not `tcpSocket` on 5432. Kubelet
   probes from outside the pod's network namespace and dials the pod IP, while the DB tunnel
   binds `127.0.0.1` only — a tcpSocket probe there can *never* pass.
3. **`maxUnavailable: 1` / `maxSurge: 0`.** Two copies of this pod do not fit on one `e2-medium`;
   the usual `0`/`1` pair deadlocks the rollout with the new pod `Pending` on `Insufficient cpu`.
4. **`runAsUser` is deliberately unset.** The distroless `:nonroot` base already sets numeric UID
   65532, and that numeric form is what lets Kubernetes verify `runAsNonRoot`.
5. **`DATABASE_URL` is deliberately absent.** `ConnectDatabaseString()` *prefers* it over every
   `DB_*` value, so setting it would silently route the app past its own sidecar.

---

## Step 8 — Verify, in layers

Each command isolates a different layer. Run them in order; the first failure tells you where to
look.

```bash
# 1. the pod was scheduled and the sidecar got past its probe
kubectl -n recommendations get pods -l app=recommendations-service
# want: 2/2 Running, 0 restarts.
# Pending     -> step 1 did not take; it is the CPU budget
# Init:*      -> the proxy has not passed startup yet
```

```bash
# 2. the proxy authenticated and connected
kubectl -n recommendations logs deploy/recommendations-service -c cloud-sql-proxy --tail=20
# want: "Authorizing with Application Default Credentials"
#       "Listening on 127.0.0.1:5432"
#       "The proxy has started successfully and is ready for new connections!"
```

Those three lines **followed by** `SIGTERM signal received` mean the proxy is healthy and its
*probe* is what is failing — check `--health-check`, `--http-address=0.0.0.0` and
`--http-port=9090` against the probe's port. Exit code 143 is 128 + 15, i.e. SIGTERM, not a crash.

```bash
# 3. the app connected and is serving
kubectl -n recommendations logs deploy/recommendations-service -c recommendations-service
# want: "database connected (127.0.0.1:5432/recommendations-backend)"
#       "listening on :9998"
```

Both lines sit immediately after code that `log.Fatalf`s on failure, which is what makes them a
real success signal rather than a hopeful one. `127.0.0.1` is correct — the app talks to the
sidecar, which holds the TLS connection to Cloud SQL.

```bash
# 4. the Service actually selected the pod
kubectl -n recommendations get endpointslice \
  -l kubernetes.io/service-name=recommendations-service \
  -o jsonpath='{.items[*].endpoints[*].addresses}{"\n"}'
# want an IP. Empty means the selector matches no *ready* pod (invariants 4 and 5).
```

```bash
# 5. end to end, without involving the load balancer
kubectl -n recommendations port-forward deploy/recommendations-service 8080:9998 &
curl -s localhost:8080/api/v1/health      # => {"env":"production","image":""}
kill %1

# through the public host (see edge-architecture.md)
make health SVC=recommendations
```

`env: "production"` confirms `APP_ENV` selected the embedded `production.yaml` rather than the
development default — it is the only externally observable proof of that. `image` is always empty:
`Config.Image` is declared but never assigned in `config.Load()`.

```bash
# 6. the identity the pod actually got -- not the one you configured
kubectl -n recommendations exec deploy/recommendations-service -c cloud-sql-proxy -- \
  curl -s -H 'Metadata-Flavor: Google' \
  'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email'
# want recommendations-sql@vincent-mini-apps-project.iam.gserviceaccount.com,
# NOT  225614846438-compute@developer.gserviceaccount.com
```

```bash
# 7. THE ONE THAT PROVES THE SCHEMA -- a real database read
curl -s "http://$IP/api/v1/places?limit=1"
# want: {"count":…,"data":[…],"metadata":{…}}
# a 500 here with a green /health is the missing-table case
```

Check 7 is not optional. Checks 1–6 are all compatible with an empty database: `healthCheck`
never touches the pool, so `/health` is green whether or not `gm_places` exists.
`recommendations-be` ships no migrations — its `Makefile` points `migrate` at a `./db/migrations`
directory that is not in the repo — so whatever created that table lives elsewhere. See
[prerequisites.md §6.2](./prerequisites.md#62-the-gm_places-table-must-already-exist).

---

## Routine redeploy

```bash
# manifest change
kubectl apply -k k8s/recommendations-service
kubectl -n recommendations rollout status deploy/recommendations-service

# ConfigMap-only change -- the restart is REQUIRED, see step 7
kubectl apply -k k8s/recommendations-service
kubectl -n recommendations rollout restart deploy/recommendations-service
kubectl -n recommendations rollout status deploy/recommendations-service

# no change, just bounce it
kubectl -n recommendations rollout restart deploy/recommendations-service
```

### Shipping a new image

```bash
cd ../recommendations-be
AR_IMAGE=asia-southeast1-docker.pkg.dev/vincent-mini-apps-project/recommendations-repository/recommendations-service
docker buildx build --platform linux/amd64 --target runtime -t $AR_IMAGE:0.0.2 --push .
gcloud artifacts docker images describe $AR_IMAGE:0.0.2 --format='value(image_summary.digest)'
```

Then pin **both** tag and digest in `deployment.yaml` and apply. Never move a tag that is already
deployed.

### Rolling back

```bash
kubectl -n recommendations rollout history deploy/recommendations-service
kubectl -n recommendations rollout undo deploy/recommendations-service
```

This works *because* images are digest-pinned. With a floating tag, an undo would re-pull
whatever that tag points at today and mean nothing.

---

## Exit checklist

- [ ] Node pool has 2 nodes and ≥150m CPU free where the pod landed
- [ ] GSA `recommendations-sql` exists; both IAM bindings verified
- [ ] `recommendations-repository` exists in `asia-southeast1`
- [ ] Image built with `--platform linux/amd64`, pushed, **digest pinned** in `deployment.yaml`
- [ ] Secret has all four keys; `ENCRYPTION_KEY` stored outside the cluster
- [ ] Exactly **one** pod, `2/2 Running`, `0` restarts
- [ ] Proxy logs show `ready for new connections`, with no `SIGTERM` after it
- [ ] App logs show `database connected` and `listening on :9998`
- [ ] EndpointSlice for `recommendations-service` is non-empty
- [ ] `curl http://$IP/api/v1/health` → `{"env":"production","image":""}`
- [ ] Pod identity is `recommendations-sql@…`, not the compute default
- [ ] **`curl http://$IP/api/v1/places?limit=1` returns rows** (step 8 check 7)

Something failed → [troubleshooting.md](../troubleshooting.md), organised by the error in front of
you.
