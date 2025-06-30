#!/bin/bash
#shellcheck disable=SC2004

## ========================================================================================
##       Title: ccab-organization.sh (File Organization Module)
##      Author: R. L. Paxton
##     Version: 4.0
##        Date: 2025-06-30
##     License: Apache 2.0
## Description: File organization and directory management module for ccab audiobook converter
##              Handles structured directory creation, file moving, and permission management
## ========================================================================================

# Module metadata
CCAB_ORGANIZATION_VERSION="4.0"

# Organization constants
DEFAULT_BASE_DIR="/audio/audiobooks"
DEFAULT_USER="rp01"
DEFAULT_GROUP="admins"
CONVERT_LOG_NAME="convert.log"

# Module initialization flag
CCAB_ORGANIZATION_INITIALIZED=false

# Initialize organization module
initializeOrganization()
{
  if [[ "$CCAB_ORGANIZATION_INITIALIZED" == "true" ]]; then
    return 0
  fi
  
  logMessage "TRACE" "Initializing organization module v${CCAB_ORGANIZATION_VERSION}"
  
  # Set default organization settings if not already configured
  if [[ -z "${BASE_DIR:-}" ]]; then
    BASE_DIR="$DEFAULT_BASE_DIR"
    logMessage "DEBUG" "Using default base directory: $BASE_DIR"
  fi
  
  if [[ -z "${FILE_USER:-}" ]]; then
    FILE_USER="$DEFAULT_USER"
    logMessage "DEBUG" "Using default file user: $FILE_USER"
  fi
  
  if [[ -z "${FILE_GROUP:-}" ]]; then
    FILE_GROUP="$DEFAULT_GROUP"
    logMessage "DEBUG" "Using default file group: $FILE_GROUP"
  fi
  
  # Initialize genre categories if not already loaded
  if [[ -z "${GENRE_CATEGORIES:-}" ]]; then
    initializeGenreCategories
  fi
  
  # Initialize convert log path
  if [[ -z "${convertLog:-}" ]]; then
    convertLog="${logDir:-/tmp}/$CONVERT_LOG_NAME"
    logMessage "DEBUG" "Using convert log: $convertLog"
  fi
  
  CCAB_ORGANIZATION_INITIALIZED=true
  logMessage "TRACE" "Organization module initialized successfully"
  return 0
}

# Initialize default genre categories
initializeGenreCategories()
{
  logMessage "TRACE" "Initializing default genre categories"
  
  # Default genre categories if not loaded from config
  GENRE_CATEGORIES=(
    "1:Romance:Romance"
    "2:Erotica:Erotica" 
    "3:Sci-Fi:SciFi"
    "4:Fantasy:Fantasy"
    "5:Thriller:Thriller"
    "6:Misc:Misc"
  )
  
  logMessage "DEBUG" "Loaded ${#GENRE_CATEGORIES[@]} genre categories"
}

# Display genre categories and get user selection
classifyIt()
{
  local inFile="$1"
  local index="$2"
  local category=""
  
  if [[ -z "$inFile" || -z "$index" ]]; then
    logMessage "ERROR" "classifyIt: Input file and index parameters required"
    return 1
  fi
  
  logMessage "TRACE" "Starting book classification for: $(basename "$inFile")"
  logMessage "INFO" "Checking book category..."
  
  # Display book information if available
  if [[ -n "${bookInfoFiles[$index]:-}" && -f "${bookInfoFiles[$index]}" ]]; then
    echo
    cat "${bookInfoFiles[$index]}"
    echo
  else
    echo
    echo "File: $(basename "$inFile")"
    echo "Title: ${bookTitles[$index]:-Unknown}"
    echo "Author: ${bookAuthors[$index]:-Unknown}"
    echo "Series: ${bookSeries[$index]:-Unknown}"
    echo
  fi
  
  # Interactive category selection loop
  while [[ -z "$category" ]]; do
    # Display genre categories
    echo -e "${C3:-}Genre Categories:${C0:-}"
    for genre_entry in "${GENRE_CATEGORIES[@]}"; do
      IFS=':' read -r num display_name dir_name <<< "$genre_entry"
      echo "$num) $display_name"
    done
    echo
    
    echo -n "Select book category number: "
    read -rn 1 category
    echo
    
    # Validate category selection
    local valid_category=false
    for genre_entry in "${GENRE_CATEGORIES[@]}"; do
      IFS=':' read -r num display_name dir_name <<< "$genre_entry"
      if [[ "$category" == "$num" ]]; then
        valid_category=true
        bookType="$dir_name"
        logMessage "INFO" "Selected category: $display_name (Directory: $dir_name)"
        break
      fi
    done
    
    if [[ "$valid_category" != "true" ]]; then
      logMessage "WARN" "Invalid category selection: $category"
      unset category
    fi
  done
  
  if [[ -z "$bookType" ]]; then
    logMessage "ERROR" "Failed to determine book type"
    return 1
  fi
  
  logMessage "DEBUG" "Book classified as: $bookType"
  return 0
}

# Get genre directory name from category number
getGenreDirectory()
{
  local category_num="$1"
  
  if [[ -z "$category_num" ]]; then
    logMessage "ERROR" "getGenreDirectory: Category number required"
    return 1
  fi
  
  for genre_entry in "${GENRE_CATEGORIES[@]}"; do
    IFS=':' read -r num display_name dir_name <<< "$genre_entry"
    if [[ "$category_num" == "$num" ]]; then
      echo "$dir_name"
      return 0
    fi
  done
  
  logMessage "ERROR" "Invalid category number: $category_num"
  return 1
}

# Build directory path for organized audiobook
buildDirectoryPath()
{
  local index="$1"
  local genre="${2:-$bookType}"
  
  if [[ -z "$index" ]]; then
    logMessage "ERROR" "buildDirectoryPath: Index parameter required"
    return 1
  fi
  
  if [[ -z "$genre" ]]; then
    logMessage "ERROR" "buildDirectoryPath: Genre not specified"
    return 1
  fi
  
  # Build author directory (reversed name format)
  local author_dir="${bookAuthorReversed[$index]:-${bookAuthors[$index]}}"
  if [[ -z "$author_dir" ]]; then
    logMessage "ERROR" "buildDirectoryPath: Author information missing"
    return 1
  fi
  
  # Build book directory (series - title format)
  local book_dir
  if [[ -n "${bookSeries[$index]:-}" ]]; then
    book_dir="${bookSeries[$index]} - ${bookTitles[$index]}"
  else
    book_dir="${bookTitles[$index]}"
  fi
  
  if [[ -z "$book_dir" ]]; then
    logMessage "ERROR" "buildDirectoryPath: Title information missing"
    return 1
  fi
  
  # Clean directory names (remove invalid characters)
  author_dir=$(echo "$author_dir" | tr -d '\000-\037\177' | sed 's/[<>:"|?*]/_/g')
  book_dir=$(echo "$book_dir" | tr -d '\000-\037\177' | sed 's/[<>:"|?*]/_/g')
  
  # Build full path
  local base_path="$BASE_DIR/$genre"
  local author_path="$base_path/$author_dir"
  local full_path="$author_path/$book_dir"
  
  # Store paths in arrays for later use  
  authorDirs[$index]="$author_path"
  #shellcheck disable=SC2034
  outDirs[$index]="$full_path"
  
  echo "$full_path"
  return 0
}

# Create directory structure with proper permissions
createDirectoryStructure()
{
  local target_dir="$1"
  local create_parent="${2:-true}"
  
  if [[ -z "$target_dir" ]]; then
    logMessage "ERROR" "createDirectoryStructure: Target directory required"
    return 1
  fi
  
  logMessage "TRACE" "Creating directory structure: $target_dir"
  
  # Create parent directories if requested
  if [[ "$create_parent" == "true" ]]; then
    if ! mkdir -p "$target_dir"; then
      logMessage "ERROR" "Failed to create directory: $target_dir"
      return 1
    fi
  else
    if ! mkdir "$target_dir"; then
      logMessage "ERROR" "Failed to create directory: $target_dir"
      return 1
    fi
  fi
  
  logMessage "DEBUG" "Created directory: $target_dir"
  return 0
}

# Handle existing directory backup
backupExistingDirectory()
{
  local target_dir="$1"
  
  if [[ -z "$target_dir" ]]; then
    logMessage "ERROR" "backupExistingDirectory: Target directory required"
    return 1
  fi
  
  if [[ -d "$target_dir" ]]; then
    local backup_dir="${target_dir}.old"
    logMessage "INFO" "Backing up existing directory to: $(basename "$backup_dir")"
    
    if ! mv "$target_dir" "$backup_dir"; then
      logMessage "ERROR" "Failed to backup existing directory"
      return 1
    fi
    
    logMessage "DEBUG" "Directory backed up successfully"
  fi
  
  return 0
}

# Move files to organized directory structure
moveIt()
{
  local inFile="$1"
  local index="$2"
  local move_enabled="${3:-${move:-false}}"
  
  if [[ -z "$inFile" || -z "$index" ]]; then
    logMessage "ERROR" "moveIt: Input file and index parameters required"
    return 1
  fi
  
  logMessage "TRACE" "Starting file organization for: $(basename "$inFile")"
  
  # Check if moving is enabled
  if [[ "$move_enabled" != "true" ]]; then
    logMessage "WARN" "Move flag not set - files will not be moved"
    return 0
  fi
  
  # Build target directory path
  local target_dir
  target_dir=$(buildDirectoryPath "$index")
  if [[ $? -ne 0 || -z "$target_dir" ]]; then
    logMessage "ERROR" "Failed to build directory path"
    return 1
  fi
  
  logMessage "INFO" "Moving files to: $target_dir"
  
  # Backup existing directory if it exists
  if ! backupExistingDirectory "$target_dir"; then
    logMessage "ERROR" "Failed to backup existing directory"
    return 1
  fi
  
  # Create target directory structure
  if ! createDirectoryStructure "$target_dir"; then
    logMessage "ERROR" "Failed to create target directory"
    return 1
  fi
  
  # Move files to target directory
  local files_to_move=()
  local move_status=0
  
  # Add files to move list
  if [[ -n "${bookInfoFiles[$index]:-}" && -f "${bookInfoFiles[$index]}" ]]; then
    files_to_move+=("${bookInfoFiles[$index]}")
  fi
  
  if [[ -n "${bookCovers[$index]:-}" && -f "${bookCovers[$index]}" ]]; then
    files_to_move+=("${bookCovers[$index]}")
  fi
  
  if [[ -n "${encodedFiles[$index]:-}" && -f "${encodedFiles[$index]}" ]]; then
    files_to_move+=("${encodedFiles[$index]}")
  fi
  
  # Move each file
  for file in "${files_to_move[@]}"; do
    if [[ -f "$file" ]]; then
      logMessage "DEBUG" "Moving: $(basename "$file")"
      if ! mv "$file" "$target_dir/"; then
        logMessage "ERROR" "Failed to move file: $(basename "$file")"
        move_status=1
      fi
    fi
  done
  
  if [[ $move_status -eq 0 ]]; then
    logMessage "INFO" "Files moved successfully"
  else
    logMessage "ERROR" "Some files failed to move"
    return 1
  fi
  
  # Set permissions
  if ! setDirectoryPermissions "${authorDirs[$index]}"; then
    logMessage "WARN" "Failed to set directory permissions"
  fi
  
  # Update convert log
  if ! updateConvertLog "$index"; then
    logMessage "WARN" "Failed to update convert log"
  fi
  
  # Send desktop notification if available
  sendNotification "$index"
  
  return 0
}

# Set appropriate directory and file permissions
setDirectoryPermissions()
{
  local base_dir="$1"
  
  if [[ -z "$base_dir" || ! -d "$base_dir" ]]; then
    logMessage "ERROR" "setDirectoryPermissions: Valid directory required"
    return 1
  fi
  
  logMessage "TRACE" "Setting permissions for: $base_dir"
  
  # Check if running as different user
  if [[ "$USER" != "$FILE_USER" ]]; then
    logMessage "INFO" "Setting file/directory permissions for user: $FILE_USER"
    
    # Set ownership
    if ! sudo chown -R "$FILE_USER:$FILE_GROUP" "$base_dir"; then
      logMessage "ERROR" "Failed to set ownership"
      return 1
    fi
    
    # Set directory permissions (775)
    if ! sudo chmod 775 "$base_dir"; then
      logMessage "ERROR" "Failed to set base directory permissions"
      return 1
    fi
    
    # Set permissions for all subdirectories and files
    if ! find "$base_dir" -type d -exec sudo chmod 775 "{}" \;; then
      logMessage "ERROR" "Failed to set subdirectory permissions"
      return 1
    fi
    
    if ! find "$base_dir" -type f -exec sudo chmod 664 "{}" \;; then
      logMessage "ERROR" "Failed to set file permissions"
      return 1
    fi
  else
    logMessage "INFO" "Setting directory permissions"
    
    # Standard permissions for current user
    if ! chmod 755 "$base_dir"; then
      logMessage "ERROR" "Failed to set base directory permissions"
      return 1
    fi
    
    if ! find "$base_dir" -type d -exec chmod 755 "{}" \;; then
      logMessage "ERROR" "Failed to set subdirectory permissions"
      return 1
    fi
    
    if ! find "$base_dir" -type f -exec chmod 644 "{}" \;; then
      logMessage "ERROR" "Failed to set file permissions"
      return 1
    fi
  fi
  
  logMessage "DEBUG" "Permissions set successfully"
  return 0
}

# Update convert log with processing information
updateConvertLog()
{
  local index="$1"
  
  if [[ -z "$index" ]]; then
    logMessage "ERROR" "updateConvertLog: Index parameter required"
    return 1
  fi
  
  logMessage "TRACE" "Updating convert log"
  
  # Create log entry
  local log_date
  log_date=$(date +%Y-%b-%d)
  log_date=${log_date^^}
  
  local log_entry="$log_date;[${bookType:-Unknown}];${bookTitles[$index]:-Unknown Title}"
  
  # Append to convert log
  if echo "$log_entry" >> "$convertLog"; then
    logMessage "DEBUG" "Convert log updated: $log_entry"
    return 0
  else
    logMessage "ERROR" "Failed to update convert log"
    return 1
  fi
}

# Send desktop notification
sendNotification()
{
  local index="$1"
  
  if [[ -z "$index" ]]; then
    return 0
  fi
  
  # Send notification if notify-send is available
  if command -v notify-send >/dev/null 2>&1; then
    local title="Audiobook encode completed:"
    local message="${bookAuthors[$index]:-Unknown} - ${bookTitles[$index]:-Unknown}"
    
    if notify-send "$title" "$message" 2>/dev/null; then
      logMessage "DEBUG" "Desktop notification sent"
    else
      logMessage "DEBUG" "Failed to send desktop notification"
    fi
  fi
}

# Validate organization configuration
validateOrganizationConfig()
{
  local errors=0
  
  logMessage "TRACE" "Validating organization configuration"
  
  # Check base directory
  if [[ -z "$BASE_DIR" ]]; then
    logMessage "ERROR" "BASE_DIR not configured"
    ((errors++))
  elif [[ ! -d "$BASE_DIR" ]]; then
    logMessage "WARN" "Base directory does not exist: $BASE_DIR"
    if ! mkdir -p "$BASE_DIR"; then
      logMessage "ERROR" "Cannot create base directory: $BASE_DIR"
      ((errors++))
    fi
  fi
  
  # Check user/group settings
  if [[ -z "$FILE_USER" ]]; then
    logMessage "WARN" "FILE_USER not configured, using current user"
    FILE_USER="$USER"
  fi
  
  if [[ -z "$FILE_GROUP" ]]; then
    logMessage "WARN" "FILE_GROUP not configured, using current group"
    FILE_GROUP=$(id -gn)
  fi
  
  # Check genre categories
  if [[ ${#GENRE_CATEGORIES[@]} -eq 0 ]]; then
    logMessage "ERROR" "No genre categories configured"
    ((errors++))
  fi
  
  if [[ $errors -gt 0 ]]; then
    logMessage "ERROR" "Organization configuration validation failed with $errors errors"
    return 1
  fi
  
  logMessage "DEBUG" "Organization configuration validation passed"
  return 0
}

# Display organization structure
showOrganizationStructure()
{
  echo "Audiobook Organization Structure:"
  echo "Base Directory: $BASE_DIR"
  echo
  echo "Genre Categories:"
  for genre_entry in "${GENRE_CATEGORIES[@]}"; do
    IFS=':' read -r num display_name dir_name <<< "$genre_entry"
    echo "  $num) $display_name -> $BASE_DIR/$dir_name/"
  done
  echo
  echo "Directory Structure:"
  echo "  $BASE_DIR/<Genre>/<Author_Last,First>/<Series - Title>/"
  echo "    ├── <Author> - <Series> - <Title>.mp3"
  echo "    ├── book.info"
  echo "    └── cover.jpg"
}

# Export organization module functions for external use
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  # Module is being sourced, export functions
  export -f initializeOrganization
  export -f initializeGenreCategories
  export -f classifyIt
  export -f getGenreDirectory
  export -f buildDirectoryPath
  export -f createDirectoryStructure
  export -f backupExistingDirectory
  export -f moveIt
  export -f setDirectoryPermissions
  export -f updateConvertLog
  export -f sendNotification
  export -f validateOrganizationConfig
  export -f showOrganizationStructure
fi