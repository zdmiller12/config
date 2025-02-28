# Personal Configurations

> Personal configs and tools...

## Setting Up a New Machine

1. Install [fish-shell](https://github.com/fish-shell/fish-shell)
2. Install [fisher](https://github.com/jorgebucaran/fisher)
3. Install [nvm.fish](https://github.com/jorgebucaran/nvm.fish)
4. Install [rbenv](https://github.com/rbenv/rbenv) & [ruby-build](https://github.com/rbenv/ruby-build) (*if needed*)
5. Install [pyenv](https://github.com/pyenv/pyenv)


### fish-shell configuration

Copy contents of [config.fish](./config.fish) to `$HOME/.config/fish/config.fish`.

> using fish shell...

```fish
printf "%s\n" ( cat config.fish ) > $HOME/.config/fish/config.fish
```

## git configuration

Copy contents of [.gitconfig](./.gitconfig) to `$HOME/.gitconfig`.

> using fish shell...

```fish
printf "%s\n" ( cat .gitconfig ) > $HOME/.gitconfig
```

## Tools

- [Printing](./printing/README.md)
- [Videos](./videos/README.md)
