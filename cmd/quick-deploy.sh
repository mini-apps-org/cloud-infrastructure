#!/bin/bash

set -euo pipefail

# --------------------------------------------------
# 1. Load configuration and secrets
# --------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/load-secret.sh"

export PROJECT="vincent-mini-apps-project"
export PROJECT_NUMBER
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')"

export REGION="asia-southeast1"
export LOCATION="asia-southeast1"
export ZONE="${REGION}-a"

export CLUSTER="league-cluster"
export REPOSITORY_NAME="league-repository"

export NAMESPACE_SERVICE="league"
export NAME_SERVICE="league-service"

export GITHUB_REPO="tanvinhnguyen2504/${NAMESPACE_SERVICE}-be"
export GITHUB_ACTIONS_SA_NAME="github-actions"

export POOL_ID="github-pool"
export PROVIDER_ID="github-provider"

export SA="${GITHUB_ACTIONS_SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
export GSA="${NAMESPACE_SERVICE}-sql@${PROJECT}.iam.gserviceaccount.com"

# --------------------------------------------------
# 2. Validate required secrets
# --------------------------------------------------

: "${DB_PASSWORD:?DB_PASSWORD is required}"
: "${GOOGLE_OAUTH_CLIENT_ID:?GOOGLE_OAUTH_CLIENT_ID is required}"
: "${GOOGLE_OAUTH_CLIENT_SECRET:?GOOGLE_OAUTH_CLIENT_SECRET is required}"
: "${ENCRYPTION_KEY:?ENCRYPTION_KEY is required}"

# --------------------------------------------------
# 3. Check current context
# --------------------------------------------------

kubectl config current-context

# --------------------------------------------------
# 4. Enable required GCP APIs
# --------------------------------------------------

gcloud services enable \
    iam.googleapis.com \
    iamcredentials.googleapis.com \
    cloudresourcemanager.googleapis.com \
    artifactregistry.googleapis.com \
    container.googleapis.com \
    --project="$PROJECT"

# --------------------------------------------------
# 5. Create Artifact Registry if not exists
# --------------------------------------------------

if ! gcloud artifacts repositories describe "$REPOSITORY_NAME" \
    --location="$LOCATION" \
    --project="$PROJECT" >/dev/null 2>&1; then

    gcloud artifacts repositories create "$REPOSITORY_NAME" \
        --repository-format=docker \
        --location="$LOCATION" \
        --project="$PROJECT" \
        --description="League Repository"
fi

# --------------------------------------------------
# 6. Create GKE Cloud SQL service account
# --------------------------------------------------

if ! gcloud iam service-accounts describe "$GSA" \
    --project="$PROJECT" >/dev/null 2>&1; then

    gcloud iam service-accounts create "${NAMESPACE_SERVICE}-sql" \
        --project="$PROJECT" \
        --display-name="${NAMESPACE_SERVICE} service Cloud SQL client"
fi

# Grant Cloud SQL Client permission
gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:${GSA}" \
    --role="roles/cloudsql.client"

# --------------------------------------------------
# 7. Create Kubernetes namespace and resources
# --------------------------------------------------

kubectl apply -f "k8s/${NAME_SERVICE}/namespace.yaml"

# Create/update Kubernetes secrets
kubectl -n "$NAMESPACE_SERVICE" create secret generic "${NAME_SERVICE}-secrets" \
    --from-literal=DB_PASSWORD="$DB_PASSWORD" \
    --from-literal=GOOGLE_OAUTH_CLIENT_ID="$GOOGLE_OAUTH_CLIENT_ID" \
    --from-literal=GOOGLE_OAUTH_CLIENT_SECRET="$GOOGLE_OAUTH_CLIENT_SECRET" \
    --from-literal=ENCRYPTION_KEY="$ENCRYPTION_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -

# Apply Kubernetes manifests
kubectl apply -k "k8s/${NAME_SERVICE}"

# Connect Kubernetes Service Account to GSA
kubectl -n "$NAMESPACE_SERVICE" annotate serviceaccount "$NAME_SERVICE" \
    "iam.gke.io/gcp-service-account=${GSA}" \
    --overwrite

# Allow KSA to impersonate GSA
gcloud iam service-accounts add-iam-policy-binding "$GSA" \
    --project="$PROJECT" \
    --role="roles/iam.workloadIdentityUser" \
    --member="serviceAccount:${PROJECT}.svc.id.goog[${NAMESPACE_SERVICE}/${NAME_SERVICE}]"

# Wait for deployment
kubectl -n "$NAMESPACE_SERVICE" rollout status \
    "deploy/${NAME_SERVICE}" --timeout=5m

# --------------------------------------------------
# 8. GitHub Actions Workload Identity Federation
# --------------------------------------------------

# Create GitHub Actions service account if not exists
if ! gcloud iam service-accounts describe "$SA" \
    --project="$PROJECT" >/dev/null 2>&1; then

    gcloud iam service-accounts create "$GITHUB_ACTIONS_SA_NAME" \
        --project="$PROJECT" \
        --display-name="GitHub Actions deployment"
fi

# Create Workload Identity Pool if not exists
if ! gcloud iam workload-identity-pools describe "$POOL_ID" \
    --project="$PROJECT" \
    --location="global" >/dev/null 2>&1; then

    gcloud iam workload-identity-pools create "$POOL_ID" \
        --project="$PROJECT" \
        --location="global" \
        --display-name="GitHub Actions Pool"
fi

# Only allow these repositories to authenticate
ATTRIBUTE_CONDITION="assertion.repository in ['tanvinhnguyen2504/auth-service', 'tanvinhnguyen2504/recommendations-be', 'tanvinhnguyen2504/league-be']"

# Create or update OIDC provider
if gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
    --project="$PROJECT" \
    --location="global" \
    --workload-identity-pool="$POOL_ID" >/dev/null 2>&1; then

    gcloud iam workload-identity-pools providers update-oidc "$PROVIDER_ID" \
        --project="$PROJECT" \
        --location="global" \
        --workload-identity-pool="$POOL_ID" \
        --issuer-uri="https://token.actions.githubusercontent.com" \
        --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
        --attribute-condition="$ATTRIBUTE_CONDITION"

else

    gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
        --project="$PROJECT" \
        --location="global" \
        --workload-identity-pool="$POOL_ID" \
        --display-name="GitHub Actions Provider" \
        --issuer-uri="https://token.actions.githubusercontent.com" \
        --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
        --attribute-condition="$ATTRIBUTE_CONDITION"

fi

# Allow only the league repository to impersonate this service account
gcloud iam service-accounts add-iam-policy-binding "$SA" \
    --project="$PROJECT" \
    --role="roles/iam.workloadIdentityUser" \
    --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/attribute.repository/${GITHUB_REPO}"

echo "Infrastructure preflight completed successfully!"

# Get the allocated IPv4 to register the record in CloudFlare
# gcloud compute addresses create league-service-ip --global
# gcloud compute addresses describe $NAMESPACE_SERVICE-service-ip --global --format='value(address)'
# E.g: gcloud compute addresses describe league-service-ip --global --format='value(address)'

# TEMP_DIR=$(mktemp -d)

# kubectl -n league create secret tls league-service-origin-tls \
#   --cert="$TEMP_DIR/mvip-league-be-origin.pem" \
#   --key="$TEMP_DIR/mvip-league-be-origin.key"