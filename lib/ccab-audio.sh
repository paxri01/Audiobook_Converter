#!/bin/bash
#shellcheck disable=SC2004

## ========================================================================================
##       Title: ccab-audio.sh (Audio Processing Module)
##      Author: R. L. Paxton  
##     Version: 4.0
##        Date: 2025-06-30
##     License: Apache 2.0
## Description: Audio processing and encoding module for ccab audiobook converter
##              Handles FFMPEG operations, format conversion, and CUDA acceleration
## ========================================================================================

# Module metadata
CCAB_AUDIO_VERSION="4.0"

# Audio processing constants
MIN_FILE_SIZE=4096000
TARGET_BITRATE=48

# Audio metadata arrays (should be populated by other modules)
declare -ga bookBitrate=()

# Module initialization flag
CCAB_AUDIO_INITIALIZED=false

# Initialize audio processing module
initializeAudio()
{
  if [[ "$CCAB_AUDIO_INITIALIZED" == "true" ]]; then
    return 0
  fi
  
  logMessage "TRACE" "Initializing audio processing module v${CCAB_AUDIO_VERSION}"
  
  # Validate required commands
  if ! validateAudioCommands; then
    logMessage "ERROR" "Audio module initialization failed - missing required commands"
    return 1
  fi
  
  # Initialize CUDA detection if not already done
  if [[ -z "${cuda_available:-}" ]]; then
    detectCudaSupport
  fi
  
  CCAB_AUDIO_INITIALIZED=true
  logMessage "TRACE" "Audio processing module initialized successfully"
  return 0
}

# Validate required audio processing commands
validateAudioCommands()
{
  local required_commands=("ffmpeg" "ffprobe")
  local missing_commands=()
  
  for cmd in "${required_commands[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing_commands+=("$cmd")
    fi
  done
  
  if [[ ${#missing_commands[@]} -gt 0 ]]; then
    logMessage "ERROR" "Missing required audio commands: ${missing_commands[*]}"
    return 1
  fi
  
  # Verify FFmpeg has MP3 encoding support
  if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "libmp3lame"; then
    logMessage "ERROR" "FFmpeg is missing MP3 encoding support (libmp3lame)"
    return 1
  fi
  
  return 0
}

# Detect CUDA support availability
detectCudaSupport()
{
  logMessage "TRACE" "Detecting CUDA support"
  
  # Check if CUDA preference is explicitly set
  if [[ "${CUDA_PREFERENCE:-auto}" == "true" ]]; then
    logMessage "INFO" "CUDA acceleration forced enabled"
    cuda_available=true
    return 0
  elif [[ "${CUDA_PREFERENCE:-auto}" == "false" ]]; then
    logMessage "INFO" "CUDA acceleration disabled by configuration"
    cuda_available=false
    return 1
  fi
  
  # Auto-detect CUDA support
  if command -v nvidia-smi >/dev/null 2>&1; then
    if nvidia-smi >/dev/null 2>&1; then
      # Check if FFmpeg has CUDA support
      if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "nvenc\|cuda"; then
        cuda_available=true
        logMessage "INFO" "CUDA acceleration detected and available"
        return 0
      else
        logMessage "WARN" "NVIDIA GPU detected but FFmpeg lacks CUDA support"
      fi
    else
      logMessage "DEBUG" "nvidia-smi available but no GPU detected"
    fi
  fi
  
  cuda_available=false
  logMessage "INFO" "CUDA acceleration not available, using CPU encoding"
  return 1
}

# Main audio encoding function
reEncode()
{
  local inFile="$1"
  local index="$2"
  local outFile="$3"
  local checkFile=0
  local outSize tempOut
  
  if [[ -z "$inFile" || -z "$index" || -z "$outFile" ]]; then
    logMessage "ERROR" "reEncode: Missing required parameters"
    return 1
  fi
  
  if [[ ! -f "$inFile" ]]; then
    logMessage "ERROR" "reEncode: Input file does not exist: $inFile"
    return 1
  fi
  
  logMessage "TRACE" "Starting reEncode for file: $(basename "$inFile")"
  
  # Get target bitrate from file metadata or use default
  local target_bitrate="${bookBitrate[$index]:-$TARGET_BITRATE}"
 
  logMessage "INFO" "Encoding $(basename "$inFile") → $(basename "$outFile") at ${target_bitrate}k bitrate"
  
  while [[ $checkFile -lt 1 ]]; do
    # Primary encoding attempt
    if [[ "${cuda_available:-false}" == "true" ]]; then
      if ! encodeWithCuda "$inFile" "$outFile" "$target_bitrate"; then
        logMessage "WARN" "CUDA encoding failed, falling back to CPU"
        cuda_available=false
        continue
      fi
    else
      if ! encodeWithCpu "$inFile" "$outFile" "$target_bitrate"; then
        logMessage "ERROR" "CPU encoding failed"
        return 1
      fi
    fi
    
    # Validate the output file
    if ! validateEncodedFile "$outFile"; then
      validation_result=$?
      case $validation_result in
        1)
          logMessage "ERROR" "Output file was not created: $outFile"
          return 1
          ;;
        2)
          # File size too small - attempt fix
          tempOut="${outFile%.*}_temp.mp3"
          outSize=$(stat -c%s "$outFile" 2>/dev/null || echo "0")
          logMessage "WARN" "File size ${outSize} bytes below threshold - applying fix"
          
          if fixSmallFileSize "$inFile" "$outFile" "$tempOut" "$target_bitrate"; then
            # Re-validate after fix
            if validateEncodedFile "$outFile"; then
              checkFile=1
            else
              logMessage "ERROR" "File still invalid after size fix"
              return 1
            fi
          else
            logMessage "ERROR" "Failed to fix small file size"
            return 1
          fi
          ;;
        3|4)
          logMessage "ERROR" "Output file is corrupted or invalid"
          return 1
          ;;
        *)
          checkFile=1
          ;;
      esac
    else
      checkFile=1
    fi
  done
  
  # Log successful encoding with final file size
  local final_size
  final_size=$(stat -c%s "$outFile" 2>/dev/null || echo "0")
  logMessage "INFO" "Successfully encoded: $(basename "$outFile") (${final_size} bytes)"
  return 0
}

# CUDA-accelerated encoding
encodeWithCuda()
{
  local inFile="$1"
  local outFile="$2"
  local bitrate="$3"
  
  logMessage "TRACE" "Starting CUDA-accelerated encoding"
  logMessage "INFO" "Using CUDA-accelerated encoding at ${bitrate}k bitrate"
 
  # For audiobooks with embedded images/video, disable CUDA for video streams
  # and only use CUDA for audio processing if possible
  if ffmpeg -hide_banner -loglevel error -stats \
    -hwaccel cuda -hwaccel_output_format cuda \
    -i "$inFile" \
    -map 0:a:0 \
    -c:a libmp3lame -b:a "${bitrate}k" \
    -ar 44100 -ac 2 \
    -vn \
    "$outFile" 2>&1; then
    logMessage "DEBUG" "CUDA-accelerated encoding completed"
    return 0
  else
    # Try fallback without hardware acceleration output format
    logMessage "DEBUG" "CUDA hwaccel_output_format failed, trying basic CUDA"
    if ffmpeg -hide_banner -loglevel error -stats \
      -hwaccel cuda \
      -i "$inFile" \
      -map 0:a:0 \
      -c:a libmp3lame -b:a "${bitrate}k" \
      -ar 44100 -ac 2 \
      -vn \
      "$outFile" 2>&1; then
      logMessage "DEBUG" "CUDA basic acceleration completed"
      return 0
    else
      logMessage "WARN" "CUDA encoding failed - likely due to embedded images or unsupported format"
      return 1
    fi
  fi
}

# CPU-based encoding
encodeWithCpu()
{
  local inFile="$1"
  local outFile="$2"
  local bitrate="${3:-$TARGET_BITRATE}"
  
  logMessage "TRACE" "Starting CPU-based encoding"
  logMessage "INFO" "Using CPU-based encoding at ${bitrate}k bitrate"
  
  # Use FFmpeg for all audio format support, explicitly extract only audio stream
  if ffmpeg -hide_banner -loglevel error -stats \
    -i "$inFile" \
    -map 0:a:0 \
    -c:a libmp3lame -b:a "${bitrate}k" \
    -ar 44100 -ac 2 \
    -vn \
    "$outFile" 2>&1; then
    logMessage "DEBUG" "CPU encoding completed"
    return 0
  else
    logMessage "ERROR" "CPU encoding failed"
    return 1
  fi
}

# Fix small file size issues through re-encoding 
fixSmallFileSize()
{
  local inFile="$1"
  local outFile="$2"
  local tempOut="$3"
  local bitrate="${4:-$TARGET_BITRATE}"
  
  logMessage "TRACE" "Attempting to fix small file size"
  logMessage "INFO" "Re-encoding due to size error"
  
  # Remove the problematic output file
  rm -f "$outFile"
  
  if [[ "${cuda_available:-false}" == "true" ]]; then
    # Try CUDA fallback encoding
    if ffmpeg -hide_banner -loglevel error -stats \
      -hwaccel cuda \
      -i "$inFile" \
      -map 0:a:0 \
      -c:a libmp3lame -b:a "${bitrate}k" \
      -ar 44100 -ac 2 \
      -vn \
      "$tempOut" 2>&1; then
      mv "$tempOut" "$outFile"
      logMessage "DEBUG" "CUDA fallback encoding successful"
      return 0
    else
      logMessage "WARN" "CUDA fallback failed, using CPU"
    fi
  fi
  
  # CPU fallback
  if ffmpeg -hide_banner -loglevel error -stats \
    -i "$inFile" \
    -map 0:a:0 \
    -c:a libmp3lame -b:a "${bitrate}k" \
    -ar 44100 -ac 2 \
    -vn \
    "$tempOut" 2>&1; then
    mv "$tempOut" "$outFile"
    logMessage "DEBUG" "CPU fallback encoding successful"
    return 0
  else
    logMessage "ERROR" "Re-encoding failed"
    # Clean up temp file if it exists
    rm -f "$tempOut"
    return 1
  fi
}

# Get audio file information using ffprobe
getAudioInfo()
{
  local inFile="$1"
  local info_type="${2:-all}"
  
  if [[ ! -f "$inFile" ]]; then
    logMessage "ERROR" "getAudioInfo: File does not exist: $inFile"
    return 1
  fi
  
  case "$info_type" in
    "duration")
      ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$inFile" 2>/dev/null
      ;;
    "bitrate")
      ffprobe -v quiet -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 "$inFile" 2>/dev/null
      ;;
    "sample_rate")
      ffprobe -v quiet -show_entries stream=sample_rate -select_streams a:0 -of default=noprint_wrappers=1:nokey=1 "$inFile" 2>/dev/null
      ;;
    "channels")
      ffprobe -v quiet -show_entries stream=channels -select_streams a:0 -of default=noprint_wrappers=1:nokey=1 "$inFile" 2>/dev/null
      ;;
    "codec")
      ffprobe -v quiet -show_entries stream=codec_name -select_streams a:0 -of default=noprint_wrappers=1:nokey=1 "$inFile" 2>/dev/null
      ;;
    "all"|*)
      ffprobe -v quiet -print_format json -show_format -show_streams -select_streams a:0 "$inFile" 2>/dev/null
      ;;
  esac
}

# Concatenate multiple audio files into single output
concatenateAudioFiles()
{
  local output_file="$1"
  shift
  local input_files=("$@")
  
  if [[ ${#input_files[@]} -eq 0 ]]; then
    logMessage "ERROR" "concatenateAudioFiles: No input files provided"
    return 1
  fi
  
  if [[ ${#input_files[@]} -eq 1 ]]; then
    logMessage "INFO" "Single file, copying instead of concatenating"
    cp "${input_files[0]}" "$output_file"
    return $?
  fi
  
  logMessage "INFO" "Concatenating ${#input_files[@]} files into $(basename "$output_file")"
  
  # Create temporary file list for ffmpeg concat
  local concat_list
  concat_list=$(mktemp) || {
    logMessage "ERROR" "Failed to create temporary concat list"
    return 1
  }
  
  # Build file list for ffmpeg
  for file in "${input_files[@]}"; do
    if [[ -f "$file" ]]; then
      local real_path
      if real_path=$(realpath "$file" 2>/dev/null); then
        echo "file '$real_path'" >> "$concat_list"
      else
        logMessage "WARN" "Could not resolve path for: $file"
      fi
    else
      logMessage "WARN" "Skipping non-existent file: $file"
    fi
  done
  
  # Perform concatenation
  local result=0
  logMessage "INFO" "Starting concatenation process"
  if ffmpeg -hide_banner -loglevel error -stats -f concat -safe 0 \
    -i "$concat_list" \
    -c:a libmp3lame -b:a "${TARGET_BITRATE}k" \
    -ar 44100 -ac 2 \
    "$output_file" 2>&1; then
    logMessage "INFO" "Successfully concatenated files"
  else
    logMessage "ERROR" "Failed to concatenate files"
    result=1
  fi
  
  # Cleanup
  rm -f "$concat_list"
  return $result
}

# Normalize audio levels
normalizeAudio()
{
  local inFile="$1"
  local outFile="$2"
  local target_lufs="${3:--23}"
  
  if [[ ! -f "$inFile" ]]; then
    logMessage "ERROR" "normalizeAudio: Input file does not exist: $inFile"
    return 1
  fi
  
  logMessage "INFO" "Normalizing audio to ${target_lufs} LUFS"
  
  if ffmpeg -hide_banner -loglevel error -stats \
    -i "$inFile" \
    -af "loudnorm=I=${target_lufs}:TP=-1.5:LRA=11" \
    -c:a libmp3lame -b:a "${TARGET_BITRATE}k" \
    "$outFile" 2>&1; then
    logMessage "INFO" "Audio normalization completed"
    return 0
  else
    logMessage "ERROR" "Audio normalization failed"
    return 1
  fi
}

# Convert between audio formats
convertAudioFormat()
{
  local inFile="$1"
  local outFile="$2"
  local format="${3:-mp3}"
  local bitrate="${4:-$TARGET_BITRATE}"
  
  if [[ ! -f "$inFile" ]]; then
    logMessage "ERROR" "convertAudioFormat: Input file does not exist: $inFile"
    return 1
  fi
  
  logMessage "INFO" "Converting $(basename "$inFile") to $format format"
  
  case "$format" in
    "mp3")
      if ffmpeg -hide_banner -loglevel error -stats \
        -i "$inFile" \
        -c:a libmp3lame -b:a "${bitrate}k" \
        -ar 44100 -ac 2 \
        "$outFile" 2>&1; then
        logMessage "INFO" "Format conversion to MP3 completed"
        return 0
      else
        logMessage "ERROR" "MP3 format conversion failed"
        return 1
      fi
      ;;
    "flac")
      if ffmpeg -hide_banner -loglevel error -stats \
        -i "$inFile" \
        -c:a flac \
        -ar 44100 -ac 2 \
        "$outFile" 2>&1; then
        logMessage "INFO" "Format conversion to FLAC completed"
        return 0
      else
        logMessage "ERROR" "FLAC format conversion failed"
        return 1
      fi
      ;;
    "m4a")
      if ffmpeg -hide_banner -loglevel error -stats \
        -i "$inFile" \
        -c:a aac -b:a "${bitrate}k" \
        -ar 44100 -ac 2 \
        "$outFile" 2>&1; then
        logMessage "INFO" "Format conversion to M4A completed"
        return 0
      else
        logMessage "ERROR" "M4A format conversion failed"
        return 1
      fi
      ;;
    *)
      logMessage "ERROR" "Unsupported audio format: $format"
      return 1
      ;;
  esac
}

# Validate that an encoded audio file is valid
validateEncodedFile()
{
  local file="$1"
  local expected_min_size="${2:-$MIN_FILE_SIZE}"
  
  if [[ ! -f "$file" ]]; then
    logMessage "ERROR" "validateEncodedFile: File does not exist: $file"
    return 1
  fi
  
  # Check file size
  local file_size
  file_size=$(stat -c%s "$file" 2>/dev/null || echo "0")
  if [[ $file_size -lt $expected_min_size ]]; then
    logMessage "WARN" "Encoded file size ${file_size} bytes is below expected minimum ${expected_min_size}"
    return 2
  fi
  
  # Check if file is readable by ffprobe (validates audio format)
  if ! ffprobe -v quiet -print_format json -show_format "$file" >/dev/null 2>&1; then
    logMessage "ERROR" "Encoded file appears to be corrupted or invalid: $file"
    return 3
  fi
  
  # Get duration to verify it's not empty
  local duration
  duration=$(ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
  if [[ -z "$duration" || $(echo "$duration < 1" | bc -l 2>/dev/null || echo "1") == "1" ]]; then
    logMessage "WARN" "Encoded file has very short or no duration: $file"
    return 4
  fi
  
  logMessage "DEBUG" "Encoded file validation passed: $(basename "$file") (${file_size} bytes, ${duration}s)"
  return 0
}

# Export audio module functions for external use
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  # Module is being sourced, export functions
  export -f initializeAudio
  export -f validateAudioCommands
  export -f detectCudaSupport
  export -f reEncode
  export -f encodeWithCuda
  export -f encodeWithCpu
  export -f fixSmallFileSize
  export -f getAudioInfo
  export -f concatenateAudioFiles
  export -f normalizeAudio
  export -f convertAudioFormat
  export -f validateEncodedFile
fi
