# IB Gateway on AWS Fargate

Simple deployment and management of Interactive Brokers Gateway on AWS ECS Fargate.

## Prerequisites

- AWS CLI configured with appropriate permissions
- Your IB credentials in `.env` file

## Quick Start

```bash
# Deploy to AWS Fargate
./aws-fargate.sh deploy

# Get public IP and API endpoints
./aws-fargate.sh ip

# Check status
./aws-fargate.sh status

# View logs
./aws-fargate.sh logs
```

## Configuration

Update `.env` file with your IB credentials and settings:

```bash
TWS_USERID=your_username
TWS_PASSWORD=your_password
TRADING_MODE=paper  # or live
```

## Management Commands

| Command | Description |
|---------|-------------|
| `deploy` | Deploy IB Gateway to AWS Fargate |
| `status` | Show service status |
| `ip` | Get public IP and API endpoints |
| `logs` | Show live logs |
| `restart` | Restart the service |
| `update` | Update service with new .env settings |
| `delete` | Delete all AWS resources |

## API Access

Once deployed, your applications can connect to:
- **Paper Trading:** `PUBLIC_IP:4004`
- **Live Trading:** `PUBLIC_IP:4003`

## Cost

Estimated cost: ~$30-50/month for 24/7 operation on AWS Fargate.

## Security

- Uses default VPC with public IP
- Security group allows API ports (4003, 4004) from anywhere
- For production, restrict security group to your IP ranges