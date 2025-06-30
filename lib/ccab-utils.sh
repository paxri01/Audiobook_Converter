#!/bin/bash
#shellcheck disable=SC2004

## ========================================================================================
##       Title: ccab-utils.sh
##      Author: R. L. Paxton
##     Version: 4.0
##        Date: 2025-06-19
##     License: Apache 2.0
## Description: System utilities module for ccab audiobook converter
##              Handles hardware detection, cleanup, and common utilities
## ========================================================================================

# Module identification
#shellcheck disable=SC2034
CCAB_UTILS_MODULE="ccab-utils"
#shellcheck disable=SC2034
CCAB_UTILS_VERSION="4.0"

# Color definitions
C0='\033[0;00m'    # Normal
C1='\033[0;91m'    # Red
C2='\033[0;92m'    # Green
C3='\033[0;93m'    # Yellow
#shellcheck disable=SC2034
C4='\033[0;94m'    # Blue
#shellcheck disable=SC2034
C5='\033[0;95m'    # Magenta
C6='\033[0;96m'    # Cyan
#shellcheck disable=SC2034
C7='\033[0;97m'    # White
C8='\033[0;90m'    # Dark Gray

checkCudaSupport()
{
  # Skip detection if explicitly disabled
  if [[ "$CUDA_PREFERENCE" == "false" ]]; then
    cuda=false
    echo -e "${C3}  >> CUDA disabled by configuration${C0}"
    return 0
  fi

  # Check for CUDA support
  if command -v nvidia-smi &> /dev/null; then
    if nvidia-smi &> /dev/null; then
      # Check if ffmpeg supports CUDA
      if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q nvenc; then
        cuda=true
        logMessage 'TRACE' "  >> CUDA acceleration available and enabled${C0}"
      else
        cuda=false
        logMessage 'WARN' "  >> CUDA detected but ffmpeg lacks nvenc support${C0}"
      fi
    else
      cuda=false
      logMessage 'WARN' "  >> CUDA driver issues detected${C0}"
    fi
  else
    cuda=false
    if [[ "$CUDA_PREFERENCE" == "true" ]]; then
      logMessage 'ERROR' "  >> ERROR: CUDA forced but nvidia-smi not found${C0}"
      return 1
    fi
    logMessage 'TRACE' "  >> CUDA not available, using CPU encoding${C0}"
  fi

  # Force enable if explicitly requested
  if [[ "$CUDA_PREFERENCE" == "true" && "$cuda" != "true" ]]; then
    logMessage 'ERROR' "  >> ERROR: CUDA forced but not available${C0}"
    return 1
  fi

  return 0
}

cleanUp()
{
  local STATUS=${1:-0}
  
  echo -e "${C8}>>> Performing cleanup${C0}"
  
  # Clean up working directory if it exists
  if [[ -n "${workDir:-}" && -d "$workDir" ]]; then
    echo -e "${C8}>>> Removing working directory: $workDir${C0}"
    rm -rf "${workDir:?}" 2>/dev/null || {
      echo -e "${C3}>>> Warning: Could not remove working directory${C0}"
    }
  fi
  
  # Clean up any remaining temporary files
  if [[ -n "${tmpDir:-}" && -d "$tmpDir/ccab" ]]; then
    find "$tmpDir/ccab" -name "ccab.*" -mtime +1 -delete 2>/dev/null || true
  fi
  
  # Log cleanup completion
  if (( STATUS == 0 )); then
    echo -e "${C2}>>> Cleanup completed successfully${C0}"
  else
    echo -e "${C3}>>> Cleanup completed with status: $STATUS${C0}"
  fi
  
  exit "$STATUS"
}

setupCleanupHandler()
{
  # Set up signal handlers for graceful cleanup
  trap 'cleanUp 1' 1 2 3 15
}

usage()
{
  echo -e "${C8}NAME${C0}"
  echo "    ccab - re-encode audio files."
  echo
  echo -e "${C8}OPTIONS${C0}"
  echo -e "    ${C2}-c${C0}, ${C2}--concat${C0}"
  echo "        Will combine detected files into a single .mp3 file."
  echo -e "    ${C2}--cuda${C0}"
  echo "        Force enable CUDA acceleration (will fail if not available)."
  echo -e "    ${C2}--no-cuda${C0}"
  echo "        Disable CUDA acceleration and use CPU encoding only."
  echo -e "    ${C2}-d${C0}, ${C2}--debug${C0}"
  echo "        Enable debug output."
  echo -e "    ${C2}--flac${C0}"
  echo "        Will limit search of input files to .flac files only."
  echo -e "    ${C2}-h${C0}, ${C2}--help${C0}"
  echo "        Display this help message."
  echo -e "    ${C2}-l${C0}, ${C2}--lookup${C0}"
  echo "        Enable metadata lookup from online sources (Amazon, Goodreads, Audible)."
  echo -e "    ${C2}-m${C0}, ${C2}--move${C0}"
  echo "        After re-encoding, will move new files to specified directory (baseDir)."
  echo "        May add option value on the command line to avoid prompting if book"
  echo "        type is know before hand [-m #]."
  echo "            Move Categories:"

  # Display genre categories from configuration
  if [[ -n "${GENRE_CATEGORIES:-}" ]]; then
    local category
    for category in "${GENRE_CATEGORIES[@]}"; do
      local num display_name
      IFS=':' read -r num display_name _ <<< "$category"
      echo "               $num = $display_name"
    done
  else
    echo "               1 = Romance"
    echo "               2 = Hot"
    echo "               3 = SciFi"
    echo "               4 = Fantasy"
    echo "               5 = Thriller"
    echo "               6 = Misc"
  fi

  echo -e "    ${C2}--m4b${C0}"
  echo "        Will limit search of input files to .m4a or .m4b files only."
  echo -e "    ${C2}--mp3${C0}"
  echo "        Will limit search of input files to .mp3 or .mp4 files only."
  echo -e "    ${C2}--no-interactive${C0}"
  echo "        Disable interactive prompts for metadata lookup."
  echo -e "    ${C2}-r${C0}, ${C2}--recurse${C0}"
  echo "        Will search subdirectories for input files, make sure subdirectories are"
  echo "        zero padded if more that 9 subs (ex. /disk 1 ==> /disk 01)."
  echo -e "    ${C2}--skip-existing${C0}"
  echo "        Skip metadata lookup for files that already have metadata."
  echo -e "    ${C2}-v${C0}, ${C2}--verify${C0}"
  echo "        Verify ID3 tags."
  echo -e "    ${C2}-x${C0}, ${C2}--remove${C0}"
  echo "        Remove source files after successful conversion (DANGEROUS)."
  echo
  echo -e "${C8}EXAMPLES${C0}"
  echo "    ccab.sh                          # Process current directory"
  echo "    ccab.sh -r /path/to/audiobooks   # Process directory recursively"
  echo "    ccab.sh -c --cuda               # Concatenate files with CUDA acceleration"
  echo "    ccab.sh -l -r /audiobooks       # Process with metadata lookup"
  echo "    ccab.sh -l --no-interactive     # Automated metadata lookup"
  echo "    ccab.sh -m 3 /audiobooks        # Process and move to SciFi category"
  echo
  echo -e "${C8}CONFIGURATION${C0}"
  echo "    Configuration file locations (in order of preference):"
  echo "      ./ccab.conf"
  echo "      ~/.config/ccab/ccab.conf"
  echo "      /etc/ccab/ccab.conf"
  echo "    "
  echo "    Use ccab.example.conf as a template."
  echo
  echo -e "${C8}VERSION${C0}"
  echo "    ccab.sh version 4.0"
  echo
}

validateDependencies()
{
  local missing_deps=()
  local optional_deps=()
  
  # Check required dependencies
  local required_commands=("ffmpeg" "ffprobe" "mid3v2" "curl" "lame" "jq")
  for cmd in "${required_commands[@]}"; do
    if ! validateCommand "$cmd"; then
      missing_deps+=("$cmd")
    else
      logMessage 'TRACE' "  >> Validated $cmd available"
    fi
  done
  
  # Check optional dependencies
  local optional_commands=("sweech" "hxnormalize" "fancy_audio")
  for cmd in "${optional_commands[@]}"; do
    if ! validateCommand "$cmd"; then
      optional_deps+=("$cmd")
    else
      logMessage 'TRACE' "  >> Validated optional $cmd available"
    fi
  done
  
  # Report missing required dependencies
  if [[ ${#missing_deps[@]} -gt 0 ]]; then
    logMessage 'ERROR' ">>> ERROR: Missing required dependencies:"
    for dep in "${missing_deps[@]}"; do
      case "$dep" in
        "ffmpeg"|"ffprobe")
          logMessage 'ERROR' "  >> $dep not found. Install: ${C2}sudo dnf install ffmpeg"
          ;;
        "mid3v2")
          logMessage 'ERROR' "  >> $dep not found. Install: ${C2}sudo pip install mutagen"
          ;;
        "fancy_audio")
          logMessage 'ERROR' "  >> $dep not found. Install: ${C2}sudo gem install fancy_audio"
          ;;
        "curl")
          logMessage 'ERROR' "  >> $dep not found. Install: ${C2}sudo dnf install curl"
          ;;
        "lame")
          logMessage 'ERROR' "  >> $dep not found. Install: ${C2}sudo dnf install lame"
          ;;
        "jq")
          logMessage 'ERROR' "  >> $dep not found. Install: ${C2}sudo dnf install jq"
          ;;
      esac
    done
    return 1
  fi
  
  # Report missing optional dependencies
  if [[ ${#optional_deps[@]} -gt 0 ]]; then
    logMessage 'WARN' ">>> WARNING: Missing optional dependencies:"
    for dep in "${optional_deps[@]}"; do
      case "$dep" in
        "sweech")
          logMessage 'WARN' "  >> $dep not found. Install: ${C2}sudo pip install sweech-cli"
          ;;
        "hxnormalize")
          logMessage 'WARN' "  >> $dep not found. Install: ${C2}sudo dnf install html-xml-utils"
          ;;
        "fancy_audio")
          logMessage 'WARN' "  >> $dep not found. Install: ${C2}sudo gem install fancy_audio"
          ;;
      esac
    done
  fi
  
  return 0
}

# Progress display utilities
showProgress()
{
  local current="$1"
  local total="$2"
  local operation="${3:-Processing}"
  local width=50
  
  local percent=$((current * 100 / total))
  local filled=$((current * width / total))
  local empty=$((width - filled))
  
  printf "\r${C2}%s: [" "$operation"
  printf "%*s" $filled | tr ' ' '='
  printf "%*s" $empty | tr ' ' '-'
  printf "] %d%% (%d/%d)${C0}" "$percent" "$current" "$total"
  
  if [[ $current -eq $total ]]; then
    echo
  fi
}

# Initialize utilities module
initializeUtils()
{
  logMessage 'INFO' ">>> Initializing utilities module..."
  
  # Setup cleanup handler
  setupCleanupHandler
  logMessage 'TRACE' "  >> Set trap handlers"
  
  # Validate dependencies
  if ! validateDependencies; then
    return 1
  fi
  
  # Check CUDA support
  if ! checkCudaSupport; then
    return 1
  fi
  
  logMessage 'INFO' ">>> Utilities module initialized successfully"
  return 0
}

# Export functions for use by other modules
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  # Script is being sourced
  export -f checkCudaSupport
  export -f cleanUp
  export -f setupCleanupHandler
  export -f usage
  export -f validateDependencies
  export -f showProgress
  export -f logMessage
  export -f initializeUtils
fi