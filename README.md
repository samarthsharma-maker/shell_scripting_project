# AWS Infrastructure Provisioning Scripts

A comprehensive set of shell scripts for provisioning and managing AWS infrastructure resources including VPC, S3, ECR, and EKS.

## Prerequisites

- AWS CLI installed and configured
- jq (JSON processor)
- Valid AWS credentials with appropriate permissions
- Bash shell (macOS/Linux)

## Project Structure

```
.
├── main.sh                          # Main orchestration script
├── provision_vpc_resources.sh       # VPC provisioning
├── provision_s3_resources.sh        # S3 bucket provisioning
├── provision_ecr_resources.sh       # ECR repository provisioning
├── provision_eks_resources.sh       # EKS cluster provisioning
├── variables.sh                     # Configuration variables
├── utilities.sh                     # Utility functions
├── verify_variables.sh              # Variable validation
└── cloud-state-{project}-{env}.json # Unified state file
```

## Configuration

Edit `variables.sh` to set your project-specific configurations:

```bash
PROJECT_NAME="myproject"
ENVIRONMENT="dev"
AWS_REGION="ap-south-1"
```

### VPC Configuration
- CIDR blocks for VPC, public/private subnets
- Number of availability zones
- NAT Gateway configuration

### S3 Configuration
- Bucket naming conventions
- Encryption settings
- Lifecycle policies

### ECR Configuration
- Repository naming
- Image scanning options
- Lifecycle policies

### EKS Configuration
- Cluster name and version
- Node group settings (instance type, scaling)
- Kubernetes version

## Usage

### Quick Start - All Resources

Run the main orchestration script:

```bash
./main.sh
```

This will present an interactive menu with options:
1. Provision all resources (VPC, S3, ECR, EKS)
2. Provision VPC only
3. Provision S3 only
4. Provision ECR only
5. Provision EKS only

### Individual Resource Provisioning

#### VPC Resources

Creates a complete VPC infrastructure with subnets, NAT gateways, route tables, and internet gateway.

```bash
./provision_vpc_resources.sh
```

**What it creates:**
- VPC with configurable CIDR block
- Public and private subnets across multiple availability zones
- Internet Gateway for public internet access
- NAT Gateways for private subnet internet access
- Route tables for public and private subnets
- Elastic IPs for NAT Gateways

**Requirements:**
- Confirmation prompt before creation
- Valid AWS credentials with VPC creation permissions

#### S3 Bucket

Creates an S3 bucket with enterprise-grade security and lifecycle management.

```bash
./provision_s3_resources.sh
```

**What it creates:**
- S3 bucket with versioning enabled
- AES256 server-side encryption
- Public access blocking (all four settings enabled)
- Lifecycle policies:
  - Transition to STANDARD_IA after 30 days
  - Transition to GLACIER after 60 days
  - Expiration after 90 days

**Requirements:**
- Confirmation prompt before creation
- Bucket name must be globally unique

#### ECR Repository

Creates an Amazon ECR repository for Docker image storage.

```bash
./provision_ecr_resources.sh
```

**What it creates:**
- Private ECR repository
- Image scanning on push enabled
- Lifecycle policy to retain last N images
- AES256 encryption at rest

**Requirements:**
- Confirmation prompt before creation
- Docker images can be pushed after creation

#### EKS Cluster

Creates a basic Amazon EKS cluster with managed node groups.

```bash
./provision_eks_resources.sh
```

**What it creates:**
- EKS service role with required policies
- Node group IAM role with required policies
- EKS cluster with specified Kubernetes version
- Managed node group with configurable instance type and scaling

**Requirements:**
- VPC must be provisioned first (checks for vpc-exports.sh)
- Confirmation prompt before creation
- Cluster creation takes 10-15 minutes

**Note:** This is a basic implementation with minimal configuration.

## State Management

All scripts use a unified state file: `cloud-state-{PROJECT_NAME}-{ENVIRONMENT}.json`

This file tracks all provisioned resources and is updated by each script. Structure:

```json
{
  "project": "myproject",
  "environment": "dev",
  "region": "ap-south-1",
  "last_updated": "2026-01-14T12:00:00+05:30",
  "vpc": { },
  "s3": { },
  "ecr": { },
  "eks": { }
}
```

## Export Files

Each script generates an export file for use by other scripts:

- `vpc-exports.sh` - VPC IDs, subnet IDs, route table IDs
- `s3-exports.sh` - Bucket name, ARN, configuration details
- `ecr-exports.sh` - Repository URI, name, ARN
- `eks-exports.sh` - Cluster name, endpoint, role ARNs

Source these files in other scripts:

```bash
source vpc-exports.sh
echo "VPC ID: $VPC_ID"
```

## Error Handling

All scripts include:
- Strict error checking (`set -euo pipefail`)
- Rollback capabilities using state files
- Cleanup functions executed on error
- Detailed logging with color-coded output

## Logging

Scripts use color-coded logging:
- **INFO** - Blue: Informational messages
- **SUCCESS** - Green: Successful operations
- **WARNING** - Yellow: Non-critical warnings
- **ERROR** - Red: Critical errors

## Common Variables

Key variables used across scripts (defined in `variables.sh`):

```bash
# Project Configuration
PROJECT_NAME="myproject"
ENVIRONMENT="dev"
AWS_REGION="ap-south-1"

# VPC Configuration
VPC_CIDR="10.0.0.0/16"
PUBLIC_SUBNET_CIDRS=("10.0.1.0/24" "10.0.2.0/24")
PRIVATE_SUBNET_CIDRS=("10.0.11.0/24" "10.0.12.0/24")
AVAILABILITY_ZONES=("ap-south-1a" "ap-south-1b")

# S3 Configuration
S3_BUCKET_PREFIX="platform-artifacts"

# ECR Configuration
ECR_REPOSITORY_NAME="${PROJECT_NAME}-${ENVIRONMENT}"
ECR_LIFECYCLE_POLICY_DAYS=30

# EKS Configuration
EKS_CLUSTER_NAME="${PROJECT_NAME}-${ENVIRONMENT}-cluster"
EKS_NODE_INSTANCE_TYPE="t3.medium"
EKS_NODE_DESIRED_SIZE=2
EKS_NODE_MIN_SIZE=1
EKS_NODE_MAX_SIZE=4
```

## Best Practices

1. **Always review configuration** in `variables.sh` before running scripts
2. **Run in order** for first-time setup: VPC → S3 → ECR → EKS
3. **Backup state files** before making changes
4. **Verify resources** in AWS Console after provisioning
5. **Use main.sh** for orchestrated deployments
6. **Test in dev environment** before running in production

## Troubleshooting

### Script fails with "command not found"
- Ensure AWS CLI is installed: `aws --version`
- Ensure jq is installed: `jq --version`

### Permission denied errors
- Make scripts executable: `chmod +x *.sh`
- Verify AWS credentials: `aws sts get-caller-identity`

### State file corruption
- Check JSON validity: `jq empty cloud-state-*.json`
- Restore from backup if available

### VPC quota exceeded
- Check VPC limits in AWS Console
- Delete unused VPCs or request limit increase

### EKS cluster creation timeout
- Cluster creation takes 10-15 minutes (normal)
- Check CloudFormation stack in AWS Console for issues

## License

MIT

## Author

Infrastructure Team