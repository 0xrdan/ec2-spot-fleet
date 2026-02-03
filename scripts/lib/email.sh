#!/bin/bash
# ec2-spot-fleet: Email alerting functions
# Source this file in other scripts: source "$(dirname "$0")/lib/email.sh"

# =============================================================================
# EMAIL ALERTING
# =============================================================================

# Send email alert using SMTP
# Usage: send_email_alert <subject> <body>
#
# Required environment variables (set in fleet.env or credentials file):
#   FLEET_ALERT_EMAIL - recipient email address
#   FLEET_SMTP_HOST - SMTP server hostname
#   FLEET_SMTP_PORT - SMTP server port (usually 587 for TLS)
#   FLEET_SMTP_USER - SMTP username
#   FLEET_SMTP_PASS - SMTP password
#   FLEET_SMTP_FROM - sender email address
#
# Optional:
#   FLEET_SMTP_CREDENTIALS - path to credentials file with SMTP_USER and SMTP_PASS
send_email_alert() {
    local subject="$1"
    local body="$2"

    # Check if email alerting is configured
    if [[ -z "${FLEET_ALERT_EMAIL:-}" ]]; then
        # Email not configured, silently skip
        return 0
    fi

    # Load credentials from file if specified
    if [[ -n "${FLEET_SMTP_CREDENTIALS:-}" && -f "${FLEET_SMTP_CREDENTIALS}" ]]; then
        # shellcheck source=/dev/null
        source "${FLEET_SMTP_CREDENTIALS}"
    fi

    # Check required SMTP settings
    local smtp_host="${FLEET_SMTP_HOST:-}"
    local smtp_port="${FLEET_SMTP_PORT:-587}"
    local smtp_user="${FLEET_SMTP_USER:-}"
    local smtp_pass="${FLEET_SMTP_PASS:-}"
    local smtp_from="${FLEET_SMTP_FROM:-$smtp_user}"
    local alert_email="${FLEET_ALERT_EMAIL}"

    if [[ -z "$smtp_host" || -z "$smtp_user" || -z "$smtp_pass" ]]; then
        log "Email alert skipped: SMTP not fully configured"
        log "  Subject: $subject"
        return 0
    fi

    # Send email using Python (most reliable cross-platform method)
    python3 << PYEOF
import smtplib
from email.mime.text import MIMEText
import sys

body = """$body"""

msg = MIMEText(body)
msg['Subject'] = "$subject"
msg['From'] = "$smtp_from"
msg['To'] = "$alert_email"

try:
    with smtplib.SMTP("$smtp_host", $smtp_port) as server:
        server.starttls()
        server.login("$smtp_user", "$smtp_pass")
        server.send_message(msg)
    print(f"Email alert sent to $alert_email")
except Exception as e:
    print(f"Failed to send email: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# Send email using sendmail (alternative method)
# Usage: send_email_sendmail <subject> <body>
send_email_sendmail() {
    local subject="$1"
    local body="$2"
    local recipient="${FLEET_ALERT_EMAIL:-}"

    if [[ -z "$recipient" ]]; then
        return 0
    fi

    if ! command -v sendmail &>/dev/null; then
        log "sendmail not available, skipping email"
        return 0
    fi

    echo -e "Subject: $subject\n\n$body" | sendmail "$recipient"
    log "Email sent to $recipient"
}

# Send Slack notification (if webhook configured)
# Usage: send_slack_alert <message>
send_slack_alert() {
    local message="$1"
    local webhook_url="${FLEET_SLACK_WEBHOOK:-}"

    if [[ -z "$webhook_url" ]]; then
        return 0
    fi

    curl -s -X POST -H 'Content-type: application/json' \
        --data "{\"text\":\"$message\"}" \
        "$webhook_url" >/dev/null

    log "Slack notification sent"
}

# Generic alert function - sends to all configured channels
# Usage: send_alert <subject> <body>
send_alert() {
    local subject="$1"
    local body="$2"

    # Try email
    if [[ -n "${FLEET_ALERT_EMAIL:-}" ]]; then
        send_email_alert "$subject" "$body" || true
    fi

    # Try Slack
    if [[ -n "${FLEET_SLACK_WEBHOOK:-}" ]]; then
        send_slack_alert "$subject: $body" || true
    fi
}
