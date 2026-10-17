# shellcheck shell=bash
# Levelled output, the dry-run-aware command wrapper, and the run summary.

: "${DRY_RUN:=0}"
: "${RUN_STAMP:=$(date +%Y%m%d-%H%M%S)}"
LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/config-bootstrap"
: "${LOG_FILE:=}"

SUMMARY_ROWS=()
SUMMARY_NOTES=()

log_init() {
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/run-$RUN_STAMP.log"
    : > "$LOG_FILE"
    log_info "Transcript: $LOG_FILE"
}

# _log LEVEL ANSI_COLOR MESSAGE...
_log() {
    local level=$1 color=$2
    shift 2
    local line="[$level] $*"
    if [[ -t 1 && -n $color ]]; then
        printf '\033[%sm%s\033[0m\n' "$color" "$line"
    else
        printf '%s\n' "$line"
    fi
    if [[ -n $LOG_FILE && -w $LOG_FILE ]]; then
        printf '%s %s\n' "$(date +%H:%M:%S)" "$line" >> "$LOG_FILE"
    fi
}

log_info()  { _log INFO  '0;34' "$@"; }
log_ok()    { _log OK    '0;32' "$@"; }
log_warn()  { _log WARN  '0;33' "$@"; }
log_error() { _log ERROR '0;31' "$@"; }
log_step()  { _log STEP  '1;37' "$@"; }

# run CMD ARG... — the single chokepoint for anything that mutates the machine.
# Cannot carry pipes or redirections; branch on DRY_RUN explicitly for those.
run() {
    if (( DRY_RUN )); then
        _log DRY '0;36' "$*"
        return 0
    fi
    _log CMD '' "$*"
    "$@"
}

run_sudo() { run sudo "$@"; }

# summary_add STATUS MODULE [DETAIL]   STATUS: ok | changed | failed
summary_add() {
    SUMMARY_ROWS+=("$1|$2|${3:-}")
}

summary_note() {
    SUMMARY_NOTES+=("$1")
}

summary_print() {
    local row status module detail failed=0
    printf '\n'
    log_step "Run summary"
    for row in "${SUMMARY_ROWS[@]:-}"; do
        [[ -z $row ]] && continue
        IFS='|' read -r status module detail <<< "$row"
        case $status in
            ok)      log_ok      "$module${detail:+ — $detail}" ;;
            changed) log_info    "$module changed${detail:+ — $detail}" ;;
            failed)  log_error   "$module failed${detail:+ — $detail}"; failed=1 ;;
        esac
    done
    if (( ${#SUMMARY_NOTES[@]} )); then
        printf '\n'
        log_step "Manual follow-ups"
        local note
        for note in "${SUMMARY_NOTES[@]}"; do
            log_warn "$note"
        done
    fi
    [[ -n $LOG_FILE ]] && log_info "Transcript: $LOG_FILE"
    return "$failed"
}
