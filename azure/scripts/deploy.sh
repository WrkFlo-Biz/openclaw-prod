#!/bin/bash
# OpenClaw Azure Deployment Script
# Deploys all infrastructure and applications to Azure

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AZURE_DIR="$PROJECT_ROOT/azure"

# Default values
ENVIRONMENT="${ENVIRONMENT:-prod}"
LOCATION="${LOCATION:-eastus}"
RESOURCE_GROUP="${RESOURCE_GROUP:-openclaw-${ENVIRONMENT}-rg}"

# Log functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check Azure CLI
    if ! command -v az &> /dev/null; then
        log_error "Azure CLI is not installed. Please install it first."
        exit 1
    fi

    # Check if logged in
    if ! az account show &> /dev/null; then
        log_error "Not logged in to Azure. Run 'az login' first."
        exit 1
    fi

    # Check for required environment variables
    local required_vars=(
        "TELEGRAM_BOT_TOKEN"
        "TELEGRAM_ADMIN_CHAT_ID"
    )

    local missing_vars=()
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            missing_vars+=("$var")
        fi
    done

    if [ ${#missing_vars[@]} -gt 0 ]; then
        log_error "Missing required environment variables:"
        for var in "${missing_vars[@]}"; do
            echo "  - $var"
        done
        log_info "Set these in your environment or create a .env file"
        exit 1
    fi

    log_success "Prerequisites check passed"
}

# Load environment variables from .env if exists
load_env() {
    local env_file="$PROJECT_ROOT/.env"
    if [ -f "$env_file" ]; then
        log_info "Loading environment from .env file..."
        export $(grep -v '^#' "$env_file" | xargs)
    fi
}

# Create resource group
create_resource_group() {
    log_info "Creating resource group: $RESOURCE_GROUP in $LOCATION..."

    if az group show --name "$RESOURCE_GROUP" &> /dev/null; then
        log_warning "Resource group already exists"
    else
        az group create \
            --name "$RESOURCE_GROUP" \
            --location "$LOCATION" \
            --tags Environment="$ENVIRONMENT" Application="OpenClaw"

        log_success "Resource group created"
    fi
}

# Deploy Bicep infrastructure
deploy_infrastructure() {
    log_info "Deploying Azure infrastructure with Bicep..."

    local bicep_file="$AZURE_DIR/bicep/main.bicep"

    if [ ! -f "$bicep_file" ]; then
        log_error "Bicep file not found: $bicep_file"
        exit 1
    fi

    # Deploy with parameters
    az deployment group create \
        --resource-group "$RESOURCE_GROUP" \
        --template-file "$bicep_file" \
        --parameters \
            environment="$ENVIRONMENT" \
            location="$LOCATION" \
            telegramBotToken="$TELEGRAM_BOT_TOKEN" \
            telegramAdminChatId="$TELEGRAM_ADMIN_CHAT_ID" \
            githubToken="${GITHUB_TOKEN:-}" \
            githubRepo="${GITHUB_REPO:-}" \
        --name "openclaw-deployment-$(date +%Y%m%d%H%M%S)" \
        --output table

    log_success "Infrastructure deployed"

    # Get outputs
    log_info "Retrieving deployment outputs..."
    OUTPUTS=$(az deployment group show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$(az deployment group list --resource-group $RESOURCE_GROUP --query '[0].name' -o tsv)" \
        --query properties.outputs)

    echo "$OUTPUTS" | jq '.'
}

# Deploy Azure Functions
deploy_functions() {
    log_info "Deploying Azure Functions..."

    local func_app_name=$(az deployment group show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$(az deployment group list --resource-group $RESOURCE_GROUP --query '[0].name' -o tsv)" \
        --query properties.outputs.functionAppName.value -o tsv)

    if [ -z "$func_app_name" ]; then
        log_warning "Function app name not found, skipping function deployment"
        return
    fi

    local functions_dir="$AZURE_DIR/functions"

    if [ -d "$functions_dir" ]; then
        cd "$functions_dir"

        # Create requirements.txt if not exists
        if [ ! -f "requirements.txt" ]; then
            cat > requirements.txt << 'EOF'
azure-functions>=1.17.0
aiohttp>=3.9.0
EOF
        fi

        # Create function.json files
        mkdir -p data_processor
        cat > data_processor/function.json << 'EOF'
{
    "scriptFile": "__init__.py",
    "bindings": [
        {
            "name": "timer",
            "type": "timerTrigger",
            "direction": "in",
            "schedule": "0 */15 * * * *"
        }
    ]
}
EOF

        # Package and deploy
        log_info "Packaging functions..."
        func azure functionapp publish "$func_app_name" --python

        cd "$PROJECT_ROOT"
        log_success "Functions deployed"
    else
        log_warning "Functions directory not found, skipping"
    fi
}

# Deploy Logic Apps workflows
deploy_logic_apps() {
    log_info "Deploying Logic Apps workflows..."

    local logic_app_name=$(az deployment group show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$(az deployment group list --resource-group $RESOURCE_GROUP --query '[0].name' -o tsv)" \
        --query properties.outputs.logicAppName.value -o tsv)

    if [ -z "$logic_app_name" ]; then
        log_warning "Logic app name not found, skipping workflow deployment"
        return
    fi

    local workflows_dir="$AZURE_DIR/logic-apps"

    if [ -d "$workflows_dir" ]; then
        for workflow_dir in "$workflows_dir"/*/; do
            local workflow_name=$(basename "$workflow_dir")
            local workflow_file="$workflow_dir/workflow.json"

            if [ -f "$workflow_file" ]; then
                log_info "Deploying workflow: $workflow_name"

                # Deploy workflow using Azure CLI
                # Note: In production, use ZIP deployment or Azure DevOps
                az logicapp deployment source config-zip \
                    --resource-group "$RESOURCE_GROUP" \
                    --name "$logic_app_name" \
                    --src "$workflow_file" 2>/dev/null || \
                log_warning "Workflow deployment via CLI not supported, use ZIP deployment"
            fi
        done

        log_success "Logic Apps workflows configured"
    else
        log_warning "Logic apps directory not found, skipping"
    fi
}

# Deploy Automation Runbooks
deploy_runbooks() {
    log_info "Deploying Azure Automation runbooks..."

    local automation_account=$(az deployment group show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$(az deployment group list --resource-group $RESOURCE_GROUP --query '[0].name' -o tsv)" \
        --query properties.outputs.automationAccountName.value -o tsv)

    if [ -z "$automation_account" ]; then
        log_warning "Automation account name not found, skipping runbook deployment"
        return
    fi

    local runbooks_dir="$AZURE_DIR/automation"

    if [ -d "$runbooks_dir" ]; then
        for runbook_file in "$runbooks_dir"/*.ps1; do
            if [ -f "$runbook_file" ]; then
                local runbook_name=$(basename "$runbook_file" .ps1)
                log_info "Deploying runbook: $runbook_name"

                # Import runbook
                az automation runbook create \
                    --resource-group "$RESOURCE_GROUP" \
                    --automation-account-name "$automation_account" \
                    --name "$runbook_name" \
                    --type PowerShell \
                    --location "$LOCATION" 2>/dev/null || true

                # Update content
                az automation runbook replace-content \
                    --resource-group "$RESOURCE_GROUP" \
                    --automation-account-name "$automation_account" \
                    --name "$runbook_name" \
                    --content @"$runbook_file"

                # Publish
                az automation runbook publish \
                    --resource-group "$RESOURCE_GROUP" \
                    --automation-account-name "$automation_account" \
                    --name "$runbook_name"

                log_info "Runbook $runbook_name published"
            fi
        done

        log_success "Automation runbooks deployed"
    else
        log_warning "Automation directory not found, skipping"
    fi
}

# Print deployment summary
print_summary() {
    log_info "=========================================="
    log_success "OpenClaw Azure Deployment Complete!"
    log_info "=========================================="
    echo ""
    log_info "Resource Group: $RESOURCE_GROUP"
    log_info "Location: $LOCATION"
    log_info "Environment: $ENVIRONMENT"
    echo ""
    log_info "Next steps:"
    echo "  1. Configure Telegram webhook in Logic Apps"
    echo "  2. Test bot commands via Telegram"
    echo "  3. Monitor via Application Insights"
    echo "  4. Review audit logs in Storage Account"
    echo ""
    log_info "View resources in Azure Portal:"
    echo "  https://portal.azure.com/#@/resource/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP/overview"
}

# Cleanup function
cleanup() {
    log_warning "Deployment interrupted. Resources may be partially deployed."
    log_info "To clean up, run: az group delete --name $RESOURCE_GROUP"
}

# Main execution
main() {
    echo ""
    echo "=========================================="
    echo "OpenClaw Azure Deployment"
    echo "=========================================="
    echo ""

    trap cleanup INT TERM

    load_env
    check_prerequisites
    create_resource_group
    deploy_infrastructure
    deploy_functions
    deploy_logic_apps
    deploy_runbooks
    print_summary
}

# Run main
main "$@"
