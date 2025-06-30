#!/bin/bash
#shellcheck disable=SC2004

## ========================================================================================
##       Title: ccab-processing.sh (Main Processing Workflow Module)
##      Author: R. L. Paxton
##     Version: 4.0
##        Date: 2025-06-30
##     License: Apache 2.0
## Description: Main processing workflow orchestration module for ccab audiobook converter
##              Coordinates all processing phases: discovery, metadata, audio, organization
## ========================================================================================

# Module metadata
CCAB_PROCESSING_VERSION="4.0"

# Processing workflow constants (for future phase tracking)
#shellcheck disable=SC2034
PROCESSING_PHASE_DISCOVERY=1
#shellcheck disable=SC2034
PROCESSING_PHASE_METADATA=2
#shellcheck disable=SC2034
PROCESSING_PHASE_AUDIO=3
#shellcheck disable=SC2034
PROCESSING_PHASE_ORGANIZATION=4
#shellcheck disable=SC2034
PROCESSING_PHASE_CLEANUP=5

# Module initialization flag
CCAB_PROCESSING_INITIALIZED=false

# Initialize processing workflow module
initializeProcessing()
{
  if [[ "$CCAB_PROCESSING_INITIALIZED" == "true" ]]; then
    return 0
  fi
  
  logMessage "TRACE" "Initializing processing workflow module v${CCAB_PROCESSING_VERSION}"
  
  # Initialize all required modules
  if ! initializeAudio; then
    logMessage "ERROR" "Failed to initialize audio module"
    return 1
  fi
  
  if ! initializeMetadata; then
    logMessage "ERROR" "Failed to initialize metadata module"
    return 1
  fi
  
  if ! initializeOrganization; then
    logMessage "ERROR" "Failed to initialize organization module"
    return 1
  fi
  
  # Initialize processing state arrays
  initializeProcessingState
  
  CCAB_PROCESSING_INITIALIZED=true
  logMessage "TRACE" "Processing workflow module initialized successfully"
  return 0
}

# Initialize processing state arrays
initializeProcessingState()
{
  logMessage "TRACE" "Initializing processing state arrays"
  
  # Clear any existing arrays
  unset processingStatus processingErrors processingStartTime
  unset needsProcessing needsMetadata needsEncoding needsOrganization
  
  # Declare processing state arrays
  declare -ag processingStatus processingErrors processingStartTime
  declare -ag needsProcessing needsMetadata needsEncoding needsOrganization
  
  # Initialize processing statistics
  totalFiles=0
  processedFiles=0
  successfulFiles=0
  failedFiles=0
  skippedFiles=0
}

# Main processing workflow orchestrator
processAudiobooks()
{
  local target_dir="$1"
  local options="$2"
  
  if [[ -z "$target_dir" ]]; then
    logMessage "ERROR" "processAudiobooks: Target directory required"
    return 1
  fi
  
  logMessage "INFO" "Starting audiobook processing workflow"
  logMessage "INFO" "Target directory: $target_dir"
  
  local start_time
  start_time=$(date +%s)
  
  # Phase 1: File Discovery
  logMessage "INFO" "Phase 1: File Discovery"
  if ! processDiscoveryPhase "$target_dir" "$options"; then
    logMessage "ERROR" "Discovery phase failed"
    return 1
  fi
  
  # Check if any files were found
  if [[ $totalFiles -eq 0 ]]; then
    logMessage "INFO" "No files found for processing"
    return 0
  fi
  
  # Phase 2: Metadata Extraction and Web Scraping
  logMessage "INFO" "Phase 2: Metadata Processing"
  if ! processMetadataPhase "$options"; then
    logMessage "ERROR" "Metadata phase failed"
    return 1
  fi
  
  # Phase 3: Audio Processing
  logMessage "INFO" "Phase 3: Audio Processing"
  if ! processAudioPhase "$options"; then
    logMessage "ERROR" "Audio processing phase failed"
    return 1
  fi
  
  # Phase 4: File Organization
  logMessage "INFO" "Phase 4: File Organization"
  if ! processOrganizationPhase "$options"; then
    logMessage "ERROR" "Organization phase failed"
    return 1
  fi
  
  # Phase 5: Cleanup and Summary
  logMessage "INFO" "Phase 5: Cleanup and Summary"
  processCleanupPhase
  
  # Display final summary
  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))
  
  displayProcessingSummary "$duration"
  
  # Return success if at least one file processed successfully
  if [[ $successfulFiles -gt 0 ]]; then
    return 0
  else
    return 1
  fi
}

# Phase 1: File Discovery and Initial Setup
processDiscoveryPhase()
{
  local target_dir="$1"
  local options="$2"
  
  logMessage "TRACE" "Starting discovery phase"
  
  # Discover files using existing file management module
  if ! getFiles "$target_dir" "${searchType:-all}" "${recurse:-false}"; then
    logMessage "ERROR" "File discovery failed"
    return 1
  fi
  
  # Update total file count
  #shellcheck disable=SC2154
  totalFiles=${#inFiles[@]}
  logMessage "INFO" "Discovered $totalFiles files for processing"
  
  if [[ $totalFiles -eq 0 ]]; then
    return 0
  fi
  
  # Show file statistics
  getFileStats
  
  # Initialize processing state for each file
  for ((i=0; i<totalFiles; i++)); do
    processingStatus[$i]="pending"
    processingErrors[$i]=""
    processingStartTime[$i]=""
    needsProcessing[$i]="false"
    needsMetadata[$i]="false"
    needsEncoding[$i]="false"
    needsOrganization[$i]="false"
  done
  
  # Analyze files to determine processing requirements
  logMessage "INFO" "Analyzing files for processing requirements"
  for ((i=0; i<totalFiles; i++)); do
    showProgress $((i+1)) "$totalFiles" "Analyzing files"
    
    if analyzeFile "${inFiles[$i]}" "$i"; then
      if [[ "${needsProcessing[$i]}" == "true" ]]; then
        ((processedFiles++))
      else
        ((skippedFiles++))
      fi
    else
      logMessage "WARN" "Could not analyze file: ${inFiles[$i]}"
      processingErrors[$i]="Analysis failed"
    fi
  done
  
  logMessage "INFO" "Analysis complete: $processedFiles files need processing, $skippedFiles files skipped"
  return 0
}

# Phase 2: Metadata Extraction and Web Scraping
processMetadataPhase()
{
  local options="$1"
  
  logMessage "TRACE" "Starting metadata phase"
  
  local metadata_processed=0
  
  # First pass: Extract existing metadata from files
  logMessage "INFO" "Extracting existing metadata from files"
  for ((i=0; i<totalFiles; i++)); do
    if [[ "${needsProcessing[$i]}" == "true" ]]; then
      showProgress $((metadata_processed+1)) "$processedFiles" "Extracting metadata"
      
      processingStatus[$i]="metadata"
      #shellcheck disable=SC2034
      processingStartTime[$i]=$(date +%s)
      
      if extractMetadata "${inFiles[$i]}" "$i"; then
        logMessage "DEBUG" "Metadata extracted for: $(basename "${inFiles[$i]}")"
      else
        logMessage "WARN" "Failed to extract metadata from: $(basename "${inFiles[$i]}")"
        needsMetadata[$i]="true"
      fi
      
      ((metadata_processed++))
    fi
  done
  
  # Second pass: Perform web scraping for missing metadata (if enabled)
  if [[ "${lookupMetadata:-false}" == "true" ]]; then
    logMessage "INFO" "Performing web-based metadata lookup"
    performMetadataLookup "$processedFiles"
  fi
  
  # Third pass: Prompt for any remaining missing metadata
  if [[ "${interactive:-true}" == "true" ]]; then
    logMessage "INFO" "Prompting for missing metadata"
    for ((i=0; i<totalFiles; i++)); do
      if [[ "${needsProcessing[$i]}" == "true" && "${needsMetadata[$i]}" == "true" ]]; then
        if ! promptForMetadata "$i" "${inFiles[$i]}"; then
          logMessage "WARN" "Failed to get complete metadata for: $(basename "${inFiles[$i]}")"
          processingErrors[$i]="Incomplete metadata"
        fi
      fi
    done
  fi
  
  # Validate metadata completeness
  logMessage "INFO" "Validating metadata completeness"
  local metadata_valid=0
  for ((i=0; i<totalFiles; i++)); do
    if [[ "${needsProcessing[$i]}" == "true" ]]; then
      if validateMetadata "$i" "${inFiles[$i]}"; then
        ((metadata_valid++))
      else
        logMessage "WARN" "Metadata validation failed for: $(basename "${inFiles[$i]}")"
        processingErrors[$i]="Invalid metadata"
        needsProcessing[$i]="false"
        ((failedFiles++))
        ((processedFiles--))
      fi
    fi
  done
  
  logMessage "INFO" "Metadata validation complete: $metadata_valid files have valid metadata"
  return 0
}

# Phase 3: Audio Processing (Encoding and Tagging)
processAudioPhase()
{
  local options="$1"
  
  logMessage "TRACE" "Starting audio processing phase"
  
  local audio_processed=0
  
  # Process files for audio encoding and tagging
  for ((i=0; i<totalFiles; i++)); do
    if [[ "${needsProcessing[$i]}" == "true" ]]; then
      showProgress $((audio_processed+1)) "$processedFiles" "Processing audio"
      
      processingStatus[$i]="audio"
      local file_start_time
      file_start_time=$(date +%s)
      
      local success=true
      local encoded_file=""
      
      # Check if file needs encoding
      if checkFile "${inFiles[$i]}" "$i"; then
        needsEncoding[$i]="true"
        
        # Generate output filename
        local base_name
        base_name=$(basename "${inFiles[$i]%.*}")
        encoded_file="${workDir:-/tmp}/${base_name}.mp3"
        
        # Perform audio encoding
        logMessage "INFO" "Encoding: $(basename "${inFiles[$i]}")"
        if reEncode "${inFiles[$i]}" "$i" "$encoded_file"; then
          encodedFiles[$i]="$encoded_file"
          logMessage "DEBUG" "Successfully encoded: $(basename "$encoded_file")"
        else
          logMessage "ERROR" "Failed to encode: $(basename "${inFiles[$i]}")"
          processingErrors[$i]="Encoding failed"
          success=false
        fi
      else
        # File doesn't need encoding, use original
        encodedFiles[$i]="${inFiles[$i]}"
        logMessage "DEBUG" "File doesn't need encoding: $(basename "${inFiles[$i]}")"
      fi
      
      # Apply ID3 tags if encoding was successful
      if [[ "$success" == "true" && -n "${encodedFiles[$i]}" ]]; then
        logMessage "INFO" "Applying ID3 tags to: $(basename "${encodedFiles[$i]}")"
        if ! tagIt "${encodedFiles[$i]}" "$i"; then
          logMessage "WARN" "Failed to apply ID3 tags to: $(basename "${encodedFiles[$i]}")"
          processingErrors[$i]="Tagging failed"
        fi
      fi
      
      # Update processing status
      if [[ "$success" == "true" ]]; then
        needsOrganization[$i]="true"
        local file_end_time
        file_end_time=$(date +%s)
        local file_duration=$((file_end_time - file_start_time))
        logMessage "DEBUG" "Audio processing completed for $(basename "${inFiles[$i]}") in ${file_duration}s"
      else
        needsProcessing[$i]="false"
        ((failedFiles++))
        ((processedFiles--))
      fi
      
      ((audio_processed++))
    fi
  done
  
  logMessage "INFO" "Audio processing complete: $audio_processed files processed"
  return 0
}

# Phase 4: File Organization and Moving
processOrganizationPhase()
{
  local options="$1"
  
  logMessage "TRACE" "Starting organization phase"
  
  # Check if file moving is enabled
  if [[ "${move:-false}" != "true" ]]; then
    logMessage "INFO" "File moving disabled - skipping organization phase"
    return 0
  fi
  
  local organized_files=0
  
  # Process files for organization
  for ((i=0; i<totalFiles; i++)); do
    if [[ "${needsOrganization[$i]}" == "true" ]]; then
      showProgress $((organized_files+1)) "$processedFiles" "Organizing files"
      
      processingStatus[$i]="organization"
      
      # Classify book genre if not already done
      if [[ -z "${bookType:-}" ]]; then
        if ! classifyIt "${inFiles[$i]}" "$i"; then
          logMessage "WARN" "Failed to classify book: $(basename "${inFiles[$i]}")"
          processingErrors[$i]="Classification failed"
          continue
        fi
      fi
      
      # Move files to organized structure
      logMessage "INFO" "Organizing: $(basename "${encodedFiles[$i]}")"
      if moveIt "${encodedFiles[$i]}" "$i" "true"; then
        ((successfulFiles++))
        processingStatus[$i]="completed"
        logMessage "DEBUG" "Successfully organized: $(basename "${encodedFiles[$i]}")"
      else
        logMessage "ERROR" "Failed to organize: $(basename "${encodedFiles[$i]}")"
        processingErrors[$i]="Organization failed"
        ((failedFiles++))
      fi
      
      ((organized_files++))
    fi
  done
  
  logMessage "INFO" "Organization complete: $organized_files files organized"
  return 0
}

# Phase 5: Cleanup and Finalization
processCleanupPhase()
{
  logMessage "TRACE" "Starting cleanup phase"
  
  # Clean up temporary files if requested
  if [[ "${clean:-true}" == "true" ]]; then
    logMessage "INFO" "Cleaning up temporary files"
    if [[ -n "${workDir:-}" && -d "$workDir" ]]; then
      local temp_file_count
      temp_file_count=$(find "$workDir" -type f | wc -l)
      if [[ $temp_file_count -gt 0 ]]; then
        logMessage "DEBUG" "Removing $temp_file_count temporary files from $workDir"
        rm -rf "${workDir:?}"/*
      fi
    fi
  else
    logMessage "INFO" "Temporary files preserved in: ${workDir:-/tmp}"
  fi
  
  # Update processing status for remaining files
  for ((i=0; i<totalFiles; i++)); do
    if [[ "${processingStatus[$i]}" != "completed" && "${needsProcessing[$i]}" == "true" ]]; then
      if [[ -z "${processingErrors[$i]}" ]]; then
        processingErrors[$i]="Processing incomplete"
      fi
      ((failedFiles++))
    fi
  done
  
  logMessage "TRACE" "Cleanup phase completed"
}

# Analyze individual file to determine processing requirements
analyzeFile()
{
  local file="$1"
  local index="$2"
  
  if [[ ! -f "$file" ]]; then
    logMessage "ERROR" "analyzeFile: File does not exist: $file"
    return 1
  fi
  
  # Extract basic metadata to populate arrays
  if ! probeFile "$file" "$index"; then
    logMessage "WARN" "Failed to probe file: $(basename "$file")"
    return 1
  fi
  
  # Determine if file needs processing
  local needs_processing=false
  
  # Check if file needs encoding (based on format, bitrate, etc.)
  if checkFile "$file" "$index"; then
    needs_processing=true
    #shellcheck disable=SC2034
    needsEncoding[$index]="true"
  fi
  
  # Check if metadata is incomplete
  #shellcheck disable=SC2154
  if [[ -z "${bookTitles[$index]:-}" || -z "${bookAuthors[$index]:-}" ]]; then
    needs_processing=true
    #shellcheck disable=SC2034
    needsMetadata[$index]="true"
  fi
  
  # Always need organization if moving is enabled
  if [[ "${move:-false}" == "true" ]]; then
    needs_processing=true
    #shellcheck disable=SC2034
    needsOrganization[$index]="true"
  fi
  
  needsProcessing[$index]="$needs_processing"
  
  return 0
}

# Display comprehensive processing summary
displayProcessingSummary()
{
  local duration="$1"
  
  echo
  logMessage "INFO" "=== Processing Summary ==="
  logMessage "INFO" "Total files discovered: $totalFiles"
  logMessage "INFO" "Files processed: $processedFiles"
  logMessage "INFO" "Successful: $successfulFiles"
  logMessage "INFO" "Failed: $failedFiles"
  logMessage "INFO" "Skipped: $skippedFiles"
  logMessage "INFO" "Total processing time: ${duration}s"
  
  # Display failed files with errors
  if [[ $failedFiles -gt 0 ]]; then
    echo
    logMessage "WARN" "Failed Files:"
    for ((i=0; i<totalFiles; i++)); do
      if [[ -n "${processingErrors[$i]}" ]]; then
        logMessage "WARN" "  $(basename "${inFiles[$i]}"): ${processingErrors[$i]}"
      fi
    done
  fi
  
  # Display successful files
  if [[ $successfulFiles -gt 0 ]]; then
    echo
    logMessage "INFO" "Successfully Processed Files:"
    for ((i=0; i<totalFiles; i++)); do
      if [[ "${processingStatus[$i]}" == "completed" ]]; then
        logMessage "INFO" "  $(basename "${inFiles[$i]}") -> ${outDirs[$i]:-Unknown}"
      fi
    done
  fi
  
  echo
}

# Get processing statistics
getProcessingStats()
{
  echo "Total: $totalFiles, Processed: $processedFiles, Success: $successfulFiles, Failed: $failedFiles, Skipped: $skippedFiles"
}

# Check if processing is complete
isProcessingComplete()
{
  [[ $((successfulFiles + failedFiles + skippedFiles)) -eq $totalFiles ]]
}

# Export processing module functions for external use
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  # Module is being sourced, export functions
  export -f initializeProcessing
  export -f initializeProcessingState
  export -f processAudiobooks
  export -f processDiscoveryPhase
  export -f processMetadataPhase
  export -f processAudioPhase
  export -f processOrganizationPhase
  export -f processCleanupPhase
  export -f analyzeFile
  export -f displayProcessingSummary
  export -f getProcessingStats
  export -f isProcessingComplete
fi