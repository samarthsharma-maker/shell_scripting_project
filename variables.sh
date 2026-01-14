#!/usr/bin/env bash

set -euo pipefail

################################################################################
# CORE CONFIGURATION VARIABLES
################################################################################

# AWS Core Settings
AWS_REGION="${AWS_REGION:-ap-south-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
AWS_PROFILE="${AWS_PROFILE:-default}"

# Project Identification
PROJECT_NAME="${PROJECT_NAME:-myproject}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"

################################################################################
# NETWORK CONFIGURATION
################################################################################

# VPC Configuration
VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
AVAILABILITY_ZONES="${AVAILABILITY_ZONES:-ap-south-1a,ap-south-1b}"
PUBLIC_SUBNET_CIDRS="${PUBLIC_SUBNET_CIDRS:-10.0.1.0/24,10.0.2.0/24}"
PRIVATE_SUBNET_CIDRS="${PRIVATE_SUBNET_CIDRS:-10.0.101.0/24,10.0.102.0/24}"

# NAT Gateway Configuration
ENABLE_NAT_GATEWAY="${ENABLE_NAT_GATEWAY:-true}"
SINGLE_NAT_GATEWAY="${SINGLE_NAT_GATEWAY:-true}"

################################################################################
# EKS CLUSTER CONFIGURATION
################################################################################

# Cluster Settings
EKS_VERSION="${EKS_VERSION:-1.28}"
EKS_SERVICE_ROLE_NAME="${EKS_SERVICE_ROLE_NAME:-}"
OIDC_PROVIDER_ENABLED="${OIDC_PROVIDER_ENABLED:-true}"

# Cluster Networking
CLUSTER_ENDPOINT_PUBLIC_ACCESS="${CLUSTER_ENDPOINT_PUBLIC_ACCESS:-true}"
CLUSTER_ENDPOINT_PRIVATE_ACCESS="${CLUSTER_ENDPOINT_PRIVATE_ACCESS:-true}"

# Cluster Logging
CLUSTER_LOG_TYPES="${CLUSTER_LOG_TYPES:-api,audit,authenticator}"

# Cluster Encryption
ENABLE_CLUSTER_ENCRYPTION="${ENABLE_CLUSTER_ENCRYPTION:-true}"
KMS_KEY_ALIAS="${KMS_KEY_ALIAS:-}"

################################################################################
# EKS NODE GROUP CONFIGURATION
################################################################################

# Node Instance Settings
NODE_INSTANCE_TYPE="${NODE_INSTANCE_TYPE:-t3.medium}"
NODE_INSTANCE_ROLE_NAME="${NODE_INSTANCE_ROLE_NAME:-}"
NODE_AMI_TYPE="${NODE_AMI_TYPE:-AL2_x86_64}"
CUSTOM_AMI_ID="${CUSTOM_AMI_ID:-}"

# Node Scaling
NODE_MIN_SIZE="${NODE_MIN_SIZE:-2}"
NODE_MAX_SIZE="${NODE_MAX_SIZE:-4}"
NODE_DESIRED_SIZE="${NODE_DESIRED_SIZE:-2}"

# Node Storage
NODE_DISK_SIZE="${NODE_DISK_SIZE:-50}"
NODE_VOLUME_TYPE="${NODE_VOLUME_TYPE:-gp3}"

# Spot Instances
ENABLE_SPOT_INSTANCES="${ENABLE_SPOT_INSTANCES:-false}"
SPOT_MAX_PRICE="${SPOT_MAX_PRICE:-}"

# Node Labels and Taints
NODE_LABELS="${NODE_LABELS:-env=${ENVIRONMENT},project=${PROJECT_NAME}}"
NODE_TAINTS="${NODE_TAINTS:-}"

################################################################################
# ECR CONFIGURATION
################################################################################

ECR_SCAN_ON_PUSH="${ECR_SCAN_ON_PUSH:-true}"
ECR_LIFECYCLE_POLICY_DAYS="${ECR_LIFECYCLE_POLICY_DAYS:-30}"
ECR_REPO_POLICY_ENABLED="${ECR_REPO_POLICY_ENABLED:-true}"

################################################################################
# S3 CONFIGURATION
################################################################################

S3_BUCKET_PURPOSE="${S3_BUCKET_PURPOSE:-platform-artifacts}"
S3_VERSIONING_ENABLED="${S3_VERSIONING_ENABLED:-true}"
S3_ENCRYPTION_ENABLED="${S3_ENCRYPTION_ENABLED:-true}"
S3_BLOCK_PUBLIC_ACCESS="${S3_BLOCK_PUBLIC_ACCESS:-true}"
S3_LIFECYCLE_DAYS="${S3_LIFECYCLE_DAYS:-90}"

################################################################################
# MONITORING & OBSERVABILITY
################################################################################

ENABLE_CLOUDWATCH_LOGS="${ENABLE_CLOUDWATCH_LOGS:-true}"
ENABLE_PROMETHEUS="${ENABLE_PROMETHEUS:-true}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"

# Alerting
ALERT_SLACK_WEBHOOK="${ALERT_SLACK_WEBHOOK:-}"
ALERT_EMAIL="${ALERT_EMAIL:-}"

################################################################################
# SECURITY & COMPLIANCE
################################################################################

ENABLE_POD_SECURITY="${ENABLE_POD_SECURITY:-true}"
ENABLE_NETWORK_POLICIES="${ENABLE_NETWORK_POLICIES:-true}"
ENABLE_AUDIT_REPORTS="${ENABLE_AUDIT_REPORTS:-true}"
COMPLIANCE_STANDARD="${COMPLIANCE_STANDARD:-CIS}"

################################################################################
# CI/CD CONFIGURATION
################################################################################

CI_PROVIDER="${CI_PROVIDER:-github}"
GIT_REPO_URL="${GIT_REPO_URL:-}"
DEPLOYMENT_STRATEGY="${DEPLOYMENT_STRATEGY:-blue-green}"
ENABLE_CANARY="${ENABLE_CANARY:-false}"

################################################################################
# SCRIPT BEHAVIOR
################################################################################

DRY_RUN="${DRY_RUN:-false}"
AUTO_APPROVE="${AUTO_APPROVE:-false}"
RESOURCE_TTL_HOURS="${RESOURCE_TTL_HOURS:-}"

################################################################################
# DERIVED VARIABLES (Auto-calculated)
################################################################################

CLUSTER_NAME="${PROJECT_NAME}-${ENVIRONMENT}-cluster"
VPC_NAME="${PROJECT_NAME}-${ENVIRONMENT}-vpc"
ECR_REPO_NAME="${PROJECT_NAME}-${ENVIRONMENT}"
S3_BUCKET_NAME="${PROJECT_NAME}-${ENVIRONMENT}-${TIMESTAMP}"
LOG_FILE="aws-provision-${TIMESTAMP}.log"

# Role names with defaults
EKS_SERVICE_ROLE_NAME="${EKS_SERVICE_ROLE_NAME:-${PROJECT_NAME}-${ENVIRONMENT}-eks-role}"
NODE_INSTANCE_ROLE_NAME="${NODE_INSTANCE_ROLE_NAME:-${PROJECT_NAME}-${ENVIRONMENT}-node-role}"

# KMS key alias
KMS_KEY_ALIAS="${KMS_KEY_ALIAS:-alias/${PROJECT_NAME}-${ENVIRONMENT}-eks}"