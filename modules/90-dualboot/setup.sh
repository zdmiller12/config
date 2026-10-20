# shellcheck shell=bash
# Dual-boot convenience: os-prober, a visible-then-hidden GRUB menu, and the
# winboot fish function. Sourced, not executed: signal completion with
# `return`, never `exit`.
#
# Step order is a safety requirement (spec section 11 item 2), not a style
# choice: Windows must be a real GRUB menu entry, and that entry must be
# VERIFIED, before the menu is hidden. Hiding first would leave a window in
# which there is neither a visible menu nor a working Windows entry — the
# firmware hotkey would be the only route to Windows. Do not reorder the
# numbered steps below.

MODULE_FAILED=0

# 0. Non-EFI systems have no NVRAM boot entries to find; nothing to do.
if [[ ! -d /sys/firmware/efi ]]; then
    log_warn "Not an EFI system; skipping the dual-boot module."
    return 0
fi

# 1. Is there a Windows entry in EFI NVRAM at all? This gate runs before
#    anything else is installed or written. If it fails, we return having
#    changed nothing.
if ! command -v efibootmgr > /dev/null 2>&1; then
    apt_install efibootmgr
fi

if ! command -v efibootmgr > /dev/null 2>&1; then
    log_error "efibootmgr is not available; cannot determine whether a Windows EFI entry exists"
    summary_note "90-dualboot could not run: efibootmgr is missing and could not be installed."
    return 1
fi

win_entry=$(efibootmgr 2>/dev/null | grep -m1 'Windows Boot Manager' || true)

if [[ -z $win_entry ]]; then
    log_warn "No 'Windows Boot Manager' entry in EFI NVRAM; nothing to configure."
    return 0
fi
log_ok "Found a Windows EFI entry"

# 2. os-prober, so Windows becomes a real GRUB menu entry. This is the fix;
#    winboot is only the convenience that rides along with it.
apt_before=${#APT_FAILED[@]}
apt_install os-prober
if (( ${#APT_FAILED[@]} > apt_before )); then
    log_error "failed to install os-prober"
    MODULE_FAILED=1
fi

# 3. Enable os-prober in the GRUB config (it defaults to disabled since
#    Ubuntu 22.04, which is why Windows was never in the menu to begin with).
patch_kv_set /etc/default/grub GRUB_DISABLE_OS_PROBER false
osprober_changed=0
[[ $PATCH_RESULT == changed ]] && osprober_changed=1

# 4. Regenerate GRUB. Only re-run update-grub when something actually
#    changed or Windows is not already present, so a clean re-run is a
#    no-op here.
if (( osprober_changed )) || ! grep -qi 'menuentry.*Windows' /boot/grub/grub.cfg 2>/dev/null; then
    if ! run_sudo update-grub; then
        log_error "update-grub failed"
        MODULE_FAILED=1
    fi
fi

# 5. Verify a Windows entry now actually exists in grub.cfg, BEFORE touching
#    GRUB_TIMEOUT_STYLE/GRUB_TIMEOUT. This is the step that makes hiding the
#    menu safe: we only hide it once we know there is another route to
#    Windows baked into the menu itself.
log_step "Verifying a Windows entry in /boot/grub/grub.cfg"
windows_in_menu=0
if grep -qi 'menuentry.*Windows' /boot/grub/grub.cfg 2>/dev/null; then
    windows_in_menu=1
    log_ok "Windows is in the GRUB menu"
else
    log_warn "No Windows menu entry found in grub.cfg; leaving the GRUB menu visible."
    summary_note "GRUB has no Windows entry yet — menu left visible on purpose. Check that the Windows ESP is mounted and re-run 90-dualboot."
fi

# 6. Only now hide the menu, and only on the branch where step 5 succeeded.
if (( windows_in_menu )); then
    patch_kv_set /etc/default/grub GRUB_TIMEOUT_STYLE hidden
    hidden_changed=0
    [[ $PATCH_RESULT == changed ]] && hidden_changed=1
    patch_kv_set /etc/default/grub GRUB_TIMEOUT 0
    [[ $PATCH_RESULT == changed ]] && hidden_changed=1

    # Re-run update-grub if the config was just changed, OR if grub.cfg does
    # not yet carry the hidden directive — e.g. a previous update-grub call
    # here failed, leaving /etc/default/grub correct but grub.cfg stale.
    # Without this second condition, a failed update-grub self-heals into a
    # permanently-visible menu that re-runs report as successful, because
    # patch_kv_set sees both keys already at their target value and never
    # fires the retry. grub-mkconfig's make_timeout() (grub-mkconfig_lib)
    # emits the literal line `set timeout_style=hidden` only when
    # GRUB_TIMEOUT_STYLE=hidden at generation time; confirmed present in
    # this machine's real /boot/grub/grub.cfg today.
    if (( hidden_changed )) || ! grep -q 'timeout_style=hidden' /boot/grub/grub.cfg 2>/dev/null; then
        if run_sudo update-grub; then
            summary_note "GRUB menu is now hidden. Hold Esc at power-on to show it."
        else
            log_error "update-grub failed while hiding the menu"
            MODULE_FAILED=1
        fi
    fi
fi

# 7. winboot, installed only because a Windows EFI entry exists. The
#    function itself is untouched — this module only links it into place.
if [[ -f $DOTFILES_DIR/fish/functions/winboot.fish ]]; then
    link_file "$DOTFILES_DIR/fish/functions/winboot.fish" \
        "$HOME/.config/fish/functions/winboot.fish"
else
    log_warn "dotfiles/fish/functions/winboot.fish not found; skipping winboot link."
fi

(( MODULE_FAILED )) && return 1
return 0
