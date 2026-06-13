#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB_DIR="$ROOT_DIR/web"

command -v vercel >/dev/null 2>&1 || {
  echo "missing Vercel CLI; install with: npm install --global vercel@54.13.0" >&2
  exit 1
}

npm ci --prefix "$WEB_DIR"
npm run build --prefix "$WEB_DIR"

if [[ -n "${VERCEL_ORG_ID:-}" && -n "${VERCEL_PROJECT_ID:-}" ]]; then
  mkdir -p "$WEB_DIR/.vercel"
  printf '{"orgId":"%s","projectId":"%s"}\n' "$VERCEL_ORG_ID" "$VERCEL_PROJECT_ID" > "$WEB_DIR/.vercel/project.json"
fi

cd "$WEB_DIR"

if [[ -n "${VERCEL_TOKEN:-}" ]]; then
  vercel pull --yes --environment=production --token "$VERCEL_TOKEN"
  vercel build --prod --token "$VERCEL_TOKEN"
  vercel deploy --prebuilt --prod --token "$VERCEL_TOKEN"
else
  vercel pull --yes --environment=production
  vercel build --prod
  vercel deploy --prebuilt --prod
fi
