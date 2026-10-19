# SharedAlbum

This repository now includes a script that automates downloading the full contents of an iCloud shared album using [Playwright](https://playwright.dev/).

1. Install the Python dependencies and the Playwright browser binaries:
   ```bash
   pip install -r requirements.txt
   playwright install chromium
   ```
2. Run the downloader, for which help can be printed, like
   ```bash
   ./main.py --help
   ```
