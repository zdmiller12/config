# shellcheck shell=bash
# The module checklist and prompts. whiptail when a TTY is available,
# a numbered list otherwise.

: "${ASSUME_YES:=0}"
UI_ITEMS=()

ui_has_tty()       { [[ -t 0 && -t 1 ]]; }
ui_has_whiptail()  { command -v whiptail > /dev/null 2>&1; }

_ui_defaults_on() {
    local entry tag desc state
    for entry in "${UI_ITEMS[@]:-}"; do
        [[ -z $entry ]] && continue
        IFS='|' read -r tag desc state <<< "$entry"
        [[ $state == on ]] && printf '%s\n' "$tag"
    done
    return 0
}

# ui_checklist TITLE — prints the selected tags, one per line.
ui_checklist() {
    local title=$1

    if (( ASSUME_YES )) || ! ui_has_tty; then
        _ui_defaults_on
        return 0
    fi

    local entry tag desc state
    if ui_has_whiptail; then
        local -a args=()
        for entry in "${UI_ITEMS[@]:-}"; do
            [[ -z $entry ]] && continue
            IFS='|' read -r tag desc state <<< "$entry"
            args+=("$tag" "$desc" "$state")
        done
        # --separate-output makes whiptail emit bare newline-separated tags.
        whiptail --title "$title" --separate-output \
            --checklist "Space toggles, Enter confirms." 20 78 12 \
            "${args[@]}" 3>&1 1>&2 2>&3
        return $?
    fi

    # Numbered fallback.
    local -a tags=() states=()
    local i=0
    for entry in "${UI_ITEMS[@]:-}"; do
        [[ -z $entry ]] && continue
        IFS='|' read -r tag desc state <<< "$entry"
        tags+=("$tag")
        states+=("$state")
        i=$((i + 1))
        printf '  %2d) [%s] %-30s %s\n' "$i" \
            "$([[ $state == on ]] && printf 'x' || printf ' ')" "$tag" "$desc" >&2
    done
    printf '\nEnter numbers to toggle, comma-separated, or Enter to accept: ' >&2
    local reply
    read -r reply
    local -a toggles=()
    IFS=', ' read -r -a toggles <<< "$reply"
    local n
    for n in "${toggles[@]:-}"; do
        [[ $n =~ ^[0-9]+$ ]] || continue
        (( n >= 1 && n <= ${#tags[@]} )) || continue
        if [[ ${states[n - 1]} == on ]]; then
            states[n - 1]=off
        else
            states[n - 1]=on
        fi
    done
    for i in "${!tags[@]}"; do
        [[ ${states[$i]} == on ]] && printf '%s\n' "${tags[$i]}"
    done
    return 0
}

# ui_prompt VARNAME PROMPT [DEFAULT]
ui_prompt() {
    local _ui_var=$1 _ui_prompt=$2 _ui_default=${3:-} _ui_value
    _ui_value=${!_ui_var:-}
    if [[ -n $_ui_value ]]; then
        return 0
    fi
    if (( ASSUME_YES )) || ! ui_has_tty; then
        _ui_value=$_ui_default
    elif ui_has_whiptail; then
        _ui_value=$(whiptail --title "Bootstrap" --inputbox "$_ui_prompt" 10 70 "$_ui_default" 3>&1 1>&2 2>&3) \
            || _ui_value=$_ui_default
    else
        read -r -p "$_ui_prompt [$_ui_default]: " _ui_value
        [[ -z $_ui_value ]] && _ui_value=$_ui_default
    fi
    printf -v "$_ui_var" '%s' "$_ui_value"
    export "${_ui_var?}"
}

# ui_pause MESSAGE
ui_pause() {
    local message=$1
    if (( ASSUME_YES )) || ! ui_has_tty; then
        log_info "$message"
        return 0
    fi
    log_warn "$message"
    read -r -p "Press Enter to continue… "
}
