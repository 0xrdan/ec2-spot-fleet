#!/bin/bash
# ec2-spot-fleet: Spot Instance Launcher
#
# Launch EC2 spot instances with multi-AZ failover support.
#
# Usage:
#   ./launch-instance.sh launch [OPTIONS]
#   ./launch-instance.sh status
#   ./launch-instance.sh terminate
#   ./launch-instance.sh ssh
#
# Prerequisites:
#   - AWS CLI configured (aws configure)
#   - SSH key pair created in AWS
#   - Configuration in fleet.env

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source common functions
source "$SCRIPT_DIR/lib/common.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

# Load configuration
load_config "$PROJECT_DIR/fleet.env" || exit 1

# Default settings
INSTANCE_COUNT=1
PROFILE="${FLEET_PROFILE:-default}"
DRY_RUN=0
AVAILABILITY_ZONE=""

# Availability zones to try (in order of preference)
if [[ -z "${FLEET_AVAILABILITY_ZONES:-}" ]]; then
    AVAILABILITY_ZONES=("${FLEET_REGION}a" "${FLEET_REGION}b" "${FLEET_REGION}c")
else
    IFS=' ' read -ra AVAILABILITY_ZONES <<< "$FLEET_AVAILABILITY_ZONES"
fi

# State files directory
STATE_DIR="${FLEET_STATE_DIR:-$PROJECT_DIR/.state}"
mkdir -p "$STATE_DIR"

# =============================================================================
# CONFIGURATION VALIDATION
# =============================================================================

check_config() {
    local errors=0

    if [[ -z "${FLEET_KEY_NAME:-}" ]]; then
        error "FLEET_KEY_NAME not configured"
        errors=$((errors + 1))
    fi

    if [[ -z "${FLEET_SECURITY_GROUP:-}" ]]; then
        error "FLEET_SECURITY_GROUP not configured"
        errors=$((errors + 1))
    fi

    if [[ -z "${FLEET_AMI_ID:-}" ]]; then
        error "FLEET_AMI_ID not configured"
        errors=$((errors + 1))
    fi

    if [[ $errors -gt 0 ]]; then
        error "Please configure fleet.env"
        exit 1
    fi
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

parse_launch_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --profile)
                PROFILE="$2"
                shift 2
                ;;
            --count)
                INSTANCE_COUNT="$2"
                if ! is_positive_int "$INSTANCE_COUNT"; then
                    error "--count must be a positive integer"
                    exit 1
                fi
                shift 2
                ;;
            --az)
                AVAILABILITY_ZONE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --help|-h)
                show_launch_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_launch_help
                exit 1
                ;;
        esac
    done
}

show_launch_help() {
    echo "Usage: $0 launch [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --profile NAME   Instance profile from profiles.json (default: default)"
    echo "  --count N        Number of instances to launch (default: 1)"
    echo "  --az ZONE        Specific availability zone (default: auto-fallback)"
    echo "  --dry-run        Show what would be launched without launching"
    echo "  --help           Show this help"
    echo ""
    echo "Profiles are defined in configs/profiles.json"
    echo ""
    echo "Examples:"
    echo "  $0 launch                         # Launch with default profile"
    echo "  $0 launch --profile gpu-t4        # Launch with gpu-t4 profile"
    echo "  $0 launch --count 3               # Launch 3 instances"
}

# =============================================================================
# SPOT INSTANCE LAUNCH
# =============================================================================

# Try to launch in a specific AZ and wait for fulfillment
try_launch_in_az() {
    local az="$1"
    local instance_num="${2:-1}"
    local instance_type="$3"
    local spot_price="$4"

    log "Trying $az..."

    # User data script
    local user_data
    user_data=$(cat <<'USERDATA'
#!/bin/bash
set -e
sleep 15
apt-get update
apt-get install -y build-essential jq
touch /home/ubuntu/.setup-complete
USERDATA
)

    # Append custom user data if defined
    if [[ -n "${FLEET_USER_DATA:-}" ]]; then
        user_data="$user_data
$FLEET_USER_DATA"
    fi

    # Request spot instance
    local spot_result
    spot_result=$(aws ec2 request-spot-instances \
        --region "${FLEET_REGION}" \
        --instance-count 1 \
        --type "one-time" \
        --launch-specification "{
            \"ImageId\": \"${FLEET_AMI_ID}\",
            \"InstanceType\": \"$instance_type\",
            \"KeyName\": \"${FLEET_KEY_NAME}\",
            \"SecurityGroupIds\": [\"${FLEET_SECURITY_GROUP}\"],
            \"Placement\": {\"AvailabilityZone\": \"$az\"},
            \"UserData\": \"$(echo "$user_data" | base64 -w0)\"
        }" \
        --spot-price "$spot_price" \
        2>&1) || true

    if ! echo "$spot_result" | grep -q "SpotInstanceRequestId"; then
        log "  Request failed in $az"
        return 1
    fi

    local request_id
    request_id=$(echo "$spot_result" | grep -o 'sir-[a-z0-9]*')
    log "  Request: $request_id - waiting for fulfillment..."

    # Wait for spot request to be fulfilled (with 60s timeout)
    if ! timeout 60 aws ec2 wait spot-instance-request-fulfilled \
        --region "${FLEET_REGION}" \
        --spot-instance-request-ids "$request_id" 2>/dev/null; then
        local status
        status=$(aws ec2 describe-spot-instance-requests \
            --region "${FLEET_REGION}" \
            --spot-instance-request-ids "$request_id" \
            --query 'SpotInstanceRequests[0].Status.Code' \
            --output text 2>/dev/null || echo "unknown")
        log "  No capacity in $az (status: $status)"
        aws ec2 cancel-spot-instance-requests \
            --region "${FLEET_REGION}" \
            --spot-instance-request-ids "$request_id" >/dev/null 2>&1 || true
        return 1
    fi

    # Success - get instance ID
    SPOT_REQUEST_ID="$request_id"
    AVAILABILITY_ZONE="$az"
    INSTANCE_ID=$(aws ec2 describe-spot-instance-requests \
        --region "${FLEET_REGION}" \
        --spot-instance-request-ids "$request_id" \
        --query 'SpotInstanceRequests[0].InstanceId' \
        --output text)

    log "  Success: $INSTANCE_ID in $az"
    return 0
}

# Launch with AZ fallback
launch_with_fallback() {
    local instance_num="${1:-1}"
    local instance_type="$2"
    local spot_price="$3"

    # If specific AZ requested, only try that one
    if [[ -n "${AVAILABILITY_ZONE:-}" ]]; then
        if try_launch_in_az "$AVAILABILITY_ZONE" "$instance_num" "$instance_type" "$spot_price"; then
            return 0
        fi
        return 1
    fi

    # Try each AZ in order
    for az in "${AVAILABILITY_ZONES[@]}"; do
        if try_launch_in_az "$az" "$instance_num" "$instance_type" "$spot_price"; then
            return 0
        fi
    done

    error "No spot capacity in any availability zone"
    error "Tried: ${AVAILABILITY_ZONES[*]}"
    return 1
}

setup_instance() {
    local ip="$1"
    local key_file="${FLEET_KEY_FILE:-$HOME/.ssh/${FLEET_KEY_NAME}.pem}"

    log "Setting up instance at $ip..."

    # Wait for SSH
    if ! wait_for_ssh "$ip" 30; then
        error "SSH not available"
        return 1
    fi

    # Copy AWS credentials if they exist
    if [[ -f ~/.aws/credentials ]]; then
        log "  Copying AWS credentials..."
        ssh_cmd "$ip" "mkdir -p ~/.aws"
        scp_cmd ~/.aws/credentials ~/.aws/config ubuntu@"$ip":~/.aws/ 2>/dev/null || true
    fi

    # Sync workspace if configured
    if [[ -n "${FLEET_SYNC_PATH:-}" && -d "${FLEET_SYNC_PATH}" ]]; then
        log "  Syncing workspace from ${FLEET_SYNC_PATH}..."
        local workspace="${FLEET_WORKSPACE:-/home/ubuntu/work}"
        ssh_cmd "$ip" "mkdir -p $workspace"
        local exclude_args=""
        for excl in ${FLEET_SYNC_EXCLUDE:-target .git node_modules}; do
            exclude_args="$exclude_args --exclude $excl"
        done
        # shellcheck disable=SC2086
        rsync -az $exclude_args -e "ssh $(get_ssh_opts)" \
            "${FLEET_SYNC_PATH}/" ubuntu@"$ip":"$workspace/"
    fi

    log "  Instance setup complete"
}

launch_spot() {
    # Load profiles
    local profiles_file="$PROJECT_DIR/configs/profiles.json"
    if [[ ! -f "$profiles_file" ]]; then
        error "Profiles file not found: $profiles_file"
        exit 1
    fi

    local instance_type
    local spot_price
    instance_type=$(jq -r ".profiles[\"$PROFILE\"].type // empty" "$profiles_file")
    spot_price=$(jq -r ".profiles[\"$PROFILE\"].spot_price // empty" "$profiles_file")

    if [[ -z "$instance_type" ]]; then
        error "Unknown profile: $PROFILE"
        echo "Available profiles:"
        jq -r '.profiles | keys[]' "$profiles_file"
        exit 1
    fi

    log "Launching $INSTANCE_COUNT x $instance_type ($PROFILE profile)..."
    log "Max spot price: \$$spot_price/hr"

    # Dry run check
    if [[ "$DRY_RUN" == "1" ]]; then
        echo ""
        echo "=== DRY RUN ==="
        echo "Would launch: $INSTANCE_COUNT x $instance_type"
        echo "Profile:      $PROFILE"
        echo "Max price:    \$$spot_price/hr"
        echo "AZ fallback:  ${AVAILABILITY_ZONES[*]}"
        echo ""
        return 0
    fi

    # Track launched instances
    local instance_ids=()
    local instance_ips=()

    for i in $(seq 1 "$INSTANCE_COUNT"); do
        log "Launching instance $i of $INSTANCE_COUNT..."

        if ! launch_with_fallback "$i" "$instance_type" "$spot_price"; then
            error "Failed to launch instance $i"
            continue
        fi

        instance_ids+=("$INSTANCE_ID")

        # Tag the instance
        aws ec2 create-tags \
            --region "${FLEET_REGION}" \
            --resources "$INSTANCE_ID" \
            --tags "Key=Name,Value=${FLEET_PROJECT_TAG}-${i}" \
                   "Key=Project,Value=${FLEET_PROJECT_TAG}" \
                   "Key=Profile,Value=${PROFILE}"

        # Wait for running
        aws ec2 wait instance-running \
            --region "${FLEET_REGION}" \
            --instance-ids "$INSTANCE_ID"

        # Get IP
        sleep 3
        PUBLIC_IP=$(aws ec2 describe-instances \
            --region "${FLEET_REGION}" \
            --instance-ids "$INSTANCE_ID" \
            --query 'Reservations[0].Instances[0].PublicIpAddress' \
            --output text)
        instance_ips+=("$PUBLIC_IP")
    done

    # Save state
    if [[ ${#instance_ids[@]} -gt 0 ]]; then
        printf '%s\n' "${instance_ids[@]}" > "$STATE_DIR/instance-ids"
        echo "${instance_ids[0]}" > "$STATE_DIR/instance-id"
        echo "${instance_ips[0]}" > "$STATE_DIR/instance-ip"

        echo ""
        echo "=============================================="
        echo "  Profile:     $PROFILE ($instance_type)"
        echo "  Instances:   ${#instance_ids[@]} of $INSTANCE_COUNT launched"
        echo "=============================================="
        for idx in "${!instance_ids[@]}"; do
            echo "  [$((idx+1))] ${instance_ids[$idx]} - ${instance_ips[$idx]}"
        done
        echo "=============================================="

        # Setup each instance
        for ip in "${instance_ips[@]}"; do
            setup_instance "$ip"
        done

        echo ""
        echo "Connect with:"
        echo "  ssh -i ~/.ssh/${FLEET_KEY_NAME}.pem ubuntu@${instance_ips[0]}"
        echo ""
    else
        error "No instances were launched"
        return 1
    fi
}

# =============================================================================
# STATUS AND MANAGEMENT
# =============================================================================

get_status() {
    log "Checking status..."

    if [[ -f "$STATE_DIR/instance-id" ]]; then
        local instance_id
        instance_id=$(cat "$STATE_DIR/instance-id")
        local state
        state=$(aws ec2 describe-instances \
            --region "${FLEET_REGION}" \
            --instance-ids "$instance_id" \
            --query 'Reservations[0].Instances[0].State.Name' \
            --output text 2>/dev/null || echo "not-found")

        if [[ "$state" != "not-found" ]]; then
            local public_ip
            public_ip=$(aws ec2 describe-instances \
                --region "${FLEET_REGION}" \
                --instance-ids "$instance_id" \
                --query 'Reservations[0].Instances[0].PublicIpAddress' \
                --output text)

            echo "Instance: $instance_id"
            echo "State:    $state"
            echo "IP:       $public_ip"
        else
            echo "Instance $instance_id not found (may have been terminated)"
        fi
    else
        echo "No instance ID saved. Run: $0 launch"
    fi

    # Show all project instances
    echo ""
    echo "All ${FLEET_PROJECT_TAG} instances:"
    aws ec2 describe-instances \
        --region "${FLEET_REGION}" \
        --filters "Name=tag:Project,Values=${FLEET_PROJECT_TAG}" \
        --query 'Reservations[*].Instances[*].[InstanceId,State.Name,PublicIpAddress,Tags[?Key==`Name`].Value|[0]]' \
        --output table 2>/dev/null || echo "  None found"
}

terminate_instance() {
    if [[ -f "$STATE_DIR/instance-id" ]]; then
        local instance_id
        instance_id=$(cat "$STATE_DIR/instance-id")
        log "Terminating instance $instance_id..."

        aws ec2 terminate-instances \
            --region "${FLEET_REGION}" \
            --instance-ids "$instance_id"
        rm -f "$STATE_DIR/instance-id" "$STATE_DIR/instance-ip" "$STATE_DIR/spot-request-id"
        log "Instance terminated"
    else
        echo "No instance to terminate"
    fi
}

ssh_to_instance() {
    if [[ -f "$STATE_DIR/instance-ip" ]]; then
        local ip
        ip=$(cat "$STATE_DIR/instance-ip")
        local key_file="${FLEET_KEY_FILE:-$HOME/.ssh/${FLEET_KEY_NAME}.pem}"
        ssh -i "$key_file" ubuntu@"$ip"
    else
        error "No instance IP saved"
        exit 1
    fi
}

# =============================================================================
# MAIN
# =============================================================================

check_aws_cli || exit 1

case "${1:-}" in
    launch)
        shift
        parse_launch_args "$@"
        check_config
        launch_spot
        ;;
    status)
        load_config "$PROJECT_DIR/fleet.env" 2>/dev/null || true
        get_status
        ;;
    terminate)
        terminate_instance
        ;;
    ssh)
        ssh_to_instance
        ;;
    *)
        echo "Usage: $0 <command> [options]"
        echo ""
        echo "Commands:"
        echo "  launch [opts]    - Launch spot instance(s)"
        echo "  status           - Check instance status"
        echo "  terminate        - Terminate instance"
        echo "  ssh              - SSH into the instance"
        echo ""
        echo "Run '$0 launch --help' for launch options"
        ;;
esac
