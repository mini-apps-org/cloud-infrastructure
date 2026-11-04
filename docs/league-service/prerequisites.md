# league-service — prerequisites

`k8s/league-service/` is **reserved config**: the manifests are complete and `kustomize`-valid,
but nothing they reference exists in GCP yet. This page is the checklist that closes that gap.

Parameter values live in one place for all three services:
[../gke-parameters.md](../gke-parameters.md).

---

## 0. Blocker — the node has no CPU for this pod

| | CPU requested |
| --- | --- |
| GKE system pods | ~701m |
| `auth-service` (app 100m + proxy 50m) | 150m |
| `recommendations-service` (app 50m + proxy 25m) | 75m |
| **Free of 940m allocatable** | **14m** — verified `926m (98%)` requested |
| `league-service` needs (app 50m + proxy 25m) | **75m** |

The pod will sit `Pending` with `Insufficient cpu` until the node pool grows. Options are already
written up in
[../recommendations-service/cpu-capacity-options.md](../recommendations-service/cpu-capacity-options.md);
`e2-standard-2` ends this class of problem.

**Nothing below is worth doing until this is resolved.**

---

## 1. Checklist

| # | Must exist | Command that creates it | Command that checks it |
| --- | --- | --- | --- |
| 1 | Artifact Registry repo `league-repository` | `gcloud artifacts repositories create league-repository --repository-format=docker --location=asia-southeast1` | `gcloud artifacts repositories describe league-repository --location=asia-southeast1` |
| 2 | GSA `league-sql` | `gcloud iam service-accounts create league-sql` | `gcloud iam service-accounts describe league-sql@vincent-mini-apps-project.iam.gserviceaccount.com` |
| 3 | `roles/cloudsql.client` on that GSA | `gcloud projects add-iam-policy-binding vincent-mini-apps-project --member=serviceAccount:league-sql@vincent-mini-apps-project.iam.gserviceaccount.com --role=roles/cloudsql.client` | `gcloud projects get-iam-policy vincent-mini-apps-project --flatten=bindings --filter='bindings.members:league-sql'` |
| 4 | Workload Identity binding **GSA → KSA** | `gcloud iam service-accounts add-iam-policy-binding league-sql@vincent-mini-apps-project.iam.gserviceaccount.com --role=roles/iam.workloadIdentityUser --member='serviceAccount:vincent-mini-apps-project.svc.id.goog[league/league-service]'` | `gcloud iam service-accounts get-iam-policy league-sql@vincent-mini-apps-project.iam.gserviceaccount.com` |
| 5 | Global static IP `league-service-ip` | `gcloud compute addresses create league-service-ip --global` | `gcloud compute addresses describe league-service-ip --global` |
| 6 | Database `league` on `recommendations-app-instance` | `gcloud sql databases create league --instance=recommendations-app-instance` | `gcloud sql databases list --instance=recommendations-app-instance` |
| 7 | Image `league-service:0.1.0` pushed | git-tag `0.1.0` in `league-be` (fires `release.yaml`) | `gcloud artifacts docker images list asia-southeast1-docker.pkg.dev/vincent-mini-apps-project/league-repository/league-service` |
| 8 | Secret `league-service-secrets` | see §2 | `kubectl -n league get secret league-service-secrets` |
| 9 | TLS secret `league-service-origin-tls` | see §3 | `kubectl -n league get secret league-service-origin-tls` |
| 10 | Cloudflare DNS `league-be` → the §5 IP, proxied | Cloudflare dashboard | `dig +short mvip-league-be.dev` |

Verified on 2026-11-04: **steps 1, 2, 5 and 6 do not exist yet.** `gcloud` lists only
`auth-repository` / `recommendations-repository`, only `auth-sql` / `recommendations-sql`, only
`auth-service-ip` / `recommendations-service-ip`, and only the `postgres` /
`recommendations-backend` databases. Nothing in this checklist is already done.

Step 4 is the one that fails silently. Both directions are required — the KSA annotation in
`service-account.yml` **and** this binding. With only the annotation, the proxy gets a token for
the node's service account and Cloud SQL rejects it.

Step 7 needs no new IAM: the `github-actions` GSA that `league-be`'s `release.yaml` impersonates
already holds `roles/artifactregistry.writer` at project level, so pushing works as soon as
`league-repository` exists.

---

## 2. The Secret — four keys, three of them unused at runtime

```bash
kubectl -n league create secret generic league-service-secrets \
  --from-literal=DB_PASSWORD='...' \
  --from-literal=GOOGLE_OAUTH_CLIENT_ID='placeholder' \
  --from-literal=GOOGLE_OAUTH_CLIENT_SECRET='placeholder' \
  --from-literal=ENCRYPTION_KEY="$(openssl rand -base64 32)"
```

`league-be` registers only the health route, yet `config.Load()` rejects an empty
`GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET` or `ENCRYPTION_KEY` before anything checks
whether a route uses them — so placeholders are required, not optional.

**Store `ENCRYPTION_KEY` in a password manager the moment you generate it.** It seals the
`oauth_tx` cookie; changing it invalidates every live session and there is no fallback key.

Not in `kustomization.yaml`, deliberately — no credential lands in this repo.

## 3. The TLS secret

The existing Cloudflare Origin certificate is issued for `*.vincentn.dev`, so it already covers
`mvip-league-be.dev`. Kubernetes Secrets are namespaced, so this is a **copy**, not a
reference:

```bash
kubectl -n league create secret tls league-service-origin-tls \
  --cert=origin.pem --key=origin.key
```

---

## 4. Two things that will surprise you

**Google login cannot work from this manifest.** `config.go` reads
`auth.google_oauth_redirect_url` only from the `//go:embed`-ed `production.yaml` via
`mapstructure` — there is **no environment override at all** — and `Load()` fails when it is
empty. `production.yaml` currently ships `http://localhost:9999/api/auth/google/callback`. Fixing
it is a code change plus a rebuild. This is the same trap as `auth-service` 0.1.1, except here no
env var exists to reach for.

**Never add `DATABASE_URL` to the ConfigMap.** `config.go` assigns it unconditionally and
`ConnectDatabaseString()` *prefers* it over every `DB_*` value, so defining it would bypass the
Cloud SQL proxy DSN and connect somewhere else — or nowhere.

---

## 5. Then

```bash
kubectl apply -k k8s/league-service     # or: make apply SVC=league
make status SVC=league
make health SVC=league                  # {"ok":true,"env":"production","image":"0.1.0"}
```

`image` in that response comes from `ENV_IMAGE` in the ConfigMap, not from the running image —
keep the two in step or it will lie to you.
