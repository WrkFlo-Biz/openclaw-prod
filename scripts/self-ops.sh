#!/bin/bash
# OpenClaw Self-Ops — commands the bots can run from inside the container
# Usage: self-ops <command>
set -euo pipefail

case "${1:-help}" in
  restart)
    echo "Restarting container in 3 seconds..."
    sleep 3
    # Send SIGTERM to PID 1 (entrypoint). Azure Container Apps auto-restarts.
    kill -TERM 1
    ;;
  redeploy)
    TAG="${2:-latest}"
    echo "Triggering redeploy (image: $TAG, skip build)..."
    gh workflow run deploy.yml \
      --repo "${GITHUB_REPO:-Wrk-Flo/openclaw-prod}" \
      -f imageTag="$TAG" \
      -f skipBuild=true
    echo "Redeploy triggered. Container will restart in ~3-5 minutes."
    ;;
  full-deploy)
    echo "Triggering full build + deploy..."
    gh workflow run deploy.yml \
      --repo "${GITHUB_REPO:-Wrk-Flo/openclaw-prod}"
    echo "Full deploy triggered. Container will restart in ~18 minutes."
    ;;
  health)
    curl -fsS http://localhost:18789/api/health && echo " OK" || echo " FAILED"
    ;;
  status)
    echo "=== Container Self-Check ==="
    echo "Hostname: $(hostname)"
    echo "Uptime: $(uptime -s 2>/dev/null || cat /proc/uptime)"
    echo "Memory: $(free -h 2>/dev/null | grep Mem || echo 'N/A')"
    echo "Disk: $(df -h /data/openclaw/.openclaw 2>/dev/null | tail -1 || echo 'N/A')"
    echo "Health: $(curl -fsS http://localhost:18789/api/health 2>/dev/null && echo 'OK' || echo 'FAILED')"
    ;;
  deploy-status)
    gh run list --repo "${GITHUB_REPO:-Wrk-Flo/openclaw-prod}" --limit 3 \
      --json databaseId,status,conclusion,createdAt,headBranch \
      --jq '.[] | "\(.status) \(.conclusion // "running") — \(.createdAt) (run \(.databaseId))"'
    ;;
  help|*)
    echo "OpenClaw Self-Ops (run from inside container):"
    echo "  restart       - Quick restart (SIGTERM → Azure auto-restart, ~30s)"
    echo "  redeploy [tag]- Redeploy current image without rebuild (~3-5 min)"
    echo "  full-deploy   - Full build + deploy from main (~18 min)"
    echo "  health        - Check health endpoint"
    echo "  status        - System resource check"
    echo "  deploy-status - Show recent deploy runs"
    ;;
esac
