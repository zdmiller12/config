# Machine Bootstrap — Design

**Date:** 2026-10-14
**Revised:** 2026-10-16 — target release corrected to 26.04 LTS; module catalog narrowed (see §12)
**Status:** Approved design, pending implementation plan
**Context:** Imminent wipe-and-reinstall of this laptop to Ubuntu 26.04 LTS, preserving the Windows dual-boot.

## 1. Goal

One command on a freshly installed Ubuntu machine brings it to a usable,
personalized state: packages installed, shell configured, dotfiles in place,
toolchains ready. The user chooses which groups of work to run via an
interactive checklist. Re-running is safe and converges rather than duplicating.

Secondary goal: the repo is legible and forkable. A stranger can run it, answer
the prompts with their own identity, and get a working machine without editing
the engine.

## 2. Constraints and decisions

Decisions made during brainstorming, recorded so the plan does not relitigate
them:

| Decision | Choice | Consequence |
|---|---|---|
| Target platform | Ubuntu-first, Debian-family tolerated | All apt calls go through `lib/apt.sh`; no macOS/brew abstraction |
| Toggle UX | Interactive checklist, saved to a file and reused | Fresh runs prompt; later runs replay the saved selection unless asked to reconfigure |
| Engine | Modular bash + declarative text manifests | No bootstrap dependency beyond `curl`; package lists stay diffable |
| Legacy tools | `printing/`, `sharedalbum/`, `videos/` move to `tools/` | Kept in git, excluded from bootstrap; no module depends on them |
| Self-hosted services | Dropped | apache2, postfix, redis-server, jackett, teamviewerd are not reproduced; README records the decision |
| Flatpak | Dropped | `pkg.sh` handles snap only; no `flatpak` manifest type; Flatseal and Packet are not reproduced |
| Virtualization | Dropped | qemu/libvirt/virt-manager are not reproduced — the native Windows dual-boot serves that need better. `docs/virtualization.md` records the non-obvious setup steps |
| Toolchains | asdf for node/ruby/terraform; pyenv for Python; uv for Python tools; rustup for Rust | Removes the duplicate Node managers, `rbenv`, and `tfenv` |
| Identity and secrets | Prompted on first run, written to a gitignored local file | Nothing personal is committed; SSH keys are generated, never copied |

Non-goals: provisioning remote hosts, managing more than one machine's divergent
state, recreating the eleven existing pyenv virtualenvs, encrypting secrets at
rest, reproducing GRUB's EFI entry index verbatim.

## 3. Architecture

Four layers, each with one job.

**Entrypoint — `bootstrap.sh`.** Curl-able and idempotent. It verifies it is on
a Debian-family system, installs `git` if absent, clones the repo to
`~/git/config` (or fast-forwards an existing clone), then re-executes the
engine from that clone. Everything after this point runs from a real working
tree, so dotfile symlinks point at files the user can edit and push.

**Engine — `lib/`.** Shared behavior, no machine-specific knowledge:

- `log.sh` — levelled output, a run summary, and a transcript at `~/.cache/config-bootstrap/run-<timestamp>.log`
- `ui.sh` — the module checklist and prompts; `whiptail` when a TTY is available, numbered-list fallback otherwise
- `apt.sh` — repo registration (keyring + `.sources`), `apt-get update` coalesced to once per run, package installation with per-package failure tolerance
- `pkg.sh` — snap installation, same tolerance
- `link.sh` — dotfile symlinking with backup of anything pre-existing and non-symlinked
- `patch.sh` — check-then-patch helpers for config files: set an INI key, uncomment a line, write a file only if its content differs
- `module.sh` — module discovery, dependency ordering, selection persistence, and the run loop

**Modules — `modules/<NN>-<name>/`.** Each is self-describing and independently
runnable. A module directory may contain:

- `meta` — `name`, `description`, one-line summary shown in the checklist, `default` (`on`/`off`), and `requires` (other module names)
- `apt`, `snap` — newline-delimited package manifests; `#` comments and blank lines allowed
- `repos` — apt repositories to register before installing, one per line as `name|keyring-url|sources-line`
- `setup.sh` — the imperative remainder, sourced with the engine's helpers available

A module with only manifests needs no code at all. That is the point: the
declarative majority stays data, and `setup.sh` exists only where real logic
lives.

**Dotfiles — `dotfiles/`.** The files themselves, plus a `links` manifest
mapping repo path to destination. Machine-specific values are rendered from
templates at run time using the local config, not committed pre-filled.

## 4. Module catalog

| Module | Default | Contents |
|---|---|---|
| `00-core` | on | build-essential, cmake, curl, git, gh, pkg-config, htop, and the library headers needed to build Pythons (libssl-dev, libreadline-dev, libsqlite3-dev, libbz2-dev, liblzma-dev, libffi-dev, tk-dev, libncurses-dev) |
| `10-shell` | on | fish, fisher, the dotfile symlinks, git identity prompt, SSH key generation, `chsh` to fish |
| `20-toolchains` | on | asdf with node/ruby/terraform plugins, pyenv + pyenv-virtualenv, uv, rustup, and the fish init blocks for each |
| `30-dev` | on | VSCode via Microsoft repo plus the extension set, Docker CE via Docker repo |
| `40-desktop` | on | brave, qbittorrent, kdeconnect, megasync (with its `fs.inotify.max_user_watches` sysctl), protonvpn, fonts, GNOME settings (dark theme, window buttons, terminal profile) |
| `50-media` | on | ffmpeg, mkvtoolnix and mkvtoolnix-gui, VLC via snap, inkscape, pandoc, texlive, exif, webp |
| `60-nas` | off | sshfs, the `mnt-nas-photos` systemd unit rendered from prompted host/path/key, and mountpoint creation |
| `90-bluetooth-autoreconnect` | off | `AutoEnable=true` in `/etc/bluetooth/main.conf` `[Policy]`, `UserspaceHID=true` in `/etc/bluetooth/input.conf` `[General]`, restart bluetooth |
| `90-dualboot` | off | GRUB hidden-menu settings and the `winboot` fish function |

`00-core` is a hard prerequisite of everything else and cannot be deselected.
`10-shell` is required by `20-toolchains` (the init blocks have nowhere to go
otherwise). All other modules are independent.

The `90-` prefix marks modules that modify system state outside the package
manager. They are off by default, and the checklist labels them as such.

**VLC ships from snap rather than apt.** Ubuntu's apt package trails upstream by
two minor versions and is maintained on the ESM track, while the snap tracks
upstream stable. The cost is confinement: `50-media/setup.sh` must connect the
`removable-media` interface, because without it VLC cannot open files under
`/mnt` — which is exactly where `60-nas` mounts. That one command is the
module's entire imperative remainder.

**`50-media` is also the dependency provider for `tools/videos/`** (see §9).

## 5. Run lifecycle

```
curl -fsSL <raw-url>/bootstrap.sh | bash
  │
  ├─ preflight: Debian-family? apt present? not root?
  ├─ ensure git, clone or update ~/git/config, re-exec engine from clone
  │
  ├─ load local config (~/.config/config-bootstrap/local.env) if present
  ├─ discover modules, resolve `requires`, order by directory prefix
  ├─ selection: saved file if present and --reconfigure absent, else checklist
  ├─ collect prompts for selected modules up front (identity, NAS host, …)
  │     └─ persist answers to local.env (gitignored, mode 0600)
  │
  ├─ for each selected module, in order:
  │     ├─ register `repos`, then one coalesced apt-get update
  │     ├─ install `apt` / `snap` manifests
  │     └─ run `setup.sh`
  │
  └─ summary: per-module ok/changed/failed, log path, manual follow-ups
```

All prompting happens before any installation. A run that needs the user's
attention asks for it in the first thirty seconds, then proceeds unattended —
rather than blocking on a question forty minutes in.

The entrypoint accepts `--reconfigure` (re-prompt the checklist), `--only
<module>`, `--skip <module>`, `--dry-run`, and `--yes` (accept defaults, no
prompts) so that repeat and unattended runs do not depend on the TTY.

## 6. Portable versus local state

Committed: package manifests, dotfiles, module code, the engine.

Local and gitignored, at `~/.config/config-bootstrap/local.env`:

- git `user.name` and `user.email`
- NAS host, remote path, mountpoint, SSH key path
- the module selection
- anything else a module prompts for

SSH keys are generated on the new machine (`ssh-keygen -t ed25519`), never
transported by this repo. After generating, bootstrap prints the public key and
pauses so it can be added to GitHub before any step needs to authenticate.

The `~/.ssh/config` host entries are committed as a template, since they
contain hostnames and key paths but no secrets.

## 7. Error handling

The guiding rule: a fresh-install bootstrap must never lose forty minutes of
work to one renamed package. Ubuntu 26.04 will have drifted from the 24.04
system this inventory came from — the upgrade skips two interim releases, so
package renames, third-party repos that have not yet published for the new
codename, and changed bluez defaults all remain live risks.

- **Package-level failures are tolerated.** A package that will not install is
  recorded and the run continues. The summary lists every failure so they can
  be chased individually.
- **Module-level failures are contained.** A `setup.sh` that exits non-zero
  fails that module only; later modules still run.
- **Preflight failures abort.** Wrong distro family, no apt, or running as root
  stops the run before it changes anything.
- **File edits are backed up.** `patch.sh` copies any file it modifies to
  `<path>.bak-<timestamp>` on first touch, and `link.sh` does the same for
  non-symlink files it would replace.
- **Privilege is explicit.** The engine runs unprivileged and calls `sudo` per
  command. It validates sudo once up front so the password prompt does not
  appear unexpectedly mid-run.
- **Every run leaves a transcript** under `~/.cache/config-bootstrap/`.

## 8. Testing

The subject under test is a destructive, one-shot, whole-machine operation, so
the strategy is layered rather than exhaustive.

- **Engine unit tests** with [bats](https://github.com/bats-core/bats-core):
  manifest parsing (comments, blanks, whitespace), `requires` resolution and
  cycle detection, INI patching idempotency (patch twice, assert one change),
  symlink backup behavior, and argument parsing.
- **A `--dry-run` mode** that prints every command without executing, exercised
  in CI against every module so a syntax error or missing manifest is caught
  without a machine.
- **Container integration test**: run the full bootstrap in a `ubuntu:26.04`
  container with `--yes`, for the modules that work headless (`00-core`,
  `10-shell`, `20-toolchains`). Desktop, snap, and systemd modules are skipped
  there and marked as container-untestable in their `meta`.
- **Idempotency test**: run twice in the container, assert the second run
  reports zero changes.
- **Shellcheck** over the engine and all `setup.sh` files.
- **Manual verification** on the real machine after the wipe, against a
  checklist in the README. The desktop, bluetooth, NAS, and dual-boot modules
  can only be truly verified there.

## 9. Migration of existing repo content

- `config.fish` → `dotfiles/fish/config.fish`, rewritten: the rbenv and tfenv
  blocks are dropped, asdf and pyenv init retained, `winboot` becomes a
  function in `dotfiles/fish/functions/` rather than an alias.
- `.gitconfig` → `dotfiles/git/gitconfig`, with `[user]` removed and rendered
  from local config instead; alias set kept verbatim.
- `printing/`, `sharedalbum/`, `videos/` → `tools/`, with their READMEs intact
  and a `tools/README.md` explaining that they are not part of bootstrap.
- **`50-media` is the dependency provider for `tools/videos/`.** Those scripts
  leave the bootstrap path, but `merge-videos.sh` invokes `ffmpeg` directly and
  the README documents `mkvmerge`, so both packages stay declared in a module.
  Recorded here so nobody later prunes `50-media` and quietly breaks `tools/`.
  Note that installing VLC does *not* make them redundant: VLC bundles decoders
  internally but ships neither CLI binary.
- The OpenUSD section of the current README → `docs/openusd.md`. It is a
  valuable hand-written build note, but it is documentation of an occasional
  manual build, not a bootstrap step. The `usd` fish function moves to
  `dotfiles/fish/functions/usd.fish`.
- `docs/virtualization.md` is new, and is what remains of the dropped KVM
  stack. The package list is not worth preserving — six apt packages are two
  minutes of rederivation — but two facts are: membership in both the `libvirt`
  and `kvm` groups requires a full logout to take effect, and `ovmf` is
  mandatory for a Windows 11 guest because of Secure Boot and TPM 2.0.
- The README becomes the bootstrap front door: the one-line curl command, the
  module table, how to fork it, and what is deliberately not included.

## 10. Known machine-specific hazards

Recorded because they are easy to forget and painful to discover late:

- **`winboot` is not portable.** It currently hardcodes `efibootmgr
  --bootnext 0001`. That index is this machine's EFI NVRAM slot and will differ
  after reinstall. The replacement must resolve the Windows entry dynamically.
- **GRUB's hidden menu with `GRUB_TIMEOUT=0`** makes a dual-boot machine hard
  to recover if the EFI entry is wrong. The `90-dualboot` module must apply the
  `winboot` function before hiding the menu, and the README must say how to
  reach GRUB with a held key.
- **The NAS unit depends on a key that must already be authorized** on the NAS
  before the mount can succeed. The module therefore prints the public key and
  verifies connectivity with a probe before enabling the unit.
- **VLC's snap confinement crosses module boundaries.** `50-media` installs a
  confined VLC; `60-nas` mounts under `/mnt`. Without the `removable-media`
  interface connected, VLC cannot see NAS files and fails in a way that looks
  like a mount problem rather than a confinement problem.
- **An LTS target lowers third-party repo risk without removing it.** MegaSync
  pins to an explicit `xUbuntu_<version>` path and ProtonVPN keys to the release
  codename; both publish for a new LTS weeks to months after release, and 26.04
  is recent. They are the likeliest failures and are grouped in `40-desktop` so
  the failure stays localized. Docker also keys to the codename but publishes
  promptly for LTS releases. The Microsoft (VSCode) and Brave repos are not
  codename-keyed and carry no release-timing risk.

## 11. Implementation notes for the plan

Work the plan will need to do that this design does not specify in full:

1. Capture the exact manifests from the current machine before the wipe:
   filtered `apt-mark showmanual`, the real (non-dependency) snaps,
   `code --list-extensions`, `asdf plugin list`, and a `dconf dump` of the
   terminal profile. These are data-gathering steps, not design decisions.
2. Decide the `winboot` resolution strategy (see §10).
3. Write the engine before any module, so modules can be pure data where
   possible.

## 12. Revision log

**2026-10-16** — reviewed the `30-dev`, `40-desktop`, and `50-media` catalogs
against the current machine's actual state rather than its `apt-mark showmanual`
output, and corrected the target release.

| Change | Reason |
|---|---|
| Target release 26.10 → **26.04 LTS** | Corrected intent. §7, §8, and §10 revised: the drift risk persists (the upgrade skips two interim releases) but third-party repo risk drops to a timing concern |
| `30-dev`: libvirt/qemu/virt-manager **dropped** | Installed 2026-09-24 alongside `cpu-checker` and a Windows 11 ISO, then abandoned: virt-manager was never launched, no storage pool, no disk image, no VM defined. The preserved Windows dual-boot serves the same need with full hardware access. Knowledge preserved in `docs/virtualization.md` |
| `40-desktop`: thunderbird **dropped** | Not wanted on the new machine |
| `40-desktop`: Flatseal and Packet **dropped** | Not wanted; they were the only two flatpaks |
| Engine: flatpak support **dropped** | No remaining consumer. Removes an untestable path — §8's container suite could not exercise it anyway |
| `50-media`: **VLC added**, as a snap | Already in use on this machine but absent from the inventory. Snap over apt because apt's is ESM-track and two minor versions behind |
| `50-media`: ffmpeg and mkvtoolnix **kept** | Not made redundant by VLC — `tools/videos/` calls both CLIs by name |
| `50-media`: weasyprint **dropped** | Nothing in the repo references it; pandoc + texlive already cover document→PDF, and `uv` is the better home for a Python tool |
| `50-media`: qgis and librecad **dropped** | Not wanted. A `qgis/qgis` Docker image is already in use if needed |
