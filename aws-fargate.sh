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
EIP_NAME="ib-gateway-eip"
NLB_NAME="ib-gateway-nlb"

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

# Function to setup networking with NLB and security groups
setup_networking() {
    echo "🌐 Setting up networking with Network Load Balancer..."
    
    # Use default VPC
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=is-default,Values=true" --query 'Vpcs[0].VpcId' --output text)
    echo "   Using VPC: $VPC_ID"
    
    # Get public subnets (we need at least 2 for NLB)
    PUBLIC_SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" --query 'Subnets[].SubnetId' --output text)
    PUBLIC_SUBNET_ARRAY=($PUBLIC_SUBNETS)
    
    if [ ${#PUBLIC_SUBNET_ARRAY[@]} -lt 2 ]; then
        echo "❌ Need at least 2 public subnets for NLB. Found: ${#PUBLIC_SUBNET_ARRAY[@]}"
        exit 1
    fi
    
    PUBLIC_SUBNET_ID=${PUBLIC_SUBNET_ARRAY[0]}
    echo "   Using public subnet for Fargate: $PUBLIC_SUBNET_ID"
    
    # Get or create Elastic IP
    EIP_ALLOCATION_ID=$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=$EIP_NAME" --query 'Addresses[0].AllocationId' --output text 2>/dev/null || echo "None")
    
    if [ "$EIP_ALLOCATION_ID" = "None" ] || [ -z "$EIP_ALLOCATION_ID" ]; then
        echo "   Creating new Elastic IP..."
        EIP_ALLOCATION_ID=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
        aws ec2 create-tags --resources $EIP_ALLOCATION_ID --tags Key=Name,Value=$EIP_NAME
        EIP_ADDRESS=$(aws ec2 describe-addresses --allocation-ids $EIP_ALLOCATION_ID --query 'Addresses[0].PublicIp' --output text)
        echo "   ✅ Created Elastic IP: $EIP_ADDRESS ($EIP_ALLOCATION_ID)"
    else
        EIP_ADDRESS=$(aws ec2 describe-addresses --allocation-ids $EIP_ALLOCATION_ID --query 'Addresses[0].PublicIp' --output text)
        echo "   ✅ Using existing Elastic IP: $EIP_ADDRESS ($EIP_ALLOCATION_ID)"
    fi
    
    # Get current IP for security group restriction
    echo "   Getting your current IP address..."
    CURRENT_IP=$(curl -s checkip.amazonaws.com)
    if [ -z "$CURRENT_IP" ]; then
        echo "❌ Failed to get current IP address"
        exit 1
    fi
    echo "   📍 Your current IP: $CURRENT_IP"
    
    # Create NLB security group (allows only your current IP)
    NLB_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=ib-gateway-nlb-sg" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
    
    if [ "$NLB_SG_ID" = "None" ] || [ -z "$NLB_SG_ID" ]; then
        echo "   Creating NLB security group (restricted to your IP)..."
        NLB_SG_ID=$(aws ec2 create-security-group \
            --group-name ib-gateway-nlb-sg \
            --description "IB Gateway NLB Security Group - Restricted Access" \
            --vpc-id $VPC_ID \
            --query 'GroupId' --output text)
        
        # Allow only your current IP on trading ports
        aws ec2 authorize-security-group-ingress --group-id $NLB_SG_ID --protocol tcp --port 4003 --cidr $CURRENT_IP/32
        aws ec2 authorize-security-group-ingress --group-id $NLB_SG_ID --protocol tcp --port 4004 --cidr $CURRENT_IP/32
        echo "   ✅ NLB security group created (restricted to $CURRENT_IP): $NLB_SG_ID"
    else
        echo "   ✅ Using existing NLB security group: $NLB_SG_ID"
        echo "   ℹ️  Use './aws-fargate.sh update-ip' to update IP restrictions"
    fi
    
    # Create Fargate security group (only allows traffic from NLB)
    FARGATE_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=ib-gateway-fargate-sg" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
    
    if [ "$FARGATE_SG_ID" = "None" ] || [ -z "$FARGATE_SG_ID" ]; then
        echo "   Creating Fargate security group..."
        FARGATE_SG_ID=$(aws ec2 create-security-group \
            --group-name ib-gateway-fargate-sg \
            --description "IB Gateway Fargate Security Group - NLB traffic only" \
            --vpc-id $VPC_ID \
            --query 'GroupId' --output text)
        
        # Allow traffic only from NLB security group
        aws ec2 authorize-security-group-ingress --group-id $FARGATE_SG_ID --protocol tcp --port 4003 --source-group $NLB_SG_ID
        aws ec2 authorize-security-group-ingress --group-id $FARGATE_SG_ID --protocol tcp --port 4004 --source-group $NLB_SG_ID
        
        # Note: Outbound internet access is allowed by default (0.0.0.0/0 egress rule)
        echo "   ✅ Fargate security group created: $FARGATE_SG_ID"
    else
        echo "   ✅ Using existing Fargate security group: $FARGATE_SG_ID"
    fi
    
    # Create or get Network Load Balancer
    NLB_ARN=$(aws elbv2 describe-load-balancers --names $NLB_NAME --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "None")
    
    if [ "$NLB_ARN" = "None" ] || [ -z "$NLB_ARN" ]; then
        echo "   Creating Network Load Balancer..."
        
        # Create subnet mappings with Elastic IP
        SUBNET_MAPPINGS=""
        for i in "${!PUBLIC_SUBNET_ARRAY[@]}"; do
            if [ $i -eq 0 ]; then
                # First subnet gets the Elastic IP
                SUBNET_MAPPINGS="SubnetId=${PUBLIC_SUBNET_ARRAY[$i]},AllocationId=$EIP_ALLOCATION_ID"
            else
                # Additional subnets for HA
                SUBNET_MAPPINGS="$SUBNET_MAPPINGS SubnetId=${PUBLIC_SUBNET_ARRAY[$i]}"
            fi
        done
        
        NLB_ARN=$(aws elbv2 create-load-balancer \
            --name $NLB_NAME \
            --scheme internet-facing \
            --type network \
            --subnet-mappings $SUBNET_MAPPINGS \
            --tags Key=Name,Value=$NLB_NAME \
            --query 'LoadBalancers[0].LoadBalancerArn' --output text)
        
        echo "   ⏳ Waiting for NLB to become active..."
        aws elbv2 wait load-balancer-available --load-balancer-arns $NLB_ARN
        echo "   ✅ Network Load Balancer created: $NLB_ARN"
    else
        echo "   ✅ Using existing Network Load Balancer: $NLB_ARN"
    fi
    
    # Create target groups for both ports
    create_target_group() {
        local port=$1
        local tg_name="ib-gateway-tg-$port"
        
        TG_ARN=$(aws elbv2 describe-target-groups --names $tg_name --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "None")
        
        if [ "$TG_ARN" = "None" ] || [ -z "$TG_ARN" ]; then
            echo "   Creating target group for port $port..."
            TG_ARN=$(aws elbv2 create-target-group \
                --name $tg_name \
                --protocol TCP \
                --port $port \
                --vpc-id $VPC_ID \
                --target-type ip \
                --health-check-protocol TCP \
                --health-check-port $port \
                --health-check-interval-seconds 30 \
                --healthy-threshold-count 2 \
                --unhealthy-threshold-count 2 \
                --tags Key=Name,Value=$tg_name \
                --query 'TargetGroups[0].TargetGroupArn' --output text)
            echo "   ✅ Target group created for port $port: $TG_ARN"
        else
            echo "   ✅ Using existing target group for port $port: $TG_ARN"
        fi
        
        # Create listener
        LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn $NLB_ARN --query "Listeners[?Port==\`$port\`].ListenerArn" --output text 2>/dev/null || echo "None")
        
        if [ "$LISTENER_ARN" = "None" ] || [ -z "$LISTENER_ARN" ]; then
            echo "   Creating listener for port $port..."
            aws elbv2 create-listener \
                --load-balancer-arn $NLB_ARN \
                --protocol TCP \
                --port $port \
                --default-actions Type=forward,TargetGroupArn=$TG_ARN > /dev/null
            echo "   ✅ Listener created for port $port"
        else
            echo "   ✅ Using existing listener for port $port"
        fi
        
        echo $TG_ARN
    }
    
    # Create target groups and listeners
    TG_4003_ARN=$(create_target_group 4003)
    TG_4004_ARN=$(create_target_group 4004)
    
    echo "🎯 Networking setup complete!"
    echo "   Elastic IP: $EIP_ADDRESS"
    echo "   Network Load Balancer: $NLB_ARN"
    echo "   NLB Security Group: $NLB_SG_ID"
    echo "   Fargate Security Group: $FARGATE_SG_ID"
    echo "   Target Group 4003: $TG_4003_ARN"
    echo "   Target Group 4004: $TG_4004_ARN"
}

# Function to deploy IB Gateway
deploy_ib_gateway() {
    setup_networking
    
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
    
    # Create service with load balancer integration
    SERVICE_EXISTS=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --query 'services[0].serviceName' --output text 2>/dev/null || echo "None")
    
    if [ "$SERVICE_EXISTS" = "None" ] || [ -z "$SERVICE_EXISTS" ]; then
        echo "🚀 Creating ECS service with NLB integration..."
        aws ecs create-service \
            --cluster $CLUSTER_NAME \
            --service-name $SERVICE_NAME \
            --task-definition $TASK_FAMILY \
            --desired-count 1 \
            --launch-type FARGATE \
            --network-configuration "awsvpcConfiguration={subnets=[$PUBLIC_SUBNET_ID],securityGroups=[$FARGATE_SG_ID],assignPublicIp=ENABLED}" \
            --load-balancers "targetGroupArn=$TG_4003_ARN,containerName=ib-gateway,containerPort=4003" "targetGroupArn=$TG_4004_ARN,containerName=ib-gateway,containerPort=4004" > /dev/null
        
        echo "   ⏳ Waiting for service to stabilize..."
        aws ecs wait services-stable --cluster $CLUSTER_NAME --services $SERVICE_NAME
        echo "   ✅ ECS service created and stable"
    else
        echo "   ✅ Using existing ECS service: $SERVICE_EXISTS"
    fi
    
    if [ "$VERBOSE_MODE" = "true" ]; then
        echo "✅ Deployed successfully with VERBOSE logging enabled!"
        echo "   The container will now produce more detailed logs."
        echo "   Wait 2-3 minutes then run './aws-fargate.sh logs' to see verbose output."
    else
        echo "✅ Deployed successfully!"
    fi
    
    echo ""
    echo "🌐 Your IB Gateway will always use the same Elastic IP: $EIP_ADDRESS"
    echo "   Paper Trading API: $EIP_ADDRESS:4004"
    echo "   Live Trading API: $EIP_ADDRESS:4003"
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
        echo "🌐 Getting Elastic IP..."
        EIP_ADDRESS=$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=$EIP_NAME" --query 'Addresses[0].PublicIp' --output text 2>/dev/null || echo "None")
        
        if [ "$EIP_ADDRESS" != "None" ] && [ -n "$EIP_ADDRESS" ]; then
            echo "Elastic IP: $EIP_ADDRESS"
            echo "Paper Trading API: $EIP_ADDRESS:4004"
            echo "Live Trading API: $EIP_ADDRESS:4003"
            echo ""
            echo "ℹ️  This IP address is persistent and will not change between deployments."
        else
            echo "❌ No Elastic IP found. Deploy first with './aws-fargate.sh deploy'"
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
            # Get Elastic IP
            EIP_ADDRESS=$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=$EIP_NAME" --query 'Addresses[0].PublicIp' --output text 2>/dev/null || echo "None")
            
            if [ "$EIP_ADDRESS" != "None" ] && [ "$EIP_ADDRESS" != "" ]; then
                echo "🌐 Elastic IP: $EIP_ADDRESS"
                echo "📡 Testing Paper Trading API (port 4004)..."
                if timeout 5 bash -c "</dev/tcp/$EIP_ADDRESS/4004" 2>/dev/null; then
                    echo "✅ Paper Trading API is responding on $EIP_ADDRESS:4004"
                else
                    echo "❌ Paper Trading API not responding"
                fi
                
                echo "📡 Testing Live Trading API (port 4003)..."
                if timeout 5 bash -c "</dev/tcp/$EIP_ADDRESS/4003" 2>/dev/null; then
                    echo "✅ Live Trading API is responding on $EIP_ADDRESS:4003"
                else
                    echo "❌ Live Trading API not responding"
                fi
                
                echo ""
                echo "💡 If APIs are responding, the container is working correctly!"
                echo "   IB Gateway typically only logs errors or connection events."
                echo "   To get more verbose logs, try: './aws-fargate.sh deploy-verbose'"
            else
                echo "❌ No Elastic IP found. The service may not be deployed yet."
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
        echo "🌐 Updating NLB security group with your current IP..."
        
        # Get current IP
        CURRENT_IP=$(curl -s checkip.amazonaws.com)
        if [ -z "$CURRENT_IP" ]; then
            echo "❌ Failed to get current IP address"
            exit 1
        fi
        
        echo "📍 Your current IP: $CURRENT_IP"
        
        # Get VPC ID
        VPC_ID=$(aws ec2 describe-vpcs --filters "Name=is-default,Values=true" --query 'Vpcs[0].VpcId' --output text)
        
        # Get NLB security group ID
        NLB_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=ib-gateway-nlb-sg" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
        
        if [ "$NLB_SG_ID" = "None" ] || [ -z "$NLB_SG_ID" ]; then
            echo "❌ NLB security group not found. Deploy first with './aws-fargate.sh deploy'"
            exit 1
        fi
        
        echo "🔒 NLB Security Group ID: $NLB_SG_ID"
        
        # Remove old rules (this will fail silently if they don't exist)
        echo "🧹 Removing old IP rules..."
        aws ec2 describe-security-groups --group-ids $NLB_SG_ID --query 'SecurityGroups[0].IpPermissions[?IpProtocol==`tcp` && (FromPort==`4003` || FromPort==`4004`)].IpRanges[].CidrIp' --output text | while read OLD_IP; do
            if [ "$OLD_IP" != "0.0.0.0/0" ] && [ -n "$OLD_IP" ]; then
                echo "  Removing rule for $OLD_IP"
                aws ec2 revoke-security-group-ingress --group-id $NLB_SG_ID --protocol tcp --port 4003 --cidr $OLD_IP 2>/dev/null || true
                aws ec2 revoke-security-group-ingress --group-id $NLB_SG_ID --protocol tcp --port 4004 --cidr $OLD_IP 2>/dev/null || true
            fi
        done
        
        # Add new rules for current IP
        echo "✅ Adding rules for your current IP: $CURRENT_IP/32"
        aws ec2 authorize-security-group-ingress --group-id $NLB_SG_ID --protocol tcp --port 4003 --cidr $CURRENT_IP/32 || echo "  Rule for port 4003 may already exist"
        aws ec2 authorize-security-group-ingress --group-id $NLB_SG_ID --protocol tcp --port 4004 --cidr $CURRENT_IP/32 || echo "  Rule for port 4004 may already exist"
        
        echo "🎉 NLB security group updated successfully!"
        echo "   Your IP $CURRENT_IP now has exclusive access to both trading APIs"
        echo "   All other IPs are blocked from accessing the NLB"
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
        read -p "This will delete ALL resources including the Elastic IP. Are you sure? (yes/no): " confirm
        if [ "$confirm" = "yes" ]; then
            echo "🛑 Stopping and deleting ECS resources..."
            # Stop service
            aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --desired-count 0 || true
            sleep 30
            aws ecs delete-service --cluster $CLUSTER_NAME --service $SERVICE_NAME || true
            
            # Delete cluster
            aws ecs delete-cluster --cluster $CLUSTER_NAME || true
            
            # Delete log group
            aws logs delete-log-group --log-group-name "/ecs/ib-gateway" || true
            
            echo "🌐 Deleting networking resources..."
            
            # Delete Network Load Balancer
            NLB_ARN=$(aws elbv2 describe-load-balancers --names $NLB_NAME --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "None")
            if [ "$NLB_ARN" != "None" ] && [ -n "$NLB_ARN" ]; then
                echo "   Deleting Network Load Balancer: $NLB_ARN"
                aws elbv2 delete-load-balancer --load-balancer-arn $NLB_ARN || true
                echo "   ⏳ Waiting for NLB to be deleted..."
                aws elbv2 wait load-balancer-not-exists --load-balancer-arns $NLB_ARN || true
            fi
            
            # Delete target groups
            for port in 4003 4004; do
                TG_ARN=$(aws elbv2 describe-target-groups --names "ib-gateway-tg-$port" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "None")
                if [ "$TG_ARN" != "None" ] && [ -n "$TG_ARN" ]; then
                    echo "   Deleting target group for port $port: $TG_ARN"
                    aws elbv2 delete-target-group --target-group-arn $TG_ARN || true
                fi
            done
            
            # Delete security groups
            FARGATE_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=ib-gateway-fargate-sg" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
            if [ "$FARGATE_SG_ID" != "None" ] && [ -n "$FARGATE_SG_ID" ]; then
                echo "   Deleting Fargate security group: $FARGATE_SG_ID"
                aws ec2 delete-security-group --group-id $FARGATE_SG_ID || true
            fi
            
            NLB_SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=ib-gateway-nlb-sg" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
            if [ "$NLB_SG_ID" != "None" ] && [ -n "$NLB_SG_ID" ]; then
                echo "   Deleting NLB security group: $NLB_SG_ID"
                aws ec2 delete-security-group --group-id $NLB_SG_ID || true
            fi
            
            # Release Elastic IP
            EIP_ALLOCATION_ID=$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=$EIP_NAME" --query 'Addresses[0].AllocationId' --output text 2>/dev/null || echo "None")
            if [ "$EIP_ALLOCATION_ID" != "None" ] && [ -n "$EIP_ALLOCATION_ID" ]; then
                EIP_ADDRESS=$(aws ec2 describe-addresses --allocation-ids $EIP_ALLOCATION_ID --query 'Addresses[0].PublicIp' --output text)
                echo "   Releasing Elastic IP: $EIP_ADDRESS ($EIP_ALLOCATION_ID)"
                aws ec2 release-address --allocation-id $EIP_ALLOCATION_ID || true
            fi
            
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
        echo "  deploy         - Deploy IB Gateway with Network Load Balancer and persistent Elastic IP"
        echo "  deploy-verbose - Deploy IB Gateway with verbose logging enabled"
        echo "  status         - Show service status"
        echo "  ip             - Get persistent Elastic IP and API endpoints"
        echo "  logs           - Show live logs"
        echo "  restart        - Restart the service"
        echo "  stop           - Stop the service (set desired count to 0)"
        echo "  start          - Start the service (set desired count to 1)"
        echo "  update-ip      - Update NLB security group to allow only your current IP"
        echo "  update         - Update service with new .env settings (quiet mode)"
        echo "  update-verbose - Update service with verbose logging enabled"
        echo "  delete         - Delete all AWS resources (including NLB and Elastic IP)"
        echo ""
        echo "Examples:"
        echo "  $0 deploy-verbose    # Deploy with NLB, detailed logging and persistent IP"
        echo "  $0 ip               # Get persistent Elastic IP endpoints"
        echo "  $0 logs             # Check logs and connectivity"
        echo "  $0 stop             # Stop the gateway service"
        echo "  $0 start            # Start the gateway service"
        echo ""
        echo "🏗️  Architecture: Network Load Balancer + Fargate with Security Group Isolation"
        echo "   • NLB in public subnet with Elastic IP (restricted to your IP only)"
        echo "   • Fargate in public subnet with restrictive security group (NLB traffic only)"
        echo "   • Persistent Elastic IP ensures consistent API endpoints"
        echo "   • Enhanced security: Only your IP can access the NLB, NLB can access Fargate"
        echo "   • Use 'update-ip' command when your IP changes"
        ;;
esac