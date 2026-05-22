#!/bin/bash
# shellcheck disable=SC2155,SC2034,SC2004,SC2154,SC2001

## ========================================================================================
##       Title: metadata.sh
##      Author: R. L. Paxton
##     Version: 2.0
##        Date: 2026-04-08
##     License: Apache 2.0
## Description: Metadata extraction, merging, ID3 tagging, and display for ccab
##              Consolidates: manage_metadata.sh, merge_metadata.sh, id3_management.sh,
##              display_messages.sh, metadata_confirmation.sh
## ========================================================================================

# Prevent multiple sourcing
if [[ "${METADATA_SOURCED:-}" == "true" ]]; then
    return 0
fi
export METADATA_SOURCED="true"

# Directory for asset files (music_note.png used by notify-send)
_METADATA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------

format_duration()
{
    local duration="${1%.*}"
    [[ ! "$duration" =~ ^[0-9]+$ ]] && { echo "$1"; return; }
    local h=$((duration/3600)) m=$(((duration%3600)/60)) s=$((duration%60))
    if   [[ $h -gt 0 ]]; then printf "%dh %02dm %02ds" "$h" "$m" "$s"
    elif [[ $m -gt 0 ]]; then printf "%dm %02ds" "$m" "$s"
    else printf "%ds" "$s"; fi
}

format_bitrate()
{
    local bitrate="$1"
    [[ ! "$bitrate" =~ ^[0-9]+$ ]] && { echo "$1"; return; }
    printf "%d kbps" "$((bitrate/1000))"
}

# "First Last" -> "Last, First"
format_author_name()
{
    local author="$1"
    local -n _fan_ref="$2"
    if [[ -z "$author" ]]; then _fan_ref="Unknown"; return 0; fi
    local first="${author%%,*}"; first="${first%% and *}"; first="${first%% & *}"
    local words=()
    read -ra words <<< "$first"
    local wc=${#words[@]}
    if   [[ $wc -eq 1 ]]; then _fan_ref="$first"
    elif [[ $wc -eq 2 ]]; then _fan_ref="${words[1]}, ${words[0]}"
    else
        local last="${words[-1]}"
        local firsts="${words[*]:0:$((wc-1))}"
        _fan_ref="$last, $firsts"
    fi
    [[ ${#_fan_ref} -gt 50 ]] && _fan_ref="${_fan_ref:0:47}..."
}

# ---------------------------------------------------------------------------
# ID3 / metadata extraction from audio file
# ---------------------------------------------------------------------------

# Extract ID3 tags from audio file into global arrays at given index
extract_id3_metadata()
{
    local file="$1"
    local index="$2"

    local probe_output
    probe_output=$(ffprobe -v quiet -print_format json -show_format -show_data "$file" 2>/dev/null)
    if [[ $? -ne 0 || -z "$probe_output" ]]; then
        log_warn "Could not read metadata from: $(basename "$file")"
        return 1
    fi
    [[ -n "${CCAB_WORKING_DIR:-}" ]] && echo "$probe_output" > "$CCAB_WORKING_DIR/original_file_metadata.json"

    log_debug "Probed: $(basename "$file")"

    local title artist author album_artist album duration bit_rate description genre date asin series_info
    title=$(echo "$probe_output"       | jq -r '.format.tags.title // .format.tags.TITLE // ""' 2>/dev/null)
    artist=$(echo "$probe_output"      | jq -r '.format.tags.artist // .format.tags.ARTIST // ""' 2>/dev/null)
    author=$(echo "$probe_output"      | jq -r '.format.tags.author // .format.tags.AUTHOR // ""' 2>/dev/null)
    album_artist=$(echo "$probe_output"| jq -r '.format.tags.album_artist // .format.tags.ALBUM_ARTIST // ""' 2>/dev/null)
    album=$(echo "$probe_output"       | jq -r '.format.tags.album // .format.tags.ALBUM // ""' 2>/dev/null)
    series_info=$(echo "$probe_output" | jq -r '.format.tags.series // .format.tags.SERIES // ""' 2>/dev/null)
    duration=$(echo "$probe_output"    | jq -r '.format.duration // ""' 2>/dev/null)
    bit_rate=$(echo "$probe_output"    | jq -r '.format.bit_rate // ""' 2>/dev/null)
    description=$(echo "$probe_output" | jq -r '.format.tags.description // .format.tags.DESCRIPTION // .format.tags.comment // .format.tags.COMMENT // ""' 2>/dev/null)
    genre=$(echo "$probe_output"       | jq -r '.format.tags.genre // .format.tags.GENRE // ""' 2>/dev/null)
    date=$(echo "$probe_output"        | jq -r '.format.tags.date // .format.tags.DATE // .format.tags.year // .format.tags.YEAR // ""' 2>/dev/null)
    asin=$(echo "$probe_output"        | jq -r '.format.tags.asin // .format.tags.ASIN // ""' 2>/dev/null)

    # Strip series info from title if present
    local cleaned_title
    cleaned_title=$(sed -rn 's/.* - (.*)/\1/p' <<< "$title")
    titles[$index]="${cleaned_title:-$title}"
    albums[$index]="$album"
    durations[$index]="$duration"
    bitrates[$index]="$bit_rate"
    descriptions[$index]="$description"
    genres[$index]="$genre"
    dates[$index]="$date"
    asins[$index]="$asin"

    # Author priority: author > artist > album_artist
    if [[ -n "$author" ]];       then authors[$index]="$author"
    elif [[ -n "$artist" ]];     then authors[$index]="$artist"
    else                              authors[$index]="$album_artist"; fi

    # Parse series info
    [[ -z "$series_info" && -n "$album" ]]  && series_info="$album"
    [[ -z "$series_info" && -n "$title" ]]  && series_info="$title"

    if   [[ "$series_info" =~ ^(.+)[[:space:]]+(Book|#|Vol|Volume)[[:space:]]*([0-9]+) ]]; then
        series[$index]="${BASH_REMATCH[1]} ${BASH_REMATCH[3]}"
    elif [[ "$series_info" =~ ^(.+)[[:space:]]+([0-9]+)$ ]]; then
        series[$index]="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
    else
        series[$index]="$series_info"
    fi

    return 0
}

# Parse title/author/series from filename as fallback
parse_filename_metadata()
{
    local file="$1"
    local index="$2"

    local filename base_name
    filename=$(basename "$file")
    base_name="${filename%.*}"
    base_name="${base_name//_/ }"
    base_name="${base_name//Unabridged/}"
    base_name="${base_name//audiobook/}"
    base_name="${base_name//Audiobook/}"

    if   [[ "$base_name" =~ ^([^-]+)[[:space:]]*-[[:space:]]*([^-]+)[[:space:]]*-[[:space:]]*(.+)$ ]]; then
        authors[$index]="${BASH_REMATCH[1]}"
        series[$index]="${BASH_REMATCH[2]}"
        titles[$index]="${BASH_REMATCH[3]}"
    elif [[ "$base_name" =~ ^([^-]+)[[:space:]]*-[[:space:]]*(.+)$ ]]; then
        authors[$index]="${BASH_REMATCH[1]}"
        titles[$index]="${BASH_REMATCH[2]}"
        series[$index]=""
    else
        titles[$index]="$base_name"
        authors[$index]=""
        series[$index]=""
    fi
}

# Remove co-authors from author field at index
clean_author_field()
{
    local index="$1"
    local a="${authors[$index]:-}"
    if [[ -n "$a" ]]; then
        a="${a%%,*}"; a="${a%% and *}"; a="${a%% & *}"; a="${a%% with *}"
        authors[$index]="$(echo "$a" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    fi
}

# ---------------------------------------------------------------------------
# HTML parsing (calls parse_html.py)
# ---------------------------------------------------------------------------

parse_book_html()
{
    local index="$1"
    local html_file="${htmlBookFile:-/tmp/book.html}"

    [[ "${webscrapeEnabled:-true}" != "true" ]] && return 0
    if [[ ! -f "$html_file" ]]; then
        log_warn "book.html not found: $html_file"
        return 1
    fi

    log_info "Parsing metadata from: $html_file"

    local py_script="$_METADATA_LIB_DIR/parse_html.py"
    if [[ ! -f "$py_script" ]]; then
        log_error "HTML parser not found: $py_script"
        return 1
    fi

    local scraped_json
    scraped_json=$(python3 "$py_script" "$html_file" 2>/dev/null)
    if [[ $? -ne 0 || -z "$scraped_json" ]]; then
        log_warn "HTML parser returned no data"
        return 1
    fi

    # Load scraped variables from JSON
    scraped_title=$(echo "$scraped_json"        | jq -r '.title // ""' 2>/dev/null)
    scraped_author=$(echo "$scraped_json"       | jq -r '.author // ""' 2>/dev/null)
    scraped_narrator=$(echo "$scraped_json"     | jq -r '.narrator // ""' 2>/dev/null)
    scraped_series=$(echo "$scraped_json"       | jq -r '.series // ""' 2>/dev/null)
    scraped_series_number=$(echo "$scraped_json"| jq -r '.series_number // ""' 2>/dev/null)
    scraped_publisher=$(echo "$scraped_json"    | jq -r '.publisher // ""' 2>/dev/null)
    scraped_duration=$(echo "$scraped_json"     | jq -r '.duration // ""' 2>/dev/null)
    scraped_release_date=$(echo "$scraped_json" | jq -r '.release_date // ""' 2>/dev/null)
    scraped_asin=$(echo "$scraped_json"         | jq -r '.asin // ""' 2>/dev/null)
    scraped_language=$(echo "$scraped_json"     | jq -r '.series_info // ""' 2>/dev/null)
    scraped_rating=$(echo "$scraped_json"       | jq -r '.rating // ""' 2>/dev/null)
    scraped_cover_url=$(echo "$scraped_json"    | jq -r '.cover_url // ""' 2>/dev/null)
    scraped_description=$(echo "$scraped_json"  | jq -r '.description // ""' 2>/dev/null)

    log_info "HTML parsing complete"
    return 0
}

# ---------------------------------------------------------------------------
# Metadata merging from web scraping into global arrays
# ---------------------------------------------------------------------------

merge_audiobook_metadata()
{
    local index="$1"
    local webscrape_enabled="${2:-false}"

    [[ "$webscrape_enabled" != "true" ]] && return 0

    local ct="${titles[$index]:-}"
    local ca="${authors[$index]:-}"
    local cs="${series[$index]:-}"

    # Title: prefer web
    if   [[ -z "$ct" && -n "${scraped_title:-}" ]]; then
        titles[$index]="$scraped_title"
        log_info "  Title (from web): $scraped_title"
    elif [[ -n "$ct" && -n "${scraped_title:-}" ]]; then
        titles[$index]="$scraped_title"
        log_info "  Title updated: '$ct' -> '$scraped_title'"
        if [[ "${ct,,}" != *"${scraped_title,,}"* && "${scraped_title,,}" != *"${ct,,}"* ]]; then
            log_warn "  Title mismatch: ID3='$ct' vs Web='$scraped_title'"
        fi
    fi

    # Author: enhance if missing, warn on mismatch
    if [[ -z "$ca" && -n "${scraped_author:-}" ]]; then
        authors[$index]="$scraped_author"
        log_info "  Author (from web): $scraped_author"
    elif [[ -n "$ca" && -n "${scraped_author:-}" ]]; then
        if [[ "${ca,,}" != *"${scraped_author,,}"* && "${scraped_author,,}" != *"${ca,,}"* ]]; then
            log_warn "  Author mismatch: ID3='$ca' vs Web='$scraped_author'"
        fi
    fi

    # Series: prefer web; embed series_number so display/save can extract it
    if [[ -n "${scraped_series:-}" ]]; then
        local merged_series="${scraped_series}"
        [[ -n "${scraped_series_number:-}" ]] && merged_series="${merged_series} ${scraped_series_number}"
        if [[ -z "$cs" || "$cs" != "$merged_series" ]]; then
            series[$index]="$merged_series"
            log_info "  Series (from web): $merged_series"
        fi
    fi

    # Additional fields from web
    [[ -n "${scraped_narrator:-}" ]]     && { narrators[$index]="$scraped_narrator";       log_info "  Narrator: $scraped_narrator"; }
    [[ -n "${scraped_publisher:-}" ]]    && { publishers[$index]="$scraped_publisher";      log_info "  Publisher: $scraped_publisher"; }
    [[ -n "${scraped_release_date:-}" ]] && { release_dates[$index]="$scraped_release_date"; log_info "  Release date: $scraped_release_date"; }
    [[ -n "${scraped_language:-}" ]]     && { languages[$index]="$scraped_language";        log_info "  Series info: $scraped_language"; }
    [[ -n "${scraped_rating:-}" ]]       && { ratings[$index]="$scraped_rating";            log_info "  Rating: $scraped_rating"; }
    [[ -n "${scraped_cover_url:-}" ]]    && { cover_urls[$index]="$scraped_cover_url";      log_info "  Cover URL found"; }
    [[ -n "${scraped_asin:-}" ]]         && { asins[$index]="$scraped_asin";                log_info "  ASIN: $scraped_asin"; }
    [[ -n "${scraped_duration:-}" && -z "${durations[$index]:-}" ]] && { durations[$index]="$scraped_duration"; log_info "  Duration (from web): $scraped_duration"; }

    if [[ -n "${scraped_description:-}" ]]; then
        if [[ -z "${descriptions[$index]:-}" || ${#descriptions[$index]} -lt 50 ]]; then
            descriptions[$index]="$scraped_description"
            log_info "  Description enhanced (${#scraped_description} chars)"
        fi
    fi

    return 0
}

# ---------------------------------------------------------------------------
# JSON persistence
# ---------------------------------------------------------------------------

save_metadata_json()
{
    local webscrape_enabled="${1:-false}"
    local file_count=${#files[@]}
    local save_limit="${2:-$file_count}"
    [[ $save_limit -gt $file_count ]] && save_limit=$file_count

    for ((i=0; i<save_limit; i++)); do
        local clean_series="${series[$i]:-}"
        local series_number=""

        if [[ "$clean_series" =~ ([0-9]+)$ ]]; then
            series_number="${BASH_REMATCH[1]}"
            clean_series="$(echo "$clean_series" | sed 's/[[:space:]]*[0-9]*$//')"
        elif [[ -n "${scraped_series_number:-}" ]]; then
            series_number="$scraped_series_number"
        fi

        [[ -z "$series_number" ]] && series_number="01"
        series_number=$(printf "%02d" "$series_number" 2>/dev/null || echo "01")

        local json_path
        if [[ -n "${CCAB_WORKING_DIR:-}" && -d "${CCAB_WORKING_DIR}" ]]; then
            json_path="$CCAB_WORKING_DIR/extracted_metadata.json"
        else
            json_path="$(dirname "${files[$i]}")/extracted_metadata.json"
        fi

        local json_content
        json_content=$(jq -n \
            --arg file          "${files[$i]}" \
            --arg title         "${titles[$i]:-}" \
            --arg author        "${authors[$i]:-}" \
            --arg series        "$clean_series" \
            --arg series_number "$series_number" \
            --arg album         "${albums[$i]:-}" \
            --arg duration      "${durations[$i]:-}" \
            --arg bitrate       "${bitrates[$i]:-}" \
            --arg description   "${descriptions[$i]:-}" \
            --arg genre         "${genres[$i]:-}" \
            --arg date          "${dates[$i]:-}" \
            --arg asin          "${asins[$i]:-}" \
            --arg narrator      "${narrators[$i]:-}" \
            --arg publisher     "${publishers[$i]:-}" \
            --arg release_date  "${release_dates[$i]:-}" \
            --arg series_info   "${languages[$i]:-}" \
            --arg rating        "${ratings[$i]:-}" \
            --arg cover_url     "${cover_urls[$i]:-}" \
            --arg timestamp     "$(date '+%Y-%m-%d %H:%M:%S')" \
            '{
                file: $file, title: $title, author: $author,
                series: $series, series_number: $series_number,
                album: $album, duration: $duration, bitrate: $bitrate,
                description: $description, genre: $genre, date: $date,
                asin: $asin, narrator: $narrator, publisher: $publisher,
                release_date: $release_date, series_info: $series_info,
                rating: $rating, cover_url: $cover_url,
                extraction_timestamp: $timestamp
            }')

        if echo "$json_content" > "$json_path"; then
            log_info "Saved metadata: $(basename "$json_path")"
        else
            log_error "Failed to save metadata JSON: $json_path"
        fi
    done
}

load_metadata_json()
{
    local json_file="$1"
    local -n _lmj_ref="$2"

    if [[ ! -f "$json_file" ]]; then
        log_error "JSON file not found: $json_file"; return 1
    fi
    if ! jq -e . "$json_file" >/dev/null 2>&1; then
        log_error "Invalid JSON: $json_file"; return 1
    fi

    _lmj_ref["file"]=$(jq -r '.file // ""' "$json_file")
    _lmj_ref["title"]=$(jq -r '.title // ""' "$json_file")
    _lmj_ref["author"]=$(jq -r '.author // ""' "$json_file")
    _lmj_ref["series"]=$(jq -r '.series // ""' "$json_file")
    _lmj_ref["series_number"]=$(jq -r '.series_number // ""' "$json_file")
    _lmj_ref["album"]=$(jq -r '.album // ""' "$json_file")
    _lmj_ref["duration"]=$(jq -r '.duration // ""' "$json_file")
    _lmj_ref["bitrate"]=$(jq -r '.bitrate // ""' "$json_file")
    _lmj_ref["description"]=$(jq -r '.description // ""' "$json_file")
    _lmj_ref["genre"]=$(jq -r '.genre // ""' "$json_file")
    _lmj_ref["date"]=$(jq -r '.date // ""' "$json_file")
    _lmj_ref["asin"]=$(jq -r '.asin // ""' "$json_file")
    _lmj_ref["narrator"]=$(jq -r '.narrator // ""' "$json_file")
    _lmj_ref["publisher"]=$(jq -r '.publisher // ""' "$json_file")
    _lmj_ref["release_date"]=$(jq -r '.release_date // ""' "$json_file")
    _lmj_ref["series_info"]=$(jq -r '.series_info // ""' "$json_file")
    _lmj_ref["rating"]=$(jq -r '.rating // ""' "$json_file")
    _lmj_ref["cover_url"]=$(jq -r '.cover_url // ""' "$json_file")
    return 0
}

# Update an existing .info file with freshly-scraped metadata from book.html
update_info_from_html()
{
    local info_file="$1"
    local html_file="${htmlBookFile:-/tmp/book.html}"

    [[ ! -f "$info_file" ]] && { log_error "Info file not found: $info_file"; return 1; }
    [[ ! -f "$html_file" ]] && { log_error "book.html not found: $html_file"; return 1; }

    local py_script="$_METADATA_LIB_DIR/parse_html.py"
    if [[ ! -f "$py_script" ]]; then
        log_error "HTML parser not found: $py_script"; return 1
    fi

    local scraped_json
    scraped_json=$(python3 "$py_script" "$html_file" 2>/dev/null)
    if [[ $? -ne 0 || -z "$scraped_json" ]]; then
        log_error "HTML parser returned no data"; return 1
    fi

    # Parse the plain-text .info into a JSON object for merging
    local ex_series_raw ex_series ex_series_num
    ex_series_raw=$(grep -m1 '^Series: ' "$info_file" | sed 's/^Series: //') || true
    ex_series_num=$(echo "$ex_series_raw" | sed -n 's/.* #\([0-9]*\)$/\1/p') || true
    ex_series=$(echo "$ex_series_raw" | sed 's/ #[0-9]*$//')

    local ex_description
    ex_description=$(awk '/^DESCRIPTION$/{f=1;next} /^TECHNICAL METADATA$/{exit} /^={3,}$/{next} f && NF{print}' \
        "$info_file" | tr '\n' ' ' | sed 's/[[:space:]]*$//')

    local existing_json
    existing_json=$(jq -n \
        --arg title        "$(grep -m1 '^Title: '        "$info_file" | sed 's/^Title: //')" \
        --arg author       "$(grep -m1 '^Author: '       "$info_file" | sed 's/^Author: //')" \
        --arg series       "$ex_series" \
        --arg series_num   "$ex_series_num" \
        --arg narrator     "$(grep -m1 '^Narrator: '     "$info_file" | sed 's/^Narrator: //')" \
        --arg publisher    "$(grep -m1 '^Publisher: '    "$info_file" | sed 's/^Publisher: //')" \
        --arg duration     "$(grep -m1 '^Duration: '     "$info_file" | sed 's/^Duration: //')" \
        --arg release_date "$(grep -m1 '^Release Date: ' "$info_file" | sed 's/^Release Date: //')" \
        --arg asin         "$(grep -m1 '^ASIN: '         "$info_file" | sed 's/^ASIN: //')" \
        --arg rating       "$(grep -m1 '^Rating: '       "$info_file" | sed 's/^Rating: //')" \
        --arg description  "$ex_description" \
        '{title:$title, author:$author, series:$series, series_number:$series_num,
          narrator:$narrator, publisher:$publisher, duration:$duration,
          release_date:$release_date, asin:$asin, rating:$rating, description:$description}')

    # Merge: scraped fields take priority over existing
    local merged_json
    merged_json=$(jq -n \
        --argjson e "$existing_json" \
        --argjson s "$scraped_json" \
        '{
            title:        ($s.title        // $e.title        // ""),
            author:       ($s.author       // $e.author       // ""),
            series:       ($s.series       // $e.series       // ""),
            series_number:($s.series_number// $e.series_number// ""),
            narrator:     ($s.narrator     // $e.narrator     // ""),
            publisher:    ($s.publisher    // $e.publisher    // ""),
            duration:     ($e.duration     // ""),
            release_date: ($s.release_date // $e.release_date // ""),
            asin:         ($e.asin         // ""),
            rating:       ($s.rating       // $e.rating       // ""),
            cover_url:    ($s.cover_url    // ""),
            description:  ($s.description  // $e.description  // "")
        }')

    # Write updated plain-text .info file
    local m_title m_author m_series m_series_num m_narrator m_publisher
    local m_duration m_release_date m_asin m_rating m_description
    m_title=$(jq -r '.title // ""'        <<< "$merged_json")
    m_author=$(jq -r '.author // ""'      <<< "$merged_json")
    m_series=$(jq -r '.series // ""'      <<< "$merged_json")
    m_series_num=$(jq -r '.series_number // ""' <<< "$merged_json")
    m_narrator=$(jq -r '.narrator // ""'  <<< "$merged_json")
    m_publisher=$(jq -r '.publisher // ""' <<< "$merged_json")
    m_duration=$(jq -r '.duration // ""'  <<< "$merged_json")
    m_release_date=$(jq -r '.release_date // ""' <<< "$merged_json")
    m_asin=$(jq -r '.asin // ""'          <<< "$merged_json")
    m_rating=$(jq -r '.rating // ""'      <<< "$merged_json")
    m_description=$(jq -r '.description // ""' <<< "$merged_json")

    {
        echo "================================================================================"
        echo "AUDIOBOOK INFORMATION"
        echo "================================================================================"
        echo
        echo "Title: ${m_title:-Unknown}"
        echo "Author: ${m_author:-Unknown}"
        [[ -n "$m_series" ]]       && echo "Series: ${m_series}${m_series_num:+ #${m_series_num}}"
        [[ -n "$m_narrator" ]]     && echo "Narrator: ${m_narrator}"
        [[ -n "$m_publisher" ]]    && echo "Publisher: ${m_publisher}"
        [[ -n "$m_duration" ]]     && echo "Duration: ${m_duration}"
        [[ -n "$m_release_date" ]] && echo "Release Date: ${m_release_date}"
        [[ -n "$m_asin" ]]         && echo "ASIN: ${m_asin}"
        [[ -n "$m_rating" ]]       && echo "Rating: ${m_rating}"
        echo
        echo "================================================================================"
        echo "DESCRIPTION"
        echo "================================================================================"
        echo
        if [[ -n "$m_description" && "$m_description" != "null" ]]; then
            echo "$m_description" | fold -s -w 80
        else
            echo "No description available."
        fi
        echo
        echo "================================================================================"
        echo "TECHNICAL METADATA"
        echo "================================================================================"
        echo
        echo "Processing Date: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Generated by: ccab Audiobook Toolkit"
        echo
    } > "$info_file" || { log_error "Failed to write updated info file"; return 1; }

    log_info "Updated info file: $(basename "$info_file")"

    # Re-download cover art if cover_url was scraped
    local new_cover
    new_cover=$(jq -r '.cover_url // ""' <<< "$scraped_json")
    if [[ -n "$new_cover" && "$new_cover" != "null" ]]; then
        local cover_dest
        cover_dest="$(dirname "$info_file")/$(basename "${info_file%.info}").jpg"
        curl -s -L --max-time 30 --max-filesize "10M" \
             --user-agent "ccab/2.0" -o "$cover_dest" "$new_cover" && \
            log_info "Cover art updated: $(basename "$cover_dest")"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# ID3 tag management
# ---------------------------------------------------------------------------

validate_tag_value()
{
    local tag_name="$1"
    local tag_value="$2"
    local -n _vtv_ref="$3"

    if [[ "$tag_value" == "null" || -z "$tag_value" ]]; then
        _vtv_ref=""; return 1
    fi

    case "$tag_name" in
        title|album|artist|author)      validate_input "$tag_value" 200 _vtv_ref ;;
        genre|narrator|publisher)       validate_input "$tag_value" 100 _vtv_ref ;;
        comment|description)            validate_input "$tag_value" 1000 _vtv_ref ;;
        date|year)
            if [[ "$tag_value" =~ ^[0-9]{4}(-[0-9]{2}-[0-9]{2})?$ ]]; then
                _vtv_ref="$tag_value"
            else _vtv_ref=""; return 1; fi ;;
        track|series_number)
            if [[ "$tag_value" =~ ^[0-9]+$ ]]; then _vtv_ref="$tag_value"
            else _vtv_ref=""; return 1; fi ;;
        *)  validate_input "$tag_value" 200 _vtv_ref ;;
    esac
}

clear_id3_tags()
{
    local mp3_file="$1"
    [[ ! -f "$mp3_file" ]] && { log_error "File not found: $mp3_file"; return 1; }
    mid3v2 --delete-all "$mp3_file" 2>/dev/null || log_warn "Failed to clear ID3 tags"
}

set_audiobook_genre()
{
    local content_type="${1:-audiobook}"
    case "${content_type,,}" in
        *romance*)          echo "Romance" ;;
        *fantasy*)          echo "Fantasy" ;;
        *science*fiction*|*scifi*) echo "Science Fiction" ;;
        *mystery*|*thriller*) echo "Mystery & Thriller" ;;
        *biography*|*memoir*) echo "Biography & Memoir" ;;
        *self*help*)        echo "Self-Help" ;;
        *business*)         echo "Business" ;;
        *history*)          echo "History" ;;
        *children*)         echo "Children's" ;;
        *)                  echo "Audiobook" ;;
    esac
}

apply_audiobook_tags()
{
    local mp3_file="$1"
    shift
    local txxx_args=()

    while [[ $# -gt 0 ]]; do
        if [[ "$1" =~ ^([^=]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
            if [[ -n "$key" && -n "$value" && "$value" != "null" ]]; then
                local vv
                if validate_tag_value "$key" "$value" vv && [[ -n "$vv" ]]; then
                    case "$key" in
                        narrator)    txxx_args+=("--TXXX" "NARRATOR:$vv") ;;
                        publisher)   txxx_args+=("--TXXX" "PUBLISHER:$vv") ;;
                        asin)        txxx_args+=("--TXXX" "ASIN:$vv") ;;
                        series)      txxx_args+=("--TXXX" "SERIES:$vv") ;;
                        series_info) txxx_args+=("--TXXX" "SERIES_INFO:$vv") ;;
                        rating)      txxx_args+=("--TXXX" "RATING:$vv") ;;
                        description) txxx_args+=("--TXXX" "DESCRIPTION:$vv") ;;
                        language)    txxx_args+=("--TXXX" "LANGUAGE:$vv") ;;
                        duration)    txxx_args+=("--TXXX" "DURATION:$vv") ;;
                    esac
                fi
            fi
        fi
        shift
    done

    if [[ ${#txxx_args[@]} -gt 0 ]]; then
        mid3v2 "${txxx_args[@]}" "$mp3_file" 2>/dev/null || log_warn "Some TXXX tags not applied"
    fi
}

apply_cover_art()
{
    local mp3_file="$1"
    local cover_file="$2"
    local generate_thumbnail="${3:-false}"

    [[ ! -f "$mp3_file" ]]   && { log_error "MP3 not found: $mp3_file"; return 1; }
    [[ ! -f "$cover_file" ]] && { log_debug "No cover file: $cover_file"; return 1; }
    file "$cover_file" | grep -q "image" || { log_warn "Not a valid image: $cover_file"; return 1; }

    log_info "Embedding cover art: $(basename "$cover_file")"

    local temp_out="${mp3_file}.cover_temp.mp3"

    if ffmpeg -i "$mp3_file" -i "$cover_file" -map 0:a -map 1 -c:a copy -c:v mjpeg \
              -disposition:v:0 attached_pic "$temp_out" -y 2>/dev/null; then
        log_debug "Cover embedded via ffmpeg"
    else
        cp "$mp3_file" "$temp_out"
        if ! mid3v2 --picture "$cover_file" "$temp_out" 2>/dev/null; then
            log_warn "Cover art embedding failed"
            rm -f "$temp_out"; return 1
        fi
        log_debug "Cover embedded via mid3v2"
    fi

    if mv "$temp_out" "$mp3_file"; then
        log_info "Cover art embedded"
        if [[ "$generate_thumbnail" == "true" ]]; then
            local thumb_dir="${CCAB_WORKING_DIR:-/tmp}"
            local thumb_file="$thumb_dir/.thumbnail_$(basename "${mp3_file%.*}").png"
            generate_notification_thumbnail "$cover_file" "$thumb_file"
        fi
        return 0
    fi
    rm -f "$temp_out"
    return 1
}

apply_id3_tags()
{
    local mp3_file="$1"
    shift
    local -A metadata=()

    while [[ $# -gt 0 ]]; do
        [[ "$1" =~ ^([^=]+)=(.*)$ ]] && metadata["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
        shift
    done

    [[ ! -f "$mp3_file" ]] && { log_error "MP3 not found: $mp3_file"; return 1; }

    clear_id3_tags "$mp3_file"

    local mid3v2_args=() vv

    validate_tag_value "title"  "${metadata[title]:-}"                         vv && [[ -n "$vv" ]] && mid3v2_args+=("--song"   "$vv")
    validate_tag_value "artist" "${metadata[author]:-${metadata[artist]:-}}"   vv && [[ -n "$vv" ]] && mid3v2_args+=("--artist" "$vv")
    validate_tag_value "album"  "${metadata[album]:-${metadata[title]:-}}"     vv && [[ -n "$vv" ]] && mid3v2_args+=("--album"  "$vv")

    local genre="${metadata[genre]:-}"
    [[ -z "$genre" ]] && genre=$(set_audiobook_genre "${metadata[series]:-}")
    validate_tag_value "genre"  "$genre" vv && [[ -n "$vv" ]] && mid3v2_args+=("--genre" "$vv")

    local tag_date="${metadata[release_date]:-${metadata[date]:-}}"
    validate_tag_value "date"   "$tag_date"              vv && [[ -n "$vv" ]] && mid3v2_args+=("--date"  "$vv")
    validate_tag_value "track"  "${metadata[series_number]:-}" vv && [[ -n "$vv" ]] && mid3v2_args+=("--track" "$vv")

    local comment="${metadata[comment]:-Encoded by ccab}"
    validate_tag_value "comment" "$comment" vv && [[ -n "$vv" ]] && mid3v2_args+=("--comment" "$vv")

    validate_tag_value "description" "${metadata[description]:-}" vv && [[ -n "$vv" ]] && mid3v2_args+=("--TXXX" "DESCRIPTION:$vv")

    if [[ ${#mid3v2_args[@]} -gt 0 ]]; then
        mid3v2 "${mid3v2_args[@]}" "$mp3_file" 2>/dev/null || log_warn "Some core ID3 tags not applied"
    fi

    # Audiobook-specific TXXX tags
    local ab_args=()
    for key in "${!metadata[@]}"; do
        local val="${metadata[$key]}"
        [[ -n "$val" && "$val" != "null" && ! "$key" =~ ^(title|author|artist|album|genre|date|comment)$ ]] && \
            ab_args+=("$key=$val")
    done
    [[ ${#ab_args[@]} -gt 0 ]] && apply_audiobook_tags "$mp3_file" "${ab_args[@]}"

    # Cover art
    [[ -n "${metadata[cover_file]:-}" ]] && apply_cover_art "$mp3_file" "${metadata[cover_file]}"
    return 0
}

# ---------------------------------------------------------------------------
# Notification / thumbnail
# ---------------------------------------------------------------------------

generate_notification_thumbnail()
{
    local cover_file="$1"
    local output_thumbnail="$2"

    [[ "${enableThumbnails:-true}" != "true" ]]      && return 1
    ! command -v convert >/dev/null 2>&1              && return 1
    [[ ! -f "$cover_file" ]]                         && return 1
    mkdir -p "$(dirname "$output_thumbnail")" 2>/dev/null || return 1

    convert "$cover_file" -thumbnail 96x96 "$output_thumbnail" 2>/dev/null
}

send_conversion_notification()
{
    local title="$1"
    local author="$2"
    local thumbnail_cover="${3:-}"

    ! command -v notify-send >/dev/null 2>&1 && return 1

    local body="$title"
    [[ -n "$author" ]] && body="$title by $author"

    local notify_args=("-i" "$_METADATA_LIB_DIR/music_note.png"
                       "--app-name=ccab" "--expire-time=6000")
    if [[ -n "$thumbnail_cover" && -f "$thumbnail_cover" ]]; then
        notify_args+=("--hint" "string:image-path:$thumbnail_cover")
    fi
    notify_args+=("Audiobook Conversion Complete" "$body")

    notify-send "${notify_args[@]}" 2>/dev/null || log_warn "Desktop notification failed"
}

# ---------------------------------------------------------------------------
# Display
# ---------------------------------------------------------------------------

display_metadata_results()
{
    local webscrape_enabled="${1:-false}"
    local file_count=${#files[@]}

    for ((i=0; i<file_count; i++)); do
        log_info ">>> Metadata for $(basename "${files[$i]}")"
        log_info "  ${C8}Title:${C0}       ${titles[$i]:-"Not found"}"
        log_info "  ${C8}Author:${C0}      ${authors[$i]:-"Not found"}"
        log_info "  ${C8}Series:${C0}      ${series[$i]:-"Not found"}"
        log_info "  ${C8}Full Title:${C0}  ${albums[$i]:-"Not found"}"

        local fd fb
        fd=$(format_duration "${durations[$i]:-0}" 2>/dev/null || echo "${durations[$i]:-Not found}")
        fb=$(format_bitrate  "${bitrates[$i]:-0}"  2>/dev/null || echo "${bitrates[$i]:-Not found}")
        log_info "  ${C8}Duration:${C0}    $fd"
        log_info "  ${C8}Bitrate:${C0}     $fb"
        log_info "  ${C8}Genre:${C0}       ${genres[$i]:-"Not found"}"

        if [[ "$webscrape_enabled" == "true" && -n "${release_dates[$i]:-}" ]]; then
            log_info "  ${C8}Date:${C0}        ${release_dates[$i]}"
        else
            log_info "  ${C8}Date:${C0}        ${dates[$i]:-"Not found"}"
        fi

        log_info "  ${C8}ASIN:${C0}        ${asins[$i]:-"Not found"}"

        if [[ "$webscrape_enabled" == "true" ]]; then
            log_info "  ${C8}Narrator:${C0}    ${narrators[$i]:-"Not found"}"
            log_info "  ${C8}Publisher:${C0}   ${publishers[$i]:-"Not found"}"
            [[ -n "${languages[$i]:-}" ]]  && log_info "  ${C8}Series Info:${C0} ${languages[$i]}"
            [[ -n "${ratings[$i]:-}" ]]    && log_info "  ${C8}Rating:${C0}      ${ratings[$i]}"
            [[ -n "${cover_urls[$i]:-}" ]] && log_info "  ${C8}Cover URL:${C0}   ${cover_urls[$i]:0:50}..."
        fi

        if [[ -n "${descriptions[$i]}" ]]; then
            local desc="${descriptions[$i]:0:70}"
            [[ ${#descriptions[$i]} -gt 70 ]] && desc="${desc}..."
            log_info "  ${C8}Description:${C0} $desc"
        fi
    done

    local cnt=0
    for ((i=0; i<file_count; i++)); do
        [[ -n "${titles[$i]}" || -n "${authors[$i]}" ]] && ((cnt++))
    done
    log_info "  Files with metadata: $cnt / $file_count"
}

display_search_results()
{
    local search_results="$1"
    local count=1

    echo
    while IFS= read -r line; do
        if [[ -n "$line" ]] && echo "$line" | jq -e . >/dev/null 2>&1; then
            local title link
            title=$(echo "$line" | jq -r '.title // "No title"' 2>/dev/null)
            link=$(echo "$line"  | jq -r '.link // ""' 2>/dev/null)
            if [[ -n "$link" && "$title" != "null" && "$link" != "null" ]]; then
                echo -e "${C4}$count. ${C7}${title/&amp;/&}${C0}"
                echo -e "   ${C8}$link${C0}"
                echo
                ((count++))
            fi
        fi
    done <<< "$search_results"

    if [[ $count -eq 1 ]]; then
        echo -e "${C5}No results found${C0}"
        return 1
    fi

    echo -e "${C8}Save the desired page as: ${C3}/tmp/book.html${C0}\n"
}

# ---------------------------------------------------------------------------
# Interactive metadata confirmation (-v flag)
# ---------------------------------------------------------------------------

format_metadata_for_display()
{
    local index="$1"
    local webscrape_enabled="${2:-false}"

    echo
    echo -e "${C4}=== AUDIOBOOK METADATA ===${C0}"
    echo -e "${C8}File: ${files[$index]:-Unknown}${C0}"
    echo

    local clean_series="${series[$index]:-}"
    local series_num=""
    if [[ "${series[$index]:-}" =~ ^(.+)[[:space:]]+([0-9]+)$ ]]; then
        clean_series="${BASH_REMATCH[1]}"
        series_num=$(printf "%02d" "${BASH_REMATCH[2]}")
    fi

    echo -e "${C3}1.${C0} ${C8}Title:${C0}          ${titles[$index]:-Not found}"
    echo -e "${C3}2.${C0} ${C8}Author:${C0}         ${authors[$index]:-Not found}"
    echo -e "${C3}3.${C0} ${C8}Series Name:${C0}    ${clean_series:-Not found}"
    echo -e "${C3}4.${C0} ${C8}Series Number:${C0}  ${series_num:-Not found}"
    echo -e "${C3}5.${C0} ${C8}Full Title:${C0}     ${albums[$index]:-Not found}"
    echo -e "${C3}6.${C0} ${C8}Genre:${C0}          ${genres[$index]:-Not found}"

    if [[ "$webscrape_enabled" == "true" ]]; then
        echo -e "${C3}7.${C0} ${C8}Narrator:${C0}       ${narrators[$index]:-Not found}"
        echo -e "${C3}8.${C0} ${C8}Publisher:${C0}      ${publishers[$index]:-Not found}"
        echo -e "${C3}9.${C0} ${C8}Date:${C0}           ${release_dates[$index]:-${dates[$index]:-Not found}}"
    else
        echo -e "${C3}7.${C0} ${C8}Date:${C0}           ${dates[$index]:-Not found}"
    fi

    if [[ -n "${descriptions[$index]:-}" ]]; then
        local dp="${descriptions[$index]:0:100}"
        [[ ${#descriptions[$index]} -gt 100 ]] && dp="${dp}..."
        echo -e "${C8}Description:${C0} $dp"
    fi
    echo
}

prompt_user_edit()
{
    local field_name="$1"
    local current_value="$2"
    echo -e "${C8}Current ${field_name}: ${C0}${current_value:-"(empty)"}" >&2
    echo -e "${C8}Enter new value (Enter to keep):${C0} " >&2
    local new_value
    read -r new_value
    if [[ -n "$new_value" ]]; then
        echo "$new_value" | sed 's/\x1b\[[0-9;]*m//g'
    else
        echo "$current_value" | sed 's/\x1b\[[0-9;]*m//g'
    fi
}

edit_metadata_field()
{
    local index="$1"
    local field_number="$2"
    local webscrape_enabled="${3:-false}"

    case "$field_number" in
        1) titles[$index]=$(prompt_user_edit "title" "${titles[$index]:-}") ;;
        2) authors[$index]=$(prompt_user_edit "author" "${authors[$index]:-}") ;;
        3)
            local sname="${series[$index]:-}"
            [[ "$sname" =~ ^(.+)[[:space:]]+[0-9]+$ ]] && sname="${BASH_REMATCH[1]}"
            local new_sname
            new_sname=$(prompt_user_edit "series name" "$sname")
            local snum=""
            [[ "${series[$index]:-}" =~ [0-9]+$ ]] && snum="${BASH_REMATCH[0]}"
            series[$index]="${new_sname}${snum:+ $snum}"
            ;;
        4)
            local csn=""
            [[ "${series[$index]:-}" =~ [0-9]+$ ]] && csn="${BASH_REMATCH[0]}"
            local new_snum
            new_snum=$(prompt_user_edit "series number (e.g. 01)" "$csn")
            local sname2="${series[$index]:-}"
            [[ "$sname2" =~ ^(.+)[[:space:]]+[0-9]+$ ]] && sname2="${BASH_REMATCH[1]}"
            series[$index]="${sname2}${new_snum:+ $new_snum}"
            ;;
        5) albums[$index]=$(prompt_user_edit "full title" "${albums[$index]:-}") ;;
        6) genres[$index]=$(prompt_user_edit "genre" "${genres[$index]:-}") ;;
        7)
            if [[ "$webscrape_enabled" == "true" ]]; then
                narrators[$index]=$(prompt_user_edit "narrator" "${narrators[$index]:-}")
            else
                dates[$index]=$(prompt_user_edit "date" "${dates[$index]:-}")
            fi ;;
        8) [[ "$webscrape_enabled" == "true" ]] && publishers[$index]=$(prompt_user_edit "publisher" "${publishers[$index]:-}") ;;
        9)
            if [[ "$webscrape_enabled" == "true" ]]; then
                release_dates[$index]=$(prompt_user_edit "release date" "${release_dates[$index]:-${dates[$index]:-}}")
            fi ;;
        *) echo -e "${C1}Invalid field: $field_number${C0}"; return 1 ;;
    esac
}

confirm_single_metadata()
{
    local index="$1"
    local webscrape_enabled="${2:-false}"
    local choice confirmed=false

    while [[ "$confirmed" != "true" ]]; do
        format_metadata_for_display "$index" "$webscrape_enabled"
        echo -e "${C4}=== MENU ===${C0}"
        echo -e "${C3}c${C0} Confirm  ${C3}1-9${C0} Edit field  ${C3}s${C0} Skip  ${C3}q${C0} Quit"
        echo -e "${C8}Choice: ${C0}"
        read -r choice

        case "$choice" in
            c|C)
                if [[ -z "${titles[$index]}" && -z "${authors[$index]}" ]]; then
                    echo -e "${C1}Title and author are both empty - cannot confirm${C0}"
                else
                    confirmed=true
                    log_info "Confirmed metadata for audiobook $((index+1))"
                fi ;;
            s|S) log_info "Skipping audiobook $((index+1))"; return 2 ;;
            q|Q) return 1 ;;
            [1-9])
                if edit_metadata_field "$index" "$choice" "$webscrape_enabled"; then
                    echo -e "${C2}Updated${C0}"
                fi ;;
            *) echo -e "${C1}Invalid choice${C0}" ;;
        esac
    done
    return 0
}

confirm_metadata()
{
    local webscrape_enabled="${1:-false}"
    local file_count=${#files[@]}

    if [[ $file_count -eq 0 ]]; then
        log_warn "No audiobooks to confirm"
        return 1
    fi

    echo -e "\n${C4}================================================================${C0}"
    echo -e "${C4}                 METADATA CONFIRMATION (-v)                    ${C0}"
    echo -e "${C4}================================================================${C0}\n"

    local processed=0 skipped=0
    for ((i=0; i<file_count; i++)); do
        confirm_single_metadata "$i" "$webscrape_enabled"
        case $? in
            0) ((processed++)) ;;
            1) log_info "User quit"; return 1 ;;
            2) ((skipped++)) ;;
        esac
    done

    echo -e "\n${C2}Confirmed: $processed${C0}  ${C3}Skipped: $skipped${C0}\n"
    [[ $processed -eq 0 ]] && return 1
    return 0
}

# ---------------------------------------------------------------------------
# Exports
# ---------------------------------------------------------------------------

export -f format_duration format_bitrate format_author_name
export -f extract_id3_metadata parse_filename_metadata clean_author_field
export -f parse_book_html merge_audiobook_metadata
export -f save_metadata_json load_metadata_json update_info_from_html
export -f validate_tag_value clear_id3_tags set_audiobook_genre
export -f apply_audiobook_tags apply_cover_art apply_id3_tags
export -f generate_notification_thumbnail send_conversion_notification
export -f display_metadata_results display_search_results
export -f format_metadata_for_display prompt_user_edit edit_metadata_field
export -f confirm_single_metadata confirm_metadata
