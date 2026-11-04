# GKE parameters — all services

Every parameter that decides how these services run on GKE, in one place.
Three services, same shape, different values.

| | `auth-service` | `recommendations-service` | `league-service` |
| --- | --- | --- | --- |
| State | live | live | **reserved, not deployed** |
| Source repo | `../auth-be` | `../recommendations-be` | `../../league/league-be` |
| Manifests | `k8s/auth-service/` | `k8s/recommendations-service/` | `k8s/league-service/` |

---

## 1. Cluster — shared by all three

| Parameter | Value |
| --- | --- |
| Project | `vincent-mini-apps-project` |
| gcloud configuration | `personal` |
| Cluster | `vincent-cluster` (zonal) |
| Zone | `asia-southeast1-a` |
| Node pool | `minimal-pool` — 1× `e2-medium`, spot, no taints |
| Allocatable CPU | 940m |
| Allocatable memory | ~3Gi |
| Workload Identity pool | `vincent-mini-apps-project.svc.id.goog` |
| Cloud SQL instance | `recommendations-app-instance`, POSTGRES_18 |
| Connection name | `vincent-mini-apps-project:asia-southeast1:recommendations-app-instance` |
| Registry host | `asia-southeast1-docker.pkg.dev` |

---

## 2. Identity and naming

| Parameter | auth | recommendations | league |
| --- | --- | --- | --- |
| Namespace | `auth` | `recommendations` | `league` |
| Deployment / Service | `auth-service` | `recommendations-service` | `league-service` |
| KSA | `auth-service` | `recommendations-service` | `league-service` |
| GSA | `auth-sql@…` | `recommendations-sql@…` | `league-sql@…` **(to create)** |
| GSA role | `roles/cloudsql.client` | same | same |
| AR repository | `auth-repository` | `recommendations-repository` | `league-repository` **(to create)** |
| ConfigMap | `auth-service-config` | `recommendations-service-config` | `league-service-config` |
| Secret | `auth-service-secrets` | `recommendations-service-secrets` | `league-service-secrets` **(to create)** |
| TLS secret | `auth-service-origin-tls` | `recommendations-service-origin-tls` | `league-service-origin-tls` **(to create)** |

One GSA per service, never shared: a future grant to one must not widen the others.

**Workload Identity needs both directions.** The KSA annotation
(`iam.gke.io/gcp-service-account`) *and* `roles/iam.workloadIdentityUser` on the GSA for
`…svc.id.goog[<namespace>/<ksa>]`. With only the annotation the proxy gets the node's token and
Cloud SQL rejects it.

---

## 3. Networking

| Parameter | auth | recommendations | league |
| --- | --- | --- | --- |
| Public host | `auth.vincentn.dev` | `recommendations-be.vincentn.dev` | `league-be.vincentn.dev` |
| Container port | 9999 | 9998 | 9200 |
| Service type | ClusterIP | ClusterIP | ClusterIP |
| Service port | 80 → `http` | 80 → `http` | 80 → `http` |
| Global static IP | `auth-service-ip` | `recommendations-service-ip` | `league-service-ip` **(to reserve)** |
| Health path | `/api/v1/health` | `/api/v1/health` | `/api/v1/health` |

Shared Ingress settings:

| Annotation | Value | Why |
| --- | --- | --- |
| `kubernetes.io/ingress.class` | `gce` | The only way to select a GKE Ingress — `spec.ingressClassName` is ignored outright |
| `kubernetes.io/ingress.global-static-ip-name` | per service | Must be **global**; regional addresses are rejected. One address backs one forwarding rule, so it cannot be shared |
| `kubernetes.io/ingress.allow-http` | `false` | Cloudflare Full (strict) only dials 443. Requires "Always Use HTTPS" on the zone |
| `cloud.google.com/neg` (Service) | `{"ingress": true}` | Container-native LB: the LB health check inherits the `readinessProbe` |

TLS is one Cloudflare Origin CA certificate for `*.vincentn.dev`, copied into each namespace —
Secrets are namespaced, so each service holds a copy, not a reference. Trusted only by
Cloudflare, which is the only client of these load balancers.

---

## 4. CPU and memory

| | auth app | auth proxy | recs app | recs proxy | league app | league proxy |
| --- | --- | --- | --- | --- | --- | --- |
| CPU request | 100m | 50m | 50m | 25m | 50m | 25m |
| CPU limit | 500m | 200m | 500m | 200m | 500m | 200m |
| Memory request | 128Mi | 64Mi | 128Mi | 64Mi | 128Mi | 64Mi |
| Memory limit | 256Mi | 128Mi | 256Mi | 128Mi | 256Mi | 128Mi |

### The binding constraint

| | CPU |
| --- | --- |
| Allocatable | 940m |
| Currently requested | **926m (98%)** — verified 2026-11-04 |
| **Free** | **14m** |
| `league-service` wants | **75m** |

So `league-service` cannot schedule today. See
[recommendations-service/cpu-capacity-options.md](recommendations-service/cpu-capacity-options.md).

This is also why **`maxUnavailable: 1` / `maxSurge: 0`** is mandatory on all three, not a
preference: two copies of a pod do not fit, and `maxUnavailable: 0` deadlocks — the old pod
cannot go until the new one is Ready, and the new one cannot schedule until the old one goes.

---

## 5. Probes — identical on all three

| Probe | Path | Period | Timeout | Failures |
| --- | --- | --- | --- | --- |
| app startup | `/api/v1/health` | 3s | — | 20 |
| app readiness | `/api/v1/health` | 10s | 3s | 3 |
| app liveness | `/api/v1/health` | 20s | 3s | 3 |
| proxy startup | `:9090/startup` | 2s | — | 30 |

Two rules behind these:

- **The health handler never touches the database**, so one slow query cannot evict a healthy pod.
  The flip side: a green probe says **nothing** about the schema.
- **The proxy probe is HTTP on 9090, never `tcpSocket` on 5432.** kubelet dials the pod IP from
  outside the pod's network namespace, while the proxy binds `127.0.0.1` only — that probe can
  never pass.

---

## 6. cloud-sql-proxy sidecar — identical on all three

| Parameter | Value |
| --- | --- |
| Image | `gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.14.1` |
| Kind | **native sidecar** — `initContainers` + `restartPolicy: Always` (needs Kubernetes 1.29+) |
| DB listen | `--port=5432` on loopback |
| Health server | `--http-address=0.0.0.0 --http-port=9090` |
| Credentials | none — Workload Identity via the bound KSA |

Native, not ordinary: each app pings the database at startup and `log.Fatalf`s on failure. A plain
sidecar starts in parallel, so the app loses the race and crashloops.

---

## 7. Environment

### Non-secret — ConfigMap

| Key | auth | recommendations | league |
| --- | --- | --- | --- |
| `APP_ENV` | `production` | `production` | `production` |
| `PORT` | `9999` | `9998` | `9200` |
| `DB_HOST` | `127.0.0.1` | `127.0.0.1` | `127.0.0.1` |
| `DB_PORT` | `5432` | `5432` | `5432` |
| `DB_USER` | `postgres` | `postgres` | `postgres` |
| `DB_NAME` | `recommendations-backend` | `recommendations-backend` | `league` **(to create)** |
| `DB_SSLMODE` | `disable` | `disable` | `disable` |
| `BASE_URL` | `https://auth.vincentn.dev` | `https://recommendations-be.vincentn.dev` | `https://league-be.vincentn.dev` |
| `FRONTEND_URL` | `http://localhost:5173` ⚠️ | `http://localhost:5173` ⚠️ | `http://localhost:5173` ⚠️ |
| `GOOGLE_OAUTH_REDIRECT_URL` | set, **ignored by the image** | — | **not settable** |
| `SESSION_TTL` | `12h` | — | `12h` |
| `SESSION_IDLE_TTL` | `30m` | — | `30m` |
| `GOOGLE_ALLOWED_HD` | — | — | `""` (any account) |
| `ENCRYPTION_KEY_VERSION` | — | — | `1` |
| `ENV_IMAGE` | — | — | `0.1.0` |

`DB_HOST: 127.0.0.1` is the proxy sidecar, not Cloud SQL. `DB_SSLMODE: disable` is correct and
not a weakening — that hop is loopback inside the pod, and the proxy makes the TLS connection to
Cloud SQL itself.

⚠️ **`FRONTEND_URL` is still localhost on all three.** It is the post-login redirect target *and*
the only allowed CORS origin, so a wrong value breaks login and every browser XHR at once —
visible only in the browser console, never in the logs.

### Secret — created imperatively, never in git

| Key | auth | recommendations | league |
| --- | --- | --- | --- |
| `DB_PASSWORD` | used | used | used |
| `GOOGLE_OAUTH_CLIENT_ID` | used | required, unused | required, unused |
| `GOOGLE_OAUTH_CLIENT_SECRET` | used | required, unused | required, unused |
| `ENCRYPTION_KEY` | used | required, unused | required, unused |

"required, unused" means `config.Load()` rejects an empty value before anything checks whether a
route uses it. Placeholders are mandatory.

`ENCRYPTION_KEY` seals live session cookies. **Store it in a password manager when you generate
it** — changing it logs everyone out and no fallback key is read.

No Secret appears in any `kustomization.yaml`, deliberately.

---

## 8. Two parameters that do not behave as they look

**`GOOGLE_OAUTH_REDIRECT_URL`.** In `auth-service` the ConfigMap sets it and the `0.1.1` image
ignores it — `config.go` overrides `BASE_URL` and `FRONTEND_URL` from the environment but not this
one, so the `//go:embed`-ed localhost value wins. In `league-service` it is worse: the field is
read *only* from the embedded `production.yaml` via `mapstructure`, with **no env override at
all**, and `Load()` fails when it is empty. Either way, Google login needs a code change and a
rebuild — not a ConfigMap edit.

**`DATABASE_URL` (league only).** Absent from the ConfigMap on purpose. `config.go` assigns it
unconditionally and `ConnectDatabaseString()` *prefers* it over every `DB_*` value, so defining it
would silently bypass the Cloud SQL proxy DSN.

---

## 9. ConfigMap edits do not restart anything

There is no `configMapGenerator`, so the ConfigMap has no name hash and editing it does not roll
the Deployment. The restart is required, not a convenience:

```bash
make apply-config SVC=league     # apply + rollout restart + wait
```

---

## 10. Commands

```bash
make apply   SVC=league   # apply manifests and wait
make status  SVC=league   # wait on the current rollout
make ps      SVC=league   # pods
make logs    SVC=league   # app container
make logs-proxy SVC=league
make events  SVC=league   # read this first on a failure
make health  SVC=league   # curl /api/v1/health
make rollback SVC=league
```

`SVC` is `auth`, `recommendations` (the default) or `league`.

Always preflight — kubectl's token comes from the **active gcloud configuration**, so a context
pointing at `vincent-cluster` is not sufficient on its own:

```bash
kubectl config current-context    # ...vincent-cluster
gcloud config get account         # vinhnguyentan99@gmail.com
kubectl get nodes                 # one Ready node
```
