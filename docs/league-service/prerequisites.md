# league-service — prerequisites

`k8s/league-service/` is **reserved config**: the manifests are complete and `kustomize`-valid,
but nothing they reference exists in GCP yet. This page is the checklist that closes that gap.

Parameter values live in one place for all three services:
[../gke-parameters.md](../gke-parameters.md).

---

## 0. league runs on its own cluster

`league-service` does **not** share `vincent-cluster` with `auth-service` and
`recommendations-service`. It gets `league-cluster`, in the same project and zone. Three
consequences, in order of how likely they are to bite:

**The CPU blocker is gone.** On `vincent-cluster` this pod could not schedule at all: ~701m of
940m allocatable goes to GKE system pods and the other two services took the remaining 239m,
leaving 14m against this pod's 75m. On a node of its own the same 75m fits with room to spare.

| | CPU on `league-cluster` |
| --- | --- |
| Allocatable (`e2-medium`) | 940m |
| GKE system pods | ~701m — measured on `vincent-cluster`; re-verify, see §8 |
| `league-service` (app 50m + proxy 25m) | 75m |
| Surge replica during a rollout | +75m |
| **Peak** | **~851m** |

**The rollout strategy is the opposite of the other two.** They pin `maxUnavailable: 1` /
`maxSurge: 0` because two copies of a pod cannot fit on the shared node, which makes
`maxUnavailable: 0` a deadlock. Here the surge replica fits, so `deployment.yaml` uses
`maxUnavailable: 0` / `maxSurge: 1` and a rollout has no gap in service. Do not "fix" this
inconsistency — the two clusters genuinely want different values.

**Everything project-scoped is unchanged.** Same project means the Workload Identity pool id,
the `league-sql` GSA, `league-repository` and the `roles/cloudsql.client` grant are all exactly
as they would have been. A separate cluster changes none of them. What it *does* change is
whether the pool is **enabled** — see step 1.

**`kubectl` now points at the wrong cluster by default.** `make apply SVC=league` against a
context for `vincent-cluster` would deploy league into the shared cluster. The `Makefile`
enforces the right context per `SVC`; see §7.

---

## 1. Checklist

| # | Must exist | Command that creates it | Command that checks it |
| --- | --- | --- | --- |
| 1 | Cluster `league-cluster` with Workload Identity **enabled** | see §2 | `gcloud container clusters describe league-cluster --zone asia-southeast1-a --format='value(workloadIdentityConfig.workloadPool)'` |
| 2 | kubectl context for it | `gcloud container clusters get-credentials league-cluster --zone asia-southeast1-a` | `kubectl config current-context` ends in `league-cluster` |
| 3 | Artifact Registry repo `league-repository` | `gcloud artifacts repositories create league-repository --repository-format=docker --location=asia-southeast1` | `gcloud artifacts repositories describe league-repository --location=asia-southeast1` |
| 4 | GSA `league-sql` | `gcloud iam service-accounts create league-sql` | `gcloud iam service-accounts describe league-sql@vincent-mini-apps-project.iam.gserviceaccount.com` |
| 5 | `roles/cloudsql.client` on that GSA | `gcloud projects add-iam-policy-binding vincent-mini-apps-project --member=serviceAccount:league-sql@vincent-mini-apps-project.iam.gserviceaccount.com --role=roles/cloudsql.client` | `gcloud projects get-iam-policy vincent-mini-apps-project --flatten=bindings --filter='bindings.members:league-sql'` |
| 6 | Workload Identity binding **GSA → KSA** | `gcloud iam service-accounts add-iam-policy-binding league-sql@vincent-mini-apps-project.iam.gserviceaccount.com --role=roles/iam.workloadIdentityUser --member='serviceAccount:vincent-mini-apps-project.svc.id.goog[league/league-service]'` | `gcloud iam service-accounts get-iam-policy league-sql@vincent-mini-apps-project.iam.gserviceaccount.com` |
| 7 | Global static IP `league-service-ip` | `gcloud compute addresses create league-service-ip --global` | `gcloud compute addresses describe league-service-ip --global` |
| 8 | Cloud SQL instance `league-app-instance` | see §3 | `gcloud sql instances describe league-app-instance` |
| 9 | `postgres` password set on it | see §3 | — (its value goes in the Secret, step 11) |
| 10 | Database `league-backend` on that instance | `gcloud sql databases create league-backend --instance=league-app-instance` | `gcloud sql databases list --instance=league-app-instance` |
| 11 | Image `league-service:0.1.0` pushed | git-tag `0.1.0` in `league-be` (fires `release.yaml`) | `gcloud artifacts docker images list asia-southeast1-docker.pkg.dev/vincent-mini-apps-project/league-repository/league-service` |
| 12 | Secret `league-service-secrets` | see §4 | `kubectl -n league get secret league-service-secrets` |
| 13 | TLS secret `league-service-origin-tls` | see §5 | `kubectl -n league get secret league-service-origin-tls` |
| 14 | Cloudflare zone `be.mvip-league.com` in the account, `@` → the step 7 IP, **proxied** | Cloudflare dashboard | `dig +short be.mvip-league.com` |

Verified on 2026-11-06: **`league-cluster` does not exist** — `gcloud container clusters list`
returns only `vincent-cluster`. Steps 3, 4, 7 and 8 do not exist either: `gcloud` lists only
`auth-repository` / `recommendations-repository`, only `auth-sql` / `recommendations-sql`, only
`auth-service-ip` / `recommendations-service-ip`, and only the `recommendations-app-instance`
SQL instance. Nothing in this checklist is already done.

**Step 6 is the one that fails silently, and it now has two causes.** Both the KSA annotation in
`service-account.yml` *and* `roles/iam.workloadIdentityUser` on the GSA are required — and both
are inert unless the pool is enabled on the cluster (step 1). Any of the three missing produces
the same symptom: the proxy gets a token for the node's service account and Cloud SQL rejects it.

Step 11 needs no new IAM: the `github-actions` GSA that `league-be`'s `release.yaml` impersonates
already holds `roles/artifactregistry.writer` at project level, so pushing works as soon as
`league-repository` exists.

---

## 2. The cluster

```bash
gcloud container clusters create league-cluster \
  --zone asia-southeast1-a \
  --num-nodes 1 \
  --machine-type e2-medium \
  --spot \
  --workload-pool vincent-mini-apps-project.svc.id.goog \
  --release-channel regular
```

What every flag does, and which defaults this short command leaves in place:
[../cluster-creation.md](../cluster-creation.md) — a generic GKE guide, so substitute the values
above for its `${PROJECT}` / `${CLUSTER}` / `${ZONE}`.

Four of those flags are load-bearing:

| Flag | Why it is not optional |
| --- | --- |
| `--workload-pool` | Without it the KSA annotation and the GSA binding are both inert and the Cloud SQL proxy authenticates as the **node's** service account. Retro-fittable (`clusters update --workload-pool=…`) but it restarts workloads, so do it now. |
| `--release-channel regular` | The `cloud-sql-proxy` sidecar is a **native** sidecar (`initContainers` + `restartPolicy: Always`), which needs **Kubernetes 1.29+**. Any current channel is ~1.36, so this is satisfied by default — it is listed because the manifest silently depends on it. |
| `--spot` | Matches `minimal-pool`. Cost, not capability: preemption is a full outage at `replicas: 1`. |
| VPC-native (default) | The `cloud.google.com/neg` annotation in `service.yaml` requires alias IPs. It is the default for new clusters, so there is no flag — but a legacy routes-based cluster would break container-native load balancing. |

The default node pool is called `default-pool`, not `minimal-pool`. `gcloud container clusters
create` has no flag to name it; getting a custom name means creating a second pool and deleting
the first, which buys nothing. Use `default-pool` in any `-l cloud.google.com/gke-nodepool=` query.

---

## 3. The Cloud SQL instance — check the bill before you run this

league gets its **own** instance, not a second database on `recommendations-app-instance`.

⚠️ **Do not mirror the existing instance's tier.** `recommendations-app-instance` is
`db-perf-optimized-N-8` — an 8-vCPU Enterprise **Plus** instance with a 100 GB SSD. A second one
of those is a serious monthly line item for a service that currently registers only a health
route. Start small; a tier is a one-command resize later, and the edition is not.

```bash
gcloud sql instances create league-app-instance \
  --database-version POSTGRES_18 \
  --edition ENTERPRISE \
  --tier db-g1-small \
  --region asia-southeast1 \
  --storage-size 10GB

# Step 9 -- a brand-new instance has NO postgres password. This is a step the
# other two services never needed, because they inherited an instance that
# already had one. DB_USER in the ConfigMap is "postgres", so this is the
# password that goes into DB_PASSWORD in §4.
gcloud sql users set-password postgres \
  --instance league-app-instance \
  --password "$(openssl rand -base64 24)"

gcloud sql databases create league-backend --instance league-app-instance
```

No authorized network and no VPC peering is needed, and the separate cluster changes nothing
here: `cloud-sql-proxy` reaches the instance over its public IP using the Cloud SQL Admin API and
the `roles/cloudsql.client` grant, from wherever it happens to run. That is also why the instance
being dedicated costs the manifest exactly one changed line — the connection name in
`deployment.yaml`.

Keep `deployment.yaml`'s connection name and this instance in step:
`vincent-mini-apps-project:asia-southeast1:league-app-instance`.

---

## 4. The Secret — four keys, three of them unused at runtime

```bash
kubectl -n league create secret generic league-service-secrets \
  --from-literal=DB_PASSWORD='...' \
  --from-literal=GOOGLE_OAUTH_CLIENT_ID='placeholder' \
  --from-literal=GOOGLE_OAUTH_CLIENT_SECRET='placeholder' \
  --from-literal=ENCRYPTION_KEY="$(openssl rand -base64 32)"
```

`DB_PASSWORD` is the one you set in §3 — it is **not** the shared instance's password, which is
the easy mistake now that the instances are separate.

`league-be` registers only the health route, yet `config.Load()` rejects an empty
`GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET` or `ENCRYPTION_KEY` before anything checks
whether a route uses them — so placeholders are required, not optional.

**Store `ENCRYPTION_KEY` in a password manager the moment you generate it.** It seals the
`oauth_tx` cookie; changing it invalidates every live session and there is no fallback key.

Not in `kustomization.yaml`, deliberately — no credential lands in this repo.

## 5. The TLS secret — a new certificate, not a copy

This is the one place league differs from the other two services at the edge, and it is easy to
get wrong because the pattern looks identical.

`auth-service` and `recommendations-service` both copy **one** Cloudflare Origin CA certificate
issued for `*.vincentn.dev`. `league-service` is on `be.mvip-league.com`, which is a separate
registrable domain — its own apex, its own Cloudflare zone. A wildcard covers one label beneath
*its own* domain and nothing in another, so `*.vincentn.dev` does not cover it. Reusing that
secret here produces a certificate/host mismatch that Cloudflare Full (strict) reports as a
**526**, with the pod perfectly healthy behind it.

So: add `be.mvip-league.com` as a zone in the Cloudflare account (its nameservers must be
delegated there — Origin CA will only issue for a zone Cloudflare serves), issue an Origin
certificate for `be.mvip-league.com` *and* `*.be.mvip-league.com`, then:

```bash
kubectl -n league create secret tls league-service-origin-tls \
  --cert=mvip-league-be-origin.pem --key=mvip-league-be-origin.key
```

Two zone settings carry over unchanged, and both are required: **Full (strict)** SSL mode, and
**Always Use HTTPS** — `ingress.yaml` sets `allow-http: "false"`, so plaintext reaches a port
with no forwarding rule and Cloudflare reports a 520 rather than redirecting.

Because it is an apex record, DNS is an **A record on `@`** pointing at the step 7 global IP,
proxied (orange cloud). No CNAME flattening is involved.

---

## 6. Two things that will surprise you

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

## 7. Then — and check the context first

`kubectl`'s token comes from the **active gcloud configuration**, and the context now has to
point at `league-cluster` rather than `vincent-cluster`:

```bash
gcloud config configurations activate personal
gcloud container clusters get-credentials league-cluster --zone asia-southeast1-a
kubectl config current-context    # ...league-cluster  <-- NOT vincent-cluster
kubectl get nodes                 # one Ready node
```

`make` targets refuse to run against the wrong cluster — every target preflights
`kubectl config current-context` against the cluster expected for that `SVC`, so a stale context
is an error rather than a deploy into the shared cluster.

```bash
kubectl apply -k k8s/league-service     # or: make apply SVC=league
make status SVC=league
make health SVC=league                  # {"ok":true,"env":"production","image":"0.1.0"}
```

`image` in that response comes from `ENV_IMAGE` in the ConfigMap, not from the running image —
keep the two in step or it will lie to you.

---

## 8. Re-verify the CPU numbers on the new cluster

The ~701m system-pod figure in §0 was measured on `vincent-cluster`. Most of it is per-node
DaemonSets and should land in the same place, but confirm rather than assume — and note the
node pool is `default-pool` here:

```bash
kubectl describe node -l cloud.google.com/gke-nodepool=default-pool \
  | sed -n '/Allocated resources/,/Events/p'
```

If a rollout leaves the surge pod `Pending` with `Insufficient cpu`, the options are the same
ones already written up in
[../recommendations-service/cpu-capacity-options.md](../recommendations-service/cpu-capacity-options.md);
`e2-standard-2` ends this class of problem. Setting `maxSurge: 0` / `maxUnavailable: 1` is the
one-line fallback, at the cost of a gap in service during rollouts.
