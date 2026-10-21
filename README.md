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
      terminal profile. `dconf dump` emits only deviations from the GNOME
      defaults, so empty output means the profile was never customized and
      there is nothing to carry across — not that the command failed.
- [ ] Copy out `~/.config/Code/User/settings.json` and `keybindings.json`.
      `30-dev` restores the extension set but not the settings; if you work in
      the VS Code integrated terminal, your terminal configuration lives here
      rather than in dconf.
- [ ] **Confirm every cloud-sync folder has finished syncing.** Nothing under
      `~/MEGA` is recreated by any module.

## After reinstalling

Manual verification on the real machine after the wipe — this is the
compensating control for everything this project cannot test in CI: stage 1,
both interactive paths, GNOME, the NAS, bluetooth, and GRUB.

- [ ] **Before trusting `GRUB_TIMEOUT=0`:** confirm GRUB shows a Windows entry,
      and that holding `Esc` (UEFI) or `Shift` (BIOS) at power-on reveals the
      menu.
- [ ] Run `winboot`, read its prompt, and confirm it resolves a plausible EFI
      boot slot — then cancel, don't actually reboot into it.
- [ ] `ssh nas` resolves, and the NAS `.mount` unit mounts.
- [ ] Bluetooth devices reconnect on their own after a reboot.
- [ ] GNOME dark theme and window-button layout are applied.
- [ ] The module checklist renders correctly — whiptail if present, the
      numbered fallback if it is absent.
- [ ] Restore the terminal profile — only if the pre-wipe `dconf dump` produced
      output: `dconf load /org/gnome/terminal/ < <your dump>`.
- [ ] Restore `~/.config/Code/User/settings.json` and `keybindings.json` from
      the copies taken before the wipe.
- [ ] Re-add any `~/.ssh/config` host entries by hand — this repo does not
      commit or restore them.

## Other docs

- [tools/](./tools/README.md) — standalone scripts, not part of bootstrap
- [docs/openusd.md](./docs/openusd.md) — OpenUSD manual build notes
- [docs/virtualization.md](./docs/virtualization.md) — if you want VMs back
- [design spec](./docs/superpowers/specs/2026-10-14-machine-bootstrap-design.md)
