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

# --- Load prompt text --------------------------------------------------------

PROMPT_FILE="$SCRIPT_DIR/../src/lib/prompt.txt"

if [ ! -f "$PROMPT_FILE" ]; then
    log_error "Prompt file not found: $PROMPT_FILE"
    exit 1
fi

PROMPT_TEXT=$(cat "$PROMPT_FILE")

if [ -z "$PROMPT_TEXT" ]; then
    log_error "Prompt file is empty: $PROMPT_FILE"
    exit 1
fi

log_info "Prompt loaded: $(echo -n "$PROMPT_TEXT" | wc -c | tr -d ' ') characters"

# --- Build variants JSON -----------------------------------------------------
# Use jq to safely escape the prompt text into valid JSON

VARIANTS=$(jq -cn --arg text "$PROMPT_TEXT" '[
    {
        "name": "default",
        "templateType": "TEXT",
        "templateConfiguration": {
            "text": {
                "text": $text
            }
        }
    }
]')

# --- Create or update prompt -------------------------------------------------

log_info "Checking for existing prompt: $PROMPT_NAME..."
EXISTING_ID=$(aws bedrock-agent list-prompts \
    --region "$REGION" \
    --query "promptSummaries[?name=='$PROMPT_NAME'].id | [0]" \
    --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_ID" ] && [ "$EXISTING_ID" != "None" ]; then
    log_info "Updating existing prompt (ID: $EXISTING_ID)..."
    aws bedrock-agent update-prompt \
        --prompt-identifier "$EXISTING_ID" \
        --name "$PROMPT_NAME" \
        --variants "$VARIANTS" \
        --region "$REGION" > /dev/null
    PROMPT_ID="$EXISTING_ID"
else
    log_info "Creating new prompt: $PROMPT_NAME..."
    CREATE_RESPONSE=$(aws bedrock-agent create-prompt \
        --name "$PROMPT_NAME" \
        --variants "$VARIANTS" \
        --region "$REGION")
    PROMPT_ID=$(echo "$CREATE_RESPONSE" | jq -r '.id')
    log_info "Prompt created (ID: $PROMPT_ID)"
fi

# --- Publish version ---------------------------------------------------------

log_info "Publishing prompt version..."
VERSION_RESPONSE=$(aws bedrock-agent create-prompt-version \
    --prompt-identifier "$PROMPT_ID" \
    --region "$REGION")

VERSION_ARN=$(echo "$VERSION_RESPONSE" | jq -r '.arn')
PROMPT_VERSION=$(echo "$VERSION_RESPONSE" | jq -r '.version')

# Derive base prompt ARN by stripping the trailing :VERSION segment
# Version ARN format: arn:aws:bedrock:REGION:ACCOUNT:prompt/ID:VERSION
PROMPT_ARN="${VERSION_ARN%:*}"

log_info "Prompt version $PROMPT_VERSION published"
log_info "Prompt ARN: $PROMPT_ARN"

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
    --arg arn "$PROMPT_ARN" \
    --arg v "$PROMPT_VERSION" \
    '.PROMPT_ARN=$arn | .PROMPT_VERSION=$v')

aws secretsmanager update-secret \
    --secret-id "$SECRET_ID" \
    --secret-string "$UPDATED_SECRET" \
    --region "$REGION" > /dev/null

log_info "Secret updated with PROMPT_ARN and PROMPT_VERSION"

echo ""
log_info "=================================================="
log_info "Prompt update complete! [$ENV]"
log_info "=================================================="
echo ""
echo -e "${GREEN}Prompt Name:${NC}    $PROMPT_NAME"
echo -e "${GREEN}Prompt ARN:${NC}     $PROMPT_ARN"
echo -e "${GREEN}Prompt Version:${NC} $PROMPT_VERSION"
echo ""
log_info "Run ./deploy.sh $ENV to deploy the Lambda with the new prompt."
echo ""
