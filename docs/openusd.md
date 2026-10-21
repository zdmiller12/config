# OpenUSD

> [OpenUSD](https://github.com/PixarAnimationStudios/OpenUSD)

Notes on an occasional manual build. This is **not** a bootstrap step — no
module performs it. Kept because the steps were worked out by hand and are
painful to rediscover.

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

**Proposed organization of OpenUSD installs:**

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

... but to avoid universally tweaking the `PATH` and `PYTHONPATH` variables,
the `usd` fish function scopes them to a single invocation. It is installed by
the `10-shell` module from
[`dotfiles/fish/functions/usd.fish`](../dotfiles/fish/functions/usd.fish).

The function could be improved to accept the python version as an argument, if
needed.
