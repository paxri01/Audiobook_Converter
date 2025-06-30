#!/bin/bash
#shellcheck disable=SC2001
#shellcheck disable=SC2004

## ========================================================================================
##       Title: ccab-modular.sh (Main Orchestration Script)
##      Author: R. L. Paxton
##     Version: 4.0
##        Date: 2025-06-19
##     License: Apache 2.0
## Description: Main orchestration script for modular ccab audiobook converter
##              Coordinates all modules to perform audiobook conversion
## ========================================================================================

# Script metadata
CCAB_VERSION="4.0"
#SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR='/home/rp01/git/paxri01/Audiobook_Converter.new'

# Color definitions (needed before modules load)
C0='\033[0;00m'    # Normal
C1='\033[0;91m'    # Red
C2='\033[0;92m'    # Green
C3='\033[0;93m'    # Yellow
C6='\033[0;96m'    # Magenta
C8='\033[0;90m'    # Dark Grey

# Add error handling and cleanup function
cleanupAndExit()
{
  local exit_code="$1"
  local cleanup_message="${2:-Processing interrupted}"
  
  logMessage "WARN" "$cleanup_message"
  
  # Cleanup temporary files if processing module is available
  if command -v processCleanupPhase >/dev/null 2>&1; then
    logMessage "INFO" "Performing cleanup..."
    processCleanupPhase
  fi
  
  # Display any available processing statistics
  if command -v getProcessingStats >/dev/null 2>&1; then
    local stats
    stats=$(getProcessingStats 2>/dev/null || echo "No statistics available")
    logMessage "INFO" "Final statistics: $stats"
  fi
  
  exit "$exit_code"
}

# Set up signal handlers for graceful shutdown
trap 'cleanupAndExit 130 "Processing interrupted by user"' INT
trap 'cleanupAndExit 143 "Processing terminated"' TERM

# Enable Consistent Logging 
logMessage()
{
  local level="$1"
  local message="$2"
  local timestamp
  
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  
  case "$level" in
    "INFO")
      echo -e "${C2}[$timestamp] INFO: $message${C0}"
      ;;
    "WARN")
      echo -e "${C3}[$timestamp] WARN: $message${C0}"
      ;;
    "ERROR")
      echo -e "${C1}[$timestamp] ERROR: $message${C0}"
      ;;
    "TRACE")
      echo -e "${C8}[$timestamp] TRACE: $message${C0}"
      ;;
    "DEBUG")
      if [[ "${debug:-false}" == "true" ]]; then
        echo -e "${C6}[$timestamp] DEBUG: $message${C0}"
      fi
      ;;
  esac
  
  # Also log to file if logDir is set
  if [[ -n "${logDir:-}" && -d "$logDir" ]]; then
    echo "[$timestamp] $level: $message" >> "$logDir/ccab.log"
  fi
}

# Initialize variables
concat=false
move=false
recurse=false
searchType="all"
debug=false
cuda="auto"
targetDir="$PWD"
lookupMetadata=false
interactive=true
skipExisting=false

# Variables for future implementation
#shellcheck disable=SC2034
moveOpt=""
#shellcheck disable=SC2034
verify=false
#shellcheck disable=SC2034
remove=false

# Load required modules
loadModules()
{
  local modules=(
    "ccab-config.sh"
    "ccab-security.sh" 
    "ccab-utils.sh"
    "ccab-files.sh"
    "ccab-parser.sh"
    "ccab-webscraper.sh"
    "ccab-audio.sh"
    "ccab-metadata.sh"
    "ccab-organization.sh"
    "ccab-processing.sh"
  )
  
  for module in "${modules[@]}"; do
    local module_path="$SCRIPT_DIR/lib/$module"
    if [[ -f "$module_path" ]]; then
      logMessage TRACE "  >> Loading module: $module"
      #shellcheck disable=SC1090
      source "$module_path"
    else
      logMessage ERROR "ERROR: Required module not found: $module_path"
      exit 1
    fi
  done
}

# Parse command line arguments
parseArguments()
{
  while [[ $# -gt 0 ]]; do
    case $1 in
      -c|--concat)
        concat=true
        shift
        ;;
      --cuda)
        cuda="true"
        shift
        ;;
      --no-cuda)
        cuda="false"
        shift
        ;;
      -d|--debug)
        debug=true
        shift
        ;;
      --flac)
        searchType="flac"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -m|--move)
        move=true
        if [[ -n "$2" && "$2" =~ ^[1-6]$ ]]; then
          #shellcheck disable=SC2034
          moveOpt="$2"
          shift
        fi
        shift
        ;;
      --m4b)
        searchType="m4b"
        shift
        ;;
      --mp3)
        searchType="mp3"
        shift
        ;;
      -l|--lookup)
        lookupMetadata=true
        shift
        ;;
      --no-interactive)
        interactive=false
        shift
        ;;
      --skip-existing)
        skipExisting=true
        shift
        ;;
      -r|--recurse)
        recurse=true
        shift
        ;;
      -v|--verify)
        #shellcheck disable=SC2034
        verify=true
        shift
        ;;
      -x|--remove)
        #shellcheck disable=SC2034
        remove=true
        shift
        ;;
      -*)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
      *)
        if [[ -d "$1" ]]; then
          targetDir="$1"
        else
          echo "Invalid directory: $1"
          exit 1
        fi
        shift
        ;;
    esac
  done
}

# Generate search query from filename
generateSearchQuery()
{
  local filename="$1"
  local query=""
  
  # Extract base filename without extension
  query=$(basename "$filename" | sed 's/\.[^.]*$//')
  
  # Clean up common patterns
  query=$(echo "$query" | sed 's/_/ /g' | sed 's/-/ /g' | sed 's/\./ /g')
  
  # Remove common audiobook suffixes
  query=$(echo "$query" | sed 's/[[:space:]]*([Uu]nabridged).*$//')
  query=$(echo "$query" | sed 's/[[:space:]]*[Aa]udiobook.*$//')
  query=$(echo "$query" | sed 's/[[:space:]]*[Mm][Pp]3.*$//')
  
  # Remove disc/part indicators
  query=$(echo "$query" | sed 's/[[:space:]]*[Dd]isc[[:space:]]*[0-9]*.*$//')
  query=$(echo "$query" | sed 's/[[:space:]]*[Pp]art[[:space:]]*[0-9]*.*$//')
  query=$(echo "$query" | sed 's/[[:space:]]*[Cc][Dd][[:space:]]*[0-9]*.*$//')
  
  # Trim whitespace
  query=$(echo "$query" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  
  echo "$query"
}

# Perform metadata lookup for discovered files
performMetadataLookup()
{
  local file_count="$1"
  
  echo -e "${C2}>>> Starting Metadata Lookup${C0}"
  echo
  
  # Clear any existing book data
  clearBookData
  clearScrapedData
  
  local successful_lookups=0
  local skipped_lookups=0
  
  for ((i=0; i<file_count; i++)); do
    #shellcheck disable=SC2154
    local current_file="${inFiles[$i]}"
    local search_query=""
    
    echo -e "${C3}Processing file $((i+1))/$file_count:${C0} $(basename "$current_file")"
    
    # Check if we should skip existing metadata
    #shellcheck disable=SC2154
    if [[ "$skipExisting" == "true" && -n "${bookTitles[$i]:-}" ]]; then
      echo -e "${C3}>>> Skipping (metadata already exists)${C0}"
      ((skipped_lookups++))
      continue
    fi
    
    # Generate search query from filename
    search_query=$(generateSearchQuery "$current_file")
    echo -e "${C6}>>> Generated search query: '$search_query'${C0}"
    
    if [[ -z "$search_query" ]]; then
      echo -e "${C1}>>> Error: Could not generate search query${C0}"
      continue
    fi
    
    # Allow user to modify search query if interactive
    if [[ "$interactive" == "true" ]]; then
      echo -n "Use this search query? [Y/n/edit]: "
      read -r response
      
      case "$response" in
        [Nn]*)
          echo -e "${C3}>>> Skipping metadata lookup for this file${C0}"
          ((skipped_lookups++))
          continue
          ;;
        [Ee]*)
          echo -n "Enter new search query: "
          read -r search_query
          if [[ -z "$search_query" ]]; then
            echo -e "${C1}>>> Error: Empty search query${C0}"
            continue
          fi
          ;;
        *)
          # Use generated query (default)
          ;;
      esac
    fi
    
    # Perform the search and scraping
    echo -e "${C6}>>> Searching for: '$search_query'${C0}"
    
    if searchAndParseBook "$search_query" "$interactive"; then
      # Check if we got data
      #shellcheck disable=SC2154
      if [[ -n "${bookTitles[$i]:-}" ]]; then
        echo -e "${C2}>>> Successfully found metadata:${C0}"
        #shellcheck disable=SC2154
        echo -e "    ${C2}Title:${C0} ${bookTitles[$i]}"
        #shellcheck disable=SC2154
        echo -e "    ${C2}Author:${C0} ${bookAuthors[$i]}"
        #shellcheck disable=SC2154
        echo -e "    ${C2}Series:${C0} ${bookSeries[$i]} #${bookSeriesNumbers[$i]}"
        #shellcheck disable=SC2154
        echo -e "    ${C2}Duration:${C0} ${bookDurations[$i]}"
        
        ((successful_lookups++))
        
        # Ask for confirmation if interactive
        if [[ "$interactive" == "true" ]]; then
          echo -n "Accept this metadata? [Y/n]: "
          read -r response
          
          if [[ "$response" =~ ^[Nn] ]]; then
            echo -e "${C3}>>> Metadata rejected by user${C0}"
            # Clear the data
            #shellcheck disable=SC2154
            bookTitles[$i]=""
            #shellcheck disable=SC2154
            bookAuthors[$i]=""
            #shellcheck disable=SC2154
            bookSeries[$i]=""
            #shellcheck disable=SC2154
            bookSeriesNumbers[$i]=""
            #shellcheck disable=SC2154
            bookDurations[$i]=""
            ((successful_lookups--))
          fi
        fi
      else
        echo -e "${C3}>>> No metadata found${C0}"
      fi
    else
      echo -e "${C1}>>> Search failed${C0}"
    fi
    
    echo
  done
  
  # Display summary
  echo -e "${C2}>>> Metadata Lookup Summary:${C0}"
  echo -e "${C2}>>>   Total files: $file_count${C0}"
  echo -e "${C2}>>>   Successful lookups: $successful_lookups${C0}"
  echo -e "${C2}>>>   Skipped: $skipped_lookups${C0}"
  echo -e "${C2}>>>   Failed: $((file_count - successful_lookups - skipped_lookups))${C0}"
  echo
  
  # Store metadata for later use
  if [[ $successful_lookups -gt 0 ]]; then
    echo -e "${C2}>>> Metadata will be used for file processing${C0}"
  fi
}

# Display current metadata for a file
showFileMetadata()
{
  local file_index="$1"
  #shellcheck disable=SC2154
  local filename="${inFiles[$file_index]}"
  
  echo -e "${C3}File:${C0} $(basename "$filename")"
  #shellcheck disable=SC2154
  echo -e "${C2}  Title:${C0} ${bookTitles[$file_index]:-Not found}"
  #shellcheck disable=SC2154
  echo -e "${C2}  Author:${C0} ${bookAuthors[$file_index]:-Not found}"
  #shellcheck disable=SC2154
  echo -e "${C2}  Narrator:${C0} ${bookNarrators[$file_index]:-Not found}"
  #shellcheck disable=SC2154
  echo -e "${C2}  Series:${C0} ${bookSeries[$file_index]:-Not found} ${bookSeriesNumbers[$file_index]:+#${bookSeriesNumbers[$file_index]}}"
  #shellcheck disable=SC2154
  echo -e "${C2}  Publisher:${C0} ${bookPublishers[$file_index]:-Not found}"
  #shellcheck disable=SC2154
  echo -e "${C2}  Duration:${C0} ${bookDurations[$file_index]:-Not found}"
  #shellcheck disable=SC2154
  echo -e "${C2}  ASIN:${C0} ${bookASINs[$file_index]:-Not found}"
}

# Main processing workflow
main()
{
  local status=0
  
  logMessage 'INFO' ">>> Starting CCAB Audiobook Converter v${CCAB_VERSION}"
  
  # Load all required modules
  loadModules
  
  # Parse command line arguments
  logMessage 'INFO' ">>> Parsing command line arguments: $*"
  parseArguments "$@"
  
  # Initialize configuration system
  if ! initializeConfiguration; then
    logMessage "ERROR" "Configuration initialization failed"
    exit 1
  fi
  
  # Override CUDA preference if specified on command line
  if [[ "$cuda" != "auto" ]]; then
    export CUDA_PREFERENCE="$cuda"
  fi
  
  # Override debug setting if specified
  if [[ "$debug" == "true" ]]; then
    export DEBUG_DEFAULT="true"
  fi
  
  # Initialize other modules
  if ! initializeSecurity; then
    logMessage "ERROR" "Security module initialization failed"
    exit 1
  fi
  
  if ! initializeUtils; then
    logMessage "ERROR" "Utils module initialization failed"
    exit 1
  fi
  
  if ! initializeFileManagement; then
    logMessage "ERROR" "File management module initialization failed"
    exit 1
  fi
  
  if ! initializeParser; then
    logMessage "ERROR" "Parser module initialization failed"
    exit 1
  fi
  
  if ! initializeWebScraper; then
    logMessage "ERROR" "Web scraper module initialization failed"
    exit 1
  fi
  
  if ! initializeAudio; then
    logMessage "ERROR" "Audio module initialization failed"
    exit 1
  fi
  
  if ! initializeMetadata; then
    logMessage "ERROR" "Metadata module initialization failed"
    exit 1
  fi
  
  if ! initializeOrganization; then
    logMessage "ERROR" "Organization module initialization failed"
    exit 1
  fi
  
  if ! initializeProcessing; then
    logMessage "ERROR" "Processing module initialization failed"
    exit 1
  fi
  
  # Discover files
  logMessage "INFO" ">>> Discovering files in: $targetDir"
  if ! getFiles "$targetDir" "$searchType" "$recurse"; then
    logMessage "ERROR" "No files found for processing"
    exit 1
  fi
  
  # Show file statistics
  getFileStats
  
  # Probe all files (arrays are populated by getFiles and probeFile functions)
  #shellcheck disable=SC2154
  local file_count=${#inFiles[@]}
  logMessage "INFO" "Analyzing $file_count files"
  
  local i
  for ((i=0; i<file_count; i++)); do
    showProgress $((i+1)) "$file_count" "Analyzing files"
    if ! probeFile "${inFiles[$i]}" "$i"; then
      logMessage "WARN" "Could not analyze file: ${inFiles[$i]}"
    fi
  done
  
  echo -e "${C2}>>> File analysis complete${C0}"
  
  # Validate file arrays after probing
  if ! validateFileArrays; then
    logMessage "ERROR" "File array validation failed after probing"
    exit 1
  fi
  
  # Check which files need processing
  local needs_processing=0
  for ((i=0; i<file_count; i++)); do
    if checkFile "${inFiles[$i]}" "$i"; then
      ((needs_processing++))
    fi
  done
  
  if [[ $needs_processing -eq 0 ]]; then
    logMessage "INFO" "No files need processing"
    exit 0
  fi
  
  logMessage "INFO" "$needs_processing files need processing"
  
  # Perform metadata lookup if requested
  if [[ "$lookupMetadata" == "true" ]]; then
    performMetadataLookup "$file_count"
  fi
  
  # Show processing summary
  echo -e "${C2}>>> Processing Summary:${C0}"
  echo -e "${C2}>>>   Files to process: $needs_processing${C0}"
  echo -e "${C2}>>>   Search type: $searchType${C0}"
  echo -e "${C2}>>>   Recursive: $recurse${C0}"
  echo -e "${C2}>>>   Concatenate: $concat${C0}"
  echo -e "${C2}>>>   Move files: $move${C0}"
  echo -e "${C2}>>>   CUDA enabled: ${cuda}${C0}"
  echo -e "${C2}>>>   Debug mode: $debug${C0}"
  echo -e "${C2}>>>   Metadata lookup: $lookupMetadata${C0}"
  echo -e "${C2}>>>   Interactive mode: $interactive${C0}"
  
  # Execute main processing workflow
  echo -e "${C2}>>> Starting audiobook processing workflow${C0}"
  echo
  
  # Set up processing options
  local processing_options=""
  if [[ "$concat" == "true" ]]; then
    processing_options="$processing_options --concat"
  fi
  if [[ "$move" == "true" ]]; then
    processing_options="$processing_options --move"
  fi
  if [[ "$debug" == "true" ]]; then
    processing_options="$processing_options --debug"
  fi
  if [[ "$interactive" == "false" ]]; then
    processing_options="$processing_options --no-interactive"
  fi
  
  # Execute the main processing workflow
  local processing_start_time
  processing_start_time=$(date +%s)
  
  if processAudiobooks "$targetDir" "$processing_options"; then
    local processing_end_time
    processing_end_time=$(date +%s)
    local total_duration=$((processing_end_time - processing_start_time))
    
    logMessage "INFO" "Processing workflow completed successfully in ${total_duration}s"
    status=0
  else
    local processing_end_time
    processing_end_time=$(date +%s)
    local total_duration=$((processing_end_time - processing_start_time))
    
    logMessage "ERROR" "Processing workflow failed after ${total_duration}s"
    
    # Get processing statistics for error reporting
    local stats
    stats=$(getProcessingStats 2>/dev/null || echo "Unknown")
    logMessage "ERROR" "Processing statistics: $stats"
    
    status=1
  fi
  
  # Display final processing summary
  echo
  logMessage "INFO" "=== Final Summary ==="
  if command -v getProcessingStats >/dev/null 2>&1; then
    local final_stats
    final_stats=$(getProcessingStats)
    logMessage "INFO" "$final_stats"
  fi
  
  return $status
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
