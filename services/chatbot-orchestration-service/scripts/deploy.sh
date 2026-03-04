set -e

# --- Argument validation -----------------------------------------------------

ENV="${1:?Usage: $0 <environment>  e.g. $0 dev}"

# --- Fixed config (does not vary by environment) -----------------------------

RUNTIME="nodejs20.x"
HANDLER="handler.handler"
TIMEOUT=60
MEMORY=512

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

log_info "Checking AWS credentials..."
if ! aws sts get-caller-identity &> /dev/null; then
    log_error "AWS credentials not configured. Run: aws configure  (or aws sso login)"
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
log_info "AWS Account: $ACCOUNT_ID | Environment: $ENV"

# --- Fetch env config from Secrets Manager (Pattern 4) ----------------------
# Parse each key individually — values are never exported to the parent shell.

log_info "Fetching deploy config from Secrets Manager: $SECRET_ID..."
deploy_secret=$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_ID" \
    --query 'SecretString' \
    --output text) || {
    log_error "Failed to fetch secret: $SECRET_ID"
    log_error "Create it with: aws secretsmanager create-secret --name $SECRET_ID --secret-string '{...}'"
    exit 1
}

ROLE_NAME=$(echo "$deploy_secret"         | jq -r '.ROLE_NAME')
MODEL_ID=$(echo "$deploy_secret"          | jq -r '.MODEL_ID')
POSTGRES_HOST=$(echo "$deploy_secret"     | jq -r '.POSTGRES_HOST')
POSTGRES_DB=$(echo "$deploy_secret"       | jq -r '.POSTGRES_DB')
DB_SECRET_ARN=$(echo "$deploy_secret"     | jq -r '.DB_SECRET_ARN')
GUARDRAIL_ID=$(echo "$deploy_secret"      | jq -r '.GUARDRAIL_ID')
GUARDRAIL_VERSION=$(echo "$deploy_secret" | jq -r '.GUARDRAIL_VERSION')
PROMPT_ARN=$(echo "$deploy_secret"        | jq -r '.PROMPT_ARN')
PROMPT_VERSION=$(echo "$deploy_secret"    | jq -r '.PROMPT_VERSION')
SUBNET_IDS=$(echo "$deploy_secret"        | jq -r '.SUBNET_IDS // empty')
SECURITY_GROUP_ID=$(echo "$deploy_secret" | jq -r '.SECURITY_GROUP_ID // empty')

for var in ROLE_NAME MODEL_ID POSTGRES_HOST POSTGRES_DB DB_SECRET_ARN GUARDRAIL_ID GUARDRAIL_VERSION PROMPT_ARN PROMPT_VERSION; do
    if [ -z "${!var}" ] || [ "${!var}" = "null" ]; then
        log_error "Missing key '$var' in secret $SECRET_ID"
        exit 1
    fi
done

# --- Grant Lambda role permissions -------------------------------------------

log_info "Granting Lambda role access to DB secret..."
aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "SecretsManagerDBAccess" \
    --policy-document "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [{
            \"Effect\": \"Allow\",
            \"Action\": \"secretsmanager:GetSecretValue\",
            \"Resource\": \"${DB_SECRET_ARN}\"
        }]
    }" 2>/dev/null || log_warn "Could not update IAM policy — ensure role has secretsmanager:GetSecretValue on the DB secret ARN"

log_info "Granting Lambda role access to Bedrock..."
aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "BedrockAccess" \
    --policy-document '{
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Action": [
                "bedrock:InvokeModelWithResponseStream",
                "bedrock:InvokeModel",
                "bedrock:ApplyGuardrail",
                "bedrock:Rerank",
                "bedrock:GetPrompt"
            ],
            "Resource": "*"
        }]
    }' 2>/dev/null || log_warn "Could not update Bedrock IAM policy"

log_info "Granting Lambda role access to DynamoDB sessions table..."
aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "DynamoDBSessionsAccess" \
    --policy-document "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [{
            \"Effect\": \"Allow\",
            \"Action\": [
                \"dynamodb:GetItem\",
                \"dynamodb:PutItem\"
            ],
            \"Resource\": \"arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/${TABLE_NAME}\"
        }]
    }" 2>/dev/null || log_warn "Could not update DynamoDB IAM policy"

# --- Package -----------------------------------------------------------------

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SRC_DIR="$PROJECT_ROOT/src"

log_info "Project root: $PROJECT_ROOT"

if [ ! -f "$SRC_DIR/handler.js" ]; then
    log_error "handler.js not found in $SRC_DIR"
    exit 1
fi

log_info "Installing Node.js dependencies..."
cd "$SRC_DIR"
npm install --omit=dev --quiet

log_info "Packaging Lambda function..."
rm -f function.zip
zip -qr function.zip .

if [ ! -f function.zip ]; then
    log_error "Failed to create function.zip"
    exit 1
fi
log_info "Package created: function.zip"

# --- IAM role check ----------------------------------------------------------

log_info "Checking IAM role: $ROLE_NAME..."
if ! aws iam get-role --role-name "$ROLE_NAME" &> /dev/null; then
    log_error "IAM role '$ROLE_NAME' not found. Create it first."
    exit 1
fi

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
log_info "Using role: $ROLE_ARN"

# --- DynamoDB sessions table -------------------------------------------------

log_info "Checking DynamoDB sessions table: $TABLE_NAME..."
if ! aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$REGION" &> /dev/null; then
    log_info "Creating DynamoDB table: $TABLE_NAME..."
    aws dynamodb create-table \
        --table-name "$TABLE_NAME" \
        --attribute-definitions AttributeName=sessionId,AttributeType=S \
        --key-schema AttributeName=sessionId,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --region "$REGION" \
        > /dev/null
    log_info "Waiting for table to become active..."
    aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$REGION"
    aws dynamodb update-time-to-live \
        --table-name "$TABLE_NAME" \
        --time-to-live-specification "Enabled=true,AttributeName=ttl" \
        --region "$REGION" \
        > /dev/null
    log_info "DynamoDB table created with TTL enabled"
else
    log_warn "DynamoDB table '$TABLE_NAME' already exists"
fi

# --- Build Lambda environment JSON -------------------------------------------
# DB credentials are NOT included here — the Lambda fetches them at runtime
# via DB_SECRET_ARN using the Secrets Manager SDK.

ENV_JSON=$(jq -cn \
    --arg model "$MODEL_ID" \
    --arg host "$POSTGRES_HOST" \
    --arg db "$POSTGRES_DB" \
    --arg arn "$DB_SECRET_ARN" \
    --arg gid "$GUARDRAIL_ID" \
    --arg gver "$GUARDRAIL_VERSION" \
    --arg parn "$PROMPT_ARN" \
    --arg pver "$PROMPT_VERSION" \
    --arg table "$TABLE_NAME" \
    '{"Variables":{"MODEL_ID":$model,"POSTGRES_HOST":$host,"POSTGRES_DB":$db,"DB_SECRET_ARN":$arn,"GUARDRAIL_ID":$gid,"GUARDRAIL_VERSION":$gver,"PROMPT_ARN":$parn,"PROMPT_VERSION":$pver,"SESSIONS_TABLE":$table}}'
)

# --- Deploy ------------------------------------------------------------------

log_info "Checking if Lambda function exists..."
if aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" &> /dev/null; then
    log_warn "Function '$FUNCTION_NAME' already exists. Updating..."

    aws lambda update-function-code \
        --function-name "$FUNCTION_NAME" \
        --zip-file fileb://function.zip \
        --region "$REGION" \
        > /dev/null
    log_info "Function code updated"

    log_info "Waiting for function update to complete..."
    aws lambda wait function-updated \
        --function-name "$FUNCTION_NAME" \
        --region "$REGION"

    UPDATE_ARGS=(
        --function-name "$FUNCTION_NAME"
        --timeout "$TIMEOUT"
        --memory-size "$MEMORY"
        --environment "$ENV_JSON"
        --region "$REGION"
    )

    if [ -n "$SUBNET_IDS" ] && [ -n "$SECURITY_GROUP_ID" ]; then
        UPDATE_ARGS+=(--vpc-config "SubnetIds=${SUBNET_IDS},SecurityGroupIds=${SECURITY_GROUP_ID}")
    fi

    aws lambda update-function-configuration "${UPDATE_ARGS[@]}" > /dev/null
    log_info "Function configuration updated"

else
    log_info "Creating new Lambda function..."

    CREATE_ARGS=(
        --function-name "$FUNCTION_NAME"
        --runtime "$RUNTIME"
        --role "$ROLE_ARN"
        --handler "$HANDLER"
        --zip-file fileb://function.zip
        --timeout "$TIMEOUT"
        --memory-size "$MEMORY"
        --environment "$ENV_JSON"
        --region "$REGION"
    )

    if [ -n "$SUBNET_IDS" ] && [ -n "$SECURITY_GROUP_ID" ]; then
        CREATE_ARGS+=(--vpc-config "SubnetIds=${SUBNET_IDS},SecurityGroupIds=${SECURITY_GROUP_ID}")
    fi

    aws lambda create-function "${CREATE_ARGS[@]}" > /dev/null
    log_info "Lambda function created"

    log_info "Waiting for function to be active..."
    aws lambda wait function-active \
        --function-name "$FUNCTION_NAME" \
        --region "$REGION"
fi

# --- Function URL (RESPONSE_STREAM required for streaming) -------------------

log_info "Checking Function URL configuration..."
if aws lambda get-function-url-config --function-name "$FUNCTION_NAME" --region "$REGION" &> /dev/null; then
    log_warn "Function URL already exists"
else
    log_info "Creating Function URL..."

    aws lambda create-function-url-config \
        --function-name "$FUNCTION_NAME" \
        --auth-type NONE \
        --invoke-mode RESPONSE_STREAM \
        --cors '{"AllowOrigins":["*"],"AllowMethods":["POST"],"AllowHeaders":["Content-Type","X-Session-Id"]}' \
        --region "$REGION" \
        > /dev/null

    aws lambda add-permission \
        --function-name "$FUNCTION_NAME" \
        --statement-id FunctionURLAllowPublicAccess \
        --action lambda:InvokeFunctionUrl \
        --principal "*" \
        --function-url-auth-type NONE \
        --region "$REGION" \
        > /dev/null 2>&1 || true

    aws lambda add-permission \
        --function-name "$FUNCTION_NAME" \
        --statement-id FunctionURLInvokeAllowPublicAccess \
        --action lambda:InvokeFunction \
        --principal "*" \
        --invoked-via-function-url \
        --region "$REGION" \
        > /dev/null 2>&1 || true

    log_info "Function URL created and configured"
fi

FUNCTION_URL=$(aws lambda get-function-url-config \
    --function-name "$FUNCTION_NAME" \
    --region "$REGION" \
    --query FunctionUrl \
    --output text)

# --- Cleanup -----------------------------------------------------------------

rm -f function.zip

echo ""
log_info "=================================================="
log_info "Deployment completed successfully! [$ENV]"
log_info "=================================================="
echo ""
echo -e "${GREEN}Function Name:${NC} $FUNCTION_NAME"
echo -e "${GREEN}Function URL:${NC}  $FUNCTION_URL"
echo ""
log_info "Add this to your frontend .env:"
echo "VITE_LAMBDA_STREAMING_URL=$FUNCTION_URL"
echo ""
