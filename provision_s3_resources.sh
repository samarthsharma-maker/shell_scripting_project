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


# State file for unified cloud state
STATE_FILE="cloud-state-${PROJECT_NAME}-${ENVIRONMENT}.json"
function save_state() {
    local existing_state="{}"
    if [[ -f "$STATE_FILE" ]]; then
        existing_state=$(cat "$STATE_FILE")
    fi

    cat > "$STATE_FILE" <<EOF
{
  "project": "${PROJECT_NAME}",
  "environment": "${ENVIRONMENT}",
  "region": "${AWS_REGION}",
  "last_updated": "$(date -Iseconds)",
  "vpc": $(echo "$existing_state" | jq -c '.vpc // {}' 2>/dev/null || echo '{}'),
  "s3": {
    "bucket_name": "${S3_BUCKET_NAME}",
    "bucket_arn": "${S3_BUCKET_ARN}",
    "kms_key_id": "${S3_KMS_KEY_ID:-}",
    "versioning_enabled": "${S3_VERSIONING_ENABLED}",
    "encryption_enabled": "${S3_ENCRYPTION_ENABLED}"
  },
  "ecr": $(echo "$existing_state" | jq -c '.ecr // {}' 2>/dev/null || echo '{}'),
  "eks": $(echo "$existing_state" | jq -c '.eks // {}' 2>/dev/null || echo '{}')
}
EOF
    log "State saved to $STATE_FILE"
}

function cleanup_on_error() {
    error "An error occurred during S3 creation. Initiating rollback..."
    
    if [[ -n "$S3_BUCKET_NAME" ]]; then
        warning "Attempting to delete bucket: $S3_BUCKET_NAME"
        aws s3 rm "s3://${S3_BUCKET_NAME}" --recursive --region "$AWS_REGION" 2>/dev/null || true
        aws s3api delete-objects --bucket "$S3_BUCKET_NAME" --delete "$(aws s3api list-object-versions --bucket "$S3_BUCKET_NAME" --output json --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' 2>/dev/null || echo '{}')" --region "$AWS_REGION" 2>/dev/null || true
        aws s3api delete-objects --bucket "$S3_BUCKET_NAME" --delete "$(aws s3api list-object-versions --bucket "$S3_BUCKET_NAME" --output json --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' 2>/dev/null || echo '{}')" --region "$AWS_REGION" 2>/dev/null || true
        aws s3api delete-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" 2>/dev/null || true
        
        success "Bucket deleted: $S3_BUCKET_NAME"
    fi
    
    save_state
    exit 1
}

trap cleanup_on_error ERR


function check_prerequisites() {
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


function check_existing_bucket() {
    section "CHECKING FOR EXISTING S3 BUCKET"
    
    local bucket_name="${PROJECT_NAME}-${ENVIRONMENT}-${S3_BUCKET_PURPOSE}-${AWS_ACCOUNT_ID}"
    
    if aws s3api head-bucket --bucket "$bucket_name" --region "$AWS_REGION" 2>/dev/null; then
        warning "S3 bucket already exists: $bucket_name"
        echo -n "Do you want to use the existing bucket? (yes/no): "
        read -r response
        
        if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            log "Using existing S3 bucket: $bucket_name"
            S3_BUCKET_NAME="$bucket_name"
            S3_BUCKET_ARN="arn:aws:s3:::${bucket_name}"

            load_existing_bucket
            return 0
        else
            error "Please use a different bucket name or delete the existing bucket"
            exit 1
        fi
    else
        log "No existing bucket found with name: $bucket_name"
        return 1
    fi
}

function load_existing_bucket() {
    log "Loading existing S3 bucket configuration..."
    local versioning_status=$(aws s3api get-bucket-versioning --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" --query 'Status' --output text 2>/dev/null || echo "None")
    
    if [[ "$versioning_status" == "Enabled" ]]; then
        log "Versioning is enabled"
    else
        warning "Versioning is not enabled"
    fi
    
    # Check encryption
    local encryption_status=$(aws s3api get-bucket-encryption --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" 2>/dev/null && echo "Enabled" || echo "Disabled")
    
    if [[ "$encryption_status" == "Enabled" ]]; then
        log "Encryption is enabled"
        S3_KMS_KEY_ID=$(aws s3api get-bucket-encryption --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID' --output text 2>/dev/null || echo "AES256")
    else
        warning "Encryption is not enabled"
        S3_KMS_KEY_ID=""
    fi
    
    save_state
    success "Loaded existing S3 bucket configuration"
}

create_s3_bucket() {
    section "CREATING S3 BUCKET"
    
    S3_BUCKET_NAME="${PROJECT_NAME}-${ENVIRONMENT}-${S3_BUCKET_PURPOSE}-${AWS_ACCOUNT_ID}"
    
    log "Creating S3 bucket: $S3_BUCKET_NAME"
    
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
        aws s3api create-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION"
    else
        aws s3api create-bucket --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" --create-bucket-configuration LocationConstraint="$AWS_REGION"
    fi
    
    S3_BUCKET_ARN="arn:aws:s3:::${S3_BUCKET_NAME}"
    success "S3 bucket created: $S3_BUCKET_NAME"
    
    # Add tags
    log "Adding tags to bucket..."
    aws s3api put-bucket-tagging --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" \
        --tagging "TagSet=[
            {Key=Name,Value=${S3_BUCKET_NAME}},
            {Key=Project,Value=${PROJECT_NAME}},
            {Key=Environment,Value=${ENVIRONMENT}},
            {Key=ManagedBy,Value=shell-script},
            {Key=CreatedAt,Value=$(date -Iseconds)},
            {Key=Purpose,Value=${S3_BUCKET_PURPOSE}}
        ]"
    success "Tags applied to bucket"
    
    save_state
}


function configure_versioning() {
    if [[ "$S3_VERSIONING_ENABLED" == "true" ]]; then
        section "CONFIGURING BUCKET VERSIONING"
        
        log "Enabling versioning on bucket: $S3_BUCKET_NAME"
        aws s3api put-bucket-versioning --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" --versioning-configuration Status=Enabled
        
        success "Versioning enabled on bucket"
        save_state
    else
        log "Versioning is disabled (S3_VERSIONING_ENABLED=false)"
    fi
}


function configure_encryption() {
    if [[ "$S3_ENCRYPTION_ENABLED" == "true" ]]; then
        section "CONFIGURING BUCKET ENCRYPTION"
        
        log "Enabling server-side encryption on bucket: $S3_BUCKET_NAME"
        aws s3api put-bucket-encryption --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" --server-side-encryption-configuration '{
                "Rules": [{
                    "ApplyServerSideEncryptionByDefault": {
                        "SSEAlgorithm": "AES256"
                    },
                    "BucketKeyEnabled": true
                }]
            }'
        
        S3_KMS_KEY_ID="AES256"
        success "Server-side encryption (AES256) enabled on bucket"
        save_state
    else
        log "Encryption is disabled (S3_ENCRYPTION_ENABLED=false)"
    fi
}

function configure_public_access_block() {
    if [[ "$S3_BLOCK_PUBLIC_ACCESS" == "true" ]]; then
        section "CONFIGURING PUBLIC ACCESS BLOCK"
        
        log "Blocking all public access to bucket: $S3_BUCKET_NAME"
        aws s3api put-public-access-block --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
        
        success "Public access blocked on bucket"
        save_state
    else
        warning "Public access block is disabled (S3_BLOCK_PUBLIC_ACCESS=false)"
    fi
}


function configure_lifecycle_policy() {
    section "CONFIGURING LIFECYCLE POLICY"
    
    log "Setting lifecycle policy for bucket: $S3_BUCKET_NAME"
    
    local lifecycle_policy='{
        "Rules": [
            {
                "ID": "TransitionOldVersions",
                "Status": "Enabled",
                "Filter": {"Prefix": ""},
                "NoncurrentVersionTransitions": [
                    {
                        "NoncurrentDays": 30,
                        "StorageClass": "STANDARD_IA"
                    },
                    {
                        "NoncurrentDays": 60,
                        "StorageClass": "GLACIER"
                    }
                ],
                "NoncurrentVersionExpiration": {
                    "NoncurrentDays": '${S3_LIFECYCLE_DAYS}'
                }
            },
            {
                "ID": "DeleteIncompleteMultipartUploads",
                "Status": "Enabled",
                "Filter": {"Prefix": ""},
                "AbortIncompleteMultipartUpload": {
                    "DaysAfterInitiation": 7
                }
            }
        ]
    }'
    
    echo "$lifecycle_policy" | aws s3api put-bucket-lifecycle-configuration --bucket "$S3_BUCKET_NAME" --region "$AWS_REGION" --lifecycle-configuration file:///dev/stdin
    
    success "Lifecycle policy configured"
    save_state
}


function print_summary() {
    section "S3 BUCKET CREATION SUMMARY"
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                S3 BUCKET INFRASTRUCTURE                   ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Bucket Details:"
    echo "  Bucket Name:         $S3_BUCKET_NAME"
    echo "  Bucket ARN:          $S3_BUCKET_ARN"
    echo "  Region:              $AWS_REGION"
    echo "  Account ID:          $AWS_ACCOUNT_ID"
    echo ""
    echo "Configuration:"
    echo "  Versioning:          $S3_VERSIONING_ENABLED"
    echo "  Encryption:          $S3_ENCRYPTION_ENABLED"
    if [[ -n "$S3_KMS_KEY_ID" ]]; then
        echo "  Encryption Type:     $S3_KMS_KEY_ID"
    fi
    echo "  Public Access:       $(if [[ "$S3_BLOCK_PUBLIC_ACCESS" == "true" ]]; then echo "Blocked"; else echo "Allowed"; fi)"
    echo "  Lifecycle Days:      $S3_LIFECYCLE_DAYS"
    echo ""
    echo "State File:"
    echo "  Location:            $STATE_FILE"
    echo ""
    echo "Log File:"
    echo "  Location:            $LOG_FILE"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    cat > "s3-exports.sh" <<EOF
#!/bin/bash
# S3 Exports - Source this file to use S3 resources in other scripts
export S3_BUCKET_NAME="$S3_BUCKET_NAME"
export S3_BUCKET_ARN="$S3_BUCKET_ARN"
export S3_KMS_KEY_ID="${S3_KMS_KEY_ID:-}"
export S3_REGION="$AWS_REGION"
EOF
    chmod +x s3-exports.sh
    success "Export file created: s3-exports.sh"
}

function main() {
    LOG_FILE="aws-s3-provision-$(date +%Y%m%d%H%M%S).log"
    
    log "Starting S3 bucket creation process..."
    log "Project: $PROJECT_NAME | Environment: $ENVIRONMENT | Region: $AWS_REGION"
    echo ""
    
    check_prerequisites
    
    if ! check_existing_bucket; then
        create_s3_bucket
    fi
    

    configure_versioning
    configure_encryption
    configure_public_access_block
    configure_lifecycle_policy
    
    print_summary
    
    success "S3 bucket provisioning completed successfully!"
    log "You can now use the S3 bucket: $S3_BUCKET_NAME"
}


main
