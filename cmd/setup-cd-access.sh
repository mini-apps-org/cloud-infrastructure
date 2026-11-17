#!/bin/bash

# One-time GCP setup that lets .github/workflows/deploy-service.yaml deploy:
# a deployer identity that only cloud-infrastructure's master branch can
# impersonate, and a control-plane endpoint a GitHub-hosted runner can reach.
# Idempotent -- safe to re-run. See deployment-workflow-context.md §9.

set -euo pipefail

# --------------------------------------------------
# 1. Configuration
# --------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/wif-config.sh"

export PROJECT="vincent-mini-apps-project"
export PROJECT_NUMBER
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')"

export ZONE="asia-southeast1-a"
CLUSTERS=("vincent-cluster" "league-cluster")

export DEPLOYER_NAME="gke-deployer"
export DEPLOYER="${DEPLOYER_NAME}@${PROJECT}.iam.gserviceaccount.com"

# Repository AND branch: the only token allowed to become the deployer is a
# workflow running on cloud-infrastructure's master. Branch protection is a
# GitHub setting that IAM never sees; this is the guard IAM enforces itself.
export DEPLOY_REPO_REF="${GITHUB_ORG}/cloud-infrastructure@refs/heads/master"

# --------------------------------------------------
# 2. Deployer service account
# --------------------------------------------------

# Separate from github-actions (image builds): a compromised backend tag
# build cannot deploy, and a compromised deploy cannot push images.
if ! gcloud iam service-accounts describe "$DEPLOYER" \
    --project="$PROJECT" >/dev/null 2>&1; then

    gcloud iam service-accounts create "$DEPLOYER_NAME" \
        --project="$PROJECT" \
        --display-name="cloud-infrastructure deployments"
fi

# container.developer: manage workloads on both clusters, which helm needs
# (including the Secrets it stores release history in). Project-wide --
# narrow to clusterViewer + per-namespace RBAC before others get merge rights.
gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:${DEPLOYER}" \
    --role="roles/container.developer" \
    --condition=None >/dev/null

# artifactregistry.reader: the tag -> digest check before helm runs.
gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:${DEPLOYER}" \
    --role="roles/artifactregistry.reader" \
    --condition=None >/dev/null

# --------------------------------------------------
# 3. Let cloud-infrastructure through the OIDC provider
# --------------------------------------------------

# Adds cloud-infrastructure to the condition and attribute.repo_ref to the
# mapping. Both come from wif-config.sh, shared with quick-deploy.sh.
gcloud iam workload-identity-pools providers update-oidc "$PROVIDER_ID" \
    --project="$PROJECT" \
    --location="global" \
    --workload-identity-pool="$POOL_ID" \
    --attribute-mapping="$WIF_ATTRIBUTE_MAPPING" \
    --attribute-condition="$WIF_ATTRIBUTE_CONDITION"

gcloud iam service-accounts add-iam-policy-binding "$DEPLOYER" \
    --project="$PROJECT" \
    --role="roles/iam.workloadIdentityUser" \
    --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/attribute.repo_ref/${DEPLOY_REPO_REF}" \
    >/dev/null

# --------------------------------------------------
# 4. DNS-based control-plane endpoint
# --------------------------------------------------

# GitHub-hosted runners are never inside the IP allowlist, and kubectl HANGS
# rather than failing against it. The DNS endpoint is authorized by IAM
# (container.developer above) instead of source IP. No node restart; the IP
# endpoint and its allowlist are unchanged.
for cluster in "${CLUSTERS[@]}"; do
    enabled="$(gcloud container clusters describe "$cluster" \
        --zone="$ZONE" --project="$PROJECT" \
        --format='value(controlPlaneEndpointsConfig.dnsEndpointConfig.allowExternalTraffic)')"

    if [ "$enabled" != "True" ]; then
        gcloud container clusters update "$cluster" \
            --zone="$ZONE" --project="$PROJECT" \
            --enable-dns-access
    fi
done

echo "CD access configured for ${DEPLOYER}."
echo
echo "Prove the path from this machine (needs roles/iam.serviceAccountTokenCreator"
echo "on ${DEPLOYER} for your own account):"
echo "  gcloud container clusters get-credentials league-cluster --zone ${ZONE} \\"
echo "    --dns-endpoint --impersonate-service-account=${DEPLOYER}"
echo "  kubectl -n league get deploy"
