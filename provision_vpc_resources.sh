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


VPC_ID=""
IGW_ID=""
declare -a PUBLIC_SUBNET_IDS=()
declare -a PRIVATE_SUBNET_IDS=()
declare -a NAT_GATEWAY_IDS=()
declare -a EIP_ALLOCATION_IDS=()
PUBLIC_ROUTE_TABLE_ID=""
declare -a PRIVATE_ROUTE_TABLE_IDS=()

# Unified state file
STATE_FILE="cloud-state-${PROJECT_NAME}-${ENVIRONMENT}.json"



save_state() {
    local public_subnets_json=""
    if [[ ${#PUBLIC_SUBNET_IDS[@]} -gt 0 ]]; then
        public_subnets_json=$(printf '"%s",' "${PUBLIC_SUBNET_IDS[@]}" | sed 's/,$//')
    fi
    
    local private_subnets_json=""
    if [[ ${#PRIVATE_SUBNET_IDS[@]} -gt 0 ]]; then
        private_subnets_json=$(printf '"%s",' "${PRIVATE_SUBNET_IDS[@]}" | sed 's/,$//')
    fi
    
    local nat_gateways_json=""
    if [[ ${#NAT_GATEWAY_IDS[@]} -gt 0 ]]; then
        nat_gateways_json=$(printf '"%s",' "${NAT_GATEWAY_IDS[@]}" | sed 's/,$//')
    fi
    
    local eip_allocs_json=""
    if [[ ${#EIP_ALLOCATION_IDS[@]} -gt 0 ]]; then
        eip_allocs_json=$(printf '"%s",' "${EIP_ALLOCATION_IDS[@]}" | sed 's/,$//')
    fi
    
    local private_rts_json=""
    if [[ ${#PRIVATE_ROUTE_TABLE_IDS[@]} -gt 0 ]]; then
        private_rts_json=$(printf '"%s",' "${PRIVATE_ROUTE_TABLE_IDS[@]}" | sed 's/,$//')
    fi
    
    # Read existing state or create new
    local existing_state="{}"
    if [[ -f "$STATE_FILE" ]]; then
        existing_state=$(cat "$STATE_FILE")
    fi
    
    # Update VPC section in state
    cat > "$STATE_FILE" <<EOF
{
  "project": "${PROJECT_NAME}",
  "environment": "${ENVIRONMENT}",
  "region": "${AWS_REGION}",
  "last_updated": "$(date -Iseconds)",
  "vpc": {
    "vpc_id": "${VPC_ID}",
    "igw_id": "${IGW_ID}",
    "public_subnet_ids": [${public_subnets_json}],
    "private_subnet_ids": [${private_subnets_json}],
    "nat_gateway_ids": [${nat_gateways_json}],
    "eip_allocation_ids": [${eip_allocs_json}],
    "public_route_table_id": "${PUBLIC_ROUTE_TABLE_ID}",
    "private_route_table_ids": [${private_rts_json}]
  },
  "s3": $(echo "$existing_state" | jq -c '.s3 // {}' 2>/dev/null || echo '{}'),
  "ecr": $(echo "$existing_state" | jq -c '.ecr // {}' 2>/dev/null || echo '{}'),
  "eks": $(echo "$existing_state" | jq -c '.eks // {}' 2>/dev/null || echo '{}')
}
EOF
    log "State saved to $STATE_FILE"
}


cleanup_on_error() {
    error "An error occurred during VPC creation. Initiating rollback..."

    for rt_id in "${PRIVATE_ROUTE_TABLE_IDS[@]}"; do
        if [[ -n "$rt_id" ]]; then
            warning "Deleting private route table: $rt_id"
            aws ec2 delete-route-table --route-table-id "$rt_id" --region "$AWS_REGION" 2>/dev/null || true
        fi
    done

    if [[ -n "$PUBLIC_ROUTE_TABLE_ID" ]]; then
        warning "Deleting public route table: $PUBLIC_ROUTE_TABLE_ID"
        aws ec2 delete-route-table --route-table-id "$PUBLIC_ROUTE_TABLE_ID" --region "$AWS_REGION" 2>/dev/null || true
    fi

    for nat_id in "${NAT_GATEWAY_IDS[@]}"; do
        if [[ -n "$nat_id" ]]; then
            warning "Deleting NAT gateway: $nat_id"
            aws ec2 delete-nat-gateway --nat-gateway-id "$nat_id" --region "$AWS_REGION" 2>/dev/null || true
        fi
    done

    if [[ ${#NAT_GATEWAY_IDS[@]} -gt 0 ]]; then
        warning "Waiting 30 seconds for NAT gateways to delete..."
        sleep 30
    fi

    for eip_id in "${EIP_ALLOCATION_IDS[@]}"; do
        if [[ -n "$eip_id" ]]; then
            warning "Releasing Elastic IP: $eip_id"
            aws ec2 release-address --allocation-id "$eip_id" --region "$AWS_REGION" 2>/dev/null || true
        fi
    done

    for subnet_id in "${PUBLIC_SUBNET_IDS[@]}" "${PRIVATE_SUBNET_IDS[@]}"; do
        if [[ -n "$subnet_id" ]]; then
            warning "Deleting subnet: $subnet_id"
            aws ec2 delete-subnet --subnet-id "$subnet_id" --region "$AWS_REGION" 2>/dev/null || true
        fi
    done

    if [[ -n "$IGW_ID" ]] && [[ -n "$VPC_ID" ]]; then
        warning "Detaching internet gateway: $IGW_ID"
        aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$AWS_REGION" 2>/dev/null || true
        warning "Deleting internet gateway: $IGW_ID"
        aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region "$AWS_REGION" 2>/dev/null || true
    fi

    if [[ -n "$VPC_ID" ]]; then
        warning "Deleting VPC: $VPC_ID"
        aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$AWS_REGION" 2>/dev/null || true
    fi
    
    error "Rollback completed. Check logs for details: $LOG_FILE"
    exit 1
}

# Set trap for cleanup
trap cleanup_on_error ERR


check_prerequisites() {
    section "CHECKING PREREQUISITES"
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        error "AWS CLI is not installed"
        exit 1
    fi
    success "AWS CLI is installed"
    
    if ! aws sts get-caller-identity --region "$AWS_REGION" &> /dev/null; then
        error "AWS credentials not configured or invalid"
        exit 1
    fi
    success "AWS credentials are valid"
    
    # Get AWS Account ID if not set
    if [[ -z "${AWS_ACCOUNT_ID:-}" ]]; then
        AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION")
        export AWS_ACCOUNT_ID
        log "AWS Account ID: $AWS_ACCOUNT_ID"
    fi
    
    # Check if jq is available (optional but helpful)
    if command -v jq &> /dev/null; then
        success "jq is available for JSON parsing"
    else
        warning "jq not found - JSON parsing will use basic methods"
    fi
    
    # Validate required variables
    local required_vars=(
        "AWS_REGION"
        "PROJECT_NAME"
        "ENVIRONMENT"
        "VPC_CIDR"
        "AVAILABILITY_ZONES"
        "PUBLIC_SUBNET_CIDRS"
        "PRIVATE_SUBNET_CIDRS"
    )
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            error "Required variable $var is not set"
            exit 1
        fi
    done
    success "All required variables are set"
    
    # Parse arrays
    IFS=',' read -ra AZ_ARRAY <<< "$AVAILABILITY_ZONES"
    IFS=',' read -ra PUBLIC_CIDRS <<< "$PUBLIC_SUBNET_CIDRS"
    IFS=',' read -ra PRIVATE_CIDRS <<< "$PRIVATE_SUBNET_CIDRS"
    
    # Validate array lengths match
    if [[ ${#PUBLIC_CIDRS[@]} != ${#AZ_ARRAY[@]} ]]; then
        error "Number of public subnet CIDRs (${#PUBLIC_CIDRS[@]}) must match availability zones (${#AZ_ARRAY[@]})"
        exit 1
    fi
    
    if [[ ${#PRIVATE_CIDRS[@]} != ${#AZ_ARRAY[@]} ]]; then
        error "Number of private subnet CIDRs (${#PRIVATE_CIDRS[@]}) must match availability zones (${#AZ_ARRAY[@]})"
        exit 1
    fi
    
    success "Configuration validation passed"
}

################################################################################
# VPC CREATION FUNCTIONS
################################################################################

check_existing_vpc() {
    section "CHECKING FOR EXISTING VPC"
    
    local vpc_name="${PROJECT_NAME}-${ENVIRONMENT}-vpc"
    
    local existing_vpc=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$vpc_name" --region "$AWS_REGION" --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "None")
    
    if [[ "$existing_vpc" != "None" ]] && [[ -n "$existing_vpc" ]]; then
        warning "VPC with name '$vpc_name' already exists: $existing_vpc"
        read -p "Do you want to use the existing VPC? (yes/no): " -r
        if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            VPC_ID="$existing_vpc"
            log "Using existing VPC: $VPC_ID"
            load_existing_vpc_resources
            complete_missing_resources
            return 0
        else
            error "Please delete the existing VPC or use a different project/environment name"
            exit 1
        fi
    fi
    
    log "No existing VPC found. Will create new VPC."
}

load_existing_vpc_resources() {
    log "Loading existing VPC resources..."
    
    # Load Internet Gateway
    IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --region "$AWS_REGION" --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null || echo "")
    
    if [[ -n "$IGW_ID" && "$IGW_ID" != "None" ]]; then
        log "Found Internet Gateway: $IGW_ID"
    else
        warning "No Internet Gateway found for VPC"
    fi
    
    # Load Public Subnets
    local public_subnet_ids=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Type,Values=public" --region "$AWS_REGION" --query 'Subnets[].SubnetId' --output text 2>/dev/null || echo "")
    
    if [[ -n "$public_subnet_ids" ]]; then
        read -ra PUBLIC_SUBNET_IDS <<< "$public_subnet_ids"
        log "Found ${#PUBLIC_SUBNET_IDS[@]} public subnet(s)"
    else
        warning "No public subnets found"
    fi
    
    # Load Private Subnets
    local private_subnet_ids=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Type,Values=private" --region "$AWS_REGION" --query 'Subnets[].SubnetId' --output text 2>/dev/null || echo "")
    
    if [[ -n "$private_subnet_ids" ]]; then
        read -ra PRIVATE_SUBNET_IDS <<< "$private_subnet_ids"
        log "Found ${#PRIVATE_SUBNET_IDS[@]} private subnet(s)"
    else
        warning "No private subnets found"
    fi
    
    # Load NAT Gateways
    local nat_gateway_ids=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available" --region "$AWS_REGION" --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null || echo "")
    
    if [[ -n "$nat_gateway_ids" ]]; then
        read -ra NAT_GATEWAY_IDS <<< "$nat_gateway_ids"
        log "Found ${#NAT_GATEWAY_IDS[@]} NAT Gateway(s)"
        
        # Load EIP allocations for NAT Gateways
        for nat_id in "${NAT_GATEWAY_IDS[@]}"; do
            local eip_id=$(aws ec2 describe-nat-gateways --nat-gateway-ids "$nat_id" --region "$AWS_REGION" --query 'NatGateways[0].NatGatewayAddresses[0].AllocationId' --output text 2>/dev/null || echo "")
            if [[ -n "$eip_id" && "$eip_id" != "None" ]]; then
                EIP_ALLOCATION_IDS+=("$eip_id")
            fi
        done
    else
        warning "No NAT Gateways found"
    fi
    
    # Load Public Route Table
    PUBLIC_ROUTE_TABLE_ID=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Type,Values=public" --region "$AWS_REGION" --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || echo "")
    
    if [[ -n "$PUBLIC_ROUTE_TABLE_ID" && "$PUBLIC_ROUTE_TABLE_ID" != "None" ]]; then
        log "Found public route table: $PUBLIC_ROUTE_TABLE_ID"
    else
        warning "No public route table found"
    fi
    
    # Load Private Route Tables
    local private_rt_ids=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Type,Values=private" --region "$AWS_REGION" --query 'RouteTables[].RouteTableId' --output text 2>/dev/null || echo "")
    
    if [[ -n "$private_rt_ids" ]]; then
        read -ra PRIVATE_ROUTE_TABLE_IDS <<< "$private_rt_ids"
        log "Found ${#PRIVATE_ROUTE_TABLE_IDS[@]} private route table(s)"
    else
        warning "No private route tables found"
    fi
    
    # Save state with loaded resources
    save_state
    
    success "Loaded existing VPC resources"
}

complete_missing_resources() {
    section "COMPLETING MISSING RESOURCES"
    
    local needs_creation=false
    
    # Check what's missing
    if [[ -z "$IGW_ID" ]]; then
        warning "Internet Gateway is missing"
        needs_creation=true
    fi
    
    if [[ ${#PUBLIC_SUBNET_IDS[@]} -eq 0 ]] || [[ ${#PRIVATE_SUBNET_IDS[@]} -eq 0 ]]; then
        warning "Subnets are missing"
        needs_creation=true
    fi
    
    if [[ -z "$PUBLIC_ROUTE_TABLE_ID" ]] || [[ ${#PRIVATE_ROUTE_TABLE_IDS[@]} -eq 0 ]]; then
        warning "Route tables are missing"
        needs_creation=true
    fi
    
    if [[ "$needs_creation" == "true" ]]; then
        echo ""
        log "Some VPC resources are incomplete or missing."
        read -p "Do you want to create the missing resources? (yes/no): " -r
        echo ""
        
        if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            log "Creating missing resources..."
            
            # Create IGW if missing
            if [[ -z "$IGW_ID" ]]; then
                create_internet_gateway
            fi
            
            # Create subnets if missing
            if [[ ${#PUBLIC_SUBNET_IDS[@]} -eq 0 ]] || [[ ${#PRIVATE_SUBNET_IDS[@]} -eq 0 ]]; then
                create_subnets
            fi
            
            # Create NAT gateways if needed and missing
            if [[ "${ENABLE_NAT_GATEWAY}" == "true" ]] && [[ ${#NAT_GATEWAY_IDS[@]} -eq 0 ]]; then
                create_nat_gateways
            fi
            
            # Create route tables if missing
            if [[ -z "$PUBLIC_ROUTE_TABLE_ID" ]] || [[ ${#PRIVATE_ROUTE_TABLE_IDS[@]} -eq 0 ]]; then
                create_route_tables
            fi
            
            success "Missing resources created successfully"
        else
            warning "Proceeding with incomplete VPC setup"
        fi
    else
        success "VPC has all required resources"
    fi
}

create_vpc() {
    section "CREATING VPC"
    
    local vpc_name="${PROJECT_NAME}-${ENVIRONMENT}-vpc"
    
    log "Creating VPC with CIDR: $VPC_CIDR"
    
    VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" --region "$AWS_REGION" \
        --tag-specifications "ResourceType=vpc,Tags=[
            {Key=Name,Value=$vpc_name},
            {Key=Environment,Value=$ENVIRONMENT},
            {Key=Project,Value=$PROJECT_NAME},
            {Key=ManagedBy,Value=terraform-script},
            {Key=CreatedAt,Value=$(date -Iseconds)}
        ]" --query 'Vpc.VpcId' --output text 2>> "$LOG_FILE")
    
    if [[ -z "$VPC_ID" ]]; then
        error "Failed to create VPC"
        exit 1
    fi
    
    success "VPC created: $VPC_ID"
    save_state
    
    # Wait for VPC to be available
    log "Waiting for VPC to become available..."
    aws ec2 wait vpc-available --vpc-ids "$VPC_ID" --region "$AWS_REGION" 2>> "$LOG_FILE" || true
    
    # Enable DNS support
    log "Enabling DNS support..."
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support --region "$AWS_REGION" 2>> "$LOG_FILE"
    
    # Enable DNS hostnames
    log "Enabling DNS hostnames..."
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames --region "$AWS_REGION" 2>> "$LOG_FILE"
    
    success "VPC DNS settings configured"
    
    # Add Name tag separately for better visibility
    aws ec2 create-tags --resources "$VPC_ID" --tags "Key=Name,Value=$vpc_name" --region "$AWS_REGION" 2>> "$LOG_FILE" || true
}

create_internet_gateway() {
    section "CREATING INTERNET GATEWAY"
    
    local igw_name="${PROJECT_NAME}-${ENVIRONMENT}-igw"
    
    log "Creating Internet Gateway..."
    
    IGW_ID=$(aws ec2 create-internet-gateway --region "$AWS_REGION" \
        --tag-specifications "ResourceType=internet-gateway,Tags=[
            {Key=Name,Value=$igw_name},
            {Key=Environment,Value=$ENVIRONMENT},
            {Key=Project,Value=$PROJECT_NAME}
        ]" --query 'InternetGateway.InternetGatewayId' --output text 2>> "$LOG_FILE")
    
    if [[ -z "$IGW_ID" ]]; then
        error "Failed to create Internet Gateway"
        exit 1
    fi
    
    success "Internet Gateway created: $IGW_ID"
    save_state
    
    # Attach to VPC with retry logic
    log "Attaching Internet Gateway to VPC..."
    local max_retries=3
    local retry_count=0
    
    while [[ $retry_count -lt $max_retries ]]; do
        if aws ec2 attach-internet-gateway --vpc-id "$VPC_ID" --internet-gateway-id "$IGW_ID" --region "$AWS_REGION" 2>> "$LOG_FILE"; then
            success "Internet Gateway attached to VPC"
            return 0
        else
            ((retry_count++))
            if [[ $retry_count -lt $max_retries ]]; then
                warning "Failed to attach IGW (attempt $retry_count/$max_retries). Retrying in 5 seconds..."
                sleep 5
            fi
        fi
    done
    
    error "Failed to attach Internet Gateway after $max_retries attempts"
    exit 1
}

create_subnets() {
    section "CREATING SUBNETS"
    
    IFS=',' read -ra AZ_ARRAY <<< "$AVAILABILITY_ZONES"
    IFS=',' read -ra PUBLIC_CIDRS <<< "$PUBLIC_SUBNET_CIDRS"
    IFS=',' read -ra PRIVATE_CIDRS <<< "$PRIVATE_SUBNET_CIDRS"
    
    log "Creating subnets in ${#AZ_ARRAY[@]} availability zones..."
    
    for i in "${!AZ_ARRAY[@]}"; do
        local az="${AZ_ARRAY[$i]}"
        local public_cidr="${PUBLIC_CIDRS[$i]}"
        local private_cidr="${PRIVATE_CIDRS[$i]}"
        
        # Create public subnet
        log "Creating public subnet in $az with CIDR $public_cidr..."
        
        local public_subnet_id=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$public_cidr" --availability-zone "$az" --region "$AWS_REGION" \
            --tag-specifications "ResourceType=subnet,Tags=[
                {Key=Name,Value=${PROJECT_NAME}-${ENVIRONMENT}-public-${az}},
                {Key=Environment,Value=$ENVIRONMENT},
                {Key=Project,Value=$PROJECT_NAME},
                {Key=Type,Value=public},
                {Key=kubernetes.io/role/elb,Value=1},
                {Key=kubernetes.io/cluster/${PROJECT_NAME}-${ENVIRONMENT}-cluster,Value=shared}
            ]" --query 'Subnet.SubnetId' --output text 2>> "$LOG_FILE")
        
        if [[ -z "$public_subnet_id" ]]; then
            error "Failed to create public subnet in $az"
            exit 1
        fi
        
        PUBLIC_SUBNET_IDS+=("$public_subnet_id")
        success "Public subnet created in $az: $public_subnet_id"
        
        # Enable auto-assign public IP
        log "Enabling auto-assign public IP for $public_subnet_id..."
        aws ec2 modify-subnet-attribute --subnet-id "$public_subnet_id" --map-public-ip-on-launch --region "$AWS_REGION" 2>> "$LOG_FILE"
        
        # Create private subnet
        log "Creating private subnet in $az with CIDR $private_cidr..."
        
        local private_subnet_id=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$private_cidr" --availability-zone "$az" --region "$AWS_REGION" \
            --tag-specifications "ResourceType=subnet,Tags=[
                {Key=Name,Value=${PROJECT_NAME}-${ENVIRONMENT}-private-${az}},
                {Key=Environment,Value=$ENVIRONMENT},
                {Key=Project,Value=$PROJECT_NAME},
                {Key=Type,Value=private},
                {Key=kubernetes.io/role/internal-elb,Value=1},
                {Key=kubernetes.io/cluster/${PROJECT_NAME}-${ENVIRONMENT}-cluster,Value=shared}
            ]" --query 'Subnet.SubnetId' --output text 2>> "$LOG_FILE")
        
        if [[ -z "$private_subnet_id" ]]; then
            error "Failed to create private subnet in $az"
            exit 1
        fi
        
        PRIVATE_SUBNET_IDS+=("$private_subnet_id")
        success "Private subnet created in $az: $private_subnet_id"
        
        save_state
    done
    
    success "Created ${#PUBLIC_SUBNET_IDS[@]} public and ${#PRIVATE_SUBNET_IDS[@]} private subnets"
}

create_nat_gateways() {
    section "CREATING NAT GATEWAYS"
    
    if [[ "${ENABLE_NAT_GATEWAY}" != "true" ]]; then
        warning "NAT Gateway creation is disabled. Private subnets will not have internet access."
        return 0
    fi
    
    local nat_count=1
    if [[ "${SINGLE_NAT_GATEWAY}" != "true" ]]; then
        nat_count=${#PUBLIC_SUBNET_IDS[@]}
        log "Creating NAT Gateway in each availability zone for high availability ($nat_count total)"
    else
        log "Creating single NAT Gateway for cost optimization"
    fi
    
    for i in $(seq 0 $((nat_count - 1))); do
        local subnet_id="${PUBLIC_SUBNET_IDS[$i]}"
        
        # Allocate Elastic IP
        log "Allocating Elastic IP for NAT Gateway $((i + 1))/$nat_count..."
        
        local eip_alloc_id=$(aws ec2 allocate-address --domain vpc --region "$AWS_REGION" \
            --tag-specifications "ResourceType=elastic-ip,Tags=[
                {Key=Name,Value=${PROJECT_NAME}-${ENVIRONMENT}-nat-eip-$((i + 1))},
                {Key=Environment,Value=$ENVIRONMENT},
                {Key=Project,Value=$PROJECT_NAME}
            ]" --query 'AllocationId' --output text 2>> "$LOG_FILE")
        
        if [[ -z "$eip_alloc_id" ]]; then
            error "Failed to allocate Elastic IP"
            exit 1
        fi
        
        EIP_ALLOCATION_IDS+=("$eip_alloc_id")
        success "Elastic IP allocated: $eip_alloc_id"
        
        # Create NAT Gateway
        log "Creating NAT Gateway in subnet $subnet_id..."
        
        local nat_gw_id=$(aws ec2 create-nat-gateway --subnet-id "$subnet_id" --allocation-id "$eip_alloc_id" --region "$AWS_REGION" \
            --tag-specifications "ResourceType=natgateway,Tags=[
                {Key=Name,Value=${PROJECT_NAME}-${ENVIRONMENT}-nat-$((i + 1))},
                {Key=Environment,Value=$ENVIRONMENT},
                {Key=Project,Value=$PROJECT_NAME}
            ]" --query 'NatGateway.NatGatewayId' --output text 2>> "$LOG_FILE")
        
        if [[ -z "$nat_gw_id" ]]; then
            error "Failed to create NAT Gateway"
            exit 1
        fi
        
        NAT_GATEWAY_IDS+=("$nat_gw_id")
        success "NAT Gateway created: $nat_gw_id"
        
        save_state
    done
    
    # Wait for NAT Gateways to become available
    log "Waiting for NAT Gateway(s) to become available (this may take 3-5 minutes)..."
    
    for nat_gw_id in "${NAT_GATEWAY_IDS[@]}"; do
        local max_wait=300  # 5 minutes
        local wait_interval=10
        local elapsed=0
        
        while [[ $elapsed -lt $max_wait ]]; do
            local state=$(aws ec2 describe-nat-gateways --nat-gateway-ids "$nat_gw_id" --region "$AWS_REGION" --query 'NatGateways[0].State' --output text 2>> "$LOG_FILE" || echo "unknown")
            
            if [[ "$state" == "available" ]]; then
                success "NAT Gateway $nat_gw_id is available"
                break
            elif [[ "$state" == "failed" ]]; then
                error "NAT Gateway $nat_gw_id failed to create"
                exit 1
            else
                log "NAT Gateway $nat_gw_id state: $state (waiting ${elapsed}s/${max_wait}s)"
                sleep $wait_interval
                ((elapsed += wait_interval))
            fi
        done
        
        if [[ $elapsed -ge $max_wait ]]; then
            error "NAT Gateway $nat_gw_id did not become available within $max_wait seconds"
            exit 1
        fi
    done
    
    success "All NAT Gateways are available"
}

create_route_tables() {
    section "CREATING ROUTE TABLES"
    
    # Create public route table
    log "Creating public route table..."
    
    PUBLIC_ROUTE_TABLE_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --region "$AWS_REGION" \
        --tag-specifications "ResourceType=route-table,Tags=[
            {Key=Name,Value=${PROJECT_NAME}-${ENVIRONMENT}-public-rt},
            {Key=Environment,Value=$ENVIRONMENT},
            {Key=Project,Value=$PROJECT_NAME},
            {Key=Type,Value=public}
        ]" --query 'RouteTable.RouteTableId' --output text 2>> "$LOG_FILE")
    
    if [[ -z "$PUBLIC_ROUTE_TABLE_ID" ]]; then
        error "Failed to create public route table"
        exit 1
    fi
    
    success "Public route table created: $PUBLIC_ROUTE_TABLE_ID"
    save_state
    
    # Add route to Internet Gateway
    log "Adding route to Internet Gateway..."
    
    aws ec2 create-route --route-table-id "$PUBLIC_ROUTE_TABLE_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" --region "$AWS_REGION" 2>> "$LOG_FILE"
    
    success "Route to IGW added to public route table"
    
    # Associate public subnets with public route table
    log "Associating public subnets with public route table..."
    
    for subnet_id in "${PUBLIC_SUBNET_IDS[@]}"; do
        aws ec2 associate-route-table --subnet-id "$subnet_id" --route-table-id "$PUBLIC_ROUTE_TABLE_ID" --region "$AWS_REGION" 2>> "$LOG_FILE"
        
        success "Public subnet $subnet_id associated with public route table"
    done
    
    # Create private route tables
    if [[ "${ENABLE_NAT_GATEWAY}" == "true" ]]; then
        local num_private_rts=${#PRIVATE_SUBNET_IDS[@]}
        
        if [[ "${SINGLE_NAT_GATEWAY}" == "true" ]]; then
            num_private_rts=1
            log "Creating single private route table (shared NAT)"
        else
            log "Creating private route table for each AZ (dedicated NAT)"
        fi
        
        for i in $(seq 0 $((num_private_rts - 1))); do
            log "Creating private route table $((i + 1))/$num_private_rts..."
            
            local private_rt_id=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --region "$AWS_REGION" \
                --tag-specifications "ResourceType=route-table,Tags=[
                    {Key=Name,Value=${PROJECT_NAME}-${ENVIRONMENT}-private-rt-$((i + 1))},
                    {Key=Environment,Value=$ENVIRONMENT},
                    {Key=Project,Value=$PROJECT_NAME},
                    {Key=Type,Value=private}
                ]" --query 'RouteTable.RouteTableId' --output text 2>> "$LOG_FILE")
            
            if [[ -z "$private_rt_id" ]]; then
                error "Failed to create private route table"
                exit 1
            fi
            
            PRIVATE_ROUTE_TABLE_IDS+=("$private_rt_id")
            success "Private route table created: $private_rt_id"
            
            # Add route to NAT Gateway
            local nat_index=$i
            if [[ "${SINGLE_NAT_GATEWAY}" == "true" ]]; then
                nat_index=0
            fi
            
            local nat_gw_id="${NAT_GATEWAY_IDS[$nat_index]}"
            
            log "Adding route to NAT Gateway $nat_gw_id..."
            
            aws ec2 create-route --route-table-id "$private_rt_id" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$nat_gw_id" --region "$AWS_REGION" 2>> "$LOG_FILE"
            
            success "Route to NAT Gateway added"
            save_state
        done
        
        # Associate private subnets with private route tables
        log "Associating private subnets with private route tables..."
        
        for i in "${!PRIVATE_SUBNET_IDS[@]}"; do
            local subnet_id="${PRIVATE_SUBNET_IDS[$i]}"
            local rt_index=$i
            
            if [[ "${SINGLE_NAT_GATEWAY}" == "true" ]]; then
                rt_index=0
            fi
            
            local rt_id="${PRIVATE_ROUTE_TABLE_IDS[$rt_index]}"
            
            aws ec2 associate-route-table --subnet-id "$subnet_id" --route-table-id "$rt_id" --region "$AWS_REGION" 2>> "$LOG_FILE"
            
            success "Private subnet $subnet_id associated with route table $rt_id"
        done
    else
        warning "NAT Gateway disabled - skipping private route table creation"
    fi
    
    success "All route tables created and associated"
}

################################################################################
# VPC ENDPOINTS (Optional but recommended)
################################################################################

create_vpc_endpoints() {
    section "CREATING VPC ENDPOINTS (OPTIONAL)"
    
    if [[ "${CREATE_VPC_ENDPOINTS:-false}" != "true" ]]; then
        log "VPC endpoints creation disabled (set CREATE_VPC_ENDPOINTS=true to enable)"
        return 0
    fi
    
    log "Creating VPC endpoints for cost optimization..."
    
    # S3 Gateway Endpoint (free)
    log "Creating S3 gateway endpoint..."
    
    local s3_endpoint=$(aws ec2 create-vpc-endpoint --vpc-id "$VPC_ID" --service-name "com.amazonaws.${AWS_REGION}.s3" --route-table-ids "${PRIVATE_ROUTE_TABLE_IDS[@]}" "$PUBLIC_ROUTE_TABLE_ID" --region "$AWS_REGION" \
        --tag-specifications "ResourceType=vpc-endpoint,Tags=[
            {Key=Name,Value=${PROJECT_NAME}-${ENVIRONMENT}-s3-endpoint},
            {Key=Environment,Value=$ENVIRONMENT},
            {Key=Project,Value=$PROJECT_NAME}
        ]" --query 'VpcEndpoint.VpcEndpointId' --output text 2>> "$LOG_FILE" || echo "")
    
    if [[ -n "$s3_endpoint" ]]; then
        success "S3 gateway endpoint created: $s3_endpoint"
    else
        warning "Failed to create S3 endpoint (non-critical)"
    fi
    
    # ECR API and DKR Endpoints (interface endpoints - have cost)
    if [[ "${CREATE_ECR_ENDPOINTS:-false}" == "true" ]]; then
        log "Creating ECR interface endpoints..."
        
        # Create security group for VPC endpoints
        local sg_id=$(aws ec2 create-security-group --group-name "${PROJECT_NAME}-${ENVIRONMENT}-vpce-sg" --description "Security group for VPC endpoints" --vpc-id "$VPC_ID" --region "$AWS_REGION" \
            --tag-specifications "ResourceType=security-group,Tags=[
                {Key=Name,Value=${PROJECT_NAME}-${ENVIRONMENT}-vpce-sg},
                {Key=Environment,Value=$ENVIRONMENT}
            ]" --query 'GroupId' --output text 2>> "$LOG_FILE" || echo "")
        
        if [[ -n "$sg_id" ]]; then
            # Allow HTTPS from VPC
            aws ec2 authorize-security-group-ingress --group-id "$sg_id" --protocol tcp --port 443 --cidr "$VPC_CIDR" --region "$AWS_REGION" 2>> "$LOG_FILE" || true
            
            success "VPC endpoint security group created: $sg_id"
        fi
    fi
}

################################################################################
# VALIDATION AND OUTPUT
################################################################################

validate_vpc_creation() {
    section "VALIDATING VPC CREATION"
    
    log "Verifying VPC exists..."
    local vpc_state=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$AWS_REGION" --query 'Vpcs[0].State' --output text 2>> "$LOG_FILE")
    
    if [[ "$vpc_state" == "available" ]]; then
        success "VPC is available: $VPC_ID"
    else
        error "VPC is not available. State: $vpc_state"
        exit 1
    fi
    
    log "Verifying subnets..."
    for subnet_id in "${PUBLIC_SUBNET_IDS[@]}" "${PRIVATE_SUBNET_IDS[@]}"; do
        local subnet_state=$(aws ec2 describe-subnets --subnet-ids "$subnet_id" --region "$AWS_REGION" --query 'Subnets[0].State' --output text 2>> "$LOG_FILE")
        
        if [[ "$subnet_state" == "available" ]]; then
            log "Subnet $subnet_id is available"
        else
            error "Subnet $subnet_id state: $subnet_state"
        fi
    done
    
    if [[ "${ENABLE_NAT_GATEWAY}" == "true" ]]; then
        log "Verifying NAT Gateways..."
        for nat_id in "${NAT_GATEWAY_IDS[@]}"; do
            local nat_state=$(aws ec2 describe-nat-gateways --nat-gateway-ids "$nat_id" --region "$AWS_REGION" --query 'NatGateways[0].State' --output text 2>> "$LOG_FILE")
            
            if [[ "$nat_state" == "available" ]]; then
                log "NAT Gateway $nat_id is available"
            else
                warning "NAT Gateway $nat_id state: $nat_state"
            fi
        done
    fi
    
    success "VPC validation completed"
}

print_vpc_summary() {
    section "VPC CREATION SUMMARY"
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    VPC INFRASTRUCTURE                      ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${GREEN}VPC Details:${NC}"
    echo "  VPC ID:              $VPC_ID"
    echo "  CIDR Block:          $VPC_CIDR"
    echo "  Region:              $AWS_REGION"
    echo "  DNS Support:         Enabled"
    echo "  DNS Hostnames:       Enabled"
    echo ""
    echo -e "${GREEN}Internet Gateway:${NC}"
    echo "  IGW ID:              $IGW_ID"
    echo ""
    echo -e "${GREEN}Public Subnets (${#PUBLIC_SUBNET_IDS[@]}):${NC}"
    IFS=',' read -ra AZ_ARRAY <<< "$AVAILABILITY_ZONES"
    for i in "${!PUBLIC_SUBNET_IDS[@]}"; do
        echo "  ${AZ_ARRAY[$i]}:    ${PUBLIC_SUBNET_IDS[$i]}"
    done
    echo ""
    echo -e "${GREEN}Private Subnets (${#PRIVATE_SUBNET_IDS[@]}):${NC}"
    for i in "${!PRIVATE_SUBNET_IDS[@]}"; do
        echo "  ${AZ_ARRAY[$i]}:    ${PRIVATE_SUBNET_IDS[$i]}"
    done
    echo ""
    
    if [[ "${ENABLE_NAT_GATEWAY}" == "true" ]]; then
        echo -e "${GREEN}NAT Gateways (${#NAT_GATEWAY_IDS[@]}):${NC}"
        for i in "${!NAT_GATEWAY_IDS[@]}"; do
            echo "  NAT-$((i + 1)):           ${NAT_GATEWAY_IDS[$i]}"
        done
        echo ""
        echo -e "${GREEN}Elastic IPs (${#EIP_ALLOCATION_IDS[@]}):${NC}"
        for i in "${!EIP_ALLOCATION_IDS[@]}"; do
            echo "  EIP-$((i + 1)):           ${EIP_ALLOCATION_IDS[$i]}"
        done
        echo ""
    fi
    
    echo -e "${GREEN}Route Tables:${NC}"
    echo "  Public RT:           $PUBLIC_ROUTE_TABLE_ID"
    if [[ ${#PRIVATE_ROUTE_TABLE_IDS[@]} -gt 0 ]]; then
        for i in "${!PRIVATE_ROUTE_TABLE_IDS[@]}"; do
            echo "  Private RT-$((i + 1)):      ${PRIVATE_ROUTE_TABLE_IDS[$i]}"
        done
    fi
    echo ""
    echo -e "${GREEN}State File:${NC}"
    echo "  Location:            $STATE_FILE"
    echo ""
    echo -e "${GREEN}Log File:${NC}"
    echo "  Location:            $LOG_FILE"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Export variables for use by other scripts
    cat > "vpc-exports.sh" <<EOF
#!/bin/bash
# VPC Exports - Source this file to use VPC resources in other scripts
export VPC_ID="$VPC_ID"
export IGW_ID="$IGW_ID"
export PUBLIC_SUBNET_IDS="${PUBLIC_SUBNET_IDS[*]:-}"
export PRIVATE_SUBNET_IDS="${PRIVATE_SUBNET_IDS[*]:-}"
export NAT_GATEWAY_IDS="${NAT_GATEWAY_IDS[*]:-}"
export PUBLIC_ROUTE_TABLE_ID="$PUBLIC_ROUTE_TABLE_ID"
export PRIVATE_ROUTE_TABLE_IDS="${PRIVATE_ROUTE_TABLE_IDS[*]:-}"
EOF
    
    success "VPC exports saved to vpc-exports.sh"
}


main() {
    log "Starting VPC creation process..."
    log "Project: $PROJECT_NAME | Environment: $ENVIRONMENT | Region: $AWS_REGION"
    
    check_prerequisites
    check_existing_vpc
    
    if [[ -z "$VPC_ID" ]]; then
        create_vpc
        create_internet_gateway
        create_subnets
        create_nat_gateways
        create_route_tables
        create_vpc_endpoints
        validate_vpc_creation
    fi
    
    print_vpc_summary
    
    success "VPC creation completed successfully!"
}

# Run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi