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

---

## OpenUSD

> [OpenUSD](https://github.com/PixarAnimationStudios/OpenUSD)

[usd-core](https://pypi.org/project/usd-core/) can be installed with pip, but installation of other OpenUSD tools, like [usdview](https://openusd.org/release/toolset.html#usdview), was achieved with the following steps...

```sh
sudo apt-get install --install-suggests \
    build-essential \
    cmake \
    freeglut3-dev \
    libao-dev \
    libglew-dev \
    libglfw3-dev \
    libglm-dev \
    libglu1-mesa-dev \
    libmpg123-dev \
    libxt-dev \
    mesa-common-dev \
    mesa-utils \
    pkg-config \
    python3-opengl
```

This installation compiles with python3.12, and the `install_dir` used with the [build_usd.py](https://github.com/PixarAnimationStudios/OpenUSD/blob/f03754834e28356781de5df73d12b48548ed475f/build_scripts/build_usd.py) script is specific to this python version. That said, `install_dir` was chosen such that installs for different python versions share the parent directory `usd`.

**Proposed organization of OpenUSD intsalls:**

```
$HOME
└── usd
    ├── python3.8
    ├── python3.12
    └── ...
```

If desired python version is not already installed with pyenv, do that.


```sh
git clone https://github.com/PixarAnimationStudios/OpenUSD.git
cd OpenUSD
pyenv virtualenv 3.12 usd
pyenv local usd
exec fish
pip install --upgrade numpy pip PyOpenGL PyOpenGL_accelerate pyside6 setuptools
python build_scripts/build_usd.py $HOME/usd/python3.12
```

The installation ends with the following message...

```sh
Success! To use USD, please ensure that you have:

    The following in your PYTHONPATH environment variable:
    /home/miller/usd/python3.12/lib/python

    The following in your PATH environment variable:
    /home/miller/usd/python3.12/bin
```

... but to avoid universally tweaking the `PATH` and `PYTHONPATH` variables, I made the following [function](https://fishshell.com/docs/current/cmds/function.html) for the fish shell.

> Saved as $HOME/.config/fish/functions/usd.fish

```shell
function usd --description "Wrapper for OpenUSD installation"
    begin
        set -l USD_PATH $HOME/usd/python3.12/
        set -l BIN_PATH $USD_PATH/bin/

        fish_add_path -aP $BIN_PATH
        set -lx PYTHONPATH $USD_PATH/lib/python/

        env -C $BIN_PATH $argv
    end
end

```

The function could definitely be improved to accept python version as an argument, if needed.
