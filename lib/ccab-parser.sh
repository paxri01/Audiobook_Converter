#!/bin/bash
#shellcheck disable=SC2004
#shellcheck disable=SC2034
#shellcheck disable=SC2154

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
CCAB_PARSER_MODULE="ccab-parser"
CCAB_PARSER_VERSION="4.0"

# Parser configuration variables
declare -g SEARCH_RETRIES=2
declare -g SEARCH_TIMEOUT=15
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
  {
  local search_query="$1"
  local max_results="${2:-5}"
  local retry_count=0
  
  logMessage "INFO" "Searching for: $search_query"
  echo -e "${C6}>>> Checking API credentials...${C0}" >&2
  
  # Skip validation for debugging - potential hang source
  echo -e "${C6}>>> Skipping input validation for debugging...${C0}" >&2
  # search_query=$(validateInput "$search_query" 200)
  if [[ -z "$search_query" ]]; then
    logMessage "ERROR" "Invalid or empty search query"
    return 1
  fi
  
  # Check for required API credentials
  echo -e "${C6}>>> Looking for API keys file at: $HOME/.config/keys${C0}" >&2
  if [[ ! -f "$HOME/.config/keys" ]]; then
    logMessage "ERROR" "API keys file not found: $HOME/.config/keys"
    logMessage "INFO" "Please create $HOME/.config/keys with your Google Custom Search API credentials:"
    logMessage "INFO" "  _engine_id=\"your_search_engine_id\""
    logMessage "INFO" "  _api_key=\"your_google_api_key\""
    return 1
  fi
  
  # Source API credentials
  echo -e "${C6}>>> Loading API credentials...${C0}" >&2
  #shellcheck disable=SC1091
  if ! source "$HOME/.config/keys"; then
    logMessage "ERROR" "Failed to load API credentials from $HOME/.config/keys"
    logMessage "INFO" "Please check that the file is readable and contains valid bash syntax"
    return 1
  fi
  
  # Validate API credentials
  echo -e "${C6}>>> API credentials loaded, validating...${C0}" >&2
  if [[ -z "${_engine_id:-}" || -z "${_api_key:-}" ]]; then
    logMessage "ERROR" "Missing required API credentials in $HOME/.config/keys"
    logMessage "INFO" "Required variables:"
    logMessage "INFO" "  _engine_id=\"your_search_engine_id\""
    logMessage "INFO" "  _api_key=\"your_google_api_key\""
    return 1
  fi
  
  # Basic validation of API key format
  if [[ ! "${_api_key}" =~ ^[A-Za-z0-9_-]{35,45}$ ]]; then
    logMessage "WARN" "API key format appears invalid (should be 35-45 alphanumeric characters)"
  fi
  
  if [[ ! "${_engine_id}" =~ ^[a-f0-9]{12}:[a-f0-9]{11}$ ]] && [[ ! "${_engine_id}" =~ ^[0-9a-z_-]{10,30}$ ]]; then
    logMessage "WARN" "Engine ID format appears invalid"
  fi
  
  # URL encode the search query - simplified for debugging
  echo -e "${C6}>>> URL encoding search query...${C0}" >&2
  local encoded_query
  encoded_query="${search_query// /+}"  # Simple space replacement instead of full encoding
  echo -e "${C6}>>> Encoded query: $encoded_query${C0}" >&2
  
  # Construct search URL
  echo -e "${C6}>>> Constructing search URL...${C0}" >&2
  local search_url="https://www.googleapis.com/customsearch/v1"
  search_url+="?key=$_api_key"
  search_url+="&cx=$_engine_id"
  search_url+="&q=$encoded_query"
  search_url+="&num=$max_results"
  search_url+="&fields=items(title,link,snippet)"
  echo -e "${C6}>>> Search URL ready${C0}" >&2
  
  # Perform search with retries and enhanced timeout handling
  echo -e "${C6}>>> Starting search retry loop...${C0}" >&2
  local search_results=""
  while [[ $retry_count -lt $SEARCH_RETRIES ]]; do
    echo -e "${C6}>>> Search attempt $((retry_count + 1))/$SEARCH_RETRIES${C0}" >&2
    logMessage "DEBUG" "Search attempt $((retry_count + 1))/$SEARCH_RETRIES"
    logMessage "DEBUG" "Search URL: $search_url"
    
    # Use timeout command as additional safeguard
    echo -e "${C6}>>> Executing curl request...${C0}" >&2
    search_results=$(timeout "$SEARCH_TIMEOUT" curl -s \
      --max-time "$SEARCH_TIMEOUT" \
      --connect-timeout 10 \
      --max-filesize "$MAX_DOWNLOAD_SIZE" \
      --user-agent "CCAB/4.0 (AudiobookConverter)" \
      "$search_url" 2>/dev/null)
    local curl_exit_code=$?
    echo -e "${C6}>>> Curl request completed with exit code: $curl_exit_code${C0}" >&2
    logMessage "DEBUG" "Curl exit code: $curl_exit_code"
    
    echo -e "${C6}>>> Checking curl results...${C0}" >&2
    
    if [[ $curl_exit_code -eq 0 && -n "$search_results" && "$search_results" =~ \"items\" ]]; then
      echo -e "${C6}>>> Search successful with results${C0}" >&2
      logMessage "DEBUG" "Search successful with results"
      break
    elif [[ $curl_exit_code -eq 124 ]]; then
      echo -e "${C6}>>> Search timed out${C0}" >&2
      logMessage "WARN" "Search timed out after ${SEARCH_TIMEOUT}s"
    elif [[ $curl_exit_code -eq 22 ]]; then
      echo -e "${C6}>>> HTTP error${C0}" >&2
      logMessage "WARN" "HTTP error (possibly rate limited or invalid request)"
    else
      echo -e "${C6}>>> Search failed${C0}" >&2
      logMessage "WARN" "Search failed with exit code $curl_exit_code"
    fi
    
    ((retry_count++))
    if [[ $retry_count -lt $SEARCH_RETRIES ]]; then
      logMessage "DEBUG" "Waiting 2 seconds before retry..."
      sleep 2
    fi
  done
  
  echo -e "${C6}>>> Exiting search retry loop${C0}" >&2
  if [[ -z "$search_results" || ! "$search_results" =~ \"items\" ]]; then
    echo -e "${C6}>>> Search failed after retries${C0}" >&2
    logMessage "ERROR" "Search failed after $SEARCH_RETRIES attempts"
    return 1
  fi
  
  # Debug: Check if we have valid JSON
  echo -e "${C6}>>> Validating JSON response${C0}" >&2
  if ! echo "$search_results" | jq empty 2>/dev/null; then
    echo -e "${C6}>>> Invalid JSON received${C0}" >&2
    logMessage "ERROR" "Invalid JSON received from Google Custom Search API"
    logMessage "DEBUG" "Raw API response (first 500 chars): ${search_results:0:500}"
    return 1
  fi
  echo -e "${C6}>>> JSON validation passed${C0}" >&2
  
  # Validate and filter results
  echo -e "${C6}>>> Filtering search results${C0}" >&2
  local filtered_results
  filtered_results=$(echo "$search_results" | jq -r '.items[]? | select(.link | test("(amazon\\.com|goodreads\\.com|audible\\.com)")) | {title: .title, link: .link, snippet: .snippet}' 2>/dev/null)
  echo -e "${C6}>>> Filtering completed${C0}" >&2
  
  if [[ -z "$filtered_results" ]]; then
    echo -e "${C6}>>> No filtered results found${C0}" >&2
    logMessage "WARN" "No valid results found from allowed sources"
    logMessage "DEBUG" "Raw search results: $search_results"
    # Try to extract any results without filtering
    local any_results
    any_results=$(echo "$search_results" | jq -r '.items[]? | {title: .title, link: .link, snippet: .snippet}' 2>/dev/null)
    if [[ -n "$any_results" ]]; then
      logMessage "INFO" "Found results but none from allowed sources (Amazon, Goodreads, Audible)"
      echo "$any_results"
      return 0
    fi
    return 1
  fi
  
  echo -e "${C6}>>> Returning filtered results${C0}" >&2
  } >&2  # Send all debug output to stderr
  echo "$filtered_results"  # Only this goes to stdout
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
  local temp_base_dir="${tmpDir:-/tmp}"
  temp_base_dir="${temp_base_dir%/}"  # Remove trailing slash
  temp_html_file=$(mktemp "${temp_base_dir}/ccab.scrape.XXXXXX")
  
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
      # Extract only the primary author, removing co-authors
      local primary_author
      primary_author=$(extractPrimaryAuthor "$author")
      bookAuthors[$book_index]="$primary_author"
      logMessage "INFO" "Parsed primary author: $primary_author (from: $author)"
      return 0
    fi
  fi
  
  logMessage "WARN" "Could not parse book author"
  bookAuthors[$book_index]="Unknown Author"
  return 1
}

# Extract primary author only (remove co-authors)
extractPrimaryAuthor()
{
  local author_string="$1"
  local primary_author=""
  
  if [[ -z "$author_string" ]]; then
    echo ""
    return 1
  fi
  
  # Remove co-authors using common separators
  # Handles: "Author1 & Author2", "Author1 and Author2", "Author1, Author2", "Author1 with Author2"
  # Also handles "Author1; Author2" and "Author1 | Author2"
  primary_author=$(echo "$author_string" | sed -E 's/[[:space:]]*(&|and|,|with|;|\|)[[:space:]].*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  
  # If the result is empty, return the original
  if [[ -z "$primary_author" ]]; then
    primary_author="$author_string"
  fi
  
  echo "$primary_author"
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
  local temp_base_dir="${tmpDir:-/tmp}"
  temp_base_dir="${temp_base_dir%/}"  # Remove trailing slash
  tempHtmlFile=$(mktemp "${temp_base_dir}/ccab.html.XXXXXX")
  tempInfoFile=$(mktemp "${temp_base_dir}/ccab.info.XXXXXX")
  tempRichFile=$(mktemp "${temp_base_dir}/ccab.rich.XXXXXX")
  
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
  
  # Search loop to handle new search requests
  local current_search="$search_query"
  local selected_url=""
  
  while [[ -z "$selected_url" ]]; do
    # Perform search with progress indication
    echo -e "${C6}>>> Performing Google search (timeout: ${SEARCH_TIMEOUT}s)...${C0}"
    local search_results
    echo -e "${C6}>>> Calling searchBooks function...${C0}" >&2
    if ! search_results=$(searchBooks "$current_search" 5); then
      echo -e "${C6}>>> searchBooks function failed${C0}" >&2
      logMessage "ERROR" "Search timed out or failed for: $current_search"
      if [[ "$interactive" == "true" ]]; then
        echo -e "${C3}>>> Search failed. Options:${C0}"
        echo -e "${C3}>>> 1. Try a different search term${C0}"
        echo -e "${C3}>>> 2. Manually provide book.html file${C0}"
        echo -n "Enter new search term (or press Enter to give up): "
        read -r new_search
        if [[ -n "$new_search" ]]; then
          current_search="$new_search"
          continue
        fi
      fi
      return 1
    fi
    
    echo -e "${C6}>>> searchBooks function returned successfully${C0}" >&2
    if [[ -z "$search_results" ]]; then
      echo -e "${C6}>>> Search results are empty${C0}" >&2
      logMessage "ERROR" "No search results found for: $current_search"
      if [[ "$interactive" == "true" ]]; then
        echo -n "Try different search term? Enter new term (or press Enter to give up): "
        read -r new_search
        if [[ -n "$new_search" ]]; then
          current_search="$new_search"
          continue
        fi
      fi
      return 1
    fi
    
    echo -e "${C6}>>> Search results received, preparing to present${C0}" >&2
    # Present results to user (if interactive)
    if [[ "$interactive" == "true" ]]; then
      echo -e "${C6}>>> Calling presentSearchResults...${C0}" >&2
      local user_selection
      user_selection=$(presentSearchResults "$search_results")
      local selection_result=$?
      
      if [[ $selection_result -eq 2 ]]; then
        # User requested new search
        current_search="${user_selection#SEARCH:}"
        logMessage "INFO" "Performing new search with: $current_search"
        continue
      elif [[ $selection_result -eq 0 ]]; then
        selected_url="$user_selection"
      else
        logMessage "ERROR" "Failed to get user selection"
        return 1
      fi
    else
      # Auto-select first result
      selected_url=$(echo "$search_results" | jq -r '.link' | head -1)
    fi
  done
  
  if [[ -z "$selected_url" ]]; then
    logMessage "ERROR" "No URL selected"
    return 1
  fi
  
  # Check for existing book.html file first
  local html_source=""
  if [[ -f "/tmp/book.html" ]]; then
    logMessage "INFO" "Using provided book.html file"
    mv "/tmp/book.html" "$tempHtmlFile"
    html_source="provided"
  else
    # Attempt automatic download first
    logMessage "INFO" "Attempting automatic download of: $selected_url"
    if downloadBookPage "$selected_url" "$tempHtmlFile"; then
      html_source="automatic"
    else
      # Automatic download failed - prompt for manual download
      if [[ "$interactive" == "true" ]]; then
        echo
        echo -e "${C3}>>> Automatic download failed (likely due to CAPTCHA protection)${C0}"
        echo -e "${C3}>>> Manual download required:${C0}"
        echo -e "${C3}>>> 1. Open this URL in your web browser:${C0}"
        echo -e "${C3}>>>    $selected_url${C0}"
        echo -e "${C3}>>> 2. Save the complete webpage as HTML file${C0}"
        echo -e "${C3}>>> 3. Copy the file to: /tmp/book.html${C0}"
        echo
        echo -n "Press Enter when you have saved the file..."
        read -r
        
        # Check if user saved the file
        if [[ -f "/tmp/book.html" ]]; then
          mv "/tmp/book.html" "$tempHtmlFile"
          mv "/tmp/book.html" "$workDir/book.html"  # Keep for reference
          html_source="manual"
          logMessage "INFO" "Using manually downloaded book.html file"
        else
          logMessage "ERROR" "No book.html file found at /tmp/book.html"
          return 1
        fi
      else
        logMessage "ERROR" "Failed to download book page and not in interactive mode"
        return 1
      fi
    fi
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
  
  echo -e "${C2}>>> Search Results:${C0}" >&2
  echo >&2
  
  local count=1
  local urls=()
  
  # Parse JSON results properly - each result is a complete JSON object
  local json_objects
  json_objects=$(echo "$search_results" | jq -c '.' 2>/dev/null)
  
  while IFS= read -r result; do
    if [[ -n "$result" && "$result" =~ ^\{.*\}$ ]]; then
      local title link
      # Safely parse JSON with error handling
      if ! title=$(echo "$result" | jq -r '.title // "No title"' 2>/dev/null); then
        title="Unknown Title"
      fi
      
      if ! link=$(echo "$result" | jq -r '.link // ""' 2>/dev/null); then
        continue
      fi
      
      if [[ -n "$link" ]]; then
        urls+=("$link")
        echo -e "${C3}$count.${C0} $title" >&2
        echo -e "   ${C8}$link${C0}" >&2
        echo >&2
        ((count++))
      fi
    fi
  done <<< "$json_objects"
  
  if [[ ${#urls[@]} -eq 0 ]]; then
    logMessage "ERROR" "No valid URLs found in search results"
    logMessage "DEBUG" "Raw search results: $search_results"
    echo -e "${C1}>>> No valid search results found from Amazon, Goodreads, or Audible${C0}" >&2
    echo -e "${C3}Options:${C0}" >&2
    echo -e "${C3}  0: Enter a manual URL${C0}" >&2
    echo -e "${C3}  s: Search again with different criteria${C0}" >&2
    echo >&2
    
    local selection=""
    while true; do
      echo -n "Your choice: " >&2
      read -r selection
      
      # Handle manual URL entry
      if [[ "$selection" == "0" ]]; then
        echo -n "Enter the book URL: " >&2
        read -r manual_url
        if [[ -n "$manual_url" ]]; then
          echo "$manual_url"
          return 0
        else
          echo -e "${C1}No URL entered. Please try again.${C0}" >&2
        fi
      # Handle new search
      elif [[ "$selection" =~ ^[Ss]$ ]]; then
        echo -n "Enter new search terms: " >&2
        read -r new_search
        if [[ -n "$new_search" ]]; then
          echo "SEARCH:$new_search"
          return 2
        else
          echo -e "${C1}No search terms entered. Please try again.${C0}" >&2
        fi
      else
        echo -e "${C1}Invalid selection. Please choose 0 or s.${C0}" >&2
      fi
    done
  fi
  # Enhanced user selection with additional options
  echo -e "${C3}Options:${C0}" >&2
  echo -e "${C3}  1-${#urls[@]}: Select from search results above${C0}" >&2
  echo -e "${C3}  0: Enter a manual URL${C0}" >&2
  echo -e "${C3}  s: Search again with different criteria${C0}" >&2
  echo >&2
  
  local selection=""
  while true; do
    echo -n "Your choice: " >&2
    read -r selection
    
    # Handle numeric selections
    if [[ "$selection" =~ ^[1-9][0-9]*$ ]] && [[ $selection -le ${#urls[@]} ]]; then
      echo "${urls[$((selection-1))]}"
      return 0
    # Handle manual URL entry
    elif [[ "$selection" == "0" ]]; then
      echo -n "Enter the book URL: " >&2
      read -r manual_url
      if [[ -n "$manual_url" ]]; then
        echo "$manual_url"
        return 0
      else
        echo -e "${C1}No URL entered. Please try again.${C0}" >&2
      fi
    # Handle new search
    elif [[ "$selection" =~ ^[Ss]$ ]]; then
      echo -n "Enter new search terms: " >&2
      read -r new_search
      if [[ -n "$new_search" ]]; then
        # Return special code to indicate new search requested
        echo "SEARCH:$new_search"
        return 2
      else
        echo -e "${C1}No search terms entered. Please try again.${C0}" >&2
      fi
    else
      echo -e "${C1}Invalid selection. Please choose 1-${#urls[@]}, 0, or s.${C0}" >&2
    fi
  done
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
  export -f extractPrimaryAuthor
  export -f searchAndParseBook
  export -f presentSearchResults
  export -f getBookInfo
  export -f getBookCount
  export -f clearBookData
fi
