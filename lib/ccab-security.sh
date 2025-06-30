#!/bin/bash
#shellcheck disable=SC2004

## ========================================================================================
##       Title: ccab-security.sh
##      Author: R. L. Paxton
##     Version: 4.0
##        Date: 2025-06-19
##     License: Apache 2.0
## Description: Security and validation module for ccab audiobook converter
##              Handles input validation, sanitization, and secure operations
## ========================================================================================

# Module identification
#shellcheck disable=SC2034
CCAB_SECURITY_MODULE="ccab-security"
#shellcheck disable=SC2034
CCAB_SECURITY_VERSION="4.0"

validateCommand()
{
  local cmd=$1
  if ! command -v "$cmd" &> /dev/null; then
    return 1
  fi
}

validateInput()
{
  local input="$1"
  local max_length="${2:-255}"

  # Truncate input to maximum length
  input="${input:0:$max_length}"

  # Remove potentially dangerous characters - comprehensive set
  #shellcheck disable=SC2001
  input=$(echo "$input" | sed "s/[;&|\`$(){}\"'<>*?[\]\\]//g")
  
  # Remove control characters, newlines, and tabs
  input=$(echo "$input" | tr -d '\000-\037\177')
  
  # Remove leading/trailing whitespace
  input=$(echo "$input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  
  echo "$input"
}

sanitizeHTML()
{
  local html_content="$1"
  local output_file="$2"
  
  # Remove script tags and their content
  html_content=$(echo "$html_content" | sed 's/<script[^>]*>.*<\/script>//gI')
  
  # Remove style tags and their content
  html_content=$(echo "$html_content" | sed 's/<style[^>]*>.*<\/style>//gI')
  
  # Remove potentially dangerous HTML tags
  #shellcheck disable=SC2001
  html_content=$(echo "$html_content" | sed 's/<\(iframe\|object\|embed\|form\|input\)[^>]*>//gI')
  
  # Remove HTML entities that could be problematic
  #shellcheck disable=SC2001
  html_content=$(echo "$html_content" | sed 's/&[#a-zA-Z0-9]*;//g')
  
  # Remove HTML comments
  #shellcheck disable=SC2001
  html_content=$(echo "$html_content" | sed 's/<!--.*-->//g')
  
  # Write sanitized content to file if specified
  if [[ -n "$output_file" ]]; then
    echo "$html_content" > "$output_file"
  else
    echo "$html_content"
  fi
}

validateURL()
{
  local url="$1"
  local allowed_hosts="$2"  # Optional: comma-separated list of allowed hosts
  
  # Check URL format
  if [[ ! "$url" =~ ^https?://[a-zA-Z0-9.-]+[/]?.*$ ]]; then
    return 1
  fi
  
  # Extract hostname for validation
  local hostname
  hostname=$(echo "$url" | sed -rn 's#^https?://([^/]+).*#\1#p')
  
  # Check against allowed hosts if specified
  if [[ -n "$allowed_hosts" ]]; then
    local allowed_host
    local host_found=false
    IFS=',' read -ra HOSTS <<< "$allowed_hosts"
    for allowed_host in "${HOSTS[@]}"; do
      if [[ "$hostname" == *"$allowed_host"* ]]; then
        host_found=true
        break
      fi
    done
    if [[ "$host_found" != true ]]; then
      return 1
    fi
  fi
  
  # Block localhost, private IPs, and other potentially dangerous hosts
  if [[ "$hostname" =~ ^(localhost|127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
    return 1
  fi
  
  return 0
}

createSecureTempFile()
{
  local prefix="${1:-ccab}"
  local suffix="${2:-.tmp}"
  local temp_file
  
  # Ensure temp directory exists
  #shellcheck disable=SC2154
  if [[ ! -d "$tmpDir/ccab" ]]; then
    mkdir -p "$tmpDir/ccab" || return 1
  fi
  
  # Create secure temporary file with restrictive permissions
  temp_file=$(mktemp "$tmpDir/ccab/${prefix}.XXXXXX${suffix}") || return 1
  chmod 600 "$temp_file" || return 1
  echo "$temp_file"
}

sanitizeFilename()
{
  local filename="$1"
  local max_length="${2:-255}"
  
  # Remove directory traversal attempts
  filename=$(basename "$filename")
  
  # Limit length
  filename="${filename:0:$max_length}"
  
  # Remove dangerous characters for filenames
  #shellcheck disable=SC2001
  filename=$(echo "$filename" | sed 's/[^a-zA-Z0-9._-]/_/g')
  
  # Ensure it doesn't start with dot or dash
  #shellcheck disable=SC2001
  filename=$(echo "$filename" | sed 's/^[.-]//')
  
  # Add fallback if empty
  if [[ -z "$filename" ]]; then
    filename="sanitized_file"
  fi
  
  echo "$filename"
}

urlEncode()
{
  local string="$1"
  local encoded=""
  local pos=0
  local char
  
  while [[ $pos -lt ${#string} ]]; do
    char="${string:$pos:1}"
    case "$char" in
      [a-zA-Z0-9.~_-])
        encoded+="$char"
        ;;
      *)
        encoded+=$(printf "%%%02X" "'$char")
        ;;
    esac
    ((pos++))
  done
  
  echo "$encoded"
}

# Validate file safety
validateFileAccess()
{
  local file_path="$1"
  local operation="${2:-read}"  # read, write, execute
  
  # Check if file exists for read operations
  if [[ "$operation" == "read" && ! -f "$file_path" ]]; then
    return 1
  fi
  
  # Check if directory exists for write operations
  if [[ "$operation" == "write" && ! -d "$(dirname "$file_path")" ]]; then
    return 1
  fi
  
  # Check permissions
  case "$operation" in
    "read")
      [[ -r "$file_path" ]] || return 1
      ;;
    "write")
      [[ -w "$(dirname "$file_path")" ]] || return 1
      ;;
    "execute")
      [[ -x "$file_path" ]] || return 1
      ;;
  esac
  
  # Check for directory traversal attempts
  if [[ "$file_path" =~ \.\./\.\. ]]; then
    return 1
  fi
  
  return 0
}

# Secure command execution wrapper
executeSecureCommand()
{
  local command="$1"
  shift
  local args=("$@")
  
  # Validate command exists
  if ! validateCommand "$command"; then
    echo "ERROR: Command not found: $command" >&2
    return 1
  fi
  
  # Execute with timeout to prevent hanging
  timeout 300 "$command" "${args[@]}"
  return $?
}

# Initialize security module
initializeSecurity()
{
  logMessage 'INFO' ">>> Initializing security module..."
  
  # Verify critical security dependencies
  local required_commands=("mktemp" "chmod" "basename" "dirname")
  for cmd in "${required_commands[@]}"; do
    if ! validateCommand "$cmd"; then
      logMessage 'ERROR' "ERROR: Required security command missing: $cmd"
      return 1
    else
      logMessage 'TRACE' "  >> Verified $cmd command"
    fi
  done
  
  logMessage 'INFO' ">>> Security module initialized successfully"
  return 0
}

# Export functions for use by other modules
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  # Script is being sourced
  export -f validateCommand
  export -f validateInput
  export -f sanitizeHTML
  export -f validateURL
  export -f createSecureTempFile
  export -f sanitizeFilename
  export -f urlEncode
  export -f validateFileAccess
  export -f executeSecureCommand
  export -f initializeSecurity
fi