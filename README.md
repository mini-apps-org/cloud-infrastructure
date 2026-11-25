# cloud-infrastructure

Helm chart, per-service values and deployment runbooks for the `my-mini-apps` services on GKE.

Covers three services across **two clusters**:

| Service | Source | Cluster | Namespace | Values | Docs | State |
| --- | --- | --- | --- | --- | --- | --- |
| **`auth-service`** | `../auth-be` | `vincent-cluster` | `auth` | `helm/values/auth.yaml` | [docs/](docs/auth-service/prerequisites.md) | live on `https://auth.vincentn.dev` (Cloudflare + GCE Ingress) |
| **`recommendations-service`** | `../recommendations-be` | `vincent-cluster` | `recommendations` | `helm/values/recommendations.yaml` | [docs/recommendations-service/](docs/recommendations-service/prerequisites.md) | live on `https://recommendations-be.vincentn.dev` (Cloudflare + GCE Ingress), `2/2 Running` |
| **`league-service`** | `../../league/league-be` | `league-cluster` | `league` | `helm/values/league.yaml` | [docs/league-service/](docs/league-service/prerequisites.md) | live on `https://be.mvip-league.com` (Cloudflare + GCE Ingress), with Grafana at `monitoring.mvip-league.com` |

`league-service` is deliberately on a cluster of its own rather than sharing `vincent-cluster`.
That is what unblocks it — on the shared node there was 14m of CPU free against the 75m it needs
— and it is why its rollout strategy, Cloud SQL instance, Cloudflare zone and TLS certificate all
differ from the other two. `make` refuses to run against the wrong cluster; see
[gke-parameters.md §1b](docs/gke-parameters.md).

---

## Docs

Shared across all three services — read these first:

| Document | What it is for |
| --- | --- |
| **[gke-parameters.md](docs/gke-parameters.md)** | Every GKE parameter for all three services in one set of tables: project, **both clusters**, Cloud SQL, identity, networking, resources, probes, sidecar, env. Start here. |
| **[troubleshooting.md](docs/troubleshooting.md)** | Every failure mode, in the order a deploy hits them. Organised by the error in front of you. |
| **[edge-architecture.md](docs/edge-architecture.md)** | How Cloudflare + GCE Ingress + TLS fit together, and how to put a new service behind the edge. |
| **[helm-migration.md](docs/helm-migration.md)** | Adopting a live, `kubectl`-applied service into the shared `helm/mini-app-service` chart without recreating it. **Still to do for `auth` and `recommendations`** (§3.4). |
| **[deployment-workflow-context.md](deployment-workflow-context.md)** | Target CI/CD: backend repos only build images; a merged values change here deploys. Access prerequisites, workflows, rollout plan. |

Standalone, and not specific to this repo — safe to share or read on its own:

| Document | What it is for |
| --- | --- |
| **[cluster-creation.md](docs/cluster-creation.md)** | Setting up a basic GKE cluster with `gcloud`, flag by flag: what the node size decides, what can and cannot be changed afterwards, and what it costs. Project-agnostic — our own values live in `gke-parameters.md`. |

Per service:

| Service | Documents |
| --- | --- |
| `auth-service` | [prerequisites.md](docs/auth-service/prerequisites.md) (state, parameters, **open issues**) · [deploy.md](docs/auth-service/deploy.md) |
| `recommendations-service` | [prerequisites.md](docs/recommendations-service/prerequisites.md) · [deploy.md](docs/recommendations-service/deploy.md) · [cpu-capacity-options.md](docs/recommendations-service/cpu-capacity-options.md) |
| `league-service` | [prerequisites.md](docs/league-service/prerequisites.md) — the 14-item checklist before a first apply · [grafana.md](docs/league-service/grafana.md) · [grafana-public-access.md](docs/league-service/grafana-public-access.md) · [grafana-loki.md](docs/league-service/grafana-loki.md) · [cloud-logging.md](docs/league-service/cloud-logging.md) |

### What is still open

| | |
| --- | --- |
| **`vincent-cluster` node CPU** | 926m of 940m requested (98%). Nothing else schedules there. No longer blocks `league-service`, which moved to its own cluster, but it still means the two live services cannot roll without a brief gap. |
| **Helm adoption** | `auth` and `recommendations` are still `kubectl`-applied objects with no Helm release, so `make apply` and the deploy workflow can't manage them yet. Adopt each one with [helm-migration.md §3.4](docs/helm-migration.md). |
| **`FRONTEND_URL`** | Still `http://localhost:5173` on all three. It is both the post-login redirect target and the only allowed CORS origin, so every browser XHR fails until it is right. |
| **Google login** | One open blocker in `auth-be`: the `__Host-oauth_tx` cookie sets `Path=/api/v1/auth/google`, which the `__Host-` prefix forbids, so browsers discard it silently. [Details](docs/auth-service/prerequisites.md#open-issues). |
| **Schemas** | A green `/api/v1/health` never touches the database on any service. Whether the auth schema and `gm_places` exist where `DB_NAME` points is still unverified. |

---

## Target environment

| | |
| --- | --- |
| Project | `vincent-mini-apps-project` (gcloud configuration **`personal`**) — one project, both clusters |
| Cluster · auth + recommendations | `vincent-cluster`, zonal `asia-southeast1-a`. Node pool `minimal-pool` — 1× `e2-medium`, **spot**, no taints |
| Cluster · league | `league-cluster`, zonal `asia-southeast1-a`, node pool `default-pool` — same shape, Workload Identity enabled |
| Cloud SQL · auth + recommendations | `recommendations-app-instance`, POSTGRES_18, `db-perf-optimized-N-8`, public IP `34.142.199.254`, database `recommendations-backend` — shared. No `auth_service` database exists; see [prerequisites.md §6.2](docs/auth-service/prerequisites.md#62-open-the-auth-schema-has-nowhere-to-live-yet) |
| Cloud SQL · league | `league-app-instance`, POSTGRES_18, database `league-backend`. Its own instance, not a second database on the shared one |
| Registry | `asia-southeast1-docker.pkg.dev/vincent-mini-apps-project/<svc>-repository/<svc>-service` — `auth-repository`, `recommendations-repository` and `league-repository`. Project-scoped, so both clusters pull from it |
| Public hosts | `auth.vincentn.dev` · `recommendations-be.vincentn.dev` (zone `vincentn.dev`) · `be.mvip-league.com` (**its own zone and its own Origin certificate**) — all behind Cloudflare, see [edge-architecture.md](docs/edge-architecture.md) |

---

## Layout

```
helm/
  mini-app-service/      the one chart all three services deploy from
    values.yaml          defaults shared by every service
    templates/           serviceaccount, configmap, deployment (app + cloud-sql-proxy
                         native sidecar), service (ClusterIP, NEG), ingress (gce,
                         Origin CA TLS), podmonitoring (opt-in)
  values/
    auth.yaml            namespace "auth", PORT=9999, auth-sql GSA
    recommendations.yaml namespace "recommendations", PORT=9998, recommendations-sql GSA
    league.yaml          namespace "league", PORT=9200, league-sql GSA
  monitoring/            Grafana, cloudflared and Alloy on league-cluster
docs/
  gke-parameters.md      every GKE parameter, all three services, one set of tables
  cluster-creation.md    basic GKE cluster setup with gcloud (generic, shareable)
  troubleshooting.md     every failure mode, all three services
  edge-architecture.md   Cloudflare + GCE Ingress + TLS, and how to add a service
  helm-migration.md      adopting a kubectl-applied service into the chart
  auth-service/          prerequisites (incl. open issues) + deploy
  recommendations-service/
                         prerequisites + deploy + cpu-capacity-options
  league-service/        prerequisites + Grafana, Loki and Cloud Logging guides
```

Anything shared by more than one service lives at the top of `docs/`, not duplicated per
service.

One chart, one values file per service: what differs between services is exactly what is in
`helm/values/<svc>.yaml`, and a change to probes, the proxy or the securityContext is made once
in the chart. Before the chart, the three services were near-identical plain YAML that had to be
edited in three places; the last commit with that tree is `1f2535c`.

### Secrets are not in this repo

`auth-service-secrets` (`DB_PASSWORD`, `GOOGLE_OAUTH_CLIENT_ID`,
`GOOGLE_OAUTH_CLIENT_SECRET`, `ENCRYPTION_KEY`) is created imperatively with
`kubectl create secret` in [deploy.md step 3](docs/auth-service/deploy.md) and is deliberately absent from
the chart and its values files.

**`ENCRYPTION_KEY` seals live session cookies — store it in a password manager the moment you
generate it.** Changing it logs every user out, and nothing in the code reads a fallback key.

---

## Quick reference

```bash
# PREFLIGHT -- always, before any apply. TWO things to get right: the context
# must point at the cluster for the service you are deploying, and kubectl's
# token comes from the ACTIVE gcloud configuration, so the right context is not
# sufficient on its own.
kubectl config current-context    # ...vincent-cluster for auth/recommendations
                                  # ...league-cluster  for league
gcloud config get account         # vinhnguyentan99@gmail.com
kubectl get nodes                 # one Ready node

# switch clusters
gcloud container clusters get-credentials vincent-cluster --zone asia-southeast1-a
gcloud container clusters get-credentials league-cluster  --zone asia-southeast1-a

# every make target refuses to run on a mismatched context, so this is a guard
# rail rather than something to remember:
make status SVC=league            # -> "SVC=league expects cluster league-cluster"

# deploy / update -- helm upgrade --install, waits for the rollout. auth and
# recommendations must be adopted into Helm first (docs/helm-migration.md §3.4)
make diff  SVC=auth                                         # preview against the live cluster
make apply SVC=auth
make rollback SVC=auth                                      # previous Helm revision, ConfigMap included

# is it healthy
kubectl -n auth get pods                                    # want 2/2 Running
kubectl -n auth logs deploy/auth-service -c auth-service    # want "database connected" + "listening on :9999"

# reach it
make health SVC=auth                                        # {"ok":true,"env":"production"}

# ship a new image -- CI builds on a git tag matching *.*.*; then set image.tag +
# image.digest in helm/values/auth.yaml and merge: the deploy workflow applies it
cd ../auth-be && git tag 0.1.3 && git push origin 0.1.3
```

---

## Known tradeoffs

- **Single spot node, `replicas: 1`, on both clusters.** Preemption is a full outage. Fine for
  staging; add a second node or a non-spot pool before anything depends on it.
- **`vincent-cluster` is full: 926m of 940m allocatable CPU is requested (98%)** — ~701m to GKE
  system pods, 150m to auth-service, 75m to recommendations-service. Nothing else will schedule
  there, and a rollout cannot run two copies — which is why `maxUnavailable: 1` / `maxSurge: 0`
  is mandatory on those two, not a preference. `e2-standard-2` ends this class of problem; see
  [prerequisites.md §3.2](docs/auth-service/prerequisites.md#32-cpu-budget--the-binding-constraint).
- **Two clusters is two control planes and two nodes' worth of cost** for three small services,
  and the second one exists mainly because the first has no CPU left. Consolidating onto one
  larger cluster (`e2-standard-2`) would be cheaper than two `e2-medium` clusters and would end
  the context-switching — worth revisiting if isolation is not the actual goal.
- **`league-cluster` can roll without downtime, the other two cannot.** `maxUnavailable: 0` /
  `maxSurge: 1` works there because the node has room. The three services therefore disagree on
  that field deliberately; normalising them would reintroduce a rollout deadlock.
- **`recommendations-app-instance` is shared** between `auth` and `recommendations`. Fine at this
  scale, worth knowing when you read the instance's metrics. `league` gets its own instance —
  which is also a second Cloud SQL bill, so do not clone the shared instance's
  `db-perf-optimized-N-8` tier for it.
- **Deploy CI needs Helm ownership.** A merged change to `helm/values/<svc>.yaml` deploys that
  service (`.github/workflows/deploy-*.yaml`). For `auth` and `recommendations` that only works
  once they are adopted into Helm — [helm-migration.md §3.4](docs/helm-migration.md).
- **Digests are pinned by hand.** That is what makes `make rollback` meaningful, and also
  what makes a redeploy a two-step job — bump the tag, then paste the digest.
