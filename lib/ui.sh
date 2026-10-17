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
    local var=$1 prompt=$2 default=${3:-} value
    value=${!var:-}
    if [[ -n $value ]]; then
        return 0
    fi
    if (( ASSUME_YES )) || ! ui_has_tty; then
        value=$default
    elif ui_has_whiptail; then
        value=$(whiptail --title "Bootstrap" --inputbox "$prompt" 10 70 "$default" 3>&1 1>&2 2>&3) \
            || value=$default
    else
        read -r -p "$prompt [$default]: " value
        [[ -z $value ]] && value=$default
    fi
    printf -v "$var" '%s' "$value"
    export "${var?}"
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
