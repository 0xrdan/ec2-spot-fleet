# ec2-spot-fleet

Generic spot instance fleet manager for running long-running jobs on AWS EC2 spot instances.

## Features

- **Multi-AZ Failover**: Automatically tries different availability zones when spot capacity is unavailable
- **Auto-Recovery**: Monitors instances and automatically recovers failed jobs
- **S3 Checkpointing**: Download checkpoints from S3 when recovering jobs
- **Email Alerts**: Get notified when instances go offline or jobs complete
- **Configurable Profiles**: Define instance types and spot prices in JSON

## Quick Start

### 1. Setup Configuration

```bash
# Copy example configs
cp fleet.env.example fleet.env
cp configs/instances.json.example configs/instances.json
cp configs/profiles.json.example configs/profiles.json

# Edit fleet.env with your AWS settings
vim fleet.env
```

### 2. Configure AWS Settings

Edit `fleet.env` with your:
- `FLEET_KEY_NAME` - SSH key pair name
- `FLEET_SECURITY_GROUP` - Security group ID (must allow SSH)
- `FLEET_AMI_ID` - AMI to use

### 3. Define Your Job

In `fleet.env`, configure:

```bash
JOB_NAME="my-job"
JOB_BUILD_CMD="make build"
JOB_START_CMD="./run.sh --start %START% --end %END% --checkpoint %CHECKPOINT%"
JOB_PROCESS_PATTERN="run.sh"
```

### 4. Configure Instances

Edit `configs/instances.json`:

```json
{
  "instances": [
    {"num": 1, "ip": "", "start": 1000, "end": 2000, "desc": "Range1"},
    {"num": 2, "ip": "", "start": 2001, "end": 3000, "desc": "Range2"}
  ]
}
```

### 5. Launch Instances

```bash
# Launch a single instance
./scripts/launch-instance.sh launch --profile gpu-t4

# Check status
./scripts/launch-instance.sh status

# SSH into instance
./scripts/launch-instance.sh ssh
```

### 6. Start Jobs

```bash
# Start job on instance 1
./scripts/recover-job.sh 1

# Start jobs on multiple instances
./scripts/recover-job.sh 1 2 3

# Start on all configured instances
./scripts/recover-job.sh all
```

### 7. Monitor Fleet

```bash
# One-time check
./scripts/monitor-fleet.sh

# Continuous monitoring
./scripts/monitor-fleet.sh --watch

# Monitor with auto-recovery
./scripts/monitor-fleet.sh --watch --auto-recover
```

## Directory Structure

```
ec2-spot-fleet/
├── fleet.env                    # Main configuration (create from example)
├── fleet.env.example            # Configuration template
├── scripts/
│   ├── launch-instance.sh       # Launch spot instances
│   ├── monitor-fleet.sh         # Monitor fleet, auto-recovery
│   ├── recover-job.sh           # Restart jobs on instances
│   └── lib/
│       ├── common.sh            # Shared functions
│       └── email.sh             # Email alerting
├── configs/
│   ├── instances.json           # Instance definitions (create from example)
│   ├── instances.json.example   # Instance config template
│   ├── profiles.json            # Instance profiles (create from example)
│   └── profiles.json.example    # Profiles template
└── examples/
    └── long-running-job/        # Example job configuration
```

## Configuration Reference

### fleet.env

| Variable | Description | Required |
|----------|-------------|----------|
| `FLEET_REGION` | AWS region | Yes |
| `FLEET_KEY_NAME` | SSH key pair name | Yes |
| `FLEET_SECURITY_GROUP` | Security group ID | Yes |
| `FLEET_AMI_ID` | AMI ID | Yes |
| `FLEET_PROJECT_TAG` | Project tag for resources | Yes |
| `FLEET_PROFILE` | Default instance profile | No |
| `FLEET_MAX_INSTANCES` | Safety limit | No |
| `FLEET_WORKSPACE` | Remote workspace path | No |
| `FLEET_SYNC_PATH` | Local path to sync | No |
| `JOB_START_CMD` | Command to start job | Yes (for jobs) |
| `JOB_PROCESS_PATTERN` | Pattern to detect running job | Yes (for jobs) |

See `fleet.env.example` for all options.

### instances.json

```json
{
  "instances": [
    {
      "num": 1,           // Instance number (unique)
      "ip": "1.2.3.4",    // Current IP (empty if not launched)
      "start": 1000,      // Start value for job
      "end": 2000,        // End value for job
      "desc": "Range1"    // Description
    }
  ]
}
```

### profiles.json

```json
{
  "profiles": {
    "gpu-t4": {
      "type": "g4dn.xlarge",
      "spot_price": "0.30",
      "description": "1x T4 GPU"
    }
  }
}
```

## Command Placeholders

In `JOB_START_CMD`, `JOB_SETUP_CMD`, and `JOB_LOG_PATTERN`, use these placeholders:

| Placeholder | Replaced With |
|-------------|---------------|
| `%NUM%` | Instance number |
| `%START%` | Start value from instances.json |
| `%END%` | End value from instances.json |
| `%CHECKPOINT%` | Checkpoint file path |
| `%LOG%` | Log file path |
| `%WORKSPACE%` | Workspace directory |

## Email Alerts

Configure SMTP settings in `fleet.env`:

```bash
FLEET_ALERT_EMAIL="alerts@example.com"
FLEET_SMTP_HOST="smtp.gmail.com"
FLEET_SMTP_PORT=587
FLEET_SMTP_USER="sender@gmail.com"
FLEET_SMTP_CREDENTIALS="/path/to/credentials.env"
```

Create credentials file (keep out of version control):

```bash
# /path/to/credentials.env
SMTP_PASS="your-app-password"
```

## S3 Checkpointing

Configure S3 bucket for checkpoints:

```bash
JOB_S3_BUCKET="my-checkpoints"
JOB_CHECKPOINT_PREFIX="checkpoint_"
```

Your job should:
1. Read checkpoint from `%CHECKPOINT%` file on startup
2. Periodically save progress to S3: `aws s3 cp checkpoint.txt s3://$JOB_S3_BUCKET/checkpoint_$NUM.txt`

## Security Notes

- Never commit `fleet.env` with real credentials
- Add to `.gitignore`:
  ```
  fleet.env
  .state/
  configs/instances.json
  *-credentials.env
  ```
- Use SMTP credential files instead of embedding passwords
- Review IAM permissions needed:
  - `ec2:*` for instance management
  - `s3:GetObject`, `s3:PutObject` for checkpointing

## Troubleshooting

### "No spot capacity in any availability zone"

All AZs are out of capacity for your instance type. Options:
- Wait and retry
- Try a different instance type/profile
- Use on-demand instances instead

### "SSH not available"

- Check security group allows port 22
- Verify key pair name matches
- Instance may still be initializing (wait 1-2 minutes)

### Jobs not detected as running

- Check `JOB_PROCESS_PATTERN` matches your process
- Verify with: `ssh ubuntu@IP 'pgrep -f "pattern"'`

## License

MIT
