# shellcheck shell=bash
# Manifest parsing, module discovery, dependency ordering, selection
# persistence, and the per-module run.

: "${MODULES_DIR:=}"
: "${LOCAL_ENV:=${XDG_CONFIG_HOME:-$HOME/.config}/config-bootstrap/local.env}"

MODULE_ORDER=()
MODULE_DIR=""
# -g is load-bearing: if this file is sourced from inside a function
# frame (directly or indirectly), a plain `declare -A` scopes the array
# to that frame and it reverts to unset once the frame returns. Every
# module name in this project is hyphenated (e.g. 00-core), and a
# hyphenated key on an unset/non-associative array is parsed as an
# arithmetic expression (00 - core), which aborts under `set -u` with
# "core: unbound variable". Do not drop the -g.
declare -gA _MOD_STATE=()

# manifest_read FILE — one entry per line. Strips blank lines, whole-line
# comments, and surrounding whitespace. Trailing comments are NOT stripped:
# a repos sources-line may legitimately contain a '#'.
manifest_read() {
    local file=$1
    [[ -f $file ]] || return 0
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$file" \
        | grep -v -e '^$' -e '^#' || true
}

# module_meta_get DIR KEY
module_meta_get() {
    local dir=$1 key=$2
    [[ -f $dir/meta ]] || return 0
    sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$dir/meta" | head -1
}

module_list() {
    local dir
    for dir in "$MODULES_DIR"/*/; do
        [[ -f ${dir}meta ]] || continue
        basename "$dir"
    done | sort
}

_module_visit() {
    local name=$1
    case ${_MOD_STATE[$name]:-new} in
        done) return 0 ;;
        visiting)
            log_error "dependency cycle involving module: $name"
            return 1
            ;;
    esac
    if [[ ! -f $MODULES_DIR/$name/meta ]]; then
        log_error "unknown module: $name"
        return 1
    fi
    _MOD_STATE[$name]=visiting
    local dep
    # requires is a space-separated list; word splitting is intentional.
    # shellcheck disable=SC2046
    for dep in $(module_meta_get "$MODULES_DIR/$name" requires); do
        _module_visit "$dep" || return 1
    done
    _MOD_STATE[$name]="done"
    MODULE_ORDER+=("$name")
    return 0
}

# module_resolve_order NAME... — sets MODULE_ORDER.
module_resolve_order() {
    MODULE_ORDER=()
    _MOD_STATE=()
    local name
    while IFS= read -r name; do
        [[ -z $name ]] && continue
        _module_visit "$name" || return 1
    done < <(printf '%s\n' "$@" | sort -u)
    return 0
}

localenv_load() {
    [[ -f $LOCAL_ENV ]] || return 0
    # shellcheck disable=SC1090
    source "$LOCAL_ENV"
}

# localenv_set KEY VALUE — upsert into the gitignored local config.
localenv_set() {
    local key=$1 value=$2 dir content=""
    dir=$(dirname "$LOCAL_ENV")
    if (( DRY_RUN )); then
        _log DRY '0;36' "set $key in $LOCAL_ENV"
        return 0
    fi
    [[ -d $dir ]] || run mkdir -p "$dir"
    if [[ -f $LOCAL_ENV ]]; then
        content=$(grep -v "^${key}=" "$LOCAL_ENV" || true)
    fi
    {
        [[ -n $content ]] && printf '%s\n' "$content"
        printf '%s="%s"\n' "$key" "$value"
    } > "$LOCAL_ENV.tmp"
    run mv "$LOCAL_ENV.tmp" "$LOCAL_ENV"
    run chmod 600 "$LOCAL_ENV"
}

# module_run NAME
module_run() {
    local name=$1
    local dir="$MODULES_DIR/$name"
    log_step "Module: $name"

    local apt_before=${#APT_FAILED[@]}
    local pkg_before=${#PKG_FAILED[@]}

    # 1. Repositories, before anything is installed.
    local line rname rkey rline
    while IFS= read -r line; do
        [[ -z $line ]] && continue
        IFS='|' read -r rname rkey rline <<< "$line"
        apt_add_repo "$rname" "$rkey" "$rline" \
            || log_error "repo registration failed: $rname"
    done < <(manifest_read "$dir/repos")

    # 2. Package manifests.
    local -a pkgs=()
    mapfile -t pkgs < <(manifest_read "$dir/apt")
    (( ${#pkgs[@]} )) && apt_install "${pkgs[@]}"

    local -a snaps=()
    mapfile -t snaps < <(manifest_read "$dir/snap")
    (( ${#snaps[@]} )) && pkg_snap_install "${snaps[@]}"

    # 3. The imperative remainder. errexit is lifted so a failure here is
    #    contained to this module, while still allowing setup.sh to use the
    #    engine's helpers and record its own summary rows.
    if [[ -f $dir/setup.sh ]]; then
        # shellcheck disable=SC2034 # consumed by setup.sh, not this file
        MODULE_DIR=$dir
        local rc=0
        # A module's setup.sh is sourced, not executed, so it should signal
        # failure with `return`, not `exit`. The shadow below is a safety
        # net for a stray `exit` call, not the intended path: sourcing a
        # file that calls `exit` would otherwise kill this whole process.
        # Shadowing it as a function makes it behave like `return` instead,
        # stopping just the sourced script. This keeps everything in the
        # current shell (so summary_add calls inside setup.sh still land in
        # SUMMARY_ROWS) while still containing the failure to this module.
        #
        # Caveat: `return` does not abort the rest of the sourced file the
        # way `exit` would have — any lines after the `exit` call still run.
        # There is no reliable way to stop a sourced script from a function,
        # and this only matters on a path where the module author already
        # made a mistake. We still need the exit CODE though: `source`
        # reports the status of the last command in the file, which may not
        # be the `exit` call if later lines ran. Capture it in a sentinel so
        # a later successful command can't mask the original failure.
        local _setup_exit=""
        # shellcheck disable=SC2329 # invoked indirectly, if at all, by setup.sh
        exit() { _setup_exit=${1:-0}; return "${1:-0}"; }
        set +e
        # shellcheck disable=SC1090,SC1091
        source "$dir/setup.sh"
        rc=$?
        set -e
        unset -f exit
        [[ -n $_setup_exit ]] && rc=$_setup_exit
        if (( rc )); then
            summary_add failed "$name" "setup.sh exited $rc"
            return 0
        fi
    fi

    local new_failures=$(( ${#APT_FAILED[@]} - apt_before + ${#PKG_FAILED[@]} - pkg_before ))
    if (( new_failures )); then
        summary_add failed "$name" "$new_failures package(s) failed"
        # Spec §7: list every failure so it can be chased individually, not
        # just a count. APT_FAILED/PKG_FAILED are cumulative across the
        # whole run, so only the slice appended since this module started
        # belongs to it.
        local -a names=()
        (( ${#APT_FAILED[@]} > apt_before )) && names+=("${APT_FAILED[@]:$apt_before}")
        (( ${#PKG_FAILED[@]} > pkg_before )) && names+=("${PKG_FAILED[@]:$pkg_before}")
        (( ${#names[@]} )) && summary_note "$name: failed package(s): ${names[*]}"
    else
        summary_add ok "$name"
    fi
    return 0
}
