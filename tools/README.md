# Tools

Standalone scripts kept in this repo but **not** part of the bootstrap. No
module installs, links, or configures anything here — running `bootstrap.sh`
will not touch these directories.

| Tool | What it does |
|---|---|
| [printing](./printing/README.md) | Scheduled print job that keeps inkjet cartridges from drying out |
| [sharedalbum](./sharedalbum/README.md) | Google Photos shared-album helper |
| [videos](./videos/README.md) | Video concatenation and renaming helpers |

## Dependencies

`videos/` shells out to `ffmpeg` and `mkvmerge` by name. Both are installed by
the `50-media` module — see §9 of the
[design spec](../docs/superpowers/specs/2026-10-14-machine-bootstrap-design.md).
If you deselect `50-media`, these scripts will not run.

Note that installing VLC does not substitute for either: VLC bundles its own
decoders internally but ships neither command-line binary.
