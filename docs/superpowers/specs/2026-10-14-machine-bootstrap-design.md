# Machine Bootstrap — Design

**Date:** 2026-10-14
**Status:** Approved design, pending implementation plan
**Context:** Imminent wipe-and-reinstall of this laptop to Ubuntu 26.10, preserving the Windows dual-boot.

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
- `pkg.sh` — snap and flatpak installation, same tolerance
- `link.sh` — dotfile symlinking with backup of anything pre-existing and non-symlinked
- `patch.sh` — check-then-patch helpers for config files: set an INI key, uncomment a line, write a file only if its content differs
- `module.sh` — module discovery, dependency ordering, selection persistence, and the run loop

**Modules — `modules/<NN>-<name>/`.** Each is self-describing and independently
runnable. A module directory may contain:

- `meta` — `name`, `description`, one-line summary shown in the checklist, `default` (`on`/`off`), and `requires` (other module names)
- `apt`, `snap`, `flatpak` — newline-delimited package manifests; `#` comments and blank lines allowed
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
| `30-dev` | on | VSCode via Microsoft repo plus the extension set, Docker CE via Docker repo, libvirt/qemu/virt-manager |
| `40-desktop` | on | brave, thunderbird, qbittorrent, kdeconnect, megasync (with its `fs.inotify.max_user_watches` sysctl), protonvpn, flatpaks (Flatseal, Packet), fonts, GNOME settings (dark theme, window buttons, terminal profile) |
| `50-media` | on | ffmpeg, mkvtoolnix, inkscape, pandoc, texlive, weasyprint, exif, webp, qgis, librecad |
| `60-nas` | off | sshfs, the `mnt-nas-photos` systemd unit rendered from prompted host/path/key, and mountpoint creation |
| `90-bluetooth-autoreconnect` | off | `AutoEnable=true` in `/etc/bluetooth/main.conf` `[Policy]`, `UserspaceHID=true` in `/etc/bluetooth/input.conf` `[General]`, restart bluetooth |
| `90-dualboot` | off | GRUB hidden-menu settings and the `winboot` fish function |

`00-core` is a hard prerequisite of everything else and cannot be deselected.
`10-shell` is required by `20-toolchains` (the init blocks have nowhere to go
otherwise). All other modules are independent.

The `90-` prefix marks modules that modify system state outside the package
manager. They are off by default, and the checklist labels them as such.

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
  │     ├─ install `apt` / `snap` / `flatpak` manifests
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
work to one renamed package. Ubuntu 26.10 will have drifted from the 24.04
system this inventory came from — package renames, a new `winehq` codename,
changed bluez defaults.

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
- **Container integration test**: run the full bootstrap in a `ubuntu:26.10`
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
- The OpenUSD section of the current README → `docs/openusd.md`. It is a
  valuable hand-written build note, but it is documentation of an occasional
  manual build, not a bootstrap step. The `usd` fish function moves to
  `dotfiles/fish/functions/usd.fish`.
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
- **26.10 is a non-LTS release.** Third-party apt repos (winehq, protonvpn,
  megasync, teamviewer) may not publish for its codename. Those packages are
  the most likely failures and are grouped in `40-desktop` so the failure is
  localized.

## 11. Implementation notes for the plan

Work the plan will need to do that this design does not specify in full:

1. Capture the exact manifests from the current machine before the wipe:
   filtered `apt-mark showmanual`, the real (non-dependency) snaps, flatpaks,
   `code --list-extensions`, `asdf plugin list`, and a `dconf dump` of the
   terminal profile. These are data-gathering steps, not design decisions.
2. Decide the `winboot` resolution strategy (see §10).
3. Write the engine before any module, so modules can be pure data where
   possible.
