#!/bin/bash

#########################################################################################
#  SCRIPT: ccab.sh
#  AUTHOR: R. Paxton
#  DATE:   09/25/2016
#  UPDATED: 03/05/2017 - rlp
#
#  PURPOSE: This script is used to scan and re-encode audiobooks. It will detect
#           m4a, m4b, or mp3 files and re-encode them to a target bitrate
#           (default 48K) or less if source is lower.  The script will attempt
#           to lookup the audiobook on Goodreads web site based on the ID3 tags.
#           If the lookup fails, the script will prompt for book information.
#
#           The script is controlled via the command options as listed below.
#
#########################################################################################
#
#  USAGE:   ccab.sh [-c ||--concat] [-m ||--move] [-mo] [-mp3] [-m4b] [-r] [-t] [-v]
#
#  -c || --concat : Will combine detected files into a single .mp3
#  -d || --debug  : Enable debug output.
#  -m || --move   : After re-encoding, will move new files to specified
#                   directory (baseDir). May add option value on the command
#                   line to avoid prompting if book type is know before hand
#                   (-m #).
#  -mo      : Will move previously encoded files to target directory.
#  -mp3     : Will limit search of input files to .mp3 files only.
#  -m4b     : Will limit search of input files to .m4a or .m4b files
#             only.
#  -r       : Will search subdirectories for input files, make sure
#             subdirectories or zero padded if more that 9 subs (ex.
#             /disk 1 ==> /disk 01).
#  -t       : Edit discovered IDv3 tags before writing.
#  --trace  : Enable trace loggin during run.
#  -v       : Will prompt for verification of detected book information.
#
#  NOTE: Other options are not fully implemented.
#
#########################################################################################
#
#  DEBUG: Debug output can be enable by specifying the -d or --debug option
#         along with the level of debug [1 or 2].
#
#  CONVERTED: If $convertLog specified, successful encodes will be logged to
#             this file, to track what files have been processed.
#
#########################################################################################


### START OF USER OPTIONS ###

targetBitrate=48                                 # Set this to desired bitrate for output files.
logDir='/var/log/ccab'                           # Working directory (logs and such)
baseDir='/audio/audiobooks'                      # Base directory to move encoded files to.
convertLog="$logDir/converted.log"               # Successful encoding log file.
workDir='/tmp/ccab.tmp'                          # Temp directory for work files (removed if successful).
user='rp01'
group='admins'

### END OF USER OPTIONS ###

mkdir -p "$logDir" >/dev/null 2>&1
mkdir -p "$workDir" >/dev/null 2>&1

# Declare global variables
typeset searchType bookTitle bookAuthor bookSeries bookBitrate baseName bookURL searchInfo outFile bookType

concat=false
recurse=false
move=false
options=$*

trap 'abort' 1 2 3 15

C1="$(printf '\033[38;5;040m')"  # Green
C2="$(printf '\033[38;5;236m')"  # Grey
C3="$(printf '\033[38;5;254m')"  # Hi-Lite
C4="$(printf '\033[38;5;184m')"  # Yellow
C5="$(printf '\033[38;5;160m')"  # Red
C6="$(printf '\033[38;5;164m')"  # Purple
C7="$(printf '\033[38;5;063m')"  # Blue
C8="$(printf '\033[38;5;240m')"  # Lt Grey
C0="$(printf '\033[0;00m')"      # Reset

# Check for command line arguments.
if [ "$#" -lt 1 ]; then
  cat << EOM
    -c || --concat    : Will combine detected files into a single .mp3
    -d || --debug     : Enable debug output (must specify level [1 or 2]
    -m || --move      : After re-encoding, will move new files to specified
                        directory (baseDir). May add option value on the command
                        line to avoid prompting if book type is know before hand
                        (-m #).
                         Move Catagories:
                            1 = Romance
                            2 = Hot
                            3 = SciFi
                            4 = Fantasy
                            5 = Thriller
                            6 = Misc
    -mp3              : Will limit search of input files to .mp3 files only.
    -m4b              : Will limit search of input files to .m4a or .m4b files
                        only.
    -r || --recurse   : Will search subdirectories for input files, make sure
                        subdirectories are zero padded if more that 9 subs (ex.
                        /disk 1 ==> /disk 01).

EOM
  exit 1
fi

# -----------------------------------------------
# Check for required packages.
# -----------------------------------------------
command -v ffprobe >/dev/null 2>&1 || { echo "ERROR: Unable to detect ffprobe, bailing." >&2; exit 1; }
  echo " > sudo yum -y install ffmpeg"
command -v ffmpeg >/dev/null 2>&1 || { echo "ERROR: Unable to detect ffmpeg, bailing." >&2; exit 1; }
  echo " > sudo yum -y install ffmpeg"
command -v mid3v2 >/dev/null 2>&1 || { echo "ERROR: Unable to detect mid3v2, bailing." >&2; \
  echo "  > sudo git clone https://github.com/quodlibet/mutagen.git /downloads/mid3v2"; exit 1; }
command -v fancy_audio >/dev/null 2>&1 || { echo "ERROR: Unable to detect fancy_audio, bailing." >&2; \
  echo "  > sudo gem install fancy_audio"; exit 1; }
command -v googler >/dev/null 2>&1 || { echo "ERROR: Unable to detect googler, bailing." >&2; \
  echo "  > sudo git clone https://github.com/jarun/googler.git /downloads/googler"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: Unable to detect curl, bailing." >&2; exit 1; }
  echo "  > sudo yum -y install curl"
command -v lame >/dev/null 2>&1 || { echo "ERROR: Unable to detect lame, bailing." >&2; exit 1; }
  echo "  > sudo yum -y install lame"

# -----------------------------------------------
# Get user options
# -----------------------------------------------
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    -b | --bitrate) # Target bitrate
      targetBitrate=${2:-48}
      shift 2
      ;;
    -c | --concat) # Concat all files found
      concat='true'
      shift
      ;;
    -d | --debug) # Set debug level
      set -x
      shift
      ;;
    -m | --move)  # Move output files to defined location
      move='true'
      catagory=$2
      if [[ $catagory = '-'[a-z] || -z $catagory ]]; then
        unset catagory
        shift
      else
        shift 2
      fi
      ;;
    --mp3) # only search for mp3 files
      searchType=".*\(mp3\)$"
      shift
      ;;
    --flac) # only search for mp3 files
      searchType=".*\(flac\)$"
      shift
      ;;
    --m4b) # only search for m4a/m4b files
      searchType=".*\(m4a\|m4b\)$"
      shift
      ;;
    -r | --recurse) # Search sub directories for files
      recurse=true
      shift
      ;;
    *)  # Unknown option
      echo -e "${C5}ERROR: 10 - Unknown option '$1'${C0}"
      exit 10
      ;;
  esac
done

# -----------------------------------------------
# Define script functions
# -----------------------------------------------
abort()
{
  tput cnorm
  exit 9
}

cleanUp()
{
  STATUS=$1

  if (( STATUS == 0 )); then
    echo -e "${C8}INFO${C0}: Cleaning temp files"
    rm -rf "${workDir:?}"
  fi

  echo -e "${C1}\nDone!${C0} STATUS: ${C3}$STATUS${C0}"
  exit "$STATUS"
}

getFiles()
{
  ## Collect incoming files
  fileList="$workDir"/ccab_files.list
  searchType=${searchType:-'\(mp3\|m4a\|m4b\|flac\)'}
  
  if [[ ! -d "$workDir" ]]; then
    mkdir "$workDir"
  fi
  
  if [[ $recurse == 'true' ]]; then
    find . -type f -iregex ".*.${searchType}" -printf '%h/%f\n' |\
      grep -v 'ccab' | sort -h > $fileList
  else
    find . -maxdepth 1 -type f -iregex ".*.${searchType}" -printf '%h/%f\n' |\
      grep -v 'ccab' | sort -h > $fileList
  fi
  
  mapfile -t inFiles < <(cat "$fileList")

  return 0
}

probeFile()
{
  # Gather information on the book (title, series, info, etc.).
  probeFile="$workDir/probe.txt"

  # set -x
  inFile="$1"

  ffprobe -hide_banner "$inFile" >"$probeFile" 2>&1

  album=$(sed -n 's/\ *album\ *:\ \(.*\)$/\1/p' "$probeFile")
  artist=$(sed -n 's/\ *artist\ *:\ \(.*\)$/\1/p' "$probeFile")
  author=$(sed -n 's/\ *author\ *:\ \(.*\)$/\1/p' "$probeFile")
  album_artist=$(sed -n 's/\ *album_artist\ *:\ \(.*\)$/\1/p' "$probeFile")
  title=$(sed -n 's/\ *title\ *:\ \(.*\)$/\1/p' "$probeFile")
  date=$(sed -n 's/\ *date\ *:\ \(.*\)$/\1/p' "$probeFile")

  ## Set book title
  bookTitle="${album:-$title}"

  ## Set book author.
  bookAuthor="${author:-$artist}"
  bookAuthor="${bookAuthor:-$album_artist}"
  ## Fix accented names
  bookAuthor=${bookAuthor/É/E}

  if [[ -z $bookTitle ]]; then
    echo -e "${C3}Enter the title of the book${C0} [$bookTitle]: \c"
    read -r tempTitle
    bookTitle=${tempTitle:-$bookTitle}
  fi

  if [[ -z $bookAuthor ]]; then
    echo -e "${C3}Enter the author of the book${C0} [$bookAuthor]: \c"
    read -r tempAuthor
    bookAuthor=${tempAuthor:-$bookAuthor}
  fi
 
  origBitrate=$(grep 'Audio:' "$probeFile" | awk -F', ' '{ print $5 }' | awk '{ print $1 }')
  if [[ $origBitrate -gt $targetBitrate ]]; then
    bookBitrate=$targetBitrate
  elif [[ $origBitrate -gt 40 ]]; then
    bookBitrate=48
  else
    bookBitrate=32
  fi

  bookDate="$date"

  cat <<EOF
  bookTitle          =  $bookTitle
  bookAuthor         =  $bookAuthor
  bookBitrate        =  $bookBitrate
  bookDate           =  $bookDate
EOF

  if [[ -z $bookTitle || -z $bookAuthor ]]; then
    echo -e "${C5}ERROR:${C0} No book information found."
    return 1
  else
    return 0
  fi
}

searchInfo()
{
  searchData="$1"
    searchData=$(sed 's/([Uu]nabridged)//' <<< "$searchData")

  ## Search for book information on goodreads.
  searchResults="$workDir/search.results"
  searchInfo="$workDir/search.html"
  searchRaw="$workDir/search.raw"
  result=0

  if [[ ! -d "$workDir" ]]; then
    mkdir "$workDir"
  fi

  if [[ -n $searchData ]]; then
    echo -e "Search string: ${C4}$searchData${C0}"
    googler -n 5 --np -w www.goodreads.com "$searchData" | tee "$searchResults"
  else
    result=6
  fi

  while [[ $result -lt 1 || $result -gt 5 ]]; do
    if [[ $result -eq 6 ]]; then
      echo -e "${C4}Enter new search string: ${C0}\c"
      read -r searchData
      googler -n 5 --np -w www.goodreads.com "$searchData" | tee "$searchResults"
      result=0
    elif [[ $result -eq 7 ]]; then
      echo -e "${C4}Enter book URL manually: ${C0}\c"
      read -r bookURL
      break
    else
      echo -e "${C6}Pick the number of the link results to use for info ('6' for new search, '7' direct URL):${C0} \c"
      read -r result
    fi
  done

  if [[ -z "$bookURL" ]]; then
    mapfile -t tmpURLs < <(grep 'www.goodreads.com' "$searchResults" | tr -d ' ')
    bookURL=${tmpURLs[((result - 1))]}
  fi

  echo "  bookURL = $bookURL"

  if [[ -n $bookURL ]]; then
    curl -sL "$bookURL" -o "$searchRaw"
    hxnormalize -l 9999 < "$searchRaw" > $searchInfo 2>/dev/null
    return 0
  else
    echo "No book URL found, bailing."
    return 1
  fi
}

parseInfo()
{
  ## Scrape results for book information.
  title1=$(grep 'property=.og:title' "$searchInfo" | awk -F'[""]' '{ print $2 }')
  title2=$(grep -m 1 '<title>' "$searchInfo" | hxselect -ic title | awk -F' by ' '{ print $1 }')
  fullTitle=${title1:-$title2}
  bookTitle=$(sed -n 's/\(.*\) (.*)/\1/p' <<< "$fullTitle")

  author=$(grep -m 1 '<title>' "$searchInfo" | hxselect -ic title | awk -F' by ' '{ print $2 }')
  bookAuthor=${author:-$bookAuthor}
    bookAuthor=${bookAuthor/É/E}
  ## Reverse author name and strip any ending '.'
  bookAuthorReverse=$(awk '{$1=$NF", "$1;NF--} 1' <<< "$bookAuthor" | sed 's/\.$//')

  bookISBN=$(grep -m 1 'itemprop=isbn' "$searchInfo" | hxselect -ic div)
  bookYear=$(grep -m 1 'Published' "$searchInfo" | sed -rn 's/.*([0-9]{4}).*/\1/p')

  if grep -q '(' <<< "$fullTitle"; then
    fullSeries=$(awk -F'[()]' '{ print $2 }' <<< "$fullTitle")
    if grep -q ', #' <<< "$fullSeries"; then
      sep=1
    elif grep -q ' Book ' <<< "$fullSeries"; then
      sep=2
    else
      sep=3
    fi
  fi

  if [[ -n $fullSeries ]]; then
    case $sep in
      1) bookSeries=$(awk -F', #' '{ print $1 }' <<< "$fullSeries")
         seriesNum=$(awk -F', #' '{ print $2 }' <<< "$fullSeries")
         ;;
      2) bookSeries=$(awk -F' Book ' '{ print $1 }' <<< "$fullSeries")
         seriesNum=$(awk -F' Book ' '{ print $2 }' <<< "$fullSeries")
         ;;
      3) bookSeries=$fullSeries
         ;;
      *) bookSeries="Unknown"
         ;;
     esac

    majNum=$(awk -F'.' '{ printf("%02d", $1) }' <<< "$seriesNum")
    minNum=$(awk -F'.' '{ print $2 }' <<< "$seriesNum")

    if [[ $majNum == '00' ]]; then
      unset seriesNum
    elif [[ -n $minNum ]]; then
      seriesNum="${majNum}.${minNum}"
    else
      seriesNum="$majNum"
    fi

    if [[ -n $seriesNum ]]; then
      bookSeries="$bookSeries $seriesNum"
    fi

  else
    bookSeries=$bookYear
  fi

  bookRating=$(grep 'ratingValue' "$searchInfo" | sed -rn 's/.*([0-9]\.[0-9]{2}).*/\1/p')

  image1=$(grep 'id=coverImage' "$searchInfo" | sed -n 's/.*src="\(.*\)">.*/\1/p')
  image2=$(grep -m 1 -i 'editioncover' "$searchInfo" | sed -n 's/.*src="\(.*\)">.*/\1/p')
  imageSource=${image1:-$image2}

  baseName="$bookAuthor - $bookSeries - $bookTitle"
  bookInfo="$workDir/${baseName}.info"
  bookLink="$workDir/${baseName}.url"
  bookCover="$workDir/${baseName}.jpg"

  if [[ -n $imageSource ]]; then
    curl -s -o "$bookCover" "$imageSource" 
  fi

  cat <<EOF >"$bookLink"
[{000214A0-0000-0000-C000-000000000046}]
Prop3=19,2
[InternetShortcut]
IDList=
URL=$bookURL
EOF

  cat << EOF >> "$bookInfo"
Author:   $bookAuthor
Title:    $bookTitle
ISBN:     $bookISBN
Series:   $bookSeries
Year:     $bookYear
Rating:   $bookRating
Bitrate:  $bookBitrate kb/s
URL:      $bookURL
Image:    $imageSource


Classifications:
$(grep 'people shelved this book' "$searchInfo" | sed -n 's/&#39;//g; s/.*title="\(.*\)">.*/\1/; s/^/  /p')


Summary:
  $(sed -n '/descriptionContainer/,/^$/p' "$searchInfo" | tail -n +6 | grep -v '^ *<' | sed 's/<.*.//g; s/^ *//g' | fold -w 80 -s)
EOF

  # Replace extended characters with apostrophe
  # echo "X" | od -t x1c  # Display hex codes
  sed -i 's/\xE2\x80\x9C/"/g; s/\xE2\x80\x9D/"/g; s/\xC3\x82//g; s/\xC5\x93/"/g; s/\xC2\x9D/"/g' "$bookInfo"

  return 0
}

promptTags()
{
  inFile=$1

  ## Manually set ID3 tags
  echo -e "${C3}No ID3 tags found in $inFile${C0}"
  tempTitle=$bookTitle
  echo -e "${C3}  Please enter a title for this book [${C4}${tempTitle}${C3}]${C0}: \c"
  read -r bookTitle
  bookTitle=${bookTitle:-$tempTitle}

  tempAuthor=$bookAuthor
  echo -e "${C3}  Please enter an author for this book [${C4}${tempAuthor}${C3}]${C0}: \c"
  read -r bookAuthor
  bookAuthor=${bookAuthor:-$tempAuthor}

  fullName="$bookAuthor - $bookSeries - $bookTitle"
  echo -e " INFO: bookTitle = ${C3}$bookTitle${C0}"
  echo -e " INFO: bookAuthor = ${C3}$bookAuthor${C0}"
  echo -e " INFO: fullName = ${C3}$fullName${C0}"

  return 0
}

checkFile()
{
  ## This function will convert non-mp3 files to mp3 and concatenate if set.
  catFile="${workDir}/ccab_concat.mp3"
  i=0

  while [[ $i -lt ${#inFiles[*]} ]]; do
    extension=${inFiles[$i]##*.}
    inFile=${inFiles[$i]}
    outFile="$workDir/${inFiles[$i]%.*}.mp3"

    if [[ ${extension,,} != 'mp3' && ! -s "$outFile" ]]; then
      ffmpeg -hide_banner -loglevel error -stats -i "$inFile" -vn -sn "$outFile"
      ## Reset inFile to converted file
      inFiles[$i]=$outFile
    fi
    ((i++))
  done
  
  if [[ $concat == 'true' ]]; then
    i=0
    find "$workDir" -name "ccab_concat*" -delete
    while [[ $i -lt ${#inFiles[*]} ]]; do
      echo "${C8}> Adding ${C7}${inFiles[$i]}${C0}"
      cat "${inFiles[$i]}" >> "$catFile"
      ((i++))
    done
    inFiles[0]="$catFile"
  fi
}

tagIt()
{
  # Attempted to use several command line tag editors, mid3v2 does most of what I needed, but has some 
  # issues with cover art....
  inFile=$1
  shortName=$(basename "$inFile")

  echo -e "${C8}> Removing original ID3 tags on: ${C7}$shortName${C0}"
  mid3v2 --delete-all "$inFile" >/dev/null 2>&1
  if [[ -s "$bookCover" ]]; then
    echo -e "${C8}> Adding book cover image to: ${C7}$shortName${C0}"
    # Falling back to fancy_audio for cover art :/.
    fancy_audio "$inFile" "$bookCover"
  fi
  echo -e "${C8}> Adding ID3 tags to: ${C7}$shortName${C0}"
  #shellcheck disable=SC2140
  mid3v2 -a "$bookAuthor" -A "$bookSeries" -t "$bookTitle" -g 'audiobook' -T 1 -c "Comment":"$bookURL":"eng" \
    -c "Rating":"$bookRating":"eng" -c "Encoded by":"theGh0st":"eng" "$inFile" > /dev/null

  return 0
}

reEncode()
{
  i=0
    inFile=$1
    outFile="$workDir/${baseName}.abr${bookBitrate}.mp3"

    # Check converted.log for already converted.
    if grep -q "$baseName" "$convertLog"; then
      echo -e "${C4}WARNING: ${C3}$inFile${C0} has already been converted."
      #return 1
    fi

    # Re-encode input file with my parameters.
    if [[ ! -s "$outFile" ]]; then
      echo -e "${C2}"
      lame --nohist -m m -V 6 "$inFile" "$outFile"
      STATUS=$?
      echo -e "${C0}"
    else
      # File previously encoded.
      echo -e "${C4}WARNING: ${C3}$inFile${C0} already encoded."
      STATUS=2
      return $STATUS
    fi
  
    if [[ $STATUS -gt 0 ]]; then
      echo -e "${C5}ERROR:${C3}$STATUS${C0} During lame encoding."
      return $STATUS
    else
      echo -e "${C1}OK:${C0} lame encoding successful."
      echo "$outFile" >> done.txt
      return 0
    fi
}

moveIt()
{

  # Check if book catagory specified in arguments.
  if [[ -n $catagory ]]; then
    REPLY=$catagory
    case $REPLY in
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
        unset catagory
        ;;
    esac
  fi

  # Prompt for book catagory if not specified.
  PS3="Select book type: "
  while [[ -z $catagory ]]; do
    echo -e "\n${C4}Available book types${C0}\n"
    # zzshellcheck disable=2034
    select bookType in Romance Erotica SciFi Fantasy Thriller Misc Quit
    do
      case $REPLY in
        1) # Romance
          #bookType="Romance"
          Check=1
          break
          ;;
        2) # Erotica
          #bookType="Erotica"
          Check=1
          break
          ;;
        3) # SciFi
          #bookType="SciFi"
          Check=1
          break
          ;;
        4) # Fantasy
          #bookType="Fantasy"
          Check=1
          break
          ;;
        5) # Thriller
          #bookType="Thriller"
          Check=1
          break
          ;;
        6) # Misc
          #bookType="Misc"
          Check=1
          break
          ;;
        7) # Quit
          echo -e "\nBailing now!"
          Check=1
          exit 5
          ;;
        *) # Unknown
          echo -e "\nUnknown option [${REPLY}]"
          Check=0
          break
          ;;
      esac
    done
    if [[ $Check -eq 1 ]]; then
      break
    fi
  done

  outDir="$baseDir/$bookType/$bookAuthorReverse/$bookSeries - $bookTitle"

  if [[ ! -d "$outDir" ]]; then
    mkdir -p "$outDir"
  fi

  shortName=$(basename "$inFile")
  echo -e "\n${C8}> Moving ${C7}$shortName${C8} to ${C7}$outDir${C0}"
  mv "$outFile" "$outDir"
  STATUS=$?
  mv "$bookInfo" "$outDir"
  mv "$bookCover" "$outDir"
  mv "$bookLink" "$outDir"

  if [[ $STATUS -eq 0 ]]; then
    chown -R $user:$group "$baseDir/$bookType/$bookAuthorReverse"
    find "$baseDir/$bookType/$bookAuthorReverse" -type d -exec chmod 775 {} \;
    find "$baseDir/$bookType/$bookAuthorReverse" -type f -exec chmod 664 {} \;
  
    mDate=$(date +%Y-%b-%d)
    mDate=${mDate^^}
    
    echo "$mDate, [$bookType], $(basename "$outFile")" >> $convertLog
    return 0
  else
    echo -e "${C5}ERROR:${C0} Moving files to $outDir"
    return $STATUS
  fi
}

# -----------------------------------------------
# MAIN
# -----------------------------------------------
echo -e " MAIN: $0 options = ${C3}$options${C0}"
rm -f "${workDir:?}"/*
echo -e " MAIN: calling ${C6}getFiles()${C0}"
getFiles

probeFile "${inFiles[0]}"
CHECK=$?

if [[ $CHECK -gt 0 ]]; then
  promptTags "${inFiles[0]}"
fi

searchInfo "${bookTitle} ${bookAuthor}"

parseInfo

echo ""
cat "$bookInfo"
echo ""

checkFile

reEncode "${inFiles[0]}"
CHECK=$?

if [[ $CHECK -gt 0 ]]; then
  echo "Error during reEncode, bailing."
  exit $CHECK
fi

tagIt "$outFile"

if [[ $move == 'true' ]]; then
  moveIt
  CHECK=$?
fi

