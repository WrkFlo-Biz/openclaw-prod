#!/bin/bash
# OpenClaw Cloud Ops — quick commands for managing the production container
# Usage: ./scripts/ops.sh <command>
set -euo pipefail

RG="openclaw-rg"
APP="openclaw-gateway"

case "${1:-help}" in
  status)
    echo "=== Container App Status ==="
    az containerapp show -g "$RG" -n "$APP" --query '{fqdn:properties.configuration.ingress.fqdn, revision:properties.latestRevisionName, running:properties.runningStatus}' -o table
    ;;
  logs)
    LINES="${2:-100}"
    az containerapp logs show -g "$RG" -n "$APP" --tail "$LINES"
    ;;
  health)
    FQDN="$(az containerapp show -g "$RG" -n "$APP" --query properties.configuration.ingress.fqdn -o tsv)"
    curl -fsS "https://${FQDN}/api/health" && echo " OK" || echo " FAILED"
    ;;
  restart)
    REV="$(az containerapp show -g "$RG" -n "$APP" --query properties.latestRevisionName -o tsv)"
    echo "Restarting revision: $REV"
    az containerapp revision restart -g "$RG" -n "$APP" --revision "$REV"
    echo "Restarted."
    ;;
  deploy)
    TAG="${2:-latest}"
    echo "Deploying image tag: $TAG"
    gh workflow run deploy.yml -f imageTag="$TAG" -f skipBuild=true
    echo "Deploy triggered. Watch with: gh run watch"
    ;;
  build-deploy)
    echo "Triggering full build + deploy..."
    gh workflow run deploy.yml
    echo "Build+deploy triggered. Watch with: gh run watch"
    ;;
  revisions)
    az containerapp revision list -g "$RG" -n "$APP" --query '[].{name:name, active:properties.active, created:properties.createdTime, status:properties.runningStatus}' -o table
    ;;
  secrets)
    az containerapp secret list -g "$RG" -n "$APP" --query '[].name' -o tsv
    ;;
  env)
    az containerapp show -g "$RG" -n "$APP" --query 'properties.template.containers[0].env[?!contains(value,`secretref`)].{name:name, value:value}' -o table
    ;;
  help|*)
    echo "OpenClaw Ops Commands:"
    echo "  status        - Show container app status and FQDN"
    echo "  logs [N]      - Show last N log lines (default: 100)"
    echo "  health        - Check health endpoint"
    echo "  restart       - Restart current revision"
    echo "  deploy [tag]  - Deploy a specific image tag (skip build)"
    echo "  build-deploy  - Trigger full build + deploy"
    echo "  revisions     - List all revisions"
    echo "  secrets       - List configured secrets"
    echo "  env           - Show non-secret env vars"
    ;;
esac
