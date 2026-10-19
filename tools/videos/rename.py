#!/usr/bin/env python3
"""Remove spaces from child directories and/or files."""

import re

from argparse import ArgumentParser
from pathlib import Path

parser = ArgumentParser()
parser.add_argument("-p", "--path", dest="path", required=True, type=Path)
parser.add_argument("-d", "--no-dirs", action="store_true", dest="no_dirs")
parser.add_argument("-f", "--no-files", action="store_true", dest="no_files")
parsed, _ = parser.parse_known_args()

path_types: str
if parsed.no_dirs and parsed.no_files:
	print("--no-dirs AND --no-files are True. No action.")
	exit()
elif parsed.no_dirs:
	path_types = "files"
elif parsed.no_files:
	path_types = "directories"
else:
	path_types = "directories and files"

path = Path(parsed.path).resolve()
print(f"Removing bad characters from {path_types} in {path}")
for p in path.glob("*"):
    if parsed.no_dirs and p.is_dir():
        continue

    if parsed.no_files and p.is_file():
        continue

    p.rename(p.parent / re.sub(r"[\\/:\"\',*?<>|\[\]\-\s]+", "", p.name))
