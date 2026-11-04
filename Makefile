# Deploy helpers for the k8s manifests in this repo.
# Images are built in the service repos (../recommendations-be, ../auth-be,
# ../../league/league-be).
#
#   make apply              # recommendations
#   make apply SVC=auth     # auth-service
#   make apply SVC=league   # league-service

SVC ?= recommendations

NS     := $(SVC)
DEPLOY := $(SVC)-service
DIR    := k8s/$(SVC)-service
KNS    := kubectl -n $(NS)

ifeq ($(wildcard $(DIR)/kustomization.yaml),)
  $(error unknown SVC "$(SVC)" -- try recommendations, auth or league)
endif

.DEFAULT_GOAL := help

.PHONY: help
help: ## List targets
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: apply
apply: ## Apply manifests and wait
	kubectl apply -k $(DIR)
	$(KNS) rollout status deploy/$(DEPLOY) --timeout=5m

# No configMapGenerator, so the ConfigMap has no name hash: editing it does not
# roll the Deployment. The restart is required, not a convenience.
.PHONY: apply-config
apply-config: ## Apply after a configmap.yaml change
	kubectl apply -k $(DIR)
	$(KNS) rollout restart deploy/$(DEPLOY)
	$(KNS) rollout status deploy/$(DEPLOY) --timeout=5m

.PHONY: restart
restart: ## Bounce the pods
	$(KNS) rollout restart deploy/$(DEPLOY)
	$(KNS) rollout status deploy/$(DEPLOY) --timeout=5m

.PHONY: status
status: ## Wait on the current rollout
	$(KNS) rollout status deploy/$(DEPLOY) --timeout=5m

.PHONY: rollback
rollback: ## Undo the last rollout
	$(KNS) rollout undo deploy/$(DEPLOY)
	$(KNS) rollout status deploy/$(DEPLOY) --timeout=5m

.PHONY: ps
ps: ## Show pods
	@$(KNS) get pods -l app=$(DEPLOY) -o wide

.PHONY: logs
logs: ## Tail the app container
	$(KNS) logs -f deploy/$(DEPLOY) -c $(DEPLOY) --tail=100

.PHONY: logs-proxy
logs-proxy: ## Tail the cloud-sql-proxy sidecar
	$(KNS) logs -f deploy/$(DEPLOY) -c cloud-sql-proxy --tail=100

.PHONY: events
events: ## Pod events -- read this first on a failure
	@$(KNS) describe pod -l app=$(DEPLOY) | sed -n '/^Events/,$$p'

# All three services are ClusterIP behind their own Ingress now, so there is no
# LoadBalancer IP to read. The fallback below stays for any service that still
# has one.
HEALTH_URL_auth            := https://auth.vincentn.dev
HEALTH_URL_recommendations := https://recommendations-be.vincentn.dev
HEALTH_URL_league          := https://mvip-league-be.dev
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
