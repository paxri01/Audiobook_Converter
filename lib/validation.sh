#!/bin/bash
# shellcheck disable=SC2016

## ========================================================================================
##       Title: validation.sh
##      Author: R. L. Paxton
##     Version: 2.0
##        Date: 2026-04-08
##     License: Apache 2.0
## Description: Input validation and sanitization library for ccab
## ========================================================================================

# Prevent multiple sourcing
if [[ "${VALIDATION_SOURCED:-}" == "true" ]]; then
    return 0
fi
export VALIDATION_SOURCED="true"

# Remove dangerous shell characters; trim to max_length; return via nameref
validate_input()
{
    local input="$1"
    local max_length="${2:-200}"
    local -n _vi_ref="$3"

    # shellcheck disable=SC2016
    local validated
    validated=$(echo "$input" | sed 's/[<>;&|`$(){}]//g' | head -c "$max_length")
    validated=$(echo "$validated" | tr -d '[:cntrl:]')
    validated=$(echo "$validated" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    _vi_ref="$validated"
}

# Basic URL format check
validate_url()
{
    local url="$1"
    [[ "$url" =~ ^https?://[a-zA-Z0-9.-]+/.*$ ]]
}

# Field-specific metadata validation
validate_metadata_field()
{
    local field_name="$1"
    local value="$2"
    local -n _vmf_ref="$3"

    case "$field_name" in
        title|author|narrator|publisher)
            validate_input "$value" 200 _vmf_ref ;;
        series)
            validate_input "$value" 100 _vmf_ref ;;
        asin)
            _vmf_ref=$(echo "$value" | sed 's/[^A-Za-z0-9]//g' | head -c 20) ;;
        duration)
            validate_input "$value" 50 _vmf_ref ;;
        description)
            validate_input "$value" 1000 _vmf_ref ;;
        series_number)
            local num="${value//[^0-9]/}"
            if [[ -n "$num" && "$num" -gt 0 ]]; then
                _vmf_ref=$(printf "%02d" "$num" 2>/dev/null || echo "01")
            else
                _vmf_ref="01"
            fi ;;
        *)
            validate_input "$value" 200 _vmf_ref ;;
    esac
}

# Remove path traversal and dangerous chars from file paths
validate_file_path()
{
    local file_path="$1"
    local -n _vfp_ref="$2"

    local validated="${file_path//[\<\>\&\|\`\$\(\)\{\}]/}"
    validated="${validated//..}"
    validated=$(echo "$validated" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    _vfp_ref="$validated"
}

# Sanitize query string for Google API
validate_search_query()
{
    local query="$1"
    local -n _vsq_ref="$2"

    local validated="${query//[\<\>\&\|\`\$\(\)\{\}]/}"
    validated=$(echo "$validated" | sed 's/[[:space:]]\+/ /g;s/^[[:space:]]*//;s/[[:space:]]*$//')
    validated=$(echo "$validated" | head -c 200)
    _vsq_ref="$validated"
}

# Sanitize string for safe filename usage
sanitize_for_filename()
{
    local input="$1"
    local -n _sff_ref="$2"
    local max_length="${3:-80}"

    local sanitized
    sanitized="$(echo "$input" | sed "s/[^a-zA-Z0-9' ,-]//g" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    if [[ ${#sanitized} -gt $max_length ]]; then
        local truncated="${sanitized:0:$max_length}"
        [[ "$truncated" =~ .*[[:space:]] ]] && truncated="${truncated% *}"
        sanitized="$truncated"
    fi

    while [[ "$sanitized" =~ [[:space:]-]$ ]]; do
        sanitized="${sanitized%?}"
    done

    [[ -z "$sanitized" ]] && sanitized="Unknown"
    _sff_ref="$sanitized"
}

export -f validate_input validate_url validate_metadata_field validate_file_path
export -f validate_search_query sanitize_for_filename
