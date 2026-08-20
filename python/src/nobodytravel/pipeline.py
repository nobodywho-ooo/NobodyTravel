from __future__ import annotations

import hashlib
import html
import io
import math
import re
import shutil
import tempfile
import threading
import time
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from pathlib import Path
from typing import Self
from urllib.parse import quote, unquote, urljoin, urlsplit

import httpx
from bs4 import BeautifulSoup, Tag
from markitdown import MarkItDown
from PIL import Image, ImageOps
from tenacity import retry, retry_if_exception, stop_after_attempt, wait_exponential
from tqdm import tqdm

API_URL = "https://en.wikivoyage.org/w/api.php"
REST_URL = "https://en.wikivoyage.org/w/rest.php/v1/page/{title}/html"
USER_AGENT = "nobodytravel/0.1 (https://github.com/duarteocarmo/nobodytravel)"
PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DATA_DIR = PROJECT_ROOT / "data"
RETRYABLE_STATUS_CODES = {408, 425, 429, 500, 502, 503, 504}


def retryable_request_error(*, error: BaseException) -> bool:
    if isinstance(error, httpx.TransportError):
        return True
    if isinstance(error, httpx.HTTPStatusError):
        return error.response.status_code in RETRYABLE_STATUS_CODES
    return False


class RequestRateLimiter:
    def __init__(self, *, requests_per_second: float) -> None:
        self.interval = 1 / requests_per_second
        self.next_request = 0.0
        self.cooldown_until = 0.0
        self.lock = threading.Lock()

    def wait(self) -> None:
        with self.lock:
            now = time.monotonic()
            delay = max(self.next_request, self.cooldown_until) - now
            if delay > 0:
                time.sleep(delay)
            self.next_request = time.monotonic() + self.interval

    def cooldown(self, *, seconds: int) -> None:
        with self.lock:
            self.cooldown_until = max(self.cooldown_until, time.monotonic() + seconds)


@dataclass
class Page:
    title: str
    html: str
    revision: str
    modified: str
    slug: str

    @property
    def source_url(self) -> str:
        title = quote(self.title.replace(" ", "_"), safe="/")
        return f"https://en.wikivoyage.org/wiki/{title}"


@dataclass
class Candidate:
    title: str
    mentions: int
    sources: set[str]
    categories: set[str]
    distance: float | None


@dataclass
class ImageAsset:
    title: str
    thumbnail_url: str
    source_url: str
    author: str
    credit: str
    license_name: str
    license_url: str
    local_name: str
    used_by: set[str] = field(default_factory=set)


class WikivoyageClient:
    def __init__(self) -> None:
        self.client = httpx.Client(
            follow_redirects=True,
            headers={"User-Agent": USER_AGENT},
            timeout=60,
        )
        self.image_rate_limiter = RequestRateLimiter(requests_per_second=2.5)

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *_: object) -> None:
        self.client.close()

    @retry(
        retry=retry_if_exception(lambda error: retryable_request_error(error=error)),
        wait=wait_exponential(multiplier=1, min=1, max=10),
        stop=stop_after_attempt(6),
        reraise=True,
    )
    def request(
        self,
        *,
        method: str,
        url: str,
        params: dict[str, str] | None = None,
        data: dict[str, str] | None = None,
    ) -> httpx.Response:
        is_image_request = url.startswith("https://upload.wikimedia.org/")
        if is_image_request:
            self.image_rate_limiter.wait()
        response = self.client.request(
            method=method,
            url=url,
            params=params,
            data=data,
        )
        if is_image_request and response.status_code == 429:
            try:
                retry_after = min(int(response.headers.get("retry-after", 10)), 10)
            except ValueError:
                retry_after = 10
            self.image_rate_limiter.cooldown(seconds=retry_after)
        response.raise_for_status()
        return response

    def api(self, *, params: dict[str, object], post: bool = False) -> dict:
        encoded_params = {key: str(value) for key, value in params.items()}
        response = self.request(
            method="POST" if post else "GET",
            url=API_URL,
            data=encoded_params if post else None,
            params=None if post else encoded_params,
        )
        return response.json()

    def resolve_title(self, *, title: str) -> str:
        result = self.api(
            params={
                "action": "query",
                "titles": title,
                "redirects": 1,
                "format": "json",
                "formatversion": 2,
            }
        )
        page = result["query"]["pages"][0]
        if "missing" in page:
            raise ValueError(f"Wikivoyage page not found: {title}")
        return page["title"]

    def discover_pages(self, *, city: str, root_only: bool = False) -> list[str]:
        root = self.resolve_title(title=city)
        if root_only:
            return [root]

        descendants = self.api(
            params={
                "action": "query",
                "list": "allpages",
                "apprefix": f"{root}/",
                "apnamespace": 0,
                "apfilterredir": "nonredirects",
                "aplimit": "max",
                "format": "json",
                "formatversion": 2,
            }
        )["query"]["allpages"]
        links = self.api(
            params={
                "action": "parse",
                "page": root,
                "prop": "links",
                "format": "json",
                "formatversion": 2,
            }
        )["parse"]["links"]

        titles = {page["title"] for page in descendants}
        root_name = root.casefold()
        titles.update(
            link["title"]
            for link in links
            if link["ns"] == 0
            and "exists" in link
            and root_name in link["title"].casefold()
            and link["title"] != root
        )
        return [root, *sorted(titles)]

    def discover_additional_pages(
        self,
        *,
        root: str,
        pages: list[Page],
        limit: int,
    ) -> list[str]:
        if limit <= 0:
            return []

        mentions: Counter[str] = Counter()
        sources: defaultdict[str, set[str]] = defaultdict(set)
        for page in pages:
            soup = BeautifulSoup(markup=page.html, features="html.parser")
            for anchor in soup.find_all("a", href=True):
                if not isinstance(anchor, Tag):
                    continue
                target = wiki_title_from_href(href=str(anchor.get("href", "")))
                if target is None:
                    continue
                title, _ = target
                if ":" in title.split("/")[0]:
                    continue
                mentions[title] += 1
                sources[title].add(page.title)

        transitions: dict[str, str] = {}
        page_records: dict[str, dict] = {}
        requested_titles = sorted({root, *mentions})
        for batch in batched(values=requested_titles, size=10):
            query = self.api(
                params={
                    "action": "query",
                    "titles": "|".join(batch),
                    "redirects": 1,
                    "prop": "coordinates|categories",
                    "coprimary": "primary",
                    "colimit": "max",
                    "cllimit": "max",
                    "format": "json",
                    "formatversion": 2,
                },
                post=True,
            )["query"]
            transitions.update(title_transitions(query=query))
            for record in query.get("pages", []):
                if "missing" not in record:
                    page_records[normalized_title(value=record["title"])] = record

        included = {normalized_title(value=page.title) for page in pages}
        merged: dict[str, Candidate] = {}
        for title, count in mentions.items():
            resolved = follow_transitions(title=title, transitions=transitions)
            key = normalized_title(value=resolved)
            record = page_records.get(key)
            if record is None or record["ns"] != 0 or key in included:
                continue
            candidate = merged.setdefault(
                key,
                candidate_from_record(
                    record=record,
                    root_record=page_records[normalized_title(value=root)],
                ),
            )
            candidate.mentions += count
            candidate.sources.update(sources[title])

        return select_candidates(
            candidates=list(merged.values()),
            root=root,
            limit=limit,
        )

    def fetch_page(self, *, title: str) -> Page:
        encoded_title = quote(title.replace(" ", "_"), safe="")
        response = self.request(
            method="GET",
            url=REST_URL.format(title=encoded_title),
        )
        return Page(
            title=title,
            html=response.text,
            revision=response.headers.get("content-revision-id", "unknown"),
            modified=response.headers.get("last-modified", "unknown"),
            slug=slugify(value=title),
        )

    def fetch_pages(
        self,
        *,
        titles: list[str],
        workers: int,
        description: str,
    ) -> list[Page]:
        pages: dict[str, Page] = {}
        with ThreadPoolExecutor(max_workers=max(1, min(workers, 4))) as executor:
            futures = {
                executor.submit(self.fetch_page, title=title): title for title in titles
            }
            completed = tqdm(
                iterable=as_completed(futures),
                total=len(futures),
                desc=description,
                unit="article",
            )
            for future in completed:
                title = futures[future]
                pages[title] = future.result()
        return [pages[title] for title in titles]

    def fetch_image_assets(
        self, *, titles: set[str], width: int
    ) -> dict[str, ImageAsset]:
        assets: dict[str, ImageAsset] = {}
        assets_by_source: dict[str, ImageAsset] = {}
        for batch in batched(values=sorted(titles), size=25):
            result = self.api(
                params={
                    "action": "query",
                    "titles": "|".join(batch),
                    "redirects": 1,
                    "prop": "imageinfo",
                    "iiprop": "url|size|mime|extmetadata",
                    "iiurlwidth": width,
                    "format": "json",
                    "formatversion": 2,
                },
                post=True,
            )
            transitions = title_transitions(query=result["query"])
            pages = result["query"]["pages"]
            page_assets: dict[str, ImageAsset] = {}
            for page in pages:
                if (
                    not page.get("imageinfo")
                    or page["imageinfo"][0].get("mime") != "image/jpeg"
                ):
                    continue
                asset = asset_from_page(page=page)
                asset = assets_by_source.setdefault(asset.source_url, asset)
                page_assets[normalized_title(value=page["title"])] = asset
            for title in batch:
                resolved = follow_transitions(title=title, transitions=transitions)
                asset = page_assets.get(normalized_title(value=resolved))
                if asset is not None:
                    assets[normalized_title(value=title)] = asset
        return assets

    def download_image(
        self, *, asset: ImageAsset, destination: Path, width: int
    ) -> None:
        response = self.request(method="GET", url=asset.thumbnail_url)
        with Image.open(io.BytesIO(response.content)) as source:
            image = ImageOps.exif_transpose(source).convert("RGB")
            image.thumbnail(size=(width, width), resample=Image.Resampling.LANCZOS)
            image.save(destination, format="WEBP", quality=80, method=4)


def slugify(*, value: str) -> str:
    slug = re.sub(r"[^\w]+", "-", value.casefold(), flags=re.UNICODE).strip("-")
    return slug or "page"


def normalized_title(*, value: str) -> str:
    return unquote(value).replace("_", " ").casefold()


def batched(*, values: list[str], size: int) -> list[list[str]]:
    return [values[index : index + size] for index in range(0, len(values), size)]


def title_transitions(*, query: dict) -> dict[str, str]:
    transitions: dict[str, str] = {}
    for transition in [*query.get("normalized", []), *query.get("redirects", [])]:
        transitions[normalized_title(value=transition["from"])] = transition["to"]
    return transitions


def follow_transitions(*, title: str, transitions: dict[str, str]) -> str:
    seen: set[str] = set()
    while normalized_title(value=title) in transitions:
        key = normalized_title(value=title)
        if key in seen:
            break
        seen.add(key)
        title = transitions[key]
    return title


def haversine_distance(*, latitude: float, longitude: float, root: dict) -> float:
    radius = 6371.0088
    latitude_delta = math.radians(latitude - root["lat"])
    longitude_delta = math.radians(longitude - root["lon"])
    root_latitude = math.radians(root["lat"])
    target_latitude = math.radians(latitude)
    value = (
        math.sin(latitude_delta / 2) ** 2
        + math.cos(root_latitude)
        * math.cos(target_latitude)
        * math.sin(longitude_delta / 2) ** 2
    )
    return 2 * radius * math.asin(math.sqrt(value))


def candidate_from_record(*, record: dict, root_record: dict) -> Candidate:
    coordinate = record.get("coordinates", [None])[0]
    root_coordinate = root_record["coordinates"][0]
    distance = None
    if coordinate is not None:
        distance = haversine_distance(
            latitude=coordinate["lat"],
            longitude=coordinate["lon"],
            root=root_coordinate,
        )
    return Candidate(
        title=record["title"],
        mentions=0,
        sources=set(),
        categories={category["title"] for category in record.get("categories", [])},
        distance=distance,
    )


def article_quality(*, candidate: Candidate) -> float:
    for status, quality in (
        ("Star", 1.25),
        ("Guide", 1.15),
        ("Usable", 1.0),
        ("Outline", 0.75),
    ):
        if f"Category:{status} articles" in candidate.categories:
            return quality
    return 0.9


def source_relevance(*, candidate: Candidate, root: str) -> float:
    source_weight = sum(
        3 if source == root else 2 if source.startswith(f"{root}/") else 0.5
        for source in candidate.sources
    )
    return source_weight + math.log1p(candidate.mentions)


def select_candidates(
    *, candidates: list[Candidate], root: str, limit: int
) -> list[str]:
    country_category = "Category:Country articles"
    destination_category = "Category:All destination articles"
    topic_categories = {"Category:Topic articles", "Category:Phrasebooks"}

    nearby = [
        candidate
        for candidate in candidates
        if destination_category in candidate.categories
        and country_category not in candidate.categories
        and candidate.distance is not None
        and candidate.distance <= 100
    ]
    countries = [
        candidate
        for candidate in candidates
        if country_category in candidate.categories
    ]
    topics = [
        candidate
        for candidate in candidates
        if candidate.categories & topic_categories
        and "Category:Flying" not in candidate.categories
    ]

    nearby.sort(
        key=lambda candidate: (
            -source_relevance(candidate=candidate, root=root)
            * article_quality(candidate=candidate)
            / (1 + (candidate.distance or 0) / 50),
            candidate.title,
        )
    )
    countries.sort(
        key=lambda candidate: (
            -source_relevance(candidate=candidate, root=root)
            * article_quality(candidate=candidate),
            candidate.title,
        )
    )
    topics.sort(
        key=lambda candidate: (
            -source_relevance(candidate=candidate, root=root)
            * article_quality(candidate=candidate),
            candidate.title,
        )
    )

    topic_quota = min(5, limit)
    country_quota = 1 if limit > topic_quota else 0
    nearby_quota = max(0, limit - topic_quota - country_quota)
    selected = [
        *nearby[:nearby_quota],
        *countries[:country_quota],
        *topics[:topic_quota],
    ]
    return [candidate.title for candidate in selected[:limit]]


def metadata_text(*, metadata: dict, key: str) -> str:
    value = str(metadata.get(key, {}).get("value", ""))
    if "<" not in value:
        return html.unescape(value).strip()
    return BeautifulSoup(markup=value, features="html.parser").get_text(" ", strip=True)


def asset_from_page(*, page: dict) -> ImageAsset:
    info = page["imageinfo"][0]
    metadata = info.get("extmetadata", {})
    title = page["title"]
    digest = hashlib.sha256(title.encode()).hexdigest()[:10]
    local_name = f"{slugify(value=title.removeprefix('File:'))[:80]}-{digest}.webp"
    return ImageAsset(
        title=title,
        thumbnail_url=info.get("thumburl", info["url"]),
        source_url=info["descriptionurl"],
        author=metadata_text(metadata=metadata, key="Artist"),
        credit=metadata_text(metadata=metadata, key="Credit"),
        license_name=metadata_text(metadata=metadata, key="LicenseShortName"),
        license_url=metadata_text(metadata=metadata, key="LicenseUrl"),
        local_name=local_name,
    )


def photo_title_for(*, figure: Tag) -> str | None:
    classes = {str(value) for value in figure.get_attribute_list("class")}
    if "mw-kartographer-container" in classes:
        return None
    image = figure.find("img", resource=True)
    if not isinstance(image, Tag):
        return None
    resource = unquote(str(image.get("resource", ""))).removeprefix("./")
    if not resource.casefold().endswith((".jpg", ".jpeg")):
        return None
    return resource


def extract_photo_titles(*, html: str) -> set[str]:
    soup = BeautifulSoup(markup=html, features="html.parser")
    return {
        title
        for figure in soup.find_all("figure")
        if isinstance(figure, Tag) and (title := photo_title_for(figure=figure))
    }


def wiki_title_from_href(*, href: str) -> tuple[str, str] | None:
    if not href.startswith("./") or href.startswith("./File:"):
        return None
    parsed = urlsplit(href)
    title = unquote(parsed.path.removeprefix("./")).replace("_", " ")
    return title, parsed.fragment


def absolute_link(*, href: str, source_url: str) -> str:
    if href.startswith(("#", "/", "//", "http://", "https://", "mailto:", "tel:")):
        return urljoin(source_url, href)
    if not href.startswith("./"):
        return urljoin(source_url, href)

    parsed = urlsplit(href)
    title = unquote(parsed.path.removeprefix("./")).replace("_", " ")
    fragment = f"#{parsed.fragment}" if parsed.fragment else ""
    if title.startswith("d:"):
        wikidata_title = quote(title.removeprefix("d:").replace(" ", "_"))
        return f"https://www.wikidata.org/wiki/{wikidata_title}{fragment}"
    if title.startswith("w:"):
        wikipedia_title = quote(title.removeprefix("w:").replace(" ", "_"), safe="/")
        return f"https://en.wikipedia.org/wiki/{wikipedia_title}{fragment}"
    wikivoyage_title = quote(title.replace(" ", "_"), safe="/:")
    return f"https://en.wikivoyage.org/wiki/{wikivoyage_title}{fragment}"


def extract_links(*, pages: list[Page]) -> set[str]:
    links: set[str] = set()
    for page in pages:
        soup = BeautifulSoup(markup=page.html, features="html.parser")
        for anchor in soup.find_all("a", href=True):
            if not isinstance(anchor, Tag):
                continue
            href = str(anchor.get("href", "")).strip()
            if href:
                links.add(absolute_link(href=href, source_url=page.source_url))
    return links


def rewrite_links(*, soup: BeautifulSoup, pages: dict[str, Page]) -> None:
    by_title = {normalized_title(value=page.title): page for page in pages.values()}
    for anchor in soup.find_all("a", href=True):
        if not isinstance(anchor, Tag):
            continue
        href = str(anchor.get("href", ""))
        classes = {str(value) for value in anchor.get_attribute_list("class")}
        if "/wiki/Special:Map/" in href or "mw-kartographer" in classes:
            anchor.decompose()
            continue
        target = wiki_title_from_href(href=href)
        if target is None:
            continue
        title, fragment = target
        page = by_title.get(normalized_title(value=title))
        if page is not None:
            anchor["href"] = f"{page.slug}.md" + (f"#{fragment}" if fragment else "")
            continue
        encoded = quote(title.replace(" ", "_"), safe="/")
        anchor["href"] = f"https://en.wikivoyage.org/wiki/{encoded}"
        if fragment:
            anchor["href"] += f"#{fragment}"


def clean_page(
    *,
    page: Page,
    pages: dict[str, Page],
    assets: dict[str, ImageAsset],
) -> str:
    soup = BeautifulSoup(markup=page.html, features="html.parser")
    for element in soup.select("style, script, link, meta, .listing-coordinates"):
        element.decompose()

    for figure in soup.find_all("figure"):
        if not isinstance(figure, Tag):
            continue
        title = photo_title_for(figure=figure)
        asset = assets.get(normalized_title(value=title)) if title else None
        if asset is None:
            figure.decompose()
            continue
        asset.used_by.add(page.title)
        caption_node = figure.find("figcaption")
        caption = (
            caption_node.get_text(" ", strip=True) if caption_node else asset.title
        )
        image = soup.new_tag("img")
        image["src"] = f"../images/{asset.local_name}"
        image["alt"] = caption
        figure.replace_with(image)

    for image in soup.find_all("img"):
        if isinstance(image, Tag) and not str(image.get("src", "")).startswith(
            "../images/"
        ):
            image.decompose()
    for anchor in soup.find_all("a"):
        if (
            isinstance(anchor, Tag)
            and not anchor.get_text(strip=True)
            and anchor.find("img") is None
        ):
            anchor.decompose()

    rewrite_links(soup=soup, pages=pages)
    markdown = (
        MarkItDown()
        .convert_stream(
            stream=io.BytesIO(str(soup).encode()),
            file_extension=".html",
        )
        .text_content.strip()
    )
    header = (
        "---\n"
        f'title: "{page.title.replace(chr(34), chr(39))}"\n'
        f'source: "{page.source_url}"\n'
        f'revision: "{page.revision}"\n'
        f'modified: "{page.modified}"\n'
        'license: "CC BY-SA 4.0"\n'
        "---\n\n"
        f"# {page.title}\n\n"
    )
    return header + markdown + "\n"


def attribution_markdown(*, assets: dict[str, ImageAsset]) -> str:
    unique_assets = {asset.source_url: asset for asset in assets.values()}
    lines = [
        "# Image attributions",
        "",
        "Images were downloaded from Wikimedia Commons and converted to WebP.",
        "",
    ]
    for asset in sorted(unique_assets.values(), key=lambda value: value.title):
        license_text = asset.license_name or "See source"
        license_link = (
            f"[{license_text}]({asset.license_url})"
            if asset.license_url
            else license_text
        )
        lines.extend(
            [
                f"## {asset.title.removeprefix('File:')}",
                "",
                f"- File: `../images/{asset.local_name}`",
                f"- Source: [{asset.source_url}]({asset.source_url})",
                f"- Author: {asset.author or 'See source'}",
                f"- Credit: {asset.credit or 'See source'}",
                f"- License: {license_link}",
                f"- Used by: {', '.join(sorted(asset.used_by))}",
                "",
            ]
        )
    return "\n".join(lines)


def build_city(
    *,
    city: str,
    output_root: Path = DEFAULT_DATA_DIR,
    root_only: bool = False,
    image_width: int = 1280,
    workers: int = 8,
    max_additional: int = 20,
) -> Path:
    output_root.mkdir(parents=True, exist_ok=True)
    with WikivoyageClient() as client:
        base_titles = client.discover_pages(city=city, root_only=root_only)
        base_pages = client.fetch_pages(
            titles=base_titles,
            workers=workers,
            description="Base articles",
        )
        additional_titles = []
        if not root_only:
            additional_titles = client.discover_additional_pages(
                root=base_titles[0],
                pages=base_pages,
                limit=max_additional,
            )
        print(f"Selected {len(additional_titles)} additional articles.")

        additional_pages = []
        if additional_titles:
            additional_pages = client.fetch_pages(
                titles=additional_titles,
                workers=workers,
                description="Additional articles",
            )
        page_list = [*base_pages, *additional_pages]
        print(f"Downloaded {len(page_list)} articles.")

        pages = {normalized_title(value=page.title): page for page in page_list}
        photo_titles = set().union(
            *(extract_photo_titles(html=page.html) for page in page_list)
        )
        assets = client.fetch_image_assets(titles=photo_titles, width=image_width)
        unique_assets = {asset.source_url: asset for asset in assets.values()}
        print(f"Found {len(unique_assets)} unique photos.")

        city_slug = slugify(value=page_list[0].title)
        destination = output_root / city_slug
        existing_images = destination / "images"
        image_cache = output_root / ".cache" / "images" / str(image_width)
        image_cache.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=output_root) as temporary_directory:
            temporary_root = Path(temporary_directory) / city_slug
            images_directory = temporary_root / "images"
            pages_directory = temporary_root / "pages"
            images_directory.mkdir(parents=True)
            pages_directory.mkdir(parents=True)

            def package_image(*, asset: ImageAsset) -> None:
                packaged_image = images_directory / asset.local_name
                existing_image = existing_images / asset.local_name
                cached_image = image_cache / asset.local_name
                if existing_image.exists():
                    shutil.copy2(existing_image, packaged_image)
                    if not cached_image.exists():
                        shutil.copy2(existing_image, cached_image)
                    return
                if cached_image.exists():
                    shutil.copy2(cached_image, packaged_image)
                    return

                temporary_image = cached_image.with_suffix(".tmp")
                try:
                    client.download_image(
                        asset=asset,
                        destination=temporary_image,
                        width=image_width,
                    )
                    temporary_image.replace(cached_image)
                finally:
                    temporary_image.unlink(missing_ok=True)
                shutil.copy2(cached_image, packaged_image)

            with ThreadPoolExecutor(max_workers=max(1, workers)) as executor:
                futures = [
                    executor.submit(package_image, asset=asset)
                    for asset in unique_assets.values()
                ]
                completed = tqdm(
                    iterable=as_completed(futures),
                    total=len(futures),
                    desc="Images",
                    unit="image",
                )
                for future in completed:
                    future.result()

            for page in page_list:
                markdown = clean_page(page=page, pages=pages, assets=assets)
                (pages_directory / f"{page.slug}.md").write_text(markdown)
            (pages_directory / "_attributions.md").write_text(
                attribution_markdown(assets=assets)
            )
            links = extract_links(pages=page_list)
            (temporary_root / "links.txt").write_text("\n".join(sorted(links)) + "\n")

            if destination.exists():
                shutil.rmtree(destination)
            shutil.move(str(temporary_root), destination)

    return destination
