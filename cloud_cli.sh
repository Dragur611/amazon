#!/bin/bash

# --- Configuration ---
GROUP_NAME="main-sg"
INSTANCE_TYPE="t3.micro"
UBUNTU_AMI_PARAMETER="/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
BLOCK_DEVICE_MAPPING='[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":8,"VolumeType":"gp3","DeleteOnTermination":true}}]'
ROLE_NAME="SSMInstanceRole"
INSTANCE_PROFILE_NAME="SSMInstanceProfile"

# --- Security Group Validation ---
echo "Checking for security group: $GROUP_NAME..."
if ! aws ec2 describe-security-groups --group-names "$GROUP_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Security group '$GROUP_NAME' not found. Creating it..."
  DESCRIPTION="Security group principal"
  VPC_ID=$(aws ec2 describe-vpcs --region "$AWS_REGION" --query "Vpcs[0].VpcId" --output text 2>/dev/null)
  aws ec2 create-security-group --group-name "$GROUP_NAME" --description "$DESCRIPTION" --vpc-id "$VPC_ID" --region "$AWS_REGION"
  aws ec2 authorize-security-group-ingress --group-name "$GROUP_NAME" --protocol tcp --port 22 --cidr "0.0.0.0/0" --region "$AWS_REGION"
  aws ec2 authorize-security-group-ingress --group-name "$GROUP_NAME" --protocol tcp --port 1080 --cidr "0.0.0.0/0" --region "$AWS_REGION"
  aws ec2 authorize-security-group-ingress --group-name "$GROUP_NAME" --protocol udp --port 1080 --cidr "0.0.0.0/0" --region "$AWS_REGION"
  echo "Security group '$GROUP_NAME' created."
else
  echo "Security group '$GROUP_NAME' already exists. Using it."
fi

# --- Key Pair Validation ---
echo "Checking for existing key pair with prefix 'main-key-pair-' on AWS..."
KEY_NAME=$(aws ec2 describe-key-pairs --filters "Name=key-name,Values=main-key-pair-*" --query "KeyPairs[0].KeyName" --output text 2>/dev/null)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

if [ -n "$KEY_NAME" ] && [ "$KEY_NAME" != "None" ]; then
  echo "Found existing key pair on AWS: $KEY_NAME"
  if [ -f "$SCRIPT_DIR/$KEY_NAME.pem" ]; then
    echo "Local .pem file found. Using key: $KEY_NAME"
  else
    echo "Key '$KEY_NAME' exists on AWS, but no local .pem file found. A new key will be created."
    KEY_NAME="" # Force creation
  fi
else
  echo "No existing key pair found on AWS with the prefix. A new key will be created."
  KEY_NAME="" # Force creation
fi

if [ -z "$KEY_NAME" ]; then
  RANDOM_ID=$(openssl rand -hex 5)
  KEY_NAME="main-key-pair-${RANDOM_ID}"
  echo "Creating new key pair: $KEY_NAME"
  aws ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text > "$SCRIPT_DIR/$KEY_NAME.pem"
  chmod 400 "$SCRIPT_DIR/$KEY_NAME.pem"
  echo "Key pair '$KEY_NAME' created and saved to '$SCRIPT_DIR/$KEY_NAME.pem'"
fi

# --- IAM Role and Profile Validation ---
echo "Checking for IAM role: $ROLE_NAME..."
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "IAM role '$ROLE_NAME' not found. Creating it..."
  tee ec2-trust-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document file://ec2-trust-policy.json
  aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  echo "IAM role '$ROLE_NAME' created."
  rm ec2-trust-policy.json
else
  echo "IAM role '$ROLE_NAME' already exists."
fi

echo "Checking for IAM instance profile: $INSTANCE_PROFILE_NAME..."
if ! aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
  echo "IAM instance profile '$INSTANCE_PROFILE_NAME' not found. Creating it..."
  aws iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME"
  aws iam add-role-to-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" --role-name "$ROLE_NAME"
  echo "IAM instance profile '$INSTANCE_PROFILE_NAME' created and associated with role '$ROLE_NAME'."
  echo "Waiting 10 seconds for instance profile to be ready..."
  sleep 10
else
  echo "IAM instance profile '$INSTANCE_PROFILE_NAME' already exists."
fi

# --- Create EC2 Instance ---
echo "Fetching latest Ubuntu 22.04 LTS AMI ID..."
AMI_ID=$(aws ssm get-parameters --names $UBUNTU_AMI_PARAMETER --query 'Parameters[0].Value' --output text)
echo "Using AMI ID: $AMI_ID"

echo "Fetching Security Group ID for '$GROUP_NAME'..."
SG_ID=$(aws ec2 describe-security-groups --group-names "$GROUP_NAME" --query "SecurityGroups[0].GroupId" --output text)
echo "Using Security Group ID: $SG_ID"

echo "Creating EC2 instance..."
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --iam-instance-profile Name="$INSTANCE_PROFILE_NAME" \
    --block-device-mappings "$BLOCK_DEVICE_MAPPING" \
    --count 1 \
    --query "Instances[0].InstanceId" \
    --output text)

echo "Instance '$INSTANCE_ID' is being created."

# Wait for the instance to be running
echo "Waiting for instance to enter 'running' state..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

# Get the public IP address
PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

echo "Instance is running. Public IP: $PUBLIC_IP"

# --- Execute Installation Script via SSM ---
echo "Executing script_install.sh on the new instance via SSM..."

echo "Waiting 30 seconds for SSM agent to register..."
sleep 30

COMMAND_ID=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters '{"commands":[
        "wget https://raw.githubusercontent.com/Dragur611/amazon/main/script_install.sh -O /tmp/script_install.sh",
        "chmod +x /tmp/script_install.sh",
        "sudo /tmp/script_install.sh"
    ]}' \
    --query "Command.CommandId" \
    --output text)

echo "SSM command sent. Command ID: $COMMAND_ID"
echo "Waiting for command to complete..."

aws ssm wait command-executed --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID"

echo "Command finished. Fetching output..."

aws ssm get-command-invocation \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --query "{Status:Status, Output:StandardOutputContent}"