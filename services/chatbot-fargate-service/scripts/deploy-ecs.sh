#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# Step 1: Variables
# ─────────────────────────────────────────────
ENV="${1:?Usage: $0 <environment>  e.g. $0 dev}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load per-environment configuration
# shellcheck source=.env.dev
source "${SCRIPT_DIR}/.env.${ENV}"

REGION="${AWS_REGION}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_REPO_NAME="${SERVICE_NAME}"
CLUSTER_NAME="${SERVICE_NAME}-cluster"
TASK_FAMILY="${SERVICE_NAME}-task"
ECS_SERVICE_NAME="${SERVICE_NAME}-service"
LOG_GROUP="/ecs/${SERVICE_NAME}"
ALB_NAME="${SERVICE_NAME}-alb"
TG_NAME="${SERVICE_NAME}-tg"
TASK_EXEC_ROLE_NAME="${SERVICE_NAME}-task-exec-role"
TASK_ROLE_NAME="${SERVICE_NAME}-task-role"
ALB_SG_NAME="${SERVICE_NAME}-alb-sg"
ECS_SG_NAME="${SERVICE_NAME}-ecs-sg"
LAMBDA_ENDPOINT_SG_NAME="${SERVICE_NAME}-lambda-endpoint-sg"

# Join CORS_ORIGINS array from config into a comma-separated string
CORS_ALLOWED_ORIGINS="$(IFS=','; echo "${CORS_ORIGINS[*]}")"

ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO_NAME}"

echo "=== Deploy: ${SERVICE_NAME} to ${REGION} (account: ${ACCOUNT_ID}) ==="

# ─────────────────────────────────────────────
# Step 2: Create ECR repo (idempotent)
# ─────────────────────────────────────────────
echo "[2] Creating ECR repo (idempotent)..."
aws ecr describe-repositories --repository-names "${ECR_REPO_NAME}" --region "${REGION}" > /dev/null 2>&1 || \
  aws ecr create-repository \
    --repository-name "${ECR_REPO_NAME}" \
    --region "${REGION}" \
    --image-scanning-configuration scanOnPush=true \
    --query 'repository.repositoryUri' \
    --output text

# ─────────────────────────────────────────────
# Step 3: Authenticate Docker to ECR
# ─────────────────────────────────────────────
echo "[3] Authenticating Docker to ECR..."
aws ecr get-login-password --region "${REGION}" | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# ─────────────────────────────────────────────
# Step 4: Build and push image (linux/amd64)
# Builds directly to ECR — avoids cross-platform
# load issues on Apple Silicon.
# ─────────────────────────────────────────────
echo "[4] Building and pushing image (linux/amd64)..."
SERVICE_DIR="$(dirname "${SCRIPT_DIR}")"
SERVICES_ROOT="$(dirname "${SERVICE_DIR}")"

docker buildx build \
  --platform linux/amd64 \
  --provenance=false \
  --file "${SERVICE_DIR}/Dockerfile" \
  -t "${ECR_URI}:latest" \
  --push \
  "${SERVICES_ROOT}"

# ─────────────────────────────────────────────
# Step 5: Capture image digest
# ─────────────────────────────────────────────
echo "[5] Capturing image digest..."
IMAGE_DIGEST="$(aws ecr describe-images \
  --repository-name "${ECR_REPO_NAME}" \
  --region "${REGION}" \
  --image-ids imageTag=latest \
  --query 'imageDetails[0].imageDigest' \
  --output text)"

IMAGE_WITH_DIGEST="${ECR_URI}@${IMAGE_DIGEST}"
echo "  Image digest: ${IMAGE_DIGEST}"

# ─────────────────────────────────────────────
# Step 6: Create ECS cluster with FARGATE (idempotent)
# ─────────────────────────────────────────────
echo "[6] Creating ECS cluster (idempotent)..."
aws ecs describe-clusters --clusters "${CLUSTER_NAME}" --region "${REGION}" \
  --query 'clusters[?status==`ACTIVE`].clusterName' --output text | grep -q "${CLUSTER_NAME}" || \
  aws ecs create-cluster \
    --cluster-name "${CLUSTER_NAME}" \
    --capacity-providers FARGATE \
    --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1 \
    --region "${REGION}"

# ─────────────────────────────────────────────
# Step 7: Create CloudWatch log group
# ─────────────────────────────────────────────
echo "[7] Creating CloudWatch log group..."
aws logs create-log-group --log-group-name "${LOG_GROUP}" --region "${REGION}" 2>/dev/null || true

# ─────────────────────────────────────────────
# Step 8: Create ECS task execution role
# ─────────────────────────────────────────────
echo "[8] Creating ECS task execution role..."
EXEC_ROLE_ARN="$(aws iam get-role --role-name "${TASK_EXEC_ROLE_NAME}" \
  --query 'Role.Arn' --output text 2>/dev/null || true)"

if [ -z "${EXEC_ROLE_ARN}" ] || [ "${EXEC_ROLE_ARN}" = "None" ]; then
  EXEC_ROLE_ARN="$(aws iam create-role \
    --role-name "${TASK_EXEC_ROLE_NAME}" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "ecs-tasks.amazonaws.com"},
        "Action": "sts:AssumeRole"
      }]
    }' \
    --query 'Role.Arn' --output text)"

  aws iam attach-role-policy \
    --role-name "${TASK_EXEC_ROLE_NAME}" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
fi

# Always update secrets policy so JWT_SECRET_ARN changes take effect on redeploy
aws iam put-role-policy \
  --role-name "${TASK_EXEC_ROLE_NAME}" \
  --policy-name "SecretsManagerRead" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": \"secretsmanager:GetSecretValue\",
      \"Resource\": \"${JWT_SECRET_ARN}*\"
    }]
  }"
echo "  Execution role ARN: ${EXEC_ROLE_ARN}"

# ─────────────────────────────────────────────
# Step 9: Create ECS task role with Lambda invoke policy
# ─────────────────────────────────────────────
echo "[9] Creating ECS task role with Lambda invoke policy..."
TASK_ROLE_ARN="$(aws iam get-role --role-name "${TASK_ROLE_NAME}" \
  --query 'Role.Arn' --output text 2>/dev/null || true)"

if [ -z "${TASK_ROLE_ARN}" ] || [ "${TASK_ROLE_ARN}" = "None" ]; then
  TASK_ROLE_ARN="$(aws iam create-role \
    --role-name "${TASK_ROLE_NAME}" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "ecs-tasks.amazonaws.com"},
        "Action": "sts:AssumeRole"
      }]
    }' \
    --query 'Role.Arn' --output text)"
fi

# Always update the policy so changes to STREAMING_LAMBDA_ARN take effect on redeploy
aws iam put-role-policy \
  --role-name "${TASK_ROLE_NAME}" \
  --policy-name "StreamingLambdaInvoke" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": \"lambda:InvokeFunction\",
      \"Resource\": \"${STREAMING_LAMBDA_ARN}\"
    }]
  }"

# Polly (SynthesizeSpeech) and Transcribe Streaming — resource-level permissions not supported
aws iam put-role-policy \
  --role-name "${TASK_ROLE_NAME}" \
  --policy-name "VoiceServices" \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": [
        "polly:SynthesizeSpeech",
        "transcribe:StartStreamTranscription"
      ],
      "Resource": "*"
    }]
  }'

# DynamoDB — UpdateItem on the sessions table for cross-task rate limiting
aws iam put-role-policy \
  --role-name "${TASK_ROLE_NAME}" \
  --policy-name "DynamoDBRateLimit" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": \"dynamodb:UpdateItem\",
      \"Resource\": \"arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/${SESSIONS_TABLE}\"
    }]
  }"
echo "  Task role ARN: ${TASK_ROLE_ARN}"

# ─────────────────────────────────────────────
# Step 10: Validate VPC ID
# ─────────────────────────────────────────────
echo "[10] Validating VPC ID..."
if [ -z "${VPC_ID}" ]; then
  echo "ERROR: VPC_ID is not set in .env.${ENV}" >&2
  exit 1
fi
echo "  VPC ID: ${VPC_ID}"


# ─────────────────────────────────────────────
# Step 11: Validate subnets
# ─────────────────────────────────────────────
echo "[11] Validating subnets..."
if [ -z "${ALB_SUBNET_1}" ] || [ -z "${ALB_SUBNET_2}" ]; then
  echo "ERROR: ALB_SUBNET_1 and ALB_SUBNET_2 must be set in .env.${ENV}" >&2
  exit 1
fi
if [ -z "${ECS_SUBNET_1}" ] || [ -z "${ECS_SUBNET_2}" ]; then
  echo "ERROR: ECS_SUBNET_1 and ECS_SUBNET_2 must be set in .env.${ENV}" >&2
  exit 1
fi
echo "  ALB subnets:  ${ALB_SUBNET_1}, ${ALB_SUBNET_2}"
echo "  ECS subnets:  ${ECS_SUBNET_1}, ${ECS_SUBNET_2}"

# ─────────────────────────────────────────────
# Step 12: Create ALB security group
# ─────────────────────────────────────────────
echo "[12] Creating ALB security group..."
ALB_SG_ID="$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${ALB_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' \
  --output text \
  --region "${REGION}" 2>/dev/null || true)"

if [ -z "${ALB_SG_ID}" ] || [ "${ALB_SG_ID}" = "None" ]; then
  ALB_SG_ID="$(aws ec2 create-security-group \
    --group-name "${ALB_SG_NAME}" \
    --description "ALB security group for ${SERVICE_NAME}" \
    --vpc-id "${VPC_ID}" \
    --query 'GroupId' \
    --output text \
    --region "${REGION}")"

  aws ec2 authorize-security-group-ingress \
    --group-id "${ALB_SG_ID}" \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0 \
    --region "${REGION}"
fi

echo "  ALB SG ID: ${ALB_SG_ID}"

# ─────────────────────────────────────────────
# Step 13: Create ECS task security group
# ─────────────────────────────────────────────
echo "[13] Creating ECS task security group..."
ECS_SG_ID="$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${ECS_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' \
  --output text \
  --region "${REGION}" 2>/dev/null || true)"

if [ -z "${ECS_SG_ID}" ] || [ "${ECS_SG_ID}" = "None" ]; then
  ECS_SG_ID="$(aws ec2 create-security-group \
    --group-name "${ECS_SG_NAME}" \
    --description "ECS task security group for ${SERVICE_NAME}" \
    --vpc-id "${VPC_ID}" \
    --query 'GroupId' \
    --output text \
    --region "${REGION}")"

  aws ec2 authorize-security-group-ingress \
    --group-id "${ECS_SG_ID}" \
    --protocol tcp \
    --port 8080 \
    --source-group "${ALB_SG_ID}" \
    --region "${REGION}"
fi
echo "  ECS SG ID: ${ECS_SG_ID}"

# ─────────────────────────────────────────────
# Step 14: Create Lambda VPC endpoint (idempotent)
# ─────────────────────────────────────────────
echo "[14] Creating Lambda VPC endpoint..."
LAMBDA_ENDPOINT_SG_ID="$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${LAMBDA_ENDPOINT_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' \
  --output text \
  --region "${REGION}" 2>/dev/null || true)"

if [ -z "${LAMBDA_ENDPOINT_SG_ID}" ] || [ "${LAMBDA_ENDPOINT_SG_ID}" = "None" ]; then
  LAMBDA_ENDPOINT_SG_ID="$(aws ec2 create-security-group \
    --group-name "${LAMBDA_ENDPOINT_SG_NAME}" \
    --description "Lambda VPC endpoint security group for ${SERVICE_NAME}" \
    --vpc-id "${VPC_ID}" \
    --query 'GroupId' \
    --output text \
    --region "${REGION}")"

  aws ec2 authorize-security-group-ingress \
    --group-id "${LAMBDA_ENDPOINT_SG_ID}" \
    --protocol tcp \
    --port 443 \
    --source-group "${ECS_SG_ID}" \
    --region "${REGION}"
fi
echo "  Lambda endpoint SG ID: ${LAMBDA_ENDPOINT_SG_ID}"

LAMBDA_ENDPOINT_ID="$(aws ec2 describe-vpc-endpoints \
  --filters \
    "Name=service-name,Values=com.amazonaws.${REGION}.lambda" \
    "Name=vpc-id,Values=${VPC_ID}" \
    "Name=vpc-endpoint-state,Values=available,pending" \
  --query 'VpcEndpoints[0].VpcEndpointId' \
  --output text \
  --region "${REGION}" 2>/dev/null || true)"

if [ -z "${LAMBDA_ENDPOINT_ID}" ] || [ "${LAMBDA_ENDPOINT_ID}" = "None" ]; then
  LAMBDA_ENDPOINT_ID="$(aws ec2 create-vpc-endpoint \
    --vpc-id "${VPC_ID}" \
    --service-name "com.amazonaws.${REGION}.lambda" \
    --vpc-endpoint-type Interface \
    --subnet-ids "${ECS_SUBNET_1}" "${ECS_SUBNET_2}" \
    --security-group-ids "${LAMBDA_ENDPOINT_SG_ID}" \
    --private-dns-enabled \
    --region "${REGION}" \
    --query 'VpcEndpoint.VpcEndpointId' \
    --output text)"
fi
echo "  Lambda VPC endpoint ID: ${LAMBDA_ENDPOINT_ID}"

# ─────────────────────────────────────────────
# Step 14a: Create Polly VPC endpoint (idempotent)
# ─────────────────────────────────────────────
echo "[14a] Creating Polly VPC endpoint..."
POLLY_ENDPOINT_ID="$(aws ec2 describe-vpc-endpoints \
  --filters \
    "Name=service-name,Values=com.amazonaws.${REGION}.polly" \
    "Name=vpc-id,Values=${VPC_ID}" \
    "Name=vpc-endpoint-state,Values=available,pending" \
  --query 'VpcEndpoints[0].VpcEndpointId' \
  --output text \
  --region "${REGION}" 2>/dev/null || true)"

if [ -z "${POLLY_ENDPOINT_ID}" ] || [ "${POLLY_ENDPOINT_ID}" = "None" ]; then
  POLLY_ENDPOINT_ID="$(aws ec2 create-vpc-endpoint \
    --vpc-id "${VPC_ID}" \
    --service-name "com.amazonaws.${REGION}.polly" \
    --vpc-endpoint-type Interface \
    --subnet-ids "${ECS_SUBNET_1}" "${ECS_SUBNET_2}" \
    --security-group-ids "${LAMBDA_ENDPOINT_SG_ID}" \
    --private-dns-enabled \
    --region "${REGION}" \
    --query 'VpcEndpoint.VpcEndpointId' \
    --output text 2>/dev/null)" || echo "  [WARN] Could not create Polly VPC endpoint — traffic will route via NAT gateway"
fi
echo "  Polly VPC endpoint ID: ${POLLY_ENDPOINT_ID:-none (using NAT)}"

# ─────────────────────────────────────────────
# Step 14b: Create Transcribe Streaming VPC endpoint (idempotent)
# ─────────────────────────────────────────────
echo "[14b] Creating Transcribe Streaming VPC endpoint..."
TRANSCRIBE_ENDPOINT_ID="$(aws ec2 describe-vpc-endpoints \
  --filters \
    "Name=service-name,Values=com.amazonaws.${REGION}.transcribestreaming" \
    "Name=vpc-id,Values=${VPC_ID}" \
    "Name=vpc-endpoint-state,Values=available,pending" \
  --query 'VpcEndpoints[0].VpcEndpointId' \
  --output text \
  --region "${REGION}" 2>/dev/null || true)"

if [ -z "${TRANSCRIBE_ENDPOINT_ID}" ] || [ "${TRANSCRIBE_ENDPOINT_ID}" = "None" ]; then
  TRANSCRIBE_ENDPOINT_ID="$(aws ec2 create-vpc-endpoint \
    --vpc-id "${VPC_ID}" \
    --service-name "com.amazonaws.${REGION}.transcribestreaming" \
    --vpc-endpoint-type Interface \
    --subnet-ids "${ECS_SUBNET_1}" "${ECS_SUBNET_2}" \
    --security-group-ids "${LAMBDA_ENDPOINT_SG_ID}" \
    --private-dns-enabled \
    --region "${REGION}" \
    --query 'VpcEndpoint.VpcEndpointId' \
    --output text 2>/dev/null)" || echo "  [WARN] Could not create Transcribe VPC endpoint — traffic will route via NAT gateway"
fi
echo "  Transcribe Streaming VPC endpoint ID: ${TRANSCRIBE_ENDPOINT_ID:-none (using NAT)}"

# ─────────────────────────────────────────────
# Step 15: Create ALB (internet-facing)
# ─────────────────────────────────────────────
echo "[15] Creating ALB..."
ALB_ARN="$(aws elbv2 describe-load-balancers \
  --names "${ALB_NAME}" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text \
  --region "${REGION}" 2>/dev/null || true)"

if [ -z "${ALB_ARN}" ] || [ "${ALB_ARN}" = "None" ]; then
  ALB_ARN="$(aws elbv2 create-load-balancer \
    --name "${ALB_NAME}" \
    --subnets "${ALB_SUBNET_1}" "${ALB_SUBNET_2}" \
    --security-groups "${ALB_SG_ID}" \
    --scheme internet-facing \
    --type application \
    --ip-address-type ipv4 \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text \
    --region "${REGION}")"
fi

ALB_DNS="$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "${ALB_ARN}" \
  --query 'LoadBalancers[0].DNSName' \
  --output text \
  --region "${REGION}")"
echo "  ALB ARN: ${ALB_ARN}"
echo "  ALB DNS: ${ALB_DNS}"

# ─────────────────────────────────────────────
# Step 15a: Create and associate WAF Web ACL
# ─────────────────────────────────────────────
echo "[15a] Setting up WAF Web ACL..."
WAF_ACL_NAME="${SERVICE_NAME}-waf-acl"

# SizeRestrictions_BODY blocks request bodies > 8 KB — overridden to Count so that
# the voice-chat endpoint can receive large base64-encoded audio payloads.
# The application enforces its own 5 MB limit, so this is safe.
WAF_RULES='[
  {
    "Name": "AWSManagedRulesCommonRuleSet",
    "Priority": 0,
    "OverrideAction": { "None": {} },
    "Statement": {
      "ManagedRuleGroupStatement": {
        "VendorName": "AWS",
        "Name": "AWSManagedRulesCommonRuleSet",
        "RuleActionOverrides": [
          {
            "Name": "SizeRestrictions_BODY",
            "ActionToUse": { "Count": {} }
          }
        ]
      }
    },
    "VisibilityConfig": {
      "SampledRequestsEnabled": true,
      "CloudWatchMetricsEnabled": true,
      "MetricName": "AWSManagedRulesCommonRuleSet"
    }
  }
]'

WAF_ACL_INFO="$(aws wafv2 list-web-acls \
  --scope REGIONAL \
  --region "${REGION}" \
  --query "WebACLs[?Name=='${WAF_ACL_NAME}'] | [0]" \
  --output json 2>/dev/null || true)"

WAF_ACL_ARN="$(echo "${WAF_ACL_INFO}" | jq -r '.ARN // empty')"
WAF_ACL_ID="$(echo "${WAF_ACL_INFO}"  | jq -r '.Id  // empty')"

if [ -z "${WAF_ACL_ARN}" ]; then
  WAF_ACL_ARN="$(aws wafv2 create-web-acl \
    --name "${WAF_ACL_NAME}" \
    --scope REGIONAL \
    --region "${REGION}" \
    --default-action '{"Allow": {}}' \
    --rules "${WAF_RULES}" \
    --visibility-config '{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"'"${WAF_ACL_NAME}"'"}' \
    --query 'Summary.ARN' \
    --output text)"
  echo "  WAF Web ACL created: ${WAF_ACL_ARN}"
else
  echo "  WAF Web ACL already exists — updating rules..."
  WAF_LOCK_TOKEN="$(aws wafv2 get-web-acl \
    --name "${WAF_ACL_NAME}" \
    --scope REGIONAL \
    --id "${WAF_ACL_ID}" \
    --region "${REGION}" \
    --query 'LockToken' \
    --output text)"
  aws wafv2 update-web-acl \
    --name "${WAF_ACL_NAME}" \
    --scope REGIONAL \
    --id "${WAF_ACL_ID}" \
    --region "${REGION}" \
    --default-action '{"Allow": {}}' \
    --rules "${WAF_RULES}" \
    --visibility-config '{"SampledRequestsEnabled":true,"CloudWatchMetricsEnabled":true,"MetricName":"'"${WAF_ACL_NAME}"'"}' \
    --lock-token "${WAF_LOCK_TOKEN}" \
    --output text > /dev/null
  echo "  WAF Web ACL updated: ${WAF_ACL_ARN}"
fi

aws wafv2 associate-web-acl \
  --web-acl-arn "${WAF_ACL_ARN}" \
  --resource-arn "${ALB_ARN}" \
  --region "${REGION}" 2>/dev/null || true
echo "  WAF associated with ALB"

# ─────────────────────────────────────────────
# Step 16: Create target group
# ─────────────────────────────────────────────
echo "[16] Creating target group..."
TG_ARN="$(aws elbv2 describe-target-groups \
  --names "${TG_NAME}" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text \
  --region "${REGION}" 2>/dev/null || true)"

if [ -z "${TG_ARN}" ] || [ "${TG_ARN}" = "None" ]; then
  TG_ARN="$(aws elbv2 create-target-group \
    --name "${TG_NAME}" \
    --protocol HTTP \
    --port 8080 \
    --vpc-id "${VPC_ID}" \
    --target-type ip \
    --health-check-protocol HTTP \
    --health-check-path /health \
    --health-check-interval-seconds 30 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text \
    --region "${REGION}")"
fi
echo "  Target group ARN: ${TG_ARN}"

# ─────────────────────────────────────────────
# Step 17: Create HTTP listener on port 80
# ─────────────────────────────────────────────
echo "[17] Creating HTTP listener..."
LISTENER_ARN="$(aws elbv2 describe-listeners \
  --load-balancer-arn "${ALB_ARN}" \
  --query 'Listeners[?Port==`80`].ListenerArn' \
  --output text \
  --region "${REGION}" 2>/dev/null || true)"

if [ -z "${LISTENER_ARN}" ] || [ "${LISTENER_ARN}" = "None" ]; then
  LISTENER_ARN="$(aws elbv2 create-listener \
    --load-balancer-arn "${ALB_ARN}" \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn="${TG_ARN}" \
    --query 'Listeners[0].ListenerArn' \
    --output text \
    --region "${REGION}")"
fi
echo "  Listener ARN: ${LISTENER_ARN}"

# ─────────────────────────────────────────────
# Step 18: Register task definition
# ─────────────────────────────────────────────
echo "[18] Registering task definition..."

CONTAINER_ENV="[
  {\"name\": \"AWS_REGION\",            \"value\": \"${REGION}\"},
  {\"name\": \"STREAMING_LAMBDA_ARN\",  \"value\": \"${STREAMING_LAMBDA_ARN}\"},
  {\"name\": \"CORS_ALLOWED_ORIGINS\",  \"value\": \"${CORS_ALLOWED_ORIGINS}\"},
  {\"name\": \"JWT_COOKIE_DOMAIN\",     \"value\": \"${JWT_COOKIE_DOMAIN}\"},
  {\"name\": \"JWT_COOKIE_SECURE\",     \"value\": \"${JWT_COOKIE_SECURE}\"},
  {\"name\": \"SESSIONS_TABLE\",        \"value\": \"${SESSIONS_TABLE}\"}
]"

CONTAINER_SECRETS="[
  {\"name\": \"JWT_SECRET\", \"valueFrom\": \"${JWT_SECRET_ARN}\"}
]"

TASK_DEF_ARN="$(aws ecs register-task-definition \
  --family "${TASK_FAMILY}" \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu 512 \
  --memory 1024 \
  --execution-role-arn "${EXEC_ROLE_ARN}" \
  --task-role-arn "${TASK_ROLE_ARN}" \
  --container-definitions "[
    {
      \"name\": \"${SERVICE_NAME}\",
      \"image\": \"${IMAGE_WITH_DIGEST}\",
      \"portMappings\": [{\"containerPort\": 8080, \"protocol\": \"tcp\"}],
      \"environment\": ${CONTAINER_ENV},
      \"secrets\": ${CONTAINER_SECRETS},
      \"logConfiguration\": {
        \"logDriver\": \"awslogs\",
        \"options\": {
          \"awslogs-group\": \"${LOG_GROUP}\",
          \"awslogs-region\": \"${REGION}\",
          \"awslogs-stream-prefix\": \"ecs\"
        }
      },
      \"essential\": true,
      \"readonlyRootFilesystem\": true
    }
  ]" \
  --region "${REGION}" \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)"

echo "  Task definition ARN: ${TASK_DEF_ARN}"

# ─────────────────────────────────────────────
# Step 19: Create or update ECS service
# ─────────────────────────────────────────────
echo "[19] Creating or updating ECS service..."
SERVICE_EXISTS="$(aws ecs describe-services \
  --cluster "${CLUSTER_NAME}" \
  --services "${ECS_SERVICE_NAME}" \
  --region "${REGION}" \
  --query 'services[?status==`ACTIVE`].serviceName' \
  --output text 2>/dev/null || true)"

if [ -z "${SERVICE_EXISTS}" ] || [ "${SERVICE_EXISTS}" = "None" ]; then
  aws ecs create-service \
    --cluster "${CLUSTER_NAME}" \
    --service-name "${ECS_SERVICE_NAME}" \
    --task-definition "${TASK_DEF_ARN}" \
    --desired-count 2 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[${ECS_SUBNET_1},${ECS_SUBNET_2}],securityGroups=[${ECS_SG_ID}],assignPublicIp=DISABLED}" \
    --load-balancers "targetGroupArn=${TG_ARN},containerName=${SERVICE_NAME},containerPort=8080" \
    --region "${REGION}" \
    --output text > /dev/null
  echo "  ECS service created."
else
  aws ecs update-service \
    --cluster "${CLUSTER_NAME}" \
    --service "${ECS_SERVICE_NAME}" \
    --task-definition "${TASK_DEF_ARN}" \
    --network-configuration "awsvpcConfiguration={subnets=[${ECS_SUBNET_1},${ECS_SUBNET_2}],securityGroups=[${ECS_SG_ID}],assignPublicIp=DISABLED}" \
    --force-new-deployment \
    --region "${REGION}" \
    --output text > /dev/null
  echo "  ECS service updated (force-new-deployment)."
fi

# ─────────────────────────────────────────────
# Step 20: Wait for stability, print env var
# ─────────────────────────────────────────────
echo "[20] Waiting for ECS service to stabilize..."
aws ecs wait services-stable \
  --cluster "${CLUSTER_NAME}" \
  --services "${ECS_SERVICE_NAME}" \
  --region "${REGION}"

echo ""
echo "=== Deploy complete ==="
echo ""
echo "Add to your frontend .env file:"
echo "  VITE_LAMBDA_API_URL=http://${ALB_DNS}"
echo ""