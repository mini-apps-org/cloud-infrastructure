# Deployment Workflow Context: Backend CI + Infrastructure-Controlled CD

## 1. Purpose

This document captures the target deployment workflow for the backend
service repositories (`league-be` first, then `auth-service` and
`recommendations-be`) and the separate `cloud-infrastructure` repository.

The primary goal is to **prevent automatic deployment when a backend
Docker image is merely built and published**.

A backend release becomes deployable only when a developer intentionally
updates the image reference in the infrastructure repository and that
change is merged into `master`.

Every name, ID and command below is taken from this repository and the
live GCP project, verified on 2026-11-17. §12 lists what is already in
place versus what still has to be built.

## 2. Core design principles

1.  Separate **artifact creation (CI)** from **deployment approval and
    execution (CD)**.
2.  The backend repositories build and publish Docker images only.
3.  `cloud-infrastructure` is the source of truth for the deployed image
    and the Kubernetes configuration of every service.
4.  A merged change to a service's values file (or to the shared chart)
    is the deployment trigger.
5.  Pull requests validate changes but do not deploy.
6.  A merge to the protected `master` branch triggers deployment.
7.  Images are referenced by **release tag + digest**
    (`repo:0.5.0@sha256:…`), never `latest`. The chart refuses to render
    without a digest.
8.  Keep credentials out of source control. GitHub OIDC + Google Cloud
    Workload Identity Federation (WIF) only — no service-account keys.

This is a GitOps-inspired, push-based deployment workflow. It is not a
full pull-based GitOps controller model such as Argo CD or Flux.

## 3. Repositories and responsibilities

### 3.1 Backend repositories — `mini-apps-org/league-be` (and the other two)

Responsibilities:

-   Store Go backend source code and Dockerfile.
-   Run lint, vet and tests (`ci.yaml`, on PRs and pushes to `master`).
-   On a Git tag matching `*.*.*`, re-run the same gates, build the image
    and push it to Artifact Registry (`release.yaml`).
-   Report the resulting immutable reference: tag **and digest**.

It must **not** deploy to GKE. Today this already holds: `release.yaml`
impersonates `github-actions@vincent-mini-apps-project.iam.gserviceaccount.com`,
whose only project role is `roles/artifactregistry.writer`.

Example image:

``` text
asia-southeast1-docker.pkg.dev/vincent-mini-apps-project/league-repository/league-service:0.5.0@sha256:b15147867e5fabc618d23fee19186df1be28b1d12e758f05eaa3aa0f32e91e6d
```

`release.yaml` tags the image with the Git tag verbatim and
`flavor: latest=false`, so no `latest` tag is ever pushed.

**Gap:** `release.yaml` does not print the digest, so today it is looked up
by hand. Add one step after `Build and Push Docker Image` (give that step
`id: build`):

``` yaml
      - name: Report image reference
        run: |
          {
            echo "### Image published — not deployed"
            echo '```yaml'
            echo "image:"
            echo "  tag: \"${{ github.ref_name }}\""
            echo "  digest: ${{ steps.build.outputs.digest }}"
            echo '```'
            echo "Paste into cloud-infrastructure/helm/values/league.yaml and open a PR."
          } >> "$GITHUB_STEP_SUMMARY"
```

### 3.2 `mini-apps-org/cloud-infrastructure` — infrastructure repository

Responsibilities:

-   Store the shared Helm chart and one values file per service.
-   Define the image (tag + digest) and runtime config of each service.
-   Validate changes in pull requests.
-   Deploy only after an approved change is merged into `master`.
-   Provide deployment history through Git commits, pull requests,
    GitHub Actions runs, and `helm history`.

The infrastructure repository is the explicit control point for deciding
**what version is deployed and when**.

## 4. High-level architecture

``` mermaid
flowchart TB
    subgraph BE["Repository: league-be"]
        A["Developer pushes Git tag 0.6.0"]
        B["release.yaml"]
        C["Lint / vet / test"]
        D["Build image"]
        E["Push image, report tag + digest"]
        A --> B --> C --> D --> E
    end

    E --> AR["Artifact Registry<br/>league-repository"]

    subgraph INFRA["Repository: cloud-infrastructure"]
        F["Update image.tag + image.digest<br/>in helm/values/league.yaml"]
        G["Open pull request"]
        H["validate.yaml: helm lint + template"]
        I["Review and approve"]
        J["Merge into protected master"]
        K["deploy-league.yaml → deploy-service.yaml"]
        L["helm upgrade --install league-service"]
        F --> G --> H --> I --> J --> K --> L
    end

    AR -. "node pulls the pinned digest" .-> GKE["league-cluster<br/>namespace league"]
    L --> GKE
```

Important: Artifact Registry does not trigger deployment. The push to
`master` in `cloud-infrastructure` does. GKE pulls the image only when the
Deployment's pod template changes.

## 5. Repository structure

One shared chart for all three services, one values file per service.
Everything below exists in the `feat/config-helm` branch.

``` text
cloud-infrastructure/
├── helm/
│   ├── mini-app-service/            shared chart, all three services
│   │   ├── Chart.yaml
│   │   ├── values.yaml              shared defaults
│   │   └── templates/
│   │       ├── _helpers.tpl
│   │       ├── serviceaccount.yaml
│   │       ├── configmap.yaml
│   │       ├── deployment.yaml
│   │       ├── service.yaml
│   │       └── ingress.yaml
│   └── values/
│       ├── auth.yaml
│       ├── recommendations.yaml
│       └── league.yaml
├── cmd/
│   ├── wif-config.sh                OIDC provider condition + mapping, shared
│   ├── setup-cd-access.sh           deployer identity + DNS endpoint (§9)
│   └── quick-deploy.sh              league preflight, uses wif-config.sh
└── .github/
    └── workflows/
        ├── validate.yaml            PRs: lint + render, no credentials
        ├── deploy-service.yaml      reusable: deploys ONE service
        ├── deploy-league.yaml       trigger: league's paths → league-cluster
        ├── deploy-auth.yaml         trigger: auth's paths  → vincent-cluster
        └── deploy-recommendations.yaml
```

Differences from a per-service-chart layout, on purpose:

| Choice | Why |
| --- | --- |
| One chart, not `helm/league-service/` | The three services' manifests are ~90% identical; one chart means a probe or proxy upgrade is one edit. |
| No `environments/staging` | There is one environment per service today (production). If staging is added, it becomes `helm/values/<env>/<svc>.yaml` and a second caller workflow per service. |
| No `hpa.yaml` | Each cluster is one spot `e2-medium` node with ~240m CPU free at best. There is nothing to scale onto. |
| One caller workflow per service | Each has its own path filter and its own cluster, so a league change never touches `vincent-cluster`. |

`helm/values/league.yaml` today (excerpt):

``` yaml
strategy:
  maxUnavailable: 0
  maxSurge: 1

image:
  repository: asia-southeast1-docker.pkg.dev/vincent-mini-apps-project/league-repository/league-service
  tag: "0.5.0"
  digest: sha256:b15147867e5fabc618d23fee19186df1be28b1d12e758f05eaa3aa0f32e91e6d

containerPort: 9200
```

`replicas` is `1` (the chart default). Do not copy a generic example with
`replicaCount: 2` and `250m` requests: the key is named `replicas` in this
chart, and those numbers do not fit the node.

The Deployment template builds the image from all three fields and fails
the render if any is empty:

``` yaml
image: "{{ $image }}:{{ $tag }}@{{ $digest }}"
```

Secrets are not in Helm at all. `<svc>-secrets` and `<svc>-origin-tls`
are created with `kubectl create secret` and only referenced by name from
the chart, so no credential reaches Git or Helm's release history.

## 6. End-to-end workflow

### Phase A — Build and publish an image (backend repository)

1.  Developer pushes a Git tag in `league-be`, e.g. `0.6.0`.
2.  `release.yaml` re-runs lint, vet and tests.
3.  It builds the image and pushes `league-service:0.6.0`.
4.  The job summary shows the tag and digest (after the §3.1 gap is closed).

**No GKE deployment occurs in this phase.**

### Phase B — Select the image (infrastructure repository)

1.  Developer copies `tag` + `digest` from the release job summary into
    `helm/values/league.yaml`.
2.  Only those two fields change, unless other changes are intended.
3.  Developer opens a pull request against `master`.
4.  `validate.yaml` runs.
5.  A reviewer checks the service, the tag/digest pair, and any `config:`
    change.
6.  After approval, the pull request is merged.

### Phase C — Deploy (infrastructure repository)

1.  The push to `master` matches `deploy-league.yaml`'s path filter.
2.  The job waits for the `production` GitHub Environment approval, if
    one is configured.
3.  It authenticates to Google Cloud via WIF as `gke-deployer`.
4.  It gets credentials for `league-cluster` via the DNS-based endpoint.
5.  It checks that `repo:tag` in Artifact Registry resolves to the pinned
    digest — catches a mistyped tag and a tag/digest mismatch.
6.  It checks that `league-service-secrets` and
    `league-service-origin-tls` exist in namespace `league`.
7.  It runs `helm upgrade --install league-service … --wait`.
8.  It confirms `rollout status` and writes `helm history` to the job
    summary.

## 7. Trigger and approval policy

-   Backend repos: image build on tag only; no deployment permissions.
-   `cloud-infrastructure` pull request: validation only, no GCP
    credentials.
-   `cloud-infrastructure` push to `master`: deploy a service only when
    its values file or the shared chart changed.
-   Protect `master`: pull request required, `validate` required to pass.
-   GitHub Environment `production` with a required reviewer, if a
    second approval after merge is wanted.

**A change to `config:` deploys too, deliberately.** Runtime config lives
in the same values file as the image, and the chart's `checksum/config`
annotation rolls the pods on a config change. A filter that only fired on
image changes would leave config merged but not deployed.

**A change to `helm/mini-app-service/**` deploys all three services**, in
parallel, on both clusters. That is correct — the chart is what all three
render — but review chart PRs with that blast radius in mind.

Trigger (`.github/workflows/deploy-league.yaml`; auth and recommendations
are the same with their own values file and `vincent-cluster`):

``` yaml
name: Deploy league-service

on:
  push:
    branches:
      - master
    paths:
      - "helm/values/league.yaml"
      - "helm/mini-app-service/**"
  workflow_dispatch:

jobs:
  deploy:
    uses: ./.github/workflows/deploy-service.yaml
    with:
      service: league
      cluster: league-cluster
    permissions:
      contents: read
      id-token: write
```

Notes:

-   `paths` filters file paths, not YAML fields — see the config note above.
-   The reusable `deploy-service.yaml` is deliberately not in the path
    filter: editing the deploy logic should not redeploy everything. Run
    a caller by hand (`workflow_dispatch`, from `master`) after changing it.
-   A README or `docs/` change matches no filter and deploys nothing.
-   GitHub skips path filtering when a push contains more than 1,000
    changed files or when diffing fails; squash merges keep each push to
    one commit and avoid both.

## 8. Validation and deployment workflows

### 8.1 Pull request validation (`validate.yaml`)

No GCP credentials and no `id-token` permission, so it cannot deploy even
if someone adds a deploy command. File: `.github/workflows/validate.yaml`.

| Step | Per service (matrix: auth, recommendations, league) |
| --- | --- |
| Lint and render | `helm lint` + `helm template` with `helm/values/<svc>.yaml` |
| Digest is a real sha256 | `image.digest` matches `^sha256:[0-9a-f]{64}$` |

`helm template` already fails on a missing tag, digest, port, GSA,
instance or host (`required` in the chart).

### 8.2 Deployment (`deploy-service.yaml`, reusable)

Called by the three per-service workflows. Release name, Deployment name
and KSA are all `<svc>-service` — the release name is load-bearing (it is
the Workload Identity member `…svc.id.goog[<ns>/<svc>-service]`). File:
`.github/workflows/deploy-service.yaml`.

| Step | What it does | Fails when |
| --- | --- | --- |
| Authenticate to Google Cloud | WIF as `gke-deployer` | not on `cloud-infrastructure@refs/heads/master`, or §9 not set up |
| Get GKE credentials | zone `asia-southeast1-a`, `use_dns_based_endpoint: true` | DNS endpoint not enabled (§9.4) |
| Image tag resolves to the pinned digest | `gcloud artifacts docker images describe repo:tag` == `image.digest` | tag missing, or digest copied from another tag |
| Imperative Secrets exist | `kubectl get secret <svc>-service-secrets <svc>-service-origin-tls` | a Secret was never created / was deleted |
| Deploy | `helm upgrade --install … --wait --timeout 5m` | readiness never reached; un-adopted objects (§11) |
| Verify rollout | `kubectl rollout status` | — |
| Record | `helm history --max 5` → job summary | always runs |

Job-level settings: `environment: production`, `concurrency: deploy-<svc>`
with `cancel-in-progress: false`, Helm pinned to `v4.3.1`.

No `--create-namespace`: the Secrets step fails first on a namespace
that does not exist, and a first-ever deploy needs its Secrets created by
hand anyway (`docs/league-service/prerequisites.md` §4–5).

Every action is pinned to a commit SHA, with the tag in a comment —
`actions/checkout` v4.4.0 and `google-github-actions/auth` v2.1.13 (same as
`league-be`), `get-gke-credentials` v2.3.5, `azure/setup-helm` v4.3.1.
`use_dns_based_endpoint` was confirmed in that action's `action.yml`.

## 9. Google Cloud and Kubernetes prerequisites

### 9.1 What exists today

| Item | State (verified 2026-11-17) |
| --- | --- |
| WIF pool / provider | `github-pool` / `github-provider` in project `225614846438` |
| Provider attribute condition | `assertion.repository in ['mini-apps-org/league-be','mini-apps-org/recommendations-be','mini-apps-org/auth-service']` — **`cloud-infrastructure` is not in it** until `cmd/setup-cd-access.sh` runs |
| Build identity | `github-actions@…` — `roles/artifactregistry.writer` only |
| Deploy identity | **none** — `cmd/setup-cd-access.sh` creates `gke-deployer` |
| `league-cluster`, `vincent-cluster` | both RUNNING, zonal `asia-southeast1-a`, GKE 1.36.4, Workload Identity enabled |
| Control-plane access (both) | authorized networks = `171.250.163.159/32` only; DNS endpoint exists but `allowExternalTraffic: false` |

### 9.2 `cmd/quick-deploy.sh` — fixed in this branch

It used to inline `ATTRIBUTE_CONDITION` with `tanvinhnguyen2504/…`, while
the live provider uses `mini-apps-org/…`; re-running it would have
overwritten the live condition and broken image builds for all three
services. The condition **and** mapping now live in `cmd/wif-config.sh`,
sourced by both scripts, because each runs `providers update-oidc`, which
replaces them wholesale — two copies would silently fight. `GITHUB_REPO`
now uses `mini-apps-org` too.

### 9.3 GitHub-to-GCP authentication for `cloud-infrastructure`

**Run `cmd/setup-cd-access.sh`** (idempotent). It:

1. creates `gke-deployer@vincent-mini-apps-project.iam.gserviceaccount.com` —
   **separate** from `github-actions`, so a compromised backend tag build
   cannot deploy and a compromised deploy cannot push images;
2. grants it `roles/container.developer` (manage workloads on both
   clusters, incl. Helm's release Secrets) and `roles/artifactregistry.reader`
   (the tag→digest check);
3. updates the provider from `cmd/wif-config.sh`: adds
   `mini-apps-org/cloud-infrastructure` to the condition, and adds the
   mapping `attribute.repo_ref = assertion.repository + '@' + assertion.ref`;
4. binds `roles/iam.workloadIdentityUser` on the deployer to
   `principalSet://…/attribute.repo_ref/mini-apps-org/cloud-infrastructure@refs/heads/master`;
5. enables the DNS endpoint on both clusters (§9.4).

**Why `repo_ref` and not `repository`:** binding on the repository alone
would let any workflow in `cloud-infrastructure` — including a PR branch
that grants itself `id-token: write` — become the deployer. Branch
protection is a GitHub setting IAM never sees. Binding on
`attribute.ref` alone would admit `league-be`'s `master` too. The combined
attribute makes IAM itself require *this repo on master*. GitHub
Environments and branch protection remain the human gate on top.

`roles/container.developer` is project-wide: both clusters, all
namespaces, including reading Secrets. Acceptable for three services and
one operator. The tighter version is `roles/container.clusterViewer` plus a
Kubernetes `RoleBinding` per namespace for the GSA's email; it is worth
doing before anyone else gets merge rights.

### 9.4 Runner-to-cluster connectivity — currently blocked

GitHub-hosted runners come from rotating Azure ranges and will never be
inside `171.250.163.159/32`, so `kubectl` from a runner **hangs and times
out** — it does not return an auth error. Turn on the DNS-based endpoint
on each cluster; it is authorized by IAM (the deployer's
`container.developer`), and the IP allowlist does not apply to it:

``` bash
# done by cmd/setup-cd-access.sh, skipped if already enabled
gcloud container clusters update league-cluster  --zone asia-southeast1-a --enable-dns-access
gcloud container clusters update vincent-cluster --zone asia-southeast1-a --enable-dns-access
```

No node restart; the existing IP endpoint and its allowlist are
unchanged. This is the same fix `docs/cluster-creation.md` recommends for
a rotating home IP. `use_dns_based_endpoint: true` in §8.2 then makes the
workflow use it.

### 9.5 Artifact Registry access

Nodes pull with the default compute service account, which already reads
both repos — every live service proves this. The deployer's
`artifactregistry.reader` is only for the tag→digest check. A successful
push from `league-be` still does not prove a node can pull; the rollout
step is what proves it.

### 9.6 Runtime configuration and secrets

Non-secret config lives in `config:` in each values file and is rendered
into the ConfigMap. Secrets stay imperative Kubernetes Secrets, created
once per namespace; the deploy workflow only checks they exist. Moving
them to Secret Manager (e.g. the Secret Manager add-on with the CSI
driver) is a separate decision — see §13.

## 10. Image versioning and deployment safety

In place:

-   Release tag + digest required by the chart; `latest` never pushed.
-   Startup, readiness and liveness probes on `/api/v1/health`, plus a
    startup probe on the proxy sidecar.
-   Requests and limits on both containers.
-   `--wait --timeout 5m` and `rollout status`.
-   Per-service `concurrency` — deploys of one service are serialized,
    different services run in parallel.
-   Deployed reference recorded in Git, the Actions run, and `helm history`.

Rollout cost per cluster:

| Service | Strategy | What a deploy looks like |
| --- | --- | --- |
| league | `maxUnavailable: 0` / `maxSurge: 1` | No gap |
| auth, recommendations | `maxUnavailable: 1` / `maxSurge: 0` | ~30–60 s of 502s: the full node cannot hold two copies |

Rollback:

-   **Normal path: `git revert` the merge commit and merge the revert.**
    That redeploys the previous tag + digest through the same workflow,
    and Git stays the source of truth.
-   **Emergency path: `helm -n <ns> rollback <svc>-service`** from a laptop
    (the IP allowlist still admits it). Follow up with the revert, or the
    next deploy re-applies the bad values.
-   `helm rollback` restores the ConfigMap too; `kubectl rollout undo` does
    not, and leaves Helm's record wrong — do not use it any more.
-   No rollback reverses database migrations, data changes or external
    side effects. Migrations must be backward-compatible with the previous
    image and run as their own step.
-   Failed deploys do **not** auto-rollback (`--rollback-on-failure` is not
    set): a failed rollout leaves the old ReplicaSet serving on league,
    and an operator decides. Revisit if that ever pages someone at night.

## 11. Ordering constraint: migrate to Helm before enabling CD

The deploy workflow assumes each service is already a Helm release. On a
service still applied with `kubectl apply -k`, the first CI
`helm upgrade --install` fails with "invalid ownership metadata". Do the
one-time adoption by hand first — `docs/helm-migration.md` §3, per
service. All three caller workflows ship in this branch, and **merging it
is itself the first CI run** (it touches `helm/mini-app-service/**`), so
adopt all three before merging (§12 Stage 4).

## 12. Implementation plan

Repo side is done in `feat/config-helm`; what remains is live actions,
in this order.

### Stage 1 — Chart

-   [x] Shared chart `helm/mini-app-service` + three values files.
-   [x] Image from `repository` + `tag` + `digest`; render fails without.
-   [x] `helm lint` / `helm template` pass; render matches Kustomize
    except Helm labels and `checksum/config`.
-   [x] Tooling cutover: Makefile on Helm, `quick-deploy.sh` on Helm,
    `k8s/` removed, docs updated (`docs/helm-migration.md` §4).
-   [ ] **Live:** adopt each service into Helm (`docs/helm-migration.md`
    §3): league → recommendations → auth. `vincent-cluster`'s node pool is
    at 0 nodes as of 2026-11-17, so scale it back up before adopting those
    two, or `helm --wait` times out.

### Stage 2 — Access

-   [x] Fix `cmd/quick-deploy.sh`'s repository owner (§9.2).
-   [x] Script for the deployer identity, provider update, bindings and
    DNS endpoint: `cmd/setup-cd-access.sh` (§9.3, §9.4).
-   [ ] **Live:** run `cmd/setup-cd-access.sh` with the `personal`
    gcloud configuration.
-   [ ] **Live:** prove the path from a laptop, impersonating the deployer:
    `gcloud container clusters get-credentials league-cluster --zone asia-southeast1-a --dns-endpoint --impersonate-service-account=gke-deployer@vincent-mini-apps-project.iam.gserviceaccount.com && kubectl -n league get deploy`
    (your own account needs `roles/iam.serviceAccountTokenCreator` on
    `gke-deployer` to impersonate it).

### Stage 3 — Pull request validation

-   [x] `validate.yaml` (§8.1).
-   [ ] **GitHub:** protect `master` — PR required, `Validate` checks
    required.

### Stage 4 — Controlled deployment

-   [x] `deploy-service.yaml` + `deploy-{league,auth,recommendations}.yaml`
    (§8.2, §7), actions pinned to commit SHAs.
-   [ ] **GitHub:** create the `production` Environment (reviewer optional).
-   [ ] **league-be:** add the digest report step to `release.yaml` (§3.1)
    — not done here, that repo has unrelated work in progress.
-   [ ] **Merge `feat/config-helm`.** It adds files under
    `helm/mini-app-service/**`, so the merge itself triggers all three
    deploy workflows. After Stages 1–2 that is a no-op redeploy of what is
    running; before them, all three fail at authentication and change
    nothing.

### Stage 5 — Test the control boundary

| Test | Expected result |
| --- | --- |
| Push a new tag to `league-be` | Image built and pushed, digest in the job summary; no deployment |
| Change `README.md` or `docs/` | No workflow runs |
| Open PR changing league's tag + digest | `validate` only; no deployment |
| Merge that PR | `Deploy league-service` runs; only `league-cluster` is touched |
| Merge a `config:`-only change | Deploys; pods roll because `checksum/config` changed |
| Merge a chart template change | All three services deploy, each to its own cluster |
| Tag that does not exist, or a digest from another tag | Fails at "Image tag resolves to the pinned digest"; Helm never runs |
| `league-service-secrets` deleted | Fails at "Imperative Secrets exist"; Helm never runs |
| Two league merges close together | Second run waits for the first (`concurrency`) |
| Image that fails its readiness probe | `helm --wait` fails; on league the old pod keeps serving; workflow red |
| PR adds `helm upgrade` to `validate.yaml` | Fails to authenticate: no `id-token` permission. A PR that *also* grants `id-token: write` would get through — only the `refs/heads/master` binding in §9.3 closes that |

## 13. Decisions

Resolved:

| Question | Decision |
| --- | --- |
| Deployment branch | `master` (the repo's default; there is no `main` in use) |
| Deploy on any values change, or image only? | Any change to the service's values file — config deploys with it |
| Tag, SHA or digest? | Release tag **and** digest, both required |
| Cluster / project / names | `league-cluster` (zone `asia-southeast1-a`), `vincent-mini-apps-project`, namespace `league`, release = Deployment = KSA = `league-service` |
| Reachable from GitHub-hosted runners? | Not today — via the DNS endpoint after §9.4 |
| Secret mechanism | Imperative Kubernetes Secrets, checked (not created) by CD |
| Auto-rollback on failure? | No; operator decides, normal rollback is `git revert` |

Still open:

-   Should production require a GitHub Environment reviewer after merge,
    or is the PR review enough for a single-operator setup?
-   Narrow `roles/container.developer` to per-namespace RBAC now, or when
    a second person gets merge rights?
-   Move Secrets to Secret Manager?
-   Add a staging environment, and if so on which cluster — neither node
    has CPU for a second copy of every service.

## 14. Target outcome

``` text
league-be:
  Git tag
    -> lint / vet / test
    -> build image
    -> push to Artifact Registry, report tag + digest
    -> STOP (no deployment)

cloud-infrastructure:
  Update image.tag + image.digest in helm/values/league.yaml
    -> pull request
    -> validate (no credentials)
    -> review and approve
    -> merge to protected master
    -> deploy-league.yaml (WIF as gke-deployer, DNS endpoint)
    -> tag→digest check, Secrets check
    -> helm upgrade --install league-service --wait
    -> rollout verification
```

**The backend repository produces deployable artifacts. The
infrastructure repository explicitly selects and authorizes which
artifact is deployed.**
