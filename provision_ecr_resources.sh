#!/usr/bin/env bash

################################################################################
# ECR Repository Creation Module - Production Grade
# Creates ECR repositories with security scanning, lifecycle policies
# Version: 2.0
################################################################################

set -euo pipefail

source utilities.sh

# Source variables if not already loaded
if [[ -z "${PROJECT_NAME:-}" ]]; then
    if [[ -f "variables.sh" ]]; then
        source variables.sh
    else
        echo "ERROR: variables.sh not found and required variables not set"
        exit 1
    fi
fi

# ECR Resource Variables
ECR_REPOSITORY_NAME=""
ECR_REPOSITORY_URI=""
ECR_REPOSITORY_ARN=""

# Unified state file
STATE_FILE="cloud-state-${PROJECT_NAME}-${ENVIRONMENT}.json"

################################################################################
# COLOR CODES
################################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

################################################################################
# STATE MANAGEMENT
################################################################################

save_state() {
    # Read existing state or create new
    local existing_state="{}"
    if [[ -f "$STATE_FILE" ]]; then
        existing_state=$(cat "$STATE_FILE")
    fi
    
    # Update ECR section in state
    cat > "$STATE_FILE" <<EOF
{
  "project": "${PROJECT_NAME}",
  "environment": "${ENVIRONMENT}",
  "region": "${AWS_REGION}",
  "last_updated": "$(date -Iseconds)",
  "vpc": $(echo "$existing_state" | jq -c '.vpc // {}' 2>/dev/null || echo '{}'),
  "s3": $(echo "$existing_state" | jq -c '.s3 // {}' 2>/dev/null || echo '{}'),
  "ecr": {
    "repository_name": "${ECR_REPOSITORY_NAME}",
    "repository_uri": "${ECR_REPOSITORY_URI}",
    "repository_arn": "${ECR_REPOSITORY_ARN}",
    "scan_on_push": "${ECR_SCAN_ON_PUSH}"
  },
  "eks": $(echo "$existing_state" | jq -c '.eks // {}' 2>/dev/null || echo '{}')
}
EOF
    log "State saved to $STATE_FILE"
}

cleanup_on_error() {
    error "An error occurred during ECR creation. Initiating rollback..."
    
    if [[ -n "$ECR_REPOSITORY_NAME" ]]; then
        warning "Attempting to delete repository: $ECR_REPOSITORY_NAME"
        
        # Force delete repository with all images
        aws ecr delete-repository --repository-name "$ECR_REPOSITORY_NAME" --region "$AWS_REGION" --force 2>/dev/null || true
        
        success "Repository deleted: $ECR_REPOSITORY_NAME"
    fi
    
    save_state
    exit 1
}

trap cleanup_on_error ERR

################################################################################
# PREREQUISITE CHECKS
################################################################################

check_prerequisites() {
    section "CHECKING PREREQUISITES"
    
    # Check AWS CLI
    if command -v aws &> /dev/null; then
        success "AWS CLI is installed"
    else
        error "AWS CLI is not installed"
        exit 1
    fi
    
    # Check AWS credentials
    if aws sts get-caller-identity --region "$AWS_REGION" &> /dev/null; then
        success "AWS credentials are valid"
        AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
        log "AWS Account ID: $AWS_ACCOUNT_ID"
    else
        error "AWS credentials are invalid or not configured"
        exit 1
    fi
    
    # Check jq
    if command -v jq &> /dev/null; then
        success "jq is available for JSON parsing"
    else
        warning "jq is not installed (optional but recommended)"
    fi
    
    # Validate required variables
    if [[ -z "$PROJECT_NAME" ]] || [[ -z "$ENVIRONMENT" ]] || [[ -z "$AWS_REGION" ]]; then
        error "Required variables not set: PROJECT_NAME, ENVIRONMENT, AWS_REGION"
        exit 1
    fi
    
    success "All required variables are set"
    success "Configuration validation passed"
}

################################################################################
# CHECK EXISTING REPOSITORY
################################################################################

check_existing_repository() {
    section "CHECKING FOR EXISTING ECR REPOSITORY"
    
    ECR_REPOSITORY_NAME="${PROJECT_NAME}-${ENVIRONMENT}"
    
    if aws ecr describe-repositories \
        --repository-names "$ECR_REPOSITORY_NAME" \
        --region "$AWS_REGION" &>/dev/null; then
        
        warning "ECR repository already exists: $ECR_REPOSITORY_NAME"
        echo -n "Do you want to use the existing repository? (yes/no): "
        read -r response
        
        if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            log "Using existing ECR repository: $ECR_REPOSITORY_NAME"
            load_existing_repository
            return 0
        else
            error "Please use a different repository name or delete the existing repository"
            exit 1
        fi
    else
        log "No existing repository found with name: $ECR_REPOSITORY_NAME"
        return 1
    fi
}

load_existing_repository() {
    log "Loading existing ECR repository configuration..."
    
    local repo_info=$(aws ecr describe-repositories \
        --repository-names "$ECR_REPOSITORY_NAME" \
        --region "$AWS_REGION" \
        --output json)
    
    ECR_REPOSITORY_URI=$(echo "$repo_info" | jq -r '.repositories[0].repositoryUri')
    ECR_REPOSITORY_ARN=$(echo "$repo_info" | jq -r '.repositories[0].repositoryArn')
    
    log "Repository URI: $ECR_REPOSITORY_URI"
    log "Repository ARN: $ECR_REPOSITORY_ARN"
    
    # Check scan on push setting
    local scan_config=$(aws ecr get-repository-policy \
        --repository-name "$ECR_REPOSITORY_NAME" \
        --region "$AWS_REGION" 2>/dev/null || echo "")
    
    local image_scanning=$(echo "$repo_info" | jq -r '.repositories[0].imageScanningConfiguration.scanOnPush')
    
    if [[ "$image_scanning" == "true" ]]; then
        log "Image scanning on push is enabled"
    else
        warning "Image scanning on push is not enabled"
    fi
    
    save_state
    success "Loaded existing ECR repository configuration"
}

################################################################################
# CREATE ECR REPOSITORY
################################################################################

create_ecr_repository() {
    section "CREATING ECR REPOSITORY"
    
    ECR_REPOSITORY_NAME="${PROJECT_NAME}-${ENVIRONMENT}"
    
    log "Creating ECR repository: $ECR_REPOSITORY_NAME"
    
    local scan_config="scanOnPush=false"
    if [[ "$ECR_SCAN_ON_PUSH" == "true" ]]; then
        scan_config="scanOnPush=true"
    fi
    
    local repo_result=$(aws ecr create-repository \
        --repository-name "$ECR_REPOSITORY_NAME" \
        --region "$AWS_REGION" \
        --image-scanning-configuration "$scan_config" \
        --encryption-configuration encryptionType=AES256 \
        --tags "Key=Name,Value=${ECR_REPOSITORY_NAME}" \
               "Key=Project,Value=${PROJECT_NAME}" \
               "Key=Environment,Value=${ENVIRONMENT}" \
               "Key=ManagedBy,Value=shell-script" \
               "Key=CreatedAt,Value=$(date -Iseconds)" \
        --output json)
    
    ECR_REPOSITORY_URI=$(echo "$repo_result" | jq -r '.repository.repositoryUri')
    ECR_REPOSITORY_ARN=$(echo "$repo_result" | jq -r '.repository.repositoryArn')
    
    success "ECR repository created: $ECR_REPOSITORY_NAME"
    log "Repository URI: $ECR_REPOSITORY_URI"
    
    save_state
}

################################################################################
# CONFIGURE LIFECYCLE POLICY
################################################################################

configure_lifecycle_policy() {
    section "CONFIGURING LIFECYCLE POLICY"
    
    log "Setting lifecycle policy for repository: $ECR_REPOSITORY_NAME"
    
    local lifecycle_policy='{
        "rules": [
            {
                "rulePriority": 1,
                "description": "Keep last '${ECR_LIFECYCLE_POLICY_DAYS}' images",
                "selection": {
                    "tagStatus": "any",
                    "countType": "imageCountMoreThan",
                    "countNumber": '${ECR_LIFECYCLE_POLICY_DAYS}'
                },
                "action": {
                    "type": "expire"
                }
            }
        ]
    }'
    
    echo "$lifecycle_policy" | aws ecr put-lifecycle-policy \
        --repository-name "$ECR_REPOSITORY_NAME" \
        --region "$AWS_REGION" \
        --lifecycle-policy-text file:///dev/stdin &>/dev/null
    
    success "Lifecycle policy configured (keep last ${ECR_LIFECYCLE_POLICY_DAYS} images)"
    save_state
}

################################################################################
# CONFIGURE REPOSITORY POLICY
################################################################################

configure_repository_policy() {
    if [[ "$ECR_REPO_POLICY_ENABLED" != "true" ]]; then
        log "Repository policy is disabled (ECR_REPO_POLICY_ENABLED=false)"
        return 0
    fi
    
    section "CONFIGURING REPOSITORY POLICY"
    
    log "Setting repository policy for: $ECR_REPOSITORY_NAME"
    
    local repository_policy='{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "AllowPushPull",
                "Effect": "Allow",
                "Principal": {
                    "AWS": "arn:aws:iam::'${AWS_ACCOUNT_ID}':root"
                },
                "Action": [
                    "ecr:GetDownloadUrlForLayer",
                    "ecr:BatchGetImage",
                    "ecr:BatchCheckLayerAvailability",
                    "ecr:PutImage",
                    "ecr:InitiateLayerUpload",
                    "ecr:UploadLayerPart",
                    "ecr:CompleteLayerUpload"
                ]
            }
        ]
    }'
    
    echo "$repository_policy" | aws ecr set-repository-policy \
        --repository-name "$ECR_REPOSITORY_NAME" \
        --region "$AWS_REGION" \
        --policy-text file:///dev/stdin &>/dev/null
    
    success "Repository policy configured"
    save_state
}

################################################################################
# ENABLE IMAGE SCANNING
################################################################################

enable_image_scanning() {
    if [[ "$ECR_SCAN_ON_PUSH" != "true" ]]; then
        log "Image scanning is disabled (ECR_SCAN_ON_PUSH=false)"
        return 0
    fi
    
    section "VERIFYING IMAGE SCANNING"
    
    log "Ensuring image scanning on push is enabled..."
    
    aws ecr put-image-scanning-configuration \
        --repository-name "$ECR_REPOSITORY_NAME" \
        --region "$AWS_REGION" \
        --image-scanning-configuration scanOnPush=true &>/dev/null
    
    success "Image scanning on push is enabled"
    save_state
}

################################################################################
# SUMMARY
################################################################################

print_summary() {
    section "ECR REPOSITORY CREATION SUMMARY"
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                ECR REPOSITORY INFRASTRUCTURE              ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Repository Details:"
    echo "  Repository Name:     $ECR_REPOSITORY_NAME"
    echo "  Repository URI:      $ECR_REPOSITORY_URI"
    echo "  Repository ARN:      $ECR_REPOSITORY_ARN"
    echo "  Region:              $AWS_REGION"
    echo "  Account ID:          $AWS_ACCOUNT_ID"
    echo ""
    echo "Configuration:"
    echo "  Scan on Push:        $ECR_SCAN_ON_PUSH"
    echo "  Lifecycle Days:      $ECR_LIFECYCLE_POLICY_DAYS"
    echo "  Repository Policy:   $ECR_REPO_POLICY_ENABLED"
    echo "  Encryption:          AES256"
    echo ""
    echo "Docker Commands:"
    echo "  Login:"
    echo "    aws ecr get-login-password --region $AWS_REGION | \\"
    echo "      docker login --username AWS --password-stdin $ECR_REPOSITORY_URI"
    echo ""
    echo "  Tag and Push:"
    echo "    docker tag myimage:latest $ECR_REPOSITORY_URI:latest"
    echo "    docker push $ECR_REPOSITORY_URI:latest"
    echo ""
    echo "State File:"
    echo "  Location:            $STATE_FILE"
    echo ""
    echo "Log File:"
    echo "  Location:            $LOG_FILE"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Export variables for use by other scripts
    cat > "ecr-exports.sh" <<EOF
#!/bin/bash
# ECR Exports - Source this file to use ECR resources in other scripts
export ECR_REPOSITORY_NAME="$ECR_REPOSITORY_NAME"
export ECR_REPOSITORY_URI="$ECR_REPOSITORY_URI"
export ECR_REPOSITORY_ARN="$ECR_REPOSITORY_ARN"
export ECR_REGION="$AWS_REGION"
EOF
    chmod +x ecr-exports.sh
    success "Export file created: ecr-exports.sh"
}

################################################################################
# MAIN EXECUTION
################################################################################

main() {
    LOG_FILE="aws-ecr-provision-$(date +%Y%m%d%H%M%S).log"
    
    log "Starting ECR repository creation process..."
    log "Project: $PROJECT_NAME | Environment: $ENVIRONMENT | Region: $AWS_REGION"
    echo ""
    
    check_prerequisites
    
    if ! check_existing_repository; then
        create_ecr_repository
    fi
    
    # Always configure/verify settings (for both new and existing repositories)
    configure_lifecycle_policy
    configure_repository_policy
    enable_image_scanning
    
    print_summary
    
    success "ECR repository provisioning completed successfully!"
    log "You can now push Docker images to: $ECR_REPOSITORY_URI"
}

# Execute main function
main
