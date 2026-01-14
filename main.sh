#!/usr/bin/env bash


set -euo pipefail


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/utilities.sh" ]]; then
    source "${SCRIPT_DIR}/utilities.sh"
else
    echo "ERROR: utilities.sh not found"
    exit 1
fi

if [[ -f "${SCRIPT_DIR}/variables.sh" ]]; then
    source "${SCRIPT_DIR}/variables.sh"
else
    echo "ERROR: variables.sh not found"
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

LOG_FILE="aws-main-provision-$(date +%Y%m%d%H%M%S).log"
PROVISION_VPC=true
PROVISION_S3=true
PROVISION_ECR=true
PROVISION_EKS=false  # Default to false as EKS takes long time

START_TIME=$(date +%s)
declare -a COMPLETED_STEPS=()
declare -a FAILED_STEPS=()


function print_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                    ║"
    echo "║        AWS INFRASTRUCTURE PROVISIONING ORCHESTRATOR v2.0           ║"
    echo "║                                                                    ║"
    echo "║  Automated provisioning of VPC, S3, ECR, and EKS resources         ║"
    echo "║                                                                    ║"
    echo "╔════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
}

function print_configuration() {
    section "CONFIGURATION OVERVIEW"
    
    echo ""
    echo -e "${BOLD}Project Details:${NC}"
    echo "  Project Name:        $PROJECT_NAME"
    echo "  Environment:         $ENVIRONMENT"
    echo "  AWS Region:          $AWS_REGION"
    echo "  AWS Account ID:      $(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo 'Not available')"
    echo ""
    echo -e "${BOLD}Resources to Provision:${NC}"
    echo "  [$(if $PROVISION_VPC; then echo -e "${GREEN}✓${NC}"; else echo -e "${YELLOW}○${NC}"; fi)] VPC and Networking"
    echo "  [$(if $PROVISION_S3; then echo -e "${GREEN}✓${NC}"; else echo -e "${YELLOW}○${NC}"; fi)] S3 Bucket"
    echo "  [$(if $PROVISION_ECR; then echo -e "${GREEN}✓${NC}"; else echo -e "${YELLOW}○${NC}"; fi)] ECR Repository"
    echo "  [$(if $PROVISION_EKS; then echo -e "${GREEN}✓${NC}"; else echo -e "${YELLOW}○${NC}"; fi)] EKS Cluster (takes 15-20 min)"
    echo ""
}

function show_menu() {
    print_banner
    
    echo -e "${BOLD}Select resources to provision:${NC}"
    echo ""
    echo "  1) All resources (VPC + S3 + ECR + EKS)"
    echo "  2) Core infrastructure only (VPC + S3 + ECR)"
    echo "  3) VPC only"
    echo "  4) Custom selection"
    echo "  5) Exit"
    echo ""
    read -p "Enter your choice [1-5]: " choice
    echo ""
    
    case $choice in
        1)
            PROVISION_VPC=true
            PROVISION_S3=true
            PROVISION_ECR=true
            PROVISION_EKS=true
            ;;
        2)
            PROVISION_VPC=true
            PROVISION_S3=true
            PROVISION_ECR=true
            PROVISION_EKS=false
            ;;
        3)
            PROVISION_VPC=true
            PROVISION_S3=false
            PROVISION_ECR=false
            PROVISION_EKS=false
            ;;
        4)
            custom_selection
            ;;
        5)
            log "Exiting..."
            exit 0
            ;;
        *)
            error "Invalid choice. Using default (Core infrastructure only)"
            PROVISION_VPC=true
            PROVISION_S3=true
            PROVISION_ECR=true
            PROVISION_EKS=false
            ;;
    esac
}

function custom_selection() {
    echo -e "${BOLD}Custom Resource Selection:${NC}"
    echo ""
    
    read -p "Provision VPC? (y/n) [y]: " vpc_choice
    PROVISION_VPC=$(if [[ "$vpc_choice" =~ ^[Nn]$ ]]; then echo false; else echo true; fi)
    
    read -p "Provision S3? (y/n) [y]: " s3_choice
    PROVISION_S3=$(if [[ "$s3_choice" =~ ^[Nn]$ ]]; then echo false; else echo true; fi)
    
    read -p "Provision ECR? (y/n) [y]: " ecr_choice
    PROVISION_ECR=$(if [[ "$ecr_choice" =~ ^[Nn]$ ]]; then echo false; else echo true; fi)
    
    read -p "Provision EKS? (y/n) [n]: " eks_choice
    PROVISION_EKS=$(if [[ "$eks_choice" =~ ^[Yy]$ ]]; then echo true; else echo false; fi)
    
    echo ""
}

function confirm_execution() {
    print_configuration
    
    echo -e "${YELLOW}${BOLD} IMPORTANT NOTES:${NC}"
    echo ""
    if $PROVISION_EKS; then
        echo "  • EKS cluster creation takes 15-20 minutes"
        echo "  • EKS will incur ongoing charges even when idle"
    fi
    echo "  • NAT Gateway (VPC) costs ~\$0.045/hour (~\$32/month)"
    echo "  • S3 and ECR have minimal costs for storage only"
    echo ""

    read -p "Do you want to proceed? (yes/no): " -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log "Provisioning cancelled by user"
        exit 0
    fi

    log "User confirmed provisioning"
}

function execute_script() {
    local script_name=$1
    local resource_name=$2
    
    section "PROVISIONING: $resource_name"
    
    log "Executing: $script_name"
    
    if [[ ! -f "${SCRIPT_DIR}/${script_name}" ]]; then
        error "Script not found: $script_name"
        FAILED_STEPS+=("$resource_name")
        return 1
    fi
    
    if ! chmod +x "${SCRIPT_DIR}/${script_name}"; then
        error "Failed to make script executable: $script_name"
        FAILED_STEPS+=("$resource_name")
        return 1
    fi
    
    echo ""
    if "${SCRIPT_DIR}/${script_name}" 2>&1 | tee -a "$LOG_FILE"; then
        success "$resource_name provisioned successfully"
        COMPLETED_STEPS+=("$resource_name")
        return 0
    else
        error "$resource_name provisioning failed"
        FAILED_STEPS+=("$resource_name")
        return 1
    fi
}


function provision_vpc() {
    if ! $PROVISION_VPC; then
        log "Skipping VPC provisioning"
        return 0
    fi
    
    execute_script "provision_vpc_resources.sh" "VPC" || {
        error "VPC provisioning failed. Cannot continue."
        exit 1
    }
}

function provision_s3() {
    if ! $PROVISION_S3; then
        log "Skipping S3 provisioning"
        return 0
    fi
    
    execute_script "provision_s3_resources.sh" "S3"
}

function provision_ecr() {
    if ! $PROVISION_ECR; then
        log "Skipping ECR provisioning"
        return 0
    fi
    
    execute_script "provision_ecr_resources.sh" "ECR"
}

function provision_eks() {
    if ! $PROVISION_EKS; then
        log "Skipping EKS provisioning"
        return 0
    fi

    if [[ ! -f "${SCRIPT_DIR}/vpc-exports.sh" ]]; then
        error "VPC not found. EKS requires VPC to be provisioned first."
        FAILED_STEPS+=("EKS")
        return 1
    fi

    warning "EKS cluster creation will take approximately 15-20 minutes"
    read -p "Continue with EKS provisioning? (yes/no): " -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log "EKS provisioning skipped by user"
        return 0
    fi

    execute_script "provision_eks_resources.sh" "EKS"
}


function print_summary() {
    local end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))
    
    section "PROVISIONING SUMMARY"
    
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                                                            ║${NC}"
    echo -e "${CYAN}║            INFRASTRUCTURE PROVISIONING COMPLETE            ║${NC}"
    echo -e "${CYAN}║                                                            ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    if [[ ${#COMPLETED_STEPS[@]} -gt 0 ]]; then
        echo -e "${GREEN}${BOLD}✓ Successfully Provisioned:${NC}"
        for step in "${COMPLETED_STEPS[@]}"; do
            echo -e "  ${GREEN}✓${NC} $step"
        done
        echo ""
    fi
    
    if [[ ${#FAILED_STEPS[@]} -gt 0 ]]; then
        echo -e "${RED}${BOLD}✗ Failed:${NC}"
        for step in "${FAILED_STEPS[@]}"; do
            echo -e "  ${RED}✗${NC} $step"
        done
        echo ""
    fi
    
    echo -e "${BOLD}Execution Details:${NC}"
    echo "  Duration:            ${minutes}m ${seconds}s"
    echo "  Log File:            $LOG_FILE"
    echo ""
    
    if [[ -f "${SCRIPT_DIR}/vpc-exports.sh" ]]; then
        echo -e "${BOLD}Created Export Files:${NC}"
        [[ -f "${SCRIPT_DIR}/vpc-exports.sh" ]] && echo "  • vpc-exports.sh"
        [[ -f "${SCRIPT_DIR}/s3-exports.sh" ]] && echo "  • s3-exports.sh"
        [[ -f "${SCRIPT_DIR}/ecr-exports.sh" ]] && echo "  • ecr-exports.sh"
        [[ -f "${SCRIPT_DIR}/eks-exports.sh" ]] && echo "  • eks-exports.sh"
        echo ""
    fi
    
    if [[ -f "${SCRIPT_DIR}/eks-exports.sh" ]]; then
        echo -e "${BOLD}Next Steps:${NC}"
        echo "  Configure kubectl:"
        echo "    source eks-exports.sh"
        echo "    aws eks update-kubeconfig --region $AWS_REGION --name \$EKS_CLUSTER_NAME"
        echo ""
        echo "  Verify cluster:"
        echo "    kubectl get nodes"
        echo "    kubectl get pods -A"
        echo ""
    fi
    
    if [[ ${#FAILED_STEPS[@]} -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}All selected resources provisioned successfully!${NC}"
    else
        echo -e "${YELLOW}${BOLD}Some resources failed to provision. Check the log file for details.${NC}"
    fi
    echo ""
}

function print_resource_info() {
    section "PROVISIONED RESOURCES"
    
    echo ""
    
    # VPC Info
    if [[ -f "${SCRIPT_DIR}/vpc-exports.sh" ]]; then
        source "${SCRIPT_DIR}/vpc-exports.sh"
        echo -e "${CYAN}${BOLD}VPC Resources:${NC}"
        echo "  VPC ID:              $VPC_ID"
        echo "  Public Subnets:      $PUBLIC_SUBNET_IDS"
        echo "  Private Subnets:     $PRIVATE_SUBNET_IDS"
        echo ""
    fi
    
    # S3 Info
    if [[ -f "${SCRIPT_DIR}/s3-exports.sh" ]]; then
        source "${SCRIPT_DIR}/s3-exports.sh"
        echo -e "${CYAN}${BOLD}S3 Resources:${NC}"
        echo "  Bucket Name:         $S3_BUCKET_NAME"
        echo "  Bucket ARN:          $S3_BUCKET_ARN"
        echo ""
    fi
    
    # ECR Info
    if [[ -f "${SCRIPT_DIR}/ecr-exports.sh" ]]; then
        source "${SCRIPT_DIR}/ecr-exports.sh"
        echo -e "${CYAN}${BOLD}ECR Resources:${NC}"
        echo "  Repository Name:     $ECR_REPOSITORY_NAME"
        echo "  Repository URI:      $ECR_REPOSITORY_URI"
        echo ""
    fi
    
    # EKS Info
    if [[ -f "${SCRIPT_DIR}/eks-exports.sh" ]]; then
        source "${SCRIPT_DIR}/eks-exports.sh"
        echo -e "${CYAN}${BOLD}EKS Resources:${NC}"
        echo "  Cluster Name:        $EKS_CLUSTER_NAME"
        echo "  Cluster Endpoint:    $EKS_CLUSTER_ENDPOINT"
        echo ""
    fi
}

function main() {
    print_banner
    
    log "Starting AWS infrastructure provisioning orchestrator..."
    log "Project: $PROJECT_NAME | Environment: $ENVIRONMENT | Region: $AWS_REGION"
    echo ""
    show_menu
    confirm_execution
    log "Starting provisioning process..."
    echo ""
    
    provision_vpc
    provision_s3
    provision_ecr
    provision_eks
    print_resource_info
    print_summary
    
    if [[ ${#FAILED_STEPS[@]} -eq 0 ]]; then
        success "Infrastructure provisioning completed successfully!"
        exit 0
    else
        warning "Infrastructure provisioning completed with some failures"
        exit 1
    fi
}

trap 'echo ""; error "Script interrupted by user"; exit 130' INT TERM

main "$@"
