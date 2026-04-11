#!/bin/bash
# shellcheck disable=SC2034

## ========================================================================================
##       Title: search.sh
##      Author: R. L. Paxton
##     Version: 2.0
##        Date: 2026-04-08
##     License: Apache 2.0
## Description: Google Custom Search API integration for ccab
##              Credentials: ~/.config/keys (_engine_id, _api_key)
## ========================================================================================

# Prevent multiple sourcing
if [[ "${SEARCH_SOURCED:-}" == "true" ]]; then
    return 0
fi
export SEARCH_SOURCED="true"

declare -g filtered_results=""

# Filter out non-book search results
is_relevant_result()
{
    local title="${1,,}"
    local link="${2,,}"

    # Drop Amazon category/search pages
    [[ "$link" =~ (/s\?|/gp/search|/stores/) ]] && return 1

    # Goodreads and Audible are always relevant
    [[ "$link" =~ (goodreads\.com|audible\.com) ]] && return 0

    # Amazon product pages: require book-like signals
    if [[ "$link" =~ amazon\.com ]]; then
        [[ "$title" =~ (book|ebook|audiobook|kindle|audible|paperback|hardcover|novel|story|series|author|unabridged|abridged|narrator) ]] && return 0
        [[ "$title" =~ (by |read by |narrated by |volume |vol\.|part\ [0-9]|#[0-9]) ]] && return 0
        [[ "$title" =~ [0-9]{10}|[0-9]{13}|978[0-9]{10} ]] && return 0
        [[ "$title" =~ \([a-z\&\ ]+\)|\ -\ |:\ [a-z] ]] && return 0
        return 1
    fi

    return 1
}

# Search Google Custom Search API
searchBooks()
{
    local search_query="$1"
    local max_results="${2:-5}"

    filtered_results=""

    [[ -z "$search_query" ]] && { log_error "Empty search query"; return 1; }

    if [[ ! -f "$HOME/.config/keys" ]]; then
        log_error "API keys file not found: $HOME/.config/keys"
        return 1
    fi
    # shellcheck disable=SC1091
    source "$HOME/.config/keys" || { log_error "Failed to load API keys"; return 1; }

    if [[ -z "${_engine_id:-}" || -z "${_api_key:-}" ]]; then
        log_error "Missing _engine_id or _api_key in $HOME/.config/keys"
        return 1
    fi

    local encoded_query="${search_query// /+}"
    local search_url="https://www.googleapis.com/customsearch/v1"
    search_url+="?key=$_api_key&cx=$_engine_id"
    search_url+="&q=$encoded_query&num=$max_results"
    search_url+="&fields=items(title,link,snippet)"

    log_info "Searching: $search_query"

    local search_results
    search_results=$(curl -s --max-time 30 --connect-timeout 10 --max-filesize "5M" \
        --user-agent "ccab/2.0" "$search_url" 2>/dev/null)

    if [[ $? -ne 0 || -z "$search_results" ]]; then
        log_warn "Search request failed"
        return 1
    fi
    if [[ ! "$search_results" =~ \"items\" ]]; then
        log_warn "No results in API response"
        return 1
    fi
    if ! echo "$search_results" | jq empty 2>/dev/null; then
        log_warn "Invalid JSON from API"
        return 1
    fi

    local amazon_results="" other_results="" relevant=0

    while IFS= read -r item; do
        if [[ -n "$item" ]]; then
            local t l
            t=$(echo "$item" | jq -r '.title // ""' 2>/dev/null)
            l=$(echo "$item" | jq -r '.link // ""' 2>/dev/null)
            if [[ -n "$t" && -n "$l" ]] && is_relevant_result "$t" "$l"; then
                ((relevant++))
                if [[ "$l" =~ amazon\.com ]]; then
                    amazon_results+="$item"$'\n'
                else
                    other_results+="$item"$'\n'
                fi
            fi
        fi
    done < <(echo "$search_results" | \
        jq -c '.items[]? | {title: .title, link: .link, snippet: .snippet}' 2>/dev/null)

    filtered_results="${amazon_results}${other_results}"

    log_info "Search complete: $relevant relevant result(s)"
    [[ $relevant -eq 0 ]] && { log_warn "No relevant results found"; return 1; }
    return 0
}

# Search for metadata for all discovered audio files
auto_search_metadata()
{
    local -n _asm_titles="$1"
    local -n _asm_authors="$2"
    local -n _asm_files="$3"

    local file_count=${#_asm_files[@]}
    [[ $file_count -eq 0 ]] && { log_error "No files to search"; return 1; }

    for ((i=0; i<file_count; i++)); do
        local title="${_asm_titles[$i]:-}"
        local author="${_asm_authors[$i]:-}"
        [[ -z "$title" && -z "$author" ]] && {
            log_warn "Skipping file $((i+1)): no metadata to search with"
            continue
        }

        local q
        q=$(build_search_query "$title" "$author" "")
        if [[ -n "$q" ]] && searchBooks "$q" 10; then
            display_search_results "$filtered_results"
        else
            log_warn "No results for: $(basename "${_asm_files[$i]}")"
        fi
    done
}

export -f is_relevant_result searchBooks auto_search_metadata
