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

  ## Set book title
  _bookTitle="${_album:-$_title}"
  # _bookTitle="${_title:-$_album}"
  _bookTitle=${_bookTitle//[^a-zA-Z ]/}

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
  _results="$workDir/results.html"
  url="www.goodreads.com"

  _searchData=${_searchData//[Uu]nabridged/}
  echo -e "\n${C8}>>> Searching for: '${_searchData// /+}'${C0}\n"
  _searchData="https://${url}/search?q=${_searchData// /+}"
  echo -e "${C2}$_searchData${C0}"
  curl -s "$_searchData" > "$_results"

  mapfile -t tmpURLs < <(grep '<a title=' "$_results" | sed -rn "s/.*href=\"(.[^?]*).*/https:\/\/${url}\1/p")
  mapfile -t tmpTitle < <(grep '<span ' "$_results" | grep 'role=.heading.' | awk -F'[><]' '{ print $3 }')

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
  searchInfo="$workDir/$(basename "${inFile%.*}").html"
  searchRaw="$workDir/$(basename "${inFile%.*}").raw"

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
        read -r bookURL[$index]
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
  while [[ ! -s "$searchRaw" ]]; do
    if $debug; then
      echo -e "${C2}++curl -sL \"${bookURL[$index]}\" -o \"$searchRaw\"${C0}"
    fi
    curl -sL "${bookURL[$index]}" -o "$searchRaw"
    sleep .5
  done

  ## Attempt to normalize html results
  hxnormalize -l 9999 < "$searchRaw" > "$searchInfo" 2>/dev/null

  return 0
}

parseInfo()
{
  ## NOTE: This is prone to failure due to many different versions of returned
  ##       data.  Multiple methods are used to attempt to gather as much as
  ##       possible.

  inFile=$1
  index=$2
  searchInfo="$workDir/$(basename "${inFile%.*}").html"
  header="$workDir/$(basename "${inFile%.*}").header"
  props="$workDir/$(basename "${inFile%.*}").props"
  unset _fullTitle
  grep -i 'author' "$searchInfo" | grep '<script' | sed 's/\",\"/\n/g' | tr -d '"' > "$header"
  grep '"props":' "$searchInfo" | sed 's/\",\"/\n/g' | tr -d '"' > "$props"
  echo -e "${C8}>>> Parsing information...${C0}"

  # METHOD #1
  if grep -q 'image:' "$header"; then
    echo -e "${C2}parse method #1${C0}"
    _fullTitle=$(grep -m1 'name:' "$header" | awk -F: '{ print $2}')
    _author=$(grep -A1 -m1 'author' "$header" | grep -v 'author' | awk -F: '{ print $2 }')
    _title=$(sed -rn 's/^(.[^\(]+) .*/\1/p' <<< "$_fullTitle")
    _series=$(sed -rn 's/^.*\((.*)\)/\1/p' <<< "$_fullTitle")
    _image=$(grep -m1 'image:' "$header" | sed 's/image://')
    _rating=$(grep rating "$header" | tr ',' '\n' | grep 'ratingValue:' | awk -F: '{ print $2 }')
  fi

  # METHOD #2
  if [[ -z $_fullTitle ]]; then
    echo -e "${C2}parse method #2${C0}"
    _fullTitle=$(grep -i 'property="og:title"' "$searchInfo" | awk -F'[""]' '{ print $2 }')
    _author=$(grep -m1 '<title>' "$searchInfo" | awk -F' by ' '{ print $2 }' |\
      sed -rn 's/^(.*) \|.*/\1/p')
    _title=$(sed -rn 's/^(.[^\(]+) .*/\1/p' <<< "$_fullTitle")
    _series=$(sed -rn 's/^.*\((.*)\)/\1/p' <<< "$_fullTitle")
    _image=$(grep '"props":' "$searchInfo" | tr ',' '\n' | grep 'imageUrl' | tr -d '"' |\
      sed 's/imageUrl://')
    _rating=$(grep '"props":' "$searchInfo" | tr ',' '\n' | grep 'averageRating' |\
      awk -F: '{ print $2 }')
  fi

  # METHOD #3
  if [[ -z $_fullTitle ]]; then
    echo -e "${C2}parse method #3${C0}"
    _fullTitle=$(grep 'titleComplete:' "$props" | sed 's/titleComplete://')
    _author=$(grep -A1 -m1 ':Contributor' "$props" | grep '\bname:' | sed -rn 's/.*:(.*)/\1/p')
    _title=$(sed -rn 's/^(.[^\(]+) .*/\1/p' <<< "$_fullTitle")
    _series=$(sed -rn 's/^.*\((.*)\)/\1/p' <<< "$_fullTitle")
    _image=$(grep 'imageUrl:' "$props" | sed -rn 's/.*(https:.*)/\1/p')
    _rating=$(grep 'averageRating:' "$props" | sed -rn 's/averageRating:(.[^,]*),.*/\1/p')
  fi

  ## Sanitize book title
  _title=${_title/&amp;/&}
  _title=${_title/&#x27;/\'}
  _title=${_title//:/-}
  _title=${_title//é/e}
  _title=${_title//[^a-zA-Z0-9 -&]/}
  bookTitle[$index]="$_title"

  # I give up!
  if [[ -z ${bookTitle[$index]} ]]; then
    echo -e "${C4}Enter book title:${C0}: \c"
    read -r _bookTitle
    bookTitle[$index]=$_bookTitle
  fi

  # Sanitize book author
  _author=${_author/É/E}
  _author=${_author//[^a-zA-Z0-9 -.]/}

  # I give up!
  if [[ -z $_author ]]; then
    echo -e "${C4}Enter book author:${C0}: \c"
    read -r _author
  fi
  ## Reverse author name and strip any ending '.'
  _authorReverse=$(awk '{$1=$NF", "$1;NF--} 1' <<< "$_author" | sed 's/\.$//')
  bookAuthor[$index]="$_author"
  # For one work authors
  bookAuthorReverse[$index]="${_authorReverse:-$_author}"

  #TODO: Move to above methods
  #bookISBN[$index]=$(grep -m 1 'itemprop=isbn' "$searchInfo" | hxselect -ic div | awk '{ print $1 }')
  _isbn1=$(grep -m 1 'isbn' "$searchInfo" | sed -rn 's/.*\"isbn\"\:(\w+),.*/\1/p')
  _isbn2=$(grep 'books:isbn' "$searchInfo" | sed -rn 's/.*tent=(.*) prop.*/\1/p')
  bookISBN[$index]=${_isbn1:-$_isbn2}
  bookASIN[$index]=$(grep -im 1 'asin' "$searchInfo" | sed -rn 's/.*ASIN=(\w+)\\.*/\1/p')


  #pubInfo=$(grep -m 1 -P 'Published.*[1-2][0-9]{3}' "$searchInfo" | sed -rn 's/.*(Pub.*)<.*/\1/p')
  pubInfo=$(grep -m 1 'publicationInfo' "$searchInfo" | hxnormalize | hxselect -ic p |\
    sed 's/Published //')
  bookYear[$index]=$(sed -rn 's/.*([0-9]{4}).*/\1/p' <<< "$pubInfo")
  bookPublisher[$index]=$(awk -F' by ' '{ print $2 }' <<< "$pubInfo")

  # I give up!
  if [[ -z $_series ]]; then
    echo -e "${C4}Enter book series:${C0}: \c"
    read -r fullSeries
  else
    fullSeries="$_series"
  fi
  echo -e "${C2}++fullSeries=$fullSeries${C0}"

  if grep -q ', #' <<< "$fullSeries"; then
    sep=1
  elif grep -q ' #' <<< "$fullSeries"; then
    sep=2
  elif grep -q ' Book ' <<< "$fullSeries"; then
    sep=3
  else
    sep=4
  fi

  case $sep in
    1) _bookSeries=$(awk -F', #' '{ print $1 }' <<< "$fullSeries")
       _seriesNum=$(awk -F', #' '{ print $2 }' <<< "$fullSeries")
       ;;
    2) _bookSeries=$(awk -F' #' '{ print $1 }' <<< "$fullSeries")
       _seriesNum=$(awk -F' #' '{ print $2 }' <<< "$fullSeries")
       ;;
    3) _bookSeries=$(awk -F' Book ' '{ print $1 }' <<< "$fullSeries")
       _seriesNum=$(awk -F' Book ' '{ print $2 }' <<< "$fullSeries")
       ;;
    4) _bookSeries=$fullSeries
       ;;
    *) _bookSeries="Unknown"
       ;;
   esac

  majNum=$(awk -F'.' '{ printf("%02d", $1) }' <<< "$_seriesNum")
  minNum=$(awk -F'.' '{ print $2 }' <<< "$_seriesNum")

  if [[ $majNum == '00' ]]; then
    unset _seriesNum
  elif [[ -n $minNum ]]; then
    _seriesNum="${majNum}.${minNum}"
  else
    _seriesNum="$majNum"
  fi

  if [[ -n $_seriesNum ]]; then
    _bookSeries="$_bookSeries $_seriesNum"
  else
    _bookSeries=${bookYear[$index]:-unknwn}
  fi

  _bookSeries=${_bookSeries/:/-}
  _bookSeries=${_bookSeries/&apos;/\'}
  _bookSeries=${_bookSeries//[^a-zA-Z0-9 -]/}
  bookSeries[$index]=$_bookSeries

  bookRating[$index]=$_rating

  if [[ -n $_image ]]; then
    imageSource[$index]=$_image
  else
    echo -e "${C4}Enter book image url:${C0}: \c"
    read -r imageSource[$index]
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

summary=$(grep -A1 'titleComplete:' "$props" | grep 'description:' | sed 's/description://' | fold -s)
# Filters to sanitize description text.
summary=${summary//\/\\u003e/}
summary=${summary//\\u003cbr/}
mapfile _genre < <(grep -A1 ':Genre' "$props" | grep -E '^name:' | awk -F: '{ print $2}')

  cat << EOF >> "${bookInfo[$index]}"
   Author: ${bookAuthor[$index]}
    Title: ${bookTitle[$index]}
     ASIN: ${bookASIN[$index]}
     ISBN: ${bookISBN[$index]}
   Series: ${bookSeries[$index]}
     Year: ${bookYear[$index]}
Publisher: ${bookPublisher[$index]}
   Rating: ${bookRating[$index]}
  Bitrate: ${bookBitrate[$index]} kb/s
      URL: ${bookURL[$index]}
    Cover: ${imageSource[$index]}


Classifications:
  ${_genre[@]}


Summary:
  $summary
EOF

  # Replace extended characters with apostrophe
  # echo "X" | od -t x1c  # Display hex codes
  #sed -i 's/\xE2\x80\x9C/"/g; s/\xE2\x80\x9D/"/g; s/\xC3\x82//g; s/\xC5\x93/"/g; s/\xC2\x9D/"/g' "${bookInfo[$index]}"

  cat << EOF
  ${C0}bookAuthor: ${C7}${bookAuthor[$index]:0:80}${C0}
  ${C0}bookTitle: ${C7}${bookTitle[$index]:0:80}${C0}
  ${C0}bookSeries: ${C7}${bookSeries[$index]:0:80}${C0}
  ${C0}bookYear: ${C7}${bookYear[$index]}${C0}
  ${C0}bookRating: ${C7}${bookRating[$index]}${C0}
  ${C0}bookCover: ${C7}${imageSource[$index]}${C0}
  ${C0}bookGenre: ${C7}${_genre[@]}${C0}
  ${C0}bookSummary: ${C7}${summary}${C0}
EOF

  # Check converted.log for already converted.
  if grep -q "${baseName[$index]}" "$convertLog"; then
    echo -e "${C4}SKIPPING:${C0} ${baseName[$index]} already converted."
    return 1
  else
    echo -e "${C1}Converting now${C0}"
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

