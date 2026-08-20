from pathlib import Path

import fire

from .pipeline import DEFAULT_DATA_DIR, build_city


def build(
    city: str,
    output: str | None = None,
    root_only: bool = False,
    image_width: int = 1280,
    workers: int = 8,
    max_additional: int = 20,
) -> None:
    """Build an offline Markdown guide from English Wikivoyage."""
    destination = build_city(
        city=city,
        output_root=Path(output) if output else DEFAULT_DATA_DIR,
        root_only=root_only,
        image_width=image_width,
        workers=workers,
        max_additional=max_additional,
    )
    page_count = len(list((destination / "pages").glob("*.md"))) - 1
    image_count = len(list((destination / "images").glob("*.webp")))
    print(f"Saved {page_count} pages and {image_count} photos to {destination}")


def main() -> None:
    fire.Fire(build)
