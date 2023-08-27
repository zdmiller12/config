set -g -x fish_greeting 'Do you like fish sticks?'

source ~/git/config/personal_aliases.sh
export AWS_DEFAULT_REGION=us-east-1
export JAVA_HOME=/usr/lib/jvm/default-java

status is-login; and pyenv init --path | source
status is-interactive; and pyenv init - | source
