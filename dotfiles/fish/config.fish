# fish-shell configuration
# https://github.com/fish-shell/fish-shell
#
# Symlinked here from ~/git/config/dotfiles/fish/config.fish by the
# 10-shell module. Edit it there and commit; this is a working tree.
#
# Toolchain initialization (asdf, pyenv, uv, rustup) is NOT here — the
# 20-toolchains module generates ~/.config/fish/conf.d/toolchains.fish,
# which fish sources automatically.

set -Ux AWS_DEFAULT_REGION us-east-1
set -Ux AWS_REGION us-east-1

function fish_greeting
    echo (set_color green)"Do you like fish sticks?"
end

# aliases
alias gitclean="git branch | grep -v \* | xargs git branch -D"
