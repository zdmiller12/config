# shellcheck shell=bash
# VLC's snap is confined. Without the removable-media interface it cannot
# open anything under /mnt — which is where 60-nas mounts. The failure looks
# like a mount problem rather than a confinement problem, so connect it here.

if pkg_snap_available; then
    pkg_snap_connect vlc removable-media
fi
return 0
