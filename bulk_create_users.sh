#!/bin/bash
#
# bulk_create_users.sh
#
# Bulk-provisions Samba4 AD DC user accounts from a CSV file.
# Idempotent: skips users that already exist, creates OUs/groups on demand.
#
# Usage:
#   sudo ./bulk_create_users.sh users.csv
#
# CSV format (no header row):
#   username,given_name,surname,ou,group,email
#
# Example row:
#   jdoe,John,Doe,IT,IT-Admins,jdoe@homelab.local
#
# Output:
#   - Console: progress/status log
#   - creds_output.csv: username,password pairs for accounts actually created
#     (delete or secure this file after distributing credentials)

set -euo pipefail

DOMAIN_DN="DC=homelab,DC=local"
CSV_FILE="${1:-}"
CREDS_FILE="creds_output.csv"
LOG_FILE="bulk_create_users.log"

# --- Sanity checks ---------------------------------------------------------

if [[ -z "$CSV_FILE" ]]; then
    echo "Usage: sudo $0 <path_to_csv>"
    exit 1
fi

if [[ ! -f "$CSV_FILE" ]]; then
    echo "Error: CSV file '$CSV_FILE' not found."
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must be run with sudo (samba-tool requires root)."
    exit 1
fi

if ! command -v samba-tool &> /dev/null; then
    echo "Error: samba-tool not found. Is Samba AD DC installed?"
    exit 1
fi

# --- Helpers ----------------------------------------------------------------

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
}

generate_password() {
    # 16-char password guaranteed to satisfy Samba's default complexity policy
    # (upper, lower, digit, symbol)
    local pass
    pass="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12)$(printf '%s' '!@#$%' | fold -w1 | shuf -n1)A9"
    echo "$pass"
}

ou_exists() {
    samba-tool ou list | grep -qx "OU=$1"
}

group_exists() {
    samba-tool group list | grep -qx "$1"
}

user_exists() {
    samba-tool user list | grep -qx "$1"
}

# --- Init ---------------------------------------------------------------

echo "username,password" > "$CREDS_FILE"
log "=== Bulk user creation started: $CSV_FILE ==="

created_count=0
skipped_count=0
error_count=0

# --- Main loop ---------------------------------------------------------

while IFS=',' read -r username given_name surname ou group email; do

    # Skip blank lines
    [[ -z "$username" ]] && continue

    # Trim whitespace from each field
    username=$(echo "$username" | xargs)
    given_name=$(echo "$given_name" | xargs)
    surname=$(echo "$surname" | xargs)
    ou=$(echo "$ou" | xargs)
    group=$(echo "$group" | xargs)
    email=$(echo "$email" | xargs)

    # --- Idempotency check ---
    if user_exists "$username"; then
        log "SKIP: user '$username' already exists."
        skipped_count=$((skipped_count + 1))
        continue
    fi

    # --- Ensure OU exists ---
    if ! ou_exists "$ou"; then
        log "OU '$ou' not found, creating it."
        if ! samba-tool ou create "OU=$ou,$DOMAIN_DN" >> "$LOG_FILE" 2>&1; then
            log "ERROR: failed to create OU '$ou'. Skipping $username."
            error_count=$((error_count + 1))
            continue
        fi
    fi

    # --- Create the user ---
    password=$(generate_password)
    if AD_PASSWORD="$password" samba-tool user create "$username" "$password" \
        --given-name="$given_name" \
        --surname="$surname" \
        --userou="OU=$ou" \
        --mail-address="$email" >> "$LOG_FILE" 2>&1; then
        log "CREATED: $username ($given_name $surname) in OU=$ou"
        echo "$username,$password" >> "$CREDS_FILE"
        created_count=$((created_count + 1))
    else
        log "ERROR: failed to create user '$username'."
        error_count=$((error_count + 1))
        continue
    fi

    # --- Ensure group exists, then add member ---
    if [[ -n "$group" ]]; then
        if ! group_exists "$group"; then
            log "Group '$group' not found, creating it."
            samba-tool group add "$group" >> "$LOG_FILE" 2>&1
        fi
        if samba-tool group addmembers "$group" "$username" >> "$LOG_FILE" 2>&1; then
            log "  -> added to group '$group'"
        else
            log "  -> WARNING: failed to add $username to group '$group'"
        fi
    fi

done < "$CSV_FILE"

# --- Summary ---------------------------------------------------------

log "=== Bulk user creation complete ==="
log "Created: $created_count | Skipped (already existed): $skipped_count | Errors: $error_count"
log "Generated credentials saved to: $CREDS_FILE (secure or delete after distribution)"

echo ""
echo "Done. See $LOG_FILE for full log and $CREDS_FILE for generated passwords."
