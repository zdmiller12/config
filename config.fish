# fish-shell configuration
# https://github.com/fish-shell/fish-shell

set -Ux RBENV_ROOT "$HOME/.rbenv"
set -Ux RBENV_SHELL fish
fish_add_path --path "$RBENV_ROOT/bin"
fish_add_path --path "$RBENV_ROOT/shims"

if status is-interactive
    # Commands to run in interactive sessions can go here

    source (rbenv init -|psub)
end

function fish_greeting
    echo (set_color green)Do you like fish sticks?
end

set -Ux AWS_DEFAULT_REGION us-east-1
set -Ux AWS_REGION us-east-1
set -Ux PYENV_ROOT "$HOME/.pyenv"

fish_add_path --path "$PYENV_ROOT/bin"

pyenv init - fish | source

# aliases

alias gitclean="git branch | grep -v \* | xargs git branch -D"
