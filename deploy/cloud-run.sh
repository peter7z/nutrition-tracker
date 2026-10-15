#!/usr/bin/env bash
# Publish the committed, validated main branch to the existing official service.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
  [[ "${GITHUB_REF:-}" == refs/heads/main && "$(git rev-parse HEAD)" == "${GITHUB_SHA:-}" ]] || { echo 'Deploy the tested main commit.' >&2; exit 1; }
else
  [[ "$(git branch --show-current)" == main ]] || { echo 'Deploy from main.' >&2; exit 1; }
fi
[[ -z "$(git status --porcelain)" ]] || { echo 'Commit pending changes before deploying.' >&2; exit 1; }
sha=$(git rev-parse HEAD)
remote_sha=$(git ls-remote --exit-code origin refs/heads/main | cut -f1)
if [[ "$sha" != "$remote_sha" ]]; then
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
    echo 'A newer main commit exists; skipping obsolete deployment.'
    exit 0
  fi
  echo 'Publish main before deploying.' >&2
  exit 1
fi

project=bocado-511619
account=${BOCADO_DEPLOY_ACCOUNT:-pedrozunino7@gmail.com}
region=us-east1
image="us-east1-docker.pkg.dev/$project/bocado-api/api:main-$sha"

gcloud builds submit backend --config=deploy/cloudbuild.yaml \
  --substitutions="_IMAGE=$image" --region="$region" \
  --project="$project" --account="$account" --quiet
# A newer merge may arrive while the image builds. Never roll it back.
remote_sha=$(git ls-remote --exit-code origin refs/heads/main | cut -f1)
[[ "$sha" == "$remote_sha" ]] || { echo 'A newer main commit exists; skipping obsolete deployment.'; exit 0; }
gcloud run services update bocado-api --image="$image" \
  --update-labels="git-sha=$sha" --region="$region" \
  --project="$project" --account="$account" --quiet
gcloud run services update-traffic bocado-api --to-latest --region="$region" \
  --project="$project" --account="$account" --quiet
curl --fail --silent --show-error --retry 3 --max-time 60 \
  https://bocado-api-929368612596.us-east1.run.app/health
printf '\nPublished main %s\n' "$sha"
