#!/bin/bash
# shellcheck disable=SC2155

## ========================================================================================
##       Title: logging.sh
##      Author: R. L. Paxton
##     Version: 2.0
##        Date: 2026-04-08
##     License: Apache 2.0
## Description: Centralized logging library for ccab
## ========================================================================================

# Prevent multiple sourcing
if [[ "${LOGGING_SOURCED:-}" == "true" ]]; then
    return 0
fi
export LOGGING_SOURCED="true"

# Set default color codes if not already defined
if [[ -z "${C0:-}" ]]; then
    export C0='\033[0m'     # Reset/Normal
    export C1='\033[91m'    # Light Red (ERROR)
    export C2='\033[92m'    # Light Green (INFO)
    export C3='\033[93m'    # Light Yellow (WARN)
    export C4='\033[94m'    # Light Blue
    export C5='\033[95m'    # Light Magenta
    export C6='\033[96m'    # Light Cyan (DEBUG)
    export C7='\033[97m'    # Light White
    export C8='\033[90m'    # Dark Gray (TRACE)
fi

# Check if a message level should be displayed based on configured log level
_should_log()
{
    local msg_level="$1"
    local config_level="${logLevel:-INFO}"

    local -A level_values=(
        ["ERROR"]=1
        ["WARN"]=2
        ["INFO"]=3
        ["DEBUG"]=4
        ["TRACE"]=5
    )

    local msg_value="${level_values[$msg_level]:-3}"
    local config_value="${level_values[$config_level]:-3}"

    [[ $msg_value -le $config_value ]]
}

# Main logging function
logMessage()
{
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [[ "$level" != "ERROR" ]] && ! _should_log "$level"; then
        return 0
    fi

    case "$level" in
        "INFO")  echo -e "[$timestamp] ${C2}INFO:${C0} $message"  >&2 ;;
        "WARN")  echo -e "[$timestamp] ${C3}WARN:${C0} $message"  >&2 ;;
        "ERROR") echo -e "[$timestamp] ${C1}ERROR:${C0} $message" >&2 ;;
        "TRACE") echo -e "${C8}[$timestamp] TRACE: $message${C0}" >&2 ;;
        "DEBUG") echo -e "[$timestamp] ${C6}DEBUG:${C0} $message" >&2 ;;
        *)       echo -e "[$timestamp] $level: $message"           >&2 ;;
    esac

    if [[ -n "${logDir:-}" && -d "$logDir" && -w "$logDir" ]]; then
        echo "[$timestamp] $level: $message" >> "$logDir/ccab.log" 2>/dev/null || true
    fi
}

log_debug() { logMessage "DEBUG" "$1"; }
log_info()  { logMessage "INFO"  "$1"; }
log_warn()  { logMessage "WARN"  "$1"; }
log_error() { logMessage "ERROR" "$1"; }
log_trace() { logMessage "TRACE" "$1"; }

export -f _should_log logMessage log_debug log_info log_warn log_error log_trace
