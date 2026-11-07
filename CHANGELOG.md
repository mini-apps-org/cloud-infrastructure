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