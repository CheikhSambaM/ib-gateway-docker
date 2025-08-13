#!/bin/bash
set -e

# Load credentials from .env
source .env

AWS_REGION="us-east-2"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CLUSTER_NAME="ib-gateway-cluster"
SERVICE_NAME="ib-gateway-service"
TASK_FAMILY="ib-gateway-paper"

case "$1" in
    "deploy")
        echo "🚀 Deploying IB Gateway to AWS Fargate..."
        
        # Use default VPC
        VPC_ID=$(aws ec2 describe-vpcs --filters "Name=is-default,Values=true" --query 'Vpcs[0].VpcId' --output text)
        SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[0].SubnetId' --output text)
        
        # Create security group
        SG_ID=$(aws ec2 create-security-group \
            --group-name ib-gateway-sg-$(date +%s) \
            --description "IB Gateway" \
            --vpc-id $VPC_ID \
            --query 'GroupId' --output text)
        
        aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 4003 --cidr 0.0.0.0/0
        aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 4004 --cidr 0.0.0.0/0
        
        # Create cluster and log group
        aws ecs create-cluster --cluster-name $CLUSTER_NAME || true
        aws logs create-log-group --log-group-name "/ecs/ib-gateway" || true
        
        # Create task definition
        cat > task-definition.json << EOF
{
  "family": "$TASK_FAMILY",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "1024",
  "memory": "2048",
  "executionRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/ecsTaskExecutionRole",
  "containerDefinitions": [
    {
      "name": "ib-gateway",
      "image": "ghcr.io/gnzsnz/ib-gateway:stable",
      "essential": true,
      "portMappings": [
        {"containerPort": 4003, "protocol": "tcp"},
        {"containerPort": 4004, "protocol": "tcp"}
      ],
      "environment": [
        {"name": "TWS_USERID", "value": "$TWS_USERID"},
        {"name": "TWS_PASSWORD", "value": "$TWS_PASSWORD"},
        {"name": "TRADING_MODE", "value": "$TRADING_MODE"},
        {"name": "READ_ONLY_API", "value": "$READ_ONLY_API"},
        {"name": "TWS_ACCEPT_INCOMING", "value": "$TWS_ACCEPT_INCOMING"},
        {"name": "TWOFA_TIMEOUT_ACTION", "value": "$TWOFA_TIMEOUT_ACTION"},
        {"name": "RELOGIN_AFTER_TWOFA_TIMEOUT", "value": "$RELOGIN_AFTER_TWOFA_TIMEOUT"},
        {"name": "EXISTING_SESSION_DETECTED_ACTION", "value": "$EXISTING_SESSION_DETECTED_ACTION"},
        {"name": "BYPASS_WARNING", "value": "$BYPASS_WARNING"},
        {"name": "ALLOW_BLIND_TRADING", "value": "$ALLOW_BLIND_TRADING"},
        {"name": "AUTO_RESTART_TIME", "value": "$AUTO_RESTART_TIME"},
        {"name": "TWS_COLD_RESTART", "value": "$TWS_COLD_RESTART"},
        {"name": "SAVE_TWS_SETTINGS", "value": "$SAVE_TWS_SETTINGS"},
        {"name": "TIME_ZONE", "value": "$TIME_ZONE"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/ib-gateway",
          "awslogs-region": "$AWS_REGION",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ]
}
EOF
        
        # Register task definition and create service
        aws ecs register-task-definition --cli-input-json file://task-definition.json
        
        aws ecs create-service \
            --cluster $CLUSTER_NAME \
            --service-name $SERVICE_NAME \
            --task-definition $TASK_FAMILY \
            --desired-count 1 \
            --launch-type FARGATE \
            --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" || true
        
        echo "✅ Deployed successfully!"
        ;;
    
    "status")
        echo "📊 Service Status:"
        aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME \
            --query 'services[0].{Status:status,Running:runningCount,Desired:desiredCount}' --output table
        ;;
    
    "ip")
        echo "🌐 Getting public IP..."
        TASK_ARN=$(aws ecs list-tasks --cluster $CLUSTER_NAME --service-name $SERVICE_NAME --query 'taskArns[0]' --output text)
        if [ "$TASK_ARN" != "None" ]; then
            ENI_ID=$(aws ecs describe-tasks --cluster $CLUSTER_NAME --tasks $TASK_ARN --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text)
            PUBLIC_IP=$(aws ec2 describe-network-interfaces --network-interface-ids $ENI_ID --query 'NetworkInterfaces[0].Association.PublicIp' --output text)
            echo "Public IP: $PUBLIC_IP"
            echo "Paper Trading API: $PUBLIC_IP:4004"
            echo "Live Trading API: $PUBLIC_IP:4003"
        else
            echo "No running tasks found"
        fi
        ;;
    
    "logs")
        echo "📋 Recent logs:"
        aws logs tail /ecs/ib-gateway --follow
        ;;
    
    "restart")
        echo "🔄 Restarting service..."
        aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --force-new-deployment
        ;;
    
    "update")
        echo "🔧 Updating with new .env settings..."
        source .env
        # Re-register task definition with new environment variables
        cat > task-definition.json << EOF
{
  "family": "$TASK_FAMILY",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "1024",
  "memory": "2048",
  "executionRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/ecsTaskExecutionRole",
  "containerDefinitions": [
    {
      "name": "ib-gateway",
      "image": "ghcr.io/gnzsnz/ib-gateway:stable",
      "essential": true,
      "portMappings": [
        {"containerPort": 4003, "protocol": "tcp"},
        {"containerPort": 4004, "protocol": "tcp"}
      ],
      "environment": [
        {"name": "TWS_USERID", "value": "$TWS_USERID"},
        {"name": "TWS_PASSWORD", "value": "$TWS_PASSWORD"},
        {"name": "TRADING_MODE", "value": "$TRADING_MODE"},
        {"name": "READ_ONLY_API", "value": "$READ_ONLY_API"},
        {"name": "TWS_ACCEPT_INCOMING", "value": "$TWS_ACCEPT_INCOMING"},
        {"name": "TWOFA_TIMEOUT_ACTION", "value": "$TWOFA_TIMEOUT_ACTION"},
        {"name": "RELOGIN_AFTER_TWOFA_TIMEOUT", "value": "$RELOGIN_AFTER_TWOFA_TIMEOUT"},
        {"name": "EXISTING_SESSION_DETECTED_ACTION", "value": "$EXISTING_SESSION_DETECTED_ACTION"},
        {"name": "BYPASS_WARNING", "value": "$BYPASS_WARNING"},
        {"name": "ALLOW_BLIND_TRADING", "value": "$ALLOW_BLIND_TRADING"},
        {"name": "AUTO_RESTART_TIME", "value": "$AUTO_RESTART_TIME"},
        {"name": "TWS_COLD_RESTART", "value": "$TWS_COLD_RESTART"},
        {"name": "SAVE_TWS_SETTINGS", "value": "$SAVE_TWS_SETTINGS"},
        {"name": "TIME_ZONE", "value": "$TIME_ZONE"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/ib-gateway",
          "awslogs-region": "$AWS_REGION",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ]
}
EOF
        aws ecs register-task-definition --cli-input-json file://task-definition.json
        aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --task-definition $TASK_FAMILY
        echo "✅ Updated successfully!"
        ;;
    
    "delete")
        echo "🗑️ Deleting infrastructure..."
        read -p "This will delete ALL resources. Are you sure? (yes/no): " confirm
        if [ "$confirm" = "yes" ]; then
            # Stop service
            aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --desired-count 0 || true
            sleep 30
            aws ecs delete-service --cluster $CLUSTER_NAME --service $SERVICE_NAME || true
            
            # Delete cluster
            aws ecs delete-cluster --cluster $CLUSTER_NAME || true
            
            # Delete log group
            aws logs delete-log-group --log-group-name "/ecs/ib-gateway" || true
            
            # Clean up files
            rm -f task-definition.json
            
            echo "✅ Infrastructure deleted!"
        else
            echo "Deletion cancelled"
        fi
        ;;
    
    *)
        echo "IB Gateway AWS Fargate Management"
        echo ""
        echo "Usage: $0 <command>"
        echo ""
        echo "Commands:"
        echo "  deploy   - Deploy IB Gateway to AWS Fargate"
        echo "  status   - Show service status"
        echo "  ip       - Get public IP and API endpoints"
        echo "  logs     - Show live logs"
        echo "  restart  - Restart the service"
        echo "  update   - Update service with new .env settings"
        echo "  delete   - Delete all AWS resources"
        echo ""
        echo "Examples:"
        echo "  $0 deploy"
        echo "  $0 ip"
        echo "  $0 logs"
        ;;
esac