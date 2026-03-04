#!/bin/bash

##############################################################################
# Frontend Deployment Script
# Builds and deploys ai-chatbot to S3 + CloudFront
#
# Usage: ./deploy.sh <environment>
# Example: ./deploy.sh dev
##############################################################################

set -e

# Validate environment argument
ENV="${1}"

if [[ -z "$ENV" || ! "$ENV" =~ ^(dev|stg|prod)$ ]]; then
    echo "Usage: ./deploy.sh <environment>"
    echo "  environment: dev | stg | prod"
    exit 1
fi

# Get project directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load per-environment configuration
CONFIG_FILE="${PROJECT_ROOT}/.env.${ENV}"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: ${CONFIG_FILE}"
    exit 1
fi
# shellcheck source=../.env.dev
source "${CONFIG_FILE}"

S3_BUCKET="${S3_BUCKET_PREFIX}-${ENV}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
if ! command -v aws &> /dev/null; then
    log_error "AWS CLI not found. Install it first: brew install awscli"
    exit 1
fi

if ! command -v node &> /dev/null; then
    log_error "Node.js not found. Install it first."
    exit 1
fi

# Check AWS credentials
log_info "Checking AWS credentials..."
if ! aws sts get-caller-identity &> /dev/null; then
    log_error "AWS credentials not configured. Run: aws configure"
    exit 1
fi

log_info "Environment: $ENV"
log_info "S3 Bucket: $S3_BUCKET"
log_info "Project root: $PROJECT_ROOT"

# Install dependencies
log_info "Installing dependencies..."
cd "$PROJECT_ROOT"
npm install

# Build for the target environment
log_info "Building for ${ENV}..."
npm run "build:${ENV}"

# Check if build output exists
if [ ! -d "$PROJECT_ROOT/dist" ]; then
    log_error "Build failed - dist directory not found"
    exit 1
fi

# Check if S3 bucket exists, create if not
log_info "Checking S3 bucket: $S3_BUCKET..."
if ! aws s3api head-bucket --bucket "$S3_BUCKET" --region "$REGION" 2>/dev/null; then
    log_info "Creating S3 bucket: $S3_BUCKET..."
    aws s3api create-bucket \
        --bucket "$S3_BUCKET" \
        --region "$REGION" \
        --create-bucket-configuration LocationConstraint="$REGION"

    # Block all public access (CloudFront will use OAC)
    aws s3api put-public-access-block \
        --bucket "$S3_BUCKET" \
        --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

    log_info "S3 bucket created"
fi

# Sync build output to S3
log_info "Uploading to S3..."
aws s3 sync "$PROJECT_ROOT/dist" "s3://${S3_BUCKET}" \
    --region "$REGION" \
    --delete

log_info "Upload complete"

# Invalidate CloudFront cache
if [ -n "$DISTRIBUTION_ID" ]; then
    log_info "Invalidating CloudFront cache..."
    INVALIDATION_ID=$(aws cloudfront create-invalidation \
        --distribution-id "$DISTRIBUTION_ID" \
        --paths "/*" \
        --query 'Invalidation.Id' \
        --output text)

    log_info "Invalidation created: $INVALIDATION_ID"
else
    log_warn "No CloudFront distribution ID set for ${ENV}. Skipping cache invalidation."
    log_warn "Set DISTRIBUTION_ID_${ENV^^} in this script after creating the distribution."
fi

echo ""
log_info "=================================================="
log_info "Deployment completed successfully!"
log_info "=================================================="
echo ""
echo -e "${GREEN}Environment:${NC} $ENV"
echo -e "${GREEN}S3 Bucket:${NC}   $S3_BUCKET"
if [ -n "$DISTRIBUTION_ID" ]; then
    DOMAIN=$(aws cloudfront get-distribution \
        --id "$DISTRIBUTION_ID" \
        --query 'Distribution.DomainName' \
        --output text 2>/dev/null || echo "unknown")
    echo -e "${GREEN}CloudFront:${NC}  https://$DOMAIN"
fi
echo ""
