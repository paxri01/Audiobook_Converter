#!/bin/bash
# shellcheck disable=SC2155,SC2034

## ========================================================================================
##       Title: audio.sh
##      Author: R. L. Paxton
##     Version: 2.0
##        Date: 2026-04-08
##     License: Apache 2.0
## Description: Audio conversion and working directory management for ccab
## ========================================================================================

# Prevent multiple sourcing
if [[ "${AUDIO_SOURCED:-}" == "true" ]]; then
    return 0
fi
export AUDIO_SOURCED="true"

# Working directory globals
declare -g CCAB_WORKING_DIR="${CCAB_WORKING_DIR:-}"
declare -g CCAB_WORKING_BASE="${CCAB_WORKING_BASE:-/tmp/ccab}"

# ---------------------------------------------------------------------------
# Working directory management
# ---------------------------------------------------------------------------

create_working_directory()
{
    local session_id="${1:-$$}"
    local base_name="${2:-ccab_session}"

    mkdir -p "$CCAB_WORKING_BASE" || { log_error "Failed to create base dir: $CCAB_WORKING_BASE"; return 1; }

    local available_mb
    available_mb=$(df -BM "$CCAB_WORKING_BASE" 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/M//')
    if [[ -n "$available_mb" && "$available_mb" =~ ^[0-9]+$ && $available_mb -lt 50 ]]; then
        log_error "Insufficient disk space: ${available_mb}MB available, 50MB required"
        return 1
    fi

    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    CCAB_WORKING_DIR="$CCAB_WORKING_BASE/${base_name}_${timestamp}_${session_id}"

    if mkdir -p "$CCAB_WORKING_DIR"; then
        log_info "Created working directory: $CCAB_WORKING_DIR"
        mkdir -p "$CCAB_WORKING_DIR/temp" "$CCAB_WORKING_DIR/backup"
        export CCAB_WORKING_DIR
        return 0
    else
        log_error "Failed to create working directory: $CCAB_WORKING_DIR"
        return 1
    fi
}

cleanup_working_directory()
{
    [[ -z "$CCAB_WORKING_DIR" || ! -d "$CCAB_WORKING_DIR" ]] && return 0

    if ${CLEANUP_WORKING_DIR_AFTER_SUCCESS:-false}; then
        if rm -rf "$CCAB_WORKING_DIR"; then
            log_debug "Removed working directory: $CCAB_WORKING_DIR"
            CCAB_WORKING_DIR=""
        fi
    else
        log_info "Preserving working directory: $CCAB_WORKING_DIR"
    fi
}

setup_cleanup_trap()
{
    trap 'cleanup_working_directory' EXIT
    log_debug "Cleanup trap registered"
}

move_book_html()
{
    local book_html_file="${1:-/tmp/book.html}"
    local -n _mbh_ref="${2:-_mbh_dummy}"

    [[ -z "$CCAB_WORKING_DIR" ]] && { log_error "Working directory not initialized"; return 1; }
    [[ ! -f "$book_html_file" ]] && { log_debug "book.html not found: $book_html_file"; return 1; }

    local moved_path="$CCAB_WORKING_DIR/manual_dl_book.html"
    if mv "$book_html_file" "$moved_path"; then
        _mbh_ref="$moved_path"
        log_info "Moved book HTML to working directory"
        return 0
    fi
    log_error "Failed to move book HTML: $book_html_file"
    return 1
}

# ---------------------------------------------------------------------------
# Audio validation helpers
# ---------------------------------------------------------------------------

validate_audio_file()
{
    local input_file="$1"
    local -n _vaf_ref="$2"

    _vaf_ref=""
    if [[ ! -f "$input_file" ]]; then _vaf_ref="File not found"; return 1; fi
    if [[ ! -r "$input_file" ]]; then _vaf_ref="File not readable"; return 1; fi

    local probe_output
    probe_output=$(ffprobe -v quiet -print_format json -show_format "$input_file" 2>/dev/null)
    if [[ $? -ne 0 || -z "$probe_output" ]]; then
        _vaf_ref="Not a valid audio file"
        return 1
    fi

    local fmt
    fmt=$(echo "$probe_output" | jq -r '.format.format_name // ""' 2>/dev/null)
    _vaf_ref="Valid: $fmt"
    return 0
}

validate_image_file()
{
    local image_file="$1"
    [[ ! -f "$image_file" ]] && return 1
    local ftype
    ftype=$(file "$image_file" 2>/dev/null)
    [[ "$ftype" =~ (JPEG|PNG|GIF|WebP|image) ]] || return 1
    local fsize
    fsize=$(stat -c%s "$image_file" 2>/dev/null || echo 0)
    [[ "$fsize" -gt 1024 ]]
}

check_audio_format()
{
    local input_file="$1"
    local -n _caf_fmt="$2"
    local -n _caf_br="$3"
    local -n _caf_sr="$4"

    local probe_output
    probe_output=$(ffprobe -v quiet -select_streams a:0 \
        -show_entries stream=codec_name,bit_rate,sample_rate \
        -of csv=p=0 "$input_file" 2>/dev/null)

    if [[ $? -eq 0 && -n "$probe_output" ]]; then
        IFS=',' read -r _caf_fmt _caf_br _caf_sr <<< "$probe_output"
        if [[ -n "$_caf_br" && "$_caf_br" -lt 48000 ]]; then
            local fmt_br
            fmt_br=$(ffprobe -v quiet -show_entries format=bit_rate \
                -of csv=p=0 "$input_file" 2>/dev/null)
            if [[ -n "$fmt_br" && "$fmt_br" -gt "$_caf_br" ]]; then
                _caf_br="$fmt_br"
            else
                _caf_br="48000"
            fi
        fi
        return 0
    fi
    _caf_fmt=""; _caf_br=""; _caf_sr=""
    return 1
}

optimize_bitrate()
{
    local source_bitrate="$1"
    local target_bitrate="$2"
    local content_type="${3:-audiobook}"

    if [[ -z "$target_bitrate" ]]; then
        case "$content_type" in
            audiobook|speech) echo "48k" ;;
            music)            echo "192k" ;;
            *)                echo "48k" ;;
        esac
        return 0
    fi

    local target_num="${target_bitrate%k}"
    if [[ ! "$target_num" =~ ^[0-9]+$ ]]; then
        echo "48k"; return 0
    fi

    if [[ "$content_type" == "audiobook" || "$content_type" == "speech" ]]; then
        if [[ $target_num -gt 48 ]]; then
            log_info "Audiobook: capping bitrate at 48k (target was $target_bitrate)" >&2
            echo "48k"; return 0
        fi
    fi
    echo "$target_bitrate"
}

# ---------------------------------------------------------------------------
# Cover art download
# ---------------------------------------------------------------------------

download_cover_art()
{
    local cover_url="$1" author="$2" series="$3" series_number="$4" title="$5"
    local output_file_ref="$6"
    local timeout="${7:-30}"

    if [[ -z "$cover_url" || "$cover_url" == "null" ]]; then
        log_debug "No cover URL provided"; return 1
    fi
    if [[ -z "${CCAB_WORKING_DIR:-}" ]]; then
        log_error "Working directory not initialized"; return 1
    fi

    local clean_author clean_series clean_title
    sanitize_for_filename "$author" clean_author
    sanitize_for_filename "$series" clean_series
    sanitize_for_filename "$title" clean_title

    local cover_filename
    if [[ -n "$clean_series" ]]; then
        if [[ -n "$series_number" ]]; then
            cover_filename="${clean_author:-Unknown} - ${clean_series} ${series_number} - ${clean_title:-Unknown}.jpg"
        else
            cover_filename="${clean_author:-Unknown} - ${clean_series} - ${clean_title:-Unknown}.jpg"
        fi
    else
        cover_filename="${clean_author:-Unknown} - ${clean_title:-Unknown}.jpg"
    fi

    local output_file="$CCAB_WORKING_DIR/$cover_filename"
    mkdir -p "$CCAB_WORKING_DIR"

    log_debug "Downloading cover art from: ${cover_url:0:60}..."

    if curl -s -L --max-time "$timeout" --max-filesize "10M" \
            --user-agent "ccab/2.0" -o "$output_file" "$cover_url"; then
        if validate_image_file "$output_file"; then
            [[ -n "$output_file_ref" ]] && printf -v "$output_file_ref" '%s' "$output_file"
            return 0
        fi
        log_warn "Downloaded file is not a valid image"
        rm -f "$output_file"
        return 1
    fi
    log_warn "Cover art download failed"
    rm -f "$output_file"
    return 1
}

save_cover_art()
{
    local cover_url="$1" title="$2" author="$3" cover_file_ref="$4"
    local series="${5:-}" series_number="${6:-}"

    [[ -z "$CCAB_WORKING_DIR" ]] && { log_error "Working directory not initialized"; return 1; }
    [[ -z "$cover_url" || "$cover_url" == "null" ]] && { log_debug "No cover URL"; return 1; }

    local downloaded_path=""
    if download_cover_art "$cover_url" "$author" "$series" "$series_number" "$title" downloaded_path; then
        [[ -n "$cover_file_ref" ]] && printf -v "$cover_file_ref" '%s' "$downloaded_path"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Core conversion
# ---------------------------------------------------------------------------

convert_to_mp3()
{
    local input_file="$1"
    local output_file="$2"
    local target_bitrate="${3:-48k}"
    local content_type="${4:-audiobook}"

    local vr
    if ! validate_audio_file "$input_file" vr; then
        log_error "Input validation failed: $vr"; return 1
    fi

    log_info "Converting $(basename "$input_file") to MP3..."

    local current_format current_bitrate current_sample_rate
    check_audio_format "$input_file" current_format current_bitrate current_sample_rate

    local optimized_bitrate
    optimized_bitrate=$(optimize_bitrate "$current_bitrate" "$target_bitrate" "$content_type")
    log_info "Target bitrate: $optimized_bitrate"

    # Already correct format+bitrate? Just copy.
    if [[ "$current_format" == "mp3" ]]; then
        local target_bps=$((${optimized_bitrate%k} * 1000))
        if [[ -n "$current_bitrate" && "$current_bitrate" -eq "$target_bps" ]]; then
            log_debug "Already MP3 at target bitrate, copying..."
            if cp "$input_file" "$output_file"; then
                touch "$(dirname "$input_file")/done.txt"
                _log_conversion "$output_file"
                return 0
            fi
            return 1
        fi
    fi

    mkdir -p "$(dirname "$output_file")" || { log_error "Cannot create output dir"; return 1; }

    local output_channels="2"
    [[ "${audioChannels:-stereo}" == "mono" ]] && output_channels="1"

    local temp_output="${output_file}.tmp.mp3"
    local ffmpeg_args=(
        "-hide_banner" "-loglevel" "quiet" "-stats" "-y"
        "-i" "$input_file"
        "-map" "0:a:0"
        "-codec:a" "libmp3lame"
        "-b:a" "$optimized_bitrate"
        "-ar" "44100"
        "-ac" "$output_channels"
        "-f" "mp3"
    )

    if [[ "$content_type" == "audiobook" || "$content_type" == "speech" ]]; then
        [[ "$output_channels" == "2" ]] && ffmpeg_args+=("-joint_stereo" "0")
        ffmpeg_args+=("-cutoff" "15000")
    fi
    [[ "$content_type" == "music" ]] && ffmpeg_args+=("-q:a" "0")

    ffmpeg_args+=(
        "-max_muxing_queue_size" "1024"
        "-avoid_negative_ts" "make_zero"
        "$temp_output"
    )

    # Show duration before starting
    local probe_out
    probe_out=$(ffprobe -v quiet -print_format json -show_format "$input_file" 2>/dev/null)
    if [[ -n "$probe_out" ]]; then
        local dur sec h m s
        dur=$(echo "$probe_out" | jq -r '.format.duration // ""' 2>/dev/null)
        if [[ -n "$dur" && "$dur" != "null" ]]; then
            sec="${dur%.*}"
            h=$((sec/3600)); m=$(((sec%3600)/60)); s=$((sec%60))
            echo -e "             duration=${C3}$(printf "%02d:%02d:%02d" $h $m $s)${C0}"
        fi
    fi

    if ffmpeg "${ffmpeg_args[@]}"; then
        local vr2
        if validate_audio_file "$temp_output" vr2; then
            if mv "$temp_output" "$output_file"; then
                touch "$(dirname "$input_file")/done.txt"
                _log_conversion "$output_file"
                log_info "Conversion complete: $(basename "$output_file")"
                return 0
            fi
        fi
        log_error "Output validation failed: $vr2"
        rm -f "$temp_output"
        return 1
    fi
    rm -f "$temp_output"
    log_error "FFmpeg conversion failed"
    return 1
}

_log_conversion()
{
    local output_file="$1"
    if [[ -n "${logDir:-}" && -d "$logDir" && -w "$logDir" ]]; then
        local ts genre base
        ts=$(date '+%Y-%b-%d' | tr '[:lower:]' '[:upper:]')
        genre="${META_GENRE:-Unknown}"
        base="$(basename "$output_file" .mp3)"
        echo "${ts};[${genre}];${base}" >> "$logDir/converted.log" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Combine multiple audio files
# ---------------------------------------------------------------------------

combine_audio_files()
{
    local source_dir="$1"
    local output_file="$2"
    local target_bitrate="${3:-48k}"
    local content_type="${4:-audiobook}"

    [[ ! -d "$source_dir" ]] && { log_error "Source directory not found: $source_dir"; return 1; }

    local audio_files=()
    while IFS= read -r -d '' file; do
        audio_files+=("$file")
    done < <(find "$source_dir" -maxdepth 1 -type f \
        \( -iname "*.mp3" -o -iname "*.m4a" -o -iname "*.m4b" \
           -o -iname "*.flac" -o -iname "*.mp4" -o -iname "*.aac" -o -iname "*.wav" \) \
        -print0 2>/dev/null | sort -z -V)

    if [[ ${#audio_files[@]} -eq 0 ]]; then
        log_error "No audio files found in: $source_dir"; return 1
    fi

    if [[ ${#audio_files[@]} -eq 1 ]]; then
        log_info "Single audio file found, converting directly"
        convert_to_mp3 "${audio_files[0]}" "$output_file" "$target_bitrate" "$content_type"
        return $?
    fi

    log_info "Found ${#audio_files[@]} audio files to combine"

    # Validate all inputs
    for f in "${audio_files[@]}"; do
        local vr
        if ! validate_audio_file "$f" vr; then
            log_error "Invalid audio file: $f - $vr"; return 1
        fi
    done

    mkdir -p "$(dirname "$output_file")"

    local temp_dir="${CCAB_WORKING_DIR:-/tmp}"
    local concat_file="$temp_dir/ffmpeg_concat_$$.txt"
    local temp_output="$temp_dir/combined_audio_$$.mp3"

    true > "$concat_file"
    for f in "${audio_files[@]}"; do
        local ef="${f//\'/\'\\\'\'}"
        echo "file '$ef'" >> "$concat_file"
    done

    local output_channels="2"
    [[ "${audioChannels:-stereo}" == "mono" ]] && output_channels="1"

    local ffmpeg_args=(
        "-hide_banner" "-loglevel" "quiet" "-stats" "-y"
        "-f" "concat" "-safe" "0" "-i" "$concat_file"
        "-codec:a" "libmp3lame"
        "-b:a" "$target_bitrate"
        "-ar" "44100"
        "-ac" "$output_channels"
        "-f" "mp3"
    )
    if [[ "$content_type" == "audiobook" || "$content_type" == "speech" ]]; then
        [[ "$output_channels" == "2" ]] && ffmpeg_args+=("-joint_stereo" "0")
        ffmpeg_args+=("-cutoff" "15000")
    fi
    ffmpeg_args+=("-max_muxing_queue_size" "1024" "-avoid_negative_ts" "make_zero" "$temp_output")

    log_info "Combining ${#audio_files[@]} files..."

    if ffmpeg "${ffmpeg_args[@]}"; then
        local vr
        if validate_audio_file "$temp_output" vr; then
            if mv "$temp_output" "$output_file"; then
                rm -f "$concat_file"
                log_info "Combined: $(basename "$output_file") ($(du -h "$output_file" | cut -f1))"
                return 0
            fi
        fi
        log_error "Combined file validation failed: $vr"
        rm -f "$concat_file" "$temp_output"
        return 1
    fi
    log_error "Audio combination failed"
    rm -f "$concat_file" "$temp_output"
    return 1
}

export -f create_working_directory cleanup_working_directory setup_cleanup_trap move_book_html
export -f validate_audio_file validate_image_file check_audio_format optimize_bitrate
export -f download_cover_art save_cover_art
export -f convert_to_mp3 combine_audio_files _log_conversion
