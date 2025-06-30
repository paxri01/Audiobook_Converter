#!/bin/bash
#shellcheck disable=SC2004

## ========================================================================================
##       Title: ccab-config.sh
##      Author: R. L. Paxton
##     Version: 4.0
##        Date: 2025-06-19
##     License: Apache 2.0
## Description: Configuration management module for ccab audiobook converter
##              Handles configuration loading, validation, and directory setup
## ========================================================================================

# Module identification
#shellcheck disable=SC2034
CCAB_CONFIG_MODULE="ccab-config"
#shellcheck disable=SC2034
CCAB_CONFIG_VERSION="4.0"

## Configuration loading
loadConfiguration()
{
  local config_file config_paths
  
  # Define possible configuration file locations (in order of preference)
  config_paths=(
    "./ccab.conf"
    "$HOME/.config/ccab/ccab.conf"
    "/etc/ccab/ccab.conf"
    "$(dirname "$0")/ccab.conf"
    "$(dirname "$0")/config/ccab.conf"
  )
  
  # Find and load configuration file
  for config_file in "${config_paths[@]}"; do
    if [[ -f "$config_file" && -r "$config_file" ]]; then
      #shellcheck disable=SC1090
      source "$config_file"
      #shellcheck disable=SC2034
      CONFIG_SOURCE="$config_file"
      return 0
    fi
  done
  
  echo -e "${C1}>>> ERROR: No configuration file found${C0}"
  echo -e "${C1}>>> Please create a configuration file in one of these locations:${C0}"
  for config_file in "${config_paths[@]}"; do
    echo -e "${C1}>>>   $config_file${C0}"
  done
  echo -e "${C1}>>> Use ccab.example.conf as a template${C0}"
  return 1
}

validateConfiguration()
{
  local errors=0
  
  # Validate numeric values
  if ! [[ "$TARGET_BITRATE" =~ ^[0-9]+$ ]] || (( TARGET_BITRATE < 8 || TARGET_BITRATE > 320 )); then
    echo -e "${C1}ERROR: TARGET_BITRATE must be between 8 and 320${C0}"
    ((errors++))
  fi
  
  if ! [[ "$MIN_FILE_SIZE" =~ ^[0-9]+$ ]]; then
    echo -e "${C1}ERROR: MIN_FILE_SIZE must be a number${C0}"
    ((errors++))
  fi
  
  # Validate directory paths
  if [[ ! -d "$(dirname "$LOG_DIR")" ]]; then
    echo -e "${C3}WARNING: Parent directory of LOG_DIR does not exist: $(dirname "$LOG_DIR")${C0}"
  fi
  
  if [[ ! -d "$(dirname "$BASE_DIR")" ]]; then
    echo -e "${C3}WARNING: Parent directory of BASE_DIR does not exist: $(dirname "$BASE_DIR")${C0}"
  fi
  
  # Validate CUDA preference
  if [[ ! "$CUDA_PREFERENCE" =~ ^(auto|true|false)$ ]]; then
    echo -e "${C1}ERROR: CUDA_PREFERENCE must be 'auto', 'true', or 'false'${C0}"
    ((errors++))
  fi
  
  # Validate boolean values
  if [[ ! "$DEBUG_DEFAULT" =~ ^(true|false)$ ]]; then
    echo -e "${C1}ERROR: DEBUG_DEFAULT must be 'true' or 'false'${C0}"
    ((errors++))
  fi
  
  # Validate required files
  if [[ ! -f "$API_KEYS_FILE" ]]; then
    echo -e "${C3}WARNING: API_KEYS_FILE does not exist: $API_KEYS_FILE${C0}"
  fi
  
  # Validate temporary file names (must not be empty)
  local temp_vars=("TEMP_BOOK_HTML" "TEMP_BOOK_INFO" "TEMP_RICH_INFO" "TEMP_FILE_LIST" "TEMP_CONCAT_MP3" "TEMP_DONE_LOG")
  for var in "${temp_vars[@]}"; do
    if [[ -z "${!var}" ]]; then
      echo -e "${C1}ERROR: $var cannot be empty${C0}"
      ((errors++))
    fi
  done
  
  return $errors
}

applyConfiguration()
{
  # Map configuration variables to script variables for backwards compatibility
  #shellcheck disable=SC2034
  targetBitrate=$TARGET_BITRATE
  #shellcheck disable=SC2034
  tmpDir=$TMP_DIR
  #shellcheck disable=SC2034
  logDir=$LOG_DIR
  #shellcheck disable=SC2034
  baseDir=$BASE_DIR
  #shellcheck disable=SC2034
  user=$FILE_USER
  #shellcheck disable=SC2034
  group=$FILE_GROUP
  #shellcheck disable=SC2034
  minFileSize=$MIN_FILE_SIZE
  #shellcheck disable=SC2034
  convertLog="$LOG_DIR/$CONVERT_LOG_FILE"
  
  # Apply debug setting
  if [[ "$DEBUG_DEFAULT" == "true" ]]; then
    #shellcheck disable=SC2034
    debug=true
  fi
  
  # Validate genre categories array
  if [[ ${#GENRE_CATEGORIES[@]} -eq 0 ]]; then
    echo -e "${C1}ERROR: GENRE_CATEGORIES array is empty${C0}"
    return 1
  fi
}

setupDirectories()
{
  ## Verify temp directory
  if [[ ! -d "$tmpDir/ccab" ]]; then
    mkdir -p "$tmpDir/ccab" || {
      echo -e "${C1}[RC:2] ERROR: Cannot create temp directory: $tmpDir/ccab${C0}"
      return 2
    }
  fi
  #shellcheck disable=SC2034
  workDir=$(mktemp -d "$tmpDir/ccab/tmp.XXXXX") || {
    echo -e "${C1}[RC:2] ERROR: Cannot create working directory${C0}"
    return 2
  }

  ## Verify log directory exists and is writable
  if [[ ! -d "$logDir" ]]; then
    echo -e "${C1}[RC:2] ERROR: Log directory does not exist: $logDir${C0}"
    echo -e "${C1}>>> Please create the log directory or update LOG_DIR in configuration${C0}"
    echo -e "${C1}>>> Example: sudo mkdir -p \"$logDir\" && sudo chown $USER:$USER \"$logDir\"${C0}"
    return 2
  fi
  
  if [[ ! -w "$logDir" ]]; then
    echo -e "${C1}[RC:2] ERROR: Log directory is not writable by current user: $logDir${C0}"
    echo -e "${C1}>>> Please fix permissions or update LOG_DIR in configuration${C0}"
    echo -e "${C1}>>> Example: sudo chown $USER:$USER \"$logDir\" && chmod 755 \"$logDir\"${C0}"
    return 2
  fi

  ## Verify base directory
  if [[ ! -d "$baseDir" ]]; then
    echo -e "${C1}[RC:2] ERROR: Base directory does not exist: $baseDir${C0}"
    echo -e "${C1}>>> Please create the base directory or update BASE_DIR in configuration${C0}"
    return 2
  fi
  
  return 0
}

# Initialize configuration system
initializeConfiguration()
{
  local status=0
  
 logMessage 'INFO' ">>> Initializing configuration system (ccab-config.sh)..."
  
  # Load configuration
  if ! loadConfiguration; then
    logMessage 'ERROR' ">>> Configuration loading failed"
    return 1
  else
    logMessage 'TRACE' "  >> Loaded configuration file: $CONFIG_SOURCE"
  fi
  
  # Validate configuration
  if ! validateConfiguration; then
    logMessage 'INFO' ">>> Configuration validation failed"
    return 1
  else
    logMessage 'TRACE' "  >> Configuration values validated"
  fi
  
  # Apply configuration
  if ! applyConfiguration; then
    logMessage 'ERROR' ">>> Configuration application failed"
    return 1
  else
    logMessage 'TRACE' "  >> Applying configuration file parameters"
  fi
  
  # Setup directories
  if ! setupDirectories; then
    logMessage 'ERROR' ">>> Directory setup failed"
    return 1
  else
    logMessage 'TRACE' "  >> Setup directories"
    logMessage 'TRACE' "    > workDir: $workDir"
    logMessage 'TRACE' "    > logDir: $logDir"
    logMessage 'TRACE' "    > baseDir: $baseDir"
  fi
  
  logMessage 'INFO' ">>> Configuration system initialized successfully"
  return 0
}

# Export functions for use by other modules
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  # Script is being sourced
  export -f loadConfiguration
  export -f validateConfiguration
  export -f applyConfiguration
  export -f setupDirectories
  export -f initializeConfiguration
fi