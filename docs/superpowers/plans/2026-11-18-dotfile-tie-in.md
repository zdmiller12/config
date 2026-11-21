# Dotfile Tie-In Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the repo a `dotfiles.sh` entry point that reports link state, links dotfiles, and adopts live files into the repo — and make `bootstrap.sh`'s linking purely additive so it can never replace a live config file.

**Architecture:** A new `link_state` function in `lib/link.sh` classifies each manifest entry into one of five states; the two callers then apply different *policies* to that classification. `link_manifest` (used by `bootstrap.sh` via the `10-shell` module) is additive — it links only destinations that do not exist, and skips everything else with a yellow, actionable warning. `dotfiles.sh` is the interactive path, where the user is present to resolve a conflict in either direction.

**Tech Stack:** Bash (targeting the bash shipped with Ubuntu 26.04), bats for unit tests, shellcheck v0.11.0 for lint. No new runtime dependencies: `cmp` and `diff` come from `diffutils`, which is Priority: required on Debian-family systems and present in the `ubuntu:26.04` base image.

**Spec:** `docs/superpowers/specs/2026-11-18-dotfile-tie-in-design.md`

## Global Constraints

- **`set -euo pipefail` is in force.** `bootstrap.sh` sets it, modules are sourced under it, and `dotfiles.sh` sets it too. The three rules below were verified empirically on bash 5.3.9, not recalled:
  - **Never write `(( counter++ ))`.** Post-increment returns the *old* value, so at `counter=0` the expression evaluates to 0, which `((` reports as exit status 1, which aborts the function **with no error message printed at all**. Use `counter=$(( counter + 1 ))`. (`(( ++counter ))` is safe from 0 but not from -1; don't rely on it.)
  - **`diff` and `cmp` exit 1 when the inputs differ** — which is exactly when you wanted them. Append `|| true` when you only want the output, or place the call in a condition context (`if`, `!`, `&&`).
  - **`cond && action` is safe as a standalone statement** — bash exempts a failing command that is not the last in an AND-OR list, and the list's own non-zero status does not re-trigger errexit. It is *not* safe as the **last statement of a function**: the function then returns 1 and the caller aborts. When a function's final statement is a conditional, add an explicit `return 0`.
- **bats' `run` is NOT available in this test suite.** `lib/log.sh:42` defines its own `run` — the dry-run command chokepoint — which *shadows* bats' `run` in every test file that calls `load_lib log`, which is all of them. `$status`, `$output`, and `$lines` are never populated, and the invoked command's non-zero return propagates as a test failure instead of being captured. Verified on bats 1.14.0: the failure trace names `lib/log.sh` line 48, not bats.
  - **Capture status and output with this repo's established idiom** (`tests/log.bats:50-58` is the precedent):

    ```bash
    status=0
    output="$(cmd_status 2>&1)" || status=$?
    [ "$status" -eq 1 ]
    [[ $output == *missing* ]]
    ```

  - For line-array assertions, use `mapfile -t lines < <(fn args)`.
  - Because `$( )` runs the function in a subshell, an errexit abort inside it *does* surface — as a non-zero captured status. So this idiom covers the abort class on its own. The direct-invocation tests each task specifies are a happy-path assertion, not the sole guard.
- **`run CMD ARG...` is the single chokepoint for anything that mutates the machine** and is dry-run aware. Per `lib/log.sh:41` it cannot carry pipes or redirections — for those, branch on `DRY_RUN` explicitly and emit `_log DRY '0;36' "..."` in the dry-run arm. `modules/10-shell/setup.sh:88` is the existing precedent for calling `_log DRY` directly.
- **Log levels carry the colors the spec asks for.** `log_warn` is ANSI `0;33` (yellow), `log_error` is `0;31`, `log_ok` is `0;32`, `log_info` is `0;34`, `log_step` is `1;37`. Use `log_warn` wherever the spec says "yellow". Defined at `lib/log.sh:34-38`.
- **Manifest line format** is `%-29s %s` — the repo-relative path left-padded to 29 columns, then a literal space, then the destination, putting the destination at column 31 to match all three existing entries in `dotfiles/links`. The explicit space is load-bearing: `%-30s%s` emits no separator once the path reaches 30 characters, and `link_manifest_entries` then rejects the line as having no destination. Destinations are written with a literal `~`, never an expanded `$HOME`.
- **Engine libraries self-default their globals** (`lib/log.sh:4-7`, `lib/ui.sh:5`), so `dotfiles.sh` can source `log`, `link`, and `ui` standalone with no bootstrap involvement.
- **Tests** live in `tests/*.bats`, `load helper`, and use `setup_tmpdir` / `teardown_tmpdir` / `load_lib <name>` from `tests/helper.bash`. Run a single file with `bats tests/link.bats`, everything with `bats tests/`.
- **Shellcheck must stay clean** at v0.11.0. Top-level scripts are linted together with the libraries they source: `shellcheck -x bootstrap.sh lib/*.sh`.
- **`run CMD` in production code is the dry-run chokepoint — never replace it with an output capture.** `lib/log.sh:42` checks `DRY_RUN` and returns *without executing*. Rewriting `run rm -f "$x"` as `output="$(rm -f "$x")"` still runs the command while silently bypassing the dry-run guard, which turns `--dry-run` into a destructive operation. The `status=0; output="$(fn 2>&1)" || status=$?` idiom is for TEST bodies capturing a function's output, and nowhere else. Every task's "changes nothing during a dry run" test exists to catch exactly this.
- **`link_manifest_entries`' stdout is a data channel, not a log.** Its consumers parse it with `IFS=$'\t' read -r rel dest`. Every diagnostic it emits must be redirected to stderr (`log_error "..." >&2`), because `log_error` prints to stdout by default (`lib/log.sh:24-28`) and an un-redirected message is read back as an entry whose whole text becomes a repo-relative path. Four consumers depend on this: `link_manifest`, `cmd_status`, `cmd_link`, and `dotfiles_manifest_append`.
- **Nothing personal is committed.** No task may add a hostname, username, email, or key path to a tracked file.

---

### Task 1: `link_state` — the shared classifier

**Files:**
- Modify: `lib/link.sh` (append after `link_file`, before `link_manifest`)
- Test: `tests/link.bats`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `link_state SRC DEST` — prints exactly one of `linked`, `missing`, `unlinked`, `diverged`, `broken` on stdout and returns 0. Every later task calls this; nothing else classifies.

- [ ] **Step 1: Write the failing tests**

Append to `tests/link.bats`:

```bash
@test "link_state reports broken when the repo file is missing" {
    [ "$(link_state "$TMPTEST/repo/absent.conf" "$TMPTEST/dest/file.conf")" = broken ]
}

@test "link_state reports broken even when the destination exists" {
    printf 'whatever\n' > "$TMPTEST/dest/file.conf"
    [ "$(link_state "$TMPTEST/repo/absent.conf" "$TMPTEST/dest/file.conf")" = broken ]
}

@test "link_state reports missing when the destination does not exist" {
    [ "$(link_state "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf")" = missing ]
}

@test "link_state reports linked for a symlink pointing at the repo file" {
    ln -s "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf"
    [ "$(link_state "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf")" = linked ]
}

@test "link_state reports unlinked for a real file with identical content" {
    printf 'source content\n' > "$TMPTEST/dest/file.conf"
    [ "$(link_state "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf")" = unlinked ]
}

@test "link_state reports diverged for a real file with different content" {
    printf 'user data\n' > "$TMPTEST/dest/file.conf"
    [ "$(link_state "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf")" = diverged ]
}

@test "link_state reports diverged for a dangling symlink" {
    ln -s "$TMPTEST/repo/absent.conf" "$TMPTEST/dest/file.conf"
    [ "$(link_state "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf")" = diverged ]
}

@test "link_state reports diverged when the destination is a directory" {
    mkdir -p "$TMPTEST/dest/file.conf"
    [ "$(link_state "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf")" = diverged ]
}

@test "link_state returns zero when called directly" {
    # Direct, un-wrapped invocation: asserts link_state returns 0, which the
    # output-comparison tests above do not check independently.
    link_state "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf" > /dev/null
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/link.bats`
Expected: the eight new tests FAIL with `link_state: command not found`. The pre-existing tests still pass.

- [ ] **Step 3: Implement `link_state`**

Insert into `lib/link.sh` after the `link_file` function and before the `# link_manifest MANIFEST REPO_ROOT` comment:

```bash
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/link.bats`
Expected: all tests PASS, including the pre-existing ones.

- [ ] **Step 5: Lint**

Run: `shellcheck -x bootstrap.sh lib/*.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add lib/link.sh tests/link.bats
git commit -m "Add link_state, the shared dotfile link classifier

Classification with no policy attached, so one implementation can serve
both an additive bootstrap and an interactive CLI.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: `link_manifest_entries` — one manifest parser

**Files:**
- Modify: `lib/link.sh` (add the function, then refactor `link_manifest` to use it)
- Test: `tests/link.bats`

**Interfaces:**
- Consumes: nothing.
- Produces: `link_manifest_entries MANIFEST` — prints one `REL<TAB>DEST` line per real entry, with a leading `~` in DEST already expanded to `$HOME`. Comments, blank lines, and a missing final newline are handled here and nowhere else. Tasks 5, 6, and 8 all read the manifest through this.

**Why:** `link_manifest` currently inlines the parsing. `status`, `link`, and `adopt` each need to walk the manifest too, and four copies of the comment/blank/no-trailing-newline handling is three copies too many.

- [ ] **Step 1: Write the failing tests**

Append to `tests/link.bats`:

```bash
@test "link_manifest_entries emits tab-separated entries and drops comments and blanks" {
    cat > links <<EOF
# a comment

file.conf    /tmp/one.conf
second.conf  /tmp/two.conf
EOF
    mapfile -t lines < <(link_manifest_entries links)
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "$(printf 'file.conf\t/tmp/one.conf')" ]
    [ "${lines[1]}" = "$(printf 'second.conf\t/tmp/two.conf')" ]
}

@test "link_manifest_entries expands a leading tilde" {
    HOME="$TMPTEST/fakehome"
    printf 'file.conf  ~/.config/app/file.conf\n' > links
    mapfile -t lines < <(link_manifest_entries links)
    [ "${lines[0]}" = "$(printf 'file.conf\t%s/.config/app/file.conf' "$TMPTEST/fakehome")" ]
}

@test "link_manifest_entries emits a final line with no trailing newline" {
    printf 'file.conf  /tmp/one.conf' > links
    mapfile -t lines < <(link_manifest_entries links)
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "$(printf 'file.conf\t/tmp/one.conf')" ]
}

@test "link_manifest_entries keeps a no-destination diagnostic out of the data stream" {
    printf 'orphan\nfile.conf  /tmp/one.conf\n' > links
    mapfile -t lines < <(link_manifest_entries links 2>/dev/null)
    [ "${#lines[@]}" -eq 1 ]
    [ "${lines[0]}" = "$(printf 'file.conf\t/tmp/one.conf')" ]
}

@test "link_manifest_entries reports a no-destination line on stderr" {
    printf 'orphan\nfile.conf  /tmp/one.conf\n' > links
    err="$(link_manifest_entries links 2>&1 > /dev/null)"
    [[ $err == *"manifest line has no destination: orphan"* ]]
}

@test "link_manifest does not build a phantom entry from a diagnostic" {
    # Regression for a real defect: log_error writes to stdout, so before the
    # >&2 redirect the error line was read back as an entry and link_file was
    # called with "$root/[ERROR] manifest line has no destination: orphan".
    printf 'orphan\nfile.conf  %s/dest/one.conf\n' "$TMPTEST" > links
    status=0
    output="$(link_manifest links "$TMPTEST/repo" 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ -L "$TMPTEST/dest/one.conf" ]
    # The load-bearing assertion. The phantom rel is embedded INSIDE the second
    # message ("link source does not exist: $root/[ERROR] manifest line has no
    # destination: orphan"), so matching on "repo/[ERROR]" is what actually
    # fires on regression. An assertion ordered the other way round would be
    # true whether the bug is present or not.
    [[ $output != *"repo/[ERROR]"* ]]
}

@test "link_manifest_entries returns zero when called directly" {
    # Direct invocation: asserts the parser returns 0, which the mapfile tests
    # above cannot check (process substitution does not expose the producer's
    # status to $?). Uses the comment/blank/multi-entry manifest so the status
    # of that path is covered, not just a single valid line.
    cat > links <<EOF
# a comment

file.conf    /tmp/one.conf
second.conf  /tmp/two.conf
EOF
    link_manifest_entries links > /dev/null
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/link.bats`
Expected: the four new tests FAIL with `link_manifest_entries: command not found`.

- [ ] **Step 3: Implement the parser and refactor `link_manifest` onto it**

Insert before `link_manifest` in `lib/link.sh`:

```bash
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
```

Then replace the body of `link_manifest` so it consumes the parser. Keep its signature and behavior identical for now — Task 3 changes the policy:

```bash
# link_manifest MANIFEST REPO_ROOT
link_manifest() {
    local manifest=$1 root=$2
    local rel dest
    while IFS=$'\t' read -r rel dest; do
        link_file "$root/$rel" "$dest" || true
    done < <(link_manifest_entries "$manifest")
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/link.bats`
Expected: all tests PASS. The pre-existing `link_manifest` tests are the regression check that the refactor preserved behavior — pay attention to "handles final line without trailing newline" and "expands a leading tilde in the destination".

- [ ] **Step 5: Lint**

Run: `shellcheck -x bootstrap.sh lib/*.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add lib/link.sh tests/link.bats
git commit -m "Extract link_manifest_entries as the one manifest parser

status, link, and adopt all need to walk the manifest; the comment,
blank-line, and missing-final-newline handling should exist once.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Make `link_manifest` additive, with actionable feedback

**Files:**
- Modify: `lib/link.sh` (`link_manifest`, plus a new `link_warn_skip` and a new `LINK_SKIPPED` global)
- Modify: `modules/10-shell/setup.sh:11`
- Test: `tests/link.bats`

**Interfaces:**
- Consumes: `link_state` (Task 1), `link_manifest_entries` (Task 2).
- Produces:
  - `LINK_SKIPPED` — integer global, reset at the top of every `link_manifest` call, holding the number of entries skipped by the last call.
  - `link_warn_skip DEST` — prints the three-line yellow warning naming both resolution commands.
  - `link_manifest MANIFEST REPO_ROOT` — same signature, now additive, always returns 0.

**Why this is the heart of the change:** today `link_file` backs a divergent destination up to `$dest.bak-$RUN_STAMP` and replaces it, with nothing reported. After this task `bootstrap.sh` cannot replace a live file at all. `link_file` keeps its backup behavior untouched, because Task 6's `--force` path depends on it.

- [ ] **Step 1: Write the failing tests**

Append to `tests/link.bats`:

```bash
@test "link_manifest links a missing destination" {
    printf 'file.conf  %s/dest/one.conf\n' "$TMPTEST" > links
    link_manifest links "$TMPTEST/repo"
    [ -L "$TMPTEST/dest/one.conf" ]
    [ "$LINK_SKIPPED" -eq 0 ]
}

@test "link_manifest leaves a divergent destination byte-for-byte alone" {
    printf 'user data\n' > "$TMPTEST/dest/one.conf"
    printf 'file.conf  %s/dest/one.conf\n' "$TMPTEST" > links
    link_manifest links "$TMPTEST/repo"
    [ ! -L "$TMPTEST/dest/one.conf" ]
    [ "$(cat "$TMPTEST/dest/one.conf")" = "user data" ]
    [ "$LINK_SKIPPED" -eq 1 ]
}

@test "link_manifest skips an identical destination rather than converting it" {
    printf 'source content\n' > "$TMPTEST/dest/one.conf"
    printf 'file.conf  %s/dest/one.conf\n' "$TMPTEST" > links
    link_manifest links "$TMPTEST/repo"
    [ ! -L "$TMPTEST/dest/one.conf" ]
    [ "$LINK_SKIPPED" -eq 1 ]
}

@test "link_manifest never creates a backup file" {
    printf 'user data\n' > "$TMPTEST/dest/one.conf"
    printf 'file.conf  %s/dest/one.conf\n' "$TMPTEST" > links
    link_manifest links "$TMPTEST/repo"
    [ -z "$(find "$TMPTEST/dest" -name '*.bak-*' -print -quit)" ]
}

@test "link_manifest returns zero even when it skipped entries" {
    printf 'user data\n' > "$TMPTEST/dest/one.conf"
    printf 'file.conf  %s/dest/one.conf\n' "$TMPTEST" > links
    status=0
    link_manifest links "$TMPTEST/repo" || status=$?
    [ "$status" -eq 0 ]
}

@test "link_manifest skip warning names both resolution commands" {
    HOME="$TMPTEST/fakehome"
    mkdir -p "$HOME"
    printf 'user data\n' > "$HOME/.one.conf"
    printf 'file.conf  ~/.one.conf\n' > links
    status=0
    output="$(link_manifest links "$TMPTEST/repo" 2>&1)" || status=$?
    [[ $output == *"not linked: a file already exists at ~/.one.conf"* ]]
    [[ $output == *"./dotfiles.sh adopt ~/.one.conf"* ]]
    [[ $output == *"./dotfiles.sh link --force ~/.one.conf"* ]]
}

@test "link_manifest reports a broken manifest entry without failing" {
    printf 'absent.conf  %s/dest/one.conf\n' "$TMPTEST" > links
    status=0
    output="$(link_manifest links "$TMPTEST/repo" 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [[ $output == *"absent.conf"* ]]
    [ ! -e "$TMPTEST/dest/one.conf" ]
    # Discriminates correct `broken` routing from a regression that misroutes
    # it into the `missing` arm. That arm calls link_file, which would emit
    # its own "link source does not exist" message (swallowed by `|| true`),
    # and every assertion above would still pass.
    [[ $output != *"link source does not exist"* ]]
}

@test "link_manifest reports a missing manifest rather than looking like a clean run" {
    # The guard this covers is the highest-value defensive line in the
    # function: the process substitution opens the manifest in a subshell, so
    # without it an unreadable path yields zero iterations, no diagnostic, and
    # a successful return -- indistinguishable from a converged machine.
    status=0
    output="$(link_manifest "$TMPTEST/nonexistent-manifest" "$TMPTEST/repo" 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [[ $output == *"no dotfile manifest at"* ]]
    [[ $output == *"nonexistent-manifest"* ]]
    # Direct call: the capture above runs in a subshell, so LINK_SKIPPED set
    # inside it is not observable here.
    link_manifest "$TMPTEST/nonexistent-manifest" "$TMPTEST/repo" > /dev/null 2>&1
    [ "$LINK_SKIPPED" -eq 0 ]
}

@test "link_manifest counts skips fresh on each call" {
    printf 'user data\n' > "$TMPTEST/dest/one.conf"
    printf 'file.conf  %s/dest/one.conf\n' "$TMPTEST" > links
    link_manifest links "$TMPTEST/repo"
    [ "$LINK_SKIPPED" -eq 1 ]
    rm -f "$TMPTEST/dest/one.conf"
    link_manifest links "$TMPTEST/repo"
    [ "$LINK_SKIPPED" -eq 0 ]
}
```

Delete the now-contradicted test `link_manifest links every entry and skips comments and blanks` only if it fails — it uses destinations under `$TMPTEST/dest/` that do not exist, so it should still pass unchanged. Verify rather than assume.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/link.bats`
Expected: the new tests FAIL — `LINK_SKIPPED: unbound variable` and the divergent-destination tests failing because the current code links and backs up.

- [ ] **Step 3: Implement the additive policy**

In `lib/link.sh`, add the global beside the existing `LINK_RESULT` declaration near the top:

```bash
# shellcheck disable=SC2034
LINK_RESULT=unchanged
# Number of entries the last link_manifest call declined to touch. Read by
# the 10-shell module to raise a single end-of-run follow-up note.
LINK_SKIPPED=0
```

Add `link_warn_skip` after `link_state`:

```bash
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
```

Replace `link_manifest` wholesale:

```bash
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/link.bats`
Expected: all tests PASS, including `link_file backs up a pre-existing regular file` — `link_file` must be unchanged.

- [ ] **Step 5: Raise the follow-up note from the module**

Replace `modules/10-shell/setup.sh:11` (the single `link_manifest` call) with:

```bash
link_manifest "${DOTFILES_DIR:-}/links" "${DOTFILES_DIR:-}"
# A skip is not a failure: linking is additive, so a destination that already
# has a file is left alone and reported. Surface the count once at the end of
# the run too, since the per-file warnings scroll past.
if (( LINK_SKIPPED )); then
    summary_note "$LINK_SKIPPED dotfile(s) were not linked; run ./dotfiles.sh status to see why and resolve each one."
fi
```

- [ ] **Step 6: Run the full suite and lint**

Run: `bats tests/ && shellcheck -x bootstrap.sh lib/*.sh && for f in modules/*/setup.sh modules/*/prompts.sh; do shellcheck -x -e SC1091 "$f"; done`
Expected: all tests PASS, no shellcheck output. `tests/modules.bats` dry-runs every module, so it is the check that the `10-shell` edit did not break module execution.

- [ ] **Step 7: Commit**

```bash
git add lib/link.sh modules/10-shell/setup.sh tests/link.bats
git commit -m "Make bootstrap dotfile linking purely additive

Previously a pre-existing ~/.gitconfig was copied to a .bak- file and
replaced, with nothing reported. Now the live file is left exactly where
it is, and the run says so in yellow -- twice -- naming both the adopt
and link --force commands that resolve it.

link_file keeps its backup behavior; dotfiles.sh --force depends on it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: `dotfiles.sh` skeleton — arguments, help, dispatch

**Files:**
- Create: `dotfiles.sh` (mode 0755)
- Create: `tests/dotfiles.bats`
- Modify: `.github/workflows/ci.yml` (the shellcheck invocation)

**Interfaces:**
- Consumes: nothing yet.
- Produces: the globals and helpers every later task builds on —
  - `REPO_ROOT`, `DOTFILES_DIR`, `MANIFEST` — absolute paths.
  - `DRY_RUN`, `ASSUME_YES`, `LINK_FORCE`, `SUBCOMMAND`, `TARGETS` (array).
  - `parse_args "$@"` — returns 0 on success, 2 on a usage error, 10 after printing help.
  - `dotfiles_tildify PATH` — prints PATH with `$HOME` replaced by `~`.
  - `DOTFILES_NO_MAIN` — when set, sourcing the script defines its functions without running `main`. Mirrors `BOOTSTRAP_NO_MAIN` (`tests/bootstrap.bats:6`).
  - `cmd_status`, `cmd_link`, `cmd_adopt` — stubs here, implemented in Tasks 5, 6, 8.

- [ ] **Step 1: Write the failing tests**

Create `tests/dotfiles.bats`:

```bash
#!/usr/bin/env bats

load helper

setup() {
    setup_tmpdir
    DOTFILES_NO_MAIN=1
    export DOTFILES_NO_MAIN
    load_lib log
    load_lib link
    load_lib ui
    RUN_STAMP="test"
    # shellcheck disable=SC1090
    source "$REPO_ROOT/dotfiles.sh"
    DRY_RUN=0
    ASSUME_YES=0
    LINK_FORCE=0
    SUBCOMMAND=status
    TARGETS=()
    # Point the CLI at a scratch repo so no test can touch the real
    # dotfiles/ tree or the real $HOME.
    DOTFILES_DIR="$TMPTEST/dotfiles"
    MANIFEST="$DOTFILES_DIR/links"
    HOME="$TMPTEST/fakehome"
    mkdir -p "$DOTFILES_DIR" "$HOME"
    : > "$MANIFEST"
}
teardown() { teardown_tmpdir; }

@test "parse_args defaults to status with no arguments" {
    parse_args
    [ "$SUBCOMMAND" = status ]
    [ "$DRY_RUN" -eq 0 ]
    [ "$LINK_FORCE" -eq 0 ]
    [ "${#TARGETS[@]}" -eq 0 ]
}

@test "parse_args accepts each subcommand" {
    parse_args status
    [ "$SUBCOMMAND" = status ]
    parse_args link
    [ "$SUBCOMMAND" = link ]
    parse_args adopt
    [ "$SUBCOMMAND" = adopt ]
}

@test "parse_args rejects an unknown subcommand" {
    status=0
    parse_args bogus || status=$?
    [ "$status" -eq 2 ]
}

@test "parse_args rejects an unknown option" {
    status=0
    parse_args link --nope || status=$?
    [ "$status" -eq 2 ]
}

@test "parse_args collects flags and targets" {
    parse_args link --force --dry-run "$HOME/.one.conf"
    [ "$SUBCOMMAND" = link ]
    [ "$LINK_FORCE" -eq 1 ]
    [ "$DRY_RUN" -eq 1 ]
    [ "${TARGETS[0]}" = "$HOME/.one.conf" ]
}

@test "parse_args returns 10 for help" {
    status=0
    parse_args --help || status=$?
    [ "$status" -eq 10 ]
}

@test "usage names every subcommand" {
    status=0
    output="$(usage 2>&1)" || status=$?
    [[ $output == *status* ]]
    [[ $output == *link* ]]
    [[ $output == *adopt* ]]
}

@test "dotfiles_tildify abbreviates a path under HOME" {
    [ "$(dotfiles_tildify "$HOME/.one.conf")" = "~/.one.conf" ]
}

@test "dotfiles_tildify leaves a path outside HOME alone" {
    [ "$(dotfiles_tildify /etc/hosts)" = "/etc/hosts" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/dotfiles.bats`
Expected: every test FAILS — `dotfiles.sh` does not exist, so the `source` in `setup` errors.

- [ ] **Step 3: Create `dotfiles.sh`**

```bash
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
```

- [ ] **Step 4: Make it executable and run the tests**

```bash
chmod +x dotfiles.sh
bats tests/dotfiles.bats
```
Expected: all tests PASS.

- [ ] **Step 5: Confirm the real entry point runs**

Run: `./dotfiles.sh --help`
Expected: the usage text, exit status 0.

Run: `./dotfiles.sh bogus; echo "exit=$?"`
Expected: `Unknown subcommand: bogus`, the usage text on stderr, `exit=2`.

- [ ] **Step 6: Add `dotfiles.sh` to the lint job**

In `.github/workflows/ci.yml`, change the single line

```
          shellcheck -x bootstrap.sh lib/*.sh
```

to

```
          shellcheck -x bootstrap.sh dotfiles.sh lib/*.sh
```

Leave the surrounding comment alone — it explains why the top-level scripts and `lib/` are analysed as one set, which now covers `dotfiles.sh` too.

- [ ] **Step 7: Lint**

Run: `shellcheck -x bootstrap.sh dotfiles.sh lib/*.sh`
Expected: no output.

- [ ] **Step 8: Commit**

```bash
git add dotfiles.sh tests/dotfiles.bats .github/workflows/ci.yml
git commit -m "Add the dotfiles.sh entry point: arguments, help, dispatch

Subcommand stubs only; status, link, and adopt land next. Sources
log/link/ui, which self-default their globals, so no bootstrap.sh
involvement is needed.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: `status`

**Files:**
- Modify: `dotfiles.sh` (replace the `cmd_status` stub, add `cmd_status_untracked`)
- Test: `tests/dotfiles.bats`

**Interfaces:**
- Consumes: `link_state` (Task 1), `link_manifest_entries` (Task 2), `dotfiles_tildify` (Task 4).
- Produces: `cmd_status` — returns 0 when every entry is `linked`, 1 when any entry is `missing`, `unlinked`, `diverged`, or `broken`. Non-zero means "something would change", which makes it usable from a hook later.

- [ ] **Step 1: Write the failing tests**

Append to `tests/dotfiles.bats`:

```bash
@test "status reports linked and exits zero when everything is linked" {
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    ln -s "$DOTFILES_DIR/one.conf" "$HOME/.one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_status 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [[ $output == *linked* ]]
    [[ $output == *"~/.one.conf"* ]]
}

@test "status reports missing and exits non-zero" {
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_status 2>&1)" || status=$?
    [ "$status" -eq 1 ]
    [[ $output == *missing* ]]
}

@test "status reports unlinked for an identical real file" {
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    printf 'content\n' > "$HOME/.one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_status 2>&1)" || status=$?
    [ "$status" -eq 1 ]
    [[ $output == *unlinked* ]]
}

@test "status reports DIVERGED for a differing real file" {
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    printf 'other\n' > "$HOME/.one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_status 2>&1)" || status=$?
    [ "$status" -eq 1 ]
    [[ $output == *DIVERGED* ]]
}

@test "status reports BROKEN for a manifest entry with no repo file" {
    printf 'absent.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_status 2>&1)" || status=$?
    [ "$status" -eq 1 ]
    [[ $output == *BROKEN* ]]
}

@test "status lists repo files no manifest entry references" {
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    ln -s "$DOTFILES_DIR/one.conf" "$HOME/.one.conf"
    mkdir -p "$DOTFILES_DIR/ssh"
    printf 'template\n' > "$DOTFILES_DIR/ssh/config.template"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_status 2>&1)" || status=$?
    [[ $output == *"ssh/config.template"* ]]
}

@test "status untracked files do not affect the exit status" {
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    ln -s "$DOTFILES_DIR/one.conf" "$HOME/.one.conf"
    printf 'orphan\n' > "$DOTFILES_DIR/orphan.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_status 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [[ $output == *orphan.conf* ]]
}

@test "status does not list the manifest itself as untracked" {
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    ln -s "$DOTFILES_DIR/one.conf" "$HOME/.one.conf"
    # Seed a genuine orphan so the untracked section is guaranteed non-empty.
    # Without this the negative assertion below passes even against a stub
    # that prints nothing at all, which is how it slipped through red->green.
    printf 'orphan\n' > "$DOTFILES_DIR/orphan.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_status 2>&1)" || status=$?
    [[ $output == *"orphan.conf"* ]]
    [[ $output != *"  links"* ]]
}

@test "status completes when called directly on a fully linked manifest" {
    # Direct invocation on the all-linked case, the only state returning 0.
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    ln -s "$DOTFILES_DIR/one.conf" "$HOME/.one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    cmd_status > /dev/null
}

@test "status completes when called directly with an unreferenced repo file" {
    # Exercises cmd_status_untracked's find/compare loop with a repo file that
    # no manifest entry names. (The empty-`referenced` case is a different
    # scenario — this manifest has an entry — and is covered by the
    # "${referenced[@]:-}" guard rather than by this test.)
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    ln -s "$DOTFILES_DIR/one.conf" "$HOME/.one.conf"
    printf 'orphan\n' > "$DOTFILES_DIR/orphan.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    cmd_status > /dev/null
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/dotfiles.bats`
Expected: the eight new tests FAIL with `cmd_status is not implemented yet`.

- [ ] **Step 3: Implement `cmd_status`**

Replace the `cmd_status` stub in `dotfiles.sh`:

```bash
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/dotfiles.bats`
Expected: all tests PASS.

- [ ] **Step 5: Run it against the real repo**

Run: `./dotfiles.sh status; echo "exit=$?"`
Expected: three manifest entries reported; `fish/functions/winboot.fish` and `ssh/config.template` listed under the untracked heading. The exit status depends on this machine's actual state — record what it was, because it tells you whether the live dotfiles are currently linked.

- [ ] **Step 6: Lint and commit**

```bash
shellcheck -x bootstrap.sh dotfiles.sh lib/*.sh
git add dotfiles.sh tests/dotfiles.bats
git commit -m "Add dotfiles.sh status

One line per manifest entry plus an informational audit of repo files no
manifest entry references -- which is how winboot.fish and
ssh/config.template become visible without being treated as errors.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: `link`

**Files:**
- Modify: `dotfiles.sh` (replace the `cmd_link` stub, add `dotfiles_target_matches`)
- Test: `tests/dotfiles.bats`

**Interfaces:**
- Consumes: `link_state`, `link_manifest_entries`, `link_file`, `link_warn_skip`, `dotfiles_tildify`.
- Produces:
  - `dotfiles_target_matches DEST REL` — returns 0 if any entry in `TARGETS` names this manifest entry, by destination (with `~` expanded) or by repo-relative path.
  - `cmd_link` — returns 0 on success, 1 if any entry refused or was broken, 2 if a `TARGETS` entry matched nothing.

- [ ] **Step 1: Write the failing tests**

Append to `tests/dotfiles.bats`:

```bash
@test "link creates a symlink for a missing destination" {
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_link 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ -L "$HOME/.one.conf" ]
}

@test "link converts an identical real file without a backup" {
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    printf 'content\n' > "$HOME/.one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_link 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ -L "$HOME/.one.conf" ]
    [ -z "$(find "$HOME" -name '*.bak-*' -print -quit)" ]
}

@test "link refuses a divergent file and leaves both sides untouched" {
    printf 'repo\n' > "$DOTFILES_DIR/one.conf"
    printf 'live\n' > "$HOME/.one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_link 2>&1)" || status=$?
    [ "$status" -eq 1 ]
    [ ! -L "$HOME/.one.conf" ]
    [ "$(cat "$HOME/.one.conf")" = live ]
    [ "$(cat "$DOTFILES_DIR/one.conf")" = repo ]
}

@test "link prints a diff for a divergent file" {
    printf 'repo\n' > "$DOTFILES_DIR/one.conf"
    printf 'live\n' > "$HOME/.one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_link 2>&1)" || status=$?
    [[ $output == *"-repo"* ]]
    [[ $output == *"+live"* ]]
}

@test "link --force backs up the live file and logs the backup path" {
    printf 'repo\n' > "$DOTFILES_DIR/one.conf"
    printf 'live\n' > "$HOME/.one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    LINK_FORCE=1
    status=0
    output="$(cmd_link 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ -L "$HOME/.one.conf" ]
    [ "$(cat "$HOME/.one.conf.bak-test")" = live ]
    [[ $output == *".bak-test"* ]]
}

@test "link is a no-op on an already linked entry" {
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    ln -s "$DOTFILES_DIR/one.conf" "$HOME/.one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_link 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [[ $output == *"already linked"* ]]
}

@test "link scoped to a destination leaves other entries alone" {
    printf 'one\n' > "$DOTFILES_DIR/one.conf"
    printf 'two\n' > "$DOTFILES_DIR/two.conf"
    printf 'one.conf  ~/.one.conf\ntwo.conf  ~/.two.conf\n' > "$MANIFEST"
    TARGETS=("$HOME/.one.conf")
    status=0
    output="$(cmd_link 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ -L "$HOME/.one.conf" ]
    [ ! -e "$HOME/.two.conf" ]
}

@test "link scoped by repo-relative path also matches" {
    printf 'one\n' > "$DOTFILES_DIR/one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    TARGETS=("one.conf")
    status=0
    output="$(cmd_link 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ -L "$HOME/.one.conf" ]
}

@test "link errors when a target matches no manifest entry" {
    printf 'one\n' > "$DOTFILES_DIR/one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    TARGETS=("$HOME/.typo.conf")
    status=0
    output="$(cmd_link 2>&1)" || status=$?
    [ "$status" -eq 2 ]
    [[ $output == *".typo.conf"* ]]
}

@test "link reports a broken manifest entry and exits non-zero" {
    printf 'absent.conf  ~/.one.conf\n' > "$MANIFEST"
    status=0
    output="$(cmd_link 2>&1)" || status=$?
    [ "$status" -eq 1 ]
    [ ! -e "$HOME/.one.conf" ]
}

@test "link changes nothing during a dry run" {
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    DRY_RUN=1
    status=0
    output="$(cmd_link 2>&1)" || status=$?
    [ ! -e "$HOME/.one.conf" ]
}

@test "link makes no removal in the unlinked path during a dry run" {
    # The unlinked arm is the only place cmd_link REMOVES anything (it clears
    # the destination before relinking so link_file writes no pointless .bak-
    # copy). That removal goes through the `run` wrapper, so a dry run must
    # leave the identical live file exactly where it is. The other dry-run
    # test covers `missing`, where nothing is removed — so without this one, a
    # future edit swapping `run rm -f` for a bare `rm` would pass the suite.
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    printf 'content\n' > "$HOME/.one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    DRY_RUN=1
    status=0
    output="$(cmd_link 2>&1)" || status=$?
    [ -f "$HOME/.one.conf" ]
    [ ! -L "$HOME/.one.conf" ]
    [ "$(cat "$HOME/.one.conf")" = content ]
}

@test "link completes when called directly" {
    # Direct invocation of the unscoped, link-everything path, which
    # exercises the empty-TARGETS array read under set -u.
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    TARGETS=()
    cmd_link > /dev/null
    [ -L "$HOME/.one.conf" ]
}

@test "link completes when called directly with a scoped target" {
    # The scoped path has its own array loops (matched, TARGETS) and its own
    # post-loop verification pass; both need a direct invocation.
    printf 'content\n' > "$DOTFILES_DIR/one.conf"
    printf 'one.conf  ~/.one.conf\n' > "$MANIFEST"
    TARGETS=("$HOME/.one.conf")
    cmd_link > /dev/null
    [ -L "$HOME/.one.conf" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/dotfiles.bats`
Expected: the eleven new tests FAIL with `cmd_link is not implemented yet`.

- [ ] **Step 3: Remove the now-obsolete lint suppression**

`cmd_link` is the reader `LINK_FORCE` has been waiting for, so Task 4's
temporary directive must go. In `parse_args`, collapse the `--force` arm back
to its one-line form and delete both the `# shellcheck disable=SC2034` and the
comment explaining it:

```bash
            --force) LINK_FORCE=1 ;;
```

Then confirm `shellcheck -x bootstrap.sh dotfiles.sh lib/*.sh` is still clean.
If SC2034 fires again, `cmd_link` is not actually reading `LINK_FORCE` and the
implementation is wrong — do not re-add the directive to silence it.

- [ ] **Step 4: Implement `cmd_link`**

Replace the `cmd_link` stub in `dotfiles.sh`:

```bash
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/dotfiles.bats`
Expected: all tests PASS.

- [ ] **Step 5: Exercise it against the real repo, without mutating anything**

Run: `./dotfiles.sh link --dry-run`
Expected: either `already linked` for all three entries, or `DRY` lines describing the symlinks it would create. Nothing changes on disk — confirm with `./dotfiles.sh status` reporting the same states as before.

- [ ] **Step 6: Lint and commit**

```bash
shellcheck -x bootstrap.sh dotfiles.sh lib/*.sh
git add dotfiles.sh tests/dotfiles.bats
git commit -m "Add dotfiles.sh link

Converts identical files without a pointless backup, refuses divergent
ones with a diff, and takes optional paths so --force can resolve a
single file. Erroring on a target that matches nothing keeps a typo from
looking like success.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: `adopt` path inference

**Files:**
- Modify: `dotfiles.sh` (add `dotfiles_infer_repo_path`)
- Test: `tests/dotfiles.bats`

**Interfaces:**
- Consumes: nothing.
- Produces: `dotfiles_infer_repo_path LIVE_PATH` — prints a repo-relative path. Task 8 uses it as the editable default in the confirmation prompt.

**Why this is its own task:** no rule gets this right every time. The existing manifest holds two incompatible precedents — `~/.config/fish/functions/usd.fish` → `fish/functions/usd.fish` strips the `~/.config/` prefix, while `~/.gitconfig` → `git/gitconfig` strips the dot *and* invents a `git/` grouping no rule can derive. The inference is therefore a best effort that Task 8 always shows for confirmation, never applies blind.

- [ ] **Step 1: Write the failing tests**

Append to `tests/dotfiles.bats`:

```bash
@test "infer strips the ~/.config prefix" {
    [ "$(dotfiles_infer_repo_path "$HOME/.config/fish/functions/usd.fish")" = "fish/functions/usd.fish" ]
}

@test "infer groups a dotfile with an extension under its stem" {
    [ "$(dotfiles_infer_repo_path "$HOME/.tmux.conf")" = "tmux/tmux.conf" ]
}

@test "infer puts an extensionless dotfile at the top level" {
    [ "$(dotfiles_infer_repo_path "$HOME/.gitconfig")" = "gitconfig" ]
    [ "$(dotfiles_infer_repo_path "$HOME/.bashrc")" = "bashrc" ]
}

@test "infer handles a path outside HOME" {
    [ "$(dotfiles_infer_repo_path /etc/someapp.conf)" = "someapp/someapp.conf" ]
}

@test "infer handles a non-dot file under HOME" {
    [ "$(dotfiles_infer_repo_path "$HOME/notes.txt")" = "notes/notes.txt" ]
}

@test "infer returns zero when called directly" {
    # Direct invocations: assert the function returns 0 for each rule branch.
    dotfiles_infer_repo_path "$HOME/.config/fish/config.fish" > /dev/null
    dotfiles_infer_repo_path "$HOME/.tmux.conf" > /dev/null
    dotfiles_infer_repo_path "$HOME/.gitconfig" > /dev/null
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/dotfiles.bats`
Expected: the five new tests FAIL with `dotfiles_infer_repo_path: command not found`.

- [ ] **Step 3: Implement the inference**

Add to `dotfiles.sh`, after `dotfiles_tildify`:

```bash
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/dotfiles.bats`
Expected: all tests PASS.

- [ ] **Step 5: Lint and commit**

```bash
shellcheck -x bootstrap.sh dotfiles.sh lib/*.sh
git add dotfiles.sh tests/dotfiles.bats
git commit -m "Add adopt's live-path to repo-path inference

A best effort that adopt shows for confirmation rather than applying.
The manifest's own entries disagree about the convention, so the comment
records why no rule can satisfy both.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: `adopt`

**Files:**
- Modify: `dotfiles.sh` (replace the `cmd_adopt` stub, add `dotfiles_is_dirty` and `dotfiles_manifest_append`)
- Test: `tests/dotfiles.bats`

**Interfaces:**
- Consumes: `dotfiles_infer_repo_path` (Task 7), `dotfiles_tildify`, `link_file`, `link_manifest_entries`, `ui_prompt` (`lib/ui.sh:79`).
- Produces:
  - `dotfiles_is_dirty REPO_PATH` — returns 0 if git reports any staged, unstaged, or untracked change for that path; 1 otherwise, including when `$REPO_ROOT` is not a git repository.
  - `dotfiles_manifest_append REL DEST` — appends one `%-30s%s` line with `~` in the destination, unless `REL` is already listed.
  - `cmd_adopt` — returns 0 on success, 1 on a refused or failed adopt, 2 on a usage error.

**Note on `ui_prompt`:** it returns early if the named variable is already non-empty, and it `export`s the variable. Clear `DOTFILES_REPO_REL` immediately before each call. With no TTY — which is every test and every CI run — it takes the default, so the inference is what tests observe.

- [ ] **Step 1: Write the failing tests**

Append to `tests/dotfiles.bats`:

```bash
@test "adopt moves a new file into the repo, links it, and records it" {
    printf 'live content\n' > "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "one/one.conf")
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ -L "$HOME/.one.conf" ]
    [ "$(cat "$DOTFILES_DIR/one/one.conf")" = "live content" ]
    [ "$(cat "$HOME/.one.conf")" = "live content" ]
    # Assert the parsed entry, not two substrings. `grep -q` on each field
    # separately would pass even with no separator between them, which is
    # exactly the corruption this file is prone to.
    mapfile -t entries < <(link_manifest_entries "$MANIFEST" 2>/dev/null)
    [ "${#entries[@]}" -eq 1 ]
    [ "${entries[0]}" = "$(printf 'one/one.conf\t%s/.one.conf' "$HOME")" ]
}

@test "adopt appends the manifest entry with the repo's column alignment" {
    printf 'live\n' > "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "one/one.conf")
    cmd_adopt
    status=0
    output="$(grep 'one/one.conf' "$MANIFEST" 2>&1)" || status=$?
    [ "$output" = "$(printf '%-29s %s' 'one/one.conf' '~/.one.conf')" ]
}

@test "adopt keeps a long repo path parseable in the manifest" {
    # Regression: %-30s%s emits NO separator once the path reaches 30 chars,
    # so the entry parses as having no destination and the adopted file
    # silently stops being linked. 38 chars here.
    printf 'live\n' > "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "fish/functions/a-rather-long-name.fish")
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    mapfile -t entries < <(link_manifest_entries "$MANIFEST" 2>/dev/null)
    [ "${#entries[@]}" -eq 1 ]
    [ "${entries[0]}" = "$(printf 'fish/functions/a-rather-long-name.fish\t%s/.one.conf' "$HOME")" ]
}

@test "adopt writes a tilde rather than an expanded HOME" {
    printf 'live\n' > "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "one/one.conf")
    cmd_adopt
    ! grep -q "$HOME" "$MANIFEST"
}

@test "adopt is idempotent on an already adopted file" {
    printf 'live\n' > "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "one/one.conf")
    cmd_adopt
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [[ $output == *"already linked"* ]]
    [ "$(grep -c 'one/one.conf' "$MANIFEST")" -eq 1 ]
}

@test "adopt overwrites a differing repo file so local wins" {
    # git init so dotfiles_is_dirty takes its real "git repo, path clean"
    # path rather than the "not a git repo at all" early return. Both answer
    # "not dirty", so without this the clean-path branch is never exercised.
    git init -q "$TMPTEST/gitrepo"
    REPO_ROOT="$TMPTEST/gitrepo"
    DOTFILES_DIR="$REPO_ROOT/dotfiles"
    MANIFEST="$DOTFILES_DIR/links"
    mkdir -p "$DOTFILES_DIR/one"
    printf 'repo\n' > "$DOTFILES_DIR/one/one.conf"
    : > "$MANIFEST"
    git -C "$REPO_ROOT" add -A
    git -C "$REPO_ROOT" -c user.email=t@example.com -c user.name=t commit -q -m init
    printf 'live\n' > "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "one/one.conf")
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ "$(cat "$DOTFILES_DIR/one/one.conf")" = live ]
    [ -L "$HOME/.one.conf" ]
}

@test "adopt links an identical repo file without touching its content" {
    mkdir -p "$DOTFILES_DIR/one"
    printf 'same\n' > "$DOTFILES_DIR/one/one.conf"
    printf 'same\n' > "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "one/one.conf")
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ "$(cat "$DOTFILES_DIR/one/one.conf")" = same ]
    [ -L "$HOME/.one.conf" ]
}

@test "adopt uses the inferred path when none is given" {
    printf 'live\n' > "$HOME/.tmux.conf"
    TARGETS=("$HOME/.tmux.conf")
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ -f "$DOTFILES_DIR/tmux/tmux.conf" ]
}

@test "adopt dereferences a live symlink so the repo gets real content" {
    # Guards against `cp -a`, which preserves the link and would commit a
    # symlink to an absolute path outside the repo. cmp cannot detect this
    # (it dereferences), so the assertion is on the file type directly.
    mkdir -p "$TMPTEST/elsewhere"
    printf 'external\n' > "$TMPTEST/elsewhere/real.conf"
    ln -s "$TMPTEST/elsewhere/real.conf" "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "one/one.conf")
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ ! -L "$DOTFILES_DIR/one/one.conf" ]
    [ -f "$DOTFILES_DIR/one/one.conf" ]
    [ "$(cat "$DOTFILES_DIR/one/one.conf")" = external ]
}

@test "adopt refuses a repo path that escapes dotfiles/" {
    printf 'live\n' > "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "../escaped.conf")
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 2 ]
    [ ! -e "$DOTFILES_DIR/../escaped.conf" ]
    # The live file must survive a refusal untouched.
    [ -f "$HOME/.one.conf" ]
    [ ! -L "$HOME/.one.conf" ]
}

@test "adopt trims a trailing slash from the repo path" {
    printf 'live\n' > "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "one/")
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    # Without the trim, cp would copy INTO dotfiles/one/ under the live
    # basename and the manifest would record "one/" as the entry.
    [ -f "$DOTFILES_DIR/one" ]
    [ ! -d "$DOTFILES_DIR/one" ]
    grep -q '^one  *~/\.one\.conf$' "$MANIFEST"
}

@test "adopt refuses every traversal form the guard lists" {
    # The guard's case has five arms; two were covered. A regression dropping
    # any single arm would otherwise go unnoticed, and this one is a guard
    # against writing outside the repo, so partial coverage is the wrong
    # trade. ".." bare, mid-path, and trailing are the three untested arms.
    printf 'live\n' > "$HOME/.one.conf"
    for bad in ".." "one/../../escaped.conf" "one/.."; do
        TARGETS=("$HOME/.one.conf" "$bad")
        status=0
        output="$(cmd_adopt 2>&1)" || status=$?
        [ "$status" -eq 2 ]
        [ -f "$HOME/.one.conf" ]
        [ ! -L "$HOME/.one.conf" ]
    done
    # A legitimate name merely containing ".." must still be accepted.
    TARGETS=("$HOME/.one.conf" "weird..name.conf")
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ -f "$DOTFILES_DIR/weird..name.conf" ]
}

@test "adopt refuses an absolute repo path" {
    printf 'live\n' > "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "$TMPTEST/escaped.conf")
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 2 ]
    [ ! -e "$TMPTEST/escaped.conf" ]
    [ -f "$HOME/.one.conf" ]
}

@test "adopt rejects a directory" {
    mkdir -p "$HOME/.somedir"
    TARGETS=("$HOME/.somedir")
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 2 ]
    [[ $output == *director* ]]
}

@test "adopt rejects a path that does not exist" {
    TARGETS=("$HOME/.absent.conf")
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 2 ]
}

@test "adopt requires a path" {
    TARGETS=()
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 2 ]
}

@test "adopt refuses when the repo file has uncommitted changes" {
    git init -q "$TMPTEST/gitrepo"
    REPO_ROOT="$TMPTEST/gitrepo"
    DOTFILES_DIR="$REPO_ROOT/dotfiles"
    MANIFEST="$DOTFILES_DIR/links"
    mkdir -p "$DOTFILES_DIR/one"
    printf 'committed\n' > "$DOTFILES_DIR/one/one.conf"
    : > "$MANIFEST"
    git -C "$REPO_ROOT" add -A
    git -C "$REPO_ROOT" -c user.email=t@example.com -c user.name=t commit -q -m init
    printf 'unreviewed repo edit\n' > "$DOTFILES_DIR/one/one.conf"
    printf 'live\n' > "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "one/one.conf")
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 1 ]
    [ "$(cat "$DOTFILES_DIR/one/one.conf")" = "unreviewed repo edit" ]
    [ "$(cat "$HOME/.one.conf")" = live ]
    [[ $output == *--force* ]]
}

@test "adopt --force overwrites an uncommitted repo file" {
    git init -q "$TMPTEST/gitrepo"
    REPO_ROOT="$TMPTEST/gitrepo"
    DOTFILES_DIR="$REPO_ROOT/dotfiles"
    MANIFEST="$DOTFILES_DIR/links"
    mkdir -p "$DOTFILES_DIR/one"
    printf 'committed\n' > "$DOTFILES_DIR/one/one.conf"
    : > "$MANIFEST"
    git -C "$REPO_ROOT" add -A
    git -C "$REPO_ROOT" -c user.email=t@example.com -c user.name=t commit -q -m init
    printf 'unreviewed repo edit\n' > "$DOTFILES_DIR/one/one.conf"
    printf 'live\n' > "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "one/one.conf")
    LINK_FORCE=1
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ "$(cat "$DOTFILES_DIR/one/one.conf")" = live ]
}

@test "adopt changes nothing during a dry run" {
    printf 'live\n' > "$HOME/.one.conf"
    TARGETS=("$HOME/.one.conf" "one/one.conf")
    DRY_RUN=1
    status=0
    output="$(cmd_adopt 2>&1)" || status=$?
    [ "$status" -eq 0 ]
    [ ! -e "$DOTFILES_DIR/one/one.conf" ]
    [ ! -L "$HOME/.one.conf" ]
    [ "$(cat "$HOME/.one.conf")" = live ]
    [ ! -s "$MANIFEST" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/dotfiles.bats`
Expected: the thirteen new tests FAIL with `cmd_adopt is not implemented yet`.

- [ ] **Step 3: Implement the helpers and `cmd_adopt`**

Add to `dotfiles.sh` before the `cmd_` functions:

```bash
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
```

Replace the `cmd_adopt` stub:

```bash
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/dotfiles.bats`
Expected: all tests PASS.

- [ ] **Step 5: Run the whole suite and lint**

Run: `bats tests/ && shellcheck -x bootstrap.sh dotfiles.sh lib/*.sh`
Expected: all tests PASS, no shellcheck output.

- [ ] **Step 6: Exercise adopt end to end on a throwaway file**

```bash
printf 'scratch\n' > ~/.config-adopt-smoke.conf
./dotfiles.sh adopt ~/.config-adopt-smoke.conf config-adopt-smoke/config-adopt-smoke.conf
./dotfiles.sh status
git -C "$PWD" diff
git -C "$PWD" status --short
```
Expected: the file is now a symlink into `dotfiles/`, `status` reports it `linked`, and `git status` shows the new repo file plus the manifest edit.

Then undo it completely, since this was only a smoke test:

```bash
rm -f ~/.config-adopt-smoke.conf
rm -rf dotfiles/config-adopt-smoke
git checkout -- dotfiles/links
git status --short   # expect: clean except for the task's real changes
```

- [ ] **Step 7: Commit**

```bash
git add dotfiles.sh tests/dotfiles.bats
git commit -m "Add dotfiles.sh adopt

Copy in, verify, then remove and link, so a failure anywhere leaves the
live file intact. A divergent repo file is overwritten so the live copy
wins and the change is reviewable in git -- unless the repo file has
uncommitted edits, which would be buried, so that refuses without --force.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 9: README

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the finished CLI from Tasks 4-8.
- Produces: nothing code depends on.

- [ ] **Step 1: Add the "Capturing config changes" section**

Insert immediately after the `## Options` table and before `## Modules`:

````markdown
## Capturing config changes

The dotfiles in `dotfiles/` are not copies. They are the files your machine
actually reads, reached through symlinks, so editing `~/.gitconfig` edits this
repo. Nothing needs syncing — only committing.

```sh
./dotfiles.sh                        # what is linked, what is not
./dotfiles.sh link                   # link anything not linked yet
./dotfiles.sh adopt ~/.tmux.conf     # pull a new live file into the repo
```

`adopt` moves the live file into `dotfiles/`, adds a manifest entry, and
symlinks it back. It infers the repo path and shows it for confirmation; pass
a second argument to choose one yourself. Nothing is committed for you —
review with `git diff`.

Nothing replaces a live file unless you ask it to. `bootstrap.sh` has no way
to ask — its linking is purely additive, so a bootstrap run cannot overwrite
config already on the machine. When it finds a file sitting at a destination
it says so in yellow and offers both ways out, because only you know which
copy is authoritative:

```
keep the live file → ./dotfiles.sh adopt ~/.config/fish/config.fish
keep the repo file → ./dotfiles.sh link --force ~/.config/fish/config.fish
```

`--force`, on the `dotfiles.sh link` side, is how you ask. It backs the live
file up to `<path>.bak-<timestamp>` before replacing it.
````

- [ ] **Step 2: Note the additive behavior in the module table**

In the `## Modules` table, change the `10-shell` row's description from

```
| `10-shell` | on | fish, fisher, dotfile links, git identity, SSH key generation |
```

to

```
| `10-shell` | on | fish, fisher, dotfile links (additive — see [Capturing config changes](#capturing-config-changes)), git identity, SSH key generation |
```

- [ ] **Step 3: Replace the stale pre-wipe checklist item**

Under `## Before wiping a machine`, replace this item

```markdown
- [ ] Commit the live `~/.config/fish/config.fish`, `~/.gitconfig`, and
      `~/.ssh/config` if they have drifted from the copies in `dotfiles/`.
```

with

```markdown
- [ ] Run `./dotfiles.sh status` and commit anything it reports. The linked
      dotfiles cannot drift — they are this repo's files — but a file that was
      never adopted, or one left unlinked because something already existed at
      its destination, only exists on this machine. `~/.ssh/config` is
      deliberately not committed; copy any host entries you want to keep by
      hand.
```

- [ ] **Step 4: Add the CLI to the docs index**

Under `## Other docs`, add as the first item:

```markdown
- [`dotfiles.sh`](./dotfiles.sh) — report, link, and adopt dotfiles (`--help`)
```

- [ ] **Step 5: Verify every command in the README actually works**

```bash
./dotfiles.sh --help
./dotfiles.sh status
./dotfiles.sh link --dry-run
```
Expected: all three succeed and behave as the new section describes. Fix the prose if they do not — the README is wrong more often than the code at this stage.

- [ ] **Step 6: Check the anchor link resolves**

The module table links to `#capturing-config-changes`. Confirm the heading is exactly `## Capturing config changes`, since GitHub derives the anchor by lowercasing and hyphenating.

- [ ] **Step 7: Commit**

```bash
git add README.md
git commit -m "Document the dotfiles CLI and retire the drift checklist

The pre-wipe item told you to check the live fish config and gitconfig
for drift against dotfiles/. They are the same files, so they cannot
drift; what can actually be lost is a file never adopted, which is what
./dotfiles.sh status reports.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Final verification

- [ ] `bats tests/` — the whole suite passes
- [ ] `shellcheck -x bootstrap.sh dotfiles.sh lib/*.sh` — silent
- [ ] `for f in modules/*/setup.sh modules/*/prompts.sh; do shellcheck -x -e SC1091 "$f"; done` — silent
- [ ] `./tests/container-smoke.sh ubuntu:26.04` — passes. This is the only check that exercises the additive link policy on a genuinely fresh machine. Note in the final report whether any dotfile was skipped on first run (for example, a `fish`-authored `config.fish` stub at the destination). Per the spec that is now a cosmetic question about first-run noise, not a correctness one — but it should be observed rather than assumed.
- [ ] `./dotfiles.sh status` on this machine, with the result recorded in the final report
- [ ] `git status --short` — no stray files from the Task 8 smoke test
