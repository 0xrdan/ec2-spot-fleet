#!/bin/bash
# ec2-spot-fleet: Common helper functions
# Source this file in other scripts: source "$(dirname "$0")/lib/common.sh"

# =============================================================================
# LOGGING
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_short() {
    echo "[$(date '+%H:%M:%S')] $1"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

# =============================================================================
# CONFIGURATION LOADING
# =============================================================================

# Load environment configuration
# Usage: load_config [config_file]
load_config() {
    local config_file="${1:-}"

    # Search order: argument, FLEET_CONFIG env, ./fleet.env, ../fleet.env
    if [[ -z "$config_file" ]]; then
        config_file="${FLEET_CONFIG:-}"
    fi

    if [[ -z "$config_file" ]]; then
        local script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
        if [[ -f "$script_dir/fleet.env" ]]; then
            config_file="$script_dir/fleet.env"
        elif [[ -f "$script_dir/../fleet.env" ]]; then
            config_file="$script_dir/../fleet.env"
        fi
    fi

    if [[ -n "$config_file" && -f "$config_file" ]]; then
        # shellcheck source=/dev/null
        source "$config_file"
        log "Loaded config: $config_file"
    else
        error "No configuration file found"
        error "Create fleet.env from fleet.env.example or set FLEET_CONFIG"
        return 1
    fi
}

# Load instance definitions from JSON
# Usage: load_instances [instances_file]
# Sets: INSTANCES array with format "num ip start end desc"
load_instances() {
    local instances_file="${1:-${FLEET_INSTANCES_FILE:-configs/instances.json}}"

    if [[ ! -f "$instances_file" ]]; then
        error "Instances file not found: $instances_file"
        return 1
    fi

    # Parse JSON into bash array
    INSTANCES=()
    while IFS= read -r line; do
        INSTANCES+=("$line")
    done < <(jq -r '.instances[] | "\(.num) \(.ip // "") \(.start) \(.end) \(.desc)"' "$instances_file")

    if [[ ${#INSTANCES[@]} -eq 0 ]]; then
        error "No instances found in $instances_file"
        return 1
    fi

    log "Loaded ${#INSTANCES[@]} instance configs from $instances_file"
}

# Get instance config by number
# Usage: get_instance_config 1
# Returns: "num ip start end desc"
get_instance_config() {
    local num="$1"
    for config in "${INSTANCES[@]}"; do
        local inst_num
        inst_num=$(echo "$config" | awk '{print $1}')
        if [[ "$inst_num" == "$num" ]]; then
            echo "$config"
            return 0
        fi
    done
    return 1
}

# Load instance profiles from JSON
# Usage: load_profiles [profiles_file]
load_profiles() {
    local profiles_file="${1:-${FLEET_PROFILES_FILE:-configs/profiles.json}}"

    if [[ ! -f "$profiles_file" ]]; then
        error "Profiles file not found: $profiles_file"
        return 1
    fi

    # Parse profiles into associative arrays
    declare -gA PROFILE_TYPES
    declare -gA PROFILE_PRICES

    while IFS='=' read -r name type; do
        PROFILE_TYPES[$name]="$type"
    done < <(jq -r '.profiles | to_entries[] | "\(.key)=\(.value.type)"' "$profiles_file")

    while IFS='=' read -r name price; do
        PROFILE_PRICES[$name]="$price"
    done < <(jq -r '.profiles | to_entries[] | "\(.key)=\(.value.spot_price)"' "$profiles_file")

    log "Loaded ${#PROFILE_TYPES[@]} instance profiles"
}

# =============================================================================
# SSH HELPERS
# =============================================================================

# Get SSH options string
get_ssh_opts() {
    local key="${FLEET_KEY_FILE:-$HOME/.ssh/${FLEET_KEY_NAME}.pem}"
    local timeout="${FLEET_SSH_TIMEOUT:-10}"
    echo "-i $key -o StrictHostKeyChecking=no -o ConnectTimeout=$timeout -o BatchMode=yes"
}

# Execute SSH command
# Usage: ssh_cmd <ip> <command...>
ssh_cmd() {
    local ip="$1"
    shift
    local opts
    opts=$(get_ssh_opts)
    # shellcheck disable=SC2086
    ssh $opts ubuntu@"$ip" "$@"
}

# Execute SSH command with timeout
# Usage: ssh_cmd_timeout <timeout_secs> <ip> <command...>
ssh_cmd_timeout() {
    local timeout_secs="$1"
    local ip="$2"
    shift 2
    local opts
    opts=$(get_ssh_opts)
    # shellcheck disable=SC2086
    timeout "$timeout_secs" ssh $opts ubuntu@"$ip" "$@"
}

# Execute SCP command
# Usage: scp_cmd <source> <dest>
scp_cmd() {
    local opts
    opts=$(get_ssh_opts)
    # shellcheck disable=SC2086
    scp $opts "$@"
}

# Wait for SSH to become available
# Usage: wait_for_ssh <ip> [max_attempts]
wait_for_ssh() {
    local ip="$1"
    local max_attempts="${2:-30}"
    local attempt=0

    log "Waiting for SSH on $ip..."
    while ! ssh_cmd "$ip" "true" 2>/dev/null; do
        attempt=$((attempt + 1))
        if [[ $attempt -ge $max_attempts ]]; then
            error "SSH not available on $ip after $((max_attempts * 5)) seconds"
            return 1
        fi
        sleep 5
    done
    log "SSH available on $ip"
    return 0
}

# Check if a process is running on remote host
# Usage: is_process_running <ip> <process_pattern>
is_process_running() {
    local ip="$1"
    local pattern="$2"
    ssh_cmd "$ip" "pgrep -f '$pattern'" &>/dev/null
}

# =============================================================================
# AWS CLI HELPERS
# =============================================================================

# Check AWS CLI is installed and configured
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        error "AWS CLI not installed. Install with: sudo apt install awscli"
        return 1
    fi

    if ! aws sts get-caller-identity &> /dev/null; then
        error "AWS CLI not configured. Run: aws configure"
        return 1
    fi

    return 0
}

# Count running instances with project tag
# Usage: count_running_instances [project_tag]
count_running_instances() {
    local project="${1:-${FLEET_PROJECT_TAG:-spot-fleet}}"
    aws ec2 describe-instances \
        --filters "Name=tag:Project,Values=$project" "Name=instance-state-name,Values=running,pending" \
        --query 'Reservations[*].Instances[*].InstanceId' \
        --output text 2>/dev/null | wc -w
}

# Get running instance IPs
# Usage: get_running_instance_ips [project_tag]
get_running_instance_ips() {
    local project="${1:-${FLEET_PROJECT_TAG:-spot-fleet}}"
    aws ec2 describe-instances \
        --filters "Name=tag:Project,Values=$project" "Name=instance-state-name,Values=running" \
        --query 'Reservations[*].Instances[*].[PublicIpAddress,InstanceId,LaunchTime]' \
        --output text 2>/dev/null | sort -k3
}

# =============================================================================
# INSTANCE CONFIG FILE MANAGEMENT
# =============================================================================

# Update IP in instances.json
# Usage: update_instance_ip <num> <new_ip> [instances_file]
update_instance_ip() {
    local num="$1"
    local new_ip="$2"
    local instances_file="${3:-${FLEET_INSTANCES_FILE:-configs/instances.json}}"

    if [[ ! -f "$instances_file" ]]; then
        error "Instances file not found: $instances_file"
        return 1
    fi

    # Update the IP for the given instance number
    local tmp_file="${instances_file}.tmp"
    jq --arg num "$num" --arg ip "$new_ip" \
        '.instances = [.instances[] | if .num == ($num | tonumber) then .ip = $ip else . end]' \
        "$instances_file" > "$tmp_file"

    if [[ $? -eq 0 ]]; then
        mv "$tmp_file" "$instances_file"
        log "Updated instance $num IP to $new_ip in $instances_file"
        return 0
    else
        rm -f "$tmp_file"
        error "Failed to update instance IP"
        return 1
    fi
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Check if a value is a valid IP address
is_valid_ip() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# Check if a value is a positive integer
is_positive_int() {
    local val="$1"
    [[ "$val" =~ ^[0-9]+$ ]] && [[ "$val" -gt 0 ]]
}

# Require a variable to be set
require_var() {
    local var_name="$1"
    local var_value="${!var_name}"

    if [[ -z "$var_value" ]]; then
        error "Required variable $var_name is not set"
        return 1
    fi
}

# Require multiple variables to be set
require_vars() {
    local missing=()
    for var in "$@"; do
        if [[ -z "${!var}" ]]; then
            missing+=("$var")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Required variables not set: ${missing[*]}"
        return 1
    fi
}
