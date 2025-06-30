#!/bin/bash
#shellcheck disable=SC2004

## ========================================================================================
##       Title: ccab-parser.sh
##      Author: R. L. Paxton
##     Version: 4.0
##        Date: 2025-06-20
##     License: Apache 2.0
## Description: Data parser module for ccab audiobook converter
##              Handles web scraping, metadata extraction, and book information parsing
## ========================================================================================

# Module identification
#shellcheck disable=SC2034
CCAB_PARSER_MODULE="ccab-parser"
#shellcheck disable=SC2034
CCAB_PARSER_VERSION="4.0"

# Parser configuration variables
#shellcheck disable=SC2034
declare -g SEARCH_RETRIES=3
#shellcheck disable=SC2034
declare -g SEARCH_TIMEOUT=30
#shellcheck disable=SC2034
declare -g MAX_DOWNLOAD_SIZE="2M"

# Book metadata arrays (global for module use)
declare -ga bookTitles=()
declare -ga bookAuthors=()
declare -ga bookSeries=()
declare -ga bookSeriesNumbers=()
declare -ga bookNarrators=()
declare -ga bookPublishers=()
declare -ga bookGenres=()
declare -ga bookCovers=()
declare -ga bookDescriptions=()
declare -ga bookASINs=()
declare -ga bookDurations=()
declare -ga bookRatings=()

# Temporary files for parsing
declare -g tempHtmlFile=""
declare -g tempInfoFile=""
declare -g tempRichFile=""

##
## Core Search Functions
##

# Perform Google Custom Search API query
searchBooks()
{
  local search_query="$1"
  local max_results="${2:-5}"
  local retry_count=0
  
  logMessage "INFO" "Searching for: $search_query"
  
  # Validate and sanitize search query
  search_query=$(validateInput "$search_query" 200)
  if [[ -z "$search_query" ]]; then
    logMessage "ERROR" "Invalid or empty search query"
    return 1
  fi
  
  # Check for required API credentials
  if [[ ! -f "$HOME/.config/keys" ]]; then
    logMessage "ERROR" "API keys file not found: $HOME/.config/keys"
    return 1
  fi
  
  # Source API credentials
  #shellcheck disable=SC1091
  if ! source "$HOME/.config/keys"; then
    logMessage "ERROR" "Failed to load API credentials"
    return 1
  fi
  
  # Validate API credentials
  if [[ -z "${_engine_id:-}" || -z "${_api_key:-}" ]]; then
    logMessage "ERROR" "Missing required API credentials (_engine_id, _api_key)"
    return 1
  fi
  
  # URL encode the search query
  local encoded_query
  encoded_query=$(urlEncode "$search_query")
  
  # Construct search URL
  local search_url="https://www.googleapis.com/customsearch/v1"
  search_url+="?key=$_api_key"
  search_url+="&cx=$_engine_id"
  search_url+="&q=$encoded_query"
  search_url+="&num=$max_results"
  search_url+="&fields=items(title,link,snippet)"
  
  # Perform search with retries
  local search_results=""
  while [[ $retry_count -lt $SEARCH_RETRIES ]]; do
    logMessage "DEBUG" "Search attempt $((retry_count + 1))/$SEARCH_RETRIES"
    
    search_results=$(curl -s \
      --max-time "$SEARCH_TIMEOUT" \
      --max-filesize "$MAX_DOWNLOAD_SIZE" \
      --user-agent "CCAB/4.0 (AudiobookConverter)" \
      "$search_url" 2>/dev/null)
    
    if [[ -n "$search_results" && "$search_results" =~ \"items\" ]]; then
      break
    fi
    
    ((retry_count++))
    sleep 2
  done
  
  if [[ -z "$search_results" || ! "$search_results" =~ \"items\" ]]; then
    logMessage "ERROR" "Search failed after $SEARCH_RETRIES attempts"
    return 1
  fi
  
  # Validate and filter results
  local filtered_results
  filtered_results=$(echo "$search_results" | jq -r '.items[]? | select(.link | test("(amazon\\.com|goodreads\\.com|audible\\.com)")) | {title: .title, link: .link, snippet: .snippet}' 2>/dev/null)
  
  if [[ -z "$filtered_results" ]]; then
    logMessage "WARN" "No valid results found from allowed sources"
    return 1
  fi
  
  echo "$filtered_results"
  return 0
}

# Enhanced download with web scraper integration  
downloadAndScrapeBookPage()
{
  local book_url="$1"
  local book_index="$2"
  
  logMessage "INFO" "Downloading and scraping book page: $book_url"
  
  # Create temporary file for HTML content
  local temp_html_file
  temp_html_file=$(mktemp "${tmpDir:-/tmp}/ccab.scrape.XXXXXX")
  
  # Download using existing function
  if downloadBookPage "$book_url" "$temp_html_file"; then
    # Use web scraper to extract data
    if command -v scrapeBookPage &> /dev/null; then
      scrapeBookPage "$temp_html_file" "$book_index"
      
      # Copy scraped data to parser arrays
      if [[ ${#SCRAPED_TITLES[@]} -gt $book_index ]]; then
        bookTitles[$book_index]="${SCRAPED_TITLES[$book_index]}"
        bookAuthors[$book_index]="${SCRAPED_AUTHORS[$book_index]}"
        bookNarrators[$book_index]="${SCRAPED_NARRATORS[$book_index]}"
        bookSeries[$book_index]="${SCRAPED_SERIES[$book_index]}"
        bookSeriesNumbers[$book_index]="${SCRAPED_SERIES_NUMBERS[$book_index]}"
        bookPublishers[$book_index]="${SCRAPED_PUBLISHERS[$book_index]}"
        bookDurations[$book_index]="${SCRAPED_DURATIONS[$book_index]}"
        bookASINs[$book_index]="${SCRAPED_ASINS[$book_index]}"
        bookCovers[$book_index]="${SCRAPED_COVER_URLS[$book_index]}"
        bookDescriptions[$book_index]="${SCRAPED_DESCRIPTIONS[$book_index]}"
        
        logMessage "INFO" "Book data imported from web scraper for index $book_index"
      fi
    else
      logMessage "WARN" "Web scraper not available, using legacy parsing"
      # Fall back to existing parsing methods
      extractRichProductInfo "$temp_html_file" "$tempRichFile"
      local page_title
      page_title=$(extractPageTitle "$temp_html_file")
      
      parseBookTitle "$tempRichFile" "$page_title" "$book_index"
      parseBookAuthor "$tempRichFile" "$temp_html_file" "$book_index"
      parseBookSeries "$tempRichFile" "${bookTitles[$book_index]}" "$book_index"
      parseAdditionalMetadata "$tempRichFile" "$temp_html_file" "$book_index"
      extractCoverArt "$temp_html_file" "$book_index"
    fi
    
    # Clean up
    rm -f "$temp_html_file"
    return 0
  else
    rm -f "$temp_html_file"
    return 1
  fi
}

# Original download function (preserved for compatibility)
downloadBookPage()
{
  local book_url="$1"
  local output_file="$2"
  
  logMessage "INFO" "Downloading book page: $book_url"
  
  # Validate URL
  if ! validateURL "$book_url"; then
    logMessage "ERROR" "Invalid URL: $book_url"
    return 1
  fi
  
  # Create secure temporary file
  if ! createSecureTempFile "$output_file"; then
    logMessage "ERROR" "Failed to create temporary file: $output_file"
    return 1
  fi
  
  # Download page content
  local curl_result
  curl_result=$(curl -s \
    --max-time "$SEARCH_TIMEOUT" \
    --max-filesize "$MAX_DOWNLOAD_SIZE" \
    --user-agent "CCAB/4.0 (AudiobookConverter)" \
    --location \
    --compressed \
    "$book_url" 2>/dev/null)
  
  if [[ -z "$curl_result" ]]; then
    logMessage "ERROR" "Failed to download page content"
    return 1
  fi
  
  # Sanitize HTML content
  local sanitized_content
  sanitized_content=$(sanitizeHTML "$curl_result")
  
  # Write sanitized content to file
  echo "$sanitized_content" > "$output_file"
  
  # Normalize HTML if hxnormalize is available
  if command -v hxnormalize &> /dev/null; then
    if hxnormalize -x -e -l 240 "$output_file" > "${output_file}.norm" 2>/dev/null; then
      mv "${output_file}.norm" "$output_file"
      logMessage "DEBUG" "HTML normalized successfully"
    fi
  fi
  
  logMessage "INFO" "Page downloaded and processed: $(wc -l < "$output_file") lines"
  return 0
}

##
## HTML Processing Functions
##

# Extract Amazon rich product information
extractRichProductInfo()
{
  local html_file="$1"
  local output_file="$2"
  
  if [[ ! -f "$html_file" ]]; then
    logMessage "ERROR" "HTML file not found: $html_file"
    return 1
  fi
  
  logMessage "DEBUG" "Extracting rich product information"
  
  # Create secure output file
  if ! createSecureTempFile "$output_file"; then
    logMessage "ERROR" "Failed to create output file: $output_file"
    return 1
  fi
  
  # Extract rich product information sections
  if grep -q "rich_product_information" "$html_file"; then
    # Extract sections containing rich product info
    sed -n '/rich_product_information/,/}/p' "$html_file" | \
    sed 's/\\"/"/g' | \
    sed 's/\\n/ /g' | \
    grep -E "(title|author|narrator|publisher|series|asin|length|rating)" > "$output_file" 2>/dev/null
    
    if [[ -s "$output_file" ]]; then
      logMessage "DEBUG" "Rich product information extracted: $(wc -l < "$output_file") lines"
      return 0
    fi
  fi
  
  # Fallback: extract from meta tags and structured data
  {
    grep -i 'property="og:' "$html_file" 2>/dev/null || true
    grep -i 'name="twitter:' "$html_file" 2>/dev/null || true
    grep -i '"@type".*"Book"' "$html_file" 2>/dev/null || true
    grep -i '"author"' "$html_file" 2>/dev/null || true
    grep -i '"name"' "$html_file" 2>/dev/null || true
  } > "$output_file"
  
  if [[ -s "$output_file" ]]; then
    logMessage "DEBUG" "Fallback metadata extracted: $(wc -l < "$output_file") lines"
    return 0
  fi
  
  logMessage "WARN" "No structured metadata found"
  return 1
}

# Extract page title
extractPageTitle()
{
  local html_file="$1"
  
  if [[ ! -f "$html_file" ]]; then
    logMessage "ERROR" "HTML file not found: $html_file"
    return 1
  fi
  
  local title=""
  
  # Extract title from <title> tag
  title=$(grep -i '<title>' "$html_file" | head -1 | sed 's/<[^>]*>//g' | sed 's/&amp;/\&/g' | sed 's/&apos;/'"'"'/g' | sed 's/&quot;/"/g' | sed 's/&lt;/</g' | sed 's/&gt;/>/g')
  
  if [[ -n "$title" ]]; then
    # Clean up title
    title=$(echo "$title" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -c 200)
    title=$(validateInput "$title" 200)
    echo "$title"
    return 0
  fi
  
  logMessage "WARN" "No page title found"
  return 1
}

##
## Metadata Parsing Functions
##

# Parse book title from various sources
parseBookTitle()
{
  local rich_info_file="$1"
  local page_title="$2"
  local book_index="$3"
  
  local title=""
  
  # Try to extract from rich info first
  if [[ -f "$rich_info_file" ]]; then
    title=$(grep -i '"title"' "$rich_info_file" | head -1 | sed 's/.*"title"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | sed 's/\\//g')
  fi
  
  # Fallback to page title
  if [[ -z "$title" && -n "$page_title" ]]; then
    # Extract title from Amazon format: "Title: Subtitle (Author) | Amazon.com"
    title=$(echo "$page_title" | sed 's/[[:space:]]*|.*$//' | sed 's/[[:space:]]*([^)]*).*$//' | sed 's/:[[:space:]]*Audible Audio Edition.*$//' | sed 's/,[[:space:]]*Unabridged.*$//')
  fi
  
  # Clean and validate title
  if [[ -n "$title" ]]; then
    title=$(validateInput "$title" 200)
    title=$(echo "$title" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    if [[ -n "$title" ]]; then
      bookTitles[$book_index]="$title"
      logMessage "INFO" "Parsed title: $title"
      return 0
    fi
  fi
  
  logMessage "WARN" "Could not parse book title"
  bookTitles[$book_index]="Unknown Title"
  return 1
}

# Parse book author
parseBookAuthor()
{
  local rich_info_file="$1"
  local html_file="$2"
  local book_index="$3"
  
  local author=""
  
  # Try rich info first
  if [[ -f "$rich_info_file" ]]; then
    author=$(grep -i '"author"' "$rich_info_file" | head -1 | sed 's/.*"author"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | sed 's/\\//g')
  fi
  
  # Try alternative patterns
  if [[ -z "$author" && -f "$html_file" ]]; then
    # Try meta tags
    author=$(grep -i 'property="books:author"' "$html_file" | head -1 | sed 's/.*content="\([^"]*\)".*/\1/')
    
    # Try by: pattern
    if [[ -z "$author" ]]; then
      author=$(grep -i 'by:' "$html_file" | head -1 | sed 's/.*by:[[:space:]]*\([^<]*\).*/\1/' | sed 's/<[^>]*>//g')
    fi
  fi
  
  # Clean and validate author
  if [[ -n "$author" ]]; then
    author=$(validateInput "$author" 100)
    author=$(echo "$author" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    if [[ -n "$author" ]]; then
      bookAuthors[$book_index]="$author"
      logMessage "INFO" "Parsed author: $author"
      return 0
    fi
  fi
  
  logMessage "WARN" "Could not parse book author"
  bookAuthors[$book_index]="Unknown Author"
  return 1
}

# Parse book series information
parseBookSeries()
{
  local rich_info_file="$1"
  local title="$2"
  local book_index="$3"
  
  local series=""
  local series_number=""
  
  # Try to extract from rich info
  if [[ -f "$rich_info_file" ]]; then
    series=$(grep -i '"series"' "$rich_info_file" | head -1 | sed 's/.*"series"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | sed 's/\\//g')
    series_number=$(grep -i '"book.*number"' "$rich_info_file" | head -1 | sed 's/.*[^0-9]\([0-9]\+\)[^0-9].*/\1/')
  fi
  
  # Try to extract from title
  if [[ -z "$series" && -n "$title" ]]; then
    # Look for patterns like "Series Name, Book 1" or "Series Name: Book 1"
    if [[ "$title" =~ (.+)[,:]?[[:space:]]*(Book|book)[[:space:]]*([0-9]+) ]]; then
      series="${BASH_REMATCH[1]}"
      series_number="${BASH_REMATCH[3]}"
    # Look for patterns like "Title (Series Name Book 1)"
    elif [[ "$title" =~ \((.+)[[:space:]]*(Book|book)[[:space:]]*([0-9]+)\) ]]; then
      series="${BASH_REMATCH[1]}"
      series_number="${BASH_REMATCH[3]}"
    fi
  fi
  
  # Clean and validate series
  if [[ -n "$series" ]]; then
    series=$(validateInput "$series" 100)
    series=$(echo "$series" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/[,:]$//g')
    
    if [[ -n "$series" ]]; then
      bookSeries[$book_index]="$series"
      
      # Format series number with zero padding
      if [[ -n "$series_number" && "$series_number" =~ ^[0-9]+$ ]]; then
        series_number=$(printf "%02d" "$series_number")
        bookSeriesNumbers[$book_index]="$series_number"
        logMessage "INFO" "Parsed series: $series #$series_number"
      else
        bookSeriesNumbers[$book_index]="01"
        logMessage "INFO" "Parsed series: $series (defaulted to #01)"
      fi
      return 0
    fi
  fi
  
  logMessage "DEBUG" "No series information found"
  bookSeries[$book_index]=""
  bookSeriesNumbers[$book_index]=""
  return 1
}

# Parse additional metadata (narrator, publisher, etc.)
parseAdditionalMetadata()
{
  local rich_info_file="$1"
  local html_file="$2"
  local book_index="$3"
  
  local narrator="" publisher="" asin="" duration="" rating=""
  
  if [[ -f "$rich_info_file" ]]; then
    # Extract narrator
    narrator=$(grep -i '"narrator"' "$rich_info_file" | head -1 | sed 's/.*"narrator"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | sed 's/\\//g')
    
    # Extract publisher
    publisher=$(grep -i '"publisher"' "$rich_info_file" | head -1 | sed 's/.*"publisher"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | sed 's/\\//g')
    
    # Extract ASIN
    asin=$(grep -i '"asin"' "$rich_info_file" | head -1 | sed 's/.*"asin"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | sed 's/\\//g')
    
    # Extract duration/length
    duration=$(grep -i '"length"' "$rich_info_file" | head -1 | sed 's/.*"length"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | sed 's/\\//g')
    
    # Extract rating
    rating=$(grep -i '"rating"' "$rich_info_file" | head -1 | sed 's/.*"rating"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | sed 's/\\//g')
  fi
  
  # Fallback to HTML parsing if rich info unavailable
  if [[ -z "$narrator" && -f "$html_file" ]]; then
    narrator=$(grep -i 'narrator' "$html_file" | head -1 | sed 's/<[^>]*>//g' | sed 's/.*[Nn]arrated by[[:space:]]*:\?[[:space:]]*\([^,<]*\).*/\1/')
  fi
  
  # Clean and store metadata
  narrator=$(validateInput "$narrator" 100)
  publisher=$(validateInput "$publisher" 100)
  asin=$(validateInput "$asin" 20)
  duration=$(validateInput "$duration" 50)
  rating=$(validateInput "$rating" 10)
  
  bookNarrators[$book_index]="$narrator"
  bookPublishers[$book_index]="$publisher"
  bookASINs[$book_index]="$asin"
  bookDurations[$book_index]="$duration"
  bookRatings[$book_index]="$rating"
  
  logMessage "DEBUG" "Additional metadata parsed for book $book_index"
  return 0
}

# Extract cover art URL
extractCoverArt()
{
  local html_file="$1"
  local book_index="$2"
  
  local cover_url=""
  
  if [[ ! -f "$html_file" ]]; then
    logMessage "ERROR" "HTML file not found: $html_file"
    return 1
  fi
  
  # Try various patterns for cover image
  cover_url=$(grep -i 'property="og:image"' "$html_file" | head -1 | sed 's/.*content="\([^"]*\)".*/\1/')
  
  if [[ -z "$cover_url" ]]; then
    cover_url=$(grep -i '"image".*"url"' "$html_file" | head -1 | sed 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
  fi
  
  if [[ -z "$cover_url" ]]; then
    cover_url=$(grep -i 'class=".*cover.*"' "$html_file" | grep -o 'src="[^"]*"' | head -1 | sed 's/src="\([^"]*\)".*/\1/')
  fi
  
  # Validate and store cover URL
  if [[ -n "$cover_url" ]]; then
    if validateURL "$cover_url"; then
      bookCovers[$book_index]="$cover_url"
      logMessage "INFO" "Cover art URL found: $cover_url"
      return 0
    fi
  fi
  
  logMessage "DEBUG" "No cover art URL found"
  bookCovers[$book_index]=""
  return 1
}

##
## High-Level Orchestration Functions
##

# Initialize parser module
initializeParser()
{
  logMessage "INFO" ">>> Initializing parser module..."
  
  # Validate dependencies
  local missing_deps=()
  
  # Initialize temporary file paths
  tempHtmlFile=$(mktemp "${tmpDir:-/tmp}/ccab.html.XXXXXX")
  tempInfoFile=$(mktemp "${tmpDir:-/tmp}/ccab.info.XXXXXX")
  tempRichFile=$(mktemp "${tmpDir:-/tmp}/ccab.rich.XXXXXX")
  
  # Set up cleanup for temporary files
  trap 'rm -f "$tempHtmlFile" "$tempInfoFile" "$tempRichFile" 2>/dev/null' EXIT
  
  logMessage "INFO" ">>> Parser module initialized successfully"
  return 0
}

# Search and parse book information
searchAndParseBook()
{
  local search_query="$1"
  local interactive="${2:-true}"
  
  logMessage "INFO" "Starting book search and parse for: $search_query"
  
  # Perform search
  local search_results
  search_results=$(searchBooks "$search_query" 5)
  
  if [[ -z "$search_results" ]]; then
    logMessage "ERROR" "No search results found"
    return 1
  fi
  
  # Present results to user (if interactive)
  local selected_url=""
  if [[ "$interactive" == "true" ]]; then
    selected_url=$(presentSearchResults "$search_results")
  else
    # Auto-select first result
    selected_url=$(echo "$search_results" | jq -r '.link' | head -1)
  fi
  
  if [[ -z "$selected_url" ]]; then
    logMessage "ERROR" "No URL selected"
    return 1
  fi
  
  # Download and parse book page
  if ! downloadBookPage "$selected_url" "$tempHtmlFile"; then
    logMessage "ERROR" "Failed to download book page"
    return 1
  fi
  
  # Extract structured information
  extractRichProductInfo "$tempHtmlFile" "$tempRichFile"
  local page_title
  page_title=$(extractPageTitle "$tempHtmlFile")
  
  # Parse book metadata
  local book_index=${#bookTitles[@]}
  
  parseBookTitle "$tempRichFile" "$page_title" "$book_index"
  parseBookAuthor "$tempRichFile" "$tempHtmlFile" "$book_index"
  parseBookSeries "$tempRichFile" "${bookTitles[$book_index]}" "$book_index"
  parseAdditionalMetadata "$tempRichFile" "$tempHtmlFile" "$book_index"
  extractCoverArt "$tempHtmlFile" "$book_index"
  
  logMessage "INFO" "Book parsing completed for index $book_index"
  return 0
}

# Present search results to user for selection
presentSearchResults()
{
  local search_results="$1"
  
  echo -e "${C2}>>> Search Results:${C0}"
  echo
  
  local count=1
  local urls=()
  
  # Display results
  while IFS= read -r result; do
    if [[ -n "$result" ]]; then
      local title link
      title=$(echo "$result" | jq -r '.title // "No title"')
      link=$(echo "$result" | jq -r '.link // ""')
      
      if [[ -n "$link" ]]; then
        urls+=("$link")
        echo -e "${C3}$count.${C0} $title"
        echo -e "   ${C7}$link${C0}"
        echo
        ((count++))
      fi
    fi
  done <<< "$search_results"
  
  if [[ ${#urls[@]} -eq 0 ]]; then
    logMessage "ERROR" "No valid URLs found in search results"
    return 1
  fi
  
  # Get user selection
  local selection=""
  while [[ ! "$selection" =~ ^[1-9][0-9]*$ ]] || [[ $selection -gt ${#urls[@]} ]]; do
    echo -n "Select a result (1-${#urls[@]}): "
    read -r selection
    
    if [[ "$selection" =~ ^[1-9][0-9]*$ ]] && [[ $selection -le ${#urls[@]} ]]; then
      break
    fi
    
    echo -e "${C1}Invalid selection. Please choose 1-${#urls[@]}.${C0}"
  done
  
  echo "${urls[$((selection-1))]}"
  return 0
}

# Get parsed book information
getBookInfo()
{
  local book_index="$1"
  
  if [[ $book_index -ge ${#bookTitles[@]} ]]; then
    logMessage "ERROR" "Invalid book index: $book_index"
    return 1
  fi
  
  # Return structured book information
  cat << EOF
{
  "title": "${bookTitles[$book_index]:-}",
  "author": "${bookAuthors[$book_index]:-}",
  "series": "${bookSeries[$book_index]:-}",
  "series_number": "${bookSeriesNumbers[$book_index]:-}",
  "narrator": "${bookNarrators[$book_index]:-}",
  "publisher": "${bookPublishers[$book_index]:-}",
  "asin": "${bookASINs[$book_index]:-}",
  "duration": "${bookDurations[$book_index]:-}",
  "rating": "${bookRatings[$book_index]:-}",
  "cover_url": "${bookCovers[$book_index]:-}"
}
EOF
  
  return 0
}

# Get number of parsed books
getBookCount()
{
  echo "${#bookTitles[@]}"
}

# Clear all parsed book data
clearBookData()
{
  bookTitles=()
  bookAuthors=()
  bookSeries=()
  bookSeriesNumbers=()
  bookNarrators=()
  bookPublishers=()
  bookGenres=()
  bookCovers=()
  bookDescriptions=()
  bookASINs=()
  bookDurations=()
  bookRatings=()
  
  logMessage "DEBUG" "Book data cleared"
}

# Export functions for use by other modules
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  # Script is being sourced
  export -f searchBooks
  export -f downloadBookPage
  export -f extractRichProductInfo
  export -f extractPageTitle
  export -f parseBookTitle
  export -f parseBookAuthor
  export -f parseBookSeries
  export -f parseAdditionalMetadata
  export -f extractCoverArt
  export -f initializeParser
  export -f searchAndParseBook
  export -f presentSearchResults
  export -f getBookInfo
  export -f getBookCount
  export -f clearBookData
fi