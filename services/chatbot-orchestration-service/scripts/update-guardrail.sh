set -e

# --- Argument validation -----------------------------------------------------

ENV="${1:?Usage: $0 <environment>  e.g. $0 dev}"

# --- Load per-environment configuration --------------------------------------

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CONFIG_FILE="${SCRIPT_DIR}/.env.${ENV}"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: ${CONFIG_FILE}"
    exit 1
fi
# shellcheck source=.env.dev
source "${CONFIG_FILE}"

# --- Colors / helpers --------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Preflight checks --------------------------------------------------------

if ! command -v aws &> /dev/null; then
    log_error "AWS CLI not found. Install it first: brew install awscli"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    log_error "jq not found. Install it first: brew install jq"
    exit 1
fi

if ! aws sts get-caller-identity &> /dev/null; then
    log_error "AWS credentials not configured. Run: aws configure  (or aws sso login)"
    exit 1
fi

log_info "AWS Account: $(aws sts get-caller-identity --query Account --output text) | Environment: $ENV"

# --- Load guardrail config ---------------------------------------------------

GUARDRAIL_FILE="$SCRIPT_DIR/../src/lib/guardrail.json"

if [ ! -f "$GUARDRAIL_FILE" ]; then
    log_error "Guardrail config not found: $GUARDRAIL_FILE"
    exit 1
fi

DESCRIPTION=$(jq -r '.description' "$GUARDRAIL_FILE")
BLOCKED_INPUT=$(jq -r '.blockedInputMessaging' "$GUARDRAIL_FILE")
BLOCKED_OUTPUT=$(jq -r '.blockedOutputsMessaging' "$GUARDRAIL_FILE")
CONTENT_POLICY=$(jq -c '.contentPolicy' "$GUARDRAIL_FILE")
SENSITIVE_POLICY=$(jq -c '.sensitiveInformationPolicy' "$GUARDRAIL_FILE")
TOPIC_POLICY=$(jq -c '.topicPolicy' "$GUARDRAIL_FILE")
WORD_POLICY=$(jq -c '.wordPolicy' "$GUARDRAIL_FILE")

# --- Create or update guardrail ----------------------------------------------

log_info "Checking for existing guardrail: $GUARDRAIL_NAME..."
EXISTING_ID=$(aws bedrock list-guardrails --region "$REGION" \
    --query "guardrails[?name=='$GUARDRAIL_NAME'].id | [0]" \
    --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_ID" ] && [ "$EXISTING_ID" != "None" ]; then
    log_info "Updating existing guardrail (ID: $EXISTING_ID)..."
    aws bedrock update-guardrail \
        --guardrail-identifier "$EXISTING_ID" \
        --name "$GUARDRAIL_NAME" \
        --description "$DESCRIPTION" \
        --blocked-input-messaging "$BLOCKED_INPUT" \
        --blocked-outputs-messaging "$BLOCKED_OUTPUT" \
        --content-policy-config "$CONTENT_POLICY" \
        --sensitive-information-policy-config "$SENSITIVE_POLICY" \
        --topic-policy-config "$TOPIC_POLICY" \
        --word-policy-config "$WORD_POLICY" \
        --region "$REGION" > /dev/null
    GUARDRAIL_ID="$EXISTING_ID"
else
    log_info "Creating new guardrail: $GUARDRAIL_NAME..."
    CREATE_RESPONSE=$(aws bedrock create-guardrail \
        --name "$GUARDRAIL_NAME" \
        --description "$DESCRIPTION" \
        --blocked-input-messaging "$BLOCKED_INPUT" \
        --blocked-outputs-messaging "$BLOCKED_OUTPUT" \
        --content-policy-config "$CONTENT_POLICY" \
        --sensitive-information-policy-config "$SENSITIVE_POLICY" \
        --topic-policy-config "$TOPIC_POLICY" \
        --word-policy-config "$WORD_POLICY" \
        --region "$REGION")
    GUARDRAIL_ID=$(echo "$CREATE_RESPONSE" | jq -r '.guardrailId')
    log_info "Guardrail created (ID: $GUARDRAIL_ID)"
fi

# --- Publish version ---------------------------------------------------------

log_info "Publishing guardrail version..."
VERSION_RESPONSE=$(aws bedrock create-guardrail-version \
    --guardrail-identifier "$GUARDRAIL_ID" \
    --region "$REGION")
GUARDRAIL_VERSION=$(echo "$VERSION_RESPONSE" | jq -r '.version')
log_info "Guardrail version $GUARDRAIL_VERSION published"

# --- Write back to Secrets Manager -------------------------------------------

log_info "Fetching current secret: $SECRET_ID..."
CURRENT_SECRET=$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_ID" \
    --query 'SecretString' \
    --output text) || {
    log_error "Failed to fetch secret: $SECRET_ID"
    exit 1
}

UPDATED_SECRET=$(echo "$CURRENT_SECRET" | jq \
    --arg id "$GUARDRAIL_ID" \
    --arg v "$GUARDRAIL_VERSION" \
    '.GUARDRAIL_ID=$id | .GUARDRAIL_VERSION=$v')

aws secretsmanager update-secret \
    --secret-id "$SECRET_ID" \
    --secret-string "$UPDATED_SECRET" \
    --region "$REGION" > /dev/null

log_info "Secret updated with GUARDRAIL_ID and GUARDRAIL_VERSION"

echo ""
log_info "=================================================="
log_info "Guardrail update complete! [$ENV]"
log_info "=================================================="
echo ""
echo -e "${GREEN}Guardrail Name:${NC}    $GUARDRAIL_NAME"
echo -e "${GREEN}Guardrail ID:${NC}      $GUARDRAIL_ID"
echo -e "${GREEN}Guardrail Version:${NC} $GUARDRAIL_VERSION"
echo ""
log_info "Run ./deploy.sh $ENV to deploy the Lambda with the new guardrail."
echo ""
