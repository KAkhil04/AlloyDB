#!/usr/bin/env bash
#==============================================================================

# mcc-eviction-unblocker.sh

#——————————————————————————

# Detect pods that are blocking the OpenShift MachineConfigController (MCC)

# from completing a node drain, evaluate them against a strict safety policy,

# and (only if every check passes) delete them so the MCO rollout can proceed.

# 

# Defaults to DRY-RUN. No pods are deleted unless –apply is passed.

# 

# Tested against: OCP 4.16, bash 4.4+, GNU coreutils.

# Required perms: cluster-admin (read pods/nodes/pdbs/owners cluster-wide,

# read MCC logs in openshift-machine-config-operator,

# delete pods in tenant namespaces).

#==============================================================================
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

#——————————————————————————

# CONFIG (override via env or CLI flags)

#——————————————————————————
: “${DRY_RUN:=true}”                      # –apply flips to false
: “${INTERACTIVE:=false}”                 # –interactive prompts y/N per pod
: “${ONCE:=false}”                        # –once: one scan then exit
: “${INTERVAL:=30}”                       # seconds between log scans
: “${LOG_WINDOW:=45s}”                    # oc logs –since=
: “${MIN_READY_REPLICAS:=2}”              # owner must have >= this ready
: “${MAX_DELETIONS_PER_CYCLE:=3}”         # blast-radius cap per cycle
: “${MAX_TOTAL_DELETIONS:=20}”            # blast-radius cap per run
: “${GRACE_PERIOD:=30}”                   # normal grace
: “${ALLOW_FORCE:=false}”                 # –allow-force enables –grace-period=0 –force
: “${STUCK_TERMINATING_SECS:=180}”        # threshold for “force candidate”
: “${REQUIRE_CORDONED_NODE:=true}”        # only act on pods on cordoned nodes
: “${PROCESSED_TTL:=600}”                 # re-evaluate same pod after N seconds
: “${EXPECTED_CLUSTER:=}”                 # refuse to run if oc context mismatches
: “${MCO_NS:=openshift-machine-config-operator}”
: “${MCC_LABEL:=k8s-app=machine-config-controller}”
: “${MCC_CONTAINER:=machine-config-controller}”
: “${DEBUG:=false}”

LOG_DIR=”${LOG_DIR:-./mcc-unblocker-logs}”
mkdir -p “$LOG_DIR”
RUN_ID=”$(date +%Y%m%d-%H%M%S)-$$”
LOG_FILE=”${LOG_DIR}/run-${RUN_ID}.log”
AUDIT_FILE=”${LOG_DIR}/audit-${RUN_ID}.jsonl”
LOCK_FILE=”/tmp/mcc-eviction-unblocker.lock”

# Namespaces we will NEVER delete pods in, regardless of other signals.

PROTECTED_NS_REGEX=’^(openshift-etcd|openshift-kube-apiserver|openshift-kube-controller-manager|openshift-kube-scheduler|openshift-machine-config-operator|openshift-cluster-version|openshift-operator-lifecycle-manager|openshift-monitoring|openshift-dns|openshift-sdn|openshift-ovn-kubernetes|openshift-ingress|openshift-ingress-operator|openshift-authentication|openshift-oauth-apiserver|openshift-apiserver|openshift-controller-manager|openshift-cluster-storage-operator|openshift-cluster-node-tuning-operator|openshift-network-operator|openshift-image-registry|kube-system|default)$’

#——————————————————————————

# LOGGING + AUDIT

#——————————————————————————
_ts() { date ‘+%F %T’; }
log()   { printf ‘[%s] [%-5s] %s\n’ “$(_ts)” “$1” “$2” | tee -a “$LOG_FILE” >&2; }
info()  { log “INFO”  “$*”; }
warn()  { log “WARN”  “$*”; }
err()   { log “ERROR” “$*”; }
debug() { [[ “$DEBUG” == “true” ]] && log “DEBUG” “$*” || true; }

# Cheap JSON-string escaper (handles the characters we actually emit).

jesc() { printf ‘%s’ “$1” | sed -e ‘s/\/\\/g’ -e ‘s/”/\”/g’ -e ‘s/\t/\t/g’; }

# audit kind=delete pod=foo ns=bar reason=“x” [extra=k=v…]

audit() {
local kind=”$1” pod=”$2” ns=”$3” reason=”$4”; shift 4
local extras=””
while [[ $# -gt 0 ]]; do extras+=”,"$1":"$(jesc “$2”)"”; shift 2; done
printf ‘{“ts”:”%s”,“run_id”:”%s”,“dry_run”:%s,“action”:”%s”,“pod”:”%s”,“ns”:”%s”,“reason”:”%s”%s}\n’   
“$(date -u +%Y-%m-%dT%H:%M:%SZ)” “$RUN_ID” “$DRY_RUN”   
“$(jesc “$kind”)” “$(jesc “$pod”)” “$(jesc “$ns”)” “$(jesc “$reason”)” “$extras”   
>> “$AUDIT_FILE”
}

#——————————————————————————

# COUNTERS + CLEANUP

#——————————————————————————
SCANNED=0; SKIPPED=0; DELETED=0

cleanup() {
local rc=$?
info “Exiting. scanned=$SCANNED skipped=$SKIPPED deleted=$DELETED rc=$rc”
info “Run log : $LOG_FILE”
info “Audit   : $AUDIT_FILE”
rm -f “$LOCK_FILE”
exit “$rc”
}
trap cleanup EXIT
trap ‘warn “Interrupted by signal”; exit 130’ INT TERM

#——————————————————————————

# PRE-FLIGHT

#——————————————————————————
preflight() {
command -v oc >/dev/null  || { err “oc not found in PATH”; exit 2; }
command -v awk >/dev/null || { err “awk not found”; exit 2; }
command -v grep >/dev/null|| { err “grep not found”; exit 2; }

if [[ -e “$LOCK_FILE” ]]; then
err “Lock file $LOCK_FILE exists. Another run, or stale. Remove if stale and retry.”
exit 3
fi
echo “$$” > “$LOCK_FILE”

local ctx server user
ctx=”$(oc config current-context 2>/dev/null || echo ‘?’)”
server=”$(oc whoami –show-server 2>/dev/null || echo ‘?’)”
user=”$(oc whoami 2>/dev/null || echo ‘?’)”
info “context=$ctx  server=$server  user=$user”
info “dry_run=$DRY_RUN  interactive=$INTERACTIVE  allow_force=$ALLOW_FORCE  min_ready=$MIN_READY_REPLICAS”
info “max_per_cycle=$MAX_DELETIONS_PER_CYCLE  max_total=$MAX_TOTAL_DELETIONS  require_cordoned=$REQUIRE_CORDONED_NODE”

if [[ -n “$EXPECTED_CLUSTER” && “$ctx” != *”$EXPECTED_CLUSTER”* && “$server” != *”$EXPECTED_CLUSTER”* ]]; then
err “Current context/server does not match EXPECTED_CLUSTER=’$EXPECTED_CLUSTER’. Refusing.”
exit 4
fi

if [[ “$DRY_RUN” != “true” ]]; then
warn “APPLY MODE - pods WILL be deleted on this cluster.”
if [[ “$INTERACTIVE” != “true” ]]; then
warn “Non-interactive apply. Sleeping 10s — Ctrl-C to abort.”
sleep 10
fi
fi
}

#——————————————————————————

# K8s HELPERS

#——————————————————————————
get_mcc_pod() {
oc -n “$MCO_NS” get pod -l “$MCC_LABEL”   
-o jsonpath=’{range .items[?(@.status.phase==“Running”)]}{.metadata.name}{”\n”}{end}’   
2>/dev/null | head -n1
}

# Walk ReplicaSet -> Deployment so we know the real “scaling” owner.

# Echos: “<kind> <name>”

resolve_scaling_owner() {
local pod=”$1” ns=”$2”
local kind name pkind pname
kind=”$(oc -n “$ns” get pod “$pod” -o jsonpath=’{.metadata.ownerReferences[0].kind}’ 2>/dev/null || true)”
name=”$(oc -n “$ns” get pod “$pod” -o jsonpath=’{.metadata.ownerReferences[0].name}’ 2>/dev/null || true)”
if [[ “$kind” == “ReplicaSet” && -n “$name” ]]; then
pkind=”$(oc -n “$ns” get rs “$name” -o jsonpath=’{.metadata.ownerReferences[0].kind}’ 2>/dev/null || true)”
pname=”$(oc -n “$ns” get rs “$name” -o jsonpath=’{.metadata.ownerReferences[0].name}’ 2>/dev/null || true)”
[[ -n “$pkind” && -n “$pname” ]] && { kind=”$pkind”; name=”$pname”; }
fi
printf ‘%s %s’ “${kind:-Unknown}” “${name:-unknown}”
}

ready_replicas() {
local kind=”$1” name=”$2” ns=”$3”
case “$kind” in
Deployment|StatefulSet|ReplicaSet)
oc -n “$ns” get “$kind” “$name” -o jsonpath=’{.status.readyReplicas}’ 2>/dev/null
;;
*) echo “” ;;
esac
}

pod_node_cordoned() {
local pod=”$1” ns=”$2” node unschedulable
node=”$(oc -n “$ns” get pod “$pod” -o jsonpath=’{.spec.nodeName}’ 2>/dev/null || true)”
[[ -z “$node” ]] && return 1
unschedulable=”$(oc get node “$node” -o jsonpath=’{.spec.unschedulable}’ 2>/dev/null || true)”
[[ “$unschedulable” == “true” ]]
}

pod_terminating_seconds() {
local pod=”$1” ns=”$2” ts del_epoch now
ts=”$(oc -n “$ns” get pod “$pod” -o jsonpath=’{.metadata.deletionTimestamp}’ 2>/dev/null || true)”
[[ -z “$ts” ]] && { echo 0; return; }
now=”$(date -u +%s)”
del_epoch=”$(date -u -d “$ts” +%s 2>/dev/null || echo “$now”)”
echo $(( now - del_epoch ))
}

# Heuristic: any PDB in the namespace currently allowing 0 disruptions?

pdb_zero_in_ns() {
local ns=”$1” lowest
lowest=”$(oc -n “$ns” get pdb -o jsonpath=’{range .items[*]}{.status.disruptionsAllowed}{”\n”}{end}’ 2>/dev/null   
| sort -n | head -n1)”
[[ -n “$lowest” && “$lowest” == “0” ]]
}

confirm_or_skip() {
[[ “$INTERACTIVE” != “true” ]] && return 0
local prompt=”$1” ans
read -r -p “$prompt [y/N]: “ ans </dev/tty || return 1
[[ “$ans” =~ ^[yY]$ ]]
}

#——————————————————————————

# DELETE

#——————————————————————————
do_delete() {
local pod=”$1” ns=”$2” reason=”$3” extra_flags=”$4”
if (( DELETED >= MAX_TOTAL_DELETIONS )); then
err “MAX_TOTAL_DELETIONS=$MAX_TOTAL_DELETIONS reached - aborting run”
exit 5
fi
if [[ “$DRY_RUN” == “true” ]]; then
info “[DRY-RUN] oc -n $ns delete pod $pod –grace-period=$GRACE_PERIOD $extra_flags  ($reason)”
audit “dryrun_delete” “$pod” “$ns” “$reason”
return
fi
info “>> DELETING $ns/$pod  ($reason)”

# shellcheck disable=SC2086

if oc -n “$ns” delete pod “$pod” –grace-period=”$GRACE_PERIOD” $extra_flags 2>&1 | tee -a “$LOG_FILE”; then
DELETED=$((DELETED+1))
audit “delete” “$pod” “$ns” “$reason” “result” “ok”
else
err “delete failed: $ns/$pod”
audit “delete” “$pod” “$ns” “$reason” “result” “fail”
fi
}

#——————————————————————————

# DECISION TREE

#——————————————————————————
evaluate_and_act() {
local pod=”$1” ns=”$2”
SCANNED=$((SCANNED+1))

# 1. Protected namespace

if [[ “$ns” =~ $PROTECTED_NS_REGEX ]]; then
info “SKIP $ns/$pod : protected namespace”
audit “skip” “$pod” “$ns” “protected_namespace”
SKIPPED=$((SKIPPED+1)); return
fi

# 2. Pod must still exist

if ! oc -n “$ns” get pod “$pod” -o name >/dev/null 2>&1; then
info “SKIP $ns/$pod : pod no longer exists”
audit “skip” “$pod” “$ns” “gone”
return
fi

# 3. Only act on pods whose node is being drained (cordoned)

if [[ “$REQUIRE_CORDONED_NODE” == “true” ]] && ! pod_node_cordoned “$pod” “$ns”; then
info “SKIP $ns/$pod : node not cordoned (probably not an active MCO drain)”
audit “skip” “$pod” “$ns” “node_not_cordoned”
SKIPPED=$((SKIPPED+1)); return
fi

# 4. Stuck Terminating fast-path (drain has politely tried; pod refuses to die)

local term_secs
term_secs=”$(pod_terminating_seconds “$pod” “$ns”)”
if (( term_secs > STUCK_TERMINATING_SECS )); then
if [[ “$ALLOW_FORCE” == “true” ]]; then
warn “$ns/$pod stuck Terminating ${term_secs}s - force deleting”
do_delete “$pod” “$ns” “stuck_terminating_${term_secs}s” “–force –grace-period=0”
else
info “SKIP $ns/$pod : stuck Terminating ${term_secs}s but ALLOW_FORCE=false”
audit “skip” “$pod” “$ns” “force_disabled” “terminating_secs” “$term_secs”
SKIPPED=$((SKIPPED+1))
fi
return
fi

# 5. Resolve true scaling owner

local kind name
read -r kind name < <(resolve_scaling_owner “$pod” “$ns”)
info “$ns/$pod owner=$kind/$name”

# 6. Owner-kind policy

case “$kind” in
Deployment|StatefulSet|ReplicaSet) ;;  # fall through to replica check
DaemonSet)
info “SKIP $ns/$pod : DaemonSet (drain handles via –ignore-daemonsets)”
audit “skip” “$pod” “$ns” “daemonset”
SKIPPED=$((SKIPPED+1)); return ;;
Job|CronJob)
info “$ns/$pod is Job-owned - safe to delete”
do_delete “$pod” “$ns” “job_owned” “”
return ;;
Unknown|””)
warn “SKIP $ns/$pod : bare pod (no owner) - refusing to delete”
audit “skip” “$pod” “$ns” “bare_pod”
SKIPPED=$((SKIPPED+1)); return ;;
*)
warn “SKIP $ns/$pod : custom owner kind ‘$kind’ - operator-managed, leaving alone”
audit “skip” “$pod” “$ns” “custom_owner” “kind” “$kind”
SKIPPED=$((SKIPPED+1)); return ;;
esac

# 7. Replica safety

local ready
ready=”$(ready_replicas “$kind” “$name” “$ns”)”
ready=”${ready:-0}”
if (( ready < MIN_READY_REPLICAS )); then
warn “SKIP $ns/$pod : $kind/$name has only $ready ready (< $MIN_READY_REPLICAS)”
audit “skip” “$pod” “$ns” “insufficient_ready” “ready” “$ready”
SKIPPED=$((SKIPPED+1)); return
fi

# 8. PDB awareness (informational - delete bypasses eviction policy)

if pdb_zero_in_ns “$ns”; then
warn “$ns has a PDB with disruptionsAllowed=0. delete (not evict) WILL bypass it.”
fi

# 9. Optional human gate

if ! confirm_or_skip “Delete $ns/$pod (owner=$kind/$name, ready=$ready)?”; then
info “SKIP $ns/$pod : not confirmed”
audit “skip” “$pod” “$ns” “not_confirmed”
SKIPPED=$((SKIPPED+1)); return
fi

do_delete “$pod” “$ns” “owner=${kind}/${name},ready=${ready}” “”
}

#——————————————————————————

# MAIN LOOP

#——————————————————————————
main() {
preflight
declare -A processed_at
info “Starting MCC eviction-unblocker (run_id=$RUN_ID)”

while true; do
local mcc_pod cycle_deletions=0 logs
mcc_pod=”$(get_mcc_pod)”
if [[ -z “$mcc_pod” ]]; then
warn “No Running MCC pod in $MCO_NS — retrying in ${INTERVAL}s”
sleep “$INTERVAL”; continue
fi
info “Scanning logs of $MCO_NS/$mcc_pod (–since=$LOG_WINDOW)”

```
logs="$(oc -n "$MCO_NS" logs "$mcc_pod" -c "$MCC_CONTAINER" --since="$LOG_WINDOW" 2>/dev/null \
        | grep -E 'error when evicting pods?' || true)"

if [[ -z "$logs" ]]; then
  info "No eviction errors in last $LOG_WINDOW"
else
  while IFS= read -r line; do
    local pod ns key now
    pod="$(grep -oP '(?<=pods/")[^"]+' <<<"$line" || true)"
    ns="$( grep -oP '(?<=-n ")[^"]+'  <<<"$line" || true)"
    if [[ -z "$pod" || -z "$ns" ]]; then debug "unparseable: $line"; continue; fi

    key="${ns}/${pod}"
    now="$(date +%s)"
    if [[ -n "${processed_at[$key]:-}" ]] && (( now - processed_at[$key] < PROCESSED_TTL )); then
      continue
    fi
    processed_at[$key]=$now

    if (( cycle_deletions >= MAX_DELETIONS_PER_CYCLE )); then
      info "Cycle cap reached ($MAX_DELETIONS_PER_CYCLE) — remainder next cycle"
      break
    fi

    local before=$DELETED
    evaluate_and_act "$pod" "$ns"
    if (( DELETED > before )); then
      cycle_deletions=$((cycle_deletions+1))
      sleep 2   # gentle on kube-apiserver
    fi
  done <<<"$logs"
fi

info "Cycle done. scanned=$SCANNED skipped=$SKIPPED deleted=$DELETED"
if [[ "$ONCE" == "true" ]]; then
  info "ONCE mode — exiting"
  break
fi
sleep "$INTERVAL"
```

done
}

#——————————————————————————

# CLI PARSING

#——————————————————————————
print_usage() {
cat <<EOF
Usage: $0 [flags]

Flags:
–apply                   Actually delete (default is dry-run)
–interactive             Prompt y/N before each delete
–allow-force             Allow –force –grace-period=0 for stuck Terminating pods
–once                    One scan then exit
–min-ready N             Minimum ready siblings required (default $MIN_READY_REPLICAS)
–interval SECS           Loop interval (default $INTERVAL)
–log-window DURATION     oc logs –since= window (default $LOG_WINDOW)
–max-per-cycle N         Cap deletions per cycle (default $MAX_DELETIONS_PER_CYCLE)
–max-total N             Cap deletions per run (default $MAX_TOTAL_DELETIONS)
–no-cordon-check         Don’t require pod’s node to be cordoned (DANGEROUS)
–expected-cluster STR    Refuse to run unless oc context/server contains STR
–debug                   Verbose
-h | –help               This help

Logs : $LOG_DIR/run-<id>.log
Audit: $LOG_DIR/audit-<id>.jsonl  (one JSON object per decision)
EOF
}

while [[ $# -gt 0 ]]; do
case “$1” in
–apply)             DRY_RUN=false ;;
–interactive)       INTERACTIVE=true ;;
–allow-force)       ALLOW_FORCE=true ;;
–once)              ONCE=true ;;
–min-ready)         MIN_READY_REPLICAS=”$2”; shift ;;
–interval)          INTERVAL=”$2”; shift ;;
–log-window)        LOG_WINDOW=”$2”; shift ;;
–max-per-cycle)     MAX_DELETIONS_PER_CYCLE=”$2”; shift ;;
–max-total)         MAX_TOTAL_DELETIONS=”$2”; shift ;;
–no-cordon-check)   REQUIRE_CORDONED_NODE=false ;;
–expected-cluster)  EXPECTED_CLUSTER=”$2”; shift ;;
–debug)             DEBUG=true ;;
-h|–help)           print_usage; exit 0 ;;
*)                   err “unknown arg: $1”; print_usage; exit 1 ;;
esac
shift
done

main