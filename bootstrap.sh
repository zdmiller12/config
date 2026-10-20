#!/usr/bin/env bash
# Machine bootstrap. Curl-able and idempotent.
#
#   curl -fsSL https://raw.githubusercontent.com/zdmiller12/config/main/bootstrap.sh | bash
#
set -euo pipefail

REPO_URL="${CONFIG_REPO_URL:-https://github.com/zdmiller12/config.git}"
REPO_DIR="${CONFIG_REPO_DIR:-$HOME/git/config}"
REPO_BRANCH="${CONFIG_REPO_BRANCH:-main}"

SELF_DIR=""
if [[ -n ${BASH_SOURCE[0]:-} && -e ${BASH_SOURCE[0]} ]]; then
    SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fi

# ---------------------------------------------------------------------------
# Stage 1: no working tree yet (curl-piped). Clone, then re-exec from the
# clone so dotfile symlinks point at files the user can edit and push.
# ---------------------------------------------------------------------------
if [[ -z $SELF_DIR || ! -f $SELF_DIR/lib/module.sh ]]; then
    if [[ $EUID -eq 0 ]]; then
        printf 'Refusing to run as root. Run as your normal user.\n' >&2
        exit 1
    fi
    if ! command -v apt-get > /dev/null 2>&1; then
        printf 'This bootstrap targets Debian-family systems (no apt-get found).\n' >&2
        exit 1
    fi
    printf '[BOOT] staging from %s\n' "$REPO_URL"
    if ! command -v git > /dev/null 2>&1; then
        printf '[BOOT] installing git\n'
        sudo apt-get update -qq
        sudo apt-get install -y git
    fi
    if [[ -d $REPO_DIR/.git ]]; then
        printf '[BOOT] updating %s\n' "$REPO_DIR"
        git -C "$REPO_DIR" fetch --quiet origin "$REPO_BRANCH"
        git -C "$REPO_DIR" merge --ff-only "origin/$REPO_BRANCH" \
            || printf '[BOOT] working tree has local changes; leaving it alone\n'
    else
        printf '[BOOT] cloning into %s\n' "$REPO_DIR"
        mkdir -p "$(dirname "$REPO_DIR")"
        git clone --quiet --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR"
    fi
    exec bash "$REPO_DIR/bootstrap.sh" "$@"
fi

# ---------------------------------------------------------------------------
# Stage 2: the engine, running from a real working tree.
# ---------------------------------------------------------------------------
REPO_ROOT=$SELF_DIR
MODULES_DIR="$REPO_ROOT/modules"
# shellcheck disable=SC2034 # consumed by modules added in later tasks
DOTFILES_DIR="$REPO_ROOT/dotfiles"

DRY_RUN=0
ASSUME_YES=0
RECONFIGURE=0
ONLY_MODULES=()
SKIP_MODULES=()

usage() {
    cat <<'EOF'
Usage: bootstrap.sh [options]

  --dry-run         Print every command without executing it
  --yes, -y         Accept defaults; never prompt
  --reconfigure     Re-prompt the module checklist, ignoring the saved selection
  --only MODULE     Run only this module (repeatable)
  --skip MODULE     Skip this module (repeatable)
  -h, --help        Show this message
EOF
}

parse_args() {
    while (( $# )); do
        case $1 in
            --dry-run) DRY_RUN=1 ;;
            --yes | -y) ASSUME_YES=1 ;;
            --reconfigure) RECONFIGURE=1 ;;
            --only)
                shift
                [[ $# -gt 0 ]] || { printf -- '--only needs a module name\n' >&2; return 2; }
                ONLY_MODULES+=("$1")
                ;;
            --skip)
                shift
                [[ $# -gt 0 ]] || { printf -- '--skip needs a module name\n' >&2; return 2; }
                SKIP_MODULES+=("$1")
                ;;
            -h | --help)
                usage
                return 10
                ;;
            *)
                printf 'Unknown option: %s\n' "$1" >&2
                return 2
                ;;
        esac
        shift
    done
    return 0
}

preflight() {
    # BOOTSTRAP_UID is an override seam for the tests: EUID is readonly in
    # bash, so a test cannot assign it to simulate root.
    if [[ ${BOOTSTRAP_UID:-$(id -u)} -eq 0 ]]; then
        log_error "Refusing to run as root. Run as your normal user; sudo is called per command."
        return 1
    fi
    if ! command -v apt-get > /dev/null 2>&1; then
        log_error "This bootstrap targets Debian-family systems (no apt-get found)."
        return 1
    fi
    log_ok "Preflight passed"
    return 0
}

sudo_validate() {
    (( DRY_RUN )) && return 0
    log_info "Validating sudo up front so no password prompt appears mid-run."
    sudo -v
}

select_modules() {
    local -a candidates=()

    if (( ${#ONLY_MODULES[@]} )); then
        candidates=("${ONLY_MODULES[@]}")
    else
        local saved=""
        (( RECONFIGURE )) || saved=${MODULE_SELECTION:-}
        if [[ -n $saved ]]; then
            log_info "Replaying the saved module selection. Use --reconfigure to change it."
            read -r -a candidates <<< "$saved"
        else
            UI_ITEMS=()
            local name summary default label
            while IFS= read -r name; do
                summary=$(module_meta_get "$MODULES_DIR/$name" summary)
                default=$(module_meta_get "$MODULES_DIR/$name" default)
                [[ -z $default ]] && default=off
                label=$summary
                [[ $name == 90-* ]] && label="$summary (changes system state)"
                UI_ITEMS+=("$name|$label|$default")
            done < <(module_list)
            # Capture the checklist's exit status separately from its output:
            # a process-substitution pipeline (the previous `mapfile < <(...)`
            # form) discards the command's exit status, so pressing Cancel in
            # whiptail was indistinguishable from selecting nothing and the
            # run proceeded with 00-core alone.
            local checklist_out checklist_rc=0
            checklist_out=$(ui_checklist "Select modules to run") || checklist_rc=$?
            if (( checklist_rc )); then
                log_error "Module selection cancelled; aborting."
                return 1
            fi
            mapfile -t candidates <<< "$checklist_out"
        fi
    fi

    # Note: "${arr[@]:-}" on an EMPTY array still yields one element (an
    # empty string), it does not vanish — that is why every loop below
    # guards with `[[ -z $m ]] && continue`. Deleting that guard as
    # "redundant" would let a phantom empty entry slip through and, on an
    # empty $candidates, defeat the has_core check below.
    # 00-core is a hard prerequisite and cannot be deselected.
    local has_core=0 m
    for m in "${candidates[@]:-}"; do
        [[ $m == 00-core ]] && has_core=1
    done
    (( has_core )) || candidates=(00-core "${candidates[@]:-}")

    # Apply --skip, but never to 00-core.
    local -a kept=()
    local skip
    for m in "${candidates[@]:-}"; do
        [[ -z $m ]] && continue
        local drop=0
        for skip in "${SKIP_MODULES[@]:-}"; do
            [[ $m == "$skip" && $m != 00-core ]] && drop=1
        done
        (( drop )) || kept+=("$m")
    done

    module_resolve_order "${kept[@]}" || return 1
    # A targeted run (--only/--skip) is a one-off, not a new preference: only
    # persist the selection when the caller did not narrow it, otherwise a
    # single `--only 60-nas` run would permanently replace the saved
    # selection and every later plain run would replay just that module.
    if (( ${#ONLY_MODULES[@]} == 0 && ${#SKIP_MODULES[@]} == 0 )); then
        localenv_set MODULE_SELECTION "${MODULE_ORDER[*]}"
    fi
    log_info "Modules: ${MODULE_ORDER[*]}"
    return 0
}

collect_prompts() {
    log_step "Collecting answers up front"
    local name
    for name in "${MODULE_ORDER[@]}"; do
        if [[ -f $MODULES_DIR/$name/prompts.sh ]]; then
            MODULE_DIR="$MODULES_DIR/$name"
            # shellcheck disable=SC1090
            source "$MODULES_DIR/$name/prompts.sh"
        fi
    done
}

main() {
    parse_args "$@" || { local rc=$?; [[ $rc -eq 10 ]] && return 0; return "$rc"; }

    # shellcheck source=lib/log.sh
    source "$REPO_ROOT/lib/log.sh"
    # shellcheck source=lib/patch.sh
    source "$REPO_ROOT/lib/patch.sh"
    # shellcheck source=lib/link.sh
    source "$REPO_ROOT/lib/link.sh"
    # shellcheck source=lib/apt.sh
    source "$REPO_ROOT/lib/apt.sh"
    # shellcheck source=lib/pkg.sh
    source "$REPO_ROOT/lib/pkg.sh"
    # shellcheck source=lib/ui.sh
    source "$REPO_ROOT/lib/ui.sh"
    # shellcheck source=lib/module.sh
    source "$REPO_ROOT/lib/module.sh"

    log_init
    (( DRY_RUN )) && log_warn "Dry run: no command will actually execute."

    preflight || return 1
    localenv_load
    select_modules || return 1
    collect_prompts
    sudo_validate || return 1

    local name
    for name in "${MODULE_ORDER[@]}"; do
        module_run "$name"
    done

    summary_print
}

if [[ ${BOOTSTRAP_NO_MAIN:-0} -eq 0 ]]; then
    main "$@"
fi
