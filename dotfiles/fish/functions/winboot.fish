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
