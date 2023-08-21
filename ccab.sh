#!/bin/bash

## User parameters
targetBitrate=48
logDir='/var/log/ccab'
baseDir='/audio/audiobooks'
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
#verify=false

cleanUp()
{
  STATUS=$1
  tput cnorm

  if (( STATUS == 0 )); then

    if $clean; then
      echo -e "${C8}>>> Cleaning temp files${C0}"
      sudo rm -rf "${workDir:?}"
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
  ## Gather information on the book (title, series, info, etc.).
  inFile=$1
  index=$2
  probeFile="$workDir/$(basename "${inFile%.*}").probe"
  echo -e "${C8}>>> probing $(basename "$inFile")${C0}"

  #set -x
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
  #_bookTitle=$(sed 's/ :.*//' <<< "$_bookTitle")

  ## Set temp book author.
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
  #set +x

  _origBitrate=$(grep 'Audio:' "$probeFile" | awk -F', ' '{ print $5 }' | awk '{ print $1 }')
  if [[ $_origBitrate -gt $targetBitrate ]]; then
    _bookBitrate=$targetBitrate
  elif [[ $_origBitrate -gt 40 ]]; then
    _bookBitrate=48
  else
    _bookBitrate=32
  fi

  bookTitle[$index]="$_bookTitle"
  bookAuthor[$index]="${_bookAuthor%%, *}"
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
  ## Search online for the book information.
  _searchData=$1
  _return="$workDir/search.json"
  _results="$workDir/results.json"
  _engine_id=951f823e30dc84ad4
  _api_key=AIzaSyD88Q-rHkVJ7u7hAyH89YmRD-35MjBlBU0
  url='https://customsearch.googleapis.com/customsearch/v1?'
  #url="https://www.goodreads.com/search?"
  #url="https://www.amazon.com/s?"

  _searchData=${_searchData//[Uu]nabridged/}

  #_searchData="${url}q=${_searchData// /+}"
  #_searchData="${url}k=${_searchData// /+}"
  _searchCmd="${url}cx=${_engine_id}&cr=us&key=${_api_key}&q=${_searchData// /+}&num=7"

  echo -e "${C2}$_searchCmd${C0}"

  echo -e "\n${C8}>>> Searching for: '${_searchData// /+}'${C0}\n"
  echo -e "${C2}$_searchData${C0}"
  curl -s "$_searchCmd" --header 'Accept: application/json' > "$_return"
  jq '.items | map(.) | .[] | { link_title: .title, url: .link }' < "$_return" > "$_results"
  sed -i 's/ \.\..*/",/' "$_results"

  #mapfile -t tmpURLs < <(grep '<a title=' "$_results" | sed -rn "s/.*href=\"(.[^?]*).*/https:\/\/${url}\1/p")
  #mapfile -t tmpTitle < <(grep '<span ' "$_results" | grep 'role=.heading.' | awk -F'[><]' '{ print $3 }')
  mapfile -t tmpURLs < <(grep 'url' "$_results" | awk -F'[""]' '{ print $4 }')
  mapfile -t tmpTitle < <(grep 'link_title' "$_results" | awk -F'[""]' '{ print $4 }')

  i=0
  while (( i < ${#tmpTitle[*]} )); do
    echo -e "${C4}$((i + 1)). ${C3}${tmpTitle[$i]}${C0}"
    echo -e "   ${C8}${tmpURLs[$i]}${C0}"
    echo ""
    ((i++))
  done

  return 0
}

searchInfo()
{
  ## Search returned results for  correct book.
  inFile=$1
  index=$2
  audible="$workDir/audible_${index}.html"
  kindle="$workDir/kindle_${index}.html"

  searchData="${bookTitle[$index]}+kindle+${bookAuthor[$index]}"
  searchData=${searchData//([Uu]nabridged)/}

  ## Search and display results
  searchIt "$searchData"

  ## Choose book results to process
  result=0
  while [[ -z ${bookURL[$index]} ]]; do
    echo -e "${C4}Choose result number for info or '0' for direct URL or 's' for new search:${C0} \c"
    read -r result

    case $result in
      [1-9]) # Selected info from current dataset (1-9).
        bookURL[$index]=${tmpURLs[((result - 1))]}
        echo -e "\n${C8}INFO: bookURL = ${bookURL[$index]}${C0}"
        ;;
      1[0-9]) # Select info from current dataset (10-19).
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

  ## Retrieve book information
  echo -e "${C8}\n>>> Retrieving book information...${C0}"
  curl -s "${bookURL[$index]}" \
    -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/115.0" \
    -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8" \
    -H "Accept-Language: en-US,en;q=0.5" -o "$kindle"

    #-H "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/110.0" \
    #-H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8" \

  _audible_asin=$(grep '#audibleAsin' "$kindle" | awk -F'[""]' '{ print $2 }')
  echo -e "${C2}_audible_asin: $_audible_asin${C0}"
  #_audible_url="https://www.amazon.com$(grep -m1 "<a href=\"/Audible-.*${_audible_asin}" "$kindle" |\
  #  awk -F'[""]' '{ print $2 }')"
  _audible_url="$(sed -rn "s/.*href=\"(.*${_audible_asin}.[^\"]+)\".*/\1/p" "$kindle" |\
    grep -m1 "${_audible_asin}")"
  echo -e "${C2}_audible_url: $_audible_url${C0}"
  
  if [[ -n $_audible_url ]]; then
    curl -s "https://www.amazon.com${_audible_url}" \
      -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/115.0" \
      -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8" \
      -H "Accept-Language: en-US,en;q=0.5" -o "$audible"
  fi

  return 0
}

parseInfo()
{
  ## NOTE: This is prone to failure due to many different versions of returned
  ##       data.  Multiple methods are used to attempt to gather as much as
  ##       possible.

  inFile=$1
  index=$2
  # Set various temp files to separate returned results (if run aborted, can be used
  # to update these methods for the dataset you have.  Good Luck!
  kindle="$workDir/kindle_${index}.html"
  audible="$workDir/audible_${index}.html"

  _fullTitle=$(grep -m 1 ' by \[' "$kindle" | hxnormalize | grep 'alt="' | awk -F'[""]' '{ print $2 }')
  _fullTitle=${_fullTitle//\&amp;/\&}
  _fullTitle=${_fullTitle//\&apos;/\'}
  echo -e "${C2}_fullTitle: $_fullTitle${C0}"
  _title=$(sed -rn 's/(.*) by \[.*/\1/p' <<< "$_fullTitle")
  echo -e "${C2}_title: $_title${C0}"
  _author=$(sed -rn 's/.*\[(.*)\]/\1/p' <<< "$_fullTitle" | sed 's/,.*//')
  echo -e "${C2}_author: $_author${C0}"
  _series=$(grep -E -m 1 'Book [0-9]{1,2} of ' "$kindle" | awk -F'[><]' '{ print $3 }' |\
    sed -rn 's/ (.*) $/\1/p')
  _series=${_series//\&amp;/\&}
  _series=${_series//\&apos;/\'}
  _series=${_series//\&#39;/\'}
  echo -e "${C2}_series: $_series${C0}"
  _pubDate=$(grep 'publication_date' "$kindle" | hxnormalize | grep -E '>[A-Z][a-z]+ [0-9]+, [0-9]{4}<' |\
    awk -F'[><]' '{ print $4 }')
  echo -e "${C2}_pubDate: $_pubDate${C0}"
  _description=$(grep '"book_description_expander"' "$kindle" | hxnormalize |\
    sed -e '/<span>/,/<\/span>/!d' | sed 's/<.*>//g; s/<\/div//')
  echo -e "${C2}_description: ${_description:0:80}...${C0}"
  _image=$(grep -m 1 ' by \[' "$kindle" | hxnormalize | grep 'src="' | awk -F'[""]' '{ print $2 }')
  echo -e "${C2}_image: $_image${C0}"
  _rating=$(grep -m 1 'data-action="acrStarsLink-click-metrics"' "$kindle" | hxnormalize |\
    grep 'title=' | awk -F'[""]' '{ print $2 }')
  echo -e "${C2}_rating: $_rating${C0}"
  _length=$(grep 'ebook_pages' "$kindle" | hxnormalize | grep -E '[0-9]+ pages' |\
    awk -F'[><]' '{ print $2 }')
  echo -e "${C2}_length: $_length${C0}"
  _asin=$(grep -m1 'id="ASIN"' "$kindle" | awk -F'[""]' '{ print $8 }')
  echo -e "${C2}_asin: $_asin${C0}"
  if [[ -e "$audible" ]]; then
    _a_pubDate=$(grep 'id="audibleProductDetails"' "$audible" | hxnormalize | grep -v '^$' |\
      grep -A1 'Date</span>' | tail -n +2 | awk -F'[><]' '{ print $5 }')
    echo -e "${C2}_a_pubDate: $_a_pubDate${C0}"
    _a_asin=$(grep 'id="audibleProductDetails"' "$audible" | hxnormalize | grep -v '^$' |\
      grep -A1 'ASIN' | tail -n +2 | awk -F'[><]' '{ print $5 }')
    echo -e "${C2}_a_asin: $_a_asin${C0}"
    _a_length=$(grep 'id="audibleProductDetails"' "$audible" | hxnormalize | grep -v '^$' |\
      grep -A1 'Length</span>' | tail -n +2 | awk -F'[><]' '{ print $5 }')
    echo -e "${C2}_a_length: $_a_length${C0}"
  fi

  if [[ -n $_a_pubDate ]]; then
    _pubDate=$_a_pubDate
  fi
  if [[ -n $_a_asin ]]; then
    _asin=$_a_asin
  fi
  if [[ -n $_a_length ]]; then
    _length=$_a_length
  fi

  # Trim colon after title text.
  #_title=$(sed 's/:.*//' <<< "$_title")
  _title=$(sed 's/:.*//; s/ (.*//g' <<< "$_title")
  
  #_title=${_title/:.*/}
  #_title=${_title/(.*/}
  
  ## Sanitize book title
  #_title=${_title//é/e}
  #_title=${_title//[^a-zA-Z0-9 &\-]/}

  # I give up!
  if [[ -z "$_title" ]]; then
    echo -e "${C4}Enter book title:${C0} \c"
    read -r bookTitle["$index"]
  else
    bookTitle[$index]="${_title}"
  fi

  # Sanitize book author
  _author=${_author/É/E}
  _author=${_author/\&apos;/\'}

  # I give up!
  if [[ -z $_author ]]; then
    echo -e "${C4}Enter book author:${C0} \c"
    read -r bookAuthor["$index"]
  else
    bookAuthor[$index]="$_author"
  fi
  ## Reverse author name and strip any ending '.'
  _authorReverse=$(awk '{$1=$NF", "$1;NF--} 1' <<< "${bookAuthor[$index]}" | sed 's/\.$//')
  # For one work authors
  bookAuthorReverse[$index]="${_authorReverse:-$_author}"

  bookYear[$index]="$_pubDate"
  bookASIN[$index]="$_asin"
  bookLength[$index]="$_length"
  bookRating[$index]="$_rating"
  #bookDescription[$index]="$_description"
  bookDescription[$index]="$(sed "s/&#x201[0-9];/'/g; s/&#x2026;/…/g; s/<\/.*//g; s/  >//g" <<< "$_description" |\
    grep -v '^$')"

  # I give up!
  if [[ -z "${bookYear[$index]}" ]]; then
    echo -e "${C4}Enter book year:${C0} \c"
    read -r bookYear["$index"]
  fi

  if [[ -z "${bookDescription[$index]}" ]]; then
    echo -e "${C4}Enter book discription:${C0}"
    vi "${workDir}/description-${index}.txt"
  fi

  if [[ -f "${workDir}/description-${index}.txt" ]]; then
    bookDescription["$index"]=$(fold -s "${workDir}/description-${index}.txt")
  fi

  _seriesNum=$(sed -rn 's/Book ([0-9]+) of.*/\1/p' <<< "$_series")
  _seriesNum=$(printf "%02d" "$_seriesNum")
  bookSeries[$index]="$(sed -rn 's/.*: (.*)/\1/p' <<< "$_series") $_seriesNum"
 
  # I give up!
  if [[ -z $_series ]]; then
    echo -e "${C4}Enter series information:${C0}: \c"
    read -r bookSeries["$index"]
  fi

  ## Get book cover 
  if [[ -n $_image ]]; then
    imageSource[$index]=$_image
  else
    echo -e "${C4}Enter book image url:${C0}: \c"
    read -r imageSource["$index"]
  fi

  baseName[$index]="${bookAuthor[$index]} - ${bookSeries[$index]} - ${bookTitle[$index]}"

  bookInfo[$index]="$workDir/${baseName[$index]}.info"
  #bookLink[$index]="$workDir/${baseName[$index]}.url"
  bookCover[$index]="$workDir/${baseName[$index]}.jpg"

  if [[ -n ${imageSource[$index]} ]]; then
    curl -s -o "${bookCover[$index]}" "${imageSource[$index]}"
  fi
  
#  cat <<EOF >"${bookLink[$index]}"
#[{000214A0-0000-0000-C000-000000000046}]
#Prop3=19,2
#[InternetShortcut]
#IDList=
#URL=${bookURL[$index]}
#EOF

### ffs, must be an easier way
#i=0
#while [[ $i -lt ${#_genre[*]} ]]; do
#  genre[$index]+=${_genre[$i]}', '
#  ((i++))
#done

  cat << EOF >> "${bookInfo[$index]}"
   Author: ${bookAuthor[$index]}
    Title: ${bookTitle[$index]}
   Length: ${bookLength[$index]}
     ASIN: ${bookASIN[$index]}
   Series: ${bookSeries[$index]}'
     Year: ${bookYear[$index]}
   Rating: ${bookRating[$index]}
  Bitrate: ${bookBitrate[$index]} kb/s
      URL: ${bookURL[$index]}
    Cover: ${imageSource[$index]}


Summary:
  ${bookDescription[$index]}
EOF

#sed -i "s/&#x201[0-9];/'/g; s/<\/.*//g; s/  >//g" "${bookDescription[$index]}"

  ## Old code but may be useful to parse info if encountered.
  # Replace extended characters with apostrophe
  # echo "X" | od -t x1c  # Display hex codes
  #sed -i 's/\xE2\x80\x9C/"/g; s/\xE2\x80\x9D/"/g; s/\xC3\x82//g; s/\xC5\x93/"/g; s/\xC2\x9D/"/g' "${bookInfo[$index]}"

  cat << EOF
  ${C0}   fullName: ${C7}${baseName[$index]}${C0}
  ${C2} bookAuthor: ${C8}${bookAuthor[$index]}${C0}
  ${C2}  bookTitle: ${C8}${bookTitle[$index]}${C0}
  ${C2}     Length: ${C8}${bookLength[$index]}${C0}
  ${C2} bookSeries: ${C8}${bookSeries[$index]}${C0}
  ${C2}   bookYear: ${C8}${bookYear[$index]}${C0}
  ${C2} bookRating: ${C8}${bookRating[$index]}${C0}
  ${C2}  bookCover: ${C8}${imageSource[$index]}${C0}
  ${C2}bookSummary:
${C8}${bookDescription[$index]}${C0}
EOF

  # Check converted.log for already converted.
  # Could add a pause here to verify all data before conversion if desired.
  if grep -q "${baseName[$index]}" "$convertLog"; then
    echo -e "${C4}SKIPPING:${C0} ${baseName[$index]} already converted."
    return 1
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
    echo -e "${C8}  bookCategory: $bookType ${C0}\n"
    return 0
  else
    cleanUp 20
  fi

  echo -e "${C8}>>> bookType: $bookType ${C0}"
}

checkFile()
{
  inFile=$1
  index=$2
  extension="${inFile##*.}"
  outFile="$workDir/$(basename "${inFile%.*}").mp3"

  # Check converted.log for already converted.
  if [[ -n "${baseName[$index]}" ]]; then
    if grep -q "${baseName[$index]}" "$convertLog"; then
      return 1
    fi
  fi

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
    echo -e "${C8}>>> Moving encoded files to .../${bookAuthorReverse[$index]}/${bookSeries[$index]} - ${bookTitle[$index]}${C0}"
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
    -v | --verify) # Verify ID3 tags
      #verify=true
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

