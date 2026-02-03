#!/bin/bash
# ec2-spot-fleet: Job Recovery Script
#
# Automatically recover jobs on spot instances that were reclaimed.
# This script handles:
#   1. Launching a new spot instance
#   2. Waiting for SSH availability
#   3. Syncing workspace
#   4. Downloading checkpoint from S3
#   5. Starting the job
#   6. Updating instance config with new IP
#
# Usage:
#   ./recover-job.sh <instance_num>           # Launch new instance and start job
#   ./recover-job.sh restart <num> [ip]       # Restart job on existing instance
#   ./recover-job.sh status                   # Show job status on all instances

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source common functions
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/email.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

# Load configuration
load_config "$PROJECT_DIR/fleet.env" || exit 1

# Safety limit
MAX_INSTANCES="${FLEET_MAX_INSTANCES:-10}"

# State directory
STATE_DIR="${FLEET_STATE_DIR:-$PROJECT_DIR/.state}"
mkdir -p "$STATE_DIR"

# =============================================================================
# JOB FUNCTIONS
# =============================================================================

# Build the project on instance (if build command configured)
build_on_instance() {
    local ip="$1"
    local num="$2"

    if [[ -z "${JOB_BUILD_CMD:-}" ]]; then
        log "[$num] No build command configured, skipping build"
        return 0
    fi

    log "[$num] Building on $ip..."

    # Install Rust if configured and needed
    if [[ "${JOB_INSTALL_RUST:-false}" == "true" ]]; then
        if ! ssh_cmd "$ip" "command -v cargo >/dev/null 2>&1"; then
            log "[$num] Installing Rust..."
            if ! ssh_cmd_timeout 120 "$ip" \
                "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"; then
                error "[$num] Failed to install Rust"
                return 1
            fi
        fi
    fi

    # Run build command
    log "[$num] Running build command..."
    local workspace="${FLEET_WORKSPACE:-/home/ubuntu/work}"
    if ! ssh_cmd "$ip" "cd $workspace && export PATH=\$HOME/.cargo/bin:\$PATH && $JOB_BUILD_CMD"; then
        error "[$num] Build failed"
        return 1
    fi

    log "[$num] Build complete"
}

# Setup checkpoint and configuration files on instance
setup_instance() {
    local ip="$1"
    local num="$2"
    local start_ts="$3"
    local end_ts="$4"

    log "[$num] Setting up instance..."

    # Download checkpoint from S3 if configured
    if [[ -n "${JOB_S3_BUCKET:-}" && -n "${JOB_CHECKPOINT_PREFIX:-}" ]]; then
        local checkpoint_file="${JOB_CHECKPOINT_PREFIX}${num}.txt"
        log "[$num] Checking S3 for checkpoint..."

        local s3_checkpoint
        s3_checkpoint=$(aws s3 cp "s3://${JOB_S3_BUCKET}/$checkpoint_file" - 2>/dev/null || echo "")

        if [[ -n "$s3_checkpoint" ]]; then
            log "[$num] Found S3 checkpoint: $s3_checkpoint"
            ssh_cmd "$ip" "echo '$s3_checkpoint' > /home/ubuntu/$checkpoint_file"
        else
            log "[$num] No checkpoint found, starting fresh"
            # Create initial checkpoint if start value provided
            if [[ -n "$start_ts" ]]; then
                ssh_cmd "$ip" "echo '$start_ts' > /home/ubuntu/$checkpoint_file"
            fi
        fi
    fi

    # Run custom setup hook if configured
    if [[ -n "${JOB_SETUP_CMD:-}" ]]; then
        log "[$num] Running setup command..."
        local workspace="${FLEET_WORKSPACE:-/home/ubuntu/work}"
        # Replace placeholders in setup command
        local setup_cmd="${JOB_SETUP_CMD}"
        setup_cmd="${setup_cmd//\%NUM\%/$num}"
        setup_cmd="${setup_cmd//\%START\%/$start_ts}"
        setup_cmd="${setup_cmd//\%END\%/$end_ts}"

        if ! ssh_cmd "$ip" "cd $workspace && $setup_cmd"; then
            error "[$num] Setup command failed"
            return 1
        fi
    fi

    log "[$num] Setup complete"
}

# Start the job on instance
start_job() {
    local ip="$1"
    local num="$2"
    local start_ts="$3"
    local end_ts="$4"

    if [[ -z "${JOB_START_CMD:-}" ]]; then
        error "[$num] JOB_START_CMD not configured"
        return 1
    fi

    local workspace="${FLEET_WORKSPACE:-/home/ubuntu/work}"
    local log_pattern="${JOB_LOG_PATTERN:-/home/ubuntu/job_%NUM%.log}"
    local log_file="${log_pattern//\%NUM\%/$num}"
    local checkpoint_file="${JOB_CHECKPOINT_PREFIX:-checkpoint_}${num}.txt"

    # Replace placeholders in start command
    local start_cmd="${JOB_START_CMD}"
    start_cmd="${start_cmd//\%NUM\%/$num}"
    start_cmd="${start_cmd//\%START\%/$start_ts}"
    start_cmd="${start_cmd//\%END\%/$end_ts}"
    start_cmd="${start_cmd//\%CHECKPOINT\%//home/ubuntu/$checkpoint_file}"
    start_cmd="${start_cmd//\%LOG\%/$log_file}"
    start_cmd="${start_cmd//\%WORKSPACE\%/$workspace}"

    log "[$num] Starting job..."
    log "[$num] Command: $start_cmd"

    # Build environment string
    local env_vars=""
    if [[ -n "${JOB_S3_BUCKET:-}" ]]; then
        env_vars="export JOB_S3_BUCKET=${JOB_S3_BUCKET} && "
    fi
    for var in ${JOB_ENV_VARS:-}; do
        if [[ -n "${!var:-}" ]]; then
            env_vars="${env_vars}export $var='${!var}' && "
        fi
    done

    # Start job in background using SSH -f
    ssh -i "${FLEET_KEY_FILE:-$HOME/.ssh/${FLEET_KEY_NAME}.pem}" \
        -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -f ubuntu@"$ip" \
        "cd $workspace && ${env_vars}export PATH=\$HOME/.cargo/bin:\$PATH && nohup $start_cmd > $log_file 2>&1 &"

    # Wait and verify process started
    sleep 3
    local process_pattern="${JOB_PROCESS_PATTERN:-$JOB_NAME}"
    local pid
    pid=$(ssh_cmd "$ip" "pgrep -f '$process_pattern' || echo ''" 2>/dev/null)

    if [[ -n "$pid" ]]; then
        log "[$num] Job started (PID: $pid)"
        return 0
    else
        error "[$num] Job process not running!"
        error "[$num] Check log: ssh ubuntu@$ip 'tail -50 $log_file'"
        return 1
    fi
}

# =============================================================================
# RECOVERY FUNCTIONS
# =============================================================================

# Launch new instance for job
launch_for_job() {
    local num="$1"

    log "[$num] Launching new spot instance..."

    cd "$SCRIPT_DIR"
    rm -f "$STATE_DIR/instance-id" "$STATE_DIR/instance-ip" 2>/dev/null || true

    if ! ./launch-instance.sh launch --profile "${FLEET_PROFILE:-default}" >&2; then
        error "[$num] Failed to launch instance"
        return 1
    fi

    if [[ -f "$STATE_DIR/instance-ip" ]]; then
        cat "$STATE_DIR/instance-ip"
    else
        error "[$num] No instance IP found after launch"
        return 1
    fi
}

# Sync workspace to instance
sync_workspace() {
    local ip="$1"
    local num="$2"

    if [[ -z "${FLEET_SYNC_PATH:-}" ]]; then
        log "[$num] No sync path configured, skipping"
        return 0
    fi

    log "[$num] Syncing workspace..."
    local workspace="${FLEET_WORKSPACE:-/home/ubuntu/work}"
    ssh_cmd "$ip" "mkdir -p $workspace"

    local exclude_args=""
    for excl in ${FLEET_SYNC_EXCLUDE:-target .git node_modules}; do
        exclude_args="$exclude_args --exclude $excl"
    done

    # shellcheck disable=SC2086
    rsync -az $exclude_args \
        -e "ssh $(get_ssh_opts)" \
        "${FLEET_SYNC_PATH}/" ubuntu@"$ip":"$workspace/"
}

# Full recovery: launch instance and start job
recover_instance() {
    local num="$1"

    # Load instance config
    load_instances "$PROJECT_DIR/configs/instances.json" || exit 1

    local config
    config=$(get_instance_config "$num")
    if [[ -z "$config" ]]; then
        error "Unknown instance number: $num"
        return 1
    fi

    local inst_num inst_ip start_ts end_ts desc
    read -r inst_num inst_ip start_ts end_ts desc <<< "$config"

    echo ""
    echo "=============================================="
    echo "  Recovering Instance $num: $desc"
    echo "  Range: $start_ts - $end_ts"
    echo "=============================================="
    echo ""

    # Safety check
    local running_count
    running_count=$(count_running_instances "${FLEET_PROJECT_TAG}")
    if [[ $running_count -ge $MAX_INSTANCES ]]; then
        error "[$num] Already at max instances ($running_count/$MAX_INSTANCES)"
        return 1
    fi
    log "[$num] Instance count: $running_count/$MAX_INSTANCES"

    # Step 1: Launch
    local ip
    ip=$(launch_for_job "$num")
    if [[ -z "$ip" ]]; then
        error "[$num] Launch failed"
        return 1
    fi
    log "[$num] Instance IP: $ip"

    # Step 2: Wait for SSH
    if ! wait_for_ssh "$ip"; then
        error "[$num] SSH wait failed"
        return 1
    fi

    # Step 3: Sync workspace
    if ! sync_workspace "$ip" "$num"; then
        error "[$num] Sync failed"
        return 1
    fi

    # Step 4: Build
    if ! build_on_instance "$ip" "$num"; then
        error "[$num] Build failed"
        return 1
    fi

    # Step 5: Setup
    if ! setup_instance "$ip" "$num" "$start_ts" "$end_ts"; then
        error "[$num] Setup failed"
        return 1
    fi

    # Step 6: Start job
    if ! start_job "$ip" "$num" "$start_ts" "$end_ts"; then
        error "[$num] Job start failed"
        return 1
    fi

    # Step 7: Update config
    update_instance_ip "$num" "$ip" "$PROJECT_DIR/configs/instances.json"

    echo ""
    log "[$num] SUCCESS - Instance $num recovered at $ip"
    echo ""
    local log_file="${JOB_LOG_PATTERN:-/home/ubuntu/job_%NUM%.log}"
    log_file="${log_file//\%NUM\%/$num}"
    echo "  Monitor: ssh ubuntu@$ip 'tail -f $log_file'"
    echo ""

    return 0
}

# Restart job on existing instance
restart_on_instance() {
    local num="$1"
    local ip="$2"
    local update_ip="${3:-false}"

    # Load instance config
    load_instances "$PROJECT_DIR/configs/instances.json" || exit 1

    local config
    config=$(get_instance_config "$num")
    if [[ -z "$config" ]]; then
        error "Unknown instance number: $num"
        return 1
    fi

    local inst_num inst_ip start_ts end_ts desc
    read -r inst_num inst_ip start_ts end_ts desc <<< "$config"

    echo ""
    echo "=============================================="
    echo "  Restarting Job on Instance $num: $desc"
    echo "  IP: $ip"
    echo "=============================================="
    echo ""

    # Check reachability
    if ! ssh_cmd "$ip" "true" 2>/dev/null; then
        error "[$num] Instance $ip is not reachable"
        return 1
    fi

    # Check if already running
    local process_pattern="${JOB_PROCESS_PATTERN:-${JOB_NAME:-job}}"
    if is_process_running "$ip" "$process_pattern"; then
        log "[$num] Job already running on $ip"
        local pid
        pid=$(ssh_cmd "$ip" "pgrep -f '$process_pattern'" 2>/dev/null)
        log "[$num] PID: $pid"
        return 0
    fi

    log "[$num] No job running, restarting..."

    # Sync workspace
    if ! sync_workspace "$ip" "$num"; then
        error "[$num] Sync failed"
        return 1
    fi

    # Build
    if ! build_on_instance "$ip" "$num"; then
        error "[$num] Build failed"
        return 1
    fi

    # Setup
    if ! setup_instance "$ip" "$num" "$start_ts" "$end_ts"; then
        error "[$num] Setup failed"
        return 1
    fi

    # Start job
    if ! start_job "$ip" "$num" "$start_ts" "$end_ts"; then
        error "[$num] Job start failed"
        return 1
    fi

    # Update config if requested
    if [[ "$update_ip" == "true" ]]; then
        update_instance_ip "$num" "$ip" "$PROJECT_DIR/configs/instances.json"
    fi

    echo ""
    log "[$num] SUCCESS - Job restarted on $ip"
    echo ""

    return 0
}

# =============================================================================
# STATUS
# =============================================================================

show_status() {
    echo ""
    echo "=========================================="
    echo "  Job Status"
    echo "=========================================="
    echo ""

    # Load instances
    load_instances "$PROJECT_DIR/configs/instances.json" || exit 1

    local process_pattern="${JOB_PROCESS_PATTERN:-${JOB_NAME:-job}}"

    for config in "${INSTANCES[@]}"; do
        local num ip start_ts end_ts desc
        read -r num ip start_ts end_ts desc <<< "$config"

        if [[ -z "$ip" ]]; then
            echo "  $num ($desc): NO IP CONFIGURED"
            continue
        fi

        # Check reachability
        if ! ssh_cmd "$ip" "true" 2>/dev/null; then
            echo "  $num ($desc): $ip - UNREACHABLE"
            continue
        fi

        # Check if job running
        if is_process_running "$ip" "$process_pattern"; then
            local pid
            pid=$(ssh_cmd "$ip" "pgrep -f '$process_pattern'" 2>/dev/null)
            local log_file="${JOB_LOG_PATTERN:-/home/ubuntu/job_%NUM%.log}"
            log_file="${log_file//\%NUM\%/$num}"
            local progress
            progress=$(ssh_cmd "$ip" "tail -1 $log_file 2>/dev/null | grep -oE 'Progress: [0-9.]+%'" 2>/dev/null || echo "unknown")
            echo "  $num ($desc): $ip - RUNNING (PID $pid) $progress"
        else
            echo "  $num ($desc): $ip - REACHABLE but NO JOB RUNNING"
        fi
    done
    echo ""
}

# =============================================================================
# USAGE
# =============================================================================

show_usage() {
    echo "Usage: $0 <command> [args...]"
    echo ""
    echo "Commands:"
    echo "  <numbers>           Launch NEW instances and start jobs (e.g., '1 3 5' or 'all')"
    echo "  restart <nums> [ip] Restart job on EXISTING instances (no new launch)"
    echo "  status              Show job status for all instances"
    echo ""
    echo "Examples:"
    echo "  $0 1                # Launch NEW instance 1 and start job"
    echo "  $0 1 3 5            # Launch NEW instances 1, 3, and 5"
    echo "  $0 all              # Launch all configured instances"
    echo "  $0 restart 1        # Restart job on existing instance 1"
    echo "  $0 restart 1 1.2.3.4  # Restart job on specified IP"
    echo "  $0 status           # Show which instances have jobs running"
}

# =============================================================================
# MAIN
# =============================================================================

if [[ $# -eq 0 ]]; then
    show_usage
    exit 1
fi

case "$1" in
    -h|--help)
        show_usage
        exit 0
        ;;
    status)
        show_status
        exit 0
        ;;
    restart)
        shift
        if [[ $# -eq 0 ]]; then
            error "Usage: $0 restart <instance_numbers...> [IP]"
            exit 1
        fi

        # Load instances for IP lookup
        load_instances "$PROJECT_DIR/configs/instances.json" || exit 1

        instances_to_restart=()
        provided_ip=""

        for arg in "$@"; do
            case "$arg" in
                all)
                    for config in "${INSTANCES[@]}"; do
                        local num
                        num=$(echo "$config" | awk '{print $1}')
                        instances_to_restart+=("$num")
                    done
                    ;;
                [0-9]|[0-9][0-9])
                    instances_to_restart+=("$arg")
                    ;;
                *)
                    if is_valid_ip "$arg"; then
                        provided_ip="$arg"
                    else
                        error "Unknown argument: $arg"
                        exit 1
                    fi
                    ;;
            esac
        done

        if [[ ${#instances_to_restart[@]} -eq 0 ]]; then
            error "No valid instance numbers specified"
            exit 1
        fi

        if [[ -n "$provided_ip" && ${#instances_to_restart[@]} -gt 1 ]]; then
            error "Cannot provide IP when restarting multiple instances"
            exit 1
        fi

        successes=()
        failures=()

        for num in "${instances_to_restart[@]}"; do
            local ip=""
            local update_ip="false"

            if [[ -n "$provided_ip" ]]; then
                ip="$provided_ip"
                update_ip="true"
            else
                local config
                config=$(get_instance_config "$num")
                ip=$(echo "$config" | awk '{print $2}')
                if [[ -z "$ip" ]]; then
                    error "[$num] No IP found for instance $num"
                    failures+=("$num")
                    continue
                fi
            fi

            if restart_on_instance "$num" "$ip" "$update_ip"; then
                successes+=("$num")
            else
                failures+=("$num")
            fi
        done

        echo ""
        echo "=========================================="
        echo "  RESTART SUMMARY"
        echo "=========================================="
        [[ ${#successes[@]} -gt 0 ]] && echo "  Succeeded: ${successes[*]}"
        [[ ${#failures[@]} -gt 0 ]] && echo "  Failed: ${failures[*]}"
        echo "=========================================="

        [[ ${#failures[@]} -gt 0 ]] && exit 1
        exit 0
        ;;
esac

# Default: launch new instances
load_instances "$PROJECT_DIR/configs/instances.json" || exit 1

instances_to_recover=()

for arg in "$@"; do
    case "$arg" in
        all)
            for config in "${INSTANCES[@]}"; do
                local num
                num=$(echo "$config" | awk '{print $1}')
                instances_to_recover+=("$num")
            done
            ;;
        [0-9]|[0-9][0-9])
            instances_to_recover+=("$arg")
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            error "Unknown argument: $arg"
            show_usage
            exit 1
            ;;
    esac
done

if [[ ${#instances_to_recover[@]} -eq 0 ]]; then
    error "No valid instances specified"
    show_usage
    exit 1
fi

# Remove duplicates
instances_to_recover=($(echo "${instances_to_recover[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

echo ""
echo "=========================================="
echo "  Job Recovery"
echo "=========================================="
echo "  Instances: ${instances_to_recover[*]}"
echo "  Profile: ${FLEET_PROFILE:-default}"
echo "=========================================="
echo ""

successes=()
failures=()

for num in "${instances_to_recover[@]}"; do
    if recover_instance "$num"; then
        successes+=("$num")
    else
        failures+=("$num")
    fi
done

echo ""
echo "=========================================="
echo "  SUMMARY"
echo "=========================================="
[[ ${#successes[@]} -gt 0 ]] && echo "  Succeeded: ${successes[*]}"
[[ ${#failures[@]} -gt 0 ]] && echo "  Failed: ${failures[*]}"
echo "=========================================="

[[ ${#failures[@]} -gt 0 ]] && exit 1
exit 0
