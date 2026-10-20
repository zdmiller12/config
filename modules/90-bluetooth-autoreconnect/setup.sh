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
