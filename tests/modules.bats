#!/usr/bin/env bats
# Module-metadata tests: catch a malformed module without needing a
# machine. The cheap half of spec §8's testing strategy. The expensive
# half — the real container run — lives in tests/container-smoke.sh.

load helper

setup() {
    load_lib log
    load_lib patch
    load_lib apt
    load_lib pkg
    load_lib module
    MODULES_DIR="$REPO_ROOT/modules"
    DRY_RUN=1
    RUN_STAMP="test"
}

@test "every module declares name, summary, default, and container" {
    local missing=""
    while IFS= read -r m; do
        for key in name summary default container; do
            [[ -n "$(module_meta_get "$MODULES_DIR/$m" "$key")" ]] \
                || missing="$missing $m:$key"
        done
    done < <(module_list)
    [ -z "$missing" ] || { echo "missing keys:$missing"; return 1; }
}

@test "every module's default is exactly on or off" {
    while IFS= read -r m; do
        d=$(module_meta_get "$MODULES_DIR/$m" default)
        [[ $d == on || $d == off ]] || { echo "$m has default=$d"; return 1; }
    done < <(module_list)
}

@test "every module's name matches its directory" {
    while IFS= read -r m; do
        n=$(module_meta_get "$MODULES_DIR/$m" name)
        [ "$n" = "$m" ] || { echo "$m declares name=$n"; return 1; }
    done < <(module_list)
}

@test "every 90-prefixed module defaults to off" {
    while IFS= read -r m; do
        case $m in
            90-*)
                d=$(module_meta_get "$MODULES_DIR/$m" default)
                [ "$d" = off ] || { echo "$m is a 90- module with default=$d"; return 1; }
                ;;
        esac
    done < <(module_list)
}

@test "60-nas defaults to off" {
    [ "$(module_meta_get "$MODULES_DIR/60-nas" default)" = off ]
}

@test "every requires names a module that exists" {
    while IFS= read -r m; do
        for dep in $(module_meta_get "$MODULES_DIR/$m" requires); do
            [ -f "$MODULES_DIR/$dep/meta" ] \
                || { echo "$m requires missing module $dep"; return 1; }
        done
    done < <(module_list)
}

@test "the full default selection resolves without a cycle" {
    local -a defaults=()
    while IFS= read -r m; do
        [[ "$(module_meta_get "$MODULES_DIR/$m" default)" == on ]] && defaults+=("$m")
    done < <(module_list)
    module_resolve_order "${defaults[@]}"
    [ "${#MODULE_ORDER[@]}" -ge 1 ]
}

@test "20-toolchains requires 10-shell" {
    [ "$(module_meta_get "$MODULES_DIR/20-toolchains" requires)" = "10-shell" ]
}

# Real package names in this repo include a dot (containerd.io), multiple
# hyphens (mkvtoolnix-gui, fonts-indic), and snap specs that may carry
# trailing flags (e.g. "code --classic"). The character class below is
# deliberately wide enough to admit all of those; if it ever rejects a
# legitimate name, widen the class rather than deleting this test.
@test "every manifest line looks like a package name" {
    while IFS= read -r m; do
        for file in apt snap; do
            [[ -f $MODULES_DIR/$m/$file ]] || continue
            while IFS= read -r entry; do
                [[ $entry =~ ^[a-zA-Z0-9][a-zA-Z0-9.+:_-]*(\ --[a-z-]+)*$ ]] \
                    || { echo "$m/$file has a suspect entry: '$entry'"; return 1; }
            done < <(manifest_read "$MODULES_DIR/$m/$file")
        done
    done < <(module_list)
}

@test "every repos line has exactly three pipe-separated fields" {
    while IFS= read -r m; do
        [[ -f $MODULES_DIR/$m/repos ]] || continue
        while IFS= read -r entry; do
            n=$(awk -F'|' '{print NF}' <<< "$entry")
            [ "$n" -eq 3 ] || { echo "$m/repos line has $n fields: $entry"; return 1; }
        done < <(manifest_read "$MODULES_DIR/$m/repos")
    done < <(module_list)
}

# @KEYRING@ and @CODENAME@ are runtime placeholders substituted by
# apt_add_repo (lib/apt.sh) and legitimately remain in committed repos
# files. UBUNTU_CODENAME is not one of this engine's placeholders — if it
# shows up, it is a leftover from authoring against the wrong token.
@test "no repos line still contains the codename placeholder" {
    ! grep -rq 'UBUNTU_CODENAME' "$MODULES_DIR"/*/repos 2>/dev/null
}

@test "every setup.sh is valid bash" {
    while IFS= read -r m; do
        [[ -f $MODULES_DIR/$m/setup.sh ]] || continue
        bash -n "$MODULES_DIR/$m/setup.sh" \
            || { echo "$m/setup.sh has a syntax error"; return 1; }
    done < <(module_list)
}

@test "every prompts.sh is valid bash" {
    while IFS= read -r m; do
        [[ -f $MODULES_DIR/$m/prompts.sh ]] || continue
        bash -n "$MODULES_DIR/$m/prompts.sh" \
            || { echo "$m/prompts.sh has a syntax error"; return 1; }
    done < <(module_list)
}

@test "a dry run of every module exits zero" {
    while IFS= read -r m; do
        run_status=0
        ( cd "$REPO_ROOT" && ./bootstrap.sh --dry-run --yes --only "$m" ) > /dev/null 2>&1 \
            || run_status=$?
        [ "$run_status" -eq 0 ] || { echo "dry run failed for $m (exit $run_status)"; return 1; }
    done < <(module_list)
}

# This is the test spec §8 calls out explicitly: a dry run must be provably
# inert outside the log transcript. Rather than check for the absence of
# one known path (weak — it would pass even if a dry run wrote fifty other
# files), this points the whole run at an isolated, empty $HOME via
# XDG_CACHE_HOME/HOME overrides and then diffs a full snapshot of that
# directory tree before and after. Anything surviving outside the cache
# directory, and outside the known-noise allowlist below, fails the test.
# This also means the test cannot touch the real machine's $HOME even if
# some code path is not actually dry-run-safe.
#
# Known noise: a handful of modules probe a real external tool's state
# before deciding whether to act (e.g. 10-shell runs `fish -c 'functions -q
# fisher'` to check whether fisher is installed; 30-dev runs
# `code --list-extensions`). Those probes are read-only from bootstrap's
# point of view — nothing is wrapped in `run`/`run_sudo`/`patch_*` there —
# but fish and VSCode both have their own first-launch side effects
# (history/state dirs, a machine id, an empty extensions.json) that are
# outside bootstrap's control and would exist on a real machine the first
# time those tools are ever invoked by *anything*, not just by this script.
# This allowlist exists so the test still catches a bootstrap-caused
# mutation (the property that actually matters) without being fragile to
# those tools' own init behavior.
_known_external_tool_noise() {
    case $1 in
        # The parent dirs themselves (.config, .local, .local/share) are
        # allowed too: mkdir -p brings them along as a side effect of
        # creating the tool-state dirs below, not as a mutation of their
        # own.
        .config | .local | .local/share \
            | .config/fish | .config/fish/* | .local/share/fish | .local/share/fish/* \
            | .config/Code | .config/Code/* | .vscode | .vscode/*)
            return 0
            ;;
    esac
    return 1
}

@test "a dry run creates no files outside the cache" {
    local fake_home
    fake_home=$(mktemp -d)
    local before
    before=$(find "$fake_home" -mindepth 1 | sort)
    ( cd "$REPO_ROOT" \
        && HOME="$fake_home" XDG_CACHE_HOME="$fake_home/.cache" \
           XDG_CONFIG_HOME="$fake_home/.config" \
           ./bootstrap.sh --dry-run --yes ) > /dev/null 2>&1

    local unexpected="" rel
    while IFS= read -r entry; do
        [[ -z $entry ]] && continue
        rel=${entry#"$fake_home"/}
        [[ $entry == "$fake_home/.cache"* ]] && continue
        _known_external_tool_noise "$rel" && continue
        unexpected="$unexpected $rel"
    done < <(find "$fake_home" -mindepth 1 | sort)

    rm -rf "$fake_home"
    [ "$before" = "" ]
    [ -z "$unexpected" ] || { echo "unexpected paths outside the cache: $unexpected"; return 1; }
}
