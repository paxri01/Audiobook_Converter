#!/bin/bash
# shellcheck disable=SC2155,SC2034

## ========================================================================================
##       Title: files.sh
##      Author: R. L. Paxton
##     Version: 2.0
##        Date: 2026-04-08
##     License: Apache 2.0
## Description: File discovery and organization for ccab
##              Derived from manage_files.sh (cache system removed)
## ========================================================================================

# Prevent multiple sourcing
if [[ "${FILES_SOURCED:-}" == "true" ]]; then
    return 0
fi
export FILES_SOURCED="true"

# ---------------------------------------------------------------------------
# File discovery
# ---------------------------------------------------------------------------

discover_audio_files()
{
    local dir="${1:-$PWD}"
    local -n _daf_ref="$2"

    log_info "Discovering audio files in: $dir"
    _daf_ref=()
    local file_count=0

    # Bash globbing (faster than find)
    local orig_pwd="$PWD"
    if ! cd "$dir" 2>/dev/null; then
        log_error "Cannot access directory: $dir"; return 1
    fi

    shopt -s nocaseglob nullglob
    local audio_files=(*.mp3 *.m4a *.m4b *.flac *.mp4 *.aac *.wav)
    shopt -u nocaseglob nullglob
    cd "$orig_pwd" || return 1

    for f in "${audio_files[@]}"; do
        local fp="$dir/$f"
        if [[ -f "$fp" && -r "$fp" ]]; then
            _daf_ref[file_count]="$fp"
            ((file_count++))
        fi
    done

    # Fallback to find if globbing found nothing
    if [[ $file_count -eq 0 ]]; then
        log_debug "Falling back to find"
        while IFS= read -r -d '' f; do
            [[ -f "$f" && -r "$f" ]] && { _daf_ref[file_count]="$f"; ((file_count++)); }
        done < <(find "$dir" -maxdepth 1 -type f \
            \( -iname "*.mp3" -o -iname "*.m4a" -o -iname "*.m4b" \
               -o -iname "*.flac" -o -iname "*.mp4" -o -iname "*.aac" -o -iname "*.wav" \) \
            -print0 2>/dev/null)
    fi

    if [[ $file_count -eq 0 ]]; then
        log_error "No audio files found in: $dir"; return 1
    fi
    log_info "Found $file_count audio file(s)"
    return 0
}

discover_json_files()
{
    local dir="${1:-$PWD}"
    local -n _djf_ref="$2"

    log_info "Looking for JSON metadata in: $dir"
    _djf_ref=()
    local count=0

    while IFS= read -r -d '' f; do
        if [[ -f "$f" && -r "$f" ]] && jq -e '.file and .title and .author' "$f" >/dev/null 2>&1; then
            _djf_ref[count]="$f"
            ((count++))
        fi
    done < <(find "$dir" -maxdepth 1 -type f -name "*.json" -print0 2>/dev/null)

    if [[ $count -eq 0 ]]; then
        log_error "No valid JSON metadata found in: $dir"; return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Search query building
# ---------------------------------------------------------------------------

build_search_query()
{
    local title="$1" author="$2" series="$3"
    local q=""

    if   [[ -n "$title"  && -n "$author" ]]; then q="$title $author"
    elif [[ -n "$title"  && -n "$series" ]]; then q="$title $series"
    elif [[ -n "$title" ]];                  then q="$title"
    elif [[ -n "$author" ]];                 then q="$author"
    fi

    q="${q//[Uu]nabridged/}"
    q="${q//[Aa]udiobook/}"
    q=$(echo "$q" | sed 's/[[:space:]]\+/ /g;s/^[[:space:]]*//;s/[[:space:]]*$//')
    echo "$q"
}

# ---------------------------------------------------------------------------
# Move mode helpers
# ---------------------------------------------------------------------------

validate_move_mode()
{
    case "$1" in 1|2|3|4|5|6) return 0 ;; esac
    log_error "Invalid move mode: $1 (valid: 1-6)"
    return 1
}

get_move_genre()
{
    local mode="$1"
    local -n _gmg_ref="$2"
    case "$mode" in
        1) _gmg_ref="${MOVE_1:-Fantasy}" ;;
        2) _gmg_ref="${MOVE_2:-SciFi}" ;;
        3) _gmg_ref="${MOVE_3:-Thriller}" ;;
        4) _gmg_ref="${MOVE_4:-Romance}" ;;
        5) _gmg_ref="${MOVE_5:-Erotica}" ;;
        6) _gmg_ref="${MOVE_6:-Misc}" ;;
        *) _gmg_ref="Unknown"; return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# File organization
# ---------------------------------------------------------------------------

compute_organized_path()
{
    local move_mode="$1"
    shift
    local -A metadata=()
    while [[ $# -gt 0 ]]; do
        [[ "$1" =~ ^([^=]+)=(.*)$ ]] && metadata["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
        shift
    done

    local base_dir="${AUDIOBOOK_BASE_DIR:-$HOME/Audiobooks}"
    local title="${metadata[title]:-Unknown}"
    local author="${metadata[author]:-Unknown}"
    local series="${metadata[series]:-}"
    local series_number="${metadata[series_number]:-}"

    local move_genre
    get_move_genre "$move_mode" move_genre || return 1

    local formatted_author
    format_author_name "$author" formatted_author

    local safe_title safe_author safe_series safe_genre
    sanitize_for_filename "$title"           safe_title
    sanitize_for_filename "$formatted_author" safe_author
    sanitize_for_filename "$series"          safe_series
    sanitize_for_filename "$move_genre"      safe_genre

    # Remove common noise words from title and series
    safe_title="${safe_title/ A LitRPG Adventure/}"
    safe_title="${safe_title/ Unabridged/}"
    safe_series="${safe_series/ Unabridged/}"

    local series_dir
    if [[ -n "$series" ]]; then
        if   [[ "$series" =~ [0-9]+$ ]]; then
            series_dir="$safe_series - $safe_title"
        elif [[ -n "$series_number" ]]; then
            series_dir="$safe_series $series_number - $safe_title"
        else
            series_dir="$safe_series - $safe_title"
        fi
    else
        series_dir="$safe_title"
    fi

    echo "$base_dir/$safe_genre/$safe_author/$series_dir"
}

create_organized_directory()
{
    local move_mode="$1"
    shift

    local organized_path
    organized_path=$(compute_organized_path "$move_mode" "$@") || return 1

    log_info "Creating directory: $organized_path"
    if mkdir -p "$organized_path"; then
        echo "$organized_path"
        return 0
    fi
    log_error "Failed to create directory: $organized_path"
    return 1
}

create_info_file()
{
    local info_file_path="$1"
    shift
    local -A metadata=()
    while [[ $# -gt 0 ]]; do
        [[ "$1" =~ ^([^=]+)=(.*)$ ]] && metadata["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
        shift
    done

    {
        echo "================================================================================"
        echo "AUDIOBOOK INFORMATION"
        echo "================================================================================"
        echo
        echo "Title: ${metadata[title]:-Unknown}"
        echo "Author: ${metadata[author]:-Unknown}"
        [[ -n "${metadata[series]:-}" ]] && echo "Series: ${metadata[series]}${metadata[series_number]:+ #${metadata[series_number]}}"
        [[ -n "${metadata[narrator]:-}" ]]    && echo "Narrator: ${metadata[narrator]}"
        [[ -n "${metadata[publisher]:-}" ]]   && echo "Publisher: ${metadata[publisher]}"
        [[ -n "${metadata[duration]:-}" ]]    && echo "Duration: ${metadata[duration]}"
        [[ -n "${metadata[release_date]:-}" ]] && echo "Release Date: ${metadata[release_date]}"
        [[ -n "${metadata[asin]:-}" ]]        && echo "ASIN: ${metadata[asin]}"
        [[ -n "${metadata[rating]:-}" ]]      && echo "Rating: ${metadata[rating]}"
        echo
        echo "================================================================================"
        echo "DESCRIPTION"
        echo "================================================================================"
        echo
        if [[ -n "${metadata[description]:-}" && "${metadata[description]}" != "null" ]]; then
            echo "${metadata[description]}" | fold -s -w 80
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
    } > "$info_file_path"

    if [[ -f "$info_file_path" && -s "$info_file_path" ]]; then
        log_debug "Created info file: $(basename "$info_file_path")"
        return 0
    fi
    log_error "Failed to create info file: $info_file_path"
    return 1
}

copy_audiobook_files()
{
    local source_dir="$1" dest_dir="$2" base_filename="$3"
    shift 3
    local -A metadata=()
    while [[ $# -gt 0 ]]; do
        [[ "$1" =~ ^([^=]+)=(.*)$ ]] && metadata["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
        shift
    done

    local mp3_file="$source_dir/${base_filename}.mp3"
    local info_file="$dest_dir/${base_filename}.info"

    # Locate cover art: exact match first, then working dir scan
    local jpg_file=""
    local candidates=(
        "$source_dir/${base_filename}.jpg"
        "${CCAB_WORKING_DIR:-}/${base_filename}.jpg"
        "$source_dir/cover.jpg"
        "${CCAB_WORKING_DIR:-}/cover.jpg"
    )
    for c in "${candidates[@]}"; do
        [[ -n "$c" && -f "$c" ]] && { jpg_file="$c"; break; }
    done

    # Fallback: any non-thumbnail JPG in working dir
    if [[ -z "$jpg_file" && -n "${CCAB_WORKING_DIR:-}" && -d "${CCAB_WORKING_DIR}" ]]; then
        for j in "${CCAB_WORKING_DIR}"/*.jpg; do
            if [[ -f "$j" && "$(basename "$j")" != thumbnail_* ]]; then
                jpg_file="$j"; log_debug "Using fallback cover art: $(basename "$j")"; break
            fi
        done
    fi

    local copied=() failed=()

    # Copy MP3
    if [[ -f "$mp3_file" ]]; then
        if cp "$mp3_file" "$dest_dir/$(basename "$mp3_file")"; then
            copied+=("$(basename "$mp3_file")")
        else
            failed+=("$(basename "$mp3_file")")
            log_error "Failed to copy: $(basename "$mp3_file")"
        fi
    else
        failed+=("$(basename "$mp3_file")")
        log_warn "MP3 not found: $mp3_file"
    fi

    # Copy cover art
    if [[ -n "$jpg_file" && -f "$jpg_file" ]]; then
        if cp "$jpg_file" "$dest_dir/${base_filename}.jpg"; then
            copied+=("${base_filename}.jpg")
        else
            failed+=("${base_filename}.jpg")
        fi
    else
        log_debug "No cover art found"
    fi

    # Copy thumbnail
    if [[ "${enableThumbnails:-true}" == "true" && -d "${CCAB_WORKING_DIR:-}" ]]; then
        for thumb in "${CCAB_WORKING_DIR}"/thumbnail_cover_*.jpg; do
            if [[ -f "$thumb" ]]; then
                cp "$thumb" "$dest_dir/${base_filename}_thumbnail.jpg" && \
                    copied+=("${base_filename}_thumbnail.jpg")
                break
            fi
        done
    fi

    # Create info file
    local info_args=()
    for k in "${!metadata[@]}"; do info_args+=("$k=${metadata[$k]}"); done
    if create_info_file "$info_file" "${info_args[@]}"; then
        copied+=("$(basename "$info_file")")
    else
        failed+=("$(basename "$info_file")")
    fi

    log_info "Copied ${#copied[@]} files to: $dest_dir"

    # Check for critical failures (MP3 or .info)
    local crit=0
    for f in "${failed[@]}"; do
        [[ "$f" == *.mp3 || "$f" == *.info ]] && ((crit++))
    done
    [[ $crit -gt 0 ]] && { log_error "$crit critical files failed"; return 1; }
    return 0
}

organize_audiobook_files()
{
    local move_mode="$1" source_dir="$2" base_filename="$3"
    shift 3
    local -A metadata=()
    while [[ $# -gt 0 ]]; do
        [[ "$1" =~ ^([^=]+)=(.*)$ ]] && metadata["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
        shift
    done

    validate_move_mode "$move_mode" || return 1

    local org_args=()
    for k in "${!metadata[@]}"; do org_args+=("$k=${metadata[$k]}"); done

    local dest_dir
    if ! dest_dir=$(create_organized_directory "$move_mode" "${org_args[@]}"); then
        log_error "Failed to create organized directory"; return 1
    fi

    if copy_audiobook_files "$source_dir" "$dest_dir" "$base_filename" "${org_args[@]}"; then
        log_info "Organized to: $dest_dir"
        return 0
    fi
    log_error "File organization failed"
    return 1
}

export -f discover_audio_files discover_json_files build_search_query
export -f validate_move_mode get_move_genre
export -f compute_organized_path create_organized_directory create_info_file copy_audiobook_files organize_audiobook_files
