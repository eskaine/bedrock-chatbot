set -e  # Exit on any error

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

LOCAL_DOCS_DIR="$SCRIPT_DIR/../docs"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${BLUE}[SUCCESS]${NC} $1"
}

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    log_error "AWS CLI not found. Install it first: brew install awscli"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    log_error "jq not found. Install it first: brew install jq"
    exit 1
fi

# Check AWS credentials
log_info "Checking AWS credentials..."
if ! aws sts get-caller-identity &> /dev/null; then
    log_error "AWS credentials not configured. Run: aws configure"
    exit 1
fi

# Fetch bucket name from Secrets Manager
log_info "Fetching config from Secrets Manager: $SECRET_ID..."
deploy_secret=$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_ID" \
    --query 'SecretString' \
    --output text) || {
    log_error "Failed to fetch secret: $SECRET_ID"
    exit 1
}

S3_BUCKET=$(echo "$deploy_secret" | jq -r '.S3_BUCKET')

if [ -z "$S3_BUCKET" ] || [ "$S3_BUCKET" = "null" ]; then
    log_error "Missing S3_BUCKET in secret $SECRET_ID"
    exit 1
fi

# Check if S3 bucket exists
log_info "Checking S3 bucket: $S3_BUCKET..."
if ! aws s3 ls "s3://$S3_BUCKET" --region "$REGION" &> /dev/null; then
    log_error "S3 bucket '$S3_BUCKET' not found or not accessible"
    log_error "Create it first: aws s3 mb s3://$S3_BUCKET --region $REGION"
    exit 1
fi

log_success "S3 bucket exists and is accessible"

# Check if local documents directory exists
if [ ! -d "$LOCAL_DOCS_DIR" ]; then
    log_error "Documents directory not found: $LOCAL_DOCS_DIR"
    log_info "Create it and add documents: mkdir -p $LOCAL_DOCS_DIR"
    exit 1
fi

# Count documents
TOTAL_FILES=$(find "$LOCAL_DOCS_DIR" -type f \( -name "*.pdf" -o -name "*.txt" -o -name "*.docx" \) | wc -l | tr -d ' ')

if [ "$TOTAL_FILES" -eq 0 ]; then
    log_warn "No documents found in $LOCAL_DOCS_DIR"
    log_info "Add .pdf, .txt, or .docx files to upload"
    exit 0
fi

log_info "Found $TOTAL_FILES document(s) to upload"
echo ""

# Upload files
UPLOADED=0
FAILED=0

while IFS= read -r file; do
    # Preserve folder structure relative to LOCAL_DOCS_DIR
    # e.g. docs/hr/leave_policy.pdf → hr/leave_policy.pdf
    RELATIVE_PATH="${file#$LOCAL_DOCS_DIR/}"
    S3_KEY="$RELATIVE_PATH"

    # Upload file preserving folder path (always overwrite to support re-indexing)
    log_info "Uploading: $S3_KEY"

    if aws s3 cp "$file" "s3://$S3_BUCKET/$S3_KEY" --region "$REGION" > /dev/null 2>&1; then
        log_success "Uploaded: $S3_KEY"
        ((UPLOADED++))
    else
        log_error "Failed to upload: $S3_KEY"
        ((FAILED++))
    fi

done < <(find "$LOCAL_DOCS_DIR" -type f \( -name "*.pdf" -o -name "*.txt" -o -name "*.docx" \))

# Summary
echo ""
echo "========================================="
echo "UPLOAD SUMMARY"
echo "========================================="
echo -e "${GREEN}Uploaded:${NC} $UPLOADED"
if [ "$FAILED" -gt 0 ]; then
    echo -e "${RED}Failed:${NC}   $FAILED"
fi
echo "========================================="
echo ""

if [ "$UPLOADED" -gt 0 ]; then
    log_success "Documents uploaded successfully!"
    log_info "Indexing Lambda will process them automatically"
    log_info ""
    log_info "Check indexing progress:"
    echo "  aws logs tail /aws/lambda/chatbot-indexing --follow --region $REGION"
    echo ""
    log_info "List uploaded files:"
    echo "  aws s3 ls s3://$S3_BUCKET/ --region $REGION"
fi

exit 0