# 2026-11-25

- feat(league): deploy tag `0.10.1`
- feat(monitoring): ship league's logs to Grafana Cloud Loki with Alloy, queryable in Grafana as `league-loki`
- refactor(make): `make health` always goes through the public `HEALTH_URL` — the LoadBalancer-IP fallback is gone
- docs: rewrite the auth and recommendations deploy guides for Helm (`make diff` / `apply` / `rollback`)
- docs: remove `manifest-reference.md` and `parameters.md`, which described the deleted `k8s/` files
- docs: track which services still need Helm adoption in `helm-migration.md`
- docs: add guides for querying league's logs in Cloud Logging and in Loki

# 2026-11-23

- feat(league): deploy tag `0.9.0`

# 2026-11-20

- [PR4](https://github.com/mini-apps-org/cloud-infrastructure/pull/4)
  - chore(k8s): remove the Kustomize manifests in `k8s/` — the Helm chart replaces them; the last commit with `k8s/` is `1f2535c`

# 2026-11-19

- [PR3](https://github.com/mini-apps-org/cloud-infrastructure/pull/3)
  - feat(helm): opt-in `podMonitoring` lets Google Managed Prometheus scrape a service's `/metrics`
  - feat(helm): optional `metricsPort` serves `/metrics` on its own port, out of reach of the Ingress
  - feat(league): turn on metrics scraping for league-service
  - feat(monitoring): Grafana on `league-cluster`, public at `monitoring.mvip-league.com` behind Cloudflare Access
  - feat(monitoring): query league's logs in Grafana from Cloud Logging, read as the `grafana-logs-reader` service account
  - docs: add Grafana setup and public-access guides for league
- feat(league): deploy tag `0.7.0`

# 2026-11-18

- [PR2](https://github.com/mini-apps-org/cloud-infrastructure/pull/2)
  - feat(helm): one shared chart `helm/mini-app-service` with per-service values, plus a migration guide
  - fix(deploy): `quick-deploy.sh` targets the `mini-apps-org` repos again; add `setup-cd-access.sh` for CD access
  - feat(ci-cd): validate the chart on PRs; deploy a service when its values change on `master`
  - docs: add `deployment-workflow-context.md` — how an image goes from build to deploy
  - chore: `make apply` / `rollback` / `diff` run Helm; `apply-config` is gone

# 2026-11-17

- feat(league): deploy tag `0.5.1`
- feat(league): deploy tag `0.5.3`

# 2026-11-07

- docs: add cluster-creation — a standalone, project-agnostic guide to setting up a basic GKE cluster with `gcloud`

# 2026-11-06

- feat(league): target a dedicated `league-cluster` instead of sharing `vincent-cluster`
- feat(league): give league its own Cloud SQL instance `league-app-instance`
- feat(league): roll with `maxUnavailable: 0` / `maxSurge: 1`, now that the node has room
- feat(make): refuse to run kubectl targets against the wrong cluster for `SVC`
- fix(league): the `*.vincentn.dev` Origin cert cannot cover `be.mvip-league.com` — needs its own
- docs: document two clusters and two Cloudflare zones across the shared references

# 2026-11-04

- docs: correct stale facts in the service docs
- docs: remove redundancy docs and add reuse docs "edge-architecture/troubleshooting"
- docs: add gke-parameters reference
- feat(league): reserve league-service
- feat(recommendations): update the domain for the recommendations-server

# 2026-10-31
- feat(recommendations): config deploy recommendations-service into gke

# 2026-10-30
- feat(auth): deploy tag `0.0.1`
- feat(auth): deploy tag `0.0.2`

# 2026-10-29
- feat(auth-service): config deploy auth-service into gke