# Dotfile tie-in: `dotfiles.sh`

Status: approved, not yet implemented
Date: 2026-11-18

## Problem

Dotfile symlinking already works, but only as step 1 of the `10-shell` module.
Three consequences:

1. **No cheap way to run it.** Applying the manifest means
   `./bootstrap.sh --only 10-shell`, which also generates an SSH key, installs
   fisher, and runs `chsh`. There is no "just sync my dotfiles" command.
2. **No way to see link state.** Nothing reports which manifest entries are
   linked, which are missing, and which have a divergent file sitting at the
   destination. The README still instructs the reader to eyeball
   `~/.config/fish/config.fish` for drift — a step the symlinks were supposed
   to make obsolete.
3. **No way to bring a new file in.** Adopting a live dotfile is a manual
   three-step dance: move the file into `dotfiles/`, hand-edit the manifest,
   symlink it back.

There is also a latent bug. `link_file` backs a divergent destination up to
`$dest.bak-$RUN_STAMP` and then replaces it. The data survives, but nothing
reports that it happened or that the files differed. On a second machine that
is silent data loss with a receipt nobody reads.

## Scope

In scope: symlinkable files listed in `dotfiles/links`.

Out of scope, deliberately:

- **Non-file state** — `dconf dump`, `apt-mark showmanual`,
  `code --list-extensions`, `asdf plugin list`. These are queries against
  system state, not files, so they cannot be symlinked and need a different
  mechanism (export to a committed file). Worth building; a separate spec.
- **`~/.gitconfig.local`** — holds the prompted git identity and is
  deliberately uncommitted. `~/.gitconfig` is already symlinked and `include`s
  it. The split is the design, not a gap.
- **`~/.ssh/config`** — technically symlinkable (ssh demands strict modes only
  on private keys, not on `config`), but it holds the NAS hostname, username,
  and key paths. Keeping it uncommitted is an editorial choice this spec does
  not revisit. The existing template + `Include ~/.ssh/config.d/` fragment
  approach stands.
- **`unlink`** — removing an adopted file is rare and is two obvious manual
  steps. Not built.

## Design

### Entry point

A new `dotfiles.sh` at the repo root, a peer to `bootstrap.sh`, sourcing
`lib/log.sh`, `lib/link.sh`, and `lib/ui.sh`. All three self-default the
globals they need (`DRY_RUN`, `RUN_STAMP`, `ASSUME_YES`), so no engine
refactor is required.

The two entry points share `lib/` and nothing else, which matches their
cadence and blast radius: `bootstrap.sh` converges a machine and is run once
per machine; `dotfiles.sh` mutates the git working tree and is run whenever
config changes.

```
./dotfiles.sh [status]
./dotfiles.sh link [--force] [--dry-run] [PATH...]
./dotfiles.sh adopt PATH [REPO_REL] [--dry-run] [--force] [--yes]
./dotfiles.sh --help
```

`status` is the default subcommand, so a bare `./dotfiles.sh` answers "is
anything out of sync?".

### `status`

One line per manifest entry, classified by a single shared `link_state`
function that both entry points call:

| State | Condition |
|---|---|
| `linked` | destination symlinks to the repo file |
| `missing` | destination does not exist |
| `unlinked` | real file, byte-identical to the repo file |
| `DIVERGED` | real file (or symlink pointing elsewhere), content differs |
| `BROKEN` | the manifest names a repo file that does not exist |

Exit status is 0 when every entry is `linked`, and 1 when any entry is
`missing`, `unlinked`, `DIVERGED`, or `BROKEN` — i.e. non-zero means
"something would change", which makes it usable from a hook later.

After the table, an informational tail lists files under `dotfiles/` that no
manifest entry references, labeled "not in the manifest — linked by a module,
or not linked at all". Today that is `ssh/config.template` (rendered by
`60-nas`, never linked), which is legitimate, so this tail never affects exit
status. No ignore-file mechanism: that would be machinery for one known,
documented entry. (`fish/functions/winboot.fish` was the second such entry —
see the revision note at the end of this document.)

### Two link policies, one classifier

`link_state` classifies; the caller decides what to do about it. There are
exactly two policies, and the difference between them is the whole point of
this design.

**Bootstrap policy — purely additive. Never touches an existing path.**

| State | Behavior |
|---|---|
| `missing` | create the symlink |
| `linked` | nothing; already correct |
| `unlinked`, `DIVERGED` | **skip**, warn in yellow, print both resolution commands |
| `BROKEN` | skip, warn — the manifest is wrong, not the machine |

Because bootstrap never removes, replaces, or backs up anything at a
destination, it cannot destroy live config. There is no `--force` on this
path and no interactive prompt: a skip is not a failure, so `10-shell` does
not set `MODULE_FAILED` and the run still succeeds.

Feedback for each skipped entry is emitted at `WARN` (ANSI `0;33`, yellow) and
names both intents explicitly, because the right answer depends on which copy
the user considers authoritative:

```
[WARN] not linked: a file already exists at ~/.config/fish/config.fish
         keep the live file → ./dotfiles.sh adopt ~/.config/fish/config.fish
         keep the repo file → ./dotfiles.sh link --force ~/.config/fish/config.fish
```

A single `summary_note` follows, so the count reappears in the end-of-run
"Manual follow-ups" block: `N dotfiles were not linked because a file already
exists at the destination; run ./dotfiles.sh status to review each one.`

Offering only `adopt` here would be a trap. On a fresh machine, anything that
auto-creates a stub at a destination — `fish` writing a starter
`config.fish`, for instance — would make `adopt` pull that stub into the repo
and overwrite the real committed file. Hence both directions, every time.

**CLI policy — `dotfiles.sh link`, where the user is present and explicit.**

| State | Behavior |
|---|---|
| `missing` | create the symlink |
| `linked` | nothing |
| `unlinked` | replace with a symlink. No backup: the content is byte-identical, so there is nothing to lose |
| `DIVERGED` | refuse. Print a unified diff (repo vs. live), leave both files untouched, name both resolution commands |
| `BROKEN` | error |
| any, with `--force` | back the live file up to `$dest.bak-$RUN_STAMP`, logging that path at `WARN`, then link |

Optional `PATH` arguments scope the run to specific manifest destinations, so
`link --force ~/.gitconfig` resolves one file without touching the rest.

`link` exits non-zero if any entry refused or was `BROKEN`, and zero otherwise
— including when it did useful work, since converging is success.

### `lib/link.sh` changes

- New `link_state SRC DEST`, printing one of the five states. The single
  source of truth for classification, used by both policies and by `status`.
- `link_file` keeps its current signature and its backup-then-replace body,
  but that body now runs only under the CLI's `--force` path.
- `link_manifest` adopts the bootstrap policy above: link `missing`, skip and
  warn on everything else, and return 0 regardless, since a skip is an
  expected outcome on a reused machine rather than an error.

This changes `bootstrap.sh` behavior deliberately. Today, a pre-existing
`~/.gitconfig` is copied to `~/.gitconfig.bak-<stamp>` and replaced, with no
indication that it happened. After this change it is left exactly where it is,
and the run tells the user — twice, in yellow — how to resolve it in either
direction.

`tests/container-smoke.sh ubuntu:26.04` will reveal whether a fresh machine
hits any skips on its first run (e.g. a `fish`-authored `config.fish` stub).
That is now a cosmetic question about first-run noise rather than a
correctness one, since the additive policy handles it safely either way.

### `adopt PATH [REPO_REL]`

Brings a live file into the repo and links it back. The repo becomes the
desired state first, then the symlink is made — so a divergent file is merged
into git history before anything is replaced.

Repo path resolution: inferred, then confirmed via `ui_prompt` with the
inference as an editable default. An explicit `REPO_REL` second argument
always wins; `--yes` or a missing TTY accepts the inference. Inference cannot
be fully mechanical — the existing manifest contains two incompatible
precedents (`~/.config/fish/functions/usd.fish` → `fish/functions/usd.fish`
strips the `~/.config/` prefix, while `~/.gitconfig` → `git/gitconfig` strips
the dot *and* invents a `git/` grouping no rule derives) — which is why the
confirmation step exists rather than a cleverer rule.

Branches:

| Situation | Behavior |
|---|---|
| `PATH` is already a symlink into the repo | report, exit 0 (idempotent) |
| repo file absent | create it, append manifest entry, link |
| repo file present, identical | append manifest entry, link |
| repo file present, differs | local wins: overwrite the repo file, print the diff against `HEAD`, link |
| repo file has uncommitted changes | refuse unless `--force` — adopting would bury an unreviewed edit |
| `PATH` is a directory | clear error; files only |

Operation order is chosen so that any failure leaves the live file intact:
`cp -a` into the repo, verify, `rm` the live file, `ln -s`. Never `mv` as the
first step.

Manifest entries are appended with the file's existing column alignment, and
with `~` rather than `$HOME` in the destination. Comments and existing
formatting are preserved; entries are only ever appended.

On success `adopt` prints the review command (`git diff`) rather than
committing anything. Committing stays the user's explicit act.

## Testing

TDD, following the existing bats patterns in `tests/` and the `load_lib` /
`setup_tmpdir` helpers.

New `tests/dotfiles.bats`:

- each `status` state, and the exit status in each case
- the untracked tail lists unreferenced `dotfiles/` files and does not affect exit status
- each row of the CLI link-policy table, including that `DIVERGED` leaves both files byte-identical to what they were
- `link --force` backs up to `$dest.bak-<stamp>` and logs that path
- `link PATH` scopes to one entry and leaves the other manifest entries untouched
- all six `adopt` branches from the table above
- `adopt` is idempotent when re-run on an already-adopted file
- appended manifest entries keep the file's alignment and use `~`
- `--dry-run` mutates neither the filesystem nor the manifest
- argument errors: unknown subcommand, missing `PATH`, nonexistent `PATH`

Updated `tests/link.bats`:

- `link_state` returns the correct state for all five conditions
- `link_manifest` links `missing` entries and leaves `unlinked`, `DIVERGED`,
  and `BROKEN` destinations byte-for-byte untouched — no `.bak-` file is
  created anywhere, which is the assertion that pins the additive policy
- `link_manifest` returns 0 even when it skipped entries
- the skip warning names both the `adopt` and `link --force` commands, with
  the real destination path substituted in
- `link_file`'s existing backup-then-replace behavior still holds, since
  `--force` depends on it

CI (`.github/workflows/ci.yml`): add `dotfiles.sh` to the shellcheck
invocation alongside `bootstrap.sh` and `lib/*.sh`, since it is sourced as
part of the same unit.

## README changes

- New **Capturing config changes** section stating the invariant plainly: the
  linked dotfiles *are* the repo's files, so edits are captured the moment you
  save them; `./dotfiles.sh status` verifies, `adopt` brings a new file in.
- The "Before wiping a machine" item that says to commit the live
  `~/.config/fish/config.fish` and `~/.gitconfig` "if they have drifted"
  becomes `./dotfiles.sh status`. The `~/.ssh/config` half of that item stays,
  because it is deliberately uncommitted.
- The `10-shell` row of the module table notes that dotfile linking is
  additive: a destination that already has a file is skipped, not replaced.
- A short note on what the yellow "not linked" warning means and the two
  commands that resolve it, so the message is self-explanatory without
  reading the spec.
- `dotfiles.sh` added to the docs index at the bottom of the README.


## Revision: winboot moved into the manifest

This spec originally kept `fish/functions/winboot.fish` out of the manifest and
left `90-dualboot` to link it, reasoning that `winboot` must only land on a
dual-boot machine. Reading the function again, that reasoning does not hold. It
resolves the Windows entry from EFI NVRAM at call time, and with no such entry
it prints "hold Esc at power-on to reach the GRUB menu instead" and returns 1.
It also confirms before rebooting, and `--bootnext` is one-shot and
self-clearing. There is no harm model on a single-boot machine.

So it is now a plain manifest entry, like `fish/functions/usd.fish`, and the
module's link block is gone. Two consequences, both wanted: `winboot` arrives
without enabling `90-dualboot` (which also sets `GRUB_TIMEOUT=0` and enables
`os-prober` — large changes to make for one function), and a divergent
`winboot.fish` is now reported once rather than twice.
