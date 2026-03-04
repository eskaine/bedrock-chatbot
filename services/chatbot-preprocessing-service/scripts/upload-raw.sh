set -e

ENV="${1:?Usage: $0 <environment>  e.g. $0 dev}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load per-environment configuration
CONFIG_FILE="${SCRIPT_DIR}/.env.${ENV}"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: ${CONFIG_FILE}"
    exit 1
fi
# shellcheck source=.env.dev
source "${CONFIG_FILE}"

LOCAL_RAW_DIR="$SCRIPT_DIR/../raw"
REDACTED_DIR="$SCRIPT_DIR/../docs"

# --- Colors / helpers --------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "${BLUE}[SUCCESS]${NC} $1"; }

# --- Preflight checks --------------------------------------------------------

if ! command -v aws &> /dev/null; then
    log_error "AWS CLI not found. Install it first: brew install awscli"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    log_error "jq not found. Install it first: brew install jq"
    exit 1
fi

if ! command -v python3 &> /dev/null; then
    log_error "python3 not found. Install Python 3 first."
    exit 1
fi

log_info "Checking AWS credentials..."
if ! aws sts get-caller-identity &> /dev/null; then
    log_error "AWS credentials not configured. Run: aws configure  (or aws sso login)"
    exit 1
fi

# --- Check local raw directory -----------------------------------------------

if [ ! -d "$LOCAL_RAW_DIR" ]; then
    log_error "Raw directory not found: $LOCAL_RAW_DIR"
    log_info "Create it and add files under category subfolders:"
    log_info "  mkdir -p $LOCAL_RAW_DIR/hr"
    log_info "  echo 'your content' > $LOCAL_RAW_DIR/hr/staff_faq.txt"
    exit 1
fi

TOTAL_FILES=$(find "$LOCAL_RAW_DIR" -type f \( -name "*.txt" -o -name "*.json" -o -name "*.md" -o -name "*.pdf" \) | wc -l | tr -d ' ')

if [ "$TOTAL_FILES" -eq 0 ]; then
    log_warn "No supported files found in $LOCAL_RAW_DIR"
    log_info "Add .txt, .json, .md, or .pdf files to upload"
    exit 0
fi

log_info "Found $TOTAL_FILES file(s) in $LOCAL_RAW_DIR"
echo ""

# --- Redact sensitive data ---------------------------------------------------

log_info "Running sensitive data redaction..."
echo ""

rm -rf "$REDACTED_DIR"

if ! python3 "$SCRIPT_DIR/redact.py" "$LOCAL_RAW_DIR" "$REDACTED_DIR"; then
    log_error "Redaction failed — aborting upload"
    exit 1
fi

echo ""
log_success "Redaction complete → $REDACTED_DIR"
echo ""

# --- Fetch raw bucket name from Secrets Manager ------------------------------

log_info "Fetching config from Secrets Manager: $SECRET_ID..."
deploy_secret=$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_ID" \
    --query 'SecretString' \
    --output text) || {
    log_error "Failed to fetch secret: $SECRET_ID"
    exit 1
}

S3_RAW_BUCKET=$(echo "$deploy_secret" | jq -r '.S3_RAW_BUCKET')

if [ -z "$S3_RAW_BUCKET" ] || [ "$S3_RAW_BUCKET" = "null" ]; then
    log_error "Missing S3_RAW_BUCKET in secret $SECRET_ID"
    exit 1
fi

log_info "Environment: $ENV | Raw bucket: $S3_RAW_BUCKET"

if ! aws s3 ls "s3://$S3_RAW_BUCKET" --region "$REGION" &> /dev/null; then
    log_error "Raw bucket '$S3_RAW_BUCKET' not found or not accessible"
    exit 1
fi

# --- Upload redacted files preserving folder structure -----------------------

UPLOADED=0
SKIPPED=0
FAILED=0

while IFS= read -r file; do
    RELATIVE_PATH="${file#$REDACTED_DIR/}"
    S3_KEY="$RELATIVE_PATH"

    if aws s3 ls "s3://$S3_RAW_BUCKET/$S3_KEY" --region "$REGION" &> /dev/null; then
        log_warn "Skipping (already exists): $S3_KEY"
        ((SKIPPED++))
        continue
    fi

    log_info "Uploading: $S3_KEY"

    if aws s3 cp "$file" "s3://$S3_RAW_BUCKET/$S3_KEY" --region "$REGION" > /dev/null 2>&1; then
        log_success "Uploaded: $S3_KEY"
        ((UPLOADED++))
    else
        log_error "Failed to upload: $S3_KEY"
        ((FAILED++))
    fi

done < <(find "$REDACTED_DIR" -type f \( -name "*.txt" -o -name "*.json" -o -name "*.md" -o -name "*.pdf" \))

# --- Summary -----------------------------------------------------------------

echo ""
echo "========================================="
echo "UPLOAD SUMMARY"
echo "========================================="
echo -e "${GREEN}Uploaded:${NC} $UPLOADED"
echo -e "${YELLOW}Skipped:${NC}  $SKIPPED"
if [ "$FAILED" -gt 0 ]; then
    echo -e "${RED}Failed:${NC}   $FAILED"
fi
echo "========================================="
echo ""

if [ "$UPLOADED" -gt 0 ]; then
    log_success "Files uploaded — preprocessing Lambda will process them automatically"
    echo ""
    log_info "Check preprocessing logs:"
    echo "  aws logs tail /aws/lambda/chatbot-preprocessing --follow --region $REGION"
    echo ""
    log_info "Check indexing logs (triggered after preprocessing):"
    echo "  aws logs tail /aws/lambda/chatbot-indexing --follow --region $REGION"
    echo ""
fi

exit 0
