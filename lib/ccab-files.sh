#!/bin/bash
#shellcheck disable=SC2004

## ========================================================================================
##       Title: ccab-files.sh
##      Author: R. L. Paxton
##     Version: 4.0
##        Date: 2025-06-19
##     License: Apache 2.0
## Description: File management module for ccab audiobook converter
##              Handles file discovery, metadata extraction, and file operations
## ========================================================================================

# Module identification
#shellcheck disable=SC2034
CCAB_FILES_MODULE="ccab-files"
#shellcheck disable=SC2034
CCAB_FILES_VERSION="4.0"

# Global arrays for file management
declare -a inFiles
declare -a baseName
declare -a filePath
declare -a fileFormat
declare -a fileSize
declare -a duration
declare -a bitrate
declare -a sampleRate
declare -a channels

getFiles()
{
  local searchDir="${1:-$PWD}"
  local searchType="${2:-all}"
  local recurse="${3:-false}"
  local file_count=0
  
  logMessage 'INFO' ">>> Discovering audio files in: $searchDir"
  
  # Clear arrays
  inFiles=()
  baseName=()
  filePath=()
  fileFormat=()
  fileSize=()
  duration=()
  bitrate=()
  sampleRate=()
  channels=()
  
  # Build find command based on parameters
  local find_cmd="find"
  local find_args=("$searchDir")
  
  if [[ "$recurse" != "true" ]]; then
    find_args+=("-maxdepth" "1")
  fi
  
  find_args+=("-type" "f")
  
  # Add file type filters
  case "$searchType" in
    "mp3")
      find_args+=("(" "-iname" "*.mp3" "-o" "-iname" "*.mp4" ")")
      ;;
    "m4b")
      find_args+=("(" "-iname" "*.m4a" "-o" "-iname" "*.m4b" ")")
      ;;
    "flac")
      find_args+=("-iname" "*.flac")
      ;;
    "all"|*)
      find_args+=("(" "-iname" "*.mp3" "-o" "-iname" "*.m4a" "-o" "-iname" "*.m4b" "-o" "-iname" "*.flac" "-o" "-iname" "*.mp4" ")")
      ;;
  esac
  
  # Execute find command and populate arrays
  while IFS= read -r -d '' file; do
    if [[ -f "$file" && -r "$file" ]]; then
      inFiles[$file_count]="$file"
      baseName[$file_count]=$(basename "$file")
      filePath[$file_count]=$(dirname "$file")
      # Initialize metadata arrays with placeholder values
      fileFormat[$file_count]="unknown"
      fileSize[$file_count]="0"
      duration[$file_count]="0"
      bitrate[$file_count]="0"
      sampleRate[$file_count]="44100"
      channels[$file_count]="2"
      ((file_count++))
    fi
  done < <("$find_cmd" "${find_args[@]}" -print0 2>/dev/null | sort -z)
  
  if [[ $file_count -eq 0 ]]; then
    logMessage "WARN" "No audio files found in $searchDir"
    return 1
  fi
  
  logMessage "INFO" "Found $file_count audio files"
  return 0
}

probeFile()
{
  local file="$1"
  local index="$2"
  
  if [[ ! -f "$file" ]]; then
    logMessage "ERROR" "File not found: $file"
    return 1
  fi
  
  logMessage "DEBUG" "Probing file: $file"
  
  # Extract metadata using ffprobe
  local probe_output
  probe_output=$(ffprobe -v quiet -print_format json -show_format -show_streams "$file" 2>/dev/null)
  
  if [[ $? -ne 0 || -z "$probe_output" ]]; then
    logMessage "WARN" "Could not probe file: $file"
    return 1
  fi
  
  # Parse JSON output
  local format_name duration_val size_val bit_rate sample_rate channels_val
  
  format_name=$(echo "$probe_output" | jq -r '.format.format_name // "unknown"' 2>/dev/null)
  duration_val=$(echo "$probe_output" | jq -r '.format.duration // "0"' 2>/dev/null)
  size_val=$(echo "$probe_output" | jq -r '.format.size // "0"' 2>/dev/null)
  bit_rate=$(echo "$probe_output" | jq -r '.format.bit_rate // "0"' 2>/dev/null)
  
  # Get audio stream info
  sample_rate=$(echo "$probe_output" | jq -r '.streams[] | select(.codec_type=="audio") | .sample_rate // "0"' 2>/dev/null | head -1)
  channels_val=$(echo "$probe_output" | jq -r '.streams[] | select(.codec_type=="audio") | .channels // "0"' 2>/dev/null | head -1)
  
  # Store metadata in arrays
  fileFormat[$index]="$format_name"
  duration[$index]="$duration_val"
  fileSize[$index]="$size_val"
  bitrate[$index]="$bit_rate"
  sampleRate[$index]="${sample_rate:-44100}"
  channels[$index]="${channels_val:-2}"
  
  # Interactive prompts if metadata is missing or unclear (only in interactive mode)
  if [[ "$duration_val" == "0" || "$duration_val" == "null" ]] && [[ "${interactive:-true}" == "true" ]]; then
    echo -e "${C3}>>> Warning: Could not determine duration for: ${baseName[$index]}${C0}"
    echo -n ">>> Enter duration in seconds (or press Enter to skip): "
    read -r user_duration
    if [[ -n "$user_duration" && "$user_duration" =~ ^[0-9]+$ ]]; then
      duration[$index]="$user_duration"
    fi
  fi
  
  # Validate file format
  case "${fileFormat[$index]}" in
    *"mp3"*|*"mpeg"*)
      fileFormat[$index]="mp3"
      ;;
    *"m4a"*|*"mp4"*|*"aac"*)
      fileFormat[$index]="m4a"
      ;;
    *"flac"*)
      fileFormat[$index]="flac"
      ;;
    *)
      if [[ "${interactive:-true}" == "true" ]]; then
        echo -e "${C3}>>> Unknown format for: ${baseName[$index]}${C0}"
        echo -n ">>> Enter format (mp3/m4a/flac) or press Enter for mp3: "
        read -r user_format
        fileFormat[$index]="${user_format:-mp3}"
      else
        fileFormat[$index]="mp3"  # Default to mp3 in non-interactive mode
      fi
      ;;
  esac
  
  logMessage "DEBUG" "Probed ${baseName[$index]}: ${fileFormat[$index]}, ${duration[$index]}s, ${fileSize[$index]} bytes"
  return 0
}

checkFile()
{
  local file="$1"
  local index="$2"
  local needs_conversion=false
  
  # Check if file needs conversion based on format and size
  case "${fileFormat[$index]}" in
    "m4a"|"m4b"|"flac"|"mp4")
      needs_conversion=true
      logMessage "INFO" "File needs format conversion: ${baseName[$index]}"
      ;;
    "mp3")
      # Check if bitrate needs adjustment
      local current_bitrate="${bitrate[$index]}"
      #shellcheck disable=SC2154
      if [[ "$current_bitrate" -gt $((targetBitrate * 1000)) ]]; then
        needs_conversion=true
        logMessage "INFO" "File needs bitrate reduction: ${baseName[$index]} (${current_bitrate} > ${targetBitrate}k)"
      fi
      
      # Check file size
      local current_size="${fileSize[$index]}"
      #shellcheck disable=SC2154
      if [[ "$current_size" -lt "$minFileSize" ]]; then
        logMessage "INFO" "File size is too small to re-encoding: ${baseName[$index]} (${current_size} < ${minFileSize})"
        return 1
      fi
      ;;
  esac
  
  if [[ "$needs_conversion" == "true" ]]; then
    return 0  # Needs processing
  else
    logMessage "INFO" "File already in correct format: ${baseName[$index]}"
    return 1  # No processing needed
  fi
}

# File concatenation for multiple parts
concatenateFiles()
{
  local output_file="$1"
  local start_index="$2"
  local end_index="$3"
  
  logMessage "INFO" "Concatenating files from index $start_index to $end_index"
  
  # Create concatenation list file
  local concat_list
  concat_list=$(createSecureTempFile "concat_list" ".txt")
  
  local i
  for ((i=start_index; i<=end_index; i++)); do
    if [[ -f "${inFiles[$i]}" ]]; then
      echo "file '${inFiles[$i]}'" >> "$concat_list"
    fi
  done
  
  # Perform concatenation
  local concat_cmd=(
    "ffmpeg" "-f" "concat" "-safe" "0" "-i" "$concat_list"
    "-c" "copy" "-y" "$output_file"
  )
  
  logMessage "DEBUG" "Concatenation command: ${concat_cmd[*]}"
  
  if executeSecureCommand "${concat_cmd[@]}"; then
    logMessage "INFO" "Files concatenated successfully to: $output_file"
    rm -f "$concat_list"
    return 0
  else
    logMessage "ERROR" "File concatenation failed"
    rm -f "$concat_list"
    return 1
  fi
}

# Get file statistics
getFileStats()
{
  local total_files=${#inFiles[@]}
  local total_size=0
  local total_duration=0
  local i
  
  for ((i=0; i<total_files; i++)); do
    # Safely handle potentially uninitialized or non-numeric values
    local size_val="${fileSize[i]:-0}"
    local dur_val="${duration[i]:-0}"
    
    # Ensure numeric values
    if [[ "$size_val" =~ ^[0-9]+$ ]]; then
      total_size=$((total_size + size_val))
    fi
    
    # Convert duration to integer if it's a decimal
    dur_val="${dur_val%.*}"
    if [[ "$dur_val" =~ ^[0-9]+$ ]]; then
      total_duration=$((total_duration + dur_val))
    fi
  done
  
  # Convert to human readable format
  local size_mb=$((total_size / 1048576))
  local duration_hours=$((total_duration / 3600))
  local duration_minutes=$(((total_duration % 3600) / 60))
  
  echo -e "${C3}>>> File Statistics:${C0}"
  echo -e "${C3}>>>   Total files: $total_files${C0}"
  echo -e "${C3}>>>   Total size: ${size_mb}MB${C0}"
  echo -e "${C3}>>>   Total duration: ${duration_hours}h ${duration_minutes}m${C0}"
}

# Validate file array integrity
validateFileArrays()
{
  local file_count=${#inFiles[@]}
  
  if [[ $file_count -eq 0 ]]; then
    logMessage "ERROR" "No files loaded"
    return 1
  fi
  
  # Check that all arrays have the same length
  local arrays=("baseName" "filePath" "fileFormat" "fileSize" "duration" "bitrate" "sampleRate" "channels")
  local validation_errors=0
  
  for array_name in "${arrays[@]}"; do
    local -n array_ref="$array_name"
    if [[ ${#array_ref[@]} -ne $file_count ]]; then
      logMessage "ERROR" "Array size mismatch: $array_name has ${#array_ref[@]} elements, expected $file_count"
      ((validation_errors++))
    fi
  done
  
  if [[ $validation_errors -gt 0 ]]; then
    logMessage "ERROR" "File array validation failed with $validation_errors errors"
    logMessage "DEBUG" "Array sizes: inFiles=${#inFiles[@]}, baseName=${#baseName[@]}, filePath=${#filePath[@]}, fileFormat=${#fileFormat[@]}, fileSize=${#fileSize[@]}, duration=${#duration[@]}, bitrate=${#bitrate[@]}, sampleRate=${#sampleRate[@]}, channels=${#channels[@]}"
    return 1
  fi
  
  logMessage "DEBUG" "File arrays validated successfully"
  return 0
}

# Initialize file management module
initializeFileManagement()
{
  logMessage "INFO" ">>> Initializing file management module..."
  
  # Initialize arrays
  inFiles=()
  baseName=()
  filePath=()
  fileFormat=()
  fileSize=()
  duration=()
  bitrate=()
  sampleRate=()
  channels=()
  
  logMessage "INFO" ">>> File management module initialized successfully"
  return 0
}

# Export functions for use by other modules
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  # Script is being sourced
  export -f getFiles
  export -f probeFile
  export -f checkFile
  export -f concatenateFiles
  export -f getFileStats
  export -f validateFileArrays
  export -f initializeFileManagement
fi