# shellcheck shell=bash
# Up-front prompt phase only — spec §5. Must not install anything here.

ui_prompt NAS_HOST  "NAS hostname or IP" ""
ui_prompt NAS_USER  "Username on the NAS" "${USER:-$(id -un)}"
ui_prompt NAS_PATH  "Remote path to mount" "/volume1/photo"
ui_prompt NAS_MOUNT "Local mountpoint" "/mnt/nas-photos"
ui_prompt NAS_KEY   "SSH key for the NAS" "$HOME/.ssh/id_ed25519"

for _v in NAS_HOST NAS_USER NAS_PATH NAS_MOUNT NAS_KEY; do
    [[ -n ${!_v:-} ]] && localenv_set "$_v" "${!_v}"
done
unset _v
return 0
