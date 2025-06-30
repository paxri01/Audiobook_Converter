#!/bin/bash
#shellcheck disable=SC2004

## ========================================================================================
##       Title: ccab-metadata.sh (Metadata Management Module)
##      Author: R. L. Paxton
##     Version: 4.0
##        Date: 2025-06-30
##     License: Apache 2.0
## Description: ID3 tag and metadata management module for ccab audiobook converter
##              Handles metadata extraction, validation, ID3 tag operations, and cover art
## ========================================================================================

# Module metadata
CCAB_METADATA_VERSION="4.0"

# Metadata processing constants
DEFAULT_GENRE="audiobook"
DEFAULT_TRACK_NUMBER=1
DEFAULT_ENCODER="ccab-converter"
#ID3_VERSION="v2.4"

# Module initialization flag
CCAB_METADATA_INITIALIZED=false

# Initialize metadata processing module
initializeMetadata()
{
  if [[ "$CCAB_METADATA_INITIALIZED" == "true" ]]; then
    return 0
  fi
  
  logMessage "TRACE" "Initializing metadata processing module v${CCAB_METADATA_VERSION}"
  
  # Validate required commands
  if ! validateMetadataCommands; then
    logMessage "ERROR" "Metadata module initialization failed - missing required commands"
    return 1
  fi
  
  CCAB_METADATA_INITIALIZED=true
  logMessage "TRACE" "Metadata processing module initialized successfully"
  return 0
}

# Validate required metadata processing commands
validateMetadataCommands()
{
  local required_commands=("mid3v2" "ffprobe")
  local optional_commands=("fancy_audio")
  local missing_commands=()
  
  for cmd in "${required_commands[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing_commands+=("$cmd")
    fi
  done
  
  if [[ ${#missing_commands[@]} -gt 0 ]]; then
    logMessage "ERROR" "Missing required metadata commands: ${missing_commands[*]}"
    return 1
  fi
  
  # Check optional commands
  for cmd in "${optional_commands[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      logMessage "WARN" "Optional command not available: $cmd (cover art embedding may be limited)"
    fi
  done
  
  return 0
}

# Extract metadata from audio file using ffprobe
extractMetadata()
{
  local inFile="$1"
  local index="$2"
  
  if [[ ! -f "$inFile" ]]; then
    logMessage "ERROR" "extractMetadata: Input file does not exist: $inFile"
    return 1
  fi
  
  if [[ -z "$index" ]]; then
    logMessage "ERROR" "extractMetadata: Index parameter required"
    return 1
  fi
  
  logMessage "TRACE" "Extracting metadata from: $(basename "$inFile")"
  
  # Create temporary probe file
  local probeFile
  probeFile=$(mktemp) || {
    logMessage "ERROR" "Failed to create temporary probe file"
    return 1
  }
  
  # Use ffprobe to extract metadata
  if ! ffprobe -hide_banner "$inFile" >"$probeFile" 2>&1; then
    logMessage "ERROR" "Failed to probe file: $inFile"
    rm -f "$probeFile"
    return 1
  fi
  
  # Extract metadata fields
  local _album _artist _author _album_artist _title _date _genre _publisher
  
  _album=$(sed -rn 's/\ +album\ *:\ (.[^:]*).*/\1/p' "$probeFile" | head -n1)
  _artist=$(sed -rn 's/\ +artist\ *:\ (.*)$/\1/p' "$probeFile" | head -n1)
  _author=$(sed -rn 's/\ +author\ *:\ (.*)$/\1/p' "$probeFile" | head -n1)
  _album_artist=$(sed -rn 's/\ +album_artist\ *:\ (.*)$/\1/p' "$probeFile" | head -n1)
  _title=$(grep -m 1 'title' "$probeFile" | sed -rn 's/.* : (.[^:]*).*/\1/p')
  _date=$(sed -rn 's/\ +date\ *:\ (.*)$/\1/p' "$probeFile" | head -n1)
  _genre=$(sed -rn 's/\ +genre\ *:\ (.*)$/\1/p' "$probeFile" | head -n1)
  _publisher=$(sed -rn 's/\ +publisher\ *:\ (.*)$/\1/p' "$probeFile" | head -n1)
  
  # Clean up probe file
  rm -f "$probeFile"
  
  # Process extracted metadata
  local _bookTitle="${_title:-$_album}"
  _bookTitle=${_bookTitle//[^a-zA-Z0-9 ]/}
  _bookTitle=$(sed -r 's/^[0-9]+ //' <<< "$_bookTitle")
  
  local _bookAuthor="${_author:-$_artist}"
  _bookAuthor="${_bookAuthor:-$_album_artist}"
  
  # Calculate optimal bitrate based on original
  local _origBitrate
  _origBitrate=$(ffprobe -v quiet -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 "$inFile" 2>/dev/null)
  _origBitrate=${_origBitrate:-48000}
  _origBitrate=$((${_origBitrate}/1000))
  
  local _bookBitrate
  if [[ $_origBitrate -gt ${targetBitrate:-48} ]]; then
    _bookBitrate=${targetBitrate:-48}
  elif [[ $_origBitrate -gt 40 ]]; then
    _bookBitrate=48
  else
    _bookBitrate=32
  fi
  
  # Store metadata in arrays (assuming global arrays exist)
  if [[ -n "$_bookTitle" ]]; then
    bookTitles[$index]="$_bookTitle"
  fi
  
  if [[ -n "$_bookAuthor" ]]; then
    bookAuthors[$index]="$_bookAuthor"
  fi
  
  bookBitrates[$index]="$_bookBitrate"
  bookDates[$index]="$_date"
  bookGenres[$index]="${_genre:-$DEFAULT_GENRE}"
  bookPublishers[$index]="$_publisher"
  
  # Log extracted metadata
  logMessage "DEBUG" "Extracted metadata for $(basename "$inFile"):"
  logMessage "DEBUG" "  Title: ${bookTitles[$index]:-Not found}"
  logMessage "DEBUG" "  Author: ${bookAuthors[$index]:-Not found}"
  logMessage "DEBUG" "  Genre: ${bookGenres[$index]:-Not found}"
  logMessage "DEBUG" "  Date: ${bookDates[$index]:-Not found}"
  logMessage "DEBUG" "  Bitrate: ${bookBitrates[$index]:-Not found}"
  
  return 0
}

# Prompt user for missing metadata
promptForMetadata()
{
  local index="$1"
  local filename="$2"
  
  if [[ -z "$index" ]]; then
    logMessage "ERROR" "promptForMetadata: Index parameter required"
    return 1
  fi
  
  logMessage "INFO" "Prompting for metadata for: $(basename "$filename")"
  
  # Prompt for title if missing
  if [[ -z "${bookTitles[$index]:-}" ]]; then
    while [[ -z "${bookTitles[$index]:-}" ]]; do
      echo -n "Enter the title of the book: "
      read -r _tempTitle
      if [[ -n "$_tempTitle" ]]; then
        bookTitles[$index]="$_tempTitle"
        logMessage "INFO" "Title set to: $_tempTitle"
      else
        logMessage "WARN" "Title cannot be empty"
      fi
    done
  fi
  
  # Prompt for author if missing
  if [[ -z "${bookAuthors[$index]:-}" ]]; then
    while [[ -z "${bookAuthors[$index]:-}" ]]; do
      echo -n "Enter the author of the book: "
      read -r _tempAuthor
      if [[ -n "$_tempAuthor" ]]; then
        bookAuthors[$index]="$_tempAuthor"
        logMessage "INFO" "Author set to: $_tempAuthor"
      else
        logMessage "WARN" "Author cannot be empty"
      fi
    done
  fi
  
  # Prompt for series if missing
  if [[ -z "${bookSeries[$index]:-}" ]]; then
    echo -n "Enter the series name (or press Enter to skip): "
    read -r _tempSeries
    if [[ -n "$_tempSeries" ]]; then
      bookSeries[$index]="$_tempSeries"
      logMessage "INFO" "Series set to: $_tempSeries"
      
      echo -n "Enter the series number (or press Enter for 1): "
      read -r _tempSeriesNum
      bookSeriesNumbers[$index]="${_tempSeriesNum:-1}"
      logMessage "INFO" "Series number set to: ${bookSeriesNumbers[$index]}"
    fi
  fi
  
  return 0
}

# Apply ID3 tags to audio file
tagIt()
{
  local inFile="$1"
  local index="$2"
  
  if [[ ! -f "$inFile" ]]; then
    logMessage "ERROR" "tagIt: Input file does not exist: $inFile"
    return 1
  fi
  
  if [[ -z "$index" ]]; then
    logMessage "ERROR" "tagIt: Index parameter required"
    return 1
  fi
  
  logMessage "TRACE" "Starting ID3 tagging for: $(basename "$inFile")"
  
  # Remove existing ID3 tags
  logMessage "INFO" "Removing original ID3 tags"
  if ! mid3v2 --delete-all "$inFile" >/dev/null 2>&1; then
    logMessage "WARN" "Failed to remove existing ID3 tags"
  fi
  
  # Add cover art if available
  if [[ -n "${bookCovers[$index]:-}" && -f "${bookCovers[$index]}" ]]; then
    logMessage "INFO" "Adding book cover image"
    if command -v fancy_audio >/dev/null 2>&1; then
      if fancy_audio "$inFile" "${bookCovers[$index]}" >/dev/null 2>&1; then
        logMessage "DEBUG" "Cover art added successfully"
      else
        logMessage "WARN" "Failed to add cover art using fancy_audio"
      fi
    else
      logMessage "WARN" "fancy_audio not available, skipping cover art"
    fi
  fi
  
  # Prepare ID3 tag data
  local author="${bookAuthors[$index]:-Unknown Author}"
  local title="${bookTitles[$index]:-Unknown Title}"
  local album="${bookSeries[$index]:-$title}"
  local genre="${bookGenres[$index]:-$DEFAULT_GENRE}"
  local date="${bookDates[$index]:-$(date +%Y)}"
  local url="${bookURLs[$index]:-}"
  local rating="${bookRatings[$index]:-}"
  local publisher="${bookPublishers[$index]:-}"
  local track="${bookSeriesNumbers[$index]:-$DEFAULT_TRACK_NUMBER}"
  
  logMessage "INFO" "Adding ID3 tags"
  
  # Build mid3v2 command
  local mid3v2_cmd=(
    "mid3v2"
    "-a" "$author"           # Artist
    "-A" "$album"            # Album
    "-t" "$title"            # Title
    "-g" "$genre"            # Genre
    "-T" "$track"            # Track number
    "-y" "$date"             # Year
  )
  
  # Add optional fields
  if [[ -n "$url" ]]; then
    mid3v2_cmd+=("-c" "Comment:$url:eng")
  fi
  
  if [[ -n "$rating" ]]; then
    mid3v2_cmd+=("-c" "Rating:$rating:eng")
  fi
  
  if [[ -n "$publisher" ]]; then
    mid3v2_cmd+=("-c" "Publisher:$publisher:eng")
  fi
  
  # Add encoding information
  mid3v2_cmd+=("-c" "Encoded by:$DEFAULT_ENCODER:eng")
  
  # Add input file
  mid3v2_cmd+=("$inFile")
  
  # Execute tagging command
  if "${mid3v2_cmd[@]}" >/dev/null 2>&1; then
    logMessage "INFO" "ID3 tags applied successfully"
    return 0
  else
    logMessage "ERROR" "Failed to apply ID3 tags"
    return 1
  fi
}

# Download cover art from URL
downloadCoverArt()
{
  local url="$1"
  local output_file="$2"
  local index="$3"
  
  if [[ -z "$url" || -z "$output_file" ]]; then
    logMessage "ERROR" "downloadCoverArt: URL and output file required"
    return 1
  fi
  
  logMessage "INFO" "Downloading cover art from: $url"
  
  # Create output directory if needed
  mkdir -p "$(dirname "$output_file")" || {
    logMessage "ERROR" "Failed to create output directory"
    return 1
  }
  
  # Download cover art with error handling
  if curl -s --max-time 30 --retry 2 --fail \
    --user-agent 'ccab-audiobook-converter/4.0' \
    -o "$output_file" "$url"; then
    
    # Verify downloaded file
    if [[ -f "$output_file" && -s "$output_file" ]]; then
      # Check if it's a valid image file
      if file "$output_file" | grep -qi "image"; then
        logMessage "INFO" "Cover art downloaded successfully"
        if [[ -n "$index" ]]; then
          bookCovers[$index]="$output_file"
        fi
        return 0
      else
        logMessage "WARN" "Downloaded file is not a valid image"
        rm -f "$output_file"
        return 1
      fi
    else
      logMessage "WARN" "Downloaded file is empty or missing"
      return 1
    fi
  else
    logMessage "WARN" "Failed to download cover art"
    return 1
  fi
}

# Validate metadata completeness
validateMetadata()
{
  local index="$1"
  local filename="$2"
  
  if [[ -z "$index" ]]; then
    logMessage "ERROR" "validateMetadata: Index parameter required"
    return 1
  fi
  
  local errors=0
  
  # Check required fields
  if [[ -z "${bookTitles[$index]:-}" ]]; then
    logMessage "ERROR" "Missing required field: title for $(basename "$filename")"
    ((errors++))
  fi
  
  if [[ -z "${bookAuthors[$index]:-}" ]]; then
    logMessage "ERROR" "Missing required field: author for $(basename "$filename")"
    ((errors++))
  fi
  
  # Check field lengths
  if [[ ${#bookTitles[$index]} -gt 200 ]]; then
    logMessage "WARN" "Title exceeds recommended length (200 chars)"
  fi
  
  if [[ ${#bookAuthors[$index]} -gt 100 ]]; then
    logMessage "WARN" "Author exceeds recommended length (100 chars)"
  fi
  
  if [[ $errors -gt 0 ]]; then
    logMessage "ERROR" "Metadata validation failed with $errors errors"
    return 1
  fi
  
  logMessage "DEBUG" "Metadata validation passed"
  return 0
}

# Generate reverse author name for directory structure
generateReverseAuthor()
{
  local author="$1"
  local index="$2"
  
  if [[ -z "$author" ]]; then
    logMessage "ERROR" "generateReverseAuthor: Author parameter required"
    return 1
  fi
  
  # Split author name and reverse (Last, First)
  local reversed=""
  if [[ "$author" =~ ^([^[:space:]]+)[[:space:]]+(.+)$ ]]; then
    # First Last -> Last, First
    reversed="${BASH_REMATCH[2]}, ${BASH_REMATCH[1]}"
  else
    # Single name or already reversed
    reversed="$author"
  fi
  
  # Clean up for directory name
  reversed=${reversed//[^a-zA-Z0-9, ]/}
  reversed=$(echo "$reversed" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  
  if [[ -n "$index" ]]; then
    bookAuthorReversed[$index]="$reversed"
  fi
  
  echo "$reversed"
  return 0
}

# Clear metadata arrays
clearMetadata()
{
  logMessage "TRACE" "Clearing metadata arrays"
  unset bookTitles bookAuthors bookSeries bookSeriesNumbers
  unset bookGenres bookDates bookPublishers bookRatings bookURLs
  unset bookCovers bookBitrates bookAuthorReversed
  declare -ag bookTitles bookAuthors bookSeries bookSeriesNumbers
  declare -ag bookGenres bookDates bookPublishers bookRatings bookURLs
  declare -ag bookCovers bookBitrates bookAuthorReversed
}

# Display metadata summary
showMetadataSummary()
{
  local index="$1"
  local filename="$2"
  
  if [[ -z "$index" ]]; then
    logMessage "ERROR" "showMetadataSummary: Index parameter required"
    return 1
  fi
  
  cat << EOF
File: $(basename "${filename:-Unknown}")
  Title: ${bookTitles[$index]:-Not found}
  Author: ${bookAuthors[$index]:-Not found}
  Author, Reversed: ${bookAuthorReversed[$index]}
  Series: ${bookSeries[$index]:-Not found} ${bookSeriesNumbers[$index]:+#${bookSeriesNumbers[$index]}}
  Genre: ${bookGenres[$index]:-Not found}
  Publisher: ${bookPublishers[$index]:-Not found}
  Date: ${bookDates[$index]:-Not found}
  Bitrate: ${bookBitrates[$index]:-Not found}k
  Cover Art: ${bookCovers[$index]:-Not found}
  Rating: ${bookRatings[$index]:-Not found}
  URL: ${bookURLs[$index]:-Not found}
EOF
}

# Export metadata module functions for external use
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  # Module is being sourced, export functions
  export -f initializeMetadata
  export -f validateMetadataCommands
  export -f extractMetadata
  export -f promptForMetadata
  export -f tagIt
  export -f downloadCoverArt
  export -f validateMetadata
  export -f generateReverseAuthor
  export -f clearMetadata
  export -f showMetadataSummary
fi