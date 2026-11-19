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
        LINK_RESULT=unchanged
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

# link_state SRC DEST — prints one of: linked missing unlinked diverged broken
#
# Classification only: it never touches the filesystem, and it makes no policy
# decision. Callers decide what each state means to them, which is how one
# implementation serves both an additive bootstrap and an interactive CLI.
#
# Order matters. A missing SRC is a manifest bug and outranks whatever happens
# to be at DEST, so `broken` is tested first.
link_state() {
    local src=$1 dest=$2
    if [[ ! -e $src ]]; then
        printf 'broken\n'
        return 0
    fi
    if [[ -L $dest ]] && [[ "$(readlink -f "$dest")" == "$(readlink -f "$src")" ]]; then
        printf 'linked\n'
        return 0
    fi
    # -e alone would call a dangling symlink "missing" and then happily
    # replace it; -L catches that case so it falls through to diverged.
    if [[ ! -e $dest && ! -L $dest ]]; then
        printf 'missing\n'
        return 0
    fi
    if [[ -f $dest ]] && cmp -s "$dest" "$src"; then
        printf 'unlinked\n'
        return 0
    fi
    printf 'diverged\n'
}

# link_manifest_entries MANIFEST — prints REL<TAB>DEST for each real entry.
#
# The one place the manifest format is parsed. Comments, blank lines, a
# leading ~ in the destination, and a final line with no trailing newline are
# all handled here so that every consumer gets identical behavior.
link_manifest_entries() {
    local manifest=$1 rel dest
    while read -r rel dest _ || [[ -n $rel ]]; do
        if [[ -z $rel || $rel == \#* ]]; then
            continue
        fi
        if [[ -z $dest ]]; then
            # >&2 is load-bearing. log_error prints to stdout (lib/log.sh:24-28),
            # and this function's stdout IS the data channel its consumers parse.
            # Without the redirect the diagnostic becomes a phantom entry: the
            # reader splits it on tab, gets no tab, and treats the whole message
            # as a repo-relative path.
            log_error "manifest line has no destination: $rel" >&2
            continue
        fi
        printf '%s\t%s\n' "$rel" "${dest/#\~/$HOME}"
    done < "$manifest"
}

# link_manifest MANIFEST REPO_ROOT
link_manifest() {
    local manifest=$1 root=$2
    local rel dest
    while IFS=$'\t' read -r rel dest; do
        link_file "$root/$rel" "$dest" || true
    done < <(link_manifest_entries "$manifest")
}
