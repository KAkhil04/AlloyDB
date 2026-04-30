#!/usr/bin/env bash
#==============================================================================

# mcc-eviction-unblocker.sh

# Detect and resolve pods blocking OpenShift MachineConfigController (MCC).

#==============================================================================
set -Eeuo pipefail

# Enable `inherit_errexit` for bash 4.4+ where supported
shopt -s inherit_errexit 2>/dev/null || true

# Constants and Defaults
DRY_RUN=${DRY_RUN:-true}                      # Defaults to dry-run mode
INTERACTIVE=${INTERACTIVE:-false}             # Defaults to non-interactive
ONCE=${ONCE:-false}                           # Defaults to looping mode
INTERVAL=${INTERVAL:-30}                      # Seconds between scans
LOG_WINDOW=${LOG_WINDOW:-"45s"}               # Log window for checks
LOCK_FILE="/tmp/mcc-eviction-unblocker.lock"  # Lock file path

# Directory for logs
LOG_DIR="${LOG_DIR:-./mcc-unblocker-logs}"
mkdir -p "$LOG_DIR" || {
  echo "[ERROR] Failed to create log directory: $LOG_DIR"
  exit 1
}
RUN_ID=$(date "+%Y%m%d-%H%M%S")
LOG_FILE="${LOG_DIR}/run-${RUN_ID}.log"
AUDIT_FILE="${LOG_DIR}/audit-${RUN_ID}.jsonl"

# Trap cleanup to enforce proper locking
cleanup() {
    local rc=$?
    rm -f "$LOCK_FILE"
    exit "$rc"
}
trap cleanup EXIT

#==============================================================================

# Logging Functions
log() {
    local level msg
    level="$1"
    msg="$2"
    printf "[%s] [%s]\t%s\n" "$(date '+%F %T')" "$level" "$msg" | tee -a "$LOG_FILE" >&2
}
info()  { log "INFO" "$1"; }
warn()  { log "WARN" "$1"; }
error() { log "ERROR" "$1"; exit 1; }
debug() { [[ "${DEBUG:-false}" == "true" ]] && log "DEBUG" "$1" || true; }

#==============================================================================

# Preflight Check
preflight() {
    # Check for required commands
    for cmd in oc awk grep; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error "$cmd not found in PATH"
        fi
    done

    # Ensure no conflicting lock file exists
    if [[ -e "$LOCK_FILE" ]]; then
        error "Another instance is running or a stale lock exists: $LOCK_FILE. Remove if stale."
    fi

    echo $$ > "$LOCK_FILE"
    info "Lock acquired: $LOCK_FILE"
}

#==============================================================================

# Get MCC pod for logs
get_mcc_pod() {
    oc get pods -n openshift-machine-config-operator \
        --selector="k8s-app=machine-config-controller" \
        --field-selector=status.phase=Running \
        -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || true
}

evaluate_and_act() {
    local pod=$1 ns=$2
    info "Evaluating pod $ns/$pod"
    # Logic for pod inspection/action here
}

#==============================================================================

# Main Loop
main() {
    preflight
    info "Starting MCC eviction-unblocker (run_id=$RUN_ID)"
    while true; do
        # Find MCC pod
        local mcc_pod
        mcc_pod="$(get_mcc_pod)"
        if [[ -z "$mcc_pod" ]]; then
            warn "No MCC pod is running."
            sleep "$INTERVAL"
            continue
        fi
        info "Scanning logs for pod: $mcc_pod"
        
        # Simulate reading logs and process further
        logs=$(oc logs -n openshift-machine-config-operator "$mcc_pod")
        if [[ -n "$logs" ]]; then
            info "Logs fetched successfully. Proceed to parse and evaluate"
            # Add log parsing logic and further evaluation
        else
            info "No recent issues found. Retrying after $INTERVAL seconds..."
        fi

        [[ "$ONCE" == "true" ]] && break
        sleep "$INTERVAL"
    done
}

main "$@"