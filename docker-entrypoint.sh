#!/bin/bash
set -e

# OpenClaw Production Docker Entrypoint
# This script initializes the environment and loads agent skills

echo "========================================"
echo "OpenClaw Production Container Starting"
echo "========================================"
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Configuration
OPENCLAW_HOME="${OPENCLAW_HOME:-/data/openclaw}"
AGENTS_DIR="${OPENCLAW_HOME}/.openclaw/agents"
SKILLS_DIR="${AGENTS_DIR}/skills"
CONFIG_DIR="${AGENTS_DIR}/config"
LOGS_DIR="${OPENCLAW_HOME}/logs"
STATE_DIR="${OPENCLAW_HOME}/state"
SCRIPTS_DIR="${OPENCLAW_HOME}/scripts"

# Create necessary directories
echo "Creating directory structure..."
mkdir -p "$LOGS_DIR"
mkdir -p "$STATE_DIR"
mkdir -p "$SCRIPTS_DIR"
mkdir -p "${OPENCLAW_HOME}/processed"
mkdir -p "${OPENCLAW_HOME}/backups"

# Set proper permissions
chmod 755 "$OPENCLAW_HOME"
chmod 755 "$AGENTS_DIR"
chmod 755 "$SKILLS_DIR"
chmod 755 "$LOGS_DIR"
chmod 755 "$STATE_DIR"

# Initialize audit log
AUDIT_LOG="${LOGS_DIR}/audit.log"
if [ ! -f "$AUDIT_LOG" ]; then
    echo "Initializing audit log..."
    echo "{\"timestamp\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",\"action\":\"system_init\",\"message\":\"Audit log initialized\"}" > "$AUDIT_LOG"
fi

# Validate required environment variables
echo "Validating environment configuration..."
REQUIRED_VARS=(
    "TELEGRAM_BOT_TOKEN"
    "TELEGRAM_ADMIN_CHAT_ID"
)

MISSING_VARS=()
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        MISSING_VARS+=("$var")
    fi
done

if [ ${#MISSING_VARS[@]} -gt 0 ]; then
    echo "WARNING: Missing required environment variables:"
    for var in "${MISSING_VARS[@]}"; do
        echo "  - $var"
    done
    echo "Some features may not work correctly."
fi

# Load and validate safety rules
SAFETY_RULES="${CONFIG_DIR}/safety-rules.json"
if [ -f "$SAFETY_RULES" ]; then
    echo "Loading safety rules from $SAFETY_RULES"
    if command -v jq &> /dev/null; then
        if ! jq empty "$SAFETY_RULES" 2>/dev/null; then
            echo "ERROR: Invalid JSON in safety-rules.json"
            exit 1
        fi
        echo "Safety rules validated successfully"

        # Extract and display key safety settings
        echo "Safety Configuration:"
        echo "  - Rate limit: $(jq -r '.rate_limits.max_actions_per_minute' "$SAFETY_RULES") actions/minute"
        echo "  - Audit logging: $(jq -r '.audit.enabled' "$SAFETY_RULES")"
        echo "  - Emergency stop commands: $(jq -r '.emergency_stop.commands | join(", ")' "$SAFETY_RULES")"
    else
        echo "Warning: jq not installed, skipping JSON validation"
    fi
else
    echo "WARNING: Safety rules file not found at $SAFETY_RULES"
fi

# Load agent skills
echo ""
echo "Loading agent skills..."
SKILLS_LOADED=0
SKILLS_FAILED=0

load_skill() {
    local skill_file=$1
    local skill_name=$(basename "$skill_file" .lobster)

    if [ -f "$skill_file" ]; then
        echo "  Loading skill: $skill_name"

        # Validate skill file syntax (basic check)
        if grep -q "^name:" "$skill_file" && grep -q "^workflow:" "$skill_file"; then
            echo "    ✓ Skill '$skill_name' loaded successfully"
            ((SKILLS_LOADED++))
            return 0
        else
            echo "    ✗ Skill '$skill_name' has invalid format"
            ((SKILLS_FAILED++))
            return 1
        fi
    else
        echo "    ✗ Skill file not found: $skill_file"
        ((SKILLS_FAILED++))
        return 1
    fi
}

# Load master orchestrator
MASTER_ORCHESTRATOR="${AGENTS_DIR}/master-orchestrator.lobster"
if [ -f "$MASTER_ORCHESTRATOR" ]; then
    echo "Loading master orchestrator..."
    load_skill "$MASTER_ORCHESTRATOR"
else
    echo "ERROR: Master orchestrator not found at $MASTER_ORCHESTRATOR"
    exit 1
fi

# Load individual skills
for skill_file in "$SKILLS_DIR"/*.lobster; do
    if [ -f "$skill_file" ]; then
        load_skill "$skill_file"
    fi
done

echo ""
echo "Skills Summary:"
echo "  - Loaded: $SKILLS_LOADED"
echo "  - Failed: $SKILLS_FAILED"

if [ $SKILLS_FAILED -gt 0 ]; then
    echo "WARNING: Some skills failed to load"
fi

# Initialize state file
STATE_FILE="${STATE_DIR}/orchestrator.json"
if [ ! -f "$STATE_FILE" ]; then
    echo "Initializing orchestrator state..."
    cat > "$STATE_FILE" << 'EOF'
{
    "initialized_at": null,
    "last_heartbeat": null,
    "skills_status": {},
    "pending_approvals": [],
    "rate_limits": {
        "minute_counts": {},
        "hour_counts": {}
    },
    "emergency_stop_active": false
}
EOF
    # Update initialized_at timestamp
    if command -v jq &> /dev/null; then
        TMP_FILE=$(mktemp)
        jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '.initialized_at = $ts' "$STATE_FILE" > "$TMP_FILE"
        mv "$TMP_FILE" "$STATE_FILE"
    fi
fi

# Create helper scripts
echo "Creating helper scripts..."

# Health check script
cat > "${SCRIPTS_DIR}/health-check.sh" << 'HEALTHCHECK'
#!/bin/bash
# Health check script for OpenClaw services

check_service() {
    local service=$1
    local url=$2

    if curl -sf "$url" > /dev/null 2>&1; then
        echo "✓ $service: healthy"
        return 0
    else
        echo "✗ $service: unhealthy"
        return 1
    fi
}

echo "Running health checks..."
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo ""

# Add your health check endpoints here
# check_service "API" "http://localhost:8080/health"
# check_service "Database" "http://localhost:5432/health"

echo ""
echo "Health check complete"
HEALTHCHECK
chmod +x "${SCRIPTS_DIR}/health-check.sh"

# Log cleanup script
cat > "${SCRIPTS_DIR}/cleanup-logs.sh" << 'CLEANUP'
#!/bin/bash
# Log cleanup script - removes logs older than retention period

LOGS_DIR="${OPENCLAW_HOME:-/data/openclaw}/logs"
RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"

echo "Cleaning up logs older than $RETENTION_DAYS days..."
echo "Logs directory: $LOGS_DIR"

find "$LOGS_DIR" -type f -name "*.log" -mtime +"$RETENTION_DAYS" -exec rm -v {} \;
find "$LOGS_DIR" -type f -name "*.log.*" -mtime +"$RETENTION_DAYS" -exec rm -v {} \;

echo "Log cleanup complete"
CLEANUP
chmod +x "${SCRIPTS_DIR}/cleanup-logs.sh"

# Config sync script
cat > "${SCRIPTS_DIR}/sync-config.sh" << 'SYNCCONFIG'
#!/bin/bash
# Sync configuration from environment variables

CONFIG_DIR="${OPENCLAW_HOME:-/data/openclaw}/.openclaw/agents/config"

echo "Syncing configuration..."

# This script can be extended to sync config from external sources
echo "Configuration sync complete"
SYNCCONFIG
chmod +x "${SCRIPTS_DIR}/sync-config.sh"

# Log startup event
echo ""
echo "Logging startup event..."
STARTUP_LOG="{\"timestamp\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",\"action\":\"container_start\",\"skills_loaded\":$SKILLS_LOADED,\"skills_failed\":$SKILLS_FAILED}"
echo "$STARTUP_LOG" >> "$AUDIT_LOG"

# Display startup summary
echo ""
echo "========================================"
echo "OpenClaw Startup Complete"
echo "========================================"
echo "  Home: $OPENCLAW_HOME"
echo "  Agents: $AGENTS_DIR"
echo "  Logs: $LOGS_DIR"
echo "  State: $STATE_DIR"
echo "  Skills loaded: $SKILLS_LOADED"
echo ""

# Execute the main command (passed as arguments)
if [ $# -gt 0 ]; then
    echo "Executing command: $@"
    exec "$@"
else
    # Default: keep container running and tail logs
    echo "No command specified. Starting log tail..."
    echo "Send Telegram commands to interact with the bot."
    echo ""

    # Keep container alive and tail audit log
    tail -f "$AUDIT_LOG" 2>/dev/null || sleep infinity
fi
