# Toolchain paths that no module installs.
#
# Symlinked here from ~/git/config/dotfiles/fish/conf.d/local-paths.fish by the
# 10-shell module. fish sources every file in conf.d automatically, so there is
# nothing to add to config.fish.
#
# Deliberately separate from both config.fish and the 20-toolchains module's
# generated conf.d/toolchains.fish. That module owns asdf, pyenv, uv and
# rustup; rbenv, user-installed Ruby gems and tfenv are packaged by nothing, so
# before this file existed they survived only in one machine's config.fish.
#
# Every block is guarded on the tool being present, because conf.d is linked
# onto a fresh machine long before any of these are installed, and an
# unguarded init line would print an error on every shell start.

# rbenv. Guarded on the install directory rather than `type -q rbenv`: the
# bin directory is added to PATH inside this block, so a PATH-based check
# could not succeed before the block it guards had already run.
if test -d "$HOME/.rbenv"
    set -Ux RBENV_ROOT "$HOME/.rbenv"
    set -Ux RBENV_SHELL fish
    fish_add_path --path "$RBENV_ROOT/bin"
    fish_add_path --path "$RBENV_ROOT/shims"
    if status is-interactive; and type -q rbenv
        source (rbenv init -|psub)
    end
end

# Ruby gems from `gem install --user-install`.
if test -d "$HOME/gems/bin"
    fish_add_path --path "$HOME/gems/bin"
end

# tfenv, the Terraform version manager.
#
# fish_add_path rather than the `set -x PATH $new $PATH` this replaces: conf.d
# files are sourced on every shell start, and a bare prepend grows PATH each
# time, while fish_add_path is idempotent.
if test -d "$HOME/.tfenv/bin"
    fish_add_path --path "$HOME/.tfenv/bin"
end
