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
            --force)
                # No reader until cmd_link lands in Task 6; shellcheck is
                # correct that nothing consumes this yet. Scoped to this one
                # statement on purpose — a disable above parse_args() would
                # mask SC2034 for DRY_RUN, ASSUME_YES, SUBCOMMAND and TARGETS
                # too, and parse_args is exactly where an unused variable
                # would be a real bug. Task 6 removes this directive.
                # shellcheck disable=SC2034
                LINK_FORCE=1
                ;;
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

cmd_link()   { log_error "cmd_link is not implemented yet"; return 1; }
cmd_adopt()  { log_error "cmd_adopt is not implemented yet"; return 1; }

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
