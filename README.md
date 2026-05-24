# ccab — Audiobook Conversion and Archive Builder

A bash-based toolkit for re-encoding, tagging, and organizing audiobook files. `ccab` extracts metadata from existing ID3 tags and optionally from a saved HTML page (`book.html`), encodes to MP3 with proper tags, and optionally moves the result into a genre-organized directory tree.

## Features

- Extracts ID3 metadata from source audio files
- Scrapes metadata from saved Amazon, Audible, or Goodreads HTML pages
- Searches Google Books API as a fallback metadata source
- Encodes to MP3 (bitrate capped at 48k for audiobook efficiency)
- Optionally combines multi-file audiobooks into a single file
- Organizes output into a genre-based directory tree
- Sends desktop notifications on completion
- Interactive metadata verification before encoding

## Requirements

| Dependency | Purpose |
|------------|---------|
| `ffmpeg` / `ffprobe` | Audio conversion and probing |
| `mid3v2` | ID3 tag writing (from `mutagen`) |
| `jq` | JSON processing |
| `curl` | Cover art download and API requests |
| `python3` | HTML metadata parsing (stdlib only) |

After installing dependencies, run `ccab --check` to verify everything is in place.

### Installing dependencies (Fedora/RHEL)

```bash
sudo dnf install ffmpeg python3 jq curl
pip install mutagen   # provides mid3v2
```

### Installing dependencies (Debian/Ubuntu)

```bash
sudo apt install ffmpeg python3 jq curl
pip install mutagen
```

## Installation

```bash
git clone https://github.com/paxri01/ccab.git
cd ccab
./install.sh
```

The installer places:
- Binary → `~/.local/bin/ccab`
- Libraries → `~/.local/share/ccab/lib/`
- Config → `~/.config/smart-ccab.conf` (only if not already present)

To uninstall:

```bash
./install.sh uninstall
```

## Usage

```
ccab [OPTIONS] [DIRECTORY]
```

| Option | Description |
|--------|-------------|
| `-m <MODE>` | Move final files to a genre directory (1=Fantasy, 2=SciFi, 3=Thriller, 4=Romance, 5=Erotica, 6=Misc) |
| `-c` | Combine multiple audio files into one before processing |
| `-v` | Interactively verify/edit metadata before encoding |
| `-x` | Extract and search metadata only — no conversion |
| `-t <DIR>` | Convert using pre-extracted metadata from a directory |
| `-u` | Update an existing `.info` file from a fresh `book.html` |
| `--check` | Verify all required dependencies are installed |
| `-h` | Show help |

### Common workflows

```bash
# Standard: extract metadata, encode, move to Fantasy
ccab -m 1

# Multi-file: combine chapters first, then encode and move
ccab -c -m 1

# Review metadata interactively before encoding
ccab -m 1 -v

# Metadata-only run (no encoding)
ccab -x

# Re-use a previously extracted metadata session
ccab -t /tmp/ccab/my-session

# Refresh metadata from a new book.html
ccab -u

# Verify dependencies
ccab --check
```

## HTML metadata scraping

For richer metadata, save the book's Amazon, Audible, or Goodreads page as an HTML file before running `ccab`. The default path is `/tmp/book.html` (configurable via `htmlBookFile` in the config).

```bash
# Save the page in your browser to /tmp/book.html, then:
ccab -m 1
```

The Python parser (`lib/parse_html.py`) auto-detects the site and extracts title, author, series, narrator, publisher, release date, description, and cover URL. It can also be tested standalone:

```bash
python3 lib/parse_html.py tests/book.html | jq .
```

## Configuration

`~/.config/smart-ccab.conf` is sourced at startup. Key settings:

| Variable | Default | Description |
|----------|---------|-------------|
| `logLevel` | `INFO` | Verbosity: `ERROR`, `WARN`, `INFO`, `DEBUG`, `TRACE` |
| `logDir` | `/var/log/ccab` | Log file directory |
| `targetBitrate` | `48k` | MP3 encode bitrate (capped at 48k internally) |
| `audioChannels` | `stereo` | Output channels: `stereo` or `mono` |
| `htmlBookFile` | `/tmp/book.html` | Path to the saved HTML page |
| `webscrapeEnabled` | `true` | Enable HTML scraping |
| `AUDIOBOOK_BASE_DIR` | `/audio/audiobooks` | Root of the organized library |
| `MOVE_1`–`MOVE_6` | Fantasy … Misc | Genre labels for `-m` modes |
| `enableThumbnails` | `true` | Show cover thumbnail in desktop notifications |
| `CLEANUP_WORKING_DIR_AFTER_MOVE` | `true` | Remove `/tmp/ccab/` session after successful move |

### Google Books API (optional)

For the search fallback, add credentials to `~/.config/keys`:

```bash
_api_key="YOUR_GOOGLE_API_KEY"
_engine_id="YOUR_CUSTOM_SEARCH_ENGINE_ID"
```

## Output structure

Organized files are placed under:

```
$AUDIOBOOK_BASE_DIR / <Genre> / <Last, First> / <Series NN - Title> /
```

Example:

```
/audio/audiobooks/Fantasy/Sanderson, Brandon/Stormlight 01 - The Way of Kings/
```

## Development

```bash
# Syntax-check all shell files
bash -n bin/ccab lib/*.sh

# Lint all shell files
shellcheck bin/ccab install.sh lib/*.sh

# Test the HTML parser against the included fixture
python3 lib/parse_html.py tests/book.html | jq .
```

There is no build step. The binary runs directly as `bash bin/ccab`.

## License

Apache 2.0
