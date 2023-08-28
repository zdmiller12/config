set -g -x fish_greeting 'Do you like fish sticks?'

source ~/git/config/personal_aliases.sh
set AWS_DEFAULT_REGION us-east-1
set JAVA_HOME /usr/lib/jvm/default-java
set PYENV_ROOT "$HOME/.pyenv"
command -v pyenv >/dev/null || set PATH "$PYENV_ROOT/bin:$PATH"

status is-login; and pyenv init --path | source
status is-interactive; and pyenv init - | source
