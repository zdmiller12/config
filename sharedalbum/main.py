#!/usr/bin/env python3.13
"""Automate downloading photos from an iCloud shared album via Playwright."""

from __future__ import annotations

import argparse
import asyncio
import shutil
from collections.abc import Iterable
from pathlib import Path

from playwright.async_api import async_playwright, Page


async def _click_first_existing(page: Page, selectors: Iterable[str]) -> bool:
    """Click the first selector that exists; return True if a click occurred."""
    for selector in selectors:
        locator = page.locator(selector)
        if await locator.count() > 0:
            await locator.first.click()
            return True
    return False


class SharedAlbum:
    def __init__(self, page, url: str, additional_clicks: Iterable[str] | None = None):
        self.additional_clicks = additional_clicks or []
        self.page = page
        self.url = url

    async def dismiss_banners(self) -> None:
        """Dismiss common cookie banners if present."""
        await _click_first_existing(
            self.page,
            (
                "button:has-text('Allow all')",
                "button:has-text('Accept all cookies')",
                "button:has-text('Accept & continue')",
                "button:has-text('Continue')",
                "button:has-text('Dismiss')",
            ),
        )

        for selector in self.additional_clicks:
            await _click_first_existing(self.page, (selector,))

    async def download(self, parent_dir: Path) -> Path:
        """Download current image and return its local path."""
        await self.page.mouse.move(100, 100)
        async with self.page.expect_download() as download_info:
            await self.page.get_by_text("Download").click()

        download = await download_info.value
        img_out = parent_dir / download.suggested_filename
        await download.save_as(img_out)
        print(f"Saved {img_out=}")
        return img_out

    async def home(self) -> None:
        await self.page.goto(self.url)
        await self.page.wait_for_load_state("networkidle")

    async def next(self) -> None:
        await self.page.keyboard.press("ArrowRight")
        await self.page.wait_for_load_state("networkidle")


async def download_shared_album(
    album_url: str,
    download_directory: Path,
    headless: bool = True,
    additional_clicks: Iterable[str] | None = None,
) -> Path:
    """Download a ZIP export of an iCloud shared album.

    Parameters
    ----------
    album_url:
        Public URL to the shared album (e.g. https://www.icloud.com/sharedalbum/... ).
    download_directory:
        Directory to place the downloaded archive in. Created if it does not exist.
    headless:
        Run the browser headless when True.
    additional_clicks:
        Optional CSS/text selectors to click after loading the album. This is handy for
        dismissing cookie prompts that vary by region.

    Returns
    -------
    Path to the output directory on disk.

    """
    async with async_playwright() as playwright:
        browser = await playwright.chromium.launch(
            headless=headless, args=["--start-maximized"]
        )
        context = await browser.new_context(accept_downloads=True, no_viewport=True)

        shared_album = SharedAlbum(
            await context.new_page(),
            album_url,
            additional_clicks,
        )
        await shared_album.home()
        # await shared_album.dismiss_banners()

        await shared_album.download(download_directory)

        for _ in range(245):
            await shared_album.next()
            await shared_album.download(download_directory)

        await context.close()
        await browser.close()

    return download_directory


def _clean_directory(directory: Path | str) -> Path:
    """Remove directory if it exists and recreate it."""
    directory = Path(directory).resolve()
    if directory.exists():
        shutil.rmtree(directory, ignore_errors=True)
    directory.mkdir(parents=True, exist_ok=True)
    return directory


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "album_url",
        help="Public URL for the iCloud shared album",
    )
    parser.add_argument(
        "-o",
        "--output",
        default=Path.home() / "icloud",
        dest="output",
        help="Directory where downloaded files should be saved",
        type=_clean_directory,
    )
    parser.add_argument(
        "--headless",
        action="store_true",
        dest="headless",
        help="Run the browser headless",
    )
    parser.add_argument(
        "-e",
        "--extra-click",
        action="append",
        default=[],
        dest="extra_clicks",
        help="Additional CSS/text selectors to click after the album loads",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    # breakpoint()
    destination = asyncio.run(
        download_shared_album(
            album_url=args.album_url,
            download_directory=args.output,
            headless=args.headless,
            additional_clicks=args.extra_clicks,
        )
    )
    print(f"Downloaded album archive to {destination}")


if __name__ == "__main__":
    main()
