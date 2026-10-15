# fish-shell configuration
# https://github.com/fish-shell/fish-shell
#
# other lines which appeared
#  source "$HOME/.cargo/env.fish"         # seems automated
#  fish_add_path --path "$HOME/gems/bin"  # is this still needed with rbenv?
#

set -Ux RBENV_ROOT "$HOME/.rbenv"
set -Ux RBENV_SHELL fish
fish_add_path --path "$RBENV_ROOT/bin"
fish_add_path --path "$RBENV_ROOT/shims"

if status is-interactive
    # Commands to run in interactive sessions can go here

    source (rbenv init -|psub)
end

function fish_greeting
    echo (set_color green)"Do you like fish sticks?"
end

set -Ux AWS_DEFAULT_REGION us-east-1
set -Ux AWS_REGION us-east-1
set -Ux PYENV_ROOT "$HOME/.pyenv"

fish_add_path --path "$PYENV_ROOT/bin"

pyenv init - fish | source

# ASDF configuration code
if test -z $ASDF_DATA_DIR
    set _asdf_shims "$HOME/.asdf/shims"
else
    set _asdf_shims "$ASDF_DATA_DIR/shims"
end

# Do not use fish_add_path (added in Fish 3.2) because it
# potentially changes the order of items in PATH
if not contains $_asdf_shims $PATH
    set -gx --prepend PATH $_asdf_shims
end
set --erase _asdf_shims

# aliases

alias gitclean="git branch | grep -v \* | xargs git branch -D"
