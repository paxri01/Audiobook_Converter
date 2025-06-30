#!/bin/bash
#shellcheck disable=SC2004

## ========================================================================================
##       Title: ccab-webscraper.sh
##      Author: R. L. Paxton
##     Version: 4.0
##        Date: 2025-06-20
##     License: Apache 2.0
## Description: Web scraping module for ccab audiobook converter
##              Specialized HTML parsing for Amazon, Goodreads, and Audible pages
## ========================================================================================

# Module identification
#shellcheck disable=SC2034
CCAB_WEBSCRAPER_MODULE="ccab-webscraper"
#shellcheck disable=SC2034
CCAB_WEBSCRAPER_VERSION="4.0"

# Scraping configuration
#shellcheck disable=SC2034
declare -g SCRAPER_DEBUG="${SCRAPER_DEBUG:-false}"
#shellcheck disable=SC2034
declare -g MAX_EXTRACT_SIZE=10000

# Extracted data structure
declare -ga SCRAPED_TITLES=()
declare -ga SCRAPED_AUTHORS=()
declare -ga SCRAPED_NARRATORS=()
declare -ga SCRAPED_SERIES=()
declare -ga SCRAPED_SERIES_NUMBERS=()
declare -ga SCRAPED_PUBLISHERS=()
declare -ga SCRAPED_DURATIONS=()
declare -ga SCRAPED_RELEASE_DATES=()
declare -ga SCRAPED_ASINS=()
declare -ga SCRAPED_LANGUAGES=()
declare -ga SCRAPED_RATINGS=()
declare -ga SCRAPED_COVER_URLS=()
declare -ga SCRAPED_DESCRIPTIONS=()

##
## Site Detection Functions
##

# Detect which site type based on HTML content
detectSiteType()
{
  local html_file="$1"
  
  if [[ ! -f "$html_file" ]]; then
    logMessage "ERROR" "HTML file not found: $html_file"
    return 1
  fi
  
  # Check for Amazon
  if grep -q "amazon\.com" "$html_file" && grep -q "richProductInformation" "$html_file"; then
    echo "amazon"
    return 0
  fi
  
  # Check for Goodreads
  if grep -q "goodreads\.com" "$html_file" || grep -q "gr-book" "$html_file"; then
    echo "goodreads"
    return 0
  fi
  
  # Check for Audible
  if grep -q "audible\.com" "$html_file" || grep -q "adbl-" "$html_file"; then
    echo "audible"
    return 0
  fi
  
  # Default to Amazon if uncertain but has rich info
  if grep -q "rich.*product.*information" "$html_file"; then
    echo "amazon"
    return 0
  fi
  
  logMessage "WARN" "Could not detect site type"
  echo "unknown"
  return 1
}

##
## Amazon-specific Parsing Functions
##

# Extract metadata from Amazon's rich product information
extractAmazonRichInfo()
{
  local html_file="$1"
  local output_index="$2"
  
  logMessage "DEBUG" "Extracting Amazon rich product information"
  
  # Extract title from meta tag first
  local title=""
  title=$(grep -i 'name="title"' "$html_file" | sed 's/.*content="\([^"]*\)".*/\1/' | sed 's/&amp;/\&/g' | sed 's/Amazon\.com: //' | sed 's/ (Audible Audio Edition).*//')
  
  if [[ -z "$title" ]]; then
    title=$(grep -i '<title>' "$html_file" | sed 's/<[^>]*>//g' | sed 's/Amazon\.com: //' | sed 's/ (Audible Audio Edition).*//')
  fi
  
  SCRAPED_TITLES[$output_index]="$title"
  logMessage "DEBUG" "Extracted title: $title"
  
  # Extract data from rich product information carousel
  local rich_section=""
  rich_section=$(sed -n '/richProductInformation/,/rich_product_information-learn_more_section/p' "$html_file")
  
  # Normalize HTML for better parsing if hxnormalize is available
  if command -v hxnormalize &> /dev/null && [[ -n "$rich_section" ]]; then
    local temp_rich_file
    temp_rich_file=$(mktemp "${tmpDir:-/tmp}/ccab.rich.XXXXXX")
    echo "$rich_section" | hxnormalize -x -e -l 240 > "$temp_rich_file" 2>/dev/null
    if [[ -s "$temp_rich_file" ]]; then
      rich_section=$(cat "$temp_rich_file")
      logMessage "DEBUG" "HTML normalized for better parsing"
    fi
    rm -f "$temp_rich_file"
  fi
  
  if [[ -n "$rich_section" ]]; then
    # Extract series information
    local series_info=""
    series_info=$(echo "$rich_section" | grep -A10 'book_details-series' | grep -o 'Book [0-9]* of [0-9]*' | head -1)
    if [[ -n "$series_info" ]]; then
      local series_num=""
      #shellcheck disable=SC2001
      series_num=$(echo "$series_info" | sed 's/Book \([0-9]*\) of [0-9]*/\1/')
      SCRAPED_SERIES_NUMBERS[$output_index]=$(printf "%02d" "$series_num" 2>/dev/null || echo "01")
    fi
    
    # Extract series name from title or rich info
    local series_name=""
    series_name=$(echo "$rich_section" | grep -A5 'rpi-attribute-value' | grep -o '<span>[^<]*</span>' | sed 's/<[^>]*>//g' | head -1)
    if [[ -z "$series_name" ]]; then
      # Try to extract from title
      if [[ "$title" =~ (.+)[,:]?[[:space:]]*(Book|book)[[:space:]]*[0-9]+ ]]; then
        series_name="${BASH_REMATCH[1]}"
      fi
    fi
    SCRAPED_SERIES[$output_index]="$series_name"
    
    # Extract listening length/duration
    local duration=""
    duration=$(echo "$rich_section" | grep -A5 'listening_length' | grep -o '[0-9]* hours and [0-9]* minutes' | head -1)
    if [[ -z "$duration" ]]; then
      duration=$(echo "$rich_section" | grep -A5 'listening_length' | grep -o '[0-9]*:[0-9]*:[0-9]*' | head -1)
    fi
    SCRAPED_DURATIONS[$output_index]="$duration"
    
    # Extract author information - improved generic pattern
    local author=""
    
    # First try: Extract from popover inline content (most reliable)
    author=$(echo "$rich_section" | grep -A10 'audiobook_details-author' | grep -o '"inlineContent":"[^"]*"' | sed 's/"inlineContent":"//' | sed 's/"$//' | sed 's/\\u003c[^>]*\\u003e//g' | sed 's/&quot;.*$//' | head -1)
    
    # Second try: Extract from href search URLs (fallback)
    if [[ -z "$author" ]]; then
      local author_section
      author_section=$(echo "$rich_section" | sed -n '/audiobook_details-author/,/\/li>/p')
      author=$(echo "$author_section" | grep -o 'href="/s?k=[^"&]*' | sed 's/.*k=//' | sed 's/%20/ /g' | sed 's/&.*//' | grep -v '^[[:space:]]*$' | head -1)
    fi
    
    # Third try: Extract actual name from span tags, excluding labels
    if [[ -z "$author" ]]; then
      local author_section
      author_section=$(echo "$rich_section" | sed -n '/audiobook_details-author/,/\/li>/p')
      author=$(echo "$author_section" | grep -o '<span>[^<]*</span>' | sed 's/<[^>]*>//g' | grep -v '^[[:space:]]*$' | grep -v -i 'author' | grep -v 'see all' | head -1)
    fi
    
    # Fourth try: Look for patterns like "Edgar Riggs, see all"
    if [[ -z "$author" ]]; then
      author=$(echo "$rich_section" | sed -n '/audiobook_details-author/,/\/li>/p' | grep -o '[A-Z][a-z]* [A-Z][a-z]*' | head -1)
    fi
    
    SCRAPED_AUTHORS[$output_index]="$author"
    
    # Extract narrator information - improved generic pattern
    local narrator=""
    
    # First try: Extract from popover inline content (most reliable)
    narrator=$(echo "$rich_section" | grep -A10 'audiobook_details-narrator' | grep -o '"inlineContent":"[^"]*"' | sed 's/"inlineContent":"//' | sed 's/"$//' | sed 's/\\u003c[^>]*\\u003e//g' | sed 's/&quot;.*$//' | head -1)
    
    # Second try: Extract from href search URLs (fallback)
    if [[ -z "$narrator" ]]; then
      local narrator_section
      narrator_section=$(echo "$rich_section" | sed -n '/audiobook_details-narrator/,/\/li>/p')
      narrator=$(echo "$narrator_section" | grep -o 'href="/s?k=[^"&]*' | sed 's/.*k=//' | sed 's/%20/ /g' | sed 's/&.*//' | grep -v '^[[:space:]]*$' | head -1)
    fi
    
    # Third try: Extract actual name from span tags, excluding labels
    if [[ -z "$narrator" ]]; then
      local narrator_section
      narrator_section=$(echo "$rich_section" | sed -n '/audiobook_details-narrator/,/\/li>/p')
      narrator=$(echo "$narrator_section" | grep -o '<span>[^<]*</span>' | sed 's/<[^>]*>//g' | grep -v '^[[:space:]]*$' | grep -v -i 'narrator' | grep -v 'see all' | head -1)
    fi
    
    # Fourth try: Look for patterns like "Richard Brock, see all"
    if [[ -z "$narrator" ]]; then
      narrator=$(echo "$rich_section" | sed -n '/audiobook_details-narrator/,/\/li>/p' | grep -o '[A-Z][a-z]* [A-Z][a-z]*' | head -1)
    fi
    
    SCRAPED_NARRATORS[$output_index]="$narrator"
    
    # Extract release date
    local release_date=""
    release_date=$(echo "$rich_section" | grep -A5 'release-date' | grep -o '[A-Za-z]* [0-9]*, [0-9]*' | head -1)
    SCRAPED_RELEASE_DATES[$output_index]="$release_date"
    
    # Extract language
    local language=""
    language=$(echo "$rich_section" | grep -A5 'audiobook_details-language' | grep -o '<span>[^<]*</span>' | sed 's/<[^>]*>//g' | grep -v '^[[:space:]]*$' | head -1)
    SCRAPED_LANGUAGES[$output_index]="$language"
    
    # Extract publisher - generic pattern
    local publisher=""
    
    # First try: Extract from structured attribute value
    publisher=$(echo "$rich_section" | sed -n '/audiobook_details-publisher/,/\/li>/p' | grep -o '<span>[^<]*</span>' | sed 's/<[^>]*>//g' | grep -v '^[[:space:]]*$' | tail -1)
    
    # Second try: Extract from href URLs and decode
    if [[ -z "$publisher" ]]; then
      publisher=$(echo "$rich_section" | grep -o 'href="/s?k=[^"&]*' | grep -i publisher | sed 's/.*k=//' | sed 's/%20/ /g' | sed 's/&.*//' | head -1)
    fi
    
    # Third try: Look for any text content between publisher tags
    if [[ -z "$publisher" ]]; then
      publisher=$(echo "$rich_section" | sed -n '/audiobook_details-publisher/,/rpi-attribute-value/p' | grep -o '>[^<>]*<' | sed 's/[><]//g' | grep -v '^[[:space:]]*$' | grep -v 'Publisher' | head -1)
    fi
    
    SCRAPED_PUBLISHERS[$output_index]="$publisher"
    
    # Extract ASIN - improved pattern
    local asin=""
    asin=$(echo "$rich_section" | sed -n '/book_details-asin/,/\/li>/p' | grep -o '>B[A-Z0-9]*<' | sed 's/[><]//g' | head -1)
    if [[ -z "$asin" ]]; then
      asin=$(echo "$rich_section" | sed -n '/book_details-asin/,/rpi-attribute-value/p' | grep -o '<span>B[A-Z0-9]*</span>' | sed 's/<[^>]*>//g' | head -1)
    fi
    SCRAPED_ASINS[$output_index]="$asin"
  fi
  
  # Extract cover image URL
  local cover_url=""
  cover_url=$(grep -i 'property="og:image"' "$html_file" | sed 's/.*content="\([^"]*\)".*/\1/' | head -1)
  SCRAPED_COVER_URLS[$output_index]="$cover_url"
  
  # Extract description
  local description=""
  description=$(grep -A20 'feature-bullets' "$html_file" | grep -o '<span[^>]*>[^<]*</span>' | sed 's/<[^>]*>//g' | tr '\n' ' ' | head -c 500)
  SCRAPED_DESCRIPTIONS[$output_index]="$description"
  
  logMessage "DEBUG" "Amazon extraction completed for index $output_index"
  return 0
}

# Parse Amazon page format (new structure)
parseAmazonFormat()
{
  local html_file="$1"
  local output_index="${2:-0}"
  
  logMessage "INFO" "Parsing Amazon format page"
  
  # Use the rich info extraction
  extractAmazonRichInfo "$html_file" "$output_index"
  
  # Additional Amazon-specific extractions
  
  # Try alternative title extraction if needed
  if [[ -z "${SCRAPED_TITLES[$output_index]}" ]]; then
    local alt_title=""
    alt_title=$(grep -i '<title>' "$html_file" | sed 's/<[^>]*>//g' | sed 's/Amazon\.com: //' | sed 's/ |.*//' | head -c 200)
    SCRAPED_TITLES[$output_index]="$alt_title"
  fi
  
  # Try alternative author extraction
  if [[ -z "${SCRAPED_AUTHORS[$output_index]}" ]]; then
    local alt_author=""
    alt_author=$(grep -i 'by:' "$html_file" | sed 's/.*by:[[:space:]]*//' | sed 's/<.*//' | head -1)
    SCRAPED_AUTHORS[$output_index]="$alt_author"
  fi
  
  logMessage "INFO" "Amazon format parsing completed"
  return 0
}

##
## Goodreads-specific Parsing Functions
##

# Parse Goodreads page format
parseGoodreadsFormat()
{
  local html_file="$1"
  local output_index="${2:-0}"
  
  logMessage "INFO" "Parsing Goodreads format page"
  
  # Extract title
  local title=""
  title=$(grep -i 'property="og:title"' "$html_file" | sed 's/.*content="\([^"]*\)".*/\1/' | head -1)
  if [[ -z "$title" ]]; then
    title=$(grep -i '<title>' "$html_file" | sed 's/<[^>]*>//g' | sed 's/ by .*//' | head -1)
  fi
  SCRAPED_TITLES[$output_index]="$title"
  
  # Extract author
  local author=""
  author=$(grep -i 'property="books:author"' "$html_file" | sed 's/.*content="\([^"]*\)".*/\1/' | head -1)
  if [[ -z "$author" ]]; then
    author=$(grep -A5 'authorName' "$html_file" | grep -o '>[^<]*<' | sed 's/[><]//g' | head -1)
  fi
  SCRAPED_AUTHORS[$output_index]="$author"
  
  # Extract rating
  local rating=""
  rating=$(grep -i 'ratingValue' "$html_file" | sed 's/.*content="\([^"]*\)".*/\1/' | head -1)
  SCRAPED_RATINGS[$output_index]="$rating"
  
  # Extract description
  local description=""
  description=$(grep -A10 'description' "$html_file" | grep -o '<span[^>]*>[^<]*</span>' | sed 's/<[^>]*>//g' | tr '\n' ' ' | head -c 500)
  SCRAPED_DESCRIPTIONS[$output_index]="$description"
  
  # Extract cover image
  local cover_url=""
  cover_url=$(grep -i 'property="og:image"' "$html_file" | sed 's/.*content="\([^"]*\)".*/\1/' | head -1)
  SCRAPED_COVER_URLS[$output_index]="$cover_url"
  
  logMessage "INFO" "Goodreads format parsing completed"
  return 0
}

##
## Audible-specific Parsing Functions
##

# Parse Audible page format
parseAudibleFormat()
{
  local html_file="$1"
  local output_index="${2:-0}"
  
  logMessage "INFO" "Parsing Audible format page"
  
  # Extract title
  local title=""
  title=$(grep -i 'property="og:title"' "$html_file" | sed 's/.*content="\([^"]*\)".*/\1/' | head -1)
  if [[ -z "$title" ]]; then
    title=$(grep -i '<title>' "$html_file" | sed 's/<[^>]*>//g' | sed 's/ (Unabridged).*//' | head -1)
  fi
  SCRAPED_TITLES[$output_index]="$title"
  
  # Extract author
  local author=""
  author=$(grep -i 'data-asin' "$html_file" | grep -A10 'author' | grep -o 'title="[^"]*"' | sed 's/title="\([^"]*\)"/\1/' | head -1)
  SCRAPED_AUTHORS[$output_index]="$author"
  
  # Extract narrator
  local narrator=""
  narrator=$(grep -i 'narrator' "$html_file" | grep -o 'title="[^"]*"' | sed 's/title="\([^"]*\)"/\1/' | head -1)
  SCRAPED_NARRATORS[$output_index]="$narrator"
  
  # Extract duration
  local duration=""
  duration=$(grep -i 'runtime' "$html_file" | grep -o '[0-9]* hrs and [0-9]* mins' | head -1)
  SCRAPED_DURATIONS[$output_index]="$duration"
  
  # Extract publisher
  local publisher=""
  publisher=$(grep -i 'publisher' "$html_file" | grep -o '>[^<]*<' | sed 's/[><]//g' | head -1)
  SCRAPED_PUBLISHERS[$output_index]="$publisher"
  
  logMessage "INFO" "Audible format parsing completed"
  return 0
}

##
## Generic HTML Parsing Functions
##

# Extract meta tag information
extractMetaTags()
{
  local html_file="$1"
  local output_index="${2:-0}"
  
  logMessage "DEBUG" "Extracting meta tag information"
  
  # Extract Open Graph tags
  local og_title og_description og_image
  og_title=$(grep -i 'property="og:title"' "$html_file" | sed 's/.*content="\([^"]*\)".*/\1/' | head -1)
  og_description=$(grep -i 'property="og:description"' "$html_file" | sed 's/.*content="\([^"]*\)".*/\1/' | head -1)
  og_image=$(grep -i 'property="og:image"' "$html_file" | sed 's/.*content="\([^"]*\)".*/\1/' | head -1)
  
  # Use as fallbacks if not already set
  if [[ -z "${SCRAPED_TITLES[$output_index]}" && -n "$og_title" ]]; then
    SCRAPED_TITLES[$output_index]="$og_title"
  fi
  
  if [[ -z "${SCRAPED_DESCRIPTIONS[$output_index]}" && -n "$og_description" ]]; then
    SCRAPED_DESCRIPTIONS[$output_index]="$og_description"
  fi
  
  if [[ -z "${SCRAPED_COVER_URLS[$output_index]}" && -n "$og_image" ]]; then
    SCRAPED_COVER_URLS[$output_index]="$og_image"
  fi
  
  logMessage "DEBUG" "Meta tag extraction completed"
  return 0
}

# Extract structured data (JSON-LD)
extractStructuredData()
{
  local html_file="$1"
  local output_index="${2:-0}"
  
  logMessage "DEBUG" "Extracting structured data"
  
  # Look for JSON-LD structured data
  local json_ld=""
  json_ld=$(sed -n '/<script type="application\/ld+json">/,/<\/script>/p' "$html_file" | sed '1d;$d')
  
  if [[ -n "$json_ld" ]] && command -v jq &> /dev/null; then
    # Extract book information from JSON-LD
    local book_title book_author book_publisher
    book_title=$(echo "$json_ld" | jq -r '.name // .title // empty' 2>/dev/null)
    book_author=$(echo "$json_ld" | jq -r '.author.name // .author // empty' 2>/dev/null)
    book_publisher=$(echo "$json_ld" | jq -r '.publisher.name // .publisher // empty' 2>/dev/null)
    
    # Use as fallbacks
    if [[ -z "${SCRAPED_TITLES[$output_index]}" && -n "$book_title" ]]; then
      SCRAPED_TITLES[$output_index]="$book_title"
    fi
    
    if [[ -z "${SCRAPED_AUTHORS[$output_index]}" && -n "$book_author" ]]; then
      SCRAPED_AUTHORS[$output_index]="$book_author"
    fi
    
    if [[ -z "${SCRAPED_PUBLISHERS[$output_index]}" && -n "$book_publisher" ]]; then
      SCRAPED_PUBLISHERS[$output_index]="$book_publisher"
    fi
  fi
  
  logMessage "DEBUG" "Structured data extraction completed"
  return 0
}

##
## High-Level Scraping Functions
##

# Main scraping function - detects site and uses appropriate parser
scrapeBookPage()
{
  local html_file="$1"
  local output_index="${2:-0}"
  
  if [[ ! -f "$html_file" ]]; then
    logMessage "ERROR" "HTML file not found: $html_file"
    return 1
  fi
  
  logMessage "INFO" "Starting web scraping for: $html_file"
  
  # Check if file is gzip-compressed and decompress if needed
  local working_file="$html_file"
  local cleanup_temp=false
  
  if file "$html_file" | grep -q "gzip compressed"; then
    logMessage "INFO" "Detected gzip-compressed HTML file, decompressing..."
    local temp_file
    temp_file=$(mktemp "${tmpDir:-/tmp}/ccab.html.XXXXXX")
    if gunzip -c "$html_file" > "$temp_file" 2>/dev/null; then
      working_file="$temp_file"
      cleanup_temp=true
      logMessage "INFO" "Successfully decompressed gzip file to: $working_file"
    else
      logMessage "ERROR" "Failed to decompress gzip file"
      rm -f "$temp_file" 2>/dev/null
      return 1
    fi
  fi
  
  # Initialize output arrays if needed
  if [[ ${#SCRAPED_TITLES[@]} -le $output_index ]]; then
    SCRAPED_TITLES[$output_index]=""
    SCRAPED_AUTHORS[$output_index]=""
    SCRAPED_NARRATORS[$output_index]=""
    SCRAPED_SERIES[$output_index]=""
    SCRAPED_SERIES_NUMBERS[$output_index]=""
    SCRAPED_PUBLISHERS[$output_index]=""
    SCRAPED_DURATIONS[$output_index]=""
    SCRAPED_RELEASE_DATES[$output_index]=""
    SCRAPED_ASINS[$output_index]=""
    SCRAPED_LANGUAGES[$output_index]=""
    SCRAPED_RATINGS[$output_index]=""
    SCRAPED_COVER_URLS[$output_index]=""
    SCRAPED_DESCRIPTIONS[$output_index]=""
  fi
  
  # Detect site type
  local site_type=""
  site_type=$(detectSiteType "$working_file")
  logMessage "INFO" "Detected site type: $site_type"
  
  # Parse based on site type
  case "$site_type" in
    "amazon")
      parseAmazonFormat "$working_file" "$output_index"
      ;;
    "goodreads")
      parseGoodreadsFormat "$working_file" "$output_index"
      ;;
    "audible")
      parseAudibleFormat "$working_file" "$output_index"
      ;;
    *)
      logMessage "WARN" "Unknown site type, using generic parsing"
      extractMetaTags "$working_file" "$output_index"
      extractStructuredData "$working_file" "$output_index"
      ;;
  esac
  
  # Always try to extract meta tags and structured data as fallbacks
  extractMetaTags "$working_file" "$output_index"
  extractStructuredData "$working_file" "$output_index"
  
  # Clean up extracted data
  cleanupScrapedData "$output_index"
  
  # Clean up temporary file if created
  if [[ "$cleanup_temp" == true && -f "$working_file" ]]; then
    rm -f "$working_file"
    logMessage "DEBUG" "Cleaned up temporary decompressed file"
  fi
  
  logMessage "INFO" "Web scraping completed for index $output_index"
  return 0
}

# Scrape multiple sample files
scrapeSampleFiles()
{
  local sample_files=("$@")
  local index=0
  
  for file in "${sample_files[@]}"; do
    if [[ -f "$file" ]]; then
      logMessage "INFO" "Scraping sample file: $file"
      scrapeBookPage "$file" "$index"
      ((index++))
    else
      logMessage "WARN" "Sample file not found: $file"
    fi
  done
  
  return 0
}

##
## Data Management Functions
##

# Clean up scraped data (sanitize and validate)
cleanupScrapedData()
{
  local index="$1"
  
  # Sanitize all extracted fields
  SCRAPED_TITLES[$index]=$(validateInput "${SCRAPED_TITLES[$index]}" 200)
  SCRAPED_AUTHORS[$index]=$(validateInput "${SCRAPED_AUTHORS[$index]}" 100)
  SCRAPED_NARRATORS[$index]=$(validateInput "${SCRAPED_NARRATORS[$index]}" 100)
  SCRAPED_SERIES[$index]=$(validateInput "${SCRAPED_SERIES[$index]}" 100)
  SCRAPED_SERIES_NUMBERS[$index]=$(validateInput "${SCRAPED_SERIES_NUMBERS[$index]}" 10)
  SCRAPED_PUBLISHERS[$index]=$(validateInput "${SCRAPED_PUBLISHERS[$index]}" 100)
  SCRAPED_DURATIONS[$index]=$(validateInput "${SCRAPED_DURATIONS[$index]}" 50)
  SCRAPED_RELEASE_DATES[$index]=$(validateInput "${SCRAPED_RELEASE_DATES[$index]}" 50)
  SCRAPED_ASINS[$index]=$(validateInput "${SCRAPED_ASINS[$index]}" 20)
  SCRAPED_LANGUAGES[$index]=$(validateInput "${SCRAPED_LANGUAGES[$index]}" 20)
  SCRAPED_RATINGS[$index]=$(validateInput "${SCRAPED_RATINGS[$index]}" 10)
  SCRAPED_DESCRIPTIONS[$index]=$(validateInput "${SCRAPED_DESCRIPTIONS[$index]}" 1000)
  
  # Validate URLs
  if [[ -n "${SCRAPED_COVER_URLS[$index]}" ]]; then
    if ! validateURL "${SCRAPED_COVER_URLS[$index]}"; then
      SCRAPED_COVER_URLS[$index]=""
    fi
  fi
  
  # Trim whitespace
  SCRAPED_TITLES[$index]=$(echo "${SCRAPED_TITLES[$index]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  SCRAPED_AUTHORS[$index]=$(echo "${SCRAPED_AUTHORS[$index]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  SCRAPED_NARRATORS[$index]=$(echo "${SCRAPED_NARRATORS[$index]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  
  logMessage "DEBUG" "Cleaned up scraped data for index $index"
}

# Get scraped data as JSON
getScrapedDataJSON()
{
  local index="$1"
  
  if [[ $index -ge ${#SCRAPED_TITLES[@]} ]]; then
    logMessage "ERROR" "Invalid scraped data index: $index"
    return 1
  fi
  
  cat << EOF
{
  "title": "${SCRAPED_TITLES[$index]:-}",
  "author": "${SCRAPED_AUTHORS[$index]:-}",
  "narrator": "${SCRAPED_NARRATORS[$index]:-}",
  "series": "${SCRAPED_SERIES[$index]:-}",
  "series_number": "${SCRAPED_SERIES_NUMBERS[$index]:-}",
  "publisher": "${SCRAPED_PUBLISHERS[$index]:-}",
  "duration": "${SCRAPED_DURATIONS[$index]:-}",
  "release_date": "${SCRAPED_RELEASE_DATES[$index]:-}",
  "asin": "${SCRAPED_ASINS[$index]:-}",
  "language": "${SCRAPED_LANGUAGES[$index]:-}",
  "rating": "${SCRAPED_RATINGS[$index]:-}",
  "cover_url": "${SCRAPED_COVER_URLS[$index]:-}",
  "description": "${SCRAPED_DESCRIPTIONS[$index]:-}"
}
EOF
}

# Get number of scraped items
getScrapedDataCount()
{
  echo "${#SCRAPED_TITLES[@]}"
}

# Clear all scraped data
clearScrapedData()
{
  SCRAPED_TITLES=()
  SCRAPED_AUTHORS=()
  SCRAPED_NARRATORS=()
  SCRAPED_SERIES=()
  SCRAPED_SERIES_NUMBERS=()
  SCRAPED_PUBLISHERS=()
  SCRAPED_DURATIONS=()
  SCRAPED_RELEASE_DATES=()
  SCRAPED_ASINS=()
  SCRAPED_LANGUAGES=()
  SCRAPED_RATINGS=()
  SCRAPED_COVER_URLS=()
  SCRAPED_DESCRIPTIONS=()
  
  logMessage "DEBUG" "Scraped data cleared"
}

# Display scraped data summary
displayScrapedSummary()
{
  local count
  count=$(getScrapedDataCount)
  
  echo -e "${C2}>>> Scraped Data Summary ($count items):${C0}"
  echo
  
  for ((i=0; i<count; i++)); do
    echo -e "${C3}Item $((i+1)):${C0}"
    echo -e "  ${C2}Title:${C0} ${SCRAPED_TITLES[$i]}"
    echo -e "  ${C2}Author:${C0} ${SCRAPED_AUTHORS[$i]}"
    echo -e "  ${C2}Narrator:${C0} ${SCRAPED_NARRATORS[$i]}"
    echo -e "  ${C2}Series:${C0} ${SCRAPED_SERIES[$i]} #${SCRAPED_SERIES_NUMBERS[$i]}"
    echo -e "  ${C2}Publisher:${C0} ${SCRAPED_PUBLISHERS[$i]}"
    echo -e "  ${C2}Duration:${C0} ${SCRAPED_DURATIONS[$i]}"
    echo -e "  ${C2}ASIN:${C0} ${SCRAPED_ASINS[$i]}"
    echo
  done
}

##
## Module Initialization
##

# Initialize web scraper module
initializeWebScraper()
{
  logMessage "INFO" ">>> Initializing web scraper module..."
  
  # Validate dependencies
  local missing_deps=()
  
  # Clear any existing data
  clearScrapedData
  
  logMessage "INFO" ">>> Web scraper module initialized successfully"
  return 0
}

# Export functions for use by other modules
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  # Script is being sourced
  export -f detectSiteType
  export -f extractAmazonRichInfo
  export -f parseAmazonFormat
  export -f parseGoodreadsFormat
  export -f parseAudibleFormat
  export -f extractMetaTags
  export -f extractStructuredData
  export -f scrapeBookPage
  export -f scrapeSampleFiles
  export -f cleanupScrapedData
  export -f getScrapedDataJSON
  export -f getScrapedDataCount
  export -f clearScrapedData
  export -f displayScrapedSummary
  export -f initializeWebScraper
fi