#!/usr/bin/env bash

set -euo pipefail

source utilities.sh
if [[ -z "${PROJECT_NAME:-}" ]]; then
    if [[ -f "variables.sh" ]]; then
        source variables.sh
    else
        echo "ERROR: variables.sh not found and required variables not set"
        exit 1
    fi
fi

EKS_CLUSTER_NAME=""
EKS_CLUSTER_ARN=""
EKS_CLUSTER_ENDPOINT=""
EKS_SERVICE_ROLE_ARN=""
NODE_GROUP_NAME=""


STATE_FILE="cloud-state-${PROJECT_NAME}-${ENVIRONMENT}.json"

function save_state() {
    local existing_state="{}"
    [[ -f "$STATE_FILE" ]] && existing_state=$(cat "$STATE_FILE")

    cat > "$STATE_FILE" <<EOF
{
  "project": "${PROJECT_NAME}",
  "environment": "${ENVIRONMENT}",
  "region": "${AWS_REGION}",
  "last_updated": "$(date -Iseconds)",
  "vpc": $(echo "$existing_state" | jq -c '.vpc // {}' 2>/dev/null || echo '{}'),
  "s3": $(echo "$existing_state" | jq -c '.s3 // {}' 2>/dev/null || echo '{}'),
  "ecr": $(echo "$existing_state" | jq -c '.ecr // {}' 2>/dev/null || echo '{}'),
  "eks": {
    "cluster_name": "${EKS_CLUSTER_NAME}",
    "cluster_arn": "${EKS_CLUSTER_ARN:-}",
    "cluster_endpoint": "${EKS_CLUSTER_ENDPOINT:-}",
    "service_role_arn": "${EKS_SERVICE_ROLE_ARN:-}",
    "node_group_name": "${NODE_GROUP_NAME:-}"
  }
}
EOF
    log "State saved to $STATE_FILE"
}


function check_prerequisites() {
    section "CHECKING PREREQUISITES"

    if command -v aws &> /dev/null; then
        success "AWS CLI is installed"
    else
        error "AWS CLI is not installed"
        exit 1
    fi

    if aws sts get-caller-identity --region "$AWS_REGION" &> /dev/null; then
        success "AWS credentials are valid"
        AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
        log "AWS Account ID: $AWS_ACCOUNT_ID"
    else
        error "AWS credentials are invalid or not configured"
        exit 1
    fi

    if [[ -f "vpc-exports.sh" ]]; then
        source vpc-exports.sh
        success "VPC configuration loaded"
        log "VPC ID: $VPC_ID"
    else
        error "VPC not found. Please run provision_vpc_resources.sh first"
        exit 1
    fi
    
    success "Configuration validation passed"
}

function create_eks_service_role() {
    section "CREATING EKS SERVICE ROLE"
    local role_name="${PROJECT_NAME}-${ENVIRONMENT}-eks-cluster-role"
    
    if aws iam get-role --role-name "$role_name" &>/dev/null; then
        log "IAM role already exists: $role_name"
        EKS_SERVICE_ROLE_ARN=$(aws iam get-role --role-name "$role_name" --query 'Role.Arn' --output text)
        log "Role ARN: $EKS_SERVICE_ROLE_ARN"
        return 0
    fi    
    log "Creating EKS service role: $role_name"

    local trust_policy='{
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Principal": {
                "Service": "eks.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }]
    }'
    EKS_SERVICE_ROLE_ARN=$(echo "$trust_policy" | aws iam create-role --role-name "$role_name" --assume-role-policy-document file:///dev/stdin --query 'Role.Arn' --output text)

    aws iam attach-role-policy --role-name "$role_name" --policy-arn "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
    aws iam attach-role-policy --role-name "$role_name" --policy-arn "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
    success "EKS service role created: $EKS_SERVICE_ROLE_ARN"
    save_state
}

function create_node_role() {
    section "CREATING NODE INSTANCE ROLE"
    local role_name="${PROJECT_NAME}-${ENVIRONMENT}-eks-node-role"
    if aws iam get-role --role-name "$role_name" &>/dev/null; then
        log "IAM role already exists: $role_name"
        NODE_INSTANCE_ROLE_ARN=$(aws iam get-role --role-name "$role_name" --query 'Role.Arn' --output text)
        log "Role ARN: $NODE_INSTANCE_ROLE_ARN"
        return 0
    fi    
    log "Creating EKS node role: $role_name"

    local trust_policy='{
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Principal": {
                "Service": "ec2.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }]
    }'

    NODE_INSTANCE_ROLE_ARN=$(echo "$trust_policy" | aws iam create-role --role-name "$role_name" --assume-role-policy-document file:///dev/stdin --query 'Role.Arn' --output text)
    
    # Attach required policies
    aws iam attach-role-policy --role-name "$role_name" --policy-arn "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
    aws iam attach-role-policy --role-name "$role_name" --policy-arn "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
    aws iam attach-role-policy --role-name "$role_name" --policy-arn "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
    success "Node instance role created: $NODE_INSTANCE_ROLE_ARN"
    save_state
}

function create_eks_cluster() {
    section "CREATING EKS CLUSTER"    
    EKS_CLUSTER_NAME="${PROJECT_NAME}-${ENVIRONMENT}-cluster"

    if aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" &>/dev/null; then
        warning "EKS cluster already exists: $EKS_CLUSTER_NAME"
        echo -n "Do you want to use the existing cluster? (yes/no): "
        read -r response
        
        if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            log "Using existing EKS cluster: $EKS_CLUSTER_NAME"
            load_existing_cluster
            return 0
        else
            error "Please use a different cluster name or delete the existing cluster"
            exit 1
        fi
    fi   
    log "Creating EKS cluster: $EKS_CLUSTER_NAME"
    log "This may take 10-15 minutes..."

    IFS=' ' read -ra SUBNET_ARRAY <<< "$PRIVATE_SUBNET_IDS"

    aws eks create-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --role-arn "$EKS_SERVICE_ROLE_ARN" --resources-vpc-config subnetIds="${SUBNET_ARRAY[0]}","${SUBNET_ARRAY[1]}" --kubernetes-version "$EKS_VERSION" --tags "Name=${EKS_CLUSTER_NAME},Project=${PROJECT_NAME},Environment=${ENVIRONMENT}" &>/dev/null    
    success "EKS cluster creation initiated"

    log "Waiting for cluster to become active..."
    aws eks wait cluster-active --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION"
    local cluster_info=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --output json)
    
    EKS_CLUSTER_ARN=$(echo "$cluster_info" | jq -r '.cluster.arn')
    EKS_CLUSTER_ENDPOINT=$(echo "$cluster_info" | jq -r '.cluster.endpoint')
    
    success "EKS cluster is now active"
    log "Cluster ARN: $EKS_CLUSTER_ARN"
    log "Cluster Endpoint: $EKS_CLUSTER_ENDPOINT"
    
    save_state
}

function load_existing_cluster() {
    log "Loading existing EKS cluster configuration..."
    local cluster_info=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --output json)

    EKS_CLUSTER_ARN=$(echo "$cluster_info" | jq -r '.cluster.arn')
    EKS_CLUSTER_ENDPOINT=$(echo "$cluster_info" | jq -r '.cluster.endpoint')
    log "Cluster ARN: $EKS_CLUSTER_ARN"
    log "Cluster Endpoint: $EKS_CLUSTER_ENDPOINT"
    save_state
    success "Loaded existing EKS cluster configuration"
}

function create_node_group() {
    section "CREATING MANAGED NODE GROUP"
    
    NODE_GROUP_NAME="${PROJECT_NAME}-${ENVIRONMENT}-nodegroup"

    if aws eks describe-nodegroup --cluster-name "$EKS_CLUSTER_NAME" --nodegroup-name "$NODE_GROUP_NAME" --region "$AWS_REGION" &>/dev/null; then
        log "Node group already exists: $NODE_GROUP_NAME"
        return 0
    fi
    
    log "Creating managed node group: $NODE_GROUP_NAME"
    log "This may take 5-10 minutes..."
    IFS=' ' read -ra SUBNET_ARRAY <<< "$PRIVATE_SUBNET_IDS"
    aws eks create-nodegroup --cluster-name "$EKS_CLUSTER_NAME" --nodegroup-name "$NODE_GROUP_NAME" --region "$AWS_REGION" --subnets "${SUBNET_ARRAY[0]}" "${SUBNET_ARRAY[1]}" --node-role "$NODE_INSTANCE_ROLE_ARN" --instance-types "$NODE_INSTANCE_TYPE" --scaling-config minSize="$NODE_MIN_SIZE",maxSize="$NODE_MAX_SIZE",desiredSize="$NODE_DESIRED_SIZE" --disk-size "$NODE_DISK_SIZE" --tags "Name=${NODE_GROUP_NAME},Project=${PROJECT_NAME},Environment=${ENVIRONMENT}" &>/dev/null    
    success "Node group creation initiated"

    log "Waiting for node group to become active..."
    aws eks wait nodegroup-active --cluster-name "$EKS_CLUSTER_NAME" --nodegroup-name "$NODE_GROUP_NAME" --region "$AWS_REGION"
    
    success "Node group is now active"
    save_state
}


function print_summary() {
    section "EKS CLUSTER CREATION SUMMARY"
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                EKS CLUSTER INFRASTRUCTURE                 ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Cluster Details:"
    echo "  Cluster Name:        $EKS_CLUSTER_NAME"
    echo "  Cluster ARN:         $EKS_CLUSTER_ARN"
    echo "  Cluster Endpoint:    $EKS_CLUSTER_ENDPOINT"
    echo "  Kubernetes Version:  $EKS_VERSION"
    echo "  Region:              $AWS_REGION"
    echo ""
    echo "Node Group:"
    echo "  Node Group Name:     $NODE_GROUP_NAME"
    echo "  Instance Type:       $NODE_INSTANCE_TYPE"
    echo "  Desired Capacity:    $NODE_DESIRED_SIZE"
    echo "  Min Size:            $NODE_MIN_SIZE"
    echo "  Max Size:            $NODE_MAX_SIZE"
    echo ""
    echo "IAM Roles:"
    echo "  Service Role:        $EKS_SERVICE_ROLE_ARN"
    echo "  Node Role:           $NODE_INSTANCE_ROLE_ARN"
    echo ""
    echo "Configure kubectl:"
    echo "  aws eks update-kubeconfig --region $AWS_REGION --name $EKS_CLUSTER_NAME"
    echo ""
    echo "Verify cluster:"
    echo "  kubectl get nodes"
    echo "  kubectl get pods -A"
    echo ""
    echo "State File:"
    echo "  Location:            $STATE_FILE"
    echo ""
    echo "Log File:"
    echo "  Location:            $LOG_FILE"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Export variables
    cat > "eks-exports.sh" <<EOF
#!/bin/bash
# EKS Exports - Source this file to use EKS resources in other scripts
export EKS_CLUSTER_NAME="$EKS_CLUSTER_NAME"
export EKS_CLUSTER_ARN="$EKS_CLUSTER_ARN"
export EKS_CLUSTER_ENDPOINT="$EKS_CLUSTER_ENDPOINT"
export EKS_REGION="$AWS_REGION"
EOF
    chmod +x eks-exports.sh
    success "Export file created: eks-exports.sh"
}

function main() {
    LOG_FILE="aws-eks-provision-$(date +%Y%m%d%H%M%S).log"
    
    log "Starting EKS cluster creation process..."
    log "Project: $PROJECT_NAME | Environment: $ENVIRONMENT | Region: $AWS_REGION"
    echo ""
    
    check_prerequisites
    create_eks_service_role
    create_node_role
    create_eks_cluster
    create_node_group
    
    print_summary
    
    success "EKS cluster provisioning completed successfully!"
    log "Run: aws eks update-kubeconfig --region $AWS_REGION --name $EKS_CLUSTER_NAME"
}

# Execute main function
main
