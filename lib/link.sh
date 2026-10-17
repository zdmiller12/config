# shellcheck shell=bash
# Dotfile symlinking. Anything pre-existing and not already a symlink is
# backed up before being replaced.

# shellcheck disable=SC2034
LINK_RESULT=unchanged

# link_file SRC DEST
link_file() {
    local src=$1 dest=$2
    if [[ ! -e $src ]]; then
        log_error "link source does not exist: $src"
        return 1
    fi
    if [[ -L $dest ]]; then
        if [[ "$(readlink -f "$dest")" == "$(readlink -f "$src")" ]]; then
            LINK_RESULT=unchanged
            return 0
        fi
        run rm -f "$dest"
    elif [[ -e $dest ]]; then
        run cp -a "$dest" "$dest.bak-$RUN_STAMP"
        run rm -rf "$dest"
    fi
    run mkdir -p "$(dirname "$dest")"
    run ln -s "$src" "$dest"
    LINK_RESULT=changed
}

# link_manifest MANIFEST REPO_ROOT
link_manifest() {
    local manifest=$1 root=$2
    local rel dest
    while read -r rel dest _; do
        [[ -z $rel || $rel == \#* ]] && continue
        [[ -z $dest ]] && { log_error "manifest line has no destination: $rel"; continue; }
        dest=${dest/#\~/$HOME}
        link_file "$root/$rel" "$dest" || log_error "could not link $rel"
    done < "$manifest"
}
