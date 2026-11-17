#!/bin/bash
# Single source of truth for the GitHub Actions OIDC provider
# (github-pool/github-provider). Sourced by quick-deploy.sh and
# setup-cd-access.sh: both run `providers update-oidc`, which REPLACES the
# condition and the mapping, so two copies drifting apart means whichever
# script ran last silently wins -- that is how a stale repository owner once
# ended up in quick-deploy.sh.

export GITHUB_ORG="mini-apps-org"
export POOL_ID="github-pool"
export PROVIDER_ID="github-provider"

# Repositories allowed to exchange a token at all. Who may impersonate WHICH
# service account is decided by the per-SA bindings, not here.
export WIF_ATTRIBUTE_CONDITION="assertion.repository in ['${GITHUB_ORG}/auth-service', '${GITHUB_ORG}/recommendations-be', '${GITHUB_ORG}/league-be', '${GITHUB_ORG}/cloud-infrastructure']"

# attribute.repo_ref exists for the deployer binding: it lets IAM require
# repository AND branch together (cloud-infrastructure@refs/heads/master).
# Binding on attribute.ref alone would also admit league-be's master.
export WIF_ATTRIBUTE_MAPPING="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repo_ref=assertion.repository+'@'+assertion.ref"
