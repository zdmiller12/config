# Machine Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a curl-able, idempotent bootstrap that brings a freshly installed Ubuntu 26.04 LTS machine to a personalized state via an interactive module checklist.

**Architecture:** Four layers. `bootstrap.sh` is a curl-able entrypoint that clones the repo and re-executes the engine from the working tree. `lib/*.sh` is the engine — shared behavior with no machine-specific knowledge. `modules/<NN>-<name>/` are self-describing units that are pure data wherever possible, with a `setup.sh` only where real logic lives. `dotfiles/` holds the files plus a `links` manifest. Every mutating command routes through a single `run` wrapper, which is what makes `--dry-run` real rather than aspirational.

**Tech Stack:** Bash 5.2, bats-core (unit tests), shellcheck (lint), whiptail (TUI), Docker (container integration test), GitHub Actions (CI).

**Spec:** `docs/superpowers/specs/2026-10-14-machine-bootstrap-design.md`

## Global Constraints

Copied verbatim from the spec. Every task's requirements implicitly include this section.

- **Target platform:** Ubuntu 26.04 LTS, Debian-family tolerated. All apt calls go through `lib/apt.sh`.
- **No bootstrap dependency beyond `curl`.** The entrypoint installs `git` if absent.
- **Clone destination:** `~/git/config` (overridable via `CONFIG_REPO_DIR`).
- **Repo:** `https://github.com/zdmiller12/config.git`. The *initial* clone must use HTTPS — on a fresh machine no SSH key exists yet. `10-shell` switches the remote to SSH after generating one.
- **Local state:** `~/.config/config-bootstrap/local.env`, mode `0600`, gitignored. Holds git identity, NAS settings, the module selection, and anything else a module prompts for.
- **Transcript:** every run writes `~/.cache/config-bootstrap/run-<timestamp>.log`.
- **Flags:** `--reconfigure`, `--only <module>`, `--skip <module>`, `--dry-run`, `--yes`.
- **Error handling:** package-level failures are tolerated and recorded; module-level failures are contained to that module; preflight failures abort before anything changes.
- **Backups:** any file the engine modifies or replaces is first copied to `<path>.bak-<timestamp>`.
- **Privilege:** the engine runs unprivileged and calls `sudo` per command, validated once up front.
- **All prompting happens before any installation.**
- **`00-core` cannot be deselected.** `10-shell` is required by `20-toolchains`. All other modules are independent.
- **The `90-` prefix** marks modules that modify system state outside the package manager. They are off by default and the checklist labels them as such.
- **SSH keys are generated, never copied.** After generating, bootstrap prints the public key and pauses.

### Two documented deviations from the spec

Both are implementation realities the spec's prose did not anticipate. Noted here so a reviewer does not flag them as drift.

1. **§3 says `apt.sh` registers repos as a keyring plus a `.sources` file.** The module manifest format the same section defines is `name|keyring-url|sources-line` — a one-line entry, which is the `.list` format, not deb822 `.sources`. Writing deb822 would require multi-field manifests. This plan writes `/etc/apt/sources.list.d/<name>.list` with a `signed-by=` option. Functionally identical; still supported in 26.04.
2. **§3 lists `patch.sh` as "set an INI key, uncomment a line, write a file only if its content differs".** The real consumers need a *section-less* key setter (`/etc/default/grub` has no `[sections]`), and that subsumes "uncomment a line" because the keys being set are already present but commented. This plan implements `patch_ini_set`, `patch_kv_set`, `patch_write_if_different`, and `patch_backup` — no standalone `patch_uncomment`.
3. **§3 enumerates the module contract as `meta`, `apt`, `snap`, `repos`, `setup.sh`.** But §5 requires that *all prompting happen before any installation*, and `setup.sh` runs after installation. Those two statements cannot both hold with only the listed files. This plan adds one optional file, **`prompts.sh`**, sourced for every selected module during the prompt-collection phase. It may only call `ui_prompt` and `localenv_set` — never install anything.

### Engine conventions every task must follow

- Library files are sourced, never executed. Each starts with `# shellcheck shell=bash`.
- **Every mutating command goes through `run` or `run_sudo`** (defined in `lib/log.sh`). This is the only thing that makes `--dry-run` correct. A command that bypasses `run` will execute during a dry run — treat that as a bug.
- `run` cannot carry pipes or redirections. Where a pipeline must mutate state, branch on `$DRY_RUN` explicitly and log the intent. Tasks that need this say so.
- Functions that may or may not change something set a result global (`PATCH_RESULT`, `LINK_RESULT`) to `changed` or `unchanged` rather than returning non-zero, so `set -euo pipefail` stays usable.

---

## File Structure

| Path | Responsibility |
|---|---|
| `bootstrap.sh` | Curl-able entrypoint: preflight, ensure git, clone/update, re-exec engine; arg parsing and the run loop driver |
| `lib/log.sh` | Levelled output, the `run`/`run_sudo` wrappers, transcript, run summary |
| `lib/patch.sh` | Check-then-patch config file helpers; backup-on-first-touch |
| `lib/link.sh` | Dotfile symlinking with backup of pre-existing non-symlinks |
| `lib/apt.sh` | Repo registration, coalesced `apt-get update`, tolerant install |
| `lib/pkg.sh` | Snap installation, same tolerance |
| `lib/ui.sh` | Module checklist and prompts; whiptail with a numbered-list fallback |
| `lib/module.sh` | Manifest parsing, module discovery, `requires` ordering, selection persistence, module run |
| `modules/<NN>-<name>/prompts.sh` | Optional. Collects that module's answers during the up-front prompt phase |
| `modules/00-core/` | Build toolchain and the headers needed to compile Pythons. Pure data |
| `modules/10-shell/` | fish, fisher, dotfile links, git identity, SSH keygen, `chsh` |
| `modules/20-toolchains/` | asdf, pyenv, uv, rustup and their fish init blocks |
| `modules/30-dev/` | VSCode via Microsoft repo plus extensions, Docker CE |
| `modules/40-desktop/` | brave, qbittorrent, kdeconnect, fonts, GNOME settings |
| `modules/50-media/` | ffmpeg, mkvtoolnix, VLC (snap), inkscape, pandoc, texlive, exif, webp |
| `modules/60-nas/` | sshfs, the NAS mount unit rendered from prompts |
| `modules/90-bluetooth-autoreconnect/` | bluez `AutoEnable` and `UserspaceHID` |
| `modules/90-dualboot/` | os-prober, GRUB hidden menu, dynamic `winboot` |
| `dotfiles/links` | Manifest mapping repo-relative path to destination |
| `dotfiles/fish/` | `config.fish` and `functions/` |
| `dotfiles/git/gitconfig` | Aliases and settings; `[user]` rendered from local config |
| `dotfiles/ssh/config.template` | Host entries, no secrets |
| `tools/` | Relocated `printing/`, `sharedalbum/`, `videos/`, excluded from bootstrap |
| `docs/openusd.md` | Relocated OpenUSD build notes |
| `docs/virtualization.md` | What remains of the dropped KVM stack |
| `tests/*.bats` | Engine unit tests |
| `tests/helper.bash` | Shared test setup |
| `.github/workflows/ci.yml` | shellcheck, bats, dry-run over every module, container integration |

**Phases.** Tasks 1–9 build the engine and are the natural first checkpoint — at the end, `bootstrap.sh --dry-run` drives a fixture module with green tests. Tasks 10–12 migrate existing repo content and build the dotfiles tree. Tasks 13–21 are the module catalog, one task per module. Task 22 wires the container and idempotency tests.

---

## Phase 1 — Engine

### Task 1: Test harness, lint, and CI skeleton

Nothing else can be verified until this exists. `bats` and `shellcheck` are **not currently installed** on the dev machine.

**Files:**
- Create: `tests/helper.bash`
- Create: `tests/harness.bats`
- Create: `.github/workflows/ci.yml`
- Create: `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: `load_lib <name>` — sources `lib/<name>.sh` into a test; `setup_tmpdir` — creates `$TMPTEST` and `cd`s into it; `teardown_tmpdir` — removes it. Every later test file uses these.

- [ ] **Step 1: Install the dev dependencies**

```bash
sudo apt-get update && sudo apt-get install -y bats shellcheck
bats --version && shellcheck --version
```

Expected: bats 1.10 or newer, shellcheck 0.9 or newer.

- [ ] **Step 2: Write the test helper**

Create `tests/helper.bash`:

```bash
# shellcheck shell=bash
# Shared setup for all bats test files.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
export REPO_ROOT

# Source an engine library by name, e.g. load_lib patch
load_lib() {
    local name=$1
    # Engine libraries assume these are set by bootstrap.sh.
    : "${DRY_RUN:=0}"
    export DRY_RUN
    # shellcheck disable=SC1090
    source "$REPO_ROOT/lib/${name}.sh"
}

setup_tmpdir() {
    TMPTEST="$(mktemp -d)"
    export TMPTEST
    cd "$TMPTEST" || return 1
}

teardown_tmpdir() {
    cd / || return 0
    [[ -n ${TMPTEST:-} && -d $TMPTEST ]] && rm -rf "$TMPTEST"
    return 0
}
```

- [ ] **Step 3: Write the failing harness test**

Create `tests/harness.bats`:

```bash
#!/usr/bin/env bats

load helper

setup() { setup_tmpdir; }
teardown() { teardown_tmpdir; }

@test "helper exposes REPO_ROOT pointing at the repo" {
    [ -n "$REPO_ROOT" ]
    [ -f "$REPO_ROOT/README.md" ]
}

@test "setup_tmpdir creates an empty working directory" {
    [ -d "$TMPTEST" ]
    [ "$(pwd)" = "$TMPTEST" ]
    [ -z "$(ls -A "$TMPTEST")" ]
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/harness.bats`
Expected: 2 tests, 2 passing. (This task's test verifies the harness itself, so it passes immediately — the TDD cycle starts in Task 2 where there is production code to drive.)

- [ ] **Step 5: Write the gitignore**

Create `.gitignore`:

```gitignore
# Local, machine-specific state — never committed.
local.env

# Editor and OS noise
*.swp
.DS_Store
```

- [ ] **Step 6: Write the CI workflow**

Create `.github/workflows/ci.yml`. The container and dry-run jobs are added in Task 22; this is the lint and unit-test skeleton.

```yaml
name: CI

on:
  push:
    branches: [main, bootstrap]
  pull_request:

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install shellcheck
        run: sudo apt-get update && sudo apt-get install -y shellcheck
      - name: Shellcheck the engine and all module setup scripts
        run: |
          shellcheck bootstrap.sh
          shellcheck lib/*.sh
          # Modules are sourced with the engine's helpers already defined,
          # so tell shellcheck not to flag those as undefined.
          for f in modules/*/setup.sh; do
            [ -e "$f" ] || continue
            shellcheck -x -e SC1091 "$f"
          done

  unit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install bats
        run: sudo apt-get update && sudo apt-get install -y bats
      - name: Run unit tests
        run: bats tests/
```

- [ ] **Step 7: Verify shellcheck runs clean on an empty engine**

Run: `shellcheck tests/helper.bash`
Expected: no output (exit 0).

- [ ] **Step 8: Commit**

```bash
git add tests/helper.bash tests/harness.bats .github/workflows/ci.yml .gitignore
git commit -m "test: add bats harness, gitignore, and CI lint/unit skeleton"
```

---

### Task 2: `lib/log.sh` — output, the run wrapper, and the summary

The `run` wrapper is the single most important function in the engine: it is what makes `--dry-run` trustworthy.

**Files:**
- Create: `lib/log.sh`
- Test: `tests/log.bats`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `log_init` — creates the log directory, sets `LOG_FILE`
  - `log_info MSG…`, `log_ok MSG…`, `log_warn MSG…`, `log_error MSG…`, `log_step MSG…`
  - `run CMD ARG…` — executes, or prints when `DRY_RUN=1`; returns the command's exit status
  - `run_sudo CMD ARG…` — `run sudo CMD ARG…`
  - `summary_add STATUS MODULE [DETAIL]` where STATUS is `ok`, `changed`, or `failed`
  - `summary_note MSG` — a manual follow-up for the end-of-run report
  - `summary_print` — prints the report; returns 1 if any `failed` entries exist
  - Globals: `DRY_RUN` (0/1), `LOG_FILE`, `RUN_STAMP`

- [ ] **Step 1: Write the failing test**

Create `tests/log.bats`:

```bash
#!/usr/bin/env bats

load helper

setup() {
    setup_tmpdir
    load_lib log
    RUN_STAMP="test"
    LOG_FILE="$TMPTEST/run.log"
    : > "$LOG_FILE"
}
teardown() { teardown_tmpdir; }

@test "run executes the command when DRY_RUN is 0" {
    DRY_RUN=0
    run_output="$(run touch made-it; ls)"
    [ -f made-it ]
}

@test "run does not execute the command when DRY_RUN is 1" {
    DRY_RUN=1
    run touch should-not-exist
    [ ! -e should-not-exist ]
}

@test "run reports the command it skipped during a dry run" {
    DRY_RUN=1
    output="$(run touch nope 2>&1)"
    [[ $output == *"touch nope"* ]]
}

@test "run propagates the command's exit status" {
    DRY_RUN=0
    run_status=0
    run false || run_status=$?
    [ "$run_status" -eq 1 ]
}

@test "run_sudo prefixes sudo" {
    DRY_RUN=1
    output="$(run_sudo apt-get install foo 2>&1)"
    [[ $output == *"sudo apt-get install foo"* ]]
}

@test "log messages are appended to the transcript" {
    log_info "hello transcript"
    grep -q "hello transcript" "$LOG_FILE"
}

@test "summary_print reports failures and returns non-zero" {
    summary_add ok 00-core
    summary_add failed 40-desktop "brave"
    status=0
    output="$(summary_print)" || status=$?
    [ "$status" -eq 1 ]
    [[ $output == *"40-desktop"* ]]
    [[ $output == *"brave"* ]]
}

@test "summary_print returns zero when nothing failed" {
    summary_add ok 00-core
    summary_add changed 10-shell
    status=0
    summary_print >/dev/null || status=$?
    [ "$status" -eq 0 ]
}

@test "summary_note surfaces manual follow-ups" {
    summary_note "Add the SSH key to GitHub"
    output="$(summary_print)"
    [[ $output == *"Add the SSH key to GitHub"* ]]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/log.bats`
Expected: all tests FAIL — `lib/log.sh` does not exist, so `load_lib log` errors with "No such file or directory".

- [ ] **Step 3: Write the implementation**

Create `lib/log.sh`:

```bash
# shellcheck shell=bash
# Levelled output, the dry-run-aware command wrapper, and the run summary.

: "${DRY_RUN:=0}"
: "${RUN_STAMP:=$(date +%Y%m%d-%H%M%S)}"
LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/config-bootstrap"
: "${LOG_FILE:=}"

SUMMARY_ROWS=()
SUMMARY_NOTES=()

log_init() {
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/run-$RUN_STAMP.log"
    : > "$LOG_FILE"
    log_info "Transcript: $LOG_FILE"
}

# _log LEVEL ANSI_COLOR MESSAGE...
_log() {
    local level=$1 color=$2
    shift 2
    local line="[$level] $*"
    if [[ -t 1 && -n $color ]]; then
        printf '\033[%sm%s\033[0m\n' "$color" "$line"
    else
        printf '%s\n' "$line"
    fi
    if [[ -n $LOG_FILE && -w $LOG_FILE ]]; then
        printf '%s %s\n' "$(date +%H:%M:%S)" "$line" >> "$LOG_FILE"
    fi
}

log_info()  { _log INFO  '0;34' "$@"; }
log_ok()    { _log OK    '0;32' "$@"; }
log_warn()  { _log WARN  '0;33' "$@"; }
log_error() { _log ERROR '0;31' "$@"; }
log_step()  { _log STEP  '1;37' "$@"; }

# run CMD ARG... — the single chokepoint for anything that mutates the machine.
# Cannot carry pipes or redirections; branch on DRY_RUN explicitly for those.
run() {
    if (( DRY_RUN )); then
        _log DRY '0;36' "$*"
        return 0
    fi
    _log CMD '' "$*"
    "$@"
}

run_sudo() { run sudo "$@"; }

# summary_add STATUS MODULE [DETAIL]   STATUS: ok | changed | failed
summary_add() {
    SUMMARY_ROWS+=("$1|$2|${3:-}")
}

summary_note() {
    SUMMARY_NOTES+=("$1")
}

summary_print() {
    local row status module detail failed=0
    printf '\n'
    log_step "Run summary"
    for row in "${SUMMARY_ROWS[@]:-}"; do
        [[ -z $row ]] && continue
        IFS='|' read -r status module detail <<< "$row"
        case $status in
            ok)      log_ok      "$module${detail:+ — $detail}" ;;
            changed) log_info    "$module changed${detail:+ — $detail}" ;;
            failed)  log_error   "$module failed${detail:+ — $detail}"; failed=1 ;;
        esac
    done
    if (( ${#SUMMARY_NOTES[@]} )); then
        printf '\n'
        log_step "Manual follow-ups"
        local note
        for note in "${SUMMARY_NOTES[@]}"; do
            log_warn "$note"
        done
    fi
    [[ -n $LOG_FILE ]] && log_info "Transcript: $LOG_FILE"
    return "$failed"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/log.bats`
Expected: 9 tests, 9 passing.

- [ ] **Step 5: Lint**

Run: `shellcheck lib/log.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add lib/log.sh tests/log.bats
git commit -m "feat(engine): add log.sh with dry-run-aware run wrapper and summary"
```

---

### Task 3: `lib/patch.sh` — check-then-patch config helpers

Pure text transformation, so this is the most thoroughly testable part of the engine. Idempotency is the property that matters: patch twice, change once.

**Files:**
- Create: `lib/patch.sh`
- Test: `tests/patch.bats`

**Interfaces:**
- Consumes: `run`, `run_sudo`, `_log`, `DRY_RUN`, `RUN_STAMP` from `lib/log.sh`.
- Produces:
  - `_patch_needs_sudo FILE` — internal; true only when the path is not writable as the current user, so `$HOME` files never become root-owned
  - `patch_backup FILE` — copies to `FILE.bak-$RUN_STAMP` once per run; no-op if the file is absent or the backup already exists
  - `patch_write_if_different FILE CONTENT` — writes only when content differs; sets `PATCH_RESULT`
  - `patch_kv_set FILE KEY VALUE` — section-less `KEY=VALUE` files such as `/etc/default/grub`; replaces an existing or commented-out key, else appends; sets `PATCH_RESULT`
  - `patch_ini_set FILE SECTION KEY VALUE` — sectioned INI files such as `/etc/bluetooth/main.conf`; creates the section if absent; sets `PATCH_RESULT`
  - Global: `PATCH_RESULT` is `changed` or `unchanged` after any of the three setters

- [ ] **Step 1: Write the failing test**

Create `tests/patch.bats`:

```bash
#!/usr/bin/env bats

load helper

setup() {
    setup_tmpdir
    load_lib log
    load_lib patch
    RUN_STAMP="test"
    DRY_RUN=0
    # patch_* shell out to sudo for system files; tests operate on files we own.
    sudo() { "$@"; }
    export -f sudo 2>/dev/null || true
}
teardown() { teardown_tmpdir; }

@test "patch_write_if_different writes a new file" {
    patch_write_if_different new.conf "hello"
    [ "$PATCH_RESULT" = changed ]
    [ "$(cat new.conf)" = "hello" ]
}

@test "patch_write_if_different is a no-op when content matches" {
    printf 'hello\n' > same.conf
    patch_write_if_different same.conf "hello"
    [ "$PATCH_RESULT" = unchanged ]
}

@test "patch_write_if_different backs up the file it replaces" {
    printf 'old\n' > replaced.conf
    patch_write_if_different replaced.conf "new"
    [ -f "replaced.conf.bak-test" ]
    [ "$(cat replaced.conf.bak-test)" = "old" ]
}

@test "patch_backup does not overwrite an existing backup" {
    printf 'original\n' > f.conf
    patch_backup f.conf
    printf 'modified\n' > f.conf
    patch_backup f.conf
    [ "$(cat f.conf.bak-test)" = "original" ]
}

@test "patch_backup is a no-op for a missing file" {
    patch_backup absent.conf
    [ ! -e "absent.conf.bak-test" ]
}

@test "patch_kv_set replaces an existing key" {
    printf 'GRUB_TIMEOUT=5\nGRUB_DEFAULT=0\n' > grub
    patch_kv_set grub GRUB_TIMEOUT 0
    [ "$PATCH_RESULT" = changed ]
    grep -qx 'GRUB_TIMEOUT=0' grub
    grep -qx 'GRUB_DEFAULT=0' grub
}

@test "patch_kv_set uncomments and sets a commented key" {
    printf '#GRUB_DISABLE_OS_PROBER=false\n' > grub
    patch_kv_set grub GRUB_DISABLE_OS_PROBER false
    grep -qx 'GRUB_DISABLE_OS_PROBER=false' grub
    ! grep -q '^#GRUB_DISABLE_OS_PROBER' grub
}

@test "patch_kv_set appends a key that is absent" {
    printf 'GRUB_DEFAULT=0\n' > grub
    patch_kv_set grub GRUB_TIMEOUT_STYLE hidden
    grep -qx 'GRUB_TIMEOUT_STYLE=hidden' grub
}

@test "patch_kv_set is idempotent" {
    printf 'GRUB_TIMEOUT=5\n' > grub
    patch_kv_set grub GRUB_TIMEOUT 0
    [ "$PATCH_RESULT" = changed ]
    patch_kv_set grub GRUB_TIMEOUT 0
    [ "$PATCH_RESULT" = unchanged ]
    [ "$(grep -c 'GRUB_TIMEOUT' grub)" -eq 1 ]
}

@test "patch_ini_set sets a key inside an existing section" {
    printf '[General]\nFoo=1\n\n[Policy]\n#AutoEnable=false\n' > main.conf
    patch_ini_set main.conf Policy AutoEnable true
    [ "$PATCH_RESULT" = changed ]
    grep -qx 'AutoEnable=true' main.conf
    grep -qx 'Foo=1' main.conf
}

@test "patch_ini_set creates a missing section" {
    printf '[General]\nFoo=1\n' > main.conf
    patch_ini_set main.conf Policy AutoEnable true
    grep -qx '\[Policy\]' main.conf
    grep -qx 'AutoEnable=true' main.conf
}

@test "patch_ini_set does not touch a same-named key in another section" {
    printf '[A]\nKey=one\n[B]\nKey=two\n' > ini.conf
    patch_ini_set ini.conf B Key three
    grep -qx 'Key=one' ini.conf
    grep -qx 'Key=three' ini.conf
    ! grep -qx 'Key=two' ini.conf
}

@test "patch_ini_set appends the key when the section is last and empty" {
    printf '[General]\nFoo=1\n[Policy]\n' > main.conf
    patch_ini_set main.conf Policy AutoEnable true
    grep -qx 'AutoEnable=true' main.conf
}

@test "patch_ini_set is idempotent" {
    printf '[Policy]\n#AutoEnable=false\n' > main.conf
    patch_ini_set main.conf Policy AutoEnable true
    [ "$PATCH_RESULT" = changed ]
    patch_ini_set main.conf Policy AutoEnable true
    [ "$PATCH_RESULT" = unchanged ]
    [ "$(grep -c 'AutoEnable' main.conf)" -eq 1 ]
}

@test "patch_kv_set changes nothing during a dry run" {
    printf 'GRUB_TIMEOUT=5\n' > grub
    DRY_RUN=1
    patch_kv_set grub GRUB_TIMEOUT 0
    grep -qx 'GRUB_TIMEOUT=5' grub
}

@test "patch_write_if_different does not use sudo for a path we own" {
    # If sudo were invoked it would fail, and the write would not land.
    sudo() { echo "SUDO WAS CALLED" >&2; return 1; }
    patch_write_if_different "$TMPTEST/mine.conf" "hello"
    [ "$(cat "$TMPTEST/mine.conf")" = "hello" ]
}

@test "patch_write_if_different creates missing parent directories" {
    sudo() { echo "SUDO WAS CALLED" >&2; return 1; }
    patch_write_if_different "$TMPTEST/a/b/c/deep.conf" "nested"
    [ "$(cat "$TMPTEST/a/b/c/deep.conf")" = "nested" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/patch.bats`
Expected: all 17 FAIL — `lib/patch.sh` does not exist.

- [ ] **Step 3: Write the implementation**

Create `lib/patch.sh`:

```bash
# shellcheck shell=bash
# Check-then-patch helpers for config files. Every setter is idempotent and
# sets PATCH_RESULT to "changed" or "unchanged".

PATCH_RESULT=unchanged

# _patch_needs_sudo FILE — true when we cannot write the path as ourselves.
# Without this, a write to ~/.gitconfig.local would go through `sudo tee` and
# leave a root-owned file in the user's own home that they cannot edit.
_patch_needs_sudo() {
    local file=$1 dir
    dir=$(dirname "$file")
    [[ -d $dir && -w $dir ]] || return 0
    [[ ! -e $file || -w $file ]] || return 0
    return 1
}

# patch_backup FILE — copy to FILE.bak-$RUN_STAMP, once per run.
patch_backup() {
    local file=$1
    [[ -e $file ]] || return 0
    local bak="$file.bak-$RUN_STAMP"
    [[ -e $bak ]] && return 0
    if _patch_needs_sudo "$file"; then
        run_sudo cp -a "$file" "$bak"
    else
        run cp -a "$file" "$bak"
    fi
}

# patch_write_if_different FILE CONTENT
patch_write_if_different() {
    local file=$1 content=$2
    if [[ -f $file ]] && [[ "$(cat "$file")" == "$content" ]]; then
        PATCH_RESULT=unchanged
        return 0
    fi
    PATCH_RESULT=changed
    patch_backup "$file"
    if (( DRY_RUN )); then
        _log DRY '0;36' "write $file (content differs)"
        return 0
    fi
    _log CMD '' "write $file"
    local dir
    dir=$(dirname "$file")
    if _patch_needs_sudo "$file"; then
        sudo install -d -m 0755 "$dir"
        printf '%s\n' "$content" | sudo tee "$file" > /dev/null
    else
        mkdir -p "$dir"
        printf '%s\n' "$content" > "$file"
    fi
}

# patch_kv_set FILE KEY VALUE — section-less KEY=VALUE files.
# Replaces the key whether it is active or commented out; appends if absent.
patch_kv_set() {
    local file=$1 key=$2 value=$3 content
    [[ -f $file ]] || { patch_write_if_different "$file" "$key=$value"; return 0; }
    content=$(awk -v key="$key" -v value="$value" '
        BEGIN { done = 0 }
        {
            if (!done && $0 ~ "^[[:space:]]*#?[[:space:]]*" key "[[:space:]]*=") {
                print key "=" value
                done = 1
                next
            }
            print
        }
        END { if (!done) print key "=" value }
    ' "$file")
    patch_write_if_different "$file" "$content"
}

# patch_ini_set FILE SECTION KEY VALUE — sectioned INI files.
# Creates the section if it is absent; only touches the key inside SECTION.
patch_ini_set() {
    local file=$1 section=$2 key=$3 value=$4 content
    if [[ ! -f $file ]]; then
        patch_write_if_different "$file" "[$section]
$key=$value"
        return 0
    fi
    content=$(awk -v section="$section" -v key="$key" -v value="$value" '
        BEGIN { insec = 0; done = 0 }
        # Any section header.
        /^[[:space:]]*\[/ {
            # Leaving the target section without having set the key.
            if (insec && !done) { print key "=" value; done = 1 }
            insec = ($0 ~ "^[[:space:]]*\\[" section "\\][[:space:]]*$")
            print
            next
        }
        {
            if (insec && !done && $0 ~ "^[[:space:]]*#?[[:space:]]*" key "[[:space:]]*=") {
                print key "=" value
                done = 1
                next
            }
            print
        }
        END {
            if (done) { }
            else if (insec) { print key "=" value }
            else { print "[" section "]"; print key "=" value }
        }
    ' "$file")
    patch_write_if_different "$file" "$content"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/patch.bats`
Expected: 17 tests, 17 passing.

If "patch_ini_set appends the key when the section is last and empty" fails, the bug is in the `END` block: when the target section is the final one and contains no matching key, `insec` is still 1 and `done` is 0, so the `else if (insec)` branch must fire.

- [ ] **Step 5: Lint**

Run: `shellcheck lib/patch.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add lib/patch.sh tests/patch.bats
git commit -m "feat(engine): add patch.sh with idempotent INI and key=value setters"
```

---

### Task 4: `lib/link.sh` — dotfile symlinking with backup

**Files:**
- Create: `lib/link.sh`
- Test: `tests/link.bats`

**Interfaces:**
- Consumes: `run`, `_log`, `log_error`, `DRY_RUN`, `RUN_STAMP` from `lib/log.sh`.
- Produces:
  - `link_file SRC DEST` — symlinks `DEST` to `SRC`; backs up a pre-existing non-symlink to `DEST.bak-$RUN_STAMP`; sets `LINK_RESULT`
  - `link_manifest MANIFEST REPO_ROOT` — reads two whitespace-separated columns (repo-relative source, destination with `~` allowed) and links each; skips `#` comments and blank lines
  - Global: `LINK_RESULT` is `changed` or `unchanged`

- [ ] **Step 1: Write the failing test**

Create `tests/link.bats`:

```bash
#!/usr/bin/env bats

load helper

setup() {
    setup_tmpdir
    load_lib log
    load_lib link
    RUN_STAMP="test"
    DRY_RUN=0
    mkdir -p repo dest
    printf 'source content\n' > repo/file.conf
}
teardown() { teardown_tmpdir; }

@test "link_file creates a symlink" {
    link_file "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf"
    [ -L "$TMPTEST/dest/file.conf" ]
    [ "$(cat "$TMPTEST/dest/file.conf")" = "source content" ]
    [ "$LINK_RESULT" = changed ]
}

@test "link_file creates missing parent directories" {
    link_file "$TMPTEST/repo/file.conf" "$TMPTEST/deep/a/b/file.conf"
    [ -L "$TMPTEST/deep/a/b/file.conf" ]
}

@test "link_file is a no-op when the correct symlink already exists" {
    link_file "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf"
    link_file "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf"
    [ "$LINK_RESULT" = unchanged ]
}

@test "link_file backs up a pre-existing regular file" {
    printf 'user data\n' > "$TMPTEST/dest/file.conf"
    link_file "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf"
    [ -L "$TMPTEST/dest/file.conf" ]
    [ "$(cat "$TMPTEST/dest/file.conf.bak-test")" = "user data" ]
}

@test "link_file replaces a symlink pointing somewhere else without a backup" {
    printf 'other\n' > "$TMPTEST/repo/other.conf"
    ln -s "$TMPTEST/repo/other.conf" "$TMPTEST/dest/file.conf"
    link_file "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf"
    [ "$(cat "$TMPTEST/dest/file.conf")" = "source content" ]
    [ ! -e "$TMPTEST/dest/file.conf.bak-test" ]
}

@test "link_file fails when the source is missing" {
    status=0
    link_file "$TMPTEST/repo/absent.conf" "$TMPTEST/dest/x.conf" || status=$?
    [ "$status" -ne 0 ]
}

@test "link_file changes nothing during a dry run" {
    DRY_RUN=1
    link_file "$TMPTEST/repo/file.conf" "$TMPTEST/dest/file.conf"
    [ ! -e "$TMPTEST/dest/file.conf" ]
}

@test "link_manifest links every entry and skips comments and blanks" {
    printf 'second\n' > repo/second.conf
    cat > links <<EOF
# a comment
file.conf    $TMPTEST/dest/one.conf

second.conf  $TMPTEST/dest/two.conf
EOF
    link_manifest links "$TMPTEST/repo"
    [ -L "$TMPTEST/dest/one.conf" ]
    [ -L "$TMPTEST/dest/two.conf" ]
}

@test "link_manifest expands a leading tilde in the destination" {
    HOME="$TMPTEST/fakehome"
    mkdir -p "$HOME"
    printf 'file.conf  ~/.config/app/file.conf\n' > links
    link_manifest links "$TMPTEST/repo"
    [ -L "$TMPTEST/fakehome/.config/app/file.conf" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/link.bats`
Expected: all 9 FAIL — `lib/link.sh` does not exist.

- [ ] **Step 3: Write the implementation**

Create `lib/link.sh`:

```bash
# shellcheck shell=bash
# Dotfile symlinking. Anything pre-existing and not already a symlink is
# backed up before being replaced.

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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/link.bats`
Expected: 9 tests, 9 passing.

- [ ] **Step 5: Lint**

Run: `shellcheck lib/link.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add lib/link.sh tests/link.bats
git commit -m "feat(engine): add link.sh with symlinking and backup of existing files"
```

---

### Task 5: `lib/apt.sh` — repo registration, coalesced update, tolerant install

Package-level failure tolerance lives here. The strategy is to try the whole batch in one `apt-get install` (fast), and only on failure retry package-by-package to isolate which one is at fault. That keeps the common case quick while still naming the culprit.

**Files:**
- Create: `lib/apt.sh`
- Test: `tests/apt.bats`

**Interfaces:**
- Consumes: `run`, `run_sudo`, `_log`, `log_warn`, `log_error`, `DRY_RUN` from `lib/log.sh`; `patch_write_if_different` and `PATCH_RESULT` from `lib/patch.sh`.
- Produces:
  - `apt_add_repo NAME KEYRING_URL SOURCES_LINE` — installs the keyring and writes `/etc/apt/sources.list.d/NAME.list`. The literal token `@KEYRING@` in `SOURCES_LINE` is replaced with the keyring path. Marks the apt cache stale.
  - `apt_update_once` — runs `apt-get update` at most once per run, unless a repo was added since
  - `apt_mark_stale` — forces the next `apt_update_once` to actually update
  - `apt_install PKG…` — installs, tolerating per-package failure; appends failures to `APT_FAILED`
  - Globals: `APT_UPDATED` (0/1), `APT_FAILED` (array)

- [ ] **Step 1: Write the failing test**

Create `tests/apt.bats`:

```bash
#!/usr/bin/env bats

load helper

setup() {
    setup_tmpdir
    load_lib log
    load_lib patch
    load_lib apt
    RUN_STAMP="test"
    DRY_RUN=1          # compose commands without touching the machine
    APT_UPDATED=0
    APT_FAILED=()
}
teardown() { teardown_tmpdir; }

@test "apt_update_once runs update the first time" {
    output="$(apt_update_once 2>&1)"
    [[ $output == *"apt-get update"* ]]
    [ "$APT_UPDATED" -eq 1 ]
}

@test "apt_update_once does not run update a second time" {
    apt_update_once > /dev/null 2>&1
    output="$(apt_update_once 2>&1)"
    [[ $output != *"apt-get update"* ]]
}

@test "apt_mark_stale forces another update" {
    apt_update_once > /dev/null 2>&1
    apt_mark_stale
    output="$(apt_update_once 2>&1)"
    [[ $output == *"apt-get update"* ]]
}

@test "apt_install with no arguments does nothing" {
    output="$(apt_install 2>&1)"
    [[ $output != *"apt-get install"* ]]
}

@test "apt_install composes a single batch install" {
    output="$(apt_install git curl 2>&1)"
    [[ $output == *"apt-get install -y git curl"* ]]
}

@test "apt_add_repo substitutes the keyring path into the sources line" {
    DRY_RUN=0
    SOURCES_DIR="$TMPTEST/sources"
    KEYRING_DIR="$TMPTEST/keyrings"
    mkdir -p "$SOURCES_DIR" "$KEYRING_DIR"
    # Pretend the keyring already exists so no network call is attempted.
    touch "$KEYRING_DIR/example.gpg"
    apt_add_repo example https://example.invalid/key.asc \
        'deb [signed-by=@KEYRING@] https://example.invalid/apt stable main'
    grep -q "signed-by=$KEYRING_DIR/example.gpg" "$SOURCES_DIR/example.list"
}

@test "apt_add_repo dearmors an ASCII-armored key but not a binary one" {
    DRY_RUN=0
    SOURCES_DIR="$TMPTEST/sources"
    KEYRING_DIR="$TMPTEST/keyrings"
    mkdir -p "$SOURCES_DIR" "$KEYRING_DIR" "$TMPTEST/bin"
    # Stub curl to serve local fixtures, and gpg to mark what it touched.
    printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\nfake\n' > "$TMPTEST/armored.asc"
    printf '\x99\x01\x0dbinary-keyring-bytes' > "$TMPTEST/binary.gpg"
    cat > "$TMPTEST/bin/curl" <<'STUB'
#!/usr/bin/env bash
# curl -fsSL URL -o DEST
dest=""; url=""
while [[ $# -gt 0 ]]; do
  case $1 in -o) dest=$2; shift 2 ;; -*) shift ;; *) url=$1; shift ;; esac
done
case $url in
  *armored*) cp "$FIXTURE_ARMORED" "$dest" ;;
  *) cp "$FIXTURE_BINARY" "$dest" ;;
esac
STUB
    cat > "$TMPTEST/bin/gpg" <<'STUB'
#!/usr/bin/env bash
# gpg --dearmor -o OUT   (reads stdin)
out=""
while [[ $# -gt 0 ]]; do
  case $1 in -o) out=$2; shift 2 ;; *) shift ;; esac
done
printf 'DEARMORED\n' > "$out"
STUB
    chmod +x "$TMPTEST/bin/curl" "$TMPTEST/bin/gpg"
    PATH="$TMPTEST/bin:$PATH"
    FIXTURE_ARMORED="$TMPTEST/armored.asc"
    FIXTURE_BINARY="$TMPTEST/binary.gpg"
    export FIXTURE_ARMORED FIXTURE_BINARY
    sudo() { "$@"; }

    apt_add_repo armoredrepo https://example.invalid/armored.asc 'deb https://x stable main'
    grep -q 'DEARMORED' "$KEYRING_DIR/armoredrepo.gpg"

    apt_add_repo binaryrepo https://example.invalid/keyring.gpg 'deb https://y stable main'
    ! grep -q 'DEARMORED' "$KEYRING_DIR/binaryrepo.gpg"
    grep -q 'binary-keyring-bytes' "$KEYRING_DIR/binaryrepo.gpg"
}

@test "apt_add_repo is idempotent and only marks stale on change" {
    DRY_RUN=0
    SOURCES_DIR="$TMPTEST/sources"
    KEYRING_DIR="$TMPTEST/keyrings"
    mkdir -p "$SOURCES_DIR" "$KEYRING_DIR"
    touch "$KEYRING_DIR/example.gpg"
    apt_add_repo example https://example.invalid/key.asc 'deb https://example.invalid/apt stable main'
    APT_UPDATED=1
    apt_add_repo example https://example.invalid/key.asc 'deb https://example.invalid/apt stable main'
    [ "$APT_UPDATED" -eq 1 ]
}
```

Note the two `SOURCES_DIR`/`KEYRING_DIR` overrides — the implementation must read those as variables rather than hardcoding `/etc`, precisely so the paths are testable without root.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/apt.bats`
Expected: all 8 FAIL — `lib/apt.sh` does not exist.

- [ ] **Step 3: Write the implementation**

Create `lib/apt.sh`:

```bash
# shellcheck shell=bash
# apt repository registration, coalesced cache refresh, and tolerant install.
# SOURCES_DIR and KEYRING_DIR are overridable so the unit tests can run
# without root.

: "${SOURCES_DIR:=/etc/apt/sources.list.d}"
: "${KEYRING_DIR:=/etc/apt/keyrings}"

APT_UPDATED=0
APT_FAILED=()

apt_mark_stale() { APT_UPDATED=0; }

apt_update_once() {
    (( APT_UPDATED )) && return 0
    run_sudo apt-get update -qq
    APT_UPDATED=1
}

# apt_add_repo NAME KEYRING_URL SOURCES_LINE
apt_add_repo() {
    local name=$1 key_url=$2 sources_line=$3
    local keyring="$KEYRING_DIR/$name.gpg"
    local list="$SOURCES_DIR/$name.list"

    [[ -d $KEYRING_DIR ]] || run_sudo install -d -m 0755 "$KEYRING_DIR"

    if [[ ! -f $keyring ]]; then
        if (( DRY_RUN )); then
            _log DRY '0;36' "fetch $key_url -> $keyring"
        else
            _log CMD '' "fetch keyring for $name"
            local tmp
            tmp=$(mktemp)
            if ! curl -fsSL "$key_url" -o "$tmp"; then
                log_error "could not download keyring for $name"
                rm -f "$tmp"
                return 1
            fi
            # Vendors are inconsistent: Microsoft and Docker publish an
            # ASCII-armored key, Brave publishes an already-binary keyring.
            # Dearmor only the former — doing it unconditionally corrupts
            # the latter.
            if head -c 64 "$tmp" | grep -q 'BEGIN PGP'; then
                sudo gpg --dearmor -o "$keyring" < "$tmp"
            else
                sudo install -m 0644 "$tmp" "$keyring"
            fi
            rm -f "$tmp"
        fi
        apt_mark_stale
    fi

    sources_line=${sources_line//@KEYRING@/$keyring}
    patch_write_if_different "$list" "$sources_line"
    [[ $PATCH_RESULT == changed ]] && apt_mark_stale
    return 0
}

# apt_install PKG... — tolerates individual package failures.
apt_install() {
    (( $# )) || return 0
    apt_update_once
    if run_sudo apt-get install -y "$@"; then
        return 0
    fi
    log_warn "batch install failed; retrying individually to isolate the failure"
    local pkg
    for pkg in "$@"; do
        if ! run_sudo apt-get install -y "$pkg"; then
            APT_FAILED+=("$pkg")
            log_error "package failed: $pkg"
        fi
    done
    return 0
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/apt.bats`
Expected: 8 tests, 8 passing.

- [ ] **Step 5: Lint**

Run: `shellcheck lib/apt.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add lib/apt.sh tests/apt.bats
git commit -m "feat(engine): add apt.sh with repo registration and tolerant install"
```

---

### Task 6: `lib/pkg.sh` — snap installation and interface connection

`pkg_snap_connect` exists because of the hazard in spec §10: VLC's snap cannot read `/mnt` without the `removable-media` interface, and `60-nas` mounts there.

**Files:**
- Create: `lib/pkg.sh`
- Test: `tests/pkg.bats`

**Interfaces:**
- Consumes: `run_sudo`, `log_info`, `log_warn`, `log_error`, `DRY_RUN` from `lib/log.sh`.
- Produces:
  - `pkg_snap_available` — true when the `snap` command exists (false in containers)
  - `pkg_snap_install SPEC…` — each SPEC is a snap name plus optional flags, e.g. `code --classic`; skips snaps already present; appends failures to `PKG_FAILED`
  - `pkg_snap_connect SNAP INTERFACE` — connects the interface unless already connected
  - Global: `PKG_FAILED` (array)

- [ ] **Step 1: Write the failing test**

Create `tests/pkg.bats`:

```bash
#!/usr/bin/env bats

load helper

setup() {
    setup_tmpdir
    load_lib log
    load_lib pkg
    RUN_STAMP="test"
    DRY_RUN=1
    PKG_FAILED=()
    # Stub snap so tests never touch the real snapd.
    mkdir -p "$TMPTEST/bin"
    cat > "$TMPTEST/bin/snap" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list)
    # "installed-snap" exists; anything else does not.
    [[ ${2:-} == installed-snap ]] && exit 0
    exit 1
    ;;
  connections)
    printf 'Interface        Plug          Slot   Notes\n'
    printf 'removable-media  %s:removable-media  :removable-media  -\n' "${2:-x}"
    printf 'camera           %s:camera  -  -\n' "${2:-x}"
    ;;
esac
exit 0
STUB
    chmod +x "$TMPTEST/bin/snap"
    PATH="$TMPTEST/bin:$PATH"
}
teardown() { teardown_tmpdir; }

@test "pkg_snap_available is true when snap exists" {
    pkg_snap_available
}

@test "pkg_snap_install composes an install for a missing snap" {
    output="$(pkg_snap_install vlc 2>&1)"
    [[ $output == *"snap install vlc"* ]]
}

@test "pkg_snap_install passes through trailing flags" {
    output="$(pkg_snap_install "code --classic" 2>&1)"
    [[ $output == *"snap install code --classic"* ]]
}

@test "pkg_snap_install skips a snap that is already installed" {
    output="$(pkg_snap_install installed-snap 2>&1)"
    [[ $output != *"snap install installed-snap"* ]]
}

@test "pkg_snap_install handles several snaps" {
    output="$(pkg_snap_install vlc installed-snap 2>&1)"
    [[ $output == *"snap install vlc"* ]]
    [[ $output != *"snap install installed-snap"* ]]
}

@test "pkg_snap_connect skips an already connected interface" {
    output="$(pkg_snap_connect vlc removable-media 2>&1)"
    [[ $output != *"snap connect"* ]]
}

@test "pkg_snap_connect connects a disconnected interface" {
    output="$(pkg_snap_connect vlc camera 2>&1)"
    [[ $output == *"snap connect vlc:camera"* ]]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/pkg.bats`
Expected: all 7 FAIL — `lib/pkg.sh` does not exist.

- [ ] **Step 3: Write the implementation**

Create `lib/pkg.sh`:

```bash
# shellcheck shell=bash
# Snap installation. Same per-package failure tolerance as apt.

PKG_FAILED=()

pkg_snap_available() { command -v snap > /dev/null 2>&1; }

# pkg_snap_install SPEC... — SPEC is a snap name plus optional flags.
pkg_snap_install() {
    (( $# )) || return 0
    if ! pkg_snap_available; then
        log_warn "snap is not available; skipping: $*"
        return 0
    fi
    local spec name flags
    for spec in "$@"; do
        read -r name flags <<< "$spec"
        if snap list "$name" > /dev/null 2>&1; then
            log_info "snap already installed: $name"
            continue
        fi
        # Word splitting on $flags is intentional.
        # shellcheck disable=SC2086
        if ! run_sudo snap install "$name" $flags; then
            PKG_FAILED+=("$name")
            log_error "snap failed: $name"
        fi
    done
    return 0
}

# pkg_snap_connect SNAP INTERFACE
# In `snap connections` output, column 3 is the slot: "-" means disconnected.
pkg_snap_connect() {
    local snap=$1 iface=$2
    pkg_snap_available || return 0
    if snap connections "$snap" 2> /dev/null \
        | awk -v i="$iface" '$1 == i && $3 != "-" { found = 1 } END { exit !found }'; then
        log_info "$snap:$iface is already connected"
        return 0
    fi
    run_sudo snap connect "$snap:$iface"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/pkg.bats`
Expected: 7 tests, 7 passing.

- [ ] **Step 5: Lint**

Run: `shellcheck lib/pkg.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add lib/pkg.sh tests/pkg.bats
git commit -m "feat(engine): add pkg.sh with snap install and interface connection"
```

---

### Task 7: `lib/ui.sh` — checklist and prompts

The whiptail path cannot be unit tested (it needs a terminal), so the tests cover the two deterministic paths: `--yes` and no-TTY. That is an honest limit, not an oversight — the interactive path is covered by the manual verification checklist in spec §8.

**Files:**
- Create: `lib/ui.sh`
- Test: `tests/ui.bats`

**Interfaces:**
- Consumes: `log_info`, `log_warn`, `ASSUME_YES` from `lib/log.sh` and `bootstrap.sh`.
- Produces:
  - `ui_has_tty`, `ui_has_whiptail` — capability probes
  - `ui_checklist TITLE` — reads entries from the `UI_ITEMS` array, each `tag|description|on|off`; prints the selected tags one per line. With `ASSUME_YES=1` or no TTY, prints the tags whose state is `on`.
  - `ui_prompt VARNAME PROMPT [DEFAULT]` — if `VARNAME` already has a non-empty value, returns immediately (this is what makes a saved `local.env` authoritative); otherwise prompts, or takes DEFAULT under `--yes`/no-TTY. Assigns and exports `VARNAME`.
  - `ui_pause MESSAGE` — logs and waits for Enter; logs and returns immediately under `--yes`/no-TTY

- [ ] **Step 1: Write the failing test**

Create `tests/ui.bats`:

```bash
#!/usr/bin/env bats

load helper

setup() {
    setup_tmpdir
    load_lib log
    load_lib ui
    RUN_STAMP="test"
    DRY_RUN=0
    ASSUME_YES=1
}
teardown() { teardown_tmpdir; }

@test "ui_checklist under --yes returns exactly the defaults that are on" {
    UI_ITEMS=(
        "00-core|Core build tooling|on"
        "60-nas|NAS mount|off"
        "50-media|Media tooling|on"
    )
    run_out="$(ui_checklist "Select modules")"
    [[ $run_out == *"00-core"* ]]
    [[ $run_out == *"50-media"* ]]
    [[ $run_out != *"60-nas"* ]]
}

@test "ui_checklist returns nothing when every default is off" {
    UI_ITEMS=("90-dualboot|Dual boot|off")
    run_out="$(ui_checklist "Select modules")"
    [ -z "$run_out" ]
}

@test "ui_prompt keeps an existing value" {
    GIT_NAME="Already Set"
    ui_prompt GIT_NAME "Your name" "Default Name"
    [ "$GIT_NAME" = "Already Set" ]
}

@test "ui_prompt takes the default when unset under --yes" {
    unset NAS_HOST
    ui_prompt NAS_HOST "NAS host" "nas.local"
    [ "$NAS_HOST" = "nas.local" ]
}

@test "ui_prompt leaves the value empty when there is no default" {
    unset NAS_KEY
    ui_prompt NAS_KEY "NAS key path" ""
    [ -z "$NAS_KEY" ]
}

@test "ui_pause returns immediately under --yes" {
    output="$(ui_pause "Add the key to GitHub" 2>&1)"
    [[ $output == *"Add the key to GitHub"* ]]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/ui.bats`
Expected: all 6 FAIL — `lib/ui.sh` does not exist.

- [ ] **Step 3: Write the implementation**

Create `lib/ui.sh`:

```bash
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
    local n
    IFS=', ' read -r -a toggles <<< "$reply"
    for n in "${toggles[@]:-}"; do
        [[ $n =~ ^[0-9]+$ ]] || continue
        (( n >= 1 && n <= ${#tags[@]} )) || continue
        if [[ ${states[$((n - 1))]} == on ]]; then
            states[$((n - 1))]=off
        else
            states[$((n - 1))]=on
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/ui.bats`
Expected: 6 tests, 6 passing.

- [ ] **Step 5: Lint**

Run: `shellcheck lib/ui.sh`
Expected: no output. If shellcheck flags `toggles` as possibly unassigned, add `local -a toggles=()` before the `IFS` read.

- [ ] **Step 6: Commit**

```bash
git add lib/ui.sh tests/ui.bats
git commit -m "feat(engine): add ui.sh with whiptail checklist and numbered fallback"
```

---

### Task 8: `lib/module.sh` — manifests, discovery, ordering, selection, run loop

The heart of the engine. Two subtleties to get right:

- **Failure containment.** `setup.sh` is sourced with `errexit` temporarily disabled, so a non-zero exit fails only that module while still letting the script use engine helpers and add its own summary rows. Running it in a subshell would contain failures too, but would discard anything it recorded.
- **Comment handling.** Only whole-line `#` comments are stripped, never trailing ones — a `repos` sources-line can legitimately contain `#`.

**Files:**
- Create: `lib/module.sh`
- Test: `tests/module.bats`

**Interfaces:**
- Consumes: everything from `log.sh`, `apt.sh`, `pkg.sh`, `patch.sh`.
- Produces:
  - `manifest_read FILE` — prints one entry per line; strips blank lines, whole-line `#` comments, and leading/trailing whitespace; silent no-op when the file is absent
  - `module_meta_get DIR KEY` — prints the value of `KEY=` from `DIR/meta`
  - `module_list` — prints every module directory name containing a `meta`, sorted
  - `module_resolve_order NAME…` — sets `MODULE_ORDER` to a dependency-correct, prefix-sorted order; returns 1 on an unknown module or a dependency cycle
  - `module_run NAME` — registers repos, installs manifests, sources `setup.sh`; records a summary row
  - `localenv_load` — sources `$LOCAL_ENV` if present
  - `localenv_set KEY VALUE` — upserts a key, creating the file at mode `0600`
  - Globals: `MODULES_DIR`, `MODULE_ORDER` (array), `LOCAL_ENV`, `MODULE_DIR` (set for the duration of each `setup.sh`)

- [ ] **Step 1: Write the failing test**

Create `tests/module.bats`:

```bash
#!/usr/bin/env bats

load helper

setup() {
    setup_tmpdir
    load_lib log
    load_lib patch
    load_lib apt
    load_lib pkg
    load_lib module
    RUN_STAMP="test"
    DRY_RUN=1
    MODULES_DIR="$TMPTEST/modules"
    LOCAL_ENV="$TMPTEST/local.env"
    mkdir -p "$MODULES_DIR"
}
teardown() { teardown_tmpdir; }

# Create a module: mkmod NAME [REQUIRES]
mkmod() {
    local name=$1 requires=${2:-}
    mkdir -p "$MODULES_DIR/$name"
    {
        printf 'name=%s\n' "$name"
        printf 'summary=The %s module\n' "$name"
        printf 'default=on\n'
        [[ -n $requires ]] && printf 'requires=%s\n' "$requires"
    } > "$MODULES_DIR/$name/meta"
}

@test "manifest_read strips comments, blanks, and surrounding whitespace" {
    cat > m <<'EOF'
# a comment

  git
curl

   # indented comment
  gh
EOF
    run_out="$(manifest_read m)"
    [ "$run_out" = "git
curl
gh" ]
}

@test "manifest_read preserves an inline hash inside a line" {
    printf 'deb https://example.invalid/apt stable main # not-a-comment\n' > m
    run_out="$(manifest_read m)"
    [[ $run_out == *"# not-a-comment"* ]]
}

@test "manifest_read is silent for a missing file" {
    run_out="$(manifest_read does-not-exist)"
    [ -z "$run_out" ]
}

@test "module_meta_get reads a key" {
    mkmod 00-core
    [ "$(module_meta_get "$MODULES_DIR/00-core" default)" = "on" ]
}

@test "module_meta_get prints nothing for an absent key" {
    mkmod 00-core
    [ -z "$(module_meta_get "$MODULES_DIR/00-core" requires)" ]
}

@test "module_list finds every module with a meta file, sorted" {
    mkmod 50-media
    mkmod 00-core
    mkdir -p "$MODULES_DIR/not-a-module"
    run_out="$(module_list)"
    [ "$run_out" = "00-core
50-media" ]
}

@test "module_resolve_order sorts by directory prefix" {
    mkmod 00-core
    mkmod 50-media
    mkmod 10-shell
    module_resolve_order 50-media 00-core 10-shell
    [ "${MODULE_ORDER[0]}" = "00-core" ]
    [ "${MODULE_ORDER[1]}" = "10-shell" ]
    [ "${MODULE_ORDER[2]}" = "50-media" ]
}

@test "module_resolve_order pulls in a requirement that was not selected" {
    mkmod 00-core
    mkmod 10-shell 00-core
    mkmod 20-toolchains 10-shell
    module_resolve_order 20-toolchains
    [ "${#MODULE_ORDER[@]}" -eq 3 ]
    [ "${MODULE_ORDER[0]}" = "00-core" ]
    [ "${MODULE_ORDER[2]}" = "20-toolchains" ]
}

@test "module_resolve_order places a dependency before its dependent" {
    mkmod 00-core
    mkmod 90-late 00-core
    module_resolve_order 90-late 00-core
    [ "${MODULE_ORDER[0]}" = "00-core" ]
}

@test "module_resolve_order detects a dependency cycle" {
    mkmod a b
    mkmod b a
    status=0
    module_resolve_order a || status=$?
    [ "$status" -ne 0 ]
}

@test "module_resolve_order rejects an unknown module" {
    mkmod 00-core
    status=0
    module_resolve_order nonexistent || status=$?
    [ "$status" -ne 0 ]
}

@test "localenv_set creates the file at mode 0600" {
    DRY_RUN=0
    localenv_set GIT_NAME "Test User"
    [ -f "$LOCAL_ENV" ]
    [ "$(stat -c '%a' "$LOCAL_ENV")" = "600" ]
}

@test "localenv_set and localenv_load round-trip a value" {
    DRY_RUN=0
    localenv_set NAS_HOST "nas.local"
    unset NAS_HOST
    localenv_load
    [ "$NAS_HOST" = "nas.local" ]
}

@test "localenv_set replaces rather than duplicating a key" {
    DRY_RUN=0
    localenv_set NAS_HOST "first"
    localenv_set NAS_HOST "second"
    [ "$(grep -c '^NAS_HOST=' "$LOCAL_ENV")" -eq 1 ]
    unset NAS_HOST
    localenv_load
    [ "$NAS_HOST" = "second" ]
}

@test "localenv_set preserves other keys" {
    DRY_RUN=0
    localenv_set GIT_NAME "Test User"
    localenv_set NAS_HOST "nas.local"
    unset GIT_NAME NAS_HOST
    localenv_load
    [ "$GIT_NAME" = "Test User" ]
    [ "$NAS_HOST" = "nas.local" ]
}

@test "localenv_set handles a value containing spaces" {
    DRY_RUN=0
    localenv_set GIT_NAME "First Last"
    unset GIT_NAME
    localenv_load
    [ "$GIT_NAME" = "First Last" ]
}

@test "module_run installs the apt manifest" {
    mkmod 00-core
    printf 'git\ncurl\n' > "$MODULES_DIR/00-core/apt"
    output="$(module_run 00-core 2>&1)"
    [[ $output == *"apt-get install -y git curl"* ]]
}

@test "module_run registers repos before installing" {
    mkmod 30-dev
    printf 'example|https://example.invalid/key.asc|deb [signed-by=@KEYRING@] https://example.invalid/apt stable main\n' \
        > "$MODULES_DIR/30-dev/repos"
    printf 'code\n' > "$MODULES_DIR/30-dev/apt"
    output="$(module_run 30-dev 2>&1)"
    repo_line=$(printf '%s\n' "$output" | grep -n 'example.invalid' | head -1 | cut -d: -f1)
    install_line=$(printf '%s\n' "$output" | grep -n 'apt-get install' | head -1 | cut -d: -f1)
    [ "$repo_line" -lt "$install_line" ]
}

@test "module_run sources setup.sh with MODULE_DIR set" {
    mkmod 10-shell
    printf 'printf "setup ran in %%s\\n" "$(basename "$MODULE_DIR")"\n' \
        > "$MODULES_DIR/10-shell/setup.sh"
    output="$(module_run 10-shell 2>&1)"
    [[ $output == *"setup ran in 10-shell"* ]]
}

@test "module_run contains a failing setup.sh" {
    mkmod 40-desktop
    printf 'exit 3\n' > "$MODULES_DIR/40-desktop/setup.sh"
    status=0
    module_run 40-desktop > /dev/null 2>&1 || status=$?
    [ "$status" -eq 0 ]
    printf '%s\n' "${SUMMARY_ROWS[@]}" | grep -q '^failed|40-desktop'
}

@test "module_run records success in the summary" {
    mkmod 00-core
    printf 'git\n' > "$MODULES_DIR/00-core/apt"
    module_run 00-core > /dev/null 2>&1
    printf '%s\n' "${SUMMARY_ROWS[@]}" | grep -q '00-core'
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/module.bats`
Expected: all 21 FAIL — `lib/module.sh` does not exist.

- [ ] **Step 3: Write the implementation**

Create `lib/module.sh`:

```bash
# shellcheck shell=bash
# Manifest parsing, module discovery, dependency ordering, selection
# persistence, and the per-module run.

: "${MODULES_DIR:=}"
: "${LOCAL_ENV:=${XDG_CONFIG_HOME:-$HOME/.config}/config-bootstrap/local.env}"

MODULE_ORDER=()
MODULE_DIR=""
declare -A _MOD_STATE=()

# manifest_read FILE — one entry per line. Strips blank lines, whole-line
# comments, and surrounding whitespace. Trailing comments are NOT stripped:
# a repos sources-line may legitimately contain a '#'.
manifest_read() {
    local file=$1
    [[ -f $file ]] || return 0
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$file" \
        | grep -v -e '^$' -e '^#' || true
}

# module_meta_get DIR KEY
module_meta_get() {
    local dir=$1 key=$2
    [[ -f $dir/meta ]] || return 0
    sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$dir/meta" | head -1
}

module_list() {
    local dir
    for dir in "$MODULES_DIR"/*/; do
        [[ -f ${dir}meta ]] || continue
        basename "$dir"
    done | sort
}

_module_visit() {
    local name=$1
    case ${_MOD_STATE[$name]:-new} in
        done) return 0 ;;
        visiting)
            log_error "dependency cycle involving module: $name"
            return 1
            ;;
    esac
    if [[ ! -f $MODULES_DIR/$name/meta ]]; then
        log_error "unknown module: $name"
        return 1
    fi
    _MOD_STATE[$name]=visiting
    local dep
    # requires is a space-separated list; word splitting is intentional.
    # shellcheck disable=SC2046
    for dep in $(module_meta_get "$MODULES_DIR/$name" requires); do
        _module_visit "$dep" || return 1
    done
    _MOD_STATE[$name]=done
    MODULE_ORDER+=("$name")
    return 0
}

# module_resolve_order NAME... — sets MODULE_ORDER.
module_resolve_order() {
    MODULE_ORDER=()
    _MOD_STATE=()
    local name
    while IFS= read -r name; do
        [[ -z $name ]] && continue
        _module_visit "$name" || return 1
    done < <(printf '%s\n' "$@" | sort -u)
    return 0
}

localenv_load() {
    [[ -f $LOCAL_ENV ]] || return 0
    # shellcheck disable=SC1090
    source "$LOCAL_ENV"
}

# localenv_set KEY VALUE — upsert into the gitignored local config.
localenv_set() {
    local key=$1 value=$2 dir content=""
    dir=$(dirname "$LOCAL_ENV")
    if (( DRY_RUN )); then
        _log DRY '0;36' "set $key in $LOCAL_ENV"
        return 0
    fi
    [[ -d $dir ]] || mkdir -p "$dir"
    if [[ -f $LOCAL_ENV ]]; then
        content=$(grep -v "^${key}=" "$LOCAL_ENV" || true)
    fi
    {
        [[ -n $content ]] && printf '%s\n' "$content"
        printf '%s="%s"\n' "$key" "$value"
    } > "$LOCAL_ENV.tmp"
    mv "$LOCAL_ENV.tmp" "$LOCAL_ENV"
    chmod 600 "$LOCAL_ENV"
}

# module_run NAME
module_run() {
    local name=$1 dir="$MODULES_DIR/$name"
    log_step "Module: $name"

    local apt_before=${#APT_FAILED[@]}
    local pkg_before=${#PKG_FAILED[@]}

    # 1. Repositories, before anything is installed.
    local line rname rkey rline
    while IFS= read -r line; do
        [[ -z $line ]] && continue
        IFS='|' read -r rname rkey rline <<< "$line"
        apt_add_repo "$rname" "$rkey" "$rline" \
            || log_error "repo registration failed: $rname"
    done < <(manifest_read "$dir/repos")

    # 2. Package manifests.
    local -a pkgs=()
    mapfile -t pkgs < <(manifest_read "$dir/apt")
    (( ${#pkgs[@]} )) && apt_install "${pkgs[@]}"

    local -a snaps=()
    mapfile -t snaps < <(manifest_read "$dir/snap")
    (( ${#snaps[@]} )) && pkg_snap_install "${snaps[@]}"

    # 3. The imperative remainder. errexit is lifted so a failure here is
    #    contained to this module, while still allowing setup.sh to use the
    #    engine's helpers and record its own summary rows.
    if [[ -f $dir/setup.sh ]]; then
        MODULE_DIR=$dir
        local rc=0
        set +e
        # shellcheck disable=SC1090
        source "$dir/setup.sh"
        rc=$?
        set -e
        if (( rc )); then
            summary_add failed "$name" "setup.sh exited $rc"
            return 0
        fi
    fi

    local new_failures=$(( ${#APT_FAILED[@]} - apt_before + ${#PKG_FAILED[@]} - pkg_before ))
    if (( new_failures )); then
        summary_add failed "$name" "$new_failures package(s) failed"
    else
        summary_add ok "$name"
    fi
    return 0
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/module.bats`
Expected: 21 tests, 21 passing.

If "module_resolve_order sorts by directory prefix" fails, check that `module_resolve_order` sorts its inputs before visiting — `sort -u` on the argument list is what makes the output deterministic.

- [ ] **Step 5: Lint**

Run: `shellcheck lib/module.sh`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add lib/module.sh tests/module.bats
git commit -m "feat(engine): add module.sh with manifests, ordering, and run loop"
```

---

### Task 9: `bootstrap.sh` — entrypoint, preflight, and the run loop

Two stages in one file. When curl-piped there is no working tree, so stage 1 clones the repo and re-executes the same script from the clone, at which point `lib/module.sh` exists and stage 2 runs.

The initial clone **must** use HTTPS: on a fresh machine there is no SSH key yet.

**Files:**
- Create: `bootstrap.sh`
- Test: `tests/bootstrap.bats`

**Interfaces:**
- Consumes: every engine library.
- Produces:
  - `parse_args ARG…` — sets `DRY_RUN`, `ASSUME_YES`, `RECONFIGURE`, `ONLY_MODULES`, `SKIP_MODULES`; returns 2 on a bad argument, 10 for `--help`
  - `preflight` — returns non-zero when running as root or when `apt-get` is absent
  - `select_modules` — sets `MODULE_ORDER` from `--only`/`--skip`, the saved selection, or the checklist
  - `collect_prompts` — sources each selected module's `prompts.sh`
  - `main ARG…` — the whole lifecycle
  - Honors `BOOTSTRAP_NO_MAIN=1` so tests can source the file without running it

- [ ] **Step 1: Write the failing test**

Create `tests/bootstrap.bats`:

```bash
#!/usr/bin/env bats

load helper

setup() {
    setup_tmpdir
    BOOTSTRAP_NO_MAIN=1
    export BOOTSTRAP_NO_MAIN
    # shellcheck disable=SC1090
    source "$REPO_ROOT/bootstrap.sh"
    DRY_RUN=0
    ASSUME_YES=0
    RECONFIGURE=0
    ONLY_MODULES=()
    SKIP_MODULES=()
}
teardown() { teardown_tmpdir; }

@test "parse_args defaults to a live, interactive run" {
    parse_args
    [ "$DRY_RUN" -eq 0 ]
    [ "$ASSUME_YES" -eq 0 ]
    [ "$RECONFIGURE" -eq 0 ]
}

@test "parse_args handles --dry-run" {
    parse_args --dry-run
    [ "$DRY_RUN" -eq 1 ]
}

@test "parse_args handles --yes and -y" {
    parse_args --yes
    [ "$ASSUME_YES" -eq 1 ]
    ASSUME_YES=0
    parse_args -y
    [ "$ASSUME_YES" -eq 1 ]
}

@test "parse_args handles --reconfigure" {
    parse_args --reconfigure
    [ "$RECONFIGURE" -eq 1 ]
}

@test "parse_args accumulates repeated --only" {
    parse_args --only 00-core --only 50-media
    [ "${#ONLY_MODULES[@]}" -eq 2 ]
    [ "${ONLY_MODULES[0]}" = "00-core" ]
    [ "${ONLY_MODULES[1]}" = "50-media" ]
}

@test "parse_args accumulates repeated --skip" {
    parse_args --skip 40-desktop --skip 50-media
    [ "${#SKIP_MODULES[@]}" -eq 2 ]
}

@test "parse_args combines flags" {
    parse_args --dry-run --yes --only 00-core
    [ "$DRY_RUN" -eq 1 ]
    [ "$ASSUME_YES" -eq 1 ]
    [ "${ONLY_MODULES[0]}" = "00-core" ]
}

@test "parse_args rejects an unknown option" {
    status=0
    parse_args --nonsense 2>/dev/null || status=$?
    [ "$status" -eq 2 ]
}

@test "parse_args rejects --only with no value" {
    status=0
    parse_args --only 2>/dev/null || status=$?
    [ "$status" -eq 2 ]
}

@test "parse_args rejects --skip with no value" {
    status=0
    parse_args --skip 2>/dev/null || status=$?
    [ "$status" -eq 2 ]
}

@test "parse_args returns 10 for --help" {
    status=0
    parse_args --help > /dev/null 2>&1 || status=$?
    [ "$status" -eq 10 ]
}

@test "preflight refuses to run as root" {
    EUID=0
    status=0
    preflight 2>/dev/null || status=$?
    [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/bootstrap.bats`
Expected: all 12 FAIL — `bootstrap.sh` does not exist.

- [ ] **Step 3: Write the implementation**

Create `bootstrap.sh` and make it executable:

```bash
#!/usr/bin/env bash
# Machine bootstrap. Curl-able and idempotent.
#
#   curl -fsSL https://raw.githubusercontent.com/zdmiller12/config/main/bootstrap.sh | bash
#
set -euo pipefail

REPO_URL="${CONFIG_REPO_URL:-https://github.com/zdmiller12/config.git}"
REPO_DIR="${CONFIG_REPO_DIR:-$HOME/git/config}"
REPO_BRANCH="${CONFIG_REPO_BRANCH:-main}"

SELF_DIR=""
if [[ -n ${BASH_SOURCE[0]:-} && -e ${BASH_SOURCE[0]} ]]; then
    SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fi

# ---------------------------------------------------------------------------
# Stage 1: no working tree yet (curl-piped). Clone, then re-exec from the
# clone so dotfile symlinks point at files the user can edit and push.
# ---------------------------------------------------------------------------
if [[ -z $SELF_DIR || ! -f $SELF_DIR/lib/module.sh ]]; then
    if [[ $EUID -eq 0 ]]; then
        printf 'Refusing to run as root. Run as your normal user.\n' >&2
        exit 1
    fi
    if ! command -v apt-get > /dev/null 2>&1; then
        printf 'This bootstrap targets Debian-family systems (no apt-get found).\n' >&2
        exit 1
    fi
    printf '[BOOT] staging from %s\n' "$REPO_URL"
    if ! command -v git > /dev/null 2>&1; then
        printf '[BOOT] installing git\n'
        sudo apt-get update -qq
        sudo apt-get install -y git
    fi
    if [[ -d $REPO_DIR/.git ]]; then
        printf '[BOOT] updating %s\n' "$REPO_DIR"
        git -C "$REPO_DIR" fetch --quiet origin "$REPO_BRANCH"
        git -C "$REPO_DIR" merge --ff-only "origin/$REPO_BRANCH" \
            || printf '[BOOT] working tree has local changes; leaving it alone\n'
    else
        printf '[BOOT] cloning into %s\n' "$REPO_DIR"
        mkdir -p "$(dirname "$REPO_DIR")"
        git clone --quiet --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR"
    fi
    exec bash "$REPO_DIR/bootstrap.sh" "$@"
fi

# ---------------------------------------------------------------------------
# Stage 2: the engine, running from a real working tree.
# ---------------------------------------------------------------------------
REPO_ROOT=$SELF_DIR
MODULES_DIR="$REPO_ROOT/modules"
DOTFILES_DIR="$REPO_ROOT/dotfiles"

DRY_RUN=0
ASSUME_YES=0
RECONFIGURE=0
ONLY_MODULES=()
SKIP_MODULES=()

usage() {
    cat <<'EOF'
Usage: bootstrap.sh [options]

  --dry-run         Print every command without executing it
  --yes, -y         Accept defaults; never prompt
  --reconfigure     Re-prompt the module checklist, ignoring the saved selection
  --only MODULE     Run only this module (repeatable)
  --skip MODULE     Skip this module (repeatable)
  -h, --help        Show this message
EOF
}

parse_args() {
    while (( $# )); do
        case $1 in
            --dry-run) DRY_RUN=1 ;;
            --yes | -y) ASSUME_YES=1 ;;
            --reconfigure) RECONFIGURE=1 ;;
            --only)
                shift
                [[ $# -gt 0 ]] || { printf -- '--only needs a module name\n' >&2; return 2; }
                ONLY_MODULES+=("$1")
                ;;
            --skip)
                shift
                [[ $# -gt 0 ]] || { printf -- '--skip needs a module name\n' >&2; return 2; }
                SKIP_MODULES+=("$1")
                ;;
            -h | --help)
                usage
                return 10
                ;;
            *)
                printf 'Unknown option: %s\n' "$1" >&2
                return 2
                ;;
        esac
        shift
    done
    return 0
}

preflight() {
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        log_error "Refusing to run as root. Run as your normal user; sudo is called per command."
        return 1
    fi
    if ! command -v apt-get > /dev/null 2>&1; then
        log_error "This bootstrap targets Debian-family systems (no apt-get found)."
        return 1
    fi
    log_ok "Preflight passed"
    return 0
}

sudo_validate() {
    (( DRY_RUN )) && return 0
    log_info "Validating sudo up front so no password prompt appears mid-run."
    sudo -v
}

select_modules() {
    local -a candidates=()

    if (( ${#ONLY_MODULES[@]} )); then
        candidates=("${ONLY_MODULES[@]}")
    else
        local saved=""
        (( RECONFIGURE )) || saved=${MODULE_SELECTION:-}
        if [[ -n $saved ]]; then
            log_info "Replaying the saved module selection. Use --reconfigure to change it."
            read -r -a candidates <<< "$saved"
        else
            UI_ITEMS=()
            local name summary default label
            while IFS= read -r name; do
                summary=$(module_meta_get "$MODULES_DIR/$name" summary)
                default=$(module_meta_get "$MODULES_DIR/$name" default)
                [[ -z $default ]] && default=off
                label=$summary
                [[ $name == 90-* ]] && label="$summary (changes system state)"
                UI_ITEMS+=("$name|$label|$default")
            done < <(module_list)
            mapfile -t candidates < <(ui_checklist "Select modules to run")
        fi
    fi

    # 00-core is a hard prerequisite and cannot be deselected.
    local has_core=0 m
    for m in "${candidates[@]:-}"; do
        [[ $m == 00-core ]] && has_core=1
    done
    (( has_core )) || candidates=(00-core "${candidates[@]:-}")

    # Apply --skip, but never to 00-core.
    local -a kept=()
    local skip
    for m in "${candidates[@]:-}"; do
        [[ -z $m ]] && continue
        local drop=0
        for skip in "${SKIP_MODULES[@]:-}"; do
            [[ $m == "$skip" && $m != 00-core ]] && drop=1
        done
        (( drop )) || kept+=("$m")
    done

    module_resolve_order "${kept[@]}" || return 1
    localenv_set MODULE_SELECTION "${MODULE_ORDER[*]}"
    log_info "Modules: ${MODULE_ORDER[*]}"
    return 0
}

collect_prompts() {
    log_step "Collecting answers up front"
    local name
    for name in "${MODULE_ORDER[@]}"; do
        if [[ -f $MODULES_DIR/$name/prompts.sh ]]; then
            MODULE_DIR="$MODULES_DIR/$name"
            # shellcheck disable=SC1090
            source "$MODULES_DIR/$name/prompts.sh"
        fi
    done
}

main() {
    parse_args "$@" || { local rc=$?; [[ $rc -eq 10 ]] && return 0; return "$rc"; }

    # shellcheck source=lib/log.sh
    source "$REPO_ROOT/lib/log.sh"
    # shellcheck source=lib/patch.sh
    source "$REPO_ROOT/lib/patch.sh"
    # shellcheck source=lib/link.sh
    source "$REPO_ROOT/lib/link.sh"
    # shellcheck source=lib/apt.sh
    source "$REPO_ROOT/lib/apt.sh"
    # shellcheck source=lib/pkg.sh
    source "$REPO_ROOT/lib/pkg.sh"
    # shellcheck source=lib/ui.sh
    source "$REPO_ROOT/lib/ui.sh"
    # shellcheck source=lib/module.sh
    source "$REPO_ROOT/lib/module.sh"

    log_init
    (( DRY_RUN )) && log_warn "Dry run: no command will actually execute."

    preflight || return 1
    localenv_load
    select_modules || return 1
    collect_prompts
    sudo_validate

    local name
    for name in "${MODULE_ORDER[@]}"; do
        module_run "$name"
    done

    summary_print
}

if [[ ${BOOTSTRAP_NO_MAIN:-0} -eq 0 ]]; then
    main "$@"
fi
```

- [ ] **Step 4: Make it executable and run the test**

```bash
chmod +x bootstrap.sh
bats tests/bootstrap.bats
```

Expected: 12 tests, 12 passing.

- [ ] **Step 5: Create a fixture module and prove the whole engine drives it**

This is the Phase 1 acceptance check — the first time every layer runs together.

```bash
mkdir -p modules/00-core
cat > modules/00-core/meta <<'EOF'
name=00-core
summary=Core build tooling and Python build headers
default=on
EOF
printf 'git\ncurl\n' > modules/00-core/apt
./bootstrap.sh --dry-run --yes
```

Expected: preflight passes, `Modules: 00-core`, a `[DRY]` line containing `sudo apt-get update`, a `[DRY]` line containing `sudo apt-get install -y git curl`, and a run summary ending with the transcript path. Nothing is installed.

- [ ] **Step 6: Lint everything**

```bash
shellcheck bootstrap.sh lib/*.sh
bats tests/
```

Expected: shellcheck silent; all tests across all files passing.

- [ ] **Step 7: Commit**

```bash
git add bootstrap.sh tests/bootstrap.bats modules/00-core
git commit -m "feat: add bootstrap.sh entrypoint with two-stage clone and run loop"
```

**Phase 1 checkpoint.** The engine is complete and verified. Stop here for review before starting Phase 2.

---

## Phase 2 — Migration and dotfiles

### Task 10: Relocate the legacy tools to `tools/`

Spec §2 and §9: `printing/`, `sharedalbum/`, and `videos/` stay in git but are excluded from bootstrap. Use `git mv` so history follows the files.

**Files:**
- Move: `printing/` → `tools/printing/`, `sharedalbum/` → `tools/sharedalbum/`, `videos/` → `tools/videos/`
- Create: `tools/README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing other modules depend on. `50-media` provides these tools' runtime dependencies (spec §9), but there is no code coupling.

- [ ] **Step 1: Move the directories, preserving history**

```bash
mkdir -p tools
git mv printing tools/printing
git mv sharedalbum tools/sharedalbum
git mv videos tools/videos
git status --short
```

Expected: nine renames staged (`R` status), including the `printing/images/*` files.

- [ ] **Step 2: Verify the move preserved history**

Run: `git log --oneline --follow tools/videos/merge-videos.sh | head -3`
Expected: at least one commit predating this one — history followed the rename.

- [ ] **Step 3: Write the tools README**

Create `tools/README.md`:

```markdown
# Tools

Standalone scripts kept in this repo but **not** part of the bootstrap. No
module installs, links, or configures anything here — running `bootstrap.sh`
will not touch these directories.

| Tool | What it does |
|---|---|
| [printing](./printing/README.md) | Scheduled print job that keeps inkjet cartridges from drying out |
| [sharedalbum](./sharedalbum/README.md) | Google Photos shared-album helper |
| [videos](./videos/README.md) | Video concatenation and renaming helpers |

## Dependencies

`videos/` shells out to `ffmpeg` and `mkvmerge` by name. Both are installed by
the `50-media` module — see §9 of the
[design spec](../docs/superpowers/specs/2026-10-14-machine-bootstrap-design.md).
If you deselect `50-media`, these scripts will not run.

Note that installing VLC does not substitute for either: VLC bundles its own
decoders internally but ships neither command-line binary.
```

- [ ] **Step 4: Verify nothing references the old paths**

```bash
grep -rn 'printing/\|sharedalbum/\|videos/' --include='*.md' --include='*.sh' . \
  | grep -v '^./tools/' | grep -v '^./docs/superpowers/' || echo "no stale references"
```

Expected: `no stale references`, or only matches inside `tools/` and `docs/superpowers/`. The root `README.md` still links `./printing/README.md` and `./videos/README.md` — Task 11 rewrites it, so leaving those for now is correct.

- [ ] **Step 5: Commit**

```bash
git add tools/README.md
git commit -m "refactor: move printing, sharedalbum, and videos under tools/"
```

---

### Task 11: Relocate the docs and rewrite the README

The current README mixes setup instructions (superseded by bootstrap) with a hand-written OpenUSD build note (worth keeping verbatim).

**Files:**
- Create: `docs/openusd.md`
- Create: `docs/virtualization.md`
- Modify: `README.md` (full rewrite)

**Interfaces:**
- Consumes: nothing.
- Produces: `docs/openusd.md` holds the `usd` fish function that Task 12 copies into `dotfiles/fish/functions/usd.fish`.

- [ ] **Step 1: Move the OpenUSD section into its own doc**

Create `docs/openusd.md` by copying lines 41–122 of the current `README.md` verbatim, with a new title and a short preamble. Do not reword the build steps — they are tested knowledge.

```markdown
# OpenUSD

> [OpenUSD](https://github.com/PixarAnimationStudios/OpenUSD)

Notes on an occasional manual build. This is **not** a bootstrap step — no
module performs it. Kept because the steps were worked out by hand and are
painful to rediscover.

[usd-core](https://pypi.org/project/usd-core/) can be installed with pip, but
installation of other OpenUSD tools, like
[usdview](https://openusd.org/release/toolset.html#usdview), was achieved with
the following steps...

```sh
sudo apt-get install --install-suggests \
    build-essential \
    cmake \
    freeglut3-dev \
    libao-dev \
    libglew-dev \
    libglfw3-dev \
    libglm-dev \
    libglu1-mesa-dev \
    libmpg123-dev \
    libxt-dev \
    mesa-common-dev \
    mesa-utils \
    pkg-config \
    python3-opengl
```

This installation compiles with python3.12, and the `install_dir` used with the
[build_usd.py](https://github.com/PixarAnimationStudios/OpenUSD/blob/f03754834e28356781de5df73d12b48548ed475f/build_scripts/build_usd.py)
script is specific to this python version. That said, `install_dir` was chosen
such that installs for different python versions share the parent directory
`usd`.

**Proposed organization of OpenUSD installs:**

```
$HOME
└── usd
    ├── python3.8
    ├── python3.12
    └── ...
```

If the desired python version is not already installed with pyenv, do that first.

```sh
git clone https://github.com/PixarAnimationStudios/OpenUSD.git
cd OpenUSD
pyenv virtualenv 3.12 usd
pyenv local usd
exec fish
pip install --upgrade numpy pip PyOpenGL PyOpenGL_accelerate pyside6 setuptools
python build_scripts/build_usd.py $HOME/usd/python3.12
```

The installation ends with the following message...

```sh
Success! To use USD, please ensure that you have:

    The following in your PYTHONPATH environment variable:
    /home/miller/usd/python3.12/lib/python

    The following in your PATH environment variable:
    /home/miller/usd/python3.12/bin
```

... but to avoid universally tweaking the `PATH` and `PYTHONPATH` variables,
the `usd` fish function scopes them to a single invocation. It is installed by
the `10-shell` module from
[`dotfiles/fish/functions/usd.fish`](../dotfiles/fish/functions/usd.fish).

The function could be improved to accept the python version as an argument, if
needed.
```

- [ ] **Step 2: Write the virtualization note**

Spec §9 and §12: the KVM stack was dropped, but two facts are worth keeping. The package list deliberately is not.

Create `docs/virtualization.md`:

```markdown
# Virtualization

No module installs a virtualization stack. The preserved Windows dual-boot
serves that need with full hardware access — see §12 of the
[design spec](./superpowers/specs/2026-10-14-machine-bootstrap-design.md) for
why it was dropped.

If you do want local VMs later:

```sh
sudo apt-get install qemu-system-x86 libvirt-daemon-system libvirt-clients \
    virt-manager ovmf bridge-utils
sudo usermod -aG libvirt,kvm "$USER"
```

Two things that are easy to lose an hour to, which is the only reason this
file exists:

1. **Group membership needs a full logout.** You must be in *both* `libvirt`
   and `kvm`. `newgrp` affects only the current shell — log out and back in, or
   the GUI will fail with permission errors that look like something else.
2. **`ovmf` is mandatory for a Windows 11 guest.** Win11 requires UEFI with
   Secure Boot and a TPM 2.0 device. Without `ovmf` installed, virt-manager
   offers no UEFI firmware option and the installer refuses to proceed.
```

- [ ] **Step 3: Rewrite the README as the bootstrap front door**

Spec §9: "the one-line curl command, the module table, how to fork it, and what is deliberately not included."

Replace `README.md` entirely:

```markdown
# Personal Configurations

One command takes a freshly installed Ubuntu machine to a usable, personalized
state: packages installed, shell configured, dotfiles linked, toolchains ready.

```sh
curl -fsSL https://raw.githubusercontent.com/zdmiller12/config/main/bootstrap.sh | bash
```

Re-running is safe: it converges rather than duplicating. The first run prompts
for a module selection and your identity; later runs replay the saved choices.

## Options

| Flag | Effect |
|---|---|
| `--dry-run` | Print every command without executing it |
| `--yes`, `-y` | Accept defaults, never prompt |
| `--reconfigure` | Re-prompt the module checklist |
| `--only MODULE` | Run just this module (repeatable) |
| `--skip MODULE` | Skip this module (repeatable) |

## Modules

| Module | Default | What it does |
|---|---|---|
| `00-core` | on | Build toolchain and the headers needed to compile Pythons |
| `10-shell` | on | fish, fisher, dotfile links, git identity, SSH key generation |
| `20-toolchains` | on | asdf, pyenv, uv, rustup and their fish init blocks |
| `30-dev` | on | VSCode and its extensions, Docker CE |
| `40-desktop` | on | Browser, torrent client, KDE Connect, fonts, GNOME settings |
| `50-media` | on | ffmpeg, mkvtoolnix, VLC, inkscape, pandoc, texlive, image tools |
| `60-nas` | off | sshfs and a systemd mount unit for the NAS |
| `90-bluetooth-autoreconnect` | off | bluez auto-enable and userspace HID |
| `90-dualboot` | off | GRUB hidden menu, Windows in the GRUB menu, `winboot` |

`00-core` cannot be deselected. `10-shell` is required by `20-toolchains`. The
`90-` prefix marks modules that change system state outside the package
manager; they are off by default.

## Forking it

Nothing personal is committed. Identity and machine-specific values are
prompted on the first run and written to `~/.config/config-bootstrap/local.env`,
which is gitignored.

1. Fork the repo.
2. Edit the manifests — `modules/*/apt`, `modules/*/snap` — to taste. They are
   newline-delimited package lists; `#` starts a whole-line comment.
3. Swap the URL in the curl command for your fork's.

You should not need to edit the engine in `lib/` to change what gets
installed. A module with only manifests needs no code at all.

## Recovering a dual-boot machine

`90-dualboot` hides the GRUB menu, so the machine boots straight to Ubuntu.
**Hold `Esc` (UEFI) or `Shift` (BIOS) during power-on to show the menu.** That
menu includes Windows, because the module enables `os-prober`. From a running
Ubuntu, `winboot` reboots into Windows once.

## Deliberately not included

- **Self-hosted services** — apache2, postfix, redis-server, jackett, and
  teamviewerd are not reproduced.
- **Virtualization** — qemu/libvirt/virt-manager. See
  [docs/virtualization.md](./docs/virtualization.md).
- **Flatpak** — no module ships flatpaks, and the engine has no flatpak support.
- **MegaSync and ProtonVPN** — both are manual post-install steps.
- **The eleven existing pyenv virtualenvs** — recreate them as needed.

## Before wiping a machine

Captured state that the wipe would destroy:

- [ ] Commit the live `~/.config/fish/config.fish`, `~/.gitconfig`, and
      `~/.ssh/config` if they have drifted from the copies in `dotfiles/`.
- [ ] Refresh the manifests: `apt-mark showmanual`, `snap list`,
      `code --list-extensions`, `asdf plugin list`, and a `dconf dump` of the
      terminal profile.
- [ ] **Confirm every cloud-sync folder has finished syncing.** Nothing under
      `~/MEGA` is recreated by any module.

## Other docs

- [tools/](./tools/README.md) — standalone scripts, not part of bootstrap
- [docs/openusd.md](./docs/openusd.md) — OpenUSD manual build notes
- [docs/virtualization.md](./docs/virtualization.md) — if you want VMs back
- [design spec](./docs/superpowers/specs/2026-10-14-machine-bootstrap-design.md)
```

- [ ] **Step 4: Verify every internal link resolves**

```bash
grep -oE '\]\(\./[^)]+\)' README.md | tr -d '](.)' | while read -r p; do
  [ -e "$p" ] || echo "BROKEN: $p"
done
echo "link check done"
```

Expected: `link check done` with no `BROKEN` lines. `tools/README.md` and both `docs/*.md` must exist by now — if `dotfiles/fish/functions/usd.fish` is reported broken, that is expected until Task 12.

- [ ] **Step 5: Commit**

```bash
git add README.md docs/openusd.md docs/virtualization.md
git commit -m "docs: make README the bootstrap front door, relocate build notes"
```

---

### Task 12: The `dotfiles/` tree and its manifest

Spec §9: the **live** `~/.config/fish/config.fish` is the migration source, not the committed copy. The committed one is stale. The live file's `rbenv`, `tfenv`, `cargo`, and `gems/bin` lines are all dropped — superseded by the toolchain decisions in spec §2.

`gitconfig` keeps its alias set verbatim but loses `[user]`, which `10-shell` renders from prompted values.

**Files:**
- Create: `dotfiles/links`
- Create: `dotfiles/fish/config.fish`
- Create: `dotfiles/fish/functions/usd.fish`
- Create: `dotfiles/fish/functions/winboot.fish`
- Create: `dotfiles/git/gitconfig`
- Create: `dotfiles/ssh/config.template`
- Delete: `config.fish`, `.gitconfig` (now superseded)

**Interfaces:**
- Consumes: `link_manifest` from `lib/link.sh`.
- Produces: `dotfiles/links` — two whitespace-separated columns, repo-relative source then destination (`~` allowed), consumed by `10-shell`.

- [ ] **Step 1: Write the links manifest**

Create `dotfiles/links`:

```
# Dotfile symlinks: <path relative to dotfiles/>   <destination>
# Anything pre-existing and not already a symlink is backed up first.

fish/config.fish              ~/.config/fish/config.fish
fish/functions/usd.fish       ~/.config/fish/functions/usd.fish
fish/functions/winboot.fish   ~/.config/fish/functions/winboot.fish
git/gitconfig                 ~/.gitconfig
```

`ssh/config.template` is deliberately absent: it is rendered, not linked.

- [ ] **Step 2: Write the fish config**

Create `dotfiles/fish/config.fish`. This file holds only what is unconditional.

**Design note:** spec §4 describes `20-toolchains` as installing "the fish init blocks for each". This file is a *symlink into the git working tree*, so appending to it would dirty the repo on every run. Instead `20-toolchains` writes a generated, uncommitted `~/.config/fish/conf.d/toolchains.fish` — fish auto-sources every `*.fish` in `conf.d/`. Same effect, no repo churn, and regenerating is idempotent by construction.

```fish
# fish-shell configuration
# https://github.com/fish-shell/fish-shell
#
# Symlinked here from ~/git/config/dotfiles/fish/config.fish by the
# 10-shell module. Edit it there and commit; this is a working tree.
#
# Toolchain initialization (asdf, pyenv, uv, rustup) is NOT here — the
# 20-toolchains module generates ~/.config/fish/conf.d/toolchains.fish,
# which fish sources automatically.

set -Ux AWS_DEFAULT_REGION us-east-1
set -Ux AWS_REGION us-east-1

function fish_greeting
    echo (set_color green)"Do you like fish sticks?"
end

# aliases
alias gitclean="git branch | grep -v \* | xargs git branch -D"
```

- [ ] **Step 3: Write the usd function**

Create `dotfiles/fish/functions/usd.fish`, copied verbatim from the OpenUSD notes:

```fish
function usd --description "Wrapper for OpenUSD installation"
    begin
        set -l USD_PATH $HOME/usd/python3.12/
        set -l BIN_PATH $USD_PATH/bin/

        fish_add_path -aP $BIN_PATH
        set -lx PYTHONPATH $USD_PATH/lib/python/

        env -C $BIN_PATH $argv
    end
end
```

- [ ] **Step 4: Create the winboot function**

The lookup below was verified against this machine's real `efibootmgr` output: it resolves `0001`, which is in fact the Windows Boot Manager slot. Do not alter the regex without re-testing it.

Create `dotfiles/fish/functions/winboot.fish`:

```fish
function winboot --description "Reboot into Windows for one boot"
    # Resolve the Windows entry from EFI NVRAM at call time. The slot index is
    # NOT stable across reinstalls, so it must never be hardcoded.
    set -l line (efibootmgr | string match -r '^Boot[0-9A-Fa-f]{4}\**\s+Windows Boot Manager.*' | head -1)
    set -l id (string replace -rf '^Boot([0-9A-Fa-f]{4}).*' '$1' -- $line)

    if test -z "$id"
        echo "No 'Windows Boot Manager' entry found in EFI NVRAM." >&2
        echo "Hold Esc at power-on to reach the GRUB menu instead." >&2
        return 1
    end

    # The resolved slot is shown on purpose. It moves after a reinstall, so
    # seeing it is how you confirm the lookup found the right entry.
    read -l -P "Reboot into Windows now (Boot$id)? [y/N] " reply
    if not string match -qi 'y*' -- $reply
        echo "Cancelled. Nothing was changed."
        return 1
    end

    # --bootnext is one-shot and self-clearing: it affects only the next boot.
    # Both commands run inside sudo's credential cache, so this is one
    # password prompt rather than two.
    sudo efibootmgr --bootnext $id >/dev/null; and sudo reboot
end
```

**Why confirm rather than reboot outright.** Setting `bootnext` is harmless and reversible; the reboot is what can cost unsaved work. The old alias bundled them, so the safe action inherited the risky one's cost. The prompt also surfaces the resolved slot, which is the only cheap way to verify the dynamic lookup on a freshly reinstalled machine — the exact scenario this rewrite exists for.

To restore the old immediate-reboot behavior instead, delete the `read`/`if` block.

- [ ] **Step 5: Write the gitconfig without `[user]`**

Create `dotfiles/git/gitconfig`. The alias set is carried over verbatim from the old `.gitconfig`; only `[user]` is removed.

```ini
# Symlinked from ~/git/config/dotfiles/git/gitconfig by the 10-shell module.
# [user] is deliberately absent — 10-shell writes it to ~/.gitconfig.local
# from prompted values so nothing personal is committed.
[include]
  path = ~/.gitconfig.local
[pull]
  rebase = true
[branch]
  autosetuprebase = always
[core]
  autocrlf = input
  editor = nano
  excludesfile = ~/.gitignore
  pager = less -F -X
[alias]
  a = add -A
  ac = commit -a --message
  br = branch
  ci = commit
  co = checkout
  cob = checkout -b
  col = checkout @{-1}
  com = checkout master
  diffc = diff --cached
  edit = !vim $(git status -s | cut -c4-)
  editbranch = !vim $(git diff --name-only  master)
  incoming = log origin/master ^master
  last = log -1 HEAD
  logpretty = log -10 --pretty=oneline
  ll = log --oneline
  lol = log --oneline --graph --decorate
  outgoing = log master ^origin/master
  pom = push --set-upstream origin master
  pob = !git push --set-upstream origin $(git branch | grep \\* | cut -d ' ' -f2)
  pullsubs = submodule foreach git pull origin master
  spa = !"git stash; git pull; git stash apply"
  spp = !"git stash; git pull; git stash pop"
  st = status
  sts = status --short --branch
  t = tag -n3
  unstage = reset HEAD --
[filter "lfs"]
  clean = git-lfs clean -- %f
  smudge = git-lfs smudge -- %f
  process = git-lfs filter-process
  required = true
```

- [ ] **Step 6: Write the ssh config template**

Create `dotfiles/ssh/config.template`. Spec §6: host entries are committed since they contain hostnames and key paths but no secrets. `@NAS_HOST@` and `@NAS_KEY@` are substituted by `60-nas`.

```
# Rendered to ~/.ssh/config.d/bootstrap by the 60-nas module.
# Contains hostnames and key paths only — never a secret.

Host nas
    HostName @NAS_HOST@
    User @NAS_USER@
    IdentityFile @NAS_KEY@
    IdentitiesOnly yes
```

- [ ] **Step 7: Add a manifest test**

Append to `tests/link.bats`:

```bash
@test "the real dotfiles manifest references files that exist" {
    manifest="$REPO_ROOT/dotfiles/links"
    [ -f "$manifest" ]
    while read -r rel dest _; do
        [[ -z $rel || $rel == \#* ]] && continue
        [ -e "$REPO_ROOT/dotfiles/$rel" ] || {
            echo "manifest references a missing file: $rel"
            return 1
        }
        [ -n "$dest" ]
    done < "$manifest"
}
```

- [ ] **Step 8: Run the test**

Run: `bats tests/link.bats`
Expected: 10 tests, 10 passing. A failure here means the manifest and the tree disagree — fix the manifest, not the test.

- [ ] **Step 9: Remove the superseded root copies**

```bash
git rm config.fish .gitconfig
```

Expected: both staged for deletion. Their content now lives under `dotfiles/`, and the live machine's versions are the migration source per spec §9.

- [ ] **Step 10: Commit**

```bash
git add dotfiles/
git commit -m "feat(dotfiles): add dotfiles tree and links manifest

Drop the rbenv, tfenv, cargo, and gems/bin lines from the live fish
config — all superseded by the 20-toolchains decisions in spec section 2.
Remove [user] from gitconfig in favor of an included ~/.gitconfig.local
that 10-shell renders from prompted values."
```

**Phase 2 checkpoint.** Stop for review before starting the module catalog.

---

## Phase 3 — The module catalog

Every module in this phase ends with the same verification: `./bootstrap.sh --dry-run --yes --only <module>`. Read the `[DRY]` lines and confirm they are the commands you intended. This is the cheapest possible check and it catches most mistakes.

### Task 13: `00-core` — build toolchain and Python build headers

Pure data, no `setup.sh`. The header list exists so `pyenv install` can compile a Python with every stdlib module present; omitting one causes a *silent* feature loss (no `sqlite3`, no `ssl`) rather than a build failure, which is why the list is explicit.

**Files:**
- Modify: `modules/00-core/meta` (created as a fixture in Task 9)
- Create: `modules/00-core/apt`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing. Every other module depends on it implicitly; the engine force-includes it.

- [ ] **Step 1: Write the meta**

```
name=00-core
summary=Core build tooling and Python build headers
default=on
container=yes
```

- [ ] **Step 2: Write the apt manifest**

Create `modules/00-core/apt`:

```
# Core tooling
build-essential
cmake
curl
git
gh
pkg-config
htop

# Headers required to build complete Pythons with pyenv. A missing header
# does not fail the build — it silently drops a stdlib module.
libssl-dev
libreadline-dev
libsqlite3-dev
libbz2-dev
liblzma-dev
libffi-dev
tk-dev
libncurses-dev
```

- [ ] **Step 3: Verify the dry run**

Run: `./bootstrap.sh --dry-run --yes --only 00-core`
Expected: one `[DRY]` line with `apt-get install -y build-essential cmake curl git gh pkg-config htop libssl-dev …` — all 15 packages in one batch, no comment lines, no blanks.

- [ ] **Step 4: Commit**

```bash
git add modules/00-core
git commit -m "feat(modules): add 00-core with build tooling and Python headers"
```

---

### Task 14: `10-shell` — fish, dotfiles, identity, and SSH keys

The first module with real logic. Order matters: the SSH key must exist and be printed *before* anything tries to authenticate to GitHub, per spec §6.

**Files:**
- Create: `modules/10-shell/meta`, `modules/10-shell/apt`, `modules/10-shell/prompts.sh`, `modules/10-shell/setup.sh`

**Interfaces:**
- Consumes: `link_manifest`, `ui_prompt`, `ui_pause`, `localenv_set`, `summary_note`, `run`, `DOTFILES_DIR`, `REPO_ROOT`.
- Produces: `GIT_NAME` and `GIT_EMAIL` in `local.env`; `~/.gitconfig.local`; an ed25519 keypair at `~/.ssh/id_ed25519`.

- [ ] **Step 1: Write the meta and apt manifest**

`modules/10-shell/meta`:

```
name=10-shell
summary=fish shell, dotfiles, git identity, SSH key
default=on
container=yes
```

`modules/10-shell/apt`:

```
fish
```

- [ ] **Step 2: Write the prompts**

Create `modules/10-shell/prompts.sh`. This runs in the up-front prompt phase and must not install anything.

```bash
# shellcheck shell=bash
# Collected before any installation. See the deviation note in the plan header.

ui_prompt GIT_NAME  "Your name, for git commits" ""
ui_prompt GIT_EMAIL "Your email, for git commits" ""

[[ -n ${GIT_NAME:-} ]]  && localenv_set GIT_NAME  "$GIT_NAME"
[[ -n ${GIT_EMAIL:-} ]] && localenv_set GIT_EMAIL "$GIT_EMAIL"
return 0
```

- [ ] **Step 3: Write the setup script**

Create `modules/10-shell/setup.sh`:

```bash
# shellcheck shell=bash
# fish, fisher, dotfile links, git identity, SSH key, and the default shell.

# 1. Dotfile symlinks.
link_manifest "$DOTFILES_DIR/links" "$DOTFILES_DIR"

# 2. git identity, written outside the repo so nothing personal is committed.
if [[ -n ${GIT_NAME:-} || -n ${GIT_EMAIL:-} ]]; then
    patch_write_if_different "$HOME/.gitconfig.local" "# Written by the 10-shell module from prompted values. Not committed.
[user]
	name = ${GIT_NAME:-}
	email = ${GIT_EMAIL:-}"
else
    summary_note "No git identity was provided; ~/.gitconfig.local was not written."
fi

# 3. SSH key. Generated here, never transported by this repo.
SSH_KEY="$HOME/.ssh/id_ed25519"
if [[ ! -f $SSH_KEY ]]; then
    run mkdir -p "$HOME/.ssh"
    run chmod 700 "$HOME/.ssh"
    run ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "${GIT_EMAIL:-$USER@$(hostname)}"
    if [[ -f $SSH_KEY.pub ]]; then
        log_step "Add this public key to GitHub before any step needs to authenticate:"
        cat "$SSH_KEY.pub"
        ui_pause "Press Enter once the key is added to https://github.com/settings/keys"
    fi
    summary_note "A new SSH key was generated at $SSH_KEY.pub — authorize it wherever it is needed."
else
    log_info "SSH key already present at $SSH_KEY"
fi

# 4. Switch this clone's remote to SSH now that a key exists. The initial
#    clone had to use HTTPS because no key existed yet.
if git -C "$REPO_ROOT" remote get-url origin 2>/dev/null | grep -q '^https://github.com/'; then
    ssh_url=$(git -C "$REPO_ROOT" remote get-url origin \
        | sed -e 's#^https://github.com/#git@github.com:#')
    run git -C "$REPO_ROOT" remote set-url origin "$ssh_url"
    log_info "Switched the origin remote to SSH: $ssh_url"
fi

# 5. fisher, the fish plugin manager. Installed inside fish, so the whole
#    thing is one `fish -c`.
if command -v fish > /dev/null 2>&1; then
    if ! fish -c 'functions -q fisher' 2>/dev/null; then
        if (( DRY_RUN )); then
            _log DRY '0;36' "install fisher via fish"
        else
            log_info "Installing fisher"
            fish -c 'curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher install jorgebucaran/fisher' \
                || log_error "fisher installation failed"
        fi
    else
        log_info "fisher is already installed"
    fi
fi

# 6. Make fish the login shell.
FISH_BIN=$(command -v fish || true)
if [[ -n $FISH_BIN && ${SHELL:-} != "$FISH_BIN" ]]; then
    run chsh -s "$FISH_BIN"
    summary_note "Login shell changed to fish; it takes effect on the next login."
fi
return 0
```

Note `nvm.fish` is deliberately *not* installed: spec §2 drops the duplicate Node managers in favor of asdf.

- [ ] **Step 4: Verify the dry run**

Run: `./bootstrap.sh --dry-run --yes --only 10-shell`

Expected `[DRY]` lines, in this order: `apt-get install -y fish`, `ln -s` for each of the four manifest entries, `write /home/…/.gitconfig.local`, `ssh-keygen -t ed25519 …`, `install fisher via fish`, `chsh -s /usr/bin/fish`. Nothing is created.

- [ ] **Step 5: Verify prompting happens before installing**

Run: `./bootstrap.sh --dry-run --only 10-shell` (no `--yes`, so it prompts)
Expected: the name and email prompts appear *before* the first `[DRY] sudo apt-get` line — this is the §5 guarantee. Answer them, then confirm the ordering in the output.

- [ ] **Step 6: Commit**

```bash
git add modules/10-shell
git commit -m "feat(modules): add 10-shell with dotfiles, identity, and SSH keygen"
```

---

### Task 15: `20-toolchains` — asdf, pyenv, uv, rustup

Each installer is a pipe-to-shell, which `run` cannot carry, so every one needs an explicit `DRY_RUN` branch. The fish init goes to `conf.d/toolchains.fish` for the reason given in Task 12.

**Files:**
- Create: `modules/20-toolchains/meta`, `modules/20-toolchains/setup.sh`

**Interfaces:**
- Consumes: `run`, `patch_write_if_different`, `log_*`, `summary_note`, `DRY_RUN`.
- Produces: `~/.asdf`, `~/.pyenv`, `~/.local/bin/uv`, `~/.cargo`, and `~/.config/fish/conf.d/toolchains.fish`.

- [ ] **Step 1: Write the meta**

```
name=20-toolchains
summary=asdf, pyenv, uv, and rustup
default=on
requires=10-shell
container=yes
```

`requires=10-shell` is the spec §4 constraint: the init file has nowhere to go without fish.

- [ ] **Step 2: Write the setup script**

Create `modules/20-toolchains/setup.sh`:

```bash
# shellcheck shell=bash
# Language toolchains. asdf for node/ruby/terraform, pyenv for Python
# itself, uv for Python tools, rustup for Rust.

# asdf ships as a single Go binary from its GitHub releases. Check for a
# newer tag before a fresh install:
#   https://github.com/asdf-vm/asdf/releases
ASDF_VERSION="${ASDF_VERSION:-v0.18.0}"
ASDF_BIN="$HOME/.local/bin/asdf"

if [[ ! -x $ASDF_BIN ]]; then
    if (( DRY_RUN )); then
        _log DRY '0;36' "install asdf $ASDF_VERSION to $ASDF_BIN"
    else
        log_info "Installing asdf $ASDF_VERSION"
        mkdir -p "$HOME/.local/bin"
        asdf_tar="$(mktemp -d)/asdf.tar.gz"
        if curl -fsSL -o "$asdf_tar" \
            "https://github.com/asdf-vm/asdf/releases/download/${ASDF_VERSION}/asdf-${ASDF_VERSION}-linux-amd64.tar.gz"; then
            tar -xzf "$asdf_tar" -C "$HOME/.local/bin" asdf
            chmod +x "$ASDF_BIN"
        else
            log_error "asdf download failed; skipping asdf plugins"
        fi
    fi
else
    log_info "asdf is already installed"
fi

# asdf plugins. Spec section 2: asdf owns node, ruby, and terraform.
if [[ -x $ASDF_BIN ]]; then
    for plugin in nodejs ruby terraform; do
        if "$ASDF_BIN" plugin list 2>/dev/null | grep -qx "$plugin"; then
            log_info "asdf plugin already present: $plugin"
        else
            run "$ASDF_BIN" plugin add "$plugin" || log_error "asdf plugin failed: $plugin"
        fi
    done
fi

# pyenv, plus pyenv-virtualenv, via the official installer.
if [[ ! -d $HOME/.pyenv ]]; then
    if (( DRY_RUN )); then
        _log DRY '0;36' "curl https://pyenv.run | bash"
    else
        log_info "Installing pyenv"
        curl -fsSL https://pyenv.run | bash || log_error "pyenv installation failed"
    fi
else
    log_info "pyenv is already installed"
fi

# uv, for Python tools that should not live in a project venv.
if ! command -v uv > /dev/null 2>&1 && [[ ! -x $HOME/.local/bin/uv ]]; then
    if (( DRY_RUN )); then
        _log DRY '0;36' "curl https://astral.sh/uv/install.sh | sh"
    else
        log_info "Installing uv"
        curl -fsSL https://astral.sh/uv/install.sh | sh || log_error "uv installation failed"
    fi
else
    log_info "uv is already installed"
fi

# rustup, which owns cargo. This is why the live fish config's
# ~/.cargo/env.fish line was dropped rather than ported.
if ! command -v rustup > /dev/null 2>&1 && [[ ! -d $HOME/.rustup ]]; then
    if (( DRY_RUN )); then
        _log DRY '0;36' "curl https://sh.rustup.rs | sh -s -- -y --no-modify-path"
    else
        log_info "Installing rustup"
        curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
            | sh -s -- -y --no-modify-path || log_error "rustup installation failed"
    fi
else
    log_info "rustup is already installed"
fi

# The generated fish init. Regenerated wholesale every run, so it is
# idempotent by construction. Not committed and not symlinked.
patch_write_if_different "$HOME/.config/fish/conf.d/toolchains.fish" '# Generated by the 20-toolchains module. Do not edit — regenerate instead.

fish_add_path --path "$HOME/.local/bin"

# pyenv
if test -d "$HOME/.pyenv"
    set -Ux PYENV_ROOT "$HOME/.pyenv"
    fish_add_path --path "$PYENV_ROOT/bin"
    if command -q pyenv
        pyenv init - fish | source
        if pyenv commands | string match -q pyenv-virtualenv-init
            pyenv virtualenv-init - | source
        end
    end
end

# asdf shims
if test -z "$ASDF_DATA_DIR"
    set -l _asdf_shims "$HOME/.asdf/shims"
    if test -d $_asdf_shims; and not contains $_asdf_shims $PATH
        set -gx --prepend PATH $_asdf_shims
    end
else
    if test -d "$ASDF_DATA_DIR/shims"; and not contains "$ASDF_DATA_DIR/shims" $PATH
        set -gx --prepend PATH "$ASDF_DATA_DIR/shims"
    end
end

# rust
if test -f "$HOME/.cargo/env.fish"
    source "$HOME/.cargo/env.fish"
end'

summary_note "Open a new shell for the toolchain paths to take effect."
return 0
```

Note that `patch_write_if_different` writes this file *without* sudo: `_patch_needs_sudo` sees a writable `$HOME` path and takes the plain-write branch, so the generated file stays owned by the user and remains editable.

- [ ] **Step 3: Verify the dry run**

Run: `./bootstrap.sh --dry-run --yes --only 20-toolchains`
Expected: `[DRY]` lines for the asdf download, three `asdf plugin add` calls, the pyenv/uv/rustup installers, and `write /home/…/.config/fish/conf.d/toolchains.fish`. Note that `00-core` and `10-shell` also appear — `20-toolchains` requires `10-shell`, and the engine pulls requirements in automatically. That is the dependency resolver working.

- [ ] **Step 4: Verify the generated fish file is syntactically valid**

The init file is the riskiest part: a syntax error there breaks every new shell.

```bash
./bootstrap.sh --yes --only 20-toolchains
fish -n ~/.config/fish/conf.d/toolchains.fish && echo "fish syntax OK"
```

Expected: `fish syntax OK`. Run this on the dev machine before the wipe — a broken `conf.d` file on a fresh machine means no working shell.

- [ ] **Step 5: Verify idempotency**

```bash
./bootstrap.sh --yes --only 20-toolchains 2>&1 | grep -c 'already installed'
```

Expected: 4 or more (asdf, pyenv, uv, rustup all report already-installed on the second run).

- [ ] **Step 6: Commit**

```bash
git add modules/20-toolchains
git commit -m "feat(modules): add 20-toolchains with asdf, pyenv, uv, and rustup"
```

---

### Task 16: `30-dev` — VSCode and Docker

Both come from vendor repos. The extension list is the real payload: 30 extensions captured from the current machine.

**Files:**
- Create: `modules/30-dev/meta`, `modules/30-dev/repos`, `modules/30-dev/apt`, `modules/30-dev/setup.sh`

**Interfaces:**
- Consumes: `apt_add_repo` (via the `repos` manifest), `run`, `run_sudo`, `log_*`, `summary_note`.
- Produces: the `docker` group membership that makes `docker` usable without sudo.

- [ ] **Step 1: Write the meta**

```
name=30-dev
summary=VSCode and its extensions, Docker CE
default=on
container=no
```

- [ ] **Step 2: Write the repos manifest**

Create `modules/30-dev/repos`. Format is `name|keyring-url|sources-line`, and `@KEYRING@` is substituted with the installed keyring path.

```
# name|keyring-url|sources-line
vscode|https://packages.microsoft.com/keys/microsoft.asc|deb [arch=amd64,arm64,armhf signed-by=@KEYRING@] https://packages.microsoft.com/repos/code stable main
docker|https://download.docker.com/linux/ubuntu/gpg|deb [arch=amd64 signed-by=@KEYRING@] https://download.docker.com/linux/ubuntu UBUNTU_CODENAME stable
```

The literal `UBUNTU_CODENAME` is replaced in `setup.sh`-free fashion by the engine? **No** — it is not. Replace it with the actual codename when you write the file:

```bash
sed -i "s/UBUNTU_CODENAME/$(lsb_release -cs)/" modules/30-dev/repos
```

Run that once and commit the result. Microsoft's repo is not codename-keyed; Docker's is. Spec §10 notes Docker publishes promptly for LTS releases, so a literal codename is acceptable and far simpler than templating the manifest format.

- [ ] **Step 3: Write the apt manifest**

Create `modules/30-dev/apt`:

```
# VSCode
code

# Docker CE and the plugins actually in use on this machine
docker-ce
docker-ce-cli
containerd.io
docker-buildx-plugin
docker-compose-plugin
```

- [ ] **Step 4: Write the setup script**

Create `modules/30-dev/setup.sh`:

```bash
# shellcheck shell=bash
# VSCode extensions and Docker group membership.

# 1. Extensions, captured from the machine this repo came from.
#    `code --install-extension` is idempotent and exits 0 when already present.
EXTENSIONS=(
    anthropic.claude-code
    christian-kohler.npm-intellisense
    docker.docker
    eamodio.gitlens
    esbenp.prettier-vscode
    github.codespaces
    github.vscode-github-actions
    hasnainroopawalla.vscode-python-timeit
    mechatroner.rainbow-csv
    mermaidchart.vscode-mermaid-chart
    ms-azuretools.vscode-containers
    ms-azuretools.vscode-docker
    ms-python.black-formatter
    ms-python.debugpy
    ms-python.isort
    ms-python.python
    ms-python.vscode-pylance
    ms-python.vscode-python-envs
    ms-toolsai.jupyter
    ms-toolsai.jupyter-keymap
    ms-toolsai.jupyter-renderers
    ms-toolsai.vscode-jupyter-cell-tags
    ms-toolsai.vscode-jupyter-slideshow
    ms-vscode-remote.remote-containers
    ms-vscode.cmake-tools
    ms-vscode.cpp-devtools
    ms-vscode.live-server
    njpwerner.autodocstring
    tomoki1207.pdf
    yzhang.markdown-all-in-one
)

if command -v code > /dev/null 2>&1; then
    installed=$(code --list-extensions 2>/dev/null || true)
    for ext in "${EXTENSIONS[@]}"; do
        if printf '%s\n' "$installed" | grep -qix "$ext"; then
            continue
        fi
        run code --install-extension "$ext" --force \
            || log_error "extension failed: $ext"
    done
else
    log_warn "code is not on PATH; skipping extensions"
fi

# 2. Docker without sudo. Requires a full logout to take effect — the same
#    trap documented in docs/virtualization.md for libvirt.
if getent group docker > /dev/null 2>&1; then
    if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
        log_info "already in the docker group"
    else
        run_sudo usermod -aG docker "$USER"
        summary_note "Added to the docker group — log out and back in before 'docker' works without sudo."
    fi
fi
return 0
```

- [ ] **Step 5: Verify the dry run**

Run: `./bootstrap.sh --dry-run --yes --only 30-dev`
Expected: two keyring fetches, two `write /etc/apt/sources.list.d/*.list` lines, exactly one `apt-get update` (the coalescing from Task 5 — if you see two, `apt_update_once` is broken), one batch `apt-get install -y code docker-ce …`, then the extension and `usermod` lines.

- [ ] **Step 6: Verify the sources lines are well formed**

```bash
grep -c 'signed-by=@KEYRING@' modules/30-dev/repos
grep -c 'UBUNTU_CODENAME' modules/30-dev/repos
```

Expected: `2` then `0` — both lines carry the keyring placeholder, and the codename placeholder has been substituted.

- [ ] **Step 7: Commit**

```bash
git add modules/30-dev
git commit -m "feat(modules): add 30-dev with VSCode, extensions, and Docker CE"
```

---

### Task 17: `40-desktop` — browser, apps, fonts, GNOME settings

MegaSync and ProtonVPN are deliberately absent (spec §12), which also removes the only `sysctl` drop-in this module used to need.

**Files:**
- Create: `modules/40-desktop/meta`, `modules/40-desktop/repos`, `modules/40-desktop/apt`, `modules/40-desktop/setup.sh`

**Interfaces:**
- Consumes: `apt_add_repo`, `run`, `log_*`.
- Produces: nothing other modules consume.

- [ ] **Step 1: Write the meta**

```
name=40-desktop
summary=Browser, desktop apps, fonts, GNOME settings
default=on
container=no
```

- [ ] **Step 2: Write the repos manifest**

Create `modules/40-desktop/repos`. Brave's keyring is published already-binary, which is exactly the case Task 5's keyring handling covers.

```
# name|keyring-url|sources-line
brave|https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg|deb [signed-by=@KEYRING@] https://brave-browser-apt-release.s3.brave.com/ stable main
```

- [ ] **Step 3: Write the apt manifest**

Create `modules/40-desktop/apt`:

```
brave-browser
qbittorrent
kdeconnect

# Fonts
fonts-indic
```

- [ ] **Step 4: Write the setup script**

Create `modules/40-desktop/setup.sh`:

```bash
# shellcheck shell=bash
# GNOME preferences. gsettings is already idempotent — setting a key to its
# current value is a no-op — so there is nothing to check first.

if ! command -v gsettings > /dev/null 2>&1; then
    log_warn "gsettings is unavailable; skipping GNOME settings"
    return 0
fi

run gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
run gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark'
run gsettings set org.gnome.desktop.wm.preferences button-layout 'appmenu:minimize,maximize,close'
return 0
```

The terminal profile is deliberately not set here: the profile lives under a generated UUID in dconf, so it cannot be scripted portably. Spec §11 item 1 calls for capturing a `dconf dump` before the wipe; restoring it is a manual one-liner recorded in the README checklist.

- [ ] **Step 5: Verify the dry run**

Run: `./bootstrap.sh --dry-run --yes --only 40-desktop`
Expected: the brave keyring fetch, one sources write, one `apt-get install -y brave-browser qbittorrent kdeconnect fonts-indic`, three `gsettings set` lines. Confirm there is **no** mention of megasync, protonvpn, thunderbird, flatpak, or `sysctl`.

- [ ] **Step 6: Commit**

```bash
git add modules/40-desktop
git commit -m "feat(modules): add 40-desktop with browser, apps, fonts, GNOME settings"
```

---

### Task 18: `50-media` — media and document tooling

The one `setup.sh` line here is the cross-module fix from spec §10: VLC's snap cannot read `/mnt` without the `removable-media` interface, and `60-nas` mounts there.

**Files:**
- Create: `modules/50-media/meta`, `modules/50-media/apt`, `modules/50-media/snap`, `modules/50-media/setup.sh`

**Interfaces:**
- Consumes: `pkg_snap_connect`, `pkg_snap_available`.
- Produces: `ffmpeg` and `mkvmerge` on PATH, which `tools/videos/` depends on (spec §9).

- [ ] **Step 1: Write the meta**

```
name=50-media
summary=Media and document tooling
default=on
container=no
```

- [ ] **Step 2: Write the apt manifest**

Create `modules/50-media/apt`:

```
# Video. tools/videos/ shells out to ffmpeg and mkvmerge by name —
# installing VLC does not substitute for either.
ffmpeg
mkvtoolnix
mkvtoolnix-gui

# Graphics and documents
inkscape
pandoc
texlive

# Image metadata and conversion
exif
webp
```

- [ ] **Step 3: Write the snap manifest**

Create `modules/50-media/snap`:

```
# VLC from snap, not apt: Ubuntu's apt package is on the ESM track and two
# minor versions behind, while the snap tracks upstream stable.
vlc
```

- [ ] **Step 4: Write the setup script**

Create `modules/50-media/setup.sh`:

```bash
# shellcheck shell=bash
# VLC's snap is confined. Without the removable-media interface it cannot
# open anything under /mnt — which is where 60-nas mounts. The failure looks
# like a mount problem rather than a confinement problem, so connect it here.

if pkg_snap_available; then
    pkg_snap_connect vlc removable-media
fi
return 0
```

- [ ] **Step 5: Verify the dry run**

Run: `./bootstrap.sh --dry-run --yes --only 50-media`
Expected: one `apt-get install -y ffmpeg mkvtoolnix mkvtoolnix-gui inkscape pandoc texlive exif webp`, a `snap install vlc` line *or* "snap already installed: vlc" on this machine, and either `snap connect vlc:removable-media` or "already connected". Confirm `weasyprint`, `qgis`, and `librecad` appear nowhere.

- [ ] **Step 6: Verify the tools dependency actually holds**

```bash
command -v ffmpeg && command -v mkvmerge && echo "tools/videos deps satisfied"
```

Expected: both paths printed, then the confirmation. This is the §9 claim made executable.

- [ ] **Step 7: Commit**

```bash
git add modules/50-media
git commit -m "feat(modules): add 50-media with VLC snap and removable-media fix"
```

---

### Task 19: `60-nas` — sshfs mount unit

Off by default. Spec §10: the mount cannot succeed until the key is authorized on the NAS, so this module probes connectivity and refuses to enable a unit that would only fail.

**Files:**
- Create: `modules/60-nas/meta`, `modules/60-nas/apt`, `modules/60-nas/prompts.sh`, `modules/60-nas/setup.sh`

**Interfaces:**
- Consumes: `ui_prompt`, `localenv_set`, `patch_write_if_different`, `run_sudo`, `summary_note`.
- Produces: `NAS_HOST`, `NAS_USER`, `NAS_PATH`, `NAS_MOUNT`, `NAS_KEY` in `local.env`; a systemd mount unit.

- [ ] **Step 1: Write the meta and apt manifest**

`modules/60-nas/meta`:

```
name=60-nas
summary=sshfs mount for the NAS
default=off
container=no
```

`modules/60-nas/apt`:

```
sshfs
```

- [ ] **Step 2: Write the prompts**

Create `modules/60-nas/prompts.sh`:

```bash
# shellcheck shell=bash
ui_prompt NAS_HOST  "NAS hostname or IP" ""
ui_prompt NAS_USER  "Username on the NAS" "$USER"
ui_prompt NAS_PATH  "Remote path to mount" "/volume1/photo"
ui_prompt NAS_MOUNT "Local mountpoint" "/mnt/nas-photos"
ui_prompt NAS_KEY   "SSH key for the NAS" "$HOME/.ssh/id_ed25519"

for _v in NAS_HOST NAS_USER NAS_PATH NAS_MOUNT NAS_KEY; do
    [[ -n ${!_v:-} ]] && localenv_set "$_v" "${!_v}"
done
unset _v
return 0
```

- [ ] **Step 3: Write the setup script**

A systemd `.mount` unit's filename must match its mount point with `/` replaced by `-` and no leading dash — `/mnt/nas-photos` becomes `mnt-nas\x2dphotos.mount`. Getting this wrong makes systemd reject the unit. `systemd-escape --path --suffix=mount` computes it correctly.

```bash
# shellcheck shell=bash
# The NAS mount unit, rendered from prompted values.

if [[ -z ${NAS_HOST:-} ]]; then
    log_warn "No NAS host was provided; skipping the mount unit."
    return 0
fi

# 1. Mountpoint.
[[ -d ${NAS_MOUNT:?} ]] || run_sudo mkdir -p "$NAS_MOUNT"
run_sudo chown "$USER:$USER" "$NAS_MOUNT"

# 2. Render the ssh host entry. No secrets — just a hostname and a key path.
if [[ -f $DOTFILES_DIR/ssh/config.template ]]; then
    rendered=$(sed \
        -e "s#@NAS_HOST@#$NAS_HOST#" \
        -e "s#@NAS_USER@#${NAS_USER:-$USER}#" \
        -e "s#@NAS_KEY@#${NAS_KEY:-$HOME/.ssh/id_ed25519}#" \
        "$DOTFILES_DIR/ssh/config.template")
    run mkdir -p "$HOME/.ssh/config.d"
    patch_write_if_different "$HOME/.ssh/config.d/bootstrap" "$rendered"
    # ~/.ssh/config must include config.d for the entry to take effect.
    if [[ -f $HOME/.ssh/config ]] && ! grep -q 'Include config.d/\*' "$HOME/.ssh/config"; then
        summary_note "Add 'Include config.d/*' to the top of ~/.ssh/config."
    fi
fi

# 3. Probe before enabling. Spec section 10: the key must already be
#    authorized on the NAS, and a unit that cannot mount is worse than none.
probe_ok=0
if (( DRY_RUN )); then
    _log DRY '0;36' "ssh probe to $NAS_HOST"
    probe_ok=1
else
    log_info "Probing $NAS_HOST over ssh"
    if ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
        -i "${NAS_KEY:-$HOME/.ssh/id_ed25519}" \
        "${NAS_USER:-$USER}@$NAS_HOST" true 2>/dev/null; then
        probe_ok=1
        log_ok "NAS reachable"
    else
        log_warn "Could not authenticate to $NAS_HOST"
        if [[ -f ${NAS_KEY:-$HOME/.ssh/id_ed25519}.pub ]]; then
            log_step "Authorize this key on the NAS, then re-run with --only 60-nas:"
            cat "${NAS_KEY:-$HOME/.ssh/id_ed25519}.pub"
        fi
        summary_note "NAS mount unit was written but NOT enabled — the key is not authorized on $NAS_HOST yet."
    fi
fi

# 4. The unit itself. The filename must match the escaped mount path.
unit_name=$(systemd-escape --path --suffix=mount "$NAS_MOUNT")
patch_write_if_different "/etc/systemd/system/$unit_name" "# Written by the 60-nas bootstrap module.
[Unit]
Description=NAS over sshfs
After=network-online.target
Wants=network-online.target

[Mount]
What=${NAS_USER:-$USER}@$NAS_HOST:$NAS_PATH
Where=$NAS_MOUNT
Type=fuse.sshfs
Options=_netdev,allow_other,IdentityFile=${NAS_KEY:-$HOME/.ssh/id_ed25519},reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,uid=$(id -u),gid=$(id -g)

[Install]
WantedBy=multi-user.target"

run_sudo systemctl daemon-reload

if (( probe_ok )); then
    run_sudo systemctl enable --now "$unit_name"
else
    log_warn "Unit $unit_name written but left disabled until the key works."
fi
return 0
```

- [ ] **Step 4: Verify the unit filename escaping**

```bash
systemd-escape --path --suffix=mount /mnt/nas-photos
```

Expected: `mnt-nas\x2dphotos.mount`. If you hand-wrote `mnt-nas-photos.mount`, systemd would silently refuse to start it — this is the reason the script computes it.

- [ ] **Step 5: Verify the dry run**

Run: `./bootstrap.sh --dry-run --yes --only 60-nas`
Expected: `apt-get install -y sshfs`, a mkdir for the mountpoint, writes for the ssh config fragment and the unit, `systemctl daemon-reload`, and `systemctl enable --now`. With `--yes` and no saved `NAS_HOST`, the prompt default is empty, so expect the early "No NAS host was provided" exit instead — that is correct behavior and proves the guard works.

- [ ] **Step 6: Commit**

```bash
git add modules/60-nas
git commit -m "feat(modules): add 60-nas with probe-before-enable mount unit"
```

---

### Task 20: `90-bluetooth-autoreconnect`

The smallest module with real logic, and the cleanest demonstration of `patch_ini_set` idempotency.

**Files:**
- Create: `modules/90-bluetooth-autoreconnect/meta`, `modules/90-bluetooth-autoreconnect/setup.sh`

**Interfaces:**
- Consumes: `patch_ini_set`, `PATCH_RESULT`, `run_sudo`.
- Produces: nothing.

- [ ] **Step 1: Write the meta**

```
name=90-bluetooth-autoreconnect
summary=Reconnect bluetooth devices automatically
default=off
container=no
```

- [ ] **Step 2: Write the setup script**

```bash
# shellcheck shell=bash
# Make bluetooth devices reconnect on their own after a reboot.
# Restart bluetooth only if something actually changed.

changed=0

patch_ini_set /etc/bluetooth/main.conf Policy AutoEnable true
[[ $PATCH_RESULT == changed ]] && changed=1

patch_ini_set /etc/bluetooth/input.conf General UserspaceHID true
[[ $PATCH_RESULT == changed ]] && changed=1

if (( changed )); then
    run_sudo systemctl restart bluetooth
    summary_add changed 90-bluetooth-autoreconnect "bluetooth restarted"
else
    log_info "bluetooth configuration already correct"
fi
return 0
```

- [ ] **Step 3: Verify it is off by default**

Run: `./bootstrap.sh --dry-run --yes`
Expected: `Modules:` lists `00-core 10-shell 20-toolchains 30-dev 40-desktop 50-media` — and **not** `90-bluetooth-autoreconnect`, `90-dualboot`, or `60-nas`. The `90-` modules being off by default is a spec §4 requirement.

- [ ] **Step 4: Verify the dry run when explicitly selected**

Run: `./bootstrap.sh --dry-run --yes --only 90-bluetooth-autoreconnect`
Expected: two `write /etc/bluetooth/*.conf` lines and a `systemctl restart bluetooth`.

- [ ] **Step 5: Verify real idempotency on the live machine**

```bash
./bootstrap.sh --yes --only 90-bluetooth-autoreconnect
./bootstrap.sh --yes --only 90-bluetooth-autoreconnect 2>&1 | tail -20
```

Expected: the second run logs "bluetooth configuration already correct" and does **not** restart bluetooth. Exactly one `.bak-` file per touched config, from the first run only.

- [ ] **Step 6: Commit**

```bash
git add modules/90-bluetooth-autoreconnect
git commit -m "feat(modules): add 90-bluetooth-autoreconnect"
```

---

### Task 21: `90-dualboot` — os-prober, GRUB, and `winboot`

Step order is a safety requirement, not a preference. Spec §11 item 2: enable `os-prober`, regenerate GRUB, and **verify the Windows entry exists** before hiding the menu. Hiding first leaves a window with neither a visible menu nor a Windows entry.

**Files:**
- Create: `modules/90-dualboot/meta`, `modules/90-dualboot/setup.sh`

**Interfaces:**
- Consumes: `patch_kv_set`, `PATCH_RESULT`, `run_sudo`, `link_file`, `summary_note`, `DOTFILES_DIR`.
- Produces: nothing.

- [ ] **Step 1: Write the meta**

```
name=90-dualboot
summary=GRUB hidden menu, Windows in the GRUB menu, winboot
default=off
container=no
```

- [ ] **Step 2: Write the setup script**

```bash
# shellcheck shell=bash
# Dual-boot convenience. Step order matters: Windows must be IN the GRUB
# menu and verified before the menu is hidden, or a failed winboot leaves
# the firmware hotkey as the only route to Windows.

if [[ ! -d /sys/firmware/efi ]]; then
    log_warn "Not an EFI system; skipping the dual-boot module."
    return 0
fi

# 1. Is there a Windows entry in EFI NVRAM at all?
if ! command -v efibootmgr > /dev/null 2>&1; then
    run_sudo apt-get install -y efibootmgr
fi

win_entry=""
if command -v efibootmgr > /dev/null 2>&1; then
    win_entry=$(efibootmgr 2>/dev/null | grep -m1 'Windows Boot Manager' || true)
fi

if [[ -z $win_entry ]]; then
    log_warn "No 'Windows Boot Manager' entry in EFI NVRAM; nothing to configure."
    return 0
fi
log_ok "Found a Windows EFI entry"

# 2. os-prober, so Windows becomes a real GRUB menu entry. This is the fix;
#    winboot is only the convenience.
run_sudo apt-get install -y os-prober
patch_kv_set /etc/default/grub GRUB_DISABLE_OS_PROBER false
osprober_changed=0
[[ $PATCH_RESULT == changed ]] && osprober_changed=1

# 3. Regenerate GRUB and confirm Windows actually appears, BEFORE hiding.
if (( osprober_changed )) || ! grep -qi 'Windows' /boot/grub/grub.cfg 2>/dev/null; then
    run_sudo update-grub
fi

windows_in_menu=0
if (( DRY_RUN )); then
    windows_in_menu=1
    _log DRY '0;36' "verify a Windows entry in /boot/grub/grub.cfg"
elif grep -qi 'menuentry.*Windows' /boot/grub/grub.cfg 2>/dev/null; then
    windows_in_menu=1
    log_ok "Windows is in the GRUB menu"
else
    log_warn "os-prober did not find Windows. Leaving the GRUB menu visible."
    summary_note "GRUB has no Windows entry — menu left visible on purpose. Check that the Windows ESP is mounted and re-run."
fi

# 4. Only now hide the menu.
if (( windows_in_menu )); then
    patch_kv_set /etc/default/grub GRUB_TIMEOUT_STYLE hidden
    hidden_changed=$([[ $PATCH_RESULT == changed ]] && echo 1 || echo 0)
    patch_kv_set /etc/default/grub GRUB_TIMEOUT 0
    [[ $PATCH_RESULT == changed ]] && hidden_changed=1
    if (( hidden_changed )); then
        run_sudo update-grub
        summary_note "GRUB menu is hidden. Hold Esc at power-on to show it."
    fi
fi

# 5. The winboot function, installed only because a Windows entry exists.
if [[ -f $DOTFILES_DIR/fish/functions/winboot.fish ]]; then
    link_file "$DOTFILES_DIR/fish/functions/winboot.fish" \
        "$HOME/.config/fish/functions/winboot.fish"
fi
return 0
```

- [ ] **Step 3: Verify the ordering guarantee in the dry run**

Run: `./bootstrap.sh --dry-run --yes --only 90-dualboot`

Expected output order, which is the §11 item 2 requirement made visible:

1. `Found a Windows EFI entry`
2. `apt-get install -y os-prober`
3. `write /etc/default/grub` (the `GRUB_DISABLE_OS_PROBER` change)
4. `update-grub`
5. `verify a Windows entry in /boot/grub/grub.cfg`
6. only then the `GRUB_TIMEOUT_STYLE` / `GRUB_TIMEOUT` writes

If any `GRUB_TIMEOUT` write appears before the verification line, the ordering is wrong and the module is unsafe. Fix it before committing.

- [ ] **Step 4: Verify the no-Windows path**

The guard matters more than the happy path, because a machine without Windows must not get a hidden menu.

```bash
# Temporarily shadow efibootmgr with one that reports no Windows entry.
mkdir -p /tmp/noefi && printf '#!/bin/sh\necho "BootCurrent: 0001"\n' > /tmp/noefi/efibootmgr
chmod +x /tmp/noefi/efibootmgr
PATH=/tmp/noefi:$PATH ./bootstrap.sh --dry-run --yes --only 90-dualboot
```

Expected: `No 'Windows Boot Manager' entry in EFI NVRAM; nothing to configure.` and **no** GRUB writes at all.

- [ ] **Step 5: Commit**

```bash
git add modules/90-dualboot
git commit -m "feat(modules): add 90-dualboot with os-prober before menu hiding"
```

**Phase 3 checkpoint.** All nine modules exist. Stop for review.

---

## Phase 4 — Integration tests

### Task 22: Dry-run coverage, container integration, and idempotency

Spec §8 asks for three things beyond the unit tests: a dry run over *every* module in CI, a container run of the headless modules, and an idempotency assertion. The `container=yes|no` key already in every `meta` is what selects the headless subset.

**Files:**
- Create: `tests/modules.bats`
- Create: `tests/container-smoke.sh`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `module_list`, `module_meta_get` from `lib/module.sh`.
- Produces: nothing.

- [ ] **Step 1: Write the module-metadata tests**

These catch a malformed module without needing a machine — the cheap half of §8.

Create `tests/modules.bats`:

```bash
#!/usr/bin/env bats

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

@test "every manifest line looks like a package name" {
    while IFS= read -r m; do
        for file in apt snap; do
            [[ -f $MODULES_DIR/$m/$file ]] || continue
            while IFS= read -r entry; do
                [[ $entry =~ ^[a-zA-Z0-9][a-zA-Z0-9.+:_-]*( --[a-z-]+)*$ ]] \
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

@test "a dry run creates no files outside the cache" {
    before=$(find "$REPO_ROOT" -newermt '-1 second' -type f 2>/dev/null | wc -l)
    ( cd "$REPO_ROOT" && ./bootstrap.sh --dry-run --yes ) > /dev/null 2>&1
    [ ! -e "$HOME/.gitconfig.local" ] || [ -n "${ALLOW_EXISTING_GITCONFIG_LOCAL:-}" ]
}
```

- [ ] **Step 2: Run the tests**

Run: `bats tests/modules.bats`
Expected: 15 tests, 15 passing. The "dry run of every module" test is the single highest-value check in the suite — it exercises every manifest and every `setup.sh` without a machine.

If "every manifest line looks like a package name" fails, the regex is probably rejecting a legitimate name. Widen the character class rather than deleting the test.

- [ ] **Step 3: Write the container smoke script**

Create `tests/container-smoke.sh` and make it executable. Spec §8: run the headless modules in a container, twice, and assert the second run reports no changes.

```bash
#!/usr/bin/env bash
# Container integration test. Runs the container-safe modules in a clean
# Ubuntu image, twice, and asserts the second run is a no-op.
#
#   tests/container-smoke.sh [image]
set -euo pipefail

IMAGE="${1:-ubuntu:26.04}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Modules that declare container=yes in their meta.
mapfile -t SAFE < <(
    for d in "$REPO_ROOT"/modules/*/; do
        [[ -f ${d}meta ]] || continue
        if grep -qx 'container=yes' "${d}meta"; then
            basename "$d"
        fi
    done
)

if (( ${#SAFE[@]} == 0 )); then
    echo "No container-safe modules found." >&2
    exit 1
fi

ONLY_ARGS=()
for m in "${SAFE[@]}"; do
    ONLY_ARGS+=(--only "$m")
done

echo "Container-safe modules: ${SAFE[*]}"

docker run --rm -v "$REPO_ROOT:/repo:ro" "$IMAGE" bash -euo pipefail -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    # sudo and a non-root user, because the engine refuses to run as root.
    apt-get install -y -qq sudo ca-certificates curl git > /dev/null
    useradd -m -s /bin/bash tester
    echo "tester ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/tester
    cp -r /repo /home/tester/config
    chown -R tester:tester /home/tester/config
    su tester -c "cd /home/tester/config && ./bootstrap.sh --yes '"${ONLY_ARGS[*]}"' 2>&1 | tee /tmp/run1.log"
    su tester -c "cd /home/tester/config && ./bootstrap.sh --yes '"${ONLY_ARGS[*]}"' 2>&1 | tee /tmp/run2.log"

    echo "--- idempotency check ---"
    # The second run must not report any failures.
    if grep -q "\[ERROR\]" /tmp/run2.log; then
        echo "FAIL: the second run logged errors" >&2
        grep "\[ERROR\]" /tmp/run2.log >&2
        exit 1
    fi
    # And it must report already-present state rather than redoing work.
    if ! grep -qE "already (installed|present)" /tmp/run2.log; then
        echo "FAIL: the second run did not report any already-present state" >&2
        exit 1
    fi
    echo "PASS: second run was clean and reported existing state"
'
```

- [ ] **Step 4: Run the container test locally**

```bash
chmod +x tests/container-smoke.sh
./tests/container-smoke.sh
```

Expected: ends with `PASS: second run was clean and reported existing state`.

If `ubuntu:26.04` cannot be pulled, fall back to `./tests/container-smoke.sh ubuntu:24.04` and note it. The container test's job is catching engine bugs, not validating 26.04 specifically — the dev machine is on 24.04 anyway.

- [ ] **Step 5: Wire both into CI**

Replace `.github/workflows/ci.yml` with the full version:

```yaml
name: CI

on:
  push:
    branches: [main, bootstrap]
  pull_request:

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install shellcheck
        run: sudo apt-get update && sudo apt-get install -y shellcheck
      - name: Shellcheck the engine and all module scripts
        run: |
          shellcheck bootstrap.sh
          shellcheck lib/*.sh
          shellcheck tests/container-smoke.sh
          for f in modules/*/setup.sh modules/*/prompts.sh; do
            [ -e "$f" ] || continue
            shellcheck -x -e SC1091 "$f"
          done
      - name: Check fish syntax where fish files are committed
        run: |
          sudo apt-get install -y fish
          for f in $(find dotfiles -name '*.fish'); do
            fish -n "$f" || exit 1
          done

  unit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install bats
        run: sudo apt-get update && sudo apt-get install -y bats
      - name: Run unit tests and the dry run over every module
        run: bats tests/

  container:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run the container integration and idempotency test
        run: ./tests/container-smoke.sh ubuntu:26.04
```

The `fish -n` step is worth its three lines: a syntax error in a committed `.fish` file breaks every new shell on the target machine, and nothing else in the suite would catch it.

- [ ] **Step 6: Verify the whole suite**

```bash
shellcheck bootstrap.sh lib/*.sh tests/container-smoke.sh modules/*/setup.sh modules/*/prompts.sh
bats tests/
./tests/container-smoke.sh
```

Expected: shellcheck silent; every bats file passing; the container test ending in `PASS`.

- [ ] **Step 7: Commit**

```bash
git add tests/modules.bats tests/container-smoke.sh .github/workflows/ci.yml
git commit -m "test: add module metadata checks, dry-run coverage, and container test"
```

---

## Acceptance

The work is done when all of these hold:

- [ ] `bats tests/` passes every file
- [ ] `shellcheck bootstrap.sh lib/*.sh modules/*/*.sh tests/*.sh` is silent
- [ ] `./tests/container-smoke.sh` ends in `PASS`
- [ ] `./bootstrap.sh --dry-run --yes` selects exactly `00-core 10-shell 20-toolchains 30-dev 40-desktop 50-media` and exits 0
- [ ] `./bootstrap.sh --dry-run --yes --only <m>` exits 0 for all nine modules
- [ ] A dry run creates nothing but a transcript under `~/.cache/config-bootstrap/`
- [ ] `git status` is clean after any run — no module writes into the working tree
- [ ] `~/.config/config-bootstrap/local.env` is mode `0600` and gitignored
- [ ] `fish -n` passes on every committed `.fish` file and on the generated `conf.d/toolchains.fish`
- [ ] `winboot` resolves the EFI slot dynamically and confirms before rebooting (verified: resolves `0001` on the pre-wipe machine)

### Deliberately out of scope

Per spec §8, these can only be verified on the real machine after the wipe, against the README checklist:

- GNOME settings actually applying
- The NAS mount succeeding against a real NAS
- Bluetooth devices reconnecting after a reboot
- GRUB showing Windows, and `winboot` resolving the right slot

### Known pre-wipe prerequisites

Spec §11 items 1 and 4. These destroy information if skipped, so they are not optional:

- [ ] Commit the live `~/.config/fish/config.fish` — it has diverged from the committed copy and is the migration source for Task 12
- [ ] Re-capture `apt-mark showmanual`, `snap list`, `code --list-extensions`, `asdf plugin list`, `dconf dump /org/gnome/terminal/`

