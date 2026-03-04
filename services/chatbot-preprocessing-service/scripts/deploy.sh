set -e

# --- Argument validation -----------------------------------------------------

ENV="${1:?Usage: $0 <environment>  e.g. $0 dev}"

# --- Fixed config (does not vary by environment) -----------------------------

RUNTIME="python3.11"
HANDLER="handler.lambda_handler"
TIMEOUT=120   # Preprocessing may take longer than indexing
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

if ! command -v pip3 &> /dev/null; then
    log_error "pip3 not found. Install Python first."
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

log_info "Fetching deploy config from Secrets Manager: $SECRET_ID..."
deploy_secret=$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_ID" \
    --query 'SecretString' \
    --output text) || {
    log_error "Failed to fetch secret: $SECRET_ID"
    log_error "Create it with: aws secretsmanager create-secret --name $SECRET_ID --secret-string '{...}'"
    exit 1
}

ROLE_NAME=$(echo "$deploy_secret"       | jq -r '.ROLE_NAME')
MODEL_ID=$(echo "$deploy_secret"        | jq -r '.MODEL_ID')
S3_RAW_BUCKET=$(echo "$deploy_secret"   | jq -r '.S3_RAW_BUCKET')
S3_DOCS_BUCKET=$(echo "$deploy_secret"  | jq -r '.S3_DOCS_BUCKET')
PROMPT_ARN=$(echo "$deploy_secret"      | jq -r '.PROMPT_ARN')
PROMPT_VERSION=$(echo "$deploy_secret"  | jq -r '.PROMPT_VERSION')

for var in ROLE_NAME MODEL_ID S3_RAW_BUCKET S3_DOCS_BUCKET PROMPT_ARN PROMPT_VERSION; do
    if [ -z "${!var}" ] || [ "${!var}" = "null" ]; then
        log_error "Missing key '$var' in secret $SECRET_ID"
        exit 1
    fi
done

# --- Grant Lambda role permissions -------------------------------------------

log_info "Granting Lambda role access to Bedrock..."
aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "BedrockAccess" \
    --policy-document '{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": ["bedrock:InvokeModel"],
                "Resource": "*"
            },
            {
                "Effect": "Allow",
                "Action": ["bedrock:GetPrompt"],
                "Resource": "*"
            }
        ]
    }' 2>/dev/null || log_warn "Could not update Bedrock IAM policy"

log_info "Granting Lambda role access to S3 buckets..."
aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "S3Access" \
    --policy-document "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [
            {
                \"Effect\": \"Allow\",
                \"Action\": \"s3:GetObject\",
                \"Resource\": \"arn:aws:s3:::${S3_RAW_BUCKET}/*\"
            },
            {
                \"Effect\": \"Allow\",
                \"Action\": \"s3:PutObject\",
                \"Resource\": \"arn:aws:s3:::${S3_DOCS_BUCKET}/*\"
            }
        ]
    }" 2>/dev/null || log_warn "Could not update S3 IAM policy"

# --- Package -----------------------------------------------------------------

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SERVICES_ROOT="$(dirname "$PROJECT_ROOT")"
SRC_DIR="$PROJECT_ROOT/src"
SHARED_DIR="$SERVICES_ROOT/shared"

log_info "Project root: $PROJECT_ROOT"

if [ ! -f "$SRC_DIR/handler.py" ]; then
    log_error "handler.py not found in $SRC_DIR"
    exit 1
fi

if [ ! -d "$SHARED_DIR" ]; then
    log_error "shared/ not found at $SHARED_DIR"
    exit 1
fi

# Ensure shared is removed from src even on failure
trap 'rm -rf "$SRC_DIR/shared"' EXIT

log_info "Including shared utilities..."
cp -r "$SHARED_DIR" "$SRC_DIR/shared"

# Install reportlab into src/modules for bundling
log_info "Installing dependencies (reportlab)..."
pip3 install reportlab pypdf \
    --target "$SRC_DIR/modules" \
    --platform manylinux2014_x86_64 \
    --implementation cp \
    --python-version 3.11 \
    --only-binary=:all: \
    --quiet 2>/dev/null || \
pip3 install reportlab pypdf --target "$SRC_DIR/modules" --quiet

log_info "Packaging Lambda function..."
cd "$SRC_DIR"
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

# --- Build Lambda environment JSON -------------------------------------------

ENV_JSON=$(jq -cn \
    --arg region "$REGION" \
    --arg model "$MODEL_ID" \
    --arg raw "$S3_RAW_BUCKET" \
    --arg docs "$S3_DOCS_BUCKET" \
    --arg promptArn "$PROMPT_ARN" \
    --arg promptVersion "$PROMPT_VERSION" \
    '{"Variables":{"AWS_REGION":$region,"MODEL_ID":$model,"S3_RAW_BUCKET":$raw,"S3_DOCS_BUCKET":$docs,"PROMPT_ARN":$promptArn,"PROMPT_VERSION":$promptVersion}}'
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

    aws lambda update-function-configuration \
        --function-name "$FUNCTION_NAME" \
        --timeout "$TIMEOUT" \
        --memory-size "$MEMORY" \
        --environment "$ENV_JSON" \
        --region "$REGION" \
        > /dev/null
    log_info "Function configuration updated"

else
    log_info "Creating new Lambda function..."

    aws lambda create-function \
        --function-name "$FUNCTION_NAME" \
        --runtime "$RUNTIME" \
        --role "$ROLE_ARN" \
        --handler "$HANDLER" \
        --zip-file fileb://function.zip \
        --timeout "$TIMEOUT" \
        --memory-size "$MEMORY" \
        --environment "$ENV_JSON" \
        --region "$REGION" \
        > /dev/null
    log_info "Lambda function created"

    log_info "Waiting for function to be active..."
    aws lambda wait function-active \
        --function-name "$FUNCTION_NAME" \
        --region "$REGION"
fi

# --- S3 trigger on raw bucket ------------------------------------------------

LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNCTION_NAME}"

log_info "Configuring S3 trigger on raw bucket: $S3_RAW_BUCKET..."

aws lambda add-permission \
    --function-name "$FUNCTION_NAME" \
    --statement-id S3RawInvokePermission \
    --action lambda:InvokeFunction \
    --principal s3.amazonaws.com \
    --source-arn "arn:aws:s3:::${S3_RAW_BUCKET}" \
    --source-account "$ACCOUNT_ID" \
    --region "$REGION" \
    > /dev/null 2>&1 || true

aws s3api put-bucket-notification-configuration \
    --bucket "$S3_RAW_BUCKET" \
    --notification-configuration "{
        \"LambdaFunctionConfigurations\": [
            {
                \"LambdaFunctionArn\": \"${LAMBDA_ARN}\",
                \"Events\": [\"s3:ObjectCreated:*\"]
            }
        ]
    }" \
    --region "$REGION"

log_info "S3 trigger configured"

# --- Cleanup -----------------------------------------------------------------

rm -f function.zip

echo ""
log_info "=================================================="
log_info "Deployment completed successfully! [$ENV]"
log_info "=================================================="
echo ""
echo -e "${GREEN}Function Name:${NC}  $FUNCTION_NAME"
echo -e "${GREEN}Raw Bucket:${NC}     $S3_RAW_BUCKET"
echo -e "${GREEN}Docs Bucket:${NC}    $S3_DOCS_BUCKET"
echo ""
log_info "Upload a raw file to trigger preprocessing:"
echo ""
echo "  aws s3 cp your-data.json s3://$S3_RAW_BUCKET/hr/ --region $REGION"
echo ""
log_info "Check preprocessing logs:"
echo ""
echo "  aws logs tail /aws/lambda/$FUNCTION_NAME --follow --region $REGION"
echo ""
