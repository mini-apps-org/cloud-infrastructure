# cloud-infrastructure

Kubernetes manifests and deployment runbooks for the `my-mini-apps` services on GKE.

Covers three services:

| Service | Source | Namespace | Manifests | Docs | State |
| --- | --- | --- | --- | --- | --- |
| **`auth-service`** | `../auth-be` | `auth` | `k8s/auth-service/` | [docs/](docs/auth-service/prerequisites.md) | live on `https://auth.vincentn.dev` (Cloudflare + GCE Ingress) |
| **`recommendations-service`** | `../recommendations-be` | `recommendations` | `k8s/recommendations-service/` | [docs/recommendations-service/](docs/recommendations-service/prerequisites.md) | live on `https://recommendations-be.vincentn.dev` (Cloudflare + GCE Ingress), `2/2 Running` |
| **`league-service`** | `../../league/league-be` | `league` | `k8s/league-service/` | [docs/league-service/](docs/league-service/prerequisites.md) | **reserved — not deployed.** Manifests complete and `kustomize`-valid; no GSA, registry repo, image, static IP or Secret exists yet, and the node has no CPU for the pod |

---

## Docs

Shared across all three services — read these first:

| Document | What it is for |
| --- | --- |
| **[gke-parameters.md](docs/gke-parameters.md)** | Every GKE parameter for all three services in one set of tables: cluster, identity, networking, resources, probes, sidecar, env. Start here. |
| **[troubleshooting.md](docs/troubleshooting.md)** | Every failure mode, in the order a deploy hits them. Organised by the error in front of you. |
| **[edge-architecture.md](docs/edge-architecture.md)** | How Cloudflare + GCE Ingress + TLS fit together, and how to put a new service behind the edge. |

Per service:

| Service | Documents |
| --- | --- |
| `auth-service` | [prerequisites.md](docs/auth-service/prerequisites.md) (state, parameters, **open issues**) · [deploy.md](docs/auth-service/deploy.md) · [manifest-reference.md](docs/auth-service/manifest-reference.md) (field-by-field rationale) · [parameters.md](docs/auth-service/parameters.md) (upstream citations) |
| `recommendations-service` | [prerequisites.md](docs/recommendations-service/prerequisites.md) · [deploy.md](docs/recommendations-service/deploy.md) · [cpu-capacity-options.md](docs/recommendations-service/cpu-capacity-options.md) |
| `league-service` | [prerequisites.md](docs/league-service/prerequisites.md) — the 10-item checklist before a first apply |

### What is still open

| | |
| --- | --- |
| **Node CPU** | 926m of 940m requested (98%). Nothing else schedules, which is why `league-service` is reserved config rather than a running pod. |
| **`FRONTEND_URL`** | Still `http://localhost:5173` on all three. It is both the post-login redirect target and the only allowed CORS origin, so every browser XHR fails until it is right. |
| **Google login** | One open blocker in `auth-be`: the `__Host-oauth_tx` cookie sets `Path=/api/v1/auth/google`, which the `__Host-` prefix forbids, so browsers discard it silently. [Details](docs/auth-service/prerequisites.md#open-issues). |
| **Schemas** | A green `/api/v1/health` never touches the database on any service. Whether the auth schema and `gm_places` exist where `DB_NAME` points is still unverified. |

---

## Target environment

| | |
| --- | --- |
| Project | `vincent-mini-apps-project` (gcloud configuration **`personal`**) |
| Cluster | `vincent-cluster`, zonal `asia-southeast1-a` |
| Node pool | `minimal-pool` — 1× `e2-medium`, **spot**, no taints |
| Cloud SQL | `recommendations-app-instance`, POSTGRES_18, public IP `34.142.199.254` |
| Connection name | `vincent-mini-apps-project:asia-southeast1:recommendations-app-instance` |
| Database | `recommendations-backend` (per `configmap.yaml`) — shared with the recommendations app. No `auth_service` database exists; see [prerequisites.md §6.2](docs/auth-service/prerequisites.md#62-open-the-auth-schema-has-nowhere-to-live-yet) |
| Registry | `asia-southeast1-docker.pkg.dev/vincent-mini-apps-project/<svc>-repository/<svc>-service` — `auth-repository` and `recommendations-repository` exist; `league-repository` **not yet created** |
| Public hosts | `auth.vincentn.dev` · `recommendations-be.vincentn.dev` · `league-be.vincentn.dev` (reserved) — all behind Cloudflare, see [edge-architecture.md](docs/edge-architecture.md) |

---

## Layout

```
k8s/
  auth-service/
    kustomization.yaml   entry point: kubectl apply -k k8s/auth-service
    namespace.yaml       namespace "auth"
    service-account.yml  KSA + Workload Identity annotation (auth-sql GSA)
    configmap.yaml       non-secret env (APP_ENV, PORT=9999, DB_*, URLs, TTLs)
    deployment.yaml      app container + cloud-sql-proxy native sidecar
    service.yaml         ClusterIP :80 -> :9999, NEG-annotated
    ingress.yaml         gce Ingress: auth.vincentn.dev, global IP, Origin CA TLS
  recommendations-service/
    ... same seven files, namespace "recommendations", PORT=9998,
        recommendations-sql GSA
  league-service/
    ... same seven files, namespace "league", PORT=9200,
        league-sql GSA -- reserved, see docs/league-service/
docs/
  gke-parameters.md      every GKE parameter, all three services, one set of tables
  troubleshooting.md     every failure mode, all three services
  edge-architecture.md   Cloudflare + GCE Ingress + TLS, and how to add a service
  auth-service/          prerequisites (incl. open issues) + deploy + 2 references
  recommendations-service/
                         prerequisites + deploy + cpu-capacity-options
  league-service/        prerequisites (what must exist before the first apply)
```

Anything shared by more than one service lives at the top of `docs/`, not duplicated per
service — the three cross-service files above replaced six per-service ones.

One folder per service under both `k8s/` and `docs/`, with the same file names in each — so a
path tells you the service and the role, and neither tree needs a prefix convention to stay
readable as services are added.

Plain YAML + Kustomize, not Helm. Three services that share a cluster but no templating still
don't justify it, and the indirection would obscure exactly the details that matter while this
is being brought up — the duplication between the three `deployment.yaml` files is the thing to
watch, and the signal to revisit. At that point a Helm + Argo CD shape becomes the right answer.

### Secrets are not in this repo

`auth-service-secrets` (`DB_PASSWORD`, `GOOGLE_OAUTH_CLIENT_ID`,
`GOOGLE_OAUTH_CLIENT_SECRET`, `ENCRYPTION_KEY`) is created imperatively with
`kubectl create secret` in [deploy.md step 3](docs/auth-service/deploy.md) and is deliberately absent from
`kustomization.yaml`.

**`ENCRYPTION_KEY` seals live session cookies — store it in a password manager the moment you
generate it.** Changing it logs every user out, and nothing in the code reads a fallback key.

---

## Quick reference

```bash
# PREFLIGHT -- always, before any apply. kubectl's token comes from the ACTIVE
# gcloud configuration, so a context pointing at vincent-cluster is not
# sufficient on its own.
kubectl config current-context    # ...vincent-cluster
gcloud config get account         # vinhnguyentan99@gmail.com
kubectl get nodes                 # one Ready node

# deploy / update
kubectl apply -k k8s/auth-service
kubectl -n auth rollout status deploy/auth-service

# is it healthy
kubectl -n auth get pods                                    # want 2/2 Running
kubectl -n auth logs deploy/auth-service -c auth-service    # want "database connected" + "listening on :9999"

# reach it
make health SVC=auth                                        # {"ok":true,"env":"production"}

# ship a new image -- CI builds on a git tag matching *.*.*, then pin the digest
cd ../auth-be && git tag 0.1.3 && git push origin 0.1.3
```

---

## Known tradeoffs

- **Single spot node, `replicas: 1`.** Preemption is a full outage. Fine for staging; add a
  second node or a non-spot pool before anything depends on it.
- **The node is full: 926m of 940m allocatable CPU is requested (98%)** — ~701m to GKE system
  pods, 150m to auth-service, 75m to recommendations-service. Nothing else will schedule, and a
  rollout cannot run two copies — which is why `maxUnavailable: 1` / `maxSurge: 0` is mandatory
  here, not a preference. `e2-standard-2` ends this class of problem; see
  [prerequisites.md §3.2](docs/auth-service/prerequisites.md#32-cpu-budget--the-binding-constraint).
- **Cloud SQL instance is shared** with `recommendations-backend`. Fine at this scale, worth
  knowing when you read the instance's metrics.
- **No deploy CI.** Images are built by CI in each service repo (a git tag matching `*.*.*`
  triggers a push to Artifact Registry), but applying manifests and pinning the new digest is
  manual `kubectl apply`. Natural next step.
- **Digests are pinned by hand.** That is what makes `kubectl rollout undo` meaningful, and also
  what makes a redeploy a two-step job — bump the tag, then paste the digest.
