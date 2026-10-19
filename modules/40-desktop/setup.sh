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
