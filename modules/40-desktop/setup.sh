# shellcheck shell=bash
# GNOME preferences. gsettings is already idempotent — setting a key to its
# current value is a no-op — so there is nothing to check first.

MODULE_FAILED=0

if ! command -v gsettings > /dev/null 2>&1; then
    log_warn "gsettings is unavailable; skipping GNOME settings"
    return 0
fi

run gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' || {
    log_error "failed to set color-scheme"
    MODULE_FAILED=1
}
run gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark' || {
    log_error "failed to set gtk-theme"
    MODULE_FAILED=1
}
run gsettings set org.gnome.desktop.wm.preferences button-layout 'appmenu:minimize,maximize,close' || {
    log_error "failed to set button-layout"
    MODULE_FAILED=1
}

(( MODULE_FAILED )) && return 1
return 0
