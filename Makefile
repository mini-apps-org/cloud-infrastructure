# Deploy helpers for the Helm chart in this repo (helm/mini-app-service, one
# values file per service). Images are built in the service repos
# (../recommendations-be, ../auth-be, ../league/league-be).
#
#   make apply              # recommendations
#   make apply SVC=auth     # auth-service
#   make apply SVC=league   # league-service
#
# Once CI deploys (.github/workflows/deploy-*.yaml), merging to master is the
# normal path; `make apply` is for a laptop deploy or an emergency.

SVC ?= recommendations

NS     := $(SVC)
# Also the Helm release name -- load-bearing: it is the KSA name in the
# Workload Identity member ...svc.id.goog[<ns>/<svc>-service].
DEPLOY := $(SVC)-service
CHART  := helm/mini-app-service
VALUES := helm/values/$(SVC).yaml
KNS    := kubectl -n $(NS)
HELM   := helm -n $(NS)

ifeq ($(wildcard $(VALUES)),)
  $(error unknown SVC "$(SVC)" -- try recommendations, auth or league)
endif

# SVC selects a CLUSTER, not just a namespace: auth and recommendations share
# vincent-cluster, league has its own. kubectl follows whichever context is
# current and says nothing about it, so without this guard
# `make apply SVC=league` on a vincent-cluster context deploys league into the
# shared cluster -- where it cannot schedule anyway, leaving a Pending pod and
# a confusing 5-minute rollout timeout.
ZONE := asia-southeast1-a
CLUSTER_auth            := vincent-cluster
CLUSTER_recommendations := vincent-cluster
CLUSTER_league          := league-cluster
CLUSTER := $(CLUSTER_$(SVC))

.DEFAULT_GOAL := help

.PHONY: help
help: ## List targets
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

# Every kubectl target depends on this. Not in `help` on purpose -- it is a
# precondition, not something you run.
.PHONY: check-context
check-context:
	@ctx=$$(kubectl config current-context 2>/dev/null) || { \
	  echo "no current kubectl context" >&2; exit 1; }; \
	case "$$ctx" in \
	  *_$(CLUSTER)) ;; \
	  *) echo "SVC=$(SVC) expects cluster $(CLUSTER), but the current context is:" >&2; \
	     echo "  $$ctx" >&2; \
	     echo "switch with:" >&2; \
	     echo "  gcloud container clusters get-credentials $(CLUSTER) --zone $(ZONE)" >&2; \
	     exit 1;; \
	esac

# kubectl diff exits 1 whenever there IS a difference, hence `|| true`.
.PHONY: diff
diff: check-context ## Preview changes against the live cluster
	helm template $(DEPLOY) $(CHART) -n $(NS) -f $(VALUES) | kubectl diff -f - || true

# No separate apply-config any more: the chart's checksum/config annotation
# rolls the pods whenever the rendered ConfigMap data changes.
.PHONY: apply
apply: check-context ## helm upgrade --install and wait
	$(HELM) upgrade --install $(DEPLOY) $(CHART) -f $(VALUES) --wait --timeout 5m
	$(KNS) rollout status deploy/$(DEPLOY) --timeout=5m

.PHONY: restart
restart: check-context ## Bounce the pods
	$(KNS) rollout restart deploy/$(DEPLOY)
	$(KNS) rollout status deploy/$(DEPLOY) --timeout=5m

.PHONY: status
status: check-context ## Wait on the current rollout
	$(KNS) rollout status deploy/$(DEPLOY) --timeout=5m

# helm rollback, not `kubectl rollout undo`: it also restores the ConfigMap and
# keeps Helm's record true. Follow it with a `git revert` of the values change,
# or the next CI deploy re-applies it.
.PHONY: rollback
rollback: check-context ## Roll back to the previous Helm revision
	$(HELM) rollback $(DEPLOY) --wait --timeout 5m
	$(KNS) rollout status deploy/$(DEPLOY) --timeout=5m

.PHONY: history
history: check-context ## Helm revisions for this service
	$(HELM) history $(DEPLOY)

.PHONY: ps
ps: check-context ## Show pods
	@$(KNS) get pods -l app=$(DEPLOY) -o wide

.PHONY: logs
logs: check-context ## Tail the app container
	$(KNS) logs -f deploy/$(DEPLOY) -c $(DEPLOY) --tail=100

.PHONY: logs-proxy
logs-proxy: check-context ## Tail the cloud-sql-proxy sidecar
	$(KNS) logs -f deploy/$(DEPLOY) -c cloud-sql-proxy --tail=100

.PHONY: events
events: check-context ## Pod events -- read this first on a failure
	@$(KNS) describe pod -l app=$(DEPLOY) | sed -n '/^Events/,$$p'

# All three services are ClusterIP behind their own Ingress now, so there is no
# LoadBalancer IP to read. The fallback below stays for any service that still
# has one.
HEALTH_URL_auth            := https://auth.vincentn.dev
HEALTH_URL_recommendations := https://recommendations-be.vincentn.dev
HEALTH_URL_league          := https://be.mvip-league.com
HEALTH_URL ?= $(HEALTH_URL_$(SVC))

.PHONY: health
health: ## curl /api/v1/health (HEALTH_URL, else the LoadBalancer IP)
	@base='$(HEALTH_URL)'; \
	if [ -z "$$base" ]; then \
	  ip=$$($(KNS) get svc $(DEPLOY) -o jsonpath='{.status.loadBalancer.ingress[0].ip}'); \
	  [ -n "$$ip" ] || { echo "no LoadBalancer IP and no HEALTH_URL for SVC=$(SVC)" >&2; exit 1; }; \
	  base="http://$$ip"; \
	fi; \
	curl -fsS "$$base/api/v1/health"; printf '\n'
