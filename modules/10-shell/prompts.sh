# shellcheck shell=bash
# Collected before any installation. See the deviation note in the plan header.

ui_prompt GIT_NAME  "Your name, for git commits" ""
ui_prompt GIT_EMAIL "Your email, for git commits" ""

[[ -n ${GIT_NAME:-} ]]  && localenv_set GIT_NAME  "$GIT_NAME"
[[ -n ${GIT_EMAIL:-} ]] && localenv_set GIT_EMAIL "$GIT_EMAIL"
return 0
