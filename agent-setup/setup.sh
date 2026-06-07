#!/usr/bin/env bash
# Formae Agent — AWS ECS Express Setup
# Deploys a persistent Formae agent backed by Aurora Serverless v2
# Run: bash setup.sh

set -euo pipefail

REGION="us-east-1"
FORMAE_VERSION="0.83.2"
DB_CLUSTER="formae-db"
DB_SECRET="formae-db-creds"
CONFIG_SECRET="formae-config"
SERVICE_NAME="formae-agent"
DB_PASSWORD=$(openssl rand -base64 20 | tr -dc 'A-Za-z0-9' | head -c 20)

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Formae Agent — ECS Express Setup"
echo "  Account: $ACCOUNT_ID  |  Region: $REGION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. DB credentials secret ────────────────────────────────────────────────
echo ""
echo "[ 1/9 ] Creating database credentials secret..."
aws secretsmanager create-secret \
  --name $DB_SECRET \
  --region $REGION \
  --secret-string "{\"username\":\"postgres\",\"password\":\"$DB_PASSWORD\"}" \
  --tags Key=app,Value=formae-agent \
  --output text --query Name 2>/dev/null || echo "  Secret already exists, skipping"

# ── 2. Aurora Serverless v2 cluster ─────────────────────────────────────────
echo ""
echo "[ 2/9 ] Creating Aurora Serverless v2 cluster (takes ~5 min)..."
aws rds create-db-cluster \
  --db-cluster-identifier $DB_CLUSTER \
  --engine aurora-postgresql \
  --engine-version 16.4 \
  --serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=2 \
  --master-username postgres \
  --master-user-password "$DB_PASSWORD" \
  --enable-http-endpoint \
  --region $REGION \
  --tags Key=app,Value=formae-agent \
  --output text --query DBCluster.DBClusterIdentifier 2>/dev/null || echo "  Cluster already exists, skipping"

aws rds wait db-cluster-available --db-cluster-identifier $DB_CLUSTER --region $REGION

aws rds create-db-instance \
  --db-instance-identifier formae-db-instance \
  --db-cluster-identifier $DB_CLUSTER \
  --db-instance-class db.serverless \
  --engine aurora-postgresql \
  --region $REGION \
  --tags Key=app,Value=formae-agent \
  --output text --query DBInstance.DBInstanceIdentifier 2>/dev/null || echo "  DB instance already exists, skipping"

aws rds wait db-instance-available --db-instance-identifier formae-db-instance --region $REGION

# ── 3. Create formae database ────────────────────────────────────────────────
echo ""
echo "[ 3/9 ] Creating formae database..."
CLUSTER_ARN=$(aws rds describe-db-clusters \
  --db-cluster-identifier $DB_CLUSTER \
  --region $REGION \
  --query "DBClusters[0].DBClusterArn" --output text)

SECRET_ARN=$(aws secretsmanager describe-secret \
  --secret-id $DB_SECRET \
  --region $REGION \
  --query "ARN" --output text)

aws rds-data execute-statement \
  --resource-arn "$CLUSTER_ARN" \
  --secret-arn "$SECRET_ARN" \
  --region $REGION \
  --sql "CREATE DATABASE formae" 2>/dev/null || echo "  Database already exists, skipping"

# ── 4. IAM Roles ─────────────────────────────────────────────────────────────
echo ""
echo "[ 4/9 ] Creating IAM roles..."

create_role_if_missing() {
  local ROLE=$1
  local PRINCIPAL=$2
  aws iam get-role --role-name "$ROLE" --output text --query Role.RoleName 2>/dev/null && return
  aws iam create-role --role-name "$ROLE" \
    --assume-role-policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [{
        \"Effect\": \"Allow\",
        \"Principal\": {\"Service\": \"$PRINCIPAL\"},
        \"Action\": \"sts:AssumeRole\"
      }]
    }" \
    --tags Key=app,Value=formae-agent \
    --output text --query Role.RoleName
}

create_role_if_missing "ecsTaskExecutionRole" "ecs-tasks.amazonaws.com"
create_role_if_missing "ecsInfrastructureRoleForExpressServices" "ecs.amazonaws.com"
create_role_if_missing "formae-ecs-task-role" "ecs-tasks.amazonaws.com"

aws iam attach-role-policy --role-name ecsTaskExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy 2>/dev/null || true

aws iam attach-role-policy --role-name ecsInfrastructureRoleForExpressServices \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSInfrastructureRoleforExpressGatewayServices 2>/dev/null || true

aws iam attach-role-policy --role-name formae-ecs-task-role \
  --policy-arn arn:aws:iam::aws:policy/PowerUserAccess 2>/dev/null || true

# Secrets access for execution role
aws iam put-role-policy --role-name ecsTaskExecutionRole \
  --policy-name formae-secrets-access \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": \"secretsmanager:GetSecretValue\",
      \"Resource\": \"arn:aws:secretsmanager:$REGION:$ACCOUNT_ID:secret:$CONFIG_SECRET*\"
    }]
  }"

# Aurora Data API access for task role
aws iam put-role-policy --role-name formae-ecs-task-role \
  --policy-name formae-data-api \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Effect\": \"Allow\",
        \"Action\": [
          \"rds-data:ExecuteStatement\",
          \"rds-data:BeginTransaction\",
          \"rds-data:CommitTransaction\",
          \"rds-data:RollbackTransaction\"
        ],
        \"Resource\": \"$CLUSTER_ARN\"
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": \"secretsmanager:GetSecretValue\",
        \"Resource\": \"arn:aws:secretsmanager:$REGION:$ACCOUNT_ID:secret:$DB_SECRET*\"
      }
    ]
  }"

# ── 5. Agent config ───────────────────────────────────────────────────────────
echo ""
echo "[ 5/9 ] Creating agent config..."
cat > /tmp/formae.conf.pkl << PKLEOF
amends "formae:/Config.pkl"

import "plugins:/Aws.pkl" as Aws

agent {
    datastore {
        datastoreType = "auroradataapi"
        auroraDataAPI {
            clusterArn = "$CLUSTER_ARN"
            secretArn  = "$SECRET_ARN"
            database   = "formae"
            region     = "$REGION"
        }
    }

    resourcePlugins {
        new Aws.PluginConfig {
            discoveryFilters = new Listing {
                new {
                    resourceTypes = new Listing {
                        "AWS::ElasticLoadBalancingV2::LoadBalancer"
                        "AWS::ElasticLoadBalancingV2::TargetGroup"
                        "AWS::ElasticLoadBalancingV2::Listener"
                        "AWS::EC2::SecurityGroup"
                        "AWS::Logs::LogGroup"
                        "AWS::CloudWatch::Alarm"
                    }
                    conditions = new Listing {
                        new {
                            propertyPath  = "$.Tags[?(@.Key=='AmazonECSManaged')].Value"
                            propertyValue = "true"
                        }
                    }
                }
                new {
                    resourceTypes = new Listing {
                        "AWS::IAM::Role"
                        "AWS::ECS::Service"
                        "AWS::ECS::TaskDefinition"
                        "AWS::RDS::DBCluster"
                        "AWS::RDS::DBInstance"
                        "AWS::SecretsManager::Secret"
                    }
                    conditions = new Listing {
                        new {
                            propertyPath  = "$.Tags[?(@.Key=='app')].Value"
                            propertyValue = "formae-agent"
                        }
                    }
                }
            }
        }
    }
}
PKLEOF

# ── 6. Store config in Secrets Manager ───────────────────────────────────────
echo ""
echo "[ 6/9 ] Storing agent config in Secrets Manager..."
aws secretsmanager create-secret \
  --name $CONFIG_SECRET \
  --region $REGION \
  --secret-string file:///tmp/formae.conf.pkl \
  --tags Key=app,Value=formae-agent \
  --output text --query Name 2>/dev/null || \
aws secretsmanager put-secret-value \
  --secret-id $CONFIG_SECRET \
  --region $REGION \
  --secret-string file:///tmp/formae.conf.pkl

CONFIG_SECRET_ARN=$(aws secretsmanager describe-secret \
  --secret-id $CONFIG_SECRET \
  --region $REGION \
  --query "ARN" --output text)

# ── 7. Deploy ECS Express service ─────────────────────────────────────────────
echo ""
echo "[ 7/9 ] Deploying Formae agent to ECS Express..."
SERVICE_URL=$(aws ecs create-express-gateway-service \
  --service-name $SERVICE_NAME \
  --region $REGION \
  --execution-role-arn "arn:aws:iam::$ACCOUNT_ID:role/ecsTaskExecutionRole" \
  --infrastructure-role-arn "arn:aws:iam::$ACCOUNT_ID:role/ecsInfrastructureRoleForExpressServices" \
  --task-role-arn "arn:aws:iam::$ACCOUNT_ID:role/formae-ecs-task-role" \
  --primary-container "{
    \"image\": \"ghcr.io/platform-engineering-labs/formae:$FORMAE_VERSION\",
    \"containerPort\": 49684,
    \"secrets\": [
      {\"name\": \"FORMAE_CONFIG\", \"valueFrom\": \"$CONFIG_SECRET_ARN\"}
    ],
    \"command\": [\"sh\", \"-c\", \"printenv FORMAE_CONFIG > /tmp/formae.conf.pkl && formae agent start --config /tmp/formae.conf.pkl\"]
  }" \
  --health-check-path "/api/v1/health" \
  --cpu 1024 \
  --memory 2048 \
  --tags key=app,value=formae-agent \
  --query "serviceConnectConfiguration.services[0].clientAliases[0].dnsName" \
  --output text 2>/dev/null || echo "")

# Fallback: get URL from describe
if [ -z "$SERVICE_URL" ]; then
  SERVICE_URL=$(aws ecs describe-services \
    --cluster default \
    --services $SERVICE_NAME \
    --region $REGION \
    --query "services[0].loadBalancers[0].dnsName" \
    --output text 2>/dev/null || echo "")
fi

# ── 8. Configure local CLI ────────────────────────────────────────────────────
echo ""
echo "[ 8/9 ] Waiting for agent health check..."
sleep 30
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://$SERVICE_URL/api/v1/health" 2>/dev/null || echo "000")
echo "  Health check: $HTTP_CODE"

# ── 9. Summary ────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Setup complete!"
echo ""
echo "  Agent URL: https://$SERVICE_URL"
echo ""
echo "  Next steps:"
echo "  1. Add to GitHub repo variable:"
echo "     FORMAE_AGENT_URL = https://$SERVICE_URL"
echo ""
echo "  2. Test locally:"
echo "     formae status agent --agent https://$SERVICE_URL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
