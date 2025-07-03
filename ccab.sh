#!/bin/bash
#shellcheck disable=SC2004

## ========================================================================================
##       Title: ccab.sh
##      Author: R. L. Paxton
##     Version: 3.1
##        Date: 2024-10-24
##     License: Apache 2.0
## Description: Convert audio book files to a standard .mp3 format.
##              This script searches online for the book information and
##              adds that to the metadata of the file.  It then converts
##              the audio file to a lower bitrate and updates the ID3 tags
##              including the cover art.  It then copies the files to the
##              specified directory (<category>/<author>/<series>).
##     Example: /audiobooks/SciFi/Author/Series 01 - Title/Author - Series 01 - Title.mp3
##
##      Usage: ccab.sh [options] [directory]|[$PWD]
##
##       NOTE1: Pass the '-h' option for help.
##       NOTE2: The script will concatenate .mp3 files into a single file if
##              the '-c' option is passed (.m4b will not concatenate).
##       NOTE3: The script will search for .mp3, .m4a, .m4b, .flac, and .mp4
##              files by default.  Use the '--mp3', '--m4b', '--flac', or '--mp4'
##
##         FYI: It works on my system.  YMMV
## ========================================================================================

## User parameters
# Set the target bitrate for the audio files.
targetBitrate=48
# Set the base log directory for the script.
logDir='/var/log/ccab'
# Set the base directory for the output of the audiobooks.
baseDir='/audio/audiobooks'
# Creates a log file of all the converted books.
convertLog="$logDir/converted.log"
user='rp01'
group='admins'

## Verify temp directory
if [[ ! -d '/tmp/ccab' ]]; then
  mkdir /tmp/ccab
fi
workDir=$(sudo mktemp -d /tmp/ccab/tmp.XXXXX)
sudo chown $user:$group "$workDir"

## Verify log directory
if [[ ! -d '/var/log/ccab' ]]; then
  sudo mkdir /var/log/ccab
  sudo chown $user:$group /var/log/ccab
  sudo chmod 775 /var/log/ccab
fi

## Verify base directory
if [[ ! -d "$baseDir" ]]; then
  echo "${C5}[RC:2] ERROR, ${C0}Base directory does not exist, bailing."
  exit 2
fi

trap 'cleanUp 1' 1 2 3 15

## Define color outputs
C1="$(printf '\033[38;5;040m')"  # Green
C2="$(printf '\033[38;5;236m')"  # Grey
C3="$(printf '\033[38;5;254m')"  # Hi-Lite
C4="$(printf '\033[38;5;184m')"  # Yellow
C5="$(printf '\033[38;5;160m')"  # Red
C6="$(printf '\033[38;5;164m')"  # Purple
C7="$(printf '\033[38;5;070m')"  # Lt Green
C8="$(printf '\033[38;5;240m')"  # Lt Grey
C0="$(printf '\033[0;00m')"      # Reset

## Check for required packages
command -v ffmpeg >/dev/null || {
  echo "${C5}[RC:10] ERROR, ${C3}ffmpeg${C0} not found in \$PATH, Install: ${C1}sudo dnf install ffmpeg${C0}";
  exit 10;
}
command -v mid3v2 >/dev/null || {
  echo "${C5}[RC:11] ERROR, ${C3}mid3v2${C0} not found in \$PATH, Install: ${C1}sudo pip install mutagen${C0}";
  exit 11;
}
command -v fancy_audio >/dev/null || {
  echo "${C5}[RC:12] ERROR, ${C3}fancy_audio${C0} not found in \$PATH, Install: ${C1}sudo gem install fancy_audio${C0}";
  exit 12;
}
command -v curl >/dev/null || {
  echo "${C5}[RC:14] ERROR, ${C3}curl${C0} not found in \$PATH, Install: ${C1}sudo dnf install curl${C0}";
  exit 14;
}
command -v lame >/dev/null || {
  echo "${C5}[RC:15] ERROR, ${C3}lame${C0} not found in \$PATH, Install: ${C1}sudo dnf install lame${C0}";
  exit 15;
}
command -v sweech >/dev/null ||
  echo "${C4}[RC:16] Warning, ${C3}sweech${C0} not found in \$PATH, (Optional) Install: ${C1}sudo pip install sweech-cli${C0}"

## Set global flags
typeset -a tmpTitle tmpURLs baseName bookInfo bookBitrate encodeFile outDir
typeset catFile bookType
clean=true
concat=false
debug=false
move=false
recurse=false

cleanUp()
{
  # Depending on the exit status, clean up the temp files and exit.
  STATUS=$1
  tput cnorm

  if (( STATUS == 0 )); then

    if $clean; then
      echo -e "${C8}>>> Cleaning temp files${C0}"
      sudo rm -rf "${workDir:?}"
      rm -f "$richInfo" "$tmpInfo" "/tmp/book.html"
    else
      echo -e "${C8}INFO: Work directory = $workDir${C0}"
    fi

    echo -e "${C1}[RC:$STATUS] Done!${C0}"

  elif (( STATUS == 1 )); then
    tput cnorm
    echo -e "${C4}[RC:$STATUS] Abnormal end, temp directory [${C8}$workDir${C4}]${C0}"

  else
    tput cnorm
    echo -e "${C5}[RC:$STATUS] Error during run, aborting.${C0} [$workDir]"
  fi

  exit "$STATUS"
}

usage()
{
  cat << EOM

${C3}NAME${C0}
    ccab - re-encode audio files.

${C3}OPTIONS${C0}
    ${C1}-c${C0}, ${C1}--concat${C0}
        Will combine detected files into a single .mp3 file.
    ${C1}-d${C0}, ${C1}--debug${C0}
        Enable debug output.
    ${C1}--flac${C0}
        Will limit search of input files to .flac files only.
    ${C1}-h${C0}, ${C1}--help${C0}
        Display this help message.
    ${C1}-m${C0}, ${C1}--move${C0}
        After re-encoding, will move new files to specified directory (baseDir).
        May add option value on the command line to avoid prompting if book
        type is know before hand [-m #].
            Move Catagories:
               1 = Romance
               2 = Hot
               3 = SciFi
               4 = Fantasy
               5 = Thriller
               6 = Misc
    ${C1}--m4b${C0}
        Will limit search of input files to .m4a or .m4b files only.
    ${C1}--mp3${C0}
        Will limit search of input files to .mp3 or .mp4 files only.
    ${C1}-r${C0}, ${C1}--recurse${C0}
        Will search subdirectories for input files, make sure subdirectories are
        zero padded if more that 9 subs (ex. /disk 1 ==> /disk 01).
    ${C1}-v${C0}, ${C1}--verify${C0}
        Verify ID3 tags.

EOM

  return 0
}

getFiles()
{
  ## Collect incoming files
  fileList="$workDir/concat_files.list"
  searchType=${searchType:-'.*\.\(mp3\|m4a\|m4b\|flac\|mp4\)'}
  inDir=${inDir:-$PWD}

  if [[ $recurse == 'true' ]]; then
    find "$inDir" -type f -iregex ".*.${searchType}" -printf '%h/%f\n' |\
      grep -v 'ccab' | sort -V > "$fileList"
  else
    find "$inDir" -maxdepth 1 -type f -iregex ".*.${searchType}" -printf '%h/%f\n' |\
      grep -v 'ccab' | sort -V > "$fileList"
  fi

  mapfile -t inFiles < <(cat "$fileList")

  return 0
}

probeFile()
{
  inFile=$1
  index=$2
  # Gather information on the book (title, series, info, etc.).
  probeFile="$workDir/$(basename "${inFile%.*}").probe"
  echo -e "${C8}>>> probing $(basename "$inFile")${C0}"

  inFile="$1"

  if $debug; then
    echo -e "${C8}++ffprobe -hide_banner \"$inFile\" >\"$probeFile\"${C0}"
  fi
  ffprobe -hide_banner "$inFile" >"$probeFile" 2>&1

  _album=$(sed -rn 's/\ +album\ *:\ (.[^:]*).*/\1/p' "$probeFile")
  _artist=$(sed -rn 's/\ +artist\ *:\ (.*)$/\1/p' "$probeFile")
  _author=$(sed -rn 's/\ +author\ *:\ (.*)$/\1/p' "$probeFile")
  _album_artist=$(sed -rn 's/\ +album_artist\ *:\ (.*)$/\1/p' "$probeFile")
  _title=$(grep -m 1 'title' "$probeFile" | sed -rn 's/.* : (.[^:]*).*/\1/p')
  _date=$(sed -rn 's/\ +date\ *:\ (.*)$/\1/p' "$probeFile")

  ## Set temp book title
  _bookTitle="${_title:-$_album}"
  _bookTitle=${_bookTitle//[^a-zA-Z0-9 ]/}
  _bookTitle=$(sed -r 's/^[0-9]+ //' <<< "$_bookTitle")

  ## Set book author.
  _bookAuthor="${_author:-$_artist}"
  _bookAuthor="${_bookAuthor:-$_album_artist}"

  if [[ -z $_bookTitle ]]; then
    echo -e "${C4}Enter the title of the book${C0} [$_bookTitle]: \c"
    read -r _tempTitle
    _bookTitle=${_tempTitle:-$_bookTitle}
  fi

  if [[ -z $_bookAuthor ]]; then
    echo -e "${C4}Enter the author of the book${C0} [$_bookAuthor]: \c"
    read -r _tempAuthor
    _bookAuthor=${_tempAuthor:-$_bookAuthor}
  fi


  _origBitrate=$(grep 'Audio:' "$probeFile" | awk -F', ' '{ print $5 }' | awk '{ print $1 }')
  if [[ $_origBitrate -gt $targetBitrate ]]; then
    _bookBitrate=$targetBitrate
  elif [[ $_origBitrate -gt 40 ]]; then
    _bookBitrate=48
  else
    _bookBitrate=32
  fi

  bookTitle[$index]="$_bookTitle"
  bookAuthor[$index]="$_bookAuthor"
  bookBitrate[$index]="$_bookBitrate"
  bookDate[$index]="$_date"

  shortDir="$(sed -rn 's;^/\w+/\w+/(.*);\1;p' <<< "$(dirname "$inFile")")"
  cat <<EOF
  ${C8}In File: ${C0}$(basename "$inFile")${C8}
  Directory: ${C0}${shortDir:0:80}${C8}
  Found Title: ${C0}${bookTitle[$index]:0:80}${C8}
  Found Author: ${C0}${bookAuthor[$index]:0:80}${C8}
  Found Bitrate: ${bookBitrate[$index]}
  Found Date: ${bookDate[$index]}${C0}
EOF

  if [[ -z ${bookTitle[$index]} || -z ${bookAuthor[$index]} ]]; then
    echo -e "${C5}ERROR:${C0} No book information found."
    return 1
  else
    return 0
  fi
}

searchIt()
{
  _searchData=$1
  _return="$workDir/search.json"
  _results="$workDir/results.json"
  # Set _engine_id and _api_key in the keys file.
  #shellcheck disable=SC1091
  source "$HOME/.config/keys"
  url='https://customsearch.googleapis.com/customsearch/v1?'

  _searchData=${_searchData//[Uu]nabridged/}

  #shellcheck disable=SC2154
  _searchCmd="${url}cx=${_engine_id}&cr=us&key=${_api_key}&q=${_searchData// /+}&num=7"

  echo -e "${C2}$_searchCmd${C0}"

  echo -e "\n${C8}>>> Searching for: '${_searchData// /+}'${C0}\n"
  _searchData="https://${url}/search?q=${_searchData// /+}"
  echo -e "${C2}$_searchData${C0}"
  curl -s "$_searchCmd" --header 'Accept: application/json' > "$_return"
  jq '.items | map(.) | .[] | { link_title: .title, url: .link }' < "$_return" > "$_results"
  sed -i 's/ \.\..*/",/' "$_results"

  mapfile -t tmpURLs < <(grep 'url' "$_results" | awk -F'[""]' '{ print $4 }')
  mapfile -t tmpTitle < <(grep 'link_title' "$_results" | awk -F'[""]' '{ print $4 }')

  i=0
  while (( i < ${#tmpTitle[*]} )); do
    echo -e "${C4}$((i + 1)). ${C3}${tmpTitle[$i]/&amp;/&/}${C0}"
    echo -e "   ${C8}${tmpURLs[$i]}${C0}"
    echo ""
    ((i++))
  done

  return 0
}

searchInfo()
{
  inFile=$1
  index=$2

  searchData="${bookTitle[$index]}+${bookAuthor[$index]}"
  searchData=${searchData//([Uu]nabridged)/}

  ## Search and display results
  searchIt "$searchData"

  ## Choose book results to process
  result=0
  while [[ -z ${bookURL[$index]} ]]; do
    echo -e "${C4}Choose result number for info or '0' for direct URL:${C0} \c"
    read -r result

    case $result in
      [1-9]) # Selected info from current dataset.
        bookURL[$index]=${tmpURLs[((result - 1))]}
        echo -e "\n${C8}INFO: bookURL = ${bookURL[$index]}${C0}"
        ;;
      1[0-9]) # Enter new search data and search again
        bookURL[$index]=${tmpURLs[((result - 1))]}
        echo -e "\n${C8}INFO: bookURL = ${bookURL[$index]}${C0}"
        ;;
      0) # Manually enter book URL
        echo -e "\n  ${C6}Enter book URL: ${C0}\c"
        read -r bookURL["$index"]
        ;;
      s|S) # New search criteria
        echo -e "\n Enter new search criteria: \c"
        read -r searchData
        searchIt "$searchData"
        ;;
      *) # Invalid option
        echo -e "\n  ${C5}Invalid option '$result'.${C0}\n"
        ;;
    esac
  done

  ## Process manually downloaded book information
  while [[ ! -r /tmp/book.html ]]; do
    cat << EOF
      ${C4}Due to Amazon blocking automated scraping with CAPTCHA, we need to maually
      download the book information. Open a browser page to the Audible book page
      and save the page as '/tmp/book.html' and press Enter to continue.${C0}
EOF
    read -r ANS
  done

  mv /tmp/book.html "${workDir}/book.html"

  return 0
}

parseInfo()
{
  ## NOTE: This is prone to failure due to many different versions of returned
  ##       data.  Multiple methods are used to attempt to gather as much as
  ##       possible.

  inFile="$workDir/book.html"
  normalFile="$workDir/normalized.html"
  index=$2

  # Normalize the book html page to allow for better parsing.
  hxnormalize -l 9999 "$inFile" > "$normalFile"

  #if [[ -r "$inFile" ]]; then
  #  grep 'rich_product_information' "$inFile" | hxnormalize -l 9999 > "$richInfo"
  #else
  #  echo -e "${C5}ERROR:${C0} Unable to read $inFile."
  #  return 1
  #fi

  _fullTitle=$(grep -m 1 '<title>' "$normalFile" | sed -rn 's/.*<title>(.*)<\/title>/\1/p')
  _fullTitle=${_fullTitle//\&amp;/\&}
  _fullTitle=${_fullTitle//\&apos;/\'}
  _fullTitle=$(sed -r 's/&#4[0-1];//g' <<< "$_fullTitle")

  echo -e "${C2}_fullTitle: $_fullTitle${C0}"
  
  if [[ -z $_title ]]; then
    _title=$(sed -'s/.*Amazon.com: //; s/ (Audible Audio Edition).*//; s/: .*LitRPG.*//' <<< "$_fullTitle")
  fi

  echo -e "${C3}Confirm book title: [${C0}${_title}${C3}]${C0} \c"
  read -r tmpTitle
  _title=${tmpTitle:-$_title}
  echo -e "${C2}_title: $_title${C0}"

  _author=$(grep -m1 'Author:' "$normalFile" | sed -rn 's/.*Author: (.*)" class.*/\1/p' | sed 's/,.*//')
  echo -e "${C3}Confirm book author: [${C0}${_author}${C3}]${C0} \c"
  read -r tmpAuthor
  _author=${tmpAuthor:-$_author}
  echo -e "${C2}_author: $_author${C0}"

  _releaseDate=$(grep -A4 'Audible release date' "$normalFile" | tail -1 | sed -rn 's/.*<span>(.*)<\/span>.*/\1/p')
  if [[ -z $_releaseDate ]]; then
    _releaseDate="unknown"
  else
    _year=$(sed 's/.*, //' <<< "$_releaseDate")
  fi

  _seriesName=$(grep -m 1 'Book [0-9] of ' "$normalFile" | sed -rn 's/.*: (.*) <\/a>.*/\1/p')
  _seriesName=${_series//\&amp;/\&}
  _seriesName=${_series//\&apos;/\'}
  #_seriesName=${_series//\&#39;/\'}

  if [[ -z $_seriesName ]]; then
    _seriesName="$(sed -rn 's/.*- (.*) - .*/\1/p' <<< "$_fullTitle")"
  fi

  echo -e "${C3}Confirm book series name: [${C0}${_seriesName}${C3}]${C0} \c"
  read -r tmpSeries
  _seriesName=${tmpSeries:-$_seriesName}
  echo -e "${C2}_seriesName: $_seriesName${C0}"

  _seriesNum=$(printf "%02d" "$(grep -m 1 'Book [0-9] or' "$normalFile" | sed -rn 's/.*Book ([0-9]+).*/\1/p')")
  if [[ -z $_seriesNum ]]; then
    _seriesNum="${_year:-'00'}"
  fi

  echo -e "${C3}Confirm series number: [${C0}${_seriesNum}${C3}]${C0} \c"
  read -r tmpNum
  _seriesNum=${tmpNum:-$_seriesNum}

  _series="$_seriesName $_seriesNum"
  echo -e "${C2}_series: $_series${C0}"

  _narrator=$(grep -A4 'Narrator' "$normalFile" | grep 'celwidget' | tail -1 | sed -rn 's/.*<span>(.*)<\/span>.*/\1/p')
  if [[ -z $_narrator ]]; then
    _narrator='unknown'
  fi 
  echo -e "${C2}_narrator: $_narrator${C0}"

  _publisher=$(grep -A4 'Publisher' "$normalFile" | grep 'celwidget' | tail -1 | sed -rn 's/.*<span>(.*)<\/span>.*/\1/p')
  if [[ -z $_publisher ]]; then
    _publisher='unknown'
  fi
  echo -e "${C2}_publisher: $_publisher${C0}"

  _ASIN=$(grep -m1 'ASIN=' "$normalFile" | sed -rn 's/.*ASIN=(.*)">.*/\1/p')
  if [[ -z $_ASIN ]]; then
    _ASIN='unknown'
  fi
  echo -e "${C2}_ASIN: $_ASIN${C0}"

  _length=$(grep -m1 -A4 'Listening Length' "$normalFile" | tail -1 | sed -rn 's/.*<span>(.*)<\/span>.*/\1/p')
  if [[ -z $_length ]]; then
    _length='unknown'
  fi
  echo -e "${C2}_length: $_length${C0}"

  _rating=$(grep -m1 'out of 5 stars' "$normalFile" | sed -rn 's/.*<span.*([0-9].[0-9]) out of.*/\1/p')
  echo -e "${C2}_rating: $_rating${C0}"

  _image=$(grep 'data-ssf-share-icon' "$normalFile" | sed -rn 's/.*(https:\/\/m.media-amazon.com.*\.jpg).*/\1/p')
  echo -e "${C2}_image: $_image${C0}"

  _description=$(sed -n '/book_description_expander/, /a-expander-header/p' "$normalFile" |\
    sed 's/<[^>]*>//g; s/&[^;]*;//g; /^[[:space:]]*$/d' | fold -s | sed -r 's/^[[:space:]]+/\n  /g')
  echo -e "${C2}_description: \n${_description:0:80}...${C0}"

  # Replace colons within title text (sweech doesn't like colons).
  _title=$(sed 's/:/-/g; s/ (.*//g' <<< "$_title")

  bookTitle[index]="$_title"
  
  # Prompt for missing title if not found
  if [[ -z ${bookTitle[$index]} ]]; then
    echo -e "${C4}Enter book title:${C0}: \c"
    read -r _bookTitle
    bookTitle[$index]=$_bookTitle
  fi

  # Sanitize book author
  _author=${_author/É/E}
  _author=${_author//[^a-zA-Z0-9 -.]/}

  # Prompt for missing author if not found
  if [[ -z $_author ]]; then
    echo -e "${C4}Enter book author:${C0}: \c"
    read -r _author
  fi
  ## Reverse author name and strip any ending '.'
  _authorReverse=$(awk '{$1=$NF", "$1;NF--} 1' <<< "$_author" | sed 's/\.$//')
  bookAuthor[$index]="$_author"
  # For one work authors
  bookAuthorReverse[$index]="${_authorReverse:-$_author}"

  bookNarrator[index]="${_narrator}"
  bookLength[index]="${_length}"
  bookDescription[index]="$_description"

  bookASIN[$index]="$_ASIN"
  bookYear[$index]="$_year"
  bookPublisher[$index]="$_publisher"

  # Prompt for missing series if not found
  if [[ -z $_series ]]; then
    echo -e "${C4}Enter book series:${C0}: \c"
    read -r fullSeries
  else
    fullSeries="$_series"
  fi
  echo -e "${C2}++fullSeries=$fullSeries${C0}"

  _bookSeries="$_series"
  _bookSeries=${_bookSeries/:/-}
  _bookSeries=${_bookSeries/&apos;/\'}
  _bookSeries=${_bookSeries//[^a-zA-Z0-9 -]/}
  bookSeries[$index]=$_bookSeries

  bookRating[$index]=$_rating

  _searchInfo="${_title} ${_author}"
  _searchInfo=${_searchInfo// /+/}
  _genre=$(curl -s -i "https://www.goodreads.com/search?q=${_searchInfo}" | hxnormalize -l 9999 |\
     grep -A4 -i 'related shelves' | sed -rn 's/.*\/shelf\/show\/(.*)" .*/\1/p')

  if [[ -n $_image ]]; then
    imageSource[$index]=$_image
  else
    echo -e "${C4}Enter book image url:${C0}: \c"
    read -r imageSource["$index"]
  fi

  baseName[$index]="${bookAuthor[$index]} - ${bookSeries[$index]} - ${bookTitle[$index]}"
  bookInfo[$index]="$workDir/${baseName[$index]}.info"
  bookCover[$index]="$workDir/${baseName[$index]}.jpg"

  if [[ -n ${imageSource[$index]} ]]; then
    curl -s -o "${bookCover[$index]}" "${imageSource[$index]}"
  fi

  cat << EOF >> "${bookInfo[$index]}"
   Author: ${bookAuthor[$index]}
    Title: ${bookTitle[$index]}
     ASIN: ${bookASIN[$index]}
   Series: ${bookSeries[$index]}
     Year: ${bookYear[$index]}
Publisher: ${bookPublisher[$index]}
   Rating: ${bookRating[$index]}
  Bitrate: ${bookBitrate[$index]} kb/s
      URL: ${bookURL[$index]}
    Cover: ${imageSource[$index]}


Classifications:
  ${_genre}


Summary:
  $_description
EOF

  # Replace extended characters with apostrophe
  # echo "X" | od -t x1c  # Display hex codes
  #sed -i 's/\xE2\x80\x9C/"/g; s/\xE2\x80\x9D/"/g; s/\xC3\x82//g; s/\xC5\x93/"/g; s/\xC2\x9D/"/g' "${bookInfo[$index]}"

  cat << EOF
  ${C8}      tmpDir: ${C9}${workDir}${C0}

  ${C0}    fullName: ${C7}${baseName[$index]}${C0}
  ${C0}      Author: ${C8}${bookAuthor[$index]}${C0}
  ${C0}    Narrator: ${C8}${bookNarrator[$index]}${C0}
  ${C0}       Title: ${C8}${bookTitle[$index]}${C0}
  ${C0}      Length: ${C8}${bookLength[$index]}${C0}
  ${C0}      Series: ${C8}${bookSeries[$index]}${C0}
  ${C0}        Year: ${C8}${bookYear[$index]}${C0}
  ${C0}   Publisher: ${C8}${bookPublisher[$index]}${C0}
  ${C0}        ASIN: ${C8}${bookASIN[$index]}${C0}
  ${C0}      Rating: ${C8}${bookRating[$index]}${C0}
  ${C0}   Cover URL: ${C8}${imageSource[$index]}${C0}
  ${C0}     Summary:
${C8}${bookDescription[$index]}${C0}
EOF

  ANS='n'
  echo -e "\n\n${C1}Continue? \c"
  read -rn 1 ANS
  echo ""
  if [[ ${ANS,,} != 'y' ]]; then
    cleanUp 0
  fi

  # Check converted.log for already converted.
  if grep -q "${baseName[$index]}" "$convertLog"; then
    echo -e "${C4}WARNING:${C0} ${baseName[$index]} already converted."
    echo -e "Re-encode this book?"
    read -rn 1 ANS
    echo ""
    if [[ ${ANS,,} != 'y' ]]; then
      return 1
    else
      echo -e "\n\n${C1}Converting now${C0}"
    fi
  else
    echo -e "\n\n${C1}Converting now${C0}"
  fi

  ## Confirm unrated books
  if [[ ${bookRating[$index]} == '0.00' ]]; then
    echo -e "${C4}WARNING:${C0} This book has a '0.00' rating, continue? [y/N]:\c"
    read -rn 1 ANS
    echo ""
    if [[ ${ANS,,} != 'y' ]]; then
      return 1
    fi
  fi

  return 0
}

classifyIt()
{
  inFile=$1
  index=$2

  echo -e "${C8}>>> Checking book catagory...${C0}"
  while [[ -z $catagory ]]; do

    echo ""
    cat "${bookInfo[$index]}"
    echo ""

    cat << EOM
${C4}1) Romance
2) Erotica
3) Sci-Fi
4) Fantasy
5) Thriller
6) Misc${C0}

EOM

    echo -e "${C4}Select book catagroy number: ${C0}\c"
    read -rn 1 catagory
    if (( ! catagory >= 1 && ! catagory < 7 )); then
      unset catagory
    fi

  echo ""
  done

  case $catagory in
    1) # Romance
      bookType="Romance"
      ;;
    2) # Erotica
      bookType="Erotica"
      ;;
    3) # SciFi
      bookType="SciFi"
      ;;
    4) # Fantasy
      bookType="Fantasy"
      ;;
    5) # Thriller
      bookType="Thriller"
      ;;
    6) # Misc
      bookType="Misc"
      ;;
    *) # Unknown
      echo -e "\nUnknown catagory type [$catagory]"
      return 1
      ;;
  esac

  if [[ -n $bookType ]]; then
    echo -e "${C8}  bookCategory: $bookType ${C0}"
    return 0
  else
    cleanUp 20
  fi
}

checkFile()
{
  inFile=$1
  index=$2
  extension="${inFile##*.}"
  outFile="$workDir/$(basename "${inFile%.*}").mp3"

  if [[ ! ${extension,,} =~ (mp3|mp4) ]]; then
    echo -e "${C8}>>> Converting $(basename "$inFile")...${C2}"
    ffmpeg -hide_banner -loglevel error -stats -i "$inFile" -vn -sn "$outFile"
    ## Reset inFiles to new converted file
    inFiles[$index]="$outFile"
    echo -e "${C8}Done converting file to mp3${C0}\n"
  fi

  if $concat; then
    echo -e "${C8}>>> Adding $inFile${C0}"
    cat "$inFile" >> "$catFile"
    return 2
  fi

  return 0
}

reEncode()
{
  inFile=$1
  index=$2
  outFile="$workDir/${baseName[$index]}.abr${bookBitrate[$index]}.mp3"
  encodeFile[$index]="$outFile"

  echo -e "${C0}>>> Encoding ${baseName[$index]}...${C2}"

  checkFile=0
  while [[ $checkFile -lt 1 ]]; do

    # Re-encode input file with my parameters.
    lame --nohist -m m -V 6 "$inFile" "$outFile"

    outSize=$(/bin/ls -l "$outFile" | awk '{ print $5 }')

    ## This is for files that don't concatenate properly
    if [[ $outSize -lt '4096000' ]]; then
      tempOut="$workDir/concat_44k.mp3"
      echo -e "${C8}>>> Re-encoding due to size error${C0}"
      ffmpeg -hide_banner -loglevel quiet -stats -i "$inFile" -codec:a libmp3lame -ar 44.1k "$tempOut"
      mv "$tempOut" "$outFile"
      checkFile=1
    else
      checkFile=1
    fi

  done

  echo -e "${C8}lame encoding completed${C0}"

  cat <<EOF >>done.txt
workDir:    $workDir
bookAuthor: ${bookAuthor[$index]}
bookTitle:  ${bookTitle[$index]}
bookSeries: ${bookSeries[$index]}
authorDir:  $baseDir/$bookType/${bookAuthorReverse[$index]}
bookDir:    ${bookSeries[$index]} - ${bookTitle[$index]}

EOF

  return 0
}

tagIt()
{
  # Attempted to use several command line tag editors, mid3v2 does most of what I needed, but has some
  # issues with cover art....
  inFile=$1
  index=$2

  echo -e "${C8}>>> Removing original ID3 tags${C0}"
  mid3v2 --delete-all "$inFile" >/dev/null 2>&1

  if [[ -s "${bookCover[$index]}" ]]; then
    echo -e "${C8}>>> Adding book cover image${C0}"
    # Falling back to fancy_audio for cover art :/.
    fancy_audio "$inFile" "${bookCover[$index]}"
  fi

  echo -e "${C8}>>> Adding ID3 tags${C0}"
  #shellcheck disable=SC2140
  mid3v2 -a "${bookAuthor[$index]}" \
    -A "${bookSeries[$index]}" \
    -t "${bookTitle[$index]}" \
    -g 'audiobook' -T 1 \
    -c "Comment":"${bookURL[$index]}":"eng" \
    -c "Rating":"${bookRating[$index]}":"eng" \
    -c "Encoded by":"theGh0st":"eng" "$inFile" > /dev/null

  return 0
}

moveIt()
{
  inFile=$1
  index=$2
  aDir="$baseDir/$bookType/${bookAuthorReverse[$index]}"
  outDir[$index]="$aDir/${bookSeries[$index]} - ${bookTitle[$index]}"
  echo -e "${C8}>>> bookType=$bookType${C0}"
  echo -e "${C8}>>> outDir[$index]=${outDir[$index]}${C0}"

  if ! $move; then
    echo -e "${C4}WARNING:${C8} Move flag not set."
    clean='false'
  else
    echo -e "${C8}>>> Moving encoded files to .../${bookAuthorReverse[$index]}/${bookTitle[$index]}${C0}"
  fi

  if $debug; then
    echo -e "${C2}++outDir[$index]=${outDir[$index]}${C0}"
  fi

  if [[ -d "${outDir[$index]}" ]]; then
    sudo mv "${outDir[$index]}"{,.old}
    sudo chown ${user}:${group} "${outDir[$index]}.old"
    sudo mkdir -p "${outDir[$index]}"
  else
    sudo mkdir -p "${outDir[$index]}"
  fi

  { sudo mv "${bookInfo[$index]}" "${outDir[$index]}";
    sudo mv "${bookCover[$index]}" "${outDir[$index]}";
    #sudo mv "${bookLink[$index]}" "${outDir[$index]}";
    sudo mv "${encodeFile[$index]}" "${outDir[$index]}"; }
  STATUS=$?

  if [[ $STATUS -eq 0 ]]; then
    echo -e "${C8}Files moved successfully${C0}"
  else
    echo -e "${C5}ERROR:${C0} moving files.${C0}"
    return $STATUS
  fi

  echo -e "${C8}>>> Setting file/directory permissions${C0}"
  sudo chown -R $user:$group "$aDir"
  sudo chmod 775 "$aDir"
  find "$aDir" -type d -exec sudo chmod 775 "{}" \;
  find "$aDir" -type f -exec sudo chmod 664 "{}" \;

  mDate=$(date +%Y-%b-%d)
  mDate=${mDate^^}

  echo -e "${C8}>>> Updating convert log${C0}"
  echo "$mDate, [$bookType], ${baseName[$index]}" >> $convertLog

  notify-send "Audiobook encode completed:" "${bookAuthor[$index]} - ${bookTitle[$index]}"
  return 0
}

## Process command line arguments
## -------------------------------------
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    -b | --bitrate) # Set bitrate for output
      re='^[0-9]+$'
      if [[ $2 =~ $re ]]; then
        targetBitrate=$2
        shift 2
      else
        targetBitrate=48
        shift
      fi
      ;;
    -c | --concat) # Concat all files found
      concat='true'
      shift
      ;;
    -d | --debug) # Enable debug output
      debug='true'
      shift
      ;;
    -h | --help) # Display help message
      usage
      exit 0
      ;;
    -m | --move) # Copy results to output directory
      move='true'
      catagory=$2
      re='^[1-6]$'
      if [[ ! $catagory =~ $re ]]; then
        unset catagory
        shift
      else
        shift 2
      fi
      ;;
    --mp3) # Search for only mp3 files
      searchType=".*\.\(mp3\)$"
      shift
      ;;
    --m4b) # Search for only .m4a or .m4b files
      searchType=".*\.\(m4a\|m4b\)$"
      shift
      ;;
    --flac) # Search for only .flac files
      searchType=".*\.\(flac\)$"
      shift
      ;;
    -r | --recurse) # Search subdirectories for files
      recurse=true
      shift
      ;;
    *) # Unknown option
      usage
      echo -e "${C5}[RC:1] ${C0}Unknown option ${C4}$1${C0}"
      exit 1
      ;;
  esac
done


## MAIN
## -------------------------------------
getFiles
## First loop to collect book information
j=0
while (( j < ${#inFiles[*]} )); do

  if $debug; then
    echo -e "${C2}+First loop, Processing '${inFiles[$j]}'${C0}"
  fi

  probeFile "${inFiles[$j]}" $j
  searchInfo "${inFiles[$j]}" $j
  parseInfo "${inFiles[$j]}" $j
  STATUS=$?

  if [[ $STATUS -eq 0 && $move ]]; then
   classifyIt "${inFiles[$j]}" $j
  fi

  ## Break if concatenating files
  if $concat; then
    catFile="$workDir/${baseName[0]}.concat.mp3"
    break;
  fi

  ((j++))

done

if $debug; then
  echo -e "${C2}+End first loop.${C0}"
fi


## Second loop to re-encode non-concatenated files
j=0
while (( j < ${#inFiles[*]} )); do

  if $debug; then
    echo -e "${C2}+Second loop, Processing '${inFiles[$j]}'${C0}"
  fi

  checkFile "${inFiles[$j]}" $j
  STATUS=$?

  if $debug; then
    echo -e "${C2}+checkFile STATUS=$STATUS\n++inFiles[$j]=${inFiles[$j]}${C0}"
  fi

  if (( STATUS == 0 )); then
    reEncode "${inFiles[$j]}" $j
    tagIt "${encodeFile[$j]}" $j
    moveIt "${baseName[$j]}" $j
    CHECK=$?
  fi

  ((j++))

done

## Process concatenated files
if $concat; then

  if $debug; then
    echo -e "${C2}+Process concat file '$catFile'${C0}"
  fi

  reEncode "$catFile" 0
  tagIt "${encodeFile[0]}" 0
  moveIt "${baseName[0]}" 0
  CHECK=$?
fi

if (( CHECK == 0 )); then
  cleanUp 0
else
  cleanUp 5
fi
