#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

source utilities.sh
source variables.sh

# Global variables to track validation status
VALIDATION_ERRORS=0
VALIDATION_WARNINGS=0

validate_required_var() {
    local var_name=$1
    local var_value=$2
    local error_msg=${3:-"$var_name is required but not set"}
    
    if [[ -z "$var_value" ]]; then
        error "$error_msg"
        ((VALIDATION_ERRORS++))
        return 1
    fi
    return 0
}

validate_optional_var() {
    local var_name=$1
    local var_value=$2
    local warning_msg=${3:-"$var_name is not set, using default or skipping feature"}
    
    if [[ -z "$var_value" ]]; then
        warning "$warning_msg"
        ((VALIDATION_WARNINGS++))
        return 1
    fi
    return 0
}

validate_boolean() {
    local var_name=$1
    local var_value=$2
    
    if [[ "$var_value" != "true" && "$var_value" != "false" ]]; then
        error "$var_name must be 'true' or 'false', got: $var_value"
        ((VALIDATION_ERRORS++))
        return 1
    fi
    return 0
}

validate_number() {
    local var_name=$1
    local var_value=$2
    local min=${3:-0}
    local max=${4:-9999}
    
    if ! [[ "$var_value" =~ ^[0-9]+$ ]]; then
        error "$var_name must be a number, got: $var_value"
        ((VALIDATION_ERRORS++))
        return 1
    fi
    
    if [[ $var_value -lt $min ]] || [[ $var_value -gt $max ]]; then
        error "$var_name must be between $min and $max, got: $var_value"
        ((VALIDATION_ERRORS++))
        return 1
    fi
    return 0
}

validate_cidr() {
    local var_name=$1
    local cidr=$2
    
    if ! [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        error "$var_name has invalid CIDR format: $cidr"
        ((VALIDATION_ERRORS++))
        return 1
    fi
    return 0
}

validate_region() {
    local region=$1
    local valid_regions=(
        "us-east-1" "us-east-2" "us-west-1" "us-west-2"
        "eu-west-1" "eu-west-2" "eu-west-3" "eu-central-1"
        "ap-south-1" "ap-northeast-1" "ap-northeast-2" "ap-southeast-1" "ap-southeast-2"
        "ca-central-1" "sa-east-1"
    )
    
    for valid_region in "${valid_regions[@]}"; do
        if [[ "$region" == "$valid_region" ]]; then
            return 0
        fi
    done
    
    warning "Region $region may not be valid. Common regions: ${valid_regions[*]}"
    ((VALIDATION_WARNINGS++))
    return 1
}

validate_eks_version() {
    local version=$1
    local valid_versions=("1.28" "1.29" "1.30" "1.31")
    
    for valid_version in "${valid_versions[@]}"; do
        if [[ "$version" == "$valid_version" ]]; then
            return 0
        fi
    done
    
    warning "EKS version $version may not be supported. Supported versions: ${valid_versions[*]}"
    ((VALIDATION_WARNINGS++))
    return 1
}

################################################################################
# COMPREHENSIVE VARIABLE VALIDATION
################################################################################

validate_all_variables() {
    section "VALIDATING CONFIGURATION"
    
    log "Starting comprehensive variable validation..."
    
    # Reset counters
    VALIDATION_ERRORS=0
    VALIDATION_WARNINGS=0
    
    # ========================================================================
    # REQUIRED VARIABLES - Must be set
    # ========================================================================
    
    info "Checking required variables..."
    
    validate_required_var "AWS_REGION" "$AWS_REGION" "AWS_REGION must be specified"
    validate_region "$AWS_REGION"
    
    validate_required_var "PROJECT_NAME" "$PROJECT_NAME" "PROJECT_NAME must be specified"
    if [[ ${#PROJECT_NAME} -gt 20 ]]; then
        warning "PROJECT_NAME is longer than 20 characters. May cause naming issues."
        ((VALIDATION_WARNINGS++))
    fi
    
    validate_required_var "ENVIRONMENT" "$ENVIRONMENT" "ENVIRONMENT must be specified (e.g., dev, staging, prod)"
    if [[ ! "$ENVIRONMENT" =~ ^(dev|development|staging|stage|prod|production)$ ]]; then
        warning "ENVIRONMENT should typically be: dev, staging, or prod. Got: $ENVIRONMENT"
        ((VALIDATION_WARNINGS++))
    fi
    
    # ========================================================================
    # AWS ACCOUNT & PROFILE
    # ========================================================================
    
    info "Checking AWS credentials..."
    
    if [[ -z "$AWS_ACCOUNT_ID" ]]; then
        warning "AWS_ACCOUNT_ID not set. Will attempt to fetch from AWS STS..."
        if command -v aws &> /dev/null; then
            AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
            if [[ -n "$AWS_ACCOUNT_ID" ]]; then
                success "AWS_ACCOUNT_ID auto-detected: $AWS_ACCOUNT_ID"
            else
                error "Failed to auto-detect AWS_ACCOUNT_ID. Set it manually or check AWS credentials."
                ((VALIDATION_ERRORS++))
            fi
        else
            error "AWS CLI not found. Cannot auto-detect AWS_ACCOUNT_ID."
            ((VALIDATION_ERRORS++))
        fi
    else
        if ! [[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
            error "AWS_ACCOUNT_ID must be a 12-digit number, got: $AWS_ACCOUNT_ID"
            ((VALIDATION_ERRORS++))
        fi
    fi
    
    # ========================================================================
    # NETWORK CONFIGURATION
    # ========================================================================
    
    info "Validating network configuration..."
    
    validate_cidr "VPC_CIDR" "$VPC_CIDR"
    
    # Validate availability zones
    validate_required_var "AVAILABILITY_ZONES" "$AVAILABILITY_ZONES"
    IFS=',' read -ra AZ_ARRAY <<< "$AVAILABILITY_ZONES"
    if [[ ${#AZ_ARRAY[@]} -lt 2 ]]; then
        warning "Less than 2 availability zones specified. Recommended: at least 2 for high availability"
        ((VALIDATION_WARNINGS++))
    fi
    
    # Validate subnet CIDRs
    validate_required_var "PUBLIC_SUBNET_CIDRS" "$PUBLIC_SUBNET_CIDRS"
    validate_required_var "PRIVATE_SUBNET_CIDRS" "$PRIVATE_SUBNET_CIDRS"
    
    IFS=',' read -ra PUBLIC_CIDRS <<< "$PUBLIC_SUBNET_CIDRS"
    IFS=',' read -ra PRIVATE_CIDRS <<< "$PRIVATE_SUBNET_CIDRS"
    
    if [[ ${#PUBLIC_CIDRS[@]} != ${#AZ_ARRAY[@]} ]]; then
        error "Number of PUBLIC_SUBNET_CIDRS (${#PUBLIC_CIDRS[@]}) must match AVAILABILITY_ZONES (${#AZ_ARRAY[@]})"
        ((VALIDATION_ERRORS++))
    fi
    
    if [[ ${#PRIVATE_CIDRS[@]} != ${#AZ_ARRAY[@]} ]]; then
        error "Number of PRIVATE_SUBNET_CIDRS (${#PRIVATE_CIDRS[@]}) must match AVAILABILITY_ZONES (${#AZ_ARRAY[@]})"
        ((VALIDATION_ERRORS++))
    fi
    
    # Validate each CIDR
    for cidr in "${PUBLIC_CIDRS[@]}"; do
        validate_cidr "PUBLIC_SUBNET_CIDR" "$cidr"
    done
    
    for cidr in "${PRIVATE_CIDRS[@]}"; do
        validate_cidr "PRIVATE_SUBNET_CIDR" "$cidr"
    done
    
    validate_boolean "ENABLE_NAT_GATEWAY" "$ENABLE_NAT_GATEWAY"
    validate_boolean "SINGLE_NAT_GATEWAY" "$SINGLE_NAT_GATEWAY"
    
    if [[ "$ENABLE_NAT_GATEWAY" == "false" ]]; then
        warning "NAT Gateway is disabled. Private subnets won't have internet access."
        ((VALIDATION_WARNINGS++))
    fi
    
    # ========================================================================
    # EKS CLUSTER CONFIGURATION
    # ========================================================================
    
    info "Validating EKS cluster configuration..."
    
    validate_eks_version "$EKS_VERSION"
    validate_boolean "OIDC_PROVIDER_ENABLED" "$OIDC_PROVIDER_ENABLED"
    validate_boolean "CLUSTER_ENDPOINT_PUBLIC_ACCESS" "$CLUSTER_ENDPOINT_PUBLIC_ACCESS"
    validate_boolean "CLUSTER_ENDPOINT_PRIVATE_ACCESS" "$CLUSTER_ENDPOINT_PRIVATE_ACCESS"
    
    if [[ "$CLUSTER_ENDPOINT_PUBLIC_ACCESS" == "false" ]] && [[ "$CLUSTER_ENDPOINT_PRIVATE_ACCESS" == "false" ]]; then
        error "Both public and private endpoint access cannot be disabled"
        ((VALIDATION_ERRORS++))
    fi
    
    if [[ "$ENVIRONMENT" == "prod" || "$ENVIRONMENT" == "production" ]] && [[ "$CLUSTER_ENDPOINT_PUBLIC_ACCESS" == "true" ]]; then
        warning "Production cluster has public endpoint access enabled. Consider using private-only for security."
        ((VALIDATION_WARNINGS++))
    fi
    
    validate_boolean "ENABLE_CLUSTER_ENCRYPTION" "$ENABLE_CLUSTER_ENCRYPTION"
    
    # ========================================================================
    # NODE GROUP CONFIGURATION
    # ========================================================================
    
    info "Validating node group configuration..."
    
    validate_number "NODE_MIN_SIZE" "$NODE_MIN_SIZE" 1 100
    validate_number "NODE_MAX_SIZE" "$NODE_MAX_SIZE" 1 1000
    validate_number "NODE_DESIRED_SIZE" "$NODE_DESIRED_SIZE" 1 1000
    
    if [[ $NODE_DESIRED_SIZE -lt $NODE_MIN_SIZE ]]; then
        error "NODE_DESIRED_SIZE ($NODE_DESIRED_SIZE) cannot be less than NODE_MIN_SIZE ($NODE_MIN_SIZE)"
        ((VALIDATION_ERRORS++))
    fi
    
    if [[ $NODE_DESIRED_SIZE -gt $NODE_MAX_SIZE ]]; then
        error "NODE_DESIRED_SIZE ($NODE_DESIRED_SIZE) cannot be greater than NODE_MAX_SIZE ($NODE_MAX_SIZE)"
        ((VALIDATION_ERRORS++))
    fi
    
    if [[ $NODE_MIN_SIZE -gt $NODE_MAX_SIZE ]]; then
        error "NODE_MIN_SIZE ($NODE_MIN_SIZE) cannot be greater than NODE_MAX_SIZE ($NODE_MAX_SIZE)"
        ((VALIDATION_ERRORS++))
    fi
    
    validate_number "NODE_DISK_SIZE" "$NODE_DISK_SIZE" 20 1000
    
    validate_boolean "ENABLE_SPOT_INSTANCES" "$ENABLE_SPOT_INSTANCES"
    
    if [[ "$ENABLE_SPOT_INSTANCES" == "true" ]] && [[ "$ENVIRONMENT" == "prod" || "$ENVIRONMENT" == "production" ]]; then
        warning "Spot instances enabled for production environment. Ensure critical workloads can handle interruptions."
        ((VALIDATION_WARNINGS++))
    fi
    
    if [[ "$NODE_AMI_TYPE" == "CUSTOM" ]] && [[ -z "$CUSTOM_AMI_ID" ]]; then
        error "CUSTOM_AMI_ID must be set when NODE_AMI_TYPE is CUSTOM"
        ((VALIDATION_ERRORS++))
    fi
    
    # ========================================================================
    # ECR CONFIGURATION
    # ========================================================================
    
    info "Validating ECR configuration..."
    
    validate_boolean "ECR_SCAN_ON_PUSH" "$ECR_SCAN_ON_PUSH"
    validate_number "ECR_LIFECYCLE_POLICY_DAYS" "$ECR_LIFECYCLE_POLICY_DAYS" 1 365
    validate_boolean "ECR_REPO_POLICY_ENABLED" "$ECR_REPO_POLICY_ENABLED"
    
    # ========================================================================
    # S3 CONFIGURATION
    # ========================================================================
    
    info "Validating S3 configuration..."
    
    validate_boolean "S3_VERSIONING_ENABLED" "$S3_VERSIONING_ENABLED"
    validate_boolean "S3_ENCRYPTION_ENABLED" "$S3_ENCRYPTION_ENABLED"
    validate_boolean "S3_BLOCK_PUBLIC_ACCESS" "$S3_BLOCK_PUBLIC_ACCESS"
    validate_number "S3_LIFECYCLE_DAYS" "$S3_LIFECYCLE_DAYS" 1 3650
    
    if [[ "$S3_BLOCK_PUBLIC_ACCESS" == "false" ]]; then
        warning "S3 bucket will allow public access. Ensure this is intentional."
        ((VALIDATION_WARNINGS++))
    fi
    
    # ========================================================================
    # MONITORING & OBSERVABILITY
    # ========================================================================
    
    info "Validating monitoring configuration..."
    
    validate_boolean "ENABLE_CLOUDWATCH_LOGS" "$ENABLE_CLOUDWATCH_LOGS"
    validate_boolean "ENABLE_PROMETHEUS" "$ENABLE_PROMETHEUS"
    
    if [[ -n "$ALERT_SLACK_WEBHOOK" ]] && [[ ! "$ALERT_SLACK_WEBHOOK" =~ ^https://hooks.slack.com/services/ ]]; then
        warning "ALERT_SLACK_WEBHOOK doesn't look like a valid Slack webhook URL"
        ((VALIDATION_WARNINGS++))
    fi
    
    if [[ -n "$ALERT_EMAIL" ]] && [[ ! "$ALERT_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        warning "ALERT_EMAIL doesn't look like a valid email address"
        ((VALIDATION_WARNINGS++))
    fi
    
    # ========================================================================
    # SECURITY & COMPLIANCE
    # ========================================================================
    
    info "Validating security configuration..."
    
    validate_boolean "ENABLE_POD_SECURITY" "$ENABLE_POD_SECURITY"
    validate_boolean "ENABLE_NETWORK_POLICIES" "$ENABLE_NETWORK_POLICIES"
    validate_boolean "ENABLE_AUDIT_REPORTS" "$ENABLE_AUDIT_REPORTS"
    
    if [[ "$ENVIRONMENT" == "prod" || "$ENVIRONMENT" == "production" ]]; then
        if [[ "$ENABLE_POD_SECURITY" == "false" ]]; then
            warning "Pod security is disabled for production environment"
            ((VALIDATION_WARNINGS++))
        fi
        if [[ "$ENABLE_CLUSTER_ENCRYPTION" == "false" ]]; then
            warning "Cluster encryption is disabled for production environment"
            ((VALIDATION_WARNINGS++))
        fi
    fi
    
    # ========================================================================
    # CI/CD CONFIGURATION
    # ========================================================================
    
    info "Validating CI/CD configuration..."
    
    if [[ -n "$GIT_REPO_URL" ]] && [[ ! "$GIT_REPO_URL" =~ ^(https?://|git@) ]]; then
        warning "GIT_REPO_URL doesn't look like a valid Git repository URL"
        ((VALIDATION_WARNINGS++))
    fi
    
    validate_boolean "ENABLE_CANARY" "$ENABLE_CANARY"
    
    # ========================================================================
    # SCRIPT BEHAVIOR
    # ========================================================================
    
    info "Validating script behavior settings..."
    
    validate_boolean "DRY_RUN" "$DRY_RUN"
    validate_boolean "AUTO_APPROVE" "$AUTO_APPROVE"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "DRY_RUN mode enabled - no resources will be created"
    fi
    
    if [[ -n "$RESOURCE_TTL_HOURS" ]]; then
        validate_number "RESOURCE_TTL_HOURS" "$RESOURCE_TTL_HOURS" 1 8760
        warning "RESOURCE_TTL_HOURS is set. Resources will be tagged for deletion after $RESOURCE_TTL_HOURS hours"
        ((VALIDATION_WARNINGS++))
    fi
    
    # ========================================================================
    # VALIDATION SUMMARY
    # ========================================================================
    
    echo ""
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${MAGENTA}  VALIDATION SUMMARY${NC}"
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    if [[ $VALIDATION_ERRORS -eq 0 ]] && [[ $VALIDATION_WARNINGS -eq 0 ]]; then
        success "All variables validated successfully! ✓"
        return 0
    elif [[ $VALIDATION_ERRORS -eq 0 ]]; then
        warning "Validation completed with $VALIDATION_WARNINGS warning(s)"
        echo ""
        log "You can proceed, but please review the warnings above."
        return 0
    else
        error "Validation failed with $VALIDATION_ERRORS error(s) and $VALIDATION_WARNINGS warning(s)"
        echo ""
        error "Please fix the errors above before proceeding."
        return 1
    fi
}

################################################################################
# DISPLAY CONFIGURATION
################################################################################

display_configuration() {
    section "CONFIGURATION SUMMARY"
    
    echo ""
    echo -e "${CYAN}Project Information:${NC}"
    echo "  Project Name:        $PROJECT_NAME"
    echo "  Environment:         $ENVIRONMENT"
    echo "  AWS Region:          $AWS_REGION"
    echo "  AWS Account ID:      ${AWS_ACCOUNT_ID:-<not set>}"
    echo ""
    
    echo -e "${CYAN}Network Configuration:${NC}"
    echo "  VPC CIDR:            $VPC_CIDR"
    echo "  Availability Zones:  $AVAILABILITY_ZONES"
    echo "  Public Subnets:      $PUBLIC_SUBNET_CIDRS"
    echo "  Private Subnets:     $PRIVATE_SUBNET_CIDRS"
    echo "  NAT Gateway:         $ENABLE_NAT_GATEWAY (Single: $SINGLE_NAT_GATEWAY)"
    echo ""
    
    echo -e "${CYAN}EKS Cluster:${NC}"
    echo "  Cluster Name:        $CLUSTER_NAME"
    echo "  Kubernetes Version:  $EKS_VERSION"
    echo "  Public Endpoint:     $CLUSTER_ENDPOINT_PUBLIC_ACCESS"
    echo "  Private Endpoint:    $CLUSTER_ENDPOINT_PRIVATE_ACCESS"
    echo "  Encryption:          $ENABLE_CLUSTER_ENCRYPTION"
    echo "  OIDC Provider:       $OIDC_PROVIDER_ENABLED"
    echo ""
    
    echo -e "${CYAN}Node Group:${NC}"
    echo "  Instance Type:       $NODE_INSTANCE_TYPE"
    echo "  Scaling:             Min=$NODE_MIN_SIZE, Desired=$NODE_DESIRED_SIZE, Max=$NODE_MAX_SIZE"
    echo "  Disk Size:           ${NODE_DISK_SIZE}GB ($NODE_VOLUME_TYPE)"
    echo "  Spot Instances:      $ENABLE_SPOT_INSTANCES"
    echo "  AMI Type:            $NODE_AMI_TYPE"
    echo ""
    
    echo -e "${CYAN}Container Registry:${NC}"
    echo "  ECR Repository:      $ECR_REPO_NAME"
    echo "  Scan on Push:        $ECR_SCAN_ON_PUSH"
    echo "  Lifecycle (days):    $ECR_LIFECYCLE_POLICY_DAYS"
    echo ""
    
    echo -e "${CYAN}S3 Bucket:${NC}"
    echo "  Bucket Name:         $S3_BUCKET_NAME"
    echo "  Purpose:             $S3_BUCKET_PURPOSE"
    echo "  Versioning:          $S3_VERSIONING_ENABLED"
    echo "  Encryption:          $S3_ENCRYPTION_ENABLED"
    echo "  Block Public Access: $S3_BLOCK_PUBLIC_ACCESS"
    echo ""
    
    echo -e "${CYAN}Monitoring:${NC}"
    echo "  CloudWatch Logs:     $ENABLE_CLOUDWATCH_LOGS"
    echo "  Prometheus:          $ENABLE_PROMETHEUS"
    echo "  Slack Alerts:        ${ALERT_SLACK_WEBHOOK:+Configured}"
    echo "  Email Alerts:        ${ALERT_EMAIL:-Not configured}"
    echo ""
    
    echo -e "${CYAN}Security:${NC}"
    echo "  Pod Security:        $ENABLE_POD_SECURITY"
    echo "  Network Policies:    $ENABLE_NETWORK_POLICIES"
    echo "  Audit Reports:       $ENABLE_AUDIT_REPORTS"
    echo "  Compliance:          $COMPLIANCE_STANDARD"
    echo ""
    
    echo -e "${CYAN}Script Settings:${NC}"
    echo "  Dry Run:             $DRY_RUN"
    echo "  Auto Approve:        $AUTO_APPROVE"
    echo "  Log Level:           $LOG_LEVEL"
    echo "  Log File:            $LOG_FILE"
    echo ""
}

################################################################################
# MAIN EXECUTION
################################################################################

main() {
    # Display header
    clear
    echo -e "${MAGENTA}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                                                               ║"
    echo "║     AWS Infrastructure Provisioning Script v2.0               ║"
    echo "║     Production-Grade EKS, VPC, ECR, and S3 Setup              ║"
    echo "║                                                               ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    
    # Validate all variables
    if ! validate_all_variables; then
        error "Variable validation failed. Exiting."
        exit 1
    fi
    
    # Display configuration
    display_configuration
    
    # Ask for confirmation if not auto-approved
    if [[ "$AUTO_APPROVE" != "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
        echo ""
        echo -e "${YELLOW}⚠️  WARNING: This will create AWS resources that will incur costs!${NC}"
        echo ""
        read -p "Do you want to proceed with infrastructure provisioning? (yes/no): " -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            log "Provisioning cancelled by user"
            exit 0
        fi
    fi
    
    success "Variable validation and configuration complete!"
    log "Ready to proceed with infrastructure provisioning..."
    
    # TODO: Continue with actual provisioning steps
    # This is where we'll add the VPC, ECR, S3, and EKS creation logic
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "DRY_RUN mode - skipping actual resource creation"
        exit 0
    fi
}

# Run main function
main "$@"