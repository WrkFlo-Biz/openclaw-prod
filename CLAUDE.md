# openclaw-prod

OpenClaw production instance. Being demoted to advisory-only downstream channel.

## Status
This project is in maintenance/demotion mode. OpenClaw is being reduced from a parallel operator runtime to a bounded downstream consumer of advisory artifacts from Global Sentinel.

## Key context
- All roles typed as paper_only in global-sentinel config/openclaw_role_registry.yaml
- Execution seeding (strategy_executor, crypto_executor) being removed from OpenClaw paths
- Telegram relay research moving to orchestrator task submission
- See global-sentinel/docs/openclaw-demotion.md for full migration plan

## Integration
- Consumes advisory artifacts from Global Sentinel (role briefs, recommendation queue)
- Being replaced by wrkflo-orchestrator for any control-plane interaction
