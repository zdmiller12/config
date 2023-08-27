#!/bin/bash
# git
alias branch='git rev-parse --abbrev-ref HEAD | tr -d "\n"'
alias branchjenk='git rev-parse --abbrev-ref HEAD | sed "s/\\//%252/g" | tr -d "\n"'
alias gitclean='git branch | grep -v \* | xargs git branch -D'
alias jenk='set REPO (repo); set BRANCH (branch); echo -n https://jenkins.internal.cloud.torc.tech/torc-robotics/job/gis/job/$REPO/job/$BRANCH/'
alias repo='git remote -v | head -n 1 | cut -d'/' -f 2 | cut -d'.' -f 1'
alias ticket="git rev-parse --abbrev-ref HEAD | cut -d'/' -f 2 | cut -d'_' -f 1"
# AWS
alias awslogin='aws ecr get-login-password | docker login --username AWS --password-stdin 588188713524.dkr.ecr.us-east-1.amazonaws.com'
# general
alias josm='reset; cd ~/torc/git/GIS/osm_tools/josm; ./launch_josm'
alias makegeotiff='~/torc/git/Mapping/mapping_tools/image_scripts/make_geotiff.sh'
alias makevrt='~/torc/git/Mapping/mapping_tools/image_scripts/make_vrt.sh'
alias pbcopy='xclip -selection clipboard'
alias pbpaste='xclip -selection clipboard -o'
alias v='nautilus .'
alias vpn='sudo openconnect vpn.torcrobotics.com --background --base-mtu=1300 --authgroup=Employee-Split-Push --user=miller'
