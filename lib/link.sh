# shellcheck shell=bash
# Dotfile symlinking. Anything pre-existing and not already a symlink is
# backed up before being replaced.

# shellcheck disable=SC2034
LINK_RESULT=unchanged
# Number of entries the last link_manifest call declined to touch. Read by
# the 10-shell module to raise a single end-of-run follow-up note.
LINK_SKIPPED=0

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

# link_warn_skip DEST — the yellow, actionable report for a destination that
# already has something at it.
#
# Both directions are offered on purpose. The right answer depends on which
# copy the user considers authoritative, and guessing wrong is destructive:
# on a fresh machine a program may have written its own starter file at the
# destination, and naming only `adopt` would pull that stub into the repo on
# top of the real committed file.
link_warn_skip() {
    local dest=$1 shown=$1
    if [[ $dest == "$HOME"/* ]]; then
        shown="~${dest#"$HOME"}"
    fi
    log_warn "not linked: a file already exists at $shown"
    log_warn "    keep the live file → ./dotfiles.sh adopt $shown"
    log_warn "    keep the repo file → ./dotfiles.sh link --force $shown"
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

# link_manifest MANIFEST REPO_ROOT — the additive policy.
#
# Creates symlinks only where nothing exists yet. Anything already at a
# destination is left exactly as it is and reported, so that a bootstrap run
# cannot destroy live configuration no matter what state the machine is in.
#
# Always returns 0. On a machine that has been used, a skip is the expected
# outcome rather than an error, and it must not fail the 10-shell module.
# Callers read LINK_SKIPPED to decide whether to raise a follow-up note.
link_manifest() {
    local manifest=$1 root=$2
    local rel dest state
    LINK_SKIPPED=0
    # A missing manifest is an error, not a skip. The process substitution
    # below opens the file in its own subshell, so without this guard the
    # open failure is invisible here and a typo'd path looks like a clean run
    # with nothing to do.
    #
    # Returns 0 rather than 1 deliberately, though not for the reason you
    # might expect: lib/module.sh:165-169 brackets its `source setup.sh` in
    # `set +e`/`set -e` and keeps only the last command's status, so a
    # non-zero return here could not fail the module anyway. It matters
    # because this library is also sourced standalone and called directly
    # from tests, where a non-zero return under `set -e` does abort the
    # caller. Report loudly, return 0.
    if [[ ! -f $manifest ]]; then
        log_error "no dotfile manifest at $manifest"
        return 0
    fi
    while IFS=$'\t' read -r rel dest; do
        state=$(link_state "$root/$rel" "$dest")
        case $state in
            linked)
                ;;
            missing)
                link_file "$root/$rel" "$dest" || true
                ;;
            broken)
                log_warn "not linked: the manifest entry '$rel' names a file that is not in the repo"
                LINK_SKIPPED=$(( LINK_SKIPPED + 1 ))
                ;;
            *)
                link_warn_skip "$dest"
                LINK_SKIPPED=$(( LINK_SKIPPED + 1 ))
                ;;
        esac
    done < <(link_manifest_entries "$manifest")
    return 0
}
