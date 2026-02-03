#!/bin/bash
# ec2-spot-fleet: Fleet Monitoring Script
#
# Monitor running instances and automatically recover failed jobs.
#
# Usage:
#   ./monitor-fleet.sh                     # One-time check
#   ./monitor-fleet.sh --watch             # Continuous monitoring
#   ./monitor-fleet.sh --watch --auto-recover   # Monitor + auto-recovery

# NOTE: Intentionally NOT using set -e here because this is a long-running
# monitoring script that should survive transient SSH failures, network issues, etc.

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

# Monitoring settings
WATCH_MODE=false
AUTO_RECOVER=false
WATCH_INTERVAL="${FLEET_WATCH_INTERVAL:-300}"  # 5 minutes default
RECOVERY_TIMEOUT="${FLEET_RECOVERY_TIMEOUT:-600}"  # 10 minutes default

# State files
STATE_DIR="${FLEET_STATE_DIR:-$PROJECT_DIR/.state}"
mkdir -p "$STATE_DIR"

OFFLINE_ALERT_FILE="$STATE_DIR/offline_alerted.txt"
RECOVERING_FILE="$STATE_DIR/recovering.txt"
touch "$OFFLINE_ALERT_FILE" 2>/dev/null || true
touch "$RECOVERING_FILE" 2>/dev/null || true

# =============================================================================
# RESULT CHECKING (CUSTOMIZABLE)
# =============================================================================

# Check S3 for result files
# Override this function in fleet.env for custom result checking
check_s3_results() {
    if [[ -z "${JOB_S3_BUCKET:-}" ]]; then
        return 1
    fi

    local result_pattern="${JOB_RESULT_PATTERN:-results}"

    echo "=== Checking S3 for results ==="
    local results
    results=$(aws s3 ls "s3://${JOB_S3_BUCKET}/" 2>/dev/null | grep -i "$result_pattern" || true)

    if [[ -n "$results" ]]; then
        echo "*** RESULTS FOUND IN S3! ***"
        echo "$results"
        echo ""

        # Download and display results
        for file in $(echo "$results" | awk '{print $4}'); do
            echo "--- $file ---"
            aws s3 cp "s3://${JOB_S3_BUCKET}/$file" - 2>/dev/null
            echo ""
        done

        # Send alert
        send_alert "[${FLEET_PROJECT_TAG}] Results Found!" "Results files found in S3 bucket:\n\n$results"
        return 0
    else
        echo "No results files in S3 yet."
        return 1
    fi
}

# Check instance logs for success markers
# Override JOB_SUCCESS_PATTERN in fleet.env
check_instance_for_success() {
    local ip="$1"
    local num="$2"
    local log_file="${JOB_LOG_PATTERN:-/home/ubuntu/job_%NUM%.log}"
    log_file="${log_file//\%NUM\%/$num}"

    local success_pattern="${JOB_SUCCESS_PATTERN:-FOUND|SUCCESS|COMPLETE}"

    local found
    found=$(ssh_cmd "$ip" "grep -iE '$success_pattern' $log_file 2>/dev/null | head -5" 2>/dev/null || true)

    if [[ -n "$found" ]]; then
        echo "$found"
        return 0
    fi
    return 1
}

# =============================================================================
# MONITORING FUNCTIONS
# =============================================================================

# Clean up stale recovery locks
cleanup_stale_locks() {
    if [[ -f "$RECOVERING_FILE" ]]; then
        local stale_time=$((2 * 60))  # 2 hours in minutes
        if [[ $(find "$RECOVERING_FILE" -mmin +$stale_time 2>/dev/null | wc -l) -gt 0 ]]; then
            echo "[CLEANUP] Removing stale recovery lock file (older than 2 hours)"
            rm -f "$RECOVERING_FILE"
            touch "$RECOVERING_FILE"
        fi
    fi
}

# Check all instances and report status
check_instance_health() {
    echo ""
    echo "=== Checking instance health ==="

    cleanup_stale_locks

    local found_any=false
    local full_report=""

    load_instances "$PROJECT_DIR/configs/instances.json" || return 1

    local process_pattern="${JOB_PROCESS_PATTERN:-${JOB_NAME:-job}}"

    for config in "${INSTANCES[@]}"; do
        local num ip start_ts end_ts desc
        read -r num ip start_ts end_ts desc <<< "$config"

        if [[ -z "$ip" ]]; then
            echo "Instance $num ($desc): NO IP CONFIGURED"
            continue
        fi

        # Check if instance is reachable
        if ! ssh_cmd "$ip" "true" 2>/dev/null; then
            echo "Instance $num ($desc) - $ip: UNREACHABLE"

            # Check if we already alerted
            if ! grep -q "$ip" "$OFFLINE_ALERT_FILE" 2>/dev/null; then
                echo "$ip" >> "$OFFLINE_ALERT_FILE"

                # Get checkpoint info if available
                local checkpoint="unknown"
                if [[ -n "${JOB_S3_BUCKET:-}" && -n "${JOB_CHECKPOINT_PREFIX:-}" ]]; then
                    checkpoint=$(aws s3 cp "s3://${JOB_S3_BUCKET}/${JOB_CHECKPOINT_PREFIX}${num}.txt" - 2>/dev/null || echo "unknown")
                fi

                # Send offline alert
                send_alert "[ALERT] Instance $num OFFLINE - $desc" \
"Instance $num has gone OFFLINE (likely reclaimed).

Instance: $num
IP: $ip
Description: $desc
Range: $start_ts - $end_ts
Last checkpoint: $checkpoint

To resume, run:
  ./scripts/recover-job.sh $num"

                echo "  -> Offline alert sent!"

                # Auto-recover if enabled
                if $AUTO_RECOVER && ! grep -q "^$num$" "$RECOVERING_FILE" 2>/dev/null; then
                    echo "$num" >> "$RECOVERING_FILE"
                    echo "  -> AUTO-RECOVERING instance $num..."

                    local recovery_exit=0
                    timeout "$RECOVERY_TIMEOUT" "$SCRIPT_DIR/recover-job.sh" "$num" >> "$STATE_DIR/recovery_$num.log" 2>&1 || recovery_exit=$?

                    if [[ $recovery_exit -eq 0 ]]; then
                        echo "  -> Instance $num recovered successfully!"

                        # Get new IP from config
                        load_instances "$PROJECT_DIR/configs/instances.json"
                        local new_config
                        new_config=$(get_instance_config "$num")
                        local new_ip
                        new_ip=$(echo "$new_config" | awk '{print $2}')

                        send_alert "[RECOVERED] Instance $num back online - $desc" \
"Instance $num was automatically recovered.

Instance: $num
New IP: $new_ip
Description: $desc

Recovery log: $STATE_DIR/recovery_$num.log"

                        sed -i "/^$num$/d" "$RECOVERING_FILE" 2>/dev/null || true
                    elif [[ $recovery_exit -eq 124 ]]; then
                        echo "  -> Recovery TIMED OUT after $((RECOVERY_TIMEOUT/60)) minutes"
                        local error_tail
                        error_tail=$(tail -20 "$STATE_DIR/recovery_$num.log" 2>/dev/null || echo "No log available")
                        send_alert "[FAILED] Instance $num recovery timed out - $desc" \
"Auto-recovery timed out for instance $num.

Last 20 lines of recovery log:
$error_tail

Manual recovery:
  ./scripts/recover-job.sh $num"
                    else
                        echo "  -> Recovery FAILED for instance $num"
                        local error_tail
                        error_tail=$(tail -20 "$STATE_DIR/recovery_$num.log" 2>/dev/null || echo "No log available")
                        send_alert "[FAILED] Instance $num recovery failed - $desc" \
"Auto-recovery failed for instance $num.

Last 20 lines of recovery log:
$error_tail

Manual recovery:
  ./scripts/recover-job.sh $num"
                    fi
                fi
            fi
            continue
        else
            # Instance is back online, remove from offline list
            sed -i "/$ip/d" "$OFFLINE_ALERT_FILE" 2>/dev/null || true
        fi

        # Check for success markers in logs
        local success_output
        if success_output=$(check_instance_for_success "$ip" "$num"); then
            echo ""
            echo "*** SUCCESS ON INSTANCE $num ($desc) - $ip! ***"
            found_any=true
            full_report="$full_report

Instance $num ($desc) - $ip:
$success_output"
        else
            # Get progress
            local log_file="${JOB_LOG_PATTERN:-/home/ubuntu/job_%NUM%.log}"
            log_file="${log_file//\%NUM\%/$num}"
            local progress
            progress=$(ssh_cmd "$ip" "tail -1 $log_file 2>/dev/null | grep -oE 'Progress: [0-9.]+%|ETA: [0-9.]+h'" 2>/dev/null | tr '\n' ' ' || echo "unknown")

            if [[ -z "$progress" ]]; then
                # Check if job is running
                if is_process_running "$ip" "$process_pattern"; then
                    progress="running"
                else
                    progress="NOT RUNNING"
                fi
            fi

            echo "Instance $num ($desc) - $ip: $progress"
        fi
    done

    if $found_any; then
        send_alert "[${FLEET_PROJECT_TAG}] Success Found!" "$full_report"
        return 0
    fi
    return 1
}

# Show quick status summary
show_summary() {
    echo ""
    echo "=== Quick Status Summary ==="

    load_instances "$PROJECT_DIR/configs/instances.json" 2>/dev/null || return 1

    local process_pattern="${JOB_PROCESS_PATTERN:-${JOB_NAME:-job}}"

    for config in "${INSTANCES[@]}"; do
        local num ip start_ts end_ts desc
        read -r num ip start_ts end_ts desc <<< "$config"

        local log_file="${JOB_LOG_PATTERN:-/home/ubuntu/job_%NUM%.log}"
        log_file="${log_file//\%NUM\%/$num}"

        local status
        status=$(timeout 10 ssh_cmd "$ip" \
            "tail -1 $log_file 2>/dev/null | grep -oE 'Progress: [0-9.]+%|ETA: [0-9.]+h'" 2>/dev/null \
            | tr '\n' ' ') || status=""

        if [[ -z "$status" ]]; then
            status="OFFLINE or no progress"
        fi
        echo "  Instance $num ($desc): $status"
    done
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

for arg in "$@"; do
    case $arg in
        --watch)
            WATCH_MODE=true
            ;;
        --auto-recover)
            AUTO_RECOVER=true
            ;;
        --interval)
            shift
            WATCH_INTERVAL="$1"
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --watch           Monitor continuously (every ${WATCH_INTERVAL}s)"
            echo "  --auto-recover    Automatically recover failed instances"
            echo "  --interval SECS   Set watch interval (default: ${WATCH_INTERVAL})"
            echo ""
            echo "Examples:"
            echo "  $0                         # One-time check"
            echo "  $0 --watch                 # Monitor mode"
            echo "  $0 --watch --auto-recover  # Monitor + auto-recovery"
            exit 0
            ;;
    esac
done

# =============================================================================
# MAIN
# =============================================================================

echo "Fleet Monitor"
echo "============="
echo "Project: ${FLEET_PROJECT_TAG:-spot-fleet}"
if [[ -n "${FLEET_ALERT_EMAIL:-}" ]]; then
    echo "Alert email: ${FLEET_ALERT_EMAIL}"
fi
if $AUTO_RECOVER; then
    echo "Auto-recover: ENABLED"
fi
echo "Checking at: $(date)"
echo ""

if $WATCH_MODE; then
    echo "Watch mode: checking every $((WATCH_INTERVAL/60)) minutes (Ctrl+C to stop)"
    if $AUTO_RECOVER; then
        echo "Auto-recovery: ENABLED - offline instances will be automatically resumed"
    fi
    echo ""
    echo "Monitor started at $(date), PID: $$"

    # Trap to log if script exits unexpectedly
    trap 'echo "[$(date)] Monitor exiting with code $?" >> "$STATE_DIR/monitor_crash.log"' EXIT

    while true; do
        # Reload instances to pick up IP changes from recovery
        load_instances "$PROJECT_DIR/configs/instances.json" 2>/dev/null || true

        echo ""
        echo "Fleet Monitor - $(date)"
        echo "================================="

        check_s3_results || echo "[INFO] No S3 results"
        check_instance_health || echo "[INFO] check_instance_health completed"
        show_summary || echo "[WARN] show_summary failed"

        echo ""
        echo "Next check in $((WATCH_INTERVAL/60)) minutes..."
        sleep "$WATCH_INTERVAL" || echo "[WARN] sleep interrupted"
    done
else
    check_s3_results || true
    check_instance_health || true
    show_summary
fi
