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

# LINK_FORCE is read by cmd_link once Task 6 lands, not by this function;
# shellcheck disable=SC2034
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
    if [[ $path == "$HOME"/* ]]; then
        printf '~%s\n' "${path#"$HOME"}"
        return 0
    fi
    printf '%s\n' "$path"
}

cmd_status() { log_error "cmd_status is not implemented yet"; return 1; }
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
