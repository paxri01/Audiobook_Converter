#!/usr/bin/env python3
"""
parse_html.py — HTML metadata extractor for ccab
Usage: python3 parse_html.py <book.html>
Output: JSON to stdout with metadata fields

Supports: Amazon, Goodreads, Audible pages
Dependencies: Python 3 stdlib only (no pip install required)
"""

import sys
import re
import json
import html as html_lib


def unescape(text):
    """Decode HTML entities."""
    return html_lib.unescape(text).strip()


def first_match(html, patterns, flags=re.IGNORECASE | re.DOTALL):
    """Return first non-empty capture group from a list of regex patterns."""
    for pattern in patterns:
        m = re.search(pattern, html, flags)
        if m:
            return unescape(m.group(1)).strip()
    return ""


def detect_site(html):
    """Identify which site the HTML came from."""
    # Check Amazon first — Amazon pages contain audible.com/goodreads links
    if re.search(r'productTitle|richProductInformation|amazon\.com/dp/', html, re.IGNORECASE):
        return "amazon"
    # Audible-hosted pages have these unique markers
    if re.search(r'class="[^"]*adbl-[^"]*"|audible\.com/pd/', html, re.IGNORECASE):
        return "audible"
    if re.search(r'goodreads\.com/book/show|class="[^"]*BookPage[^"]*"', html, re.IGNORECASE):
        return "goodreads"
    # Amazon is the default
    return "amazon"


def primary_author(author):
    """Keep only the first author, stripping co-authors."""
    if not author:
        return author
    author = re.split(r'\s*[&;]\s*|\s+and\s+|\s+with\s+', author, maxsplit=1)[0]
    author = re.split(r'\s*,\s*(?=[A-Z])', author, maxsplit=1)[0]
    return author.strip()


# ---------------------------------------------------------------------------
# Amazon parser
# ---------------------------------------------------------------------------

def parse_amazon(html):
    result = {}

    # --- Title (may be compound: "Title: Series, Book N") ---
    raw_title = first_match(html, [
        r'id="productTitle"[^>]*>\s*([^<]+)',
        r'"bookTitle"\s*:\s*"([^"]+)"',
        r'<title>\s*(?:Amazon\.com:\s*)?([^:]+)',
    ])

    # Compound title patterns
    series = ""
    series_number = ""
    title = raw_title

    patterns = [
        # "Title: Series, Book N"  (comma before Book)
        r'^(.+?):\s*(.+),\s*Book\s*(\d+(?:\.\d+)?)$',
        # "Title: Series Book N"   (no comma — e.g. "Super!: Level Up! Book 5")
        r'^(.+?):\s*(.+?)\s+Book\s+(\d+(?:\.\d+)?)$',
        # "Title (Series Book N)"
        r'^(.+?)\s*\((.+?)\s+Book\s*(\d+(?:\.\d+)?)\)$',
        # "Title: Series #N"
        r'^(.+?):\s*(.+?)\s*#(\d+(?:\.\d+)?)$',
        # "Title - Series Book N"
        r'^(.+?)\s+-\s+(.+?)\s+Book\s*(\d+(?:\.\d+)?)$',
    ]
    for pat in patterns:
        m = re.match(pat, raw_title, re.IGNORECASE)
        if m:
            title = m.group(1).strip()
            series = m.group(2).strip()
            series_number = m.group(3).strip()
            break

    # Fallback: extract series number from "Book N of M" text in the page
    if not series_number:
        m = re.search(r'Book\s+(\d+(?:\.\d+)?)\s+of\s+\d+', html, re.IGNORECASE)
        if m:
            series_number = m.group(1)

    result["title"] = unescape(title)
    result["series"] = unescape(series)
    result["series_number"] = series_number

    # --- Author ---
    author = first_match(html, [
        r'"authorNameList"\s*:\s*\[.*?"name"\s*:\s*"([^"]+)"',
        r'class="[^"]*author[^"]*"[^>]*>[^<]*<[^>]*>([^<]+)',
        r'"author"\s*:\s*\{"name"\s*:\s*"([^"]+)"',
        r'(?:Written|Author)\s+by[^<>]*>\s*<[^>]+>([^<]+)',
    ])
    result["author"] = primary_author(unescape(author))

    # --- Narrator ---
    # Amazon stores narrator name in the search URL of the rpi-attribute section
    narrator = ""
    m = re.search(r'audiobook_details-narrator.*?href="/s\?k=([^&"]+)', html, re.DOTALL)
    if m:
        import urllib.parse
        narrator = urllib.parse.unquote_plus(m.group(1))
    if not narrator:
        narrator = first_match(html, [
            r'"narrator"\s*:\s*"([^"]+)"',
            r'read\s+by\s+([A-Z][^<,\n]{3,50})',
            r'narrated\s+by\s+([A-Z][^<,\n]{3,50})',
        ])
    result["narrator"] = primary_author(narrator)

    # --- ASIN ---
    asin = first_match(html, [
        r'name="ASIN"\s+value="([A-Z0-9]{10})"',
        r'/dp/([A-Z0-9]{10})',
        r'"ASIN"\s*:\s*"([A-Z0-9]{10})"',
        r'data-asin="([A-Z0-9]{10})"',
    ])
    result["asin"] = asin

    # --- Cover URL ---
    cover_url = first_match(html, [
        r'"hiRes"\s*:\s*"(https?://[^"]+)"',
        r'id="imgBlkFront"[^>]*src="(https?://[^"]+)"',
        r'id="ebooksImgBlkFront"[^>]*src="(https?://[^"]+)"',
        r'"large"\s*:\s*"(https?://[^"]+)"',
    ])
    result["cover_url"] = cover_url

    # --- Rating ---
    rating = first_match(html, [
        r'aria-label="(\d+(?:\.\d+)?)\s*out of 5 stars"',
        r'"ratingValue"\s*:\s*"?(\d+(?:\.\d+)?)"?',
    ])
    result["rating"] = rating

    # --- Release date ---
    release_date = first_match(html, [
        r'(?:Publication date|Release date)[^:]*:?\s*</[^>]+>\s*<[^>]+>\s*([A-Z][a-z]+ \d+, \d{4})',
        r'"datePublished"\s*:\s*"([^"]+)"',
        r'((?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d+,\s+\d{4})',
    ])
    result["release_date"] = release_date

    # --- Publisher ---
    publisher = first_match(html, [
        r'"publisherName"\s*:\s*"([^"]+)"',
        # rpi-attribute-value div structure (Amazon book detail cards)
        r'book_details-publisher.*?rpi-attribute-value[^>]*>\s*<[^>]*>\s*([^<]+)',
        r'class="[^"]*publisher[^"]*"[^>]*>([^<]+)',
        r'Publisher[^:]*:</span>\s*<span[^>]*>\s*([^<]+)',
        r'"publisher"\s*:\s*\{"name"\s*:\s*"([^"]+)"',
    ])
    result["publisher"] = publisher

    # --- Duration ---
    m = re.search(r'(\d+)\s*hours?\s+(?:and\s+)?(\d+)\s*minutes?', html, re.IGNORECASE)
    if m:
        result["duration"] = "{}h {}m".format(m.group(1), m.group(2))
    else:
        dur = first_match(html, [r'"duration"\s*:\s*"([^"]+)"'])
        result["duration"] = dur

    # --- Description ---
    description = ""
    m = re.search(r'<div[^>]+id="bookDescription_feature_div"[^>]*>(.*?)</noscript>',
                  html, re.DOTALL)
    if m:
        description = m.group(1)
    if not description:
        m = re.search(r'"description"\s*:\s*"([^"]{50,})"', html)
        if m:
            description = m.group(1)
    description = re.sub(r'<[^>]+>', '', description)
    description = re.sub(r'\s+', ' ', description).strip()
    # Trim at "Read more" or obvious page-content noise (max 1500 chars)
    description = re.split(r'\s+Read more\b', description, maxsplit=1)[0]
    description = description[:1500].strip()
    result["description"] = description

    # --- Series info (e.g. "Book 1 of 7 in ...") ---
    series_info = first_match(html, [
        r'Book \d+ of \d+ in[^<]+<[^>]*>([^<]+)',
        r'"seriesInfo"\s*:\s*"([^"]+)"',
    ])
    result["series_info"] = series_info

    return result


# ---------------------------------------------------------------------------
# Goodreads parser
# ---------------------------------------------------------------------------

def parse_goodreads(html):
    result = {}

    # Try JSON-LD first
    ld_matches = re.findall(
        r'<script[^>]+type="application/ld\+json"[^>]*>(.*?)</script>',
        html, re.DOTALL | re.IGNORECASE
    )
    ld = {}
    for raw in ld_matches:
        try:
            d = json.loads(raw.strip())
            if isinstance(d, dict) and d.get("@type") in ("Book", "Audiobook"):
                ld = d
                break
        except Exception:
            pass

    result["title"] = unescape(ld.get("name", "") or first_match(html, [
        r'<h1[^>]+data-testid="bookTitle"[^>]*>([^<]+)',
        r'<h1[^>]+class="[^"]*bookTitle[^"]*"[^>]*>([^<]+)',
    ]))

    raw_author = ""
    if "author" in ld:
        a = ld["author"]
        if isinstance(a, list): a = a[0]
        raw_author = a.get("name", "") if isinstance(a, dict) else str(a)
    if not raw_author:
        raw_author = first_match(html, [
            r'data-testid="name"[^>]*>([^<]+)',
            r'class="[^"]*authorName[^"]*"[^>]*>[^<]*<span[^>]*>([^<]+)',
        ])
    result["author"] = primary_author(unescape(raw_author))

    # Series
    series = first_match(html, [
        r'class="[^"]*bookSeries[^"]*"[^>]*>.*?\(([^)]+)\)',
        r'<a[^>]+href="/series/[^"]*"[^>]*>([^<]+)',
    ])
    series_number = ""
    if series:
        m = re.search(r'^(.+?)\s*#(\d+(?:\.\d+)?)$', series.strip())
        if m:
            series = m.group(1).strip()
            series_number = m.group(2)
    result["series"] = unescape(series)
    result["series_number"] = series_number

    # Genre (first genre tag)
    genre = first_match(html, [
        r'class="[^"]*BookPageMetadataSection__genre[^"]*"[^>]*>[^<]*<[^>]*>([^<]+)',
        r'data-testid="genresList"[^>]*>.*?<span[^>]*>([^<]+)',
    ])
    result["genre"] = genre

    # Rating
    rating = first_match(html, [
        r'"ratingValue"\s*:\s*"?(\d+(?:\.\d+)?)"?',
        r'data-testid="ratingsStatistics"[^>]*>.*?(\d+(?:\.\d+)?)\s+(?:avg|average)',
        r'class="[^"]*RatingStatistics__rating[^"]*"[^>]*>(\d+(?:\.\d+)?)',
    ])
    result["rating"] = rating

    # Description
    description = first_match(html, [
        r'data-testid="description"[^>]*>.*?<span[^>]*>([^<]{50,})',
        r'"description"\s*:\s*"([^"]{50,})"',
    ])
    description = re.sub(r'<[^>]+>', '', description)
    description = re.sub(r'\s+', ' ', description).strip()
    result["description"] = description

    # Cover
    cover = first_match(html, [
        r'id="coverImage"[^>]*src="(https?://[^"]+)"',
        r'"image"\s*:\s*"(https?://[^"]+)"',
        r'class="[^"]*BookCover[^"]*"[^>]*>.*?<img[^>]*src="(https?://[^"]+)"',
    ])
    result["cover_url"] = cover

    # Publication date
    pub_date = first_match(html, [
        r'(?:First published|Published).*?(\w+ \d+, \d{4})',
        r'"datePublished"\s*:\s*"([^"]+)"',
    ])
    result["release_date"] = pub_date

    # Publisher
    publisher = first_match(html, [
        r'class="[^"]*publisher[^"]*"[^>]*>([^<]+)',
        r'"publisher"\s*:\s*\{"name"\s*:\s*"([^"]+)"',
    ])
    result["publisher"] = publisher

    # ASIN / ISBN (Goodreads sometimes has this)
    asin = first_match(html, [r'"isbn"\s*:\s*"([^"]+)"', r'ASIN[:\s]+([A-Z0-9]{10})'])
    result["asin"] = asin

    result["narrator"] = ""
    result["duration"] = ""
    result["series_info"] = ""

    return result


# ---------------------------------------------------------------------------
# Audible parser
# ---------------------------------------------------------------------------

def parse_audible(html):
    result = {}

    # Title
    raw_title = first_match(html, [
        r'<h1[^>]+class="[^"]*bc-heading[^"]*"[^>]*>([^<]+)',
        r'<title>\s*([^|:<]+)',
        r'"og:title"[^>]*content="([^"]+)"',
    ])
    title = raw_title
    series = ""
    series_number = ""
    for pat in [
        r'^(.+?):\s*(.+),\s*Book\s*(\d+(?:\.\d+)?)$',
        r'^(.+?)\s*\((.+?)\s+Book\s*(\d+(?:\.\d+)?)\)$',
    ]:
        m = re.match(pat, raw_title, re.IGNORECASE)
        if m:
            title = m.group(1).strip()
            series = m.group(2).strip()
            series_number = m.group(3).strip()
            break
    result["title"] = unescape(title)
    result["series"] = unescape(series)
    result["series_number"] = series_number

    # Author
    author = first_match(html, [
        r'Written by[^<>]*>[^<]*<[^>]+>([^<]+)',
        r'"author"\s*:\s*\[?\s*\{[^}]*"name"\s*:\s*"([^"]+)"',
        r'class="[^"]*authorLabel[^"]*"[^>]*>([^<]+)',
    ])
    result["author"] = primary_author(unescape(author))

    # Narrator
    narrator = first_match(html, [
        r'Narrated by[^<>]*>[^<]*<[^>]+>([^<]+)',
        r'"narrator"\s*:\s*\[?\s*\{[^}]*"name"\s*:\s*"([^"]+)"',
        r'class="[^"]*narratorLabel[^"]*"[^>]*>([^<]+)',
    ])
    result["narrator"] = primary_author(narrator)

    # Rating
    result["rating"] = first_match(html, [
        r'aria-label="(\d+(?:\.\d+)?)\s*out of 5"',
        r'"ratingValue"\s*:\s*"?(\d+(?:\.\d+)?)"?',
    ])

    # Cover
    result["cover_url"] = first_match(html, [
        r'"og:image"[^>]*content="(https?://[^"]+)"',
        r'class="[^"]*product-image[^"]*"[^>]*src="(https?://[^"]+)"',
    ])

    # ASIN
    result["asin"] = first_match(html, [
        r'/pd/([A-Z0-9]{10})',
        r'data-asin="([A-Z0-9]{10})"',
    ])

    # Duration
    m = re.search(r'(\d+)\s*hrs?\s*(?:and\s+)?(\d+)\s*mins?', html, re.IGNORECASE)
    if m:
        result["duration"] = "{}h {}m".format(m.group(1), m.group(2))
    else:
        result["duration"] = first_match(html, [r'"duration"\s*:\s*"([^"]+)"'])

    # Publisher
    result["publisher"] = first_match(html, [
        r'Publisher[^:]*:.*?<span[^>]*>([^<]+)',
        r'"publisherName"\s*:\s*"([^"]+)"',
    ])

    # Release date
    result["release_date"] = first_match(html, [
        r'"datePublished"\s*:\s*"([^"]+)"',
        r'Release date[^<]*<[^>]+>([^<]+)',
    ])

    # Description
    desc = first_match(html, [
        r'class="[^"]*productDescription[^"]*"[^>]*>([^<]{50,})',
        r'"description"\s*:\s*"([^"]{50,})"',
    ])
    desc = re.sub(r'<[^>]+>', '', desc)
    desc = re.sub(r'\s+', ' ', desc).strip()
    result["description"] = desc
    result["series_info"] = ""
    result["genre"] = ""

    return result


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def parse(html_path):
    with open(html_path, encoding="utf-8", errors="replace") as f:
        html = f.read()

    site = detect_site(html)

    if site == "goodreads":
        result = parse_goodreads(html)
    elif site == "audible":
        result = parse_audible(html)
    else:
        result = parse_amazon(html)

    # Ensure all expected keys exist
    for key in ("title", "author", "narrator", "series", "series_number",
                "publisher", "duration", "release_date", "asin",
                "series_info", "rating", "cover_url", "description", "genre"):
        result.setdefault(key, "")

    return result


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: parse_html.py <book.html>", file=sys.stderr)
        sys.exit(1)

    try:
        data = parse(sys.argv[1])
        json.dump(data, sys.stdout, indent=2, ensure_ascii=False)
        print()  # trailing newline
    except FileNotFoundError:
        print("Error: file not found: {}".format(sys.argv[1]), file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print("Error: {}".format(e), file=sys.stderr)
        sys.exit(1)
