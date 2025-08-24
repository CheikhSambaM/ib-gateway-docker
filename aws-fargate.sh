#!/bin/bash
set -e

# Disable AWS CLI pager
export AWS_PAGER=""

# Load credentials from .env
source .env

AWS_REGION="us-east-2"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CLUSTER_NAME="ib-gateway-cluster"
SERVICE_NAME="ib-gateway-service"
TASK_FAMILY="ib-gateway-paper"

# Function to create task definition with optional verbose settings
create_task_definition() {
    local verbose_env=""
    if [ "$VERBOSE_MODE" = "true" ]; then
        verbose_env=',
        {"name": "VNC_SERVER_PASSWORD", "value": ""},
        {"name": "DISPLAY", "value": ":1"},
        {"name": "VERBOSE", "value": "true"},
        {"name": "DEBUG", "value": "true"}'
    fi
    
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
        {"name": "TIME_ZONE", "value": "$TIME_ZONE"}$verbose_env
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
}

# Function to deploy IB Gateway
deploy_ib_gateway() {
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
    
    # Ensure the execution role has CloudWatch Logs permissions
    echo "🔧 Ensuring execution role has proper permissions..."
    aws iam attach-role-policy \
        --role-name ecsTaskExecutionRole \
        --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy || true
    
    # Create task definition
    create_task_definition
    
    # Register task definition and create service
    aws ecs register-task-definition --cli-input-json file://task-definition.json
    
    aws ecs create-service \
        --cluster $CLUSTER_NAME \
        --service-name $SERVICE_NAME \
        --task-definition $TASK_FAMILY \
        --desired-count 1 \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" || true
    
    if [ "$VERBOSE_MODE" = "true" ]; then
        echo "✅ Deployed successfully with VERBOSE logging enabled!"
        echo "   The container will now produce more detailed logs."
        echo "   Wait 2-3 minutes then run './aws-fargate.sh logs' to see verbose output."
    else
        echo "✅ Deployed successfully!"
    fi
}

case "$1" in
    "deploy")
        echo "🚀 Deploying IB Gateway to AWS Fargate..."
        VERBOSE_MODE="false"
        deploy_ib_gateway
        ;;
    
    "deploy-verbose")
        echo "🚀 Deploying IB Gateway to AWS Fargate (VERBOSE MODE)..."
        VERBOSE_MODE="true"
        deploy_ib_gateway
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
        
        # Use temp files for AWS CLI output
        TEMP_STREAMS=$(mktemp)
        TEMP_TASK=$(mktemp)
        
        # Check if there are any log streams
        aws logs describe-log-streams --log-group-name "/ecs/ib-gateway" --query 'logStreams[].logStreamName' --output text > $TEMP_STREAMS
        STREAMS=$(cat $TEMP_STREAMS)
        
        if [ -z "$STREAMS" ] || [ "$STREAMS" = "None" ]; then
            echo "⚠️  No log streams found. Let's diagnose the issue..."
            echo ""
            
            # Check current task status
            aws ecs list-tasks --cluster $CLUSTER_NAME --service-name $SERVICE_NAME --query 'taskArns[0]' --output text > $TEMP_TASK
            TASK_ARN=$(cat $TEMP_TASK)
            
            if [ "$TASK_ARN" != "None" ] && [ "$TASK_ARN" != "" ]; then
                echo "📊 Current task status:"
                aws ecs describe-tasks --cluster $CLUSTER_NAME --tasks $TASK_ARN --query 'tasks[0].{LastStatus:lastStatus,DesiredStatus:desiredStatus,HealthStatus:healthStatus,StoppedReason:stoppedReason,CreatedAt:createdAt}' --output table
                
                echo ""
                echo "📦 Container status:"
                aws ecs describe-tasks --cluster $CLUSTER_NAME --tasks $TASK_ARN --query 'tasks[0].containers[0].{Name:name,LastStatus:lastStatus,Reason:reason,ExitCode:exitCode}' --output table
            fi
            
            echo ""
            echo "ℹ️  IB Gateway container is running but not producing console logs."
            echo "   This is normal behavior - the application runs silently."
            echo ""
            echo "🧪 Testing connectivity..."
            if [ "$TASK_ARN" != "None" ] && [ "$TASK_ARN" != "" ]; then
                # Get public IP
                ENI_ID=$(aws ecs describe-tasks --cluster $CLUSTER_NAME --tasks $TASK_ARN --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text)
                PUBLIC_IP=$(aws ec2 describe-network-interfaces --network-interface-ids $ENI_ID --query 'NetworkInterfaces[0].Association.PublicIp' --output text)
                
                if [ "$PUBLIC_IP" != "None" ] && [ "$PUBLIC_IP" != "" ]; then
                    echo "🌐 Public IP: $PUBLIC_IP"
                    echo "📡 Testing Paper Trading API (port 4004)..."
                    if timeout 5 bash -c "</dev/tcp/$PUBLIC_IP/4004" 2>/dev/null; then
                        echo "✅ Paper Trading API is responding on $PUBLIC_IP:4004"
                    else
                        echo "❌ Paper Trading API not responding"
                    fi
                    
                    echo "📡 Testing Live Trading API (port 4003)..."
                    if timeout 5 bash -c "</dev/tcp/$PUBLIC_IP/4003" 2>/dev/null; then
                        echo "✅ Live Trading API is responding on $PUBLIC_IP:4003"
                    else
                        echo "❌ Live Trading API not responding"
                    fi
                    
                    echo ""
                    echo "💡 If APIs are responding, the container is working correctly!"
                    echo "   IB Gateway typically only logs errors or connection events."
                    echo "   To get more verbose logs, try: './aws-fargate.sh deploy-verbose'"
                fi
            fi
        else
            echo "✅ Found log streams:"
            echo "$STREAMS"
            echo ""
            echo "📋 Tailing logs (press Ctrl+C to stop):"
            aws logs tail /ecs/ib-gateway --follow
        fi
        
        # Cleanup temp files
        rm -f $TEMP_STREAMS $TEMP_TASK
        ;;
    
    "restart")
        echo "🔄 Restarting service..."
        aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --force-new-deployment
        ;;
    
    "stop")
        echo "⏹️  Stopping IB Gateway service..."
        aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --desired-count 0
        echo "✅ Service stopped. Use './aws-fargate.sh start' to restart it."
        ;;
    
    "start")
        echo "▶️  Starting IB Gateway service..."
        aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --desired-count 1
        echo "✅ Service started. Use './aws-fargate.sh status' to check status."
        ;;
    
    "update-ip")
        echo "🌐 Updating security group with your current IP..."
        
        # Get current IP
        CURRENT_IP=$(curl -s checkip.amazonaws.com)
        if [ -z "$CURRENT_IP" ]; then
            echo "❌ Failed to get current IP address"
            exit 1
        fi
        
        echo "📍 Your current IP: $CURRENT_IP"
        
        # Get the security group ID from the running task
        TASK_ARN=$(aws ecs list-tasks --cluster $CLUSTER_NAME --service-name $SERVICE_NAME --query 'taskArns[0]' --output text)
        if [ "$TASK_ARN" = "None" ] || [ -z "$TASK_ARN" ]; then
            echo "❌ No running tasks found. Deploy first with './aws-fargate.sh deploy'"
            exit 1
        fi
        
        # Get security group ID
        SG_ID=$(aws ecs describe-tasks --cluster $CLUSTER_NAME --tasks $TASK_ARN --query 'tasks[0].attachments[0].details[?name==`subnetId`]' --output text)
        # Actually get it from the network configuration
        SG_ID=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --query 'services[0].networkConfiguration.awsvpcConfiguration.securityGroups[0]' --output text)
        
        if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
            echo "❌ Could not find security group ID"
            exit 1
        fi
        
        echo "🔒 Security Group ID: $SG_ID"
        
        # Remove old rules (this will fail silently if they don't exist)
        echo "🧹 Removing old IP rules..."
        aws ec2 describe-security-groups --group-ids $SG_ID --query 'SecurityGroups[0].IpPermissions[?IpProtocol==`tcp` && (FromPort==`4003` || FromPort==`4004`)].IpRanges[].CidrIp' --output text | while read OLD_IP; do
            if [ "$OLD_IP" != "0.0.0.0/0" ] && [ -n "$OLD_IP" ]; then
                echo "  Removing rule for $OLD_IP"
                aws ec2 revoke-security-group-ingress --group-id $SG_ID --protocol tcp --port 4003 --cidr $OLD_IP 2>/dev/null || true
                aws ec2 revoke-security-group-ingress --group-id $SG_ID --protocol tcp --port 4004 --cidr $OLD_IP 2>/dev/null || true
            fi
        done
        
        # Add new rules for current IP
        echo "✅ Adding rules for your current IP: $CURRENT_IP/32"
        aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 4003 --cidr $CURRENT_IP/32 || echo "  Rule for port 4003 may already exist"
        aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 4004 --cidr $CURRENT_IP/32 || echo "  Rule for port 4004 may already exist"
        
        echo "🎉 Security group updated successfully!"
        echo "   Your IP $CURRENT_IP now has access to both trading APIs"
        ;;
    
    "update")
        echo "🔧 Updating with new .env settings..."
        source .env
        VERBOSE_MODE="false"
        create_task_definition
        aws ecs register-task-definition --cli-input-json file://task-definition.json
        aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --task-definition $TASK_FAMILY
        echo "✅ Updated successfully!"
        ;;
    
    "update-verbose")
        echo "🔧 Updating with new .env settings (VERBOSE MODE)..."
        source .env
        VERBOSE_MODE="true"
        create_task_definition
        aws ecs register-task-definition --cli-input-json file://task-definition.json
        aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --task-definition $TASK_FAMILY
        echo "✅ Updated successfully with verbose logging!"
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
        echo "  deploy         - Deploy IB Gateway to AWS Fargate (quiet mode)"
        echo "  deploy-verbose - Deploy IB Gateway with verbose logging enabled"
        echo "  status         - Show service status"
        echo "  ip             - Get public IP and API endpoints"
        echo "  logs           - Show live logs"
        echo "  restart        - Restart the service"
        echo "  stop           - Stop the service (set desired count to 0)"
        echo "  start          - Start the service (set desired count to 1)"
        echo "  update-ip      - Update security group with your current IP address"
        echo "  update         - Update service with new .env settings (quiet mode)"
        echo "  update-verbose - Update service with verbose logging enabled"
        echo "  delete         - Delete all AWS resources"
        echo ""
        echo "Examples:"
        echo "  $0 deploy-verbose    # Deploy with detailed logging"
        echo "  $0 ip               # Get connection endpoints"
        echo "  $0 logs             # Check logs and connectivity"
        echo "  $0 stop             # Stop the gateway service"
        echo "  $0 start            # Start the gateway service"
        ;;
esac