#!/usr/bin/env bash
# Tie the repo's dotfiles to their live locations.
#
#   ./dotfiles.sh                        # what is linked and what is not
#   ./dotfiles.sh link                   # link anything not yet linked
#   ./dotfiles.sh adopt ~/.tmux.conf     # pull a live file into the repo
#
# The companion to bootstrap.sh, not a part of it. bootstrap.sh converges a
# machine once; this converges the repo and the machine whenever config
# changes. They share lib/ and nothing else.
set -euo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$SELF_DIR
DOTFILES_DIR="$REPO_ROOT/dotfiles"
MANIFEST="$DOTFILES_DIR/links"

DRY_RUN=0
ASSUME_YES=0
LINK_FORCE=0
SUBCOMMAND=status
TARGETS=()

usage() {
    cat <<'EOF'
Usage: dotfiles.sh [status|link|adopt] [options] [PATH...]

  status                  Report every manifest entry's link state (default)
  link [PATH...]          Link entries that are not linked yet
  adopt PATH [REPO_REL]   Move a live file into the repo and link it back

  --force           link:  replace the live file, backing it up first
                    adopt: proceed even though the repo file has
                           uncommitted changes
  --dry-run         Print every action without performing it
  --yes, -y         Accept the inferred repo path; never prompt
  -h, --help        Show this message

Nothing is committed for you. Review with `git diff`, then commit.
EOF
}

parse_args() {
    SUBCOMMAND=status
    TARGETS=()
    if (( $# )) && [[ $1 != -* ]]; then
        case $1 in
            status | link | adopt)
                SUBCOMMAND=$1
                shift
                ;;
            *)
                printf 'Unknown subcommand: %s\n' "$1" >&2
                return 2
                ;;
        esac
    fi
    while (( $# )); do
        case $1 in
            --dry-run) DRY_RUN=1 ;;
            --force) LINK_FORCE=1 ;;
            --yes | -y) ASSUME_YES=1 ;;
            -h | --help)
                usage
                return 10
                ;;
            -*)
                printf 'Unknown option: %s\n' "$1" >&2
                return 2
                ;;
            *)
                TARGETS+=("$1")
                ;;
        esac
        shift
    done
    return 0
}

# dotfiles_tildify PATH — print PATH with $HOME collapsed back to ~, so that
# every message and every appended manifest entry shows the portable form.
dotfiles_tildify() {
    local path=$1
    # The "$HOME" case is separate because "$HOME"/* requires a literal
    # slash after it, so a bare $HOME would otherwise print as an absolute
    # path while every path under it printed as ~/...
    if [[ $path == "$HOME" ]]; then
        printf '~\n'
        return 0
    fi
    if [[ $path == "$HOME"/* ]]; then
        printf '~%s\n' "${path#"$HOME"}"
        return 0
    fi
    printf '%s\n' "$path"
}

# dotfiles_infer_repo_path LIVE_PATH — a best-effort repo-relative path.
#
# Always shown for confirmation, never applied blind, because the existing
# manifest contains two precedents no single rule satisfies:
#
#   ~/.config/fish/functions/usd.fish -> fish/functions/usd.fish   (strip ~/.config/)
#   ~/.gitconfig                      -> git/gitconfig             (strip the dot AND
#                                                                   invent the grouping)
#
# Nothing can derive "git" from ".gitconfig", so the rules below produce
# `gitconfig` for that case and rely on the user editing the prompt.
#
# Rules, in order:
#   under ~/.config/   the path relative to ~/.config
#   name has a suffix  <stem>/<name>, with any leading dot stripped
#   no suffix          <name>, with any leading dot stripped
dotfiles_infer_repo_path() {
    local live=$1 base stem
    if [[ $live == "$HOME/.config/"* ]]; then
        printf '%s\n' "${live#"$HOME/.config/"}"
        return 0
    fi
    base=$(basename "$live")
    base=${base#.}
    stem=${base%%.*}
    if [[ $stem != "$base" ]]; then
        printf '%s/%s\n' "$stem" "$base"
        return 0
    fi
    printf '%s\n' "$base"
}

# cmd_status — one line per manifest entry, then the untracked audit.
# Exit 1 means "something would change", not "something is broken", so a
# fresh machine reports non-zero until its first link.
cmd_status() {
    local rel dest state shown pending=0
    log_step "Dotfile links"
    while IFS=$'\t' read -r rel dest; do
        state=$(link_state "$DOTFILES_DIR/$rel" "$dest")
        shown=$(dotfiles_tildify "$dest")
        case $state in
            linked)
                log_ok "$(printf '%-10s %-30s %s' linked "$rel" "$shown")"
                ;;
            missing)
                log_info "$(printf '%-10s %-30s %s' missing "$rel" "$shown")"
                pending=1
                ;;
            unlinked)
                log_warn "$(printf '%-10s %-30s %s' unlinked "$rel" "$shown")"
                # Deliberately does not say "a real file": link_state's
                # unlinked branch uses -f, which dereferences symlinks, so
                # this state also covers a symlink pointing somewhere else
                # whose target happens to match the repo file byte for byte.
                log_warn "           content matches the repo; ./dotfiles.sh link will point it at dotfiles/$rel"
                pending=1
                ;;
            diverged)
                log_warn "$(printf '%-10s %-30s %s' DIVERGED "$rel" "$shown")"
                link_warn_skip "$dest"
                pending=1
                ;;
            broken)
                log_error "$(printf '%-10s %-30s %s' BROKEN "$rel" "$shown")"
                log_error "           dotfiles/$rel is in the manifest but not in the repo"
                pending=1
                ;;
        esac
    done < <(link_manifest_entries "$MANIFEST")

    cmd_status_untracked

    if (( pending )); then
        return 1
    fi
    return 0
}

# cmd_status_untracked — files under dotfiles/ that no manifest entry names.
#
# Informational only, and deliberately so: some are legitimately owned by a
# module rather than the manifest. fish/functions/winboot.fish is linked by
# 90-dualboot, because winboot must only land on a dual-boot machine, and
# ssh/config.template is rendered by 60-nas rather than linked at all. There
# is no ignore list, because that would be machinery for two known entries.
cmd_status_untracked() {
    local referenced=() untracked=() rel dest found candidate seen
    while IFS=$'\t' read -r rel dest; do
        referenced+=("$rel")
    done < <(link_manifest_entries "$MANIFEST")

    while IFS= read -r found; do
        candidate=${found#"$DOTFILES_DIR/"}
        if [[ $candidate == links ]]; then
            continue
        fi
        seen=0
        for rel in "${referenced[@]:-}"; do
            if [[ $rel == "$candidate" ]]; then
                seen=1
            fi
        done
        if (( ! seen )); then
            untracked+=("$candidate")
        fi
    done < <(find "$DOTFILES_DIR" -type f | sort)

    if (( ${#untracked[@]} == 0 )); then
        return 0
    fi
    printf '\n'
    log_step "In dotfiles/ but not in the manifest — linked by a module, or not linked at all"
    for candidate in "${untracked[@]}"; do
        log_info "  $candidate"
    done
    return 0
}

# dotfiles_target_matches DEST REL — does TARGETS name this manifest entry?
# Accepts either side of the manifest line, since both are things a user
# plausibly copies out of `status` output.
dotfiles_target_matches() {
    local dest=$1 rel=$2 target expanded
    for target in "${TARGETS[@]:-}"; do
        if [[ -z $target ]]; then
            continue
        fi
        expanded=${target/#\~/$HOME}
        if [[ $expanded == "$dest" || $target == "$rel" ]]; then
            return 0
        fi
    done
    return 1
}

# cmd_link — the interactive policy. The user is present, so a conflict is
# reported in full and left for them to resolve, rather than skipped quietly
# the way bootstrap does it.
cmd_link() {
    local rel dest state shown rc=0 scoped=0 matched=()
    if (( ${#TARGETS[@]} )); then
        scoped=1
    fi

    while IFS=$'\t' read -r rel dest; do
        if (( scoped )) && ! dotfiles_target_matches "$dest" "$rel"; then
            continue
        fi
        matched+=("$dest" "$rel")
        shown=$(dotfiles_tildify "$dest")
        state=$(link_state "$DOTFILES_DIR/$rel" "$dest")

        if (( LINK_FORCE )) && [[ $state != linked && $state != broken ]]; then
            # link_file does the backup itself, and logs the path it used.
            log_warn "replacing $shown; the live file is backed up to $shown.bak-$RUN_STAMP"
            if ! link_file "$DOTFILES_DIR/$rel" "$dest"; then
                rc=1
            fi
            continue
        fi

        case $state in
            linked)
                log_ok "already linked: $shown"
                ;;
            missing)
                if ! link_file "$DOTFILES_DIR/$rel" "$dest"; then
                    rc=1
                fi
                ;;
            unlinked)
                # Byte-identical, so there is nothing to back up. Remove it
                # first so link_file sees a clean destination and does not
                # write a pointless .bak- copy of content we already have.
                log_info "converting an identical file to a symlink: $shown"
                run rm -f "$dest"
                if ! link_file "$DOTFILES_DIR/$rel" "$dest"; then
                    rc=1
                fi
                ;;
            diverged)
                log_warn "DIVERGED: $shown"
                # diff exits 1 when the files differ, which is the whole
                # reason we are here.
                diff -u \
                    --label "repo: dotfiles/$rel" \
                    --label "live: $shown" \
                    "$DOTFILES_DIR/$rel" "$dest" || true
                link_warn_skip "$dest"
                rc=1
                ;;
            broken)
                log_error "dotfiles/$rel is in the manifest but not in the repo"
                rc=1
                ;;
        esac
    done < <(link_manifest_entries "$MANIFEST")

    if (( scoped )); then
        local target expanded hit
        for target in "${TARGETS[@]}"; do
            expanded=${target/#\~/$HOME}
            hit=0
            for dest in "${matched[@]:-}"; do
                if [[ $dest == "$expanded" || $dest == "$target" ]]; then
                    hit=1
                fi
            done
            if (( ! hit )); then
                log_error "no manifest entry matches: $target"
                rc=2
            fi
        done
    fi
    return "$rc"
}

# dotfiles_is_dirty REPO_PATH — does git see any uncommitted change here?
#
# Covers staged, unstaged, and untracked in one query. A path outside a git
# repository counts as clean: there is no review workflow to protect.
dotfiles_is_dirty() {
    local path=$1 porcelain
    if ! git -C "$REPO_ROOT" rev-parse --git-dir > /dev/null 2>&1; then
        return 1
    fi
    porcelain=$(git -C "$REPO_ROOT" status --porcelain -- "$path" 2>/dev/null || true)
    [[ -n $porcelain ]]
}

# dotfiles_manifest_append REL DEST — append one aligned entry.
#
# Entries are only ever appended; comments and existing lines are never
# rewritten. `run` cannot carry a redirection (lib/log.sh:41), so the dry-run
# arm is explicit.
dotfiles_manifest_append() {
    local rel=$1 dest=$2 shown existing
    shown=$(dotfiles_tildify "$dest")
    while IFS=$'\t' read -r existing _; do
        if [[ $existing == "$rel" ]]; then
            log_info "the manifest already lists $rel"
            return 0
        fi
    done < <(link_manifest_entries "$MANIFEST")

    if (( DRY_RUN )); then
        _log DRY '0;36' "append to dotfiles/links: $rel $shown"
        return 0
    fi
    # %-29s plus a literal space, NOT %-30s. With %-30s a repo path of 30+
    # characters gets no separator at all — the fields run together and
    # link_manifest_entries rejects the line as having no destination, so the
    # freshly adopted dotfile silently stops being linked. Both forms put the
    # destination at column 31 for shorter paths, matching the existing file.
    printf '%-29s %s\n' "$rel" "$shown" >> "$MANIFEST"
    log_info "manifest entry added: $rel → $shown"
}

# cmd_adopt — bring a live file into the repo and link it back.
#
# The repo becomes the desired state first, then the symlink is made, which
# is what makes a divergent file reviewable in git rather than lost. Operation
# order is chosen so that any failure leaves the live file intact: copy in,
# verify, only then remove and link. Never `mv` as the first step.
cmd_adopt() {
    local live rel target resolved inferred tmplink
    if (( ${#TARGETS[@]} == 0 )); then
        log_error "adopt needs a path: ./dotfiles.sh adopt ~/.tmux.conf"
        return 2
    fi
    live=${TARGETS[0]}
    live=${live/#\~/$HOME}
    rel=${TARGETS[1]:-}

    if [[ ! -e $live && ! -L $live ]]; then
        log_error "no such file: $live"
        return 2
    fi
    if [[ -d $live ]]; then
        log_error "adopt takes a file, not a directory: $(dotfiles_tildify "$live")"
        return 2
    fi

    if [[ -L $live ]]; then
        resolved=$(readlink -f "$live")
        if [[ $resolved == "$DOTFILES_DIR/"* ]]; then
            # readlink -f canonicalises even when the final component is
            # missing, so a symlink into the repo whose target was deleted
            # still lands here. Reporting that as "already linked" would call
            # a broken config healthy and exit 0 — link_state classifies the
            # same situation as `broken`, and adopt must not disagree.
            if [[ ! -e $resolved ]]; then
                log_error "$(dotfiles_tildify "$live") points at ${resolved#"$REPO_ROOT/"}, which is missing from the repo"
                log_error "    restore that file, or remove the dangling link and adopt again"
                return 1
            fi
            log_ok "already linked: $(dotfiles_tildify "$live") → ${resolved#"$REPO_ROOT/"}"
            return 0
        fi
    fi

    if [[ -z $rel ]]; then
        inferred=$(dotfiles_infer_repo_path "$live")
        # ui_prompt returns early if the variable is already non-empty.
        DOTFILES_REPO_REL=""
        ui_prompt DOTFILES_REPO_REL \
            "Repo path under dotfiles/ for $(dotfiles_tildify "$live")" \
            "$inferred"
        rel=$DOTFILES_REPO_REL
    fi
    if [[ -z $rel ]]; then
        log_error "no repo path given"
        return 2
    fi
    # Trim trailing slashes before validating or using the path. Tab
    # completion onto a directory yields them (~/.config/fish/ infers as
    # "fish/"), and a rel ending in / makes `cp` copy INTO that directory
    # under the live basename while the manifest records the directory — a
    # quietly wrong entry rather than an error. There is only one sensible
    # reading of a trailing slash, so trim rather than reject.
    while [[ $rel == */ ]]; do
        rel=${rel%/}
    done
    if [[ -z $rel ]]; then
        log_error "repo path is empty after trimming slashes"
        return 2
    fi
    # Keep the repo path inside dotfiles/. Reachable three ways, so the check
    # lives here at the consumer rather than inside the inference: the
    # inference faithfully passes through a live path containing ..
    # (~/.config/../../../etc/passwd -> ../../../etc/passwd), the user can
    # edit the confirmation prompt, and an explicit second argument skips
    # inference altogether. Escaping would write outside the repo AND append
    # a manifest entry naming a file git does not track.
    case $rel in
        /* | .. | ../* | */../* | */..)
            log_error "repo path must stay inside dotfiles/: $rel"
            return 2
            ;;
    esac
    target="$DOTFILES_DIR/$rel"

    if [[ -e $target ]] && ! cmp -s "$live" "$target"; then
        if (( ! LINK_FORCE )) && dotfiles_is_dirty "$target"; then
            log_error "dotfiles/$rel has uncommitted changes; adopting would overwrite them"
            log_error "    review them → git -C $REPO_ROOT diff -- dotfiles/$rel"
            log_error "    overwrite   → ./dotfiles.sh adopt $(dotfiles_tildify "$live") $rel --force"
            return 1
        fi
        log_warn "dotfiles/$rel differs from the live file; the live file wins"
    fi

    run mkdir -p "$(dirname "$target")"
    # -L, not -a. `cp -a` implies -d (no-dereference), so adopting a live
    # file that is itself a symlink pointing outside the repo would put a
    # SYMLINK into dotfiles/ aimed at an absolute external path — committed,
    # that is broken on every other machine. The verification below cannot
    # catch it either: cmp dereferences both sides, so it would compare the
    # same file against itself and pass.
    run cp -L --preserve=mode,timestamps "$live" "$target"
    if (( ! DRY_RUN )) && ! cmp -s "$live" "$target"; then
        log_error "copy verification failed; $(dotfiles_tildify "$live") was left untouched"
        return 1
    fi
    # Atomic swap, not remove-then-link. `rm` followed by `ln` leaves a window
    # where the live path holds nothing at all: if the link step fails there
    # (ENOSPC, a permissions change), the user's config file is simply gone
    # until they re-run `link`. Staging the symlink beside the live path and
    # renaming it over replaces in one syscall, so the path always holds
    # either the original file or the finished symlink — which is what this
    # function's header comment promises.
    #
    # In a dry run nothing was copied, so there is no link to stage; describe
    # it instead, the way lib/log.sh's own dry-run arm does.
    if (( DRY_RUN )); then
        _log DRY '0;36' "ln -s $target $live (replacing the live file)"
    else
        tmplink="$live.dotfiles-adopt-$$"
        if ! run ln -s "$target" "$tmplink"; then
            log_error "could not stage a symlink at $tmplink; $(dotfiles_tildify "$live") is untouched"
            return 1
        fi
        if ! run mv -T "$tmplink" "$live"; then
            run rm -f "$tmplink"
            log_error "could not replace $(dotfiles_tildify "$live"); it is untouched"
            return 1
        fi
    fi
    dotfiles_manifest_append "$rel" "$live"

    log_step "Adopted dotfiles/$rel"
    log_info "Review it with: git -C $REPO_ROOT diff"
    return 0
}

main() {
    # shellcheck source=lib/log.sh
    source "$REPO_ROOT/lib/log.sh"
    # shellcheck source=lib/link.sh
    source "$REPO_ROOT/lib/link.sh"
    # shellcheck source=lib/ui.sh
    source "$REPO_ROOT/lib/ui.sh"

    local rc=0
    parse_args "$@" || rc=$?
    if (( rc == 10 )); then
        return 0
    fi
    if (( rc )); then
        usage >&2
        return "$rc"
    fi

    if [[ ! -f $MANIFEST ]]; then
        log_error "no manifest at $MANIFEST"
        return 1
    fi

    case $SUBCOMMAND in
        status) cmd_status ;;
        link) cmd_link ;;
        adopt) cmd_adopt ;;
    esac
}

# DOTFILES_NO_MAIN lets the tests source this file for its functions without
# executing anything, the same seam bootstrap.sh uses.
if [[ -z ${DOTFILES_NO_MAIN:-} ]]; then
    main "$@"
fi
