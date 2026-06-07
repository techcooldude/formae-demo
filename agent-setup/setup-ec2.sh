#!/usr/bin/env bash
# Formae Agent — EC2 Free Tier Setup
# Launches a t2.micro EC2 instance running the Formae agent (SQLite state)
# Run this in AWS CloudShell

set -euo pipefail

REGION="us-east-1"
FORMAE_VERSION="0.83.2"
INSTANCE_NAME="formae-agent"
KEY_NAME="formae-agent-key"
export AWS_PAGER=""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Formae Agent — EC2 Free Tier Setup"
echo "  Region: $REGION | Instance: t2.micro (free)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. Key pair ───────────────────────────────────────────────────────────────
echo ""
echo "[ 1/5 ] Creating key pair..."
aws ec2 create-key-pair \
  --key-name $KEY_NAME \
  --region $REGION \
  --query "KeyMaterial" \
  --output text > formae-agent-key.pem 2>/dev/null || echo "  Key pair already exists"
chmod 400 formae-agent-key.pem 2>/dev/null || true

# ── 2. Security group ─────────────────────────────────────────────────────────
echo ""
echo "[ 2/5 ] Creating security group..."
SG_ID=$(aws ec2 create-security-group \
  --group-name formae-agent-sg \
  --description "Formae agent security group" \
  --region $REGION \
  --query GroupId \
  --output text 2>/dev/null) || \
SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values=formae-agent-sg \
  --region $REGION \
  --query "SecurityGroups[0].GroupId" \
  --output text)

echo "  Security group: $SG_ID"

# Allow Formae agent port from anywhere
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp --port 11144 --cidr 0.0.0.0/0 \
  --region $REGION 2>/dev/null || true

# Allow SSH for debugging
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp --port 22 --cidr 0.0.0.0/0 \
  --region $REGION 2>/dev/null || true

# ── 3. Get Amazon Linux 2023 AMI ──────────────────────────────────────────────
echo ""
echo "[ 3/5 ] Finding latest Amazon Linux 2023 AMI..."
AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --filters \
    "Name=name,Values=al2023-ami-*-x86_64" \
    "Name=state,Values=available" \
  --region $REGION \
  --query "sort_by(Images, &CreationDate)[-1].ImageId" \
  --output text)
echo "  AMI: $AMI_ID"

# ── 4. Launch EC2 instance ────────────────────────────────────────────────────
echo ""
echo "[ 4/5 ] Launching t2.micro instance..."

USER_DATA=$(cat << 'USERDATA'
#!/bin/bash
# Install Formae
curl -fsSL https://hub.platform.engineering/setup/formae.sh | bash -s -- -y
export PATH="/opt/pel/formae/bin:$PATH"

# Create data directory for persistent SQLite state
mkdir -p /opt/formae/data

# Create agent config — listen on all interfaces, use /opt/formae/data for state
mkdir -p /etc/formae
cat > /etc/formae/formae.conf.pkl << 'PKLEOF'
amends "formae:/Config.pkl"

agent {
    api {
        host = "0.0.0.0"
        port = 11144
    }
}
PKLEOF

# Create systemd service so agent starts on boot and restarts on crash
cat > /etc/systemd/system/formae-agent.service << 'SVCEOF'
[Unit]
Description=Formae Agent
After=network.target

[Service]
Type=simple
User=ec2-user
Environment="PATH=/opt/pel/formae/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/opt/pel/formae/bin/formae agent start --config /etc/formae/formae.conf.pkl
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

# Change ownership so ec2-user can write state
mkdir -p /home/ec2-user/.pel/formae/data
chown -R ec2-user:ec2-user /home/ec2-user/.pel
chown ec2-user:ec2-user /etc/formae/formae.conf.pkl

systemctl daemon-reload
systemctl enable formae-agent
systemctl start formae-agent
USERDATA
)

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type t3.micro \
  --key-name $KEY_NAME \
  --security-group-ids $SG_ID \
  --user-data "$USER_DATA" \
  --region $REGION \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=app,Value=formae-agent}]" \
  --query "Instances[0].InstanceId" \
  --output text)

echo "  Instance: $INSTANCE_ID"
echo "  Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID --region $REGION

PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --region $REGION \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text)

# ── 5. Done ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Instance running!"
echo "  Public IP: $PUBLIC_IP"
echo ""
echo "  Waiting 60s for Formae agent to start..."
sleep 60
echo ""
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://$PUBLIC_IP:11144/api/v1/health" 2>/dev/null || echo "000")
echo "  Health check: $HTTP_CODE"
echo ""
echo "  Agent URL: http://$PUBLIC_IP:11144"
echo ""
echo "  Add this to GitHub repo variables:"
echo "  FORMAE_AGENT_URL = http://$PUBLIC_IP:11144"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
