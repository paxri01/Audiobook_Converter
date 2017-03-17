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
#  -v       : Will prompt for verification of detected book information.
#
#  NOTE: Other options are not fully implemented.
#
#########################################################################################
#
#  TRACING: The details of the file processing is logged to $ccLog output for
#           debugging or tracing processing. $ccError has limited value as 
#           only odd errors typically get logged to it, but may be worth
#           checking if problems occur.
#
#  CONVERTED: If $convertLog specified, successful encodes will be logged to
#             this file, to track what files have been processed.
#
#########################################################################################

### START OF USER OPTIONS ###

targetBitrate=48                                 # Set this to desired bitrate for output files.
ffOptions="-loglevel fatal -hide_banner -y"      # Don't change this unless you know ffmpeg.
workDir=/mnt/vuze/logs                           # Working directory (logs and such)
baseDir=/mnt/audiobooks                          # Base directory to move encoded files to.
ccLog=$workDir/ccab-$(date +%Y%m%d).log          # Output log file.
ccError=$workDir/ccab-error-$(date +%Y%m%d).log  # Output tracing file.
m4bLog=$workDir/m4b-convert.log                  # Only used for m4b logging.
convertLog=$workDir/converted.log                # Successful encoding log file.

### END OF USER OPTIONS ###

typeset bookAuthor bookSeries bookTitle baseName bookType fullName outFile rPID
typeset -i i=0 j=0 concat=0 verify=0 m4b=0 m4bx=0 mp3=0 move=0 moveOnly=0 recurse=0 update=0 remove=0 result=0
umask=0022
startTime=$(date +%H:%M:%S" on "%b" "%d", "%Y)
echo "ccab log started @ $startTime" >> $ccLog
echo " DATE    TIME      MODULE    LINE #   STATUS  MESSAGE" >> $ccLog
echo "------ -------- ------------ ------- -------- ---------------------------------" >> $ccLog
options=$*

searchType=".*\(mp3\|m4a\|m4b\)$"

# Remove any previous run temp files.
rm *.cc > /dev/null 2>&1

trap 'abort' 1 2 3 15

C1="$(printf '\033[38;5;040m')"  # Green
C2="$(printf '\033[38;5;243m')"  # Grey
C3="$(printf '\033[38;5;254m')"  # White
C4="$(printf '\033[38;5;184m')"  # Yellow
C5="$(printf '\033[38;5;160m')"  # Red
C6="$(printf '\033[38;5;165m')"  # Purple
C7="$(printf '\033[38;5;063m')"  # Blue
C0="$(printf '\033[0;00m')"      # Reset


# Check for command line arguments.
if [ "$#" -lt 1 ]; then
  cat << EOM
  USAGE:   ccab.sh [-c ||--concat] [-m ||--move] [-mo] [-mp3] [-m4b] [-r] [-v]

    -c || --concat    : Will combine detected files into a single .mp3
    -m || --move      : After re-encoding, will move new files to specified
                        directory (baseDir). May add option value on the command
                        line to avoid prompting if book type is know before hand
                        (-m #).
    -mo               : Will move previously encoded files to target directory.
    -mp3              : Will limit search of input files to .mp3 files only.
    -m4b              : Will limit search of input files to .m4a or .m4b files
                        only.
    -r || --recurse   : Will search subdirectories for input files, make sure
                        subdirectories or zero padded if more that 9 subs (ex.
                        /disk 1 ==> /disk 01).
    -t || --tags      : Edit IDv3 tags before writing.
    -u || --update    : Only update book information (title, info, etc.) for an
                        already converted book (eg. change series info, title).
    -v || --verify    : Will prompt for verification of detected book information.
    -x || --remove    : Remove source files after conversion (DANGEROUS!).

EOM
  exit 1
fi

# Check for required packages.
command -v ffprobe >/dev/null 2>&1 || { echo "ERROR: Unable to detect ffprobe, bailing." >&2; exit 1; }
command -v ffmpeg >/dev/null 2>&1 || { echo "ERROR: Unable to detect ffmpeg, bailing." >&2; exit 1; }
command -v mid3v2 >/dev/null 2>&1 || { echo "ERROR: Unable to detect mid3v2, bailing." >&2; exit 1; }
command -v fancy_audio >/dev/null 2>&1 || { echo "ERROR: Unable to detect fancy_audio, bailing." >&2; exit 1; }
command -v googler >/dev/null 2>&1 || { echo "ERROR: Unable to detect googler, bailing." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: Unable to detect curl, bailing." >&2; exit 1; }
command -v lame >/dev/null 2>&1 || { echo "ERROR: Unable to detect lame, bailing." >&2; exit 1; }

# Get user options
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    -c | --concat)  # Concat all files found
      concat=1
      shift
      ;;
    -m | --move)  # Move output files to defined location
      move=1
      catagory=$2
      if [[ $catagory = '-'[a-z] || -z $catagory ]]; then
        unset catagory
        shift
      else
        shift 2
      fi
      ;;
    -mo) # Move only previously encoded files
      moveOnly=1
      searchType=".*\.abr..\.mp3$"
      shift
      ;;
    -mp3) # only search for mp3 files
      searchType=".*\(mp3\)$"
      shift
      ;;
    -m4b) # only search for m4a/m4b files
      searchType=".*\(m4a\|m4b\)$"
      shift
      ;;
    -r | --recurse)  # Look for files in subdirectories
      recurse=1
      shift
      ;;
    -t | --tags)    # Edit final tags
      tags=1
      shift
      ;;
    -u | --update)  # Update book information and rename if required
      update=1
      shift
      ;;
    -v | --verify)  # Verify automated tag values
      verify=1
      shift
      ;;
    -x | --remove)  # Remove original files after conversion
      remove=1
      shift
      ;;
    --trace)        # Set tracing in log file
      trace=1
      shift
      ;;
    *)  # Unknown option
      echo -e "${C5}ERROR: 10 - Unknown option '$1'${C0}"
      exit 10
      ;;
  esac
done


logIt ()
{

  module=$(printf '%-11s' $1)
  lineNo=$(printf '%.5d' $2)
  status=$(printf '%-6s' $3)
  msg=$4

  if [[ $status == "TRACE " && $trace -eq 1 ]]; then
    echo -e "$(date +%b" "%d" "%H:%M:%S) $module: [$lineNo] [$status] $msg" >> $ccLog
  elif [[ $status != "TRACE " ]]; then
    echo -e "$(date +%b" "%d" "%H:%M:%S) $module: [$lineNo] [$status] $msg" >> $ccLog
  fi
}

displayIt ()
{

  Text1=$1
  Text2=$2
  # Used to display '.' between fields
  pad=$(printf '%0.1s' "."{1..100})
  # Maximum length of the display line
  padlength=100

  if (( $# > 1 )); then
    printf "${C2}$Text1${C0} ${C7}$Text2${C0}"
    printf '%*.*s' 0 $((padlength - ${#Text1} - ${#Text2} - 7 )) "$pad"
  else
    printf "${C2}${Text1}${C0}"
    printf '%*.*s' 0 $((padlength - ${#Text1} - 6 )) "$pad"
  fi
  rotate &
  rPID=$!
  return 0
}

rotate ()
{

  # Interval between movements
  interval=.5

  trap 'abort' 1 2 3 15

  while : 
  do
    tput civis
    ((z++))
    case $z in
      "1") echo -e "-\b\c"
        sleep $interval
        ;;
      "2") echo -e '\\'"\b\c"
        sleep $interval
        ;;
      "3") echo -e "|\b\c"
        sleep $interval
        ;;
      "4") echo -e "/\b\c"
        sleep $interval
        ;;
      *) z=0 ;;
    esac
  done
}

killWait ()
{

  # Determine status message
  FLAG=$1
  MSG=$2

  kill -9 $rPID
  wait $rPID 2>/dev/null
  echo -e "\b\b\c"
  tput cnorm

  case $FLAG in
    "0") echo -e "[${C1}  OK  ${C0}]"
      if [[ $# > 1 ]]; then
        echo -e "  ${C1}$MSG${C0}"
      fi
      ;;
    "1") echo -e "[${C5}ERROR!${C0}]"
      if [[ $# > 1 ]]; then
        echo -e "  ${C5}$MSG${C0}"
      fi
      ;;
    "2") echo -e "[${C4} WARN ${C0}]"
      if [[ $# > 1 ]]; then
        echo -e "  ${C4}$MSG${C0}"
      fi
      ;;
    "3") echo -e "[${C3} WAIT ${C0}]"
      if [[ $# > 1 ]]; then
        echo -e "  ${C4}$MSG${C0}"
      fi
      ;;
    *) echo -e "[${C6}UNKWN!${C0}]"
      if [[ $# > 1 ]]; then
        echo -e "  ${C6}$MSG${C0}"
      fi
      ;;
  esac
  return 0
}

abort ()
{
  killWait 1 "User abort detected!"
  tput cnorm
  # rm cc.log error.log *.url *.info
  # rm cc.log
  exit 9
}

cleanUp ()
{
  STATUS=$1

  if (( STATUS == 0 )); then
    if (( concat == 1 && m4bFile == 1 )); then
      while read LINE; do
        logIt "cleanUp" $LINENO "TRACE" "rm \"$(awk -F\"['']\" '{print $1}' <<< $LINE)\""
        rm "$(awk -F"['']" '{print $1}' <<< $LINE)"
      done < cat.cc
    fi

    logIt "cleanUp" $LINENO "TRACE" "rm *.cc"
    rm -rf ccConcat.mp3 $ccError *.cc >/dev/null 2>&1
  fi

  echo -e "ccab finished @ $(date +%H:%M:%S" on "%b" "%d", "%Y)" >> $ccLog
  logIt "cleanUp" $LINENO "info" "exit status = $STATUS"

  echo -e "${C1}\nDone!${C0}"
  exit $STATUS
}

getFiles ()
{
  # Clear any previous list files
  rm list.cc >/dev/null 2>&1

  # Find all audio files in current or recursive directories.
  if (( moveOnly == 1 )); then
    find -maxdepth 1 -iregex ".*\.abr[0-9][0-9].mp3" -fprintf temp.cc '%h/%f\n'
  elif (( recurse == 1 )); then
    logIt "getFiles" $LINENO "TRACE" "find -iregex '.*.$searchType' -fprintf temp.cc '%h/%f\\\\n'"
    find -iregex "$searchType" -fprintf temp.cc '%h/%f\n'
  else
    logIt "getFiles" $LINENO "TRACE" "find -maxdepth 1 -iregex '.*.$searchType' -fprintf temp.cc '%h/%f\\\\n'"
    find -maxdepth 1 -iregex "$searchType" -fprintf temp.cc '%h/%f\n'
  fi

  # Remove already converted files from list
  if (( moveOnly == 0 && update == 0 )); then
    sed -r -i '/(\.abr[0-9]{2,3}\.mp3$)/d' temp.cc
  fi
  # Remove already concatenated file from list
  sed -i '/ccConcat.mp3/d' temp.cc

  # Restructure list for use with ffmpeg
  i=0
  while read FILE; do
    origFile[$i]=$FILE
    j=$((i+1))
    logIt "getFiles" $LINENO "info" "Source file $j = ${origFile[$i]}"
    if (( concat == 1 )); then
      echo "file '$FILE'" >> list.cc
    fi
    ((i++))
  done < temp.cc

  if (( concat == 1 )); then
    # Fix for apostropes in file name for ffmpeg
    sed -i "s/'s/'\\\''s/g" list.cc
  fi

  # Remove temp file
  rm temp.cc
  return 0
}

checkFile ()
{
  # Function to strip file name and determine type for further processing.
  in="$1"
  inExt=$(awk -F '.' '{print $NF}' <<< "$in")
  inExt=$(echo "$inExt" | tr '[:upper:]' '[:lower:]')
  baseName="$(sed 's/\....$//' <<< "$in")"
  out="${baseName}.mp3"
  displayIt "Checking file:" "$in"
  logIt "checkFile" $LINENO "info" "in = $in"
  logIt "checkFile" $LINENO "info" "out = $out"
  logIt "checkFile" $LINENO "info" "inExt = $inExt"
  logIt "checkFile" $LINENO "info" "baseName = $baseName"

  if (( concat == 1 )); then
    echo "file '$out'" >> cat.cc
  fi

  if [[  $inExt = "m4b" || $inExt = "m4a" ]]; then

    if [[ -s $out || -s ccConcat.mp3 ]]; then
      # File already converted.
      logIt "checkFile" $LINENO "  ok" "$in previously converted."
      
      if (( concat == 1 )); then
        # Check if next file the same as $out to avoid duplicates.
        i=$((j+1))
        if [[ ${origFile[$i]} = "$out" ]]; then
          logIt "checkFile" $LINENO "TRACE" "unset origFile[$i]"
          unset origFile[$i]
        fi
      fi

      killWait 2 "$in already processed, skipping."
      return 3
    else
      # Need to convert.
      logIt "checkFile" $LINENO "info" "Need to convert $in."
      killWait 0
      return 1
    fi
  else 
    if [[ $(find . -path "${baseName}.abr??.mp3" | wc -l) -gt 0 ]]; then
      # mp3 file already encoded.
      logIt "checkFile" $LINENO "WARN" "$in already encoded."
      killWait 2 "$in already converted."
      return 0
    else
      logIt "checkFile" $LINENO "info" "$in already in .mp3 format, skipping."
      killWait 0
      return 2
    fi
  fi
}

probeFile ()
{
  # Gather information on the book (title, series, info, etc.).

  # set -x
  in="$1"
  logIt "probeFile" $LINENO "info "  "Incoming file = $in"

  displayIt "Collecting tag information"

  # Get Book Title from IDv3 tags (if available)
  bookTitle=$(ffprobe "$in" 2>&1 | grep -e '^ \{4\}title' | sed 's/  //g' | sed 's/title : //')
    # Various filters to strip tags to base book title.
    bookTitle=$(sed -r 's/^Ch[0-9]{2}\s-\s//' <<< $bookTitle)
    bookTitle=$(sed -r 's/^Track\s[0-9]{1,2}//' <<< $bookTitle)
    bookTitle=$(sed -r 's/^[0-9]{2}.[0-9]{2}\s//' <<< $bookTitle)
    # bookTitle=$(echo $bookTitle | sed -r 's/ [0-9]{2}.*$//')
  logIt "probeFile" $LINENO "info "  "bookTitle = $bookTitle"

  # Get Book Authro
  bookAuthor=$(ffprobe "$in" 2>&1 | grep -e '^ \{4\}artist' | sed 's/  //g' | sed 's/artist: //')
  logIt "probeFile" $LINENO "info "  "bookAuthor = $bookAuthor"
  bookAuthorReverse=$(echo $bookAuthor | awk '{$1=$NF", "$1;NF--} 1' | sed 's/\.$//')
  logIt "probeFile" $LINENO "info "  "bookAuthorReverse = $bookAuthorReverse"

  # Get Book Series
  bookSeries=$(ffprobe "$in" 2>&1 | grep -e '^ \{4\}album\s*:' | sed 's/  //g' | sed 's/album : //')
  logIt "probeFile" $LINENO "info "  "bookSeries = $bookSeries"

  bookDuration=$(ffprobe "$in" 2>&1 |grep 'Duration' | awk -F',' '{print $1}' | awk '{print $2}')
  logIt "probeFile" $LINENO "info "  "bookDuration = $bookDuration"
  bookBitrate=$(ffprobe "$in" 2>&1 |grep 'Duration' | awk -F',' '{print $3}' | awk '{print $2}')
  logIt "probeFile" $LINENO "info "  "Original bookBitrate = $bookBitrate"
  if (( bookBitrate > targetBitrate )); then
    bookBitrate=$targetBitrate
  elif (( bookBitrate > 40 )); then
    bookBitrate=48
  else
    bookBitrate=32
  fi
  logIt "probeFile" $LINENO "info "  "Adjusted bookBitrate = $bookBitrate"
  bookSize=$(ffprobe -v error -select_streams a:0 -show_entries format=size -of default=noprint_wrappers=1 "$in" 2>>$ccError | awk -F '=' '{print $2}')
  bookSize="$(echo "scale=2;$bookSize/1048576" | bc) MB"
  logIt "probeFile" $LINENO "info "  "bookSize = $bookSize"
  audioStream=$(ffprobe "$in" 2>&1 | grep -E 'Stream.*Audio' | sed 's/^.*Stream //')
  logIt "probeFile" $LINENO "info "  "audioStream = $audioStream"
  bookSample=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of default=noprint_wrappers=1 "$in" 2>>$ccError | awk -F '=' '{print $2}')
  bookSample=$(echo "scale=2;$bookSample/1000" | bc)
  logIt "probeFile" $LINENO "info "  "bookSample = $bookSample"
  bookDate=$(ffprobe "$in" 2>&1 | grep '^\s\{4\}date\s*:' | awk -F': ' '{print $2}')
  logIt "probeFile" $LINENO "info "  "bookDate = $bookDate"

  if [[ -z $bookTitle || -z $bookAuthor ]]; then
    logIt "probeFile" $LINENO "WARN "  "No book information found."
    killWait 2 "No book information found for $in."
    return 1
  else
    killWait 0
    return 0
  fi
}

promptTags ()
{
  echo -e "${C3}Collect ID3 tags for $1${C0}"
  tempTitle=$bookTitle
  echo -e "${C3}  Please enter a title for this book: [${C4}${tempTitle}${C3}]${C0}\c"
  read bookTitle
  bookTitle=${bookTitle:-$tempTitle}
  logIt "promptTags" $LINENO "info "  "bookTitle = $bookTitle"

  tempAuthor=$bookAuthor
  echo -e "${C3}  Please enter an author for this book: [${C4}${tempAuthor}${C3}]${C0}\c"
  read bookAuthor
  bookAuthor=${bookAuthor:-$tempAuthor}
  logIt "promptTags" $LINENO "info "  "bookAuthor = $bookAuthor"

  #TODO add logic for no series
# tempSeries=$bookSeries
# echo -e "${C3}  Please enter the series for this book: [${C4}${tempSeries}${C3}]${C0}\c"
# read bookSeries
# bookSeries=${bookSeries:-$tempSeries}
  
  fullName="$bookAuthor - $bookSeries - $bookTitle"
  logIt "promptTags" $LINENO "info "  "fullName = $fullName"
  return 0
}

concatFiles ()
{
  displayIt "Concatenating discovered audio files"
  outCat="ccConcat.mp3"
  # Fix apostrophes in title for ffmpeg
  sed -i "s/'s/'\\\''s/g" cat.cc
  cat cat.cc | grep ' [1-9]\.' | sort -h > cat2.cc
  cat cat.cc | grep -v ' [1-9]\.' | sort -h >> cat2.cc
  mv cat2.cc cat.cc
  # if (( verify == 1 )); then
  #   vi cat.cc
  # fi
  if [[ ! -s $outCat ]]; then
    killWait 3 
    ffmpeg -loglevel fatal -y -safe 0 -f concat -i cat.cc -vn -sn -c copy "$outCat"
    logIt "concatFiles" $LINENO "TRACE"  "ffmpeg -loglevel fatal -y -safe 0 -f concat -i cat.cc -vn -sn -c copy \"$outCat\""
    STATUS=$?
  else
    killWait 0
    STATUS=0
  fi

  if (( STATUS > 0 )); then
    logIt "concatFiles" $LINENO "ERROR!" "$STATUS: Errors detected during encoding."
    echo -e "${C5}ERROR: $STATUS concatenating files."
    return $STATUS
  elif (( remove == 1 )); then
    logIt "concatFiles" $LINENO "OK  "  "Encode of concatenated file successful."
    while read LINE; do
      logIt "concatFiles" $LINENO "TRACE" "rm $(awk -F\' '{print $2}' <<< $LINE)"
      rm "$(awk -F\' '{print $2}' <<< $LINE)" 
    done < cat.cc
    rm cat.cc
  else
    logIt "concatFiles" $LINENO "OK  "  "Encode of concatenated file successful."
  fi
  bookDuration=$(ffprobe "$outCat" 2>&1 |grep 'Duration' | awk -F',' '{print $1}' | awk '{print $2}')
  logIt "concatFiles" $LINENO "info"  "Concatenated bookDuration = $bookDuration"
  return 0
}

tagIt ()
{
  in=$1
  displayIt "Applying ID3 tags to:" "$in"
  logIt "tagIt" $LINENO "info "  "in = $in"
  # Set tags to discovered tags
  author=$bookAuthor
  logIt "tagIt" $LINENO "info "  "author = $author"
  title=$bookTitle
  logIt "tagIt" $LINENO "info "  "title = $title"
  series=$bookSeries
  logIt "tagIt" $LINENO "info "  "series = $series"
  logIt "tagIt" $LINENO "info "  "bookCover = $bookCover"
  if [[ -z $author || -z $title ]]; then
    killWait 1 "No tag information to apply, bailing."
    return 1
  fi

  # Attempted to use several command line tag editors, mid3v2 does most of what I needed, but has some 
  # issues with cover art....

  mid3v2 --delete-all "$in" >/dev/null 2>>$ccLog

  # Add book cover image and tags or...
  if [[ -s "$bookCover" ]]; then
    # Failing back to fancy_audio for cover art :/.
    logIt "tagIt" $LINENO "TRACE"  "fancy_audio \"$in\" \"$bookCover\""
    fancy_audio "$in" "$bookCover" 1>>$ccError 2>&1

    logIt "tagIt" $LINENO "TRACE"  "mid3v2 -a \"$author\" -A \"$series\" -t \"$title\" -g \"audiobook\" -T 1 -c \"Comment\":\"$goodreadsURL\":\"eng\" -c \"Rating\":\"$bookRating\":\"eng\" -c \"Encoded by\":\"theGh0st\":\"eng\" \"$in\""
    mid3v2 -a "$author" -A "$series" -t "$title" -g "audiobook" -T 1 -c "Comment":"$goodreadsURL":"eng" -c "Rating":"$bookRating":"eng" -c "Encoded by":"theGh0st":"eng" "$in" >/dev/null 2>>$ccError
    STATUS=$?

    if (( STATUS > 0 )); then
      logIt "tagIt" $LINENO "ERROR!" "$STATUS: Failed to tag $in"
      killWait 1 "Error adding tags to $in."
      return $STATUS
    else
      logIt "tagIt" $LINENO "OK  "  "Tagging of $in successfull."
      killWait 0
      return 0
    fi
  else
    # ... Only add IDv3 tags without book cover.
    logIt "tagIt" $LINENO "TRACE"  "mid3v2 -a \"$author\" -A \"$series\" -t \"$title\" -g \"audiobook\" -T 1 -c \"Comment\":\"$goodreadsURL\":\"eng\" -c \"Rating\":\"$bookRating\":\"eng\" -c \"Encoded by\":\"theGh0st\":\"eng\" \"$in\""
    mid3v2 -a "$author" -A "$series" -t "$title" -g "audiobook" -T 1 -c "Comment":"$goodreadsURL":"eng" -c "Rating":"$bookRating":"eng" -c "Encoded by":"theGh0st":"eng" "$in" >/dev/null 2>>$ccError
    STATUS=$?
    if (( STATUS > 0 )); then
      logIt "tagIt" $LINENO "ERROR!" "$STATUS: Failed to tag $in"
      killWait 1 "Error adding tags to $in."
      return $STATUS
    else
      logIt "tagIt" $LINENO "OK  "  "Tagging of $in successfull."
      killWait 0
      return 0
    fi
  fi
}

convert ()
{
  in=$1
  out="$(sed 's/....$//' <<< $in).mp3"
  outFile[$j]=$out
  echo -e "${C3}Converting $in to .mp3${C0}"
  logIt "convert" $LINENO "info "  "in = $in"
  logIt "convert" $LINENO "info "  "out = $out"
  # echo -e "${C2}"
  if [[ ! -s $out ]]; then
    logIt "convert" $LINENO "TRACE" "ffmpeg ${ffOptions} -i \"$in\" -vn -sn -map_metadata -1 \"$out\""
    ffmpeg -loglevel error -i "${in}" -vn -sn -map_metadata -1 "${out}" 
    STATUS=$?
  else
    logIt "convert" $LINENO "WARN" "$out already exist."
    STATUS=0
  fi
  # echo -e "${C0}"
  if (( STATUS > 0 )); then
    logIt "convert" $LINENO "ERROR!" "$STATUS: Failed to convert $in."
    echo -e "${C5}File conversion failed for $in.${C0}"
    return 1
  else
    logIt "convert" $LINENO "OK" "File $in converted."
    echo "$(date +%Y.%m.%d' @ '%H:%M.%S) $in" >> $m4bLog

    # Set flag for m4b/m4a conversion success.
    m4bFile=1

    # Add converted file to concat list if option set.
    if (( concat == 1 )); then
      echo "file '$out'" >> cat.cc
      rm ccConcat.mp3 > /dev/null 2>&1
    fi
    return 0
  fi
}

displayInfo ()
{
  prompt=$1
  if [[ -z $bookAuthor || -z $bookTitle ]]; then
    logIt "displayInfo" $LINENO "ERROR!" "No information to display."
    echo -e "${C5}Nothing to display."
    return 1
  fi
  logIt "displayInfo" $LINENO "TRACE" "bookAuthor=$bookAuthor; bookTitle=$bookTitle"

  cat << EOT

    ${C4}Author:  ${C6}$bookAuthor${C0}
    ${C4}Reverse: ${C6}$bookAuthorReverse${C0}
    ${C4}Title:   ${C6}$bookTitle${C0}
    ${C4}Series:  ${C6}$bookSeries${C0}
    ${C4}Rating:  ${C6}$bookRating${C0}
    ${C4}Year:    ${C6}$bookYear${C0}
    ${C4}Stream:   ${C6}$audioStream${C0}
    ${C4}Bitrate:  ${C6}$bookBitrate${C0}
    ${C4}Sample:   ${C6}$bookSample${C0}
    ${C4}Duration: ${C6}$bookDuration${C0}
    ${C4}Size:     ${C6}$bookSize${C0}
    ${C4}URL:      ${C6}$goodreadsURL${C0}
EOT

  if [[ -s genre.cc ]]; then
    echo -e "  ${C4}Classifications:${C0}"
    while read LINE; do
      echo -e "    ${C6}$(sed -r 's/^[0-9]{2} / &/; s/^[0-9] /  &/' <<< $LINE )${C0}"
    done < genre.cc
  echo ""
  fi

  if [[ -n $prompt ]]; then
    unset prompt
    echo -e "${C3}Do you want to change values?${C0} [n]\b\b\c"
    read ANS
    tmpANS=n
    ANS=$(echo $ANS | tr '[:upper:]' '[:lower:]')
    ANS=${ANS:-tmpANS}

    if [[ $ANS = 'y' ]]; then
      return 1
    else
      return 0
    fi
  else
    return 0
  fi
}

getInfo ()
{
  # Collect book summary information
  displayIt "Collecting book information from goodreads.com"
  if [[ ! -s info.cc ]]; then
    logIt "getInfo" $LINENO "ERROR!" "No info.cc file to search, bailing."
    killWait 1 "No info.cc file to search."
    return 1
  fi

  logIt "getInfo" $LINENO "info" "Collecting book information."
  origIFS="$IFS"
  IFS=$'\n'
  grep -E 'people shelved this book' info.cc | sed 's/&#39;//g' |awk -F'"' '{print $2}' | head -5 > genre.cc
  IFS="$origIFS"

  rm -rf ${baseName}.info >/dev/null 2>&1
  echo "Author:    $bookAuthor" > "${baseName}.info" 2>>$ccError
  echo "Title:     $bookTitle" >> "${baseName}.info" 2>>$ccError
  echo "Series:    $bookSeries" >> "${baseName}.info" 2>>$ccError
  echo "Rating:    $bookRating" >> "${baseName}.info" 2>>$ccError
  echo "Duration:  $bookDuration" >> "${baseName}.info" 2>>$ccError
  echo "URL:       $goodreadsURL" >> "${baseName}.info" 2>>$ccError
  echo -e "\nClassifications:" >> "${baseName}.info" 2>>$ccError
  while read LINE; do
    echo "  $(sed -r 's/^[0-9]{3} / &/; s/^[0-9]{2} /  &/; s/^[0-9] /   &/' <<< $LINE)" >> "${baseName}.info"
  done < genre.cc
  echo -e "\nSummary:" >> "${baseName}.info" 2>>$ccError

  # Attempt to get the full book summary information.
  bookID=$(grep -m 1 -E '^.*freeTextContainer.*>' info.cc | awk -F'[""]' '{print $2}' | sed 's/Container//')
  if (( $(grep -c $bookID info.cc) == 0 )); then
    bookID=$(sed 's/freeText/freeTextContainer/' <<< $bookID)
  fi
  # grep $bookID info.cc | sed "s/<br>/\n/g; s/<[^>]*>//g; s/\xE2\x80\x99/\'/g; s/\xE2\x80\x94/\-/g" | fold -w 80 -s >> "${baseName}.info"
  logIt "getInfo" $LINENO "info" "bookID = $bookID"
  grep $bookID info.cc | sed "s/<br>/\n/g; s/<[^>]*>//g; s/\xE2\x80//g; s/\x99/'/g; s/\x94/\-/g" | fold -w 80 -s >> "${baseName}.info"
  logIt "getInfo" $LINENO "TRACE" "grep $bookID info.cc | sed \"s/<br>/\\\n/g; s/<[^>]*>//g; s/\xE2\x80//g; s/\x99/'/g; s/\x94/\-/g\" | fold -w 80 -s >> \"${baseName}.info\""
  sed -i 's/\xE2\x80\x9C/"/g; s/\xE2\x80\x9D/"/g; s/\xC3\x82//g; s/\xC5\x93/"/g; s/\xC2\x9D/"/g' "${baseName}.info"
  logIt "getInfo" $LINENO "TRACE" "sed -i 's/\xE2\x80\x9C/\"/g; s/\xE2\x80\x9D/\"/g; s/\xC3\x82//g' \"${baseName}.info\""
  
  # Replace extended characters with apostrophe
  # echo "X" | od -t x1c  # Display hex codes
  
  # Download book cover image
  if [[ ! -s "${bookCover}" ]]; then
    logIt "getInfo" $LINENO "TRACE" "curl -s -o \"$bookCover\" $imageSource" 
    curl -s -o "$bookCover" $imageSource 1>>$ccError 2>&1
    STATUS=$?

    if (( STATUS > 0 )); then
      logIt "getInfo" $LINENO "ERROR!" "Unable to download book cover image."
    else
      logIt "getInfo" $LINENO "OK" "Downloaded book cover image."
    fi
  else
    logIt "getInfo" $LINENO "info" "Using existing cover art ${bookCover}"
  fi

  # Create shortcut to goodreads url
  urlName="${baseName}.goodreads.url"
  logIt "getInfo" $LINENO "info" "URL = $goodreadsURL"
  echo "[{000214A0-0000-0000-C000-000000000046}]" > "${urlName}"
  echo "Prop3=19,2" >> "${urlName}"
  echo "[InternetShortcut]" >> "${urlName}"
  echo "IDList=" >> "${urlName}"
  echo "URL=$goodreadsURL" >> "${urlName}"
  killWait 0
  return 0
}

lookupMP3 ()
{
  in="$1"
  searchString="$bookTitle $bookAuthor"
    # Various filters for book titles before search, ideally only book title and author.
    searchString=$(sed 's/([Uu]nabridged)//' <<< "$searchString")
  displayIt "Looking up:" "$searchString"

  logIt "lookupMP3" $LINENO "TRACE" "googler -n 5 --np -C -w goodreads.com \"$searchString\""
  googler -n 5 --np -C -w goodreads.com "$searchString" > results.cc 2>>$ccError

  while [[ ! -s results.cc ]]; do
    killWait 1 "No results found using $searchString"
    echo -e "\n${C3}Enter new book title [${C4}$bookTitle${C0}]: ${C4}\c"
    read tmpBookTitle
    bookTitle=${tmpBookTitle:-$bookTitle}
    echo -e "${C3}Enter new book author [${C4}$bookAuthor${C0}]: ${C4}\c"
    read tmpBookAuthor
    bookAuthor=${tmpBookAuthor:-$bookAuthor}
    searchString="$bookTitle $bookAuthor"

    displayIt "Looking up:" "$searchString"
    echo -e "${C3}Searching for $searchString.${C0}"
    googler -n 5 -C --np -w goodreads.com "$searchString" > results.cc
    STATUS=$?
  done
  killWait 0

  goodreadsURL=$(grep -E '(http|https):.*book' results.cc | head -n 1)
  if [[ -z $goodreadsURL || $verify -eq 1 ]]; then
    echo -e "${C0}"
    cat results.cc
    echo -e "${C4}Pick the number of the link results to use for info ('6' for new search, '7' direct URL): \c${C0}"
    read result 
    while [[ $result -lt 1 || $result -gt 5 ]]; do
      if [[ $result -eq 6 ]]; then
        echo -e "${C3}Enter new search string: ${C0}\c"
        read searchString
        googler -n 5 --np -C -w goodreads.com "$searchString" > results.cc 2>/dev/null
        cat results.cc
        result=0
      elif [[ $result -eq 7 ]]; then
        echo -e "${C3}Enter book URL manually: ${C0}\c"
        read goodreadsURL
        break
      else
        echo -e "${C4}Pick the number of the link results to use for info ('6' for new search): \c${C0}"
        read result
      fi
    done
    if [[ $result -gt 0 && $result -lt 6 ]]; then
      goodreadsURL=$(grep -A 1 "^ $result" results.cc | tail -1)
    fi
  fi
  logIt "lookupMP3" $LINENO "info" "goodreadsURL = $goodreadsURL"

  if [[ -n $goodreadsURL ]]; then
    rm info.cc 2>/dev/null
    logIt "lookupMP3" $LINENO "TRACE" "curl -s $goodreadsURL -o info.cc"
    curl -s $goodreadsURL -o info.cc 1>>$ccError 2>&1
    STATUS=$?

    if (( STATUS > 0 )); then
      logIt "lookupMP3" $LINENO "ERROR!" "$STATUS: Unable to obtain goodreads.com URL"
      return $STATUS
    else
      logIt "lookupMP3" $LINENO "OK" "Obtained goodreads.com URL for book."
    fi

    logIt "lookupMP3" $LINENO "TRACE" "bookSeries = grep -A 1 -E 'class=\\\"greyText.*\/series\/' info.cc | tail -1 | sed 's/(Publication) //' | awk -F '[()]' '{print \$2}' | tr -d '#'"
    bookSeries=$(grep -A 1 -E 'class=\"greyText.*\/series\/' info.cc | tail -1 | sed 's/(Publication) //' | sed 's/(Part .)//; s/\&amp;/\&/g' | awk -F '[()]' '{print $2}' | tr '#' '0' | tr '/' '-' | tr ':' ',')
    if [[ -z $bookSeries ]]; then
      # try 2nd approach
      logIt "lookupMP3" $LINENO "TRACE" "bookSeries=$(grep -A 1 -E '<h1 id=\"bookTitle\" class=\"bookTitle\"' info.cc | tail -1 | awk -F'[()]' '{print $2}' | sed 's/\&amp;/\&/' | tr '/' '-' | tr ':' ',')"
      bookSeries=$(grep -A 1 -E '<h1 id="bookTitle" class="bookTitle"' info.cc | tail -1 | awk -F'[()]' '{print $2}' | sed 's/\&amp;/\&/' | tr '/' '-' | tr ':' ',')
    fi

    # A whole lot of manipulation to get padded series numbers and or .x versions
    bookSeriesNum=$(awk '{print $NF}' <<< $bookSeries | sed 's/^0//')
    majorNum=$(awk -F'.' '{printf "%.2d", "$1"}' <<< $bookSeriesNum)
    if [[ $majorNum = "00" ]]; then
      majorNum=$(printf "%.2d" "$bookSeriesNum" 2>/dev/null) 
    fi
    logIt "lookupMP3" $LINENO "info" "majorNum = $majorNum"
    minorNum=$(awk -F'.' '{print $2}' <<< $bookSeriesNum)
    if [[ -n $minorNum ]]; then
      bookSeriesNum="${majorNum}.${minorNum}"
      logIt "lookupMP3" $LINENO "info" "minorNum = $minorNum"
    else
      bookSeriesNum="${majorNum}"
    fi
    logIt "lookupMP3" $LINENO "info" "bookSeriesNum = $bookSeriesNum"
    bookSeries="$(awk 'NF{NF--};1' <<< $bookSeries) $bookSeriesNum"

    # Still testing this  
    bookYear=$(grep '^\s*(first published' info.cc | awk -F'[()]' '{print $2}' | sed -r 's/.*([0-9]{4})/\1/')
    if [[ -z $bookYear ]]; then
      bookYear=$(grep -A1 '^\s*Published' info.cc | tail -1 | sed -r 's/.*([0-9]{4})/\1/')
    fi
    logIt "lookupMP3" $LINENO "info" "bookYear = $bookYear"

    # Set year if not a series
    if [[ $bookSeries == ' 00' ]]; then
      # bookSeries="00"
      bookSeries=$bookYear
    fi
    logIt "lookupMP3" $LINENO "info" "bookSeries = $bookSeries"

    # Get book title from goodreads info.
    logIt "lookupMP3" $LINENO "TRACE" "bookTitle = grep -A 1 'id=\"bookTitle\" class=\"bookTitle\" itemprop=\"name\"' info.cc |tail -1 | sed 's/^[[:space:]]*//' | awk -F'[()]' '{print $1}' | sed 's/\&amp;/\&/g; s/ $//; s/\//-/g; s/\\/-/g' | tr ':' '-' | tr -d '?')"
    bookTitle=$(grep -A 1 'id="bookTitle" class="bookTitle" itemprop="name"' info.cc |tail -1 | sed 's/^[[:space:]]*//' | awk -F'[()]' '{print $1}' | sed 's/\&amp;/\&/g; s/ $//; s/\//-/g; s/\\/-/g' | tr ':' '-' | tr -d '?')
    logIt "lookupMP3" $LINENO "info" "bookTitle = $bookTitle"

    # Get book author from goodreads info.
    logIt "lookupMP3" $LINENO "TRACE" "bookAuthor = grep 'class=\"authorName\" itemprop=\"url\"' info.cc | awk -F'>' '{print $3}' | sed 's/<.*$//; s/  / /g' | head -1)"
    bookAuthor=$(grep 'class="authorName" itemprop="url"' info.cc | awk -F'>' '{print $3}' | sed 's/<.*$//; s/  / /g' | head -1)
    logIt "lookupMP3" $LINENO "info" "bookAuthor = $bookAuthor"
    bookAuthorReverse=$(awk '{$1=$NF", "$1;NF--} 1' <<< ${bookAuthor} | sed 's/\.$//')
    logIt "lookupMP3" $LINENO "info" "bookAuthorReverse = $bookAuthorReverse"

    # Get book rating from goodreads info.
    bookRating=$(grep 'ratingValue' info.cc | sed 's/.*<.*ratingValue">//; s/<\/.*>//')
    logIt "lookupMP3" $LINENO "info" "bookRating = $bookRating"

    # Get book cover from goodreads info.
    imageSource=$(grep -m 1 'Audible' info.cc |sed 's/\\n/\n/g' |grep 'img src' | awk -F'"' '{print $2}' | tr -d '\\')
    if [[ -z ${imageSource} ]]; then
      imageSource=$(grep -m 1 '\"coverImage\"' info.cc |sed 's/ /\n/g' |grep 'src' |awk -F'"' '{print $2}')
      logIt "lookupMP3" $LINENO "info" "Using default image source"
    else
      logIt "lookupMP3" $LINENO "info" "Using Audible image source"
    fi
    logIt "lookupMP3" $LINENO "info" "imageSource = $imageSource"

    # Set new baseName based on goodreads info.
    baseName="${bookAuthor} - ${bookSeries} - ${bookTitle}"
    logIt "lookupMP3" $LINENO "info" "baseName = $baseName"

    bookCover="${baseName}.cover.jpg"
    logIt "lookupMP3" $LINENO "info" "bookCover = $bookCover"
  fi
  return 0
}

reEncode ()
{
  in=$1
  logIt "reEncode" $LINENO "info" "in = $in"

  displayIt "Encoding:" "$in"
  # Reset name of output file (append bitrate info).
  baseName="${bookAuthor} - ${bookSeries} - ${bookTitle}"
  logIt "reEncode" $LINENO "info" "baseName = $baseName"

  # Multiple in files may be passed to reEncode, array maintains out file.
  outFile[$j]="${baseName}.abr${bookBitrate}.mp3"
  logIt "reEncode" $LINENO "info" "outFile[$j] = ${outFile[$j]}"

  # Re-encode input file with my parameters.
  killWait 3 "Re-encoding $in"
  echo -e "${C2}"
  if [[ ! -s ${outFile[$j]} ]]; then
    logIt "reEncode" $LINENO "TRACE" "lame --nohist -m m --abr $bookBitrate --resample $bookSample \"$in\" \"${outFile[$j]}\""
    lame --nohist -m m --abr $bookBitrate --resample $bookSample "$in" "${outFile[$j]}" 
    STATUS=$?
    echo -e "${C0}"
  else
    # File previously encoded.
    echo -e "  ${C4}${outFile[$j]} already encoded, skipping.${C0}"
    logIt "reEncode" $LINENO "WARN" "$in already encoded."
    STATUS=2
  fi

  displayIt "Checking encoding status"
  sleep 2
  if (( STATUS == 1 )); then
    logIt "reEncode" $LINENO "ERROR!" "$STATUS: Unknown error during lame encoding."
    killWait 1 "Error during lame encode!"
    return $STATUS
  else
    logIt "reEncode" $LINENO "OK" "lame encoding successful."
    killWait 0
    return 0
  fi
}

moveIt ()
{
  inFile="$1"
  logIt "moveIt" $LINENO "info" "inFile = $inFile"

  PS3_Orig=$PS3
  PS3="Select book type: "

  # Check if book catagory specified in arguments.
  if [[ -n $catagory ]]; then
    REPLY=$catagory

    case $REPLY in
      1) # Romance
        bookType="Romance"
        ;;
      2) # Erotica
        bookType="Hot"
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
        echo "\nUnknown catagory type [$catagory]"
        unset catagory
        ;;
    esac
  fi

  # Prompt for book catagory if not specified.
  while [[ -z $catagory ]]; do
    echo -e "\n${C4}Available book types${C0}\n"

    select option in Romance Erotica SciFi Fantasy Thriller Misc Quit
    do
      case $REPLY in
        1) # Romance
          bookType="Romance"
          Check=1
          break
          ;;
        2) # Erotica
          bookType="Hot"
          Check=1
          break
          ;;
        3) # SciFi
          bookType="SciFi"
          Check=1
          break
          ;;
        4) # Fantasy
          bookType="Fantasy"
          Check=1
          break
          ;;
        5) # Thriller
          bookType="Thriller"
          Check=1
          break
          ;;
        6) # Misc
          bookType="Misc"
          Check=1
          break
          ;;
        7) # Quit
          echo -e "\nBailing now!"
          Check=1
          exit 5
          ;;
        *) # Unknown
          echo -3 "\nUnknown option [${REPLY}]"
          Check=0
          break
          ;;
      esac
    done
    if [[ $Check -eq 1 ]]; then
      break
    fi
  done
  PS3=$PS3_Orig

  baseDir=$(sed 's/\/$//' <<< $baseDir)
  outDir="$baseDir/$bookType/$bookAuthorReverse/$bookSeries - $bookTitle/"
  logIt "moveIt" $LINENO "info" "outDir = $outDir"

  baseName="$bookAuthor - $bookSeries - $bookTitle"
  logIt "moveIt" $LINENO "info" "baseName = $baseName"

  if [[ -e "${outDir}/${baseName}\.abr[0-9][0-9]\.mp3" ]]; then
    logIt "moveIt" $LINENO "WARN" "$outDir/${baseName}.abr??.mp3 already exists, skipping move"
    killWait 1 "Output file already exist, skipping move."
    return 1
  fi

  displayIt "Moving to:" "$outDir"
  mkdir -p "$outDir" 1>>$ccError 2>&1

  if [[ ! -e "$inFile" ]]; then
    killWait 1 "No '${baseName}*' files found to move."
    logIt "moveIt" $LINENO "ERROR!" "Unable to find ${baseName}* files to move."
    return 1
  fi
  
  if [[ -s "$outDir/$inFile" ]]; then
    killWait 2 "Output file already exist, bailing"
    logIt "moveIt" $LINENO "ERROR!" "Output files already exist"
    return 1
  fi

  IFS=$'\n'
  for LINE in $(find . -name "${baseName}.*"); do
    logIt "moveIt" $LINENO "TRACE" "mv \"$LINE\" \"$outDir\""
    mv "$LINE" "$outDir" 1>>$ccError 2>&1
  done
  STATUS=$?

  if (( STATUS > 0 )); then
    logIt "moveIt" $LINENO "ERROR!" "$STATUS: Error attempting to move files."
    killWait 1 "Unable to move files to $outDir"
    return $STATUS
  else
    logIt "moveIt" $LINENO "OK" "Move encoded files to $outDir"
    rm genre.cc info.cc >/dev/null 2>&1
    killWait 0
    return 0
  fi
}


# -----------------------------------------------
# MAIN
# -----------------------------------------------
logIt "MAIN" $LINENO "info" "options = $options"

logIt "MAIN" $LINENO "FUNC" "calling getFiles: "
getFiles
j=0

# -----------------------------------------------
# Move only.
# -----------------------------------------------
if (( moveOnly == 1 )); then
  i=0
  while (( i < ${#origFile[*]} )); do
    logIt "MAIN" $LINENO "FUNC" "calling probeFile: "
    probeFile "${origFile[$i]}"
    cat "$bookAuthor - $bookSeries - $bookTitle.info"
    logIt "MAIN" $LINENO "FUNC" "calling moveIt:  ${origFile[$i]}"
    moveIt "${origFile[$i]}"
    # Update convertLog with move information.
    echo "$(date +%b" "%d", "%Y), [$bookType], ${origFile[$j]}" >> $convertLog
    ((i++))
  done
  logIt "MAIN" $LINENO "FUNC" "calling cleanUp:  0"
  cleanUp 0
fi

# -----------------------------------------------
# Update only.
# -----------------------------------------------
if (( update == 1 )); then
  logIt "MAIN" $LINENO "info" "inFile = ${origFile[0]}"
  inFile="${origFile[0]}"

  logIt "MAIN" $LINENO "FUNC" "calling probeFile:  \"$inFile\""
  probeFile "$inFile"

  if [[ -z $bookAuthor || -z $bookTitle ]]; then
    echo "No tags for $inFile, bailing."
    cleanUp 1
  fi

  logIt "MAIN" $LINENO "FUNC" "calling lookupMP3: "
  lookupMP3
  logIt "MAIN" $LINENO "FUNC" "calling getInfo: "
  getInfo

  ext=$(echo $inFile | awk -F'.' '{print $(NF-1)"."$NF}')
  logIt "MAIN" $LINENO "info" "ext = $ext"
  outFile="${bookAuthor} - ${bookSeries} - ${bookTitle}.${ext}"
  logIt "MAIN" $LINENO "info" "outFile = $outFile"

  # displayInfo
  echo -e "\n${C3}SOURCE: ${C4}${origFile[0]}${C0}"
  echo -e "${C3}TARGET: ${C6}${outFile}${C0}"
  echo -e "${C4}Sleeping...${C0}\n"
  # sleep 5

  if [[ "$inFile" != "./$outFile" ]]; then
    logIt "MAIN" $LINENO "TRACE" "mv \"$inFile\" \"$outFile\""
    mv "$inFile" "$outFile"
    logIt "MAIN" $LINENO "FUNC" "calling tagIt:  \"$outFile\""
    tagIt "$outFile"
  fi

  if (( move == 1 )); then
    logIt "MAIN" $LINENO "FUNC" "calling displayInfo: "
    displayInfo
    logIt "MAIN" $LINENO "FUNC" "calling moveIt:  \"$outFile\""
    moveIt "$outFile"
  fi

  logIt "MAIN" $LINENO "FUNC" "calling cleanUp:  0"
  cleanUp 0
fi


# -----------------------------------------------
# Concatenate files if option set.
# -----------------------------------------------
if (( concat == 1 )); then
  logIt "MAIN" $LINENO "FUNC" "calling probeFile:  \"${origFile[0]}\""
  probeFile "${origFile[0]}"
  STATUS=$?

  if (( STATUS > 0 )); then
    logIt "MAIN" $LINENO "FUNC" "calling displayInfo: "
    displayInfo
    logIt "MAIN" $LINENO "FUNC" "calling promptTags:  \"${origFile[0]}\""
    promptTags "${origFile[0]}"
  fi

  j=0
  while (( j < ${#origFile[*]} )); do
    logIt "MAIN" $LINENO "FUNC" "calling checkFile:  \"${origFile[$j]}\""
    checkFile "${origFile[$j]}"
    CHECK=$?
    logIt "MAIN" $LINENO "info" "checkFile:  status = $CHECK"

    if (( CHECK == 1 )); then
      logIt "MAIN" $LINENO "FUNC" "calling convert:  \"${origFile[$j]}\""
      convert "${origFile[$j]}"
    fi
    ((j++))
  done
  logIt "MAIN" $LINENO "FUNC" "calling concatFiles: "
  concatFiles
  STATUS=$?

  if (( STATUS > 0 )); then
    logIt "MAIN" $LINENO "ERROR!" "concatFiles:  returned status: $STATUS"
    exit 1
  fi

  j=0
  unset origFile[*]
  origFile[0]="ccConcat.mp3"
  logIt "MAIN" $LINENO "info" "origFile[0] = ${origFile[0]}"

  logIt "MAIN" $LINENO "FUNC" "calling lookupMP3: "
  lookupMP3 
  STATUS=$?

  while (( STATUS > 0 )); do
    logIt "MAIN" $LINENO "FUNC" "calling displayInfo: "
    displayInfo
    logIt "MAIN" $LINENO "FUNC" "calling promptTags:  \"${origFile[0]}\""
    promptTags "${origFile[0]}"
    logIt "MAIN" $LINENO "FUNC" "calling lookupMP3: "
    lookupMP3
    STATUS=$?
  done

  logIt "MAIN" $LINENO "FUNC" "calling getInfo: "
  getInfo

  echo -e "${C3}Found the following information:${C0}"
  logIt "MAIN" $LINENO "FUNC" "calling displayInfo: "
  displayInfo
  if (( tags == 1 )); then
    echo -e "${C3}Change book author = ${C4}$bookAuthor${C3}:${C0} \c"
    read newAuthor
    bookAuthor=${newAuthor:-$bookAuthor}
    echo -e "${C3}Change book title = ${C4}$bookTitle${C3}:${C0} \c"
    read newTitle
    bookTitle=${newTitle:-$bookTitle}
    echo -e "${C3}Change series name = ${C4}$bookSeries${C3}:${C0} \c"
    read newSeries
    bookSeries=${newSeries:-$bookSeries}

    # Update already created support files
    if [[ -e "$bookAuthor - 00 - $bookTitle.info" ]]; then
      mv "$bookAuthor - 00 - $bookTitle.info" "$bookAuthor - $bookSeries - $bookTitle.info" > /dev/null 2>&1
      mv "$bookAuthor - 00 - $bookTitle.goodreads.url" "$bookAuthor - $bookSeries - $bookTitle.goodreads.url" > /dev/null 2>&1
      mv "$bookAuthor - 00 - $bookTitle.cover.jpg" "$bookAuthor - $bookSeries - $bookTitle.cover.jpg" > /dev/null 2>&1
    fi
  fi
  
  logIt "MAIN" $LINENO "FUNC" "calling reEncode:  \"${origFile[0]}\""
  reEncode "${origFile[0]}"
  STATUS=$?

  if (( STATUS == 0 )); then
    logIt "MAIN" $LINENO "FUNC" "calling tagIt:  \"${origFile[0]}\""
    tagIt "${outFile[0]}"
  fi

  if (( remove == 1 )); then
    while read LINE; do
      logIt "MAIN" $LINENO "TRACE" "rm \"$LINE\""
      rm "$LINE"
    done < list.cc
  fi

  if (( move == 1 )); then
    logIt "MAIN" $LINENO "FUNC" "calling displayInfo: "
    displayInfo
    logIt "MAIN" $LINENO "FUNC" "calling moveIt:  \"${origFile[0]}\""
    moveIt "${outFile[0]}"
    echo "$(date +%Y.%m.%d), [$bookType], ${outFile[$j]}" >> $convertLog
  fi

  logIt "MAIN" $LINENO "FUNC" "calling cleanUp: "
  cleanUp 0
fi


# -----------------------------------------------
# Process various files one at a time.
# -----------------------------------------------
j=0
while (( j < ${#origFile[*]} )); do
  logIt "MAIN" $LINENO "FUNC" "calling probeFile:  \"${origFile[$j]}\""
  probeFile "${origFile[$j]}"
  STATUS=$?

  if (( STATUS > 0 )); then
    logIt "MAIN" $LINENO "FUNC" "calling displayInfo: "
    displayInfo
    logIt "MAIN" $LINENO "FUNC" "calling promptTags:  \"${origFile[$j]}\""
    promptTags "${origFile[$j]}"
  fi

  logIt "MAIN" $LINENO "FUNC" "calling checkFile:  \"${origFile[$j]}\""
  checkFile "${origFile[$j]}"
  STATUS=$?

  logIt "MAIN" $LINENO "info" "checkFile status = $STATUS"
  case $STATUS in
    1) # m4a/m4b file, need to convert
       recodeFlag=1
       m4bFlag=1
       ;;
    2) # mp3 file, need to reEncode
       recodeFlag=1
       m4bFlag=0
       ;;
    3) # m4a/m4b file, already convered
       recodeFlag=0
       m4bFlag=1
       ((j++))
       continue
       ;;
    0) # mp3 file, already converted
       recodeFlag=0
       m4bFlag=0
       ;;
    *) # Unknown status, bailing
       #TODO, fix this.
       echo -e "${C5}Unknown status, skipping.${C0}"
       ((j++))
       break
       ;;
  esac

  logIt "MAIN" $LINENO "FUNC" "calling lookupMP3: "
  lookupMP3
  STATUS=$?

  while (( STATUS > 0 )); do
    logIt "MAIN" $LINENO "FUNC" "calling displayInfo: "
    displayInfo
    logIt "MAIN" $LINENO "FUNC" "calling promptTags:  \"${origFile[$j]}\""
    promptTags "${origFile[$j]}"
    logIt "MAIN" $LINENO "FUNC" "calling lookupMP3: "
    lookupMP3
    STATUS=$?
  done

  logIt "MAIN" $LINENO "FUNC" "calling getInfo: "
  getInfo
  echo -e "${C3}Found the following information:${C0}"
  logIt "MAIN" $LINENO "FUNC" "calling displayInfo: "
  displayInfo

  if [[ $recodeFlag -eq 1 && $m4bFlag -eq 1 ]]; then
    logIt "MAIN" $LINENO "FUNC" "calling convert:  \"${origFile[$j]}\""
    convert "${origFile[$j]}"
    logIt "MAIN" $LINENO "FUNC" "calling tagIt:  \"${origFile[$j]}\""
    tagIt "${outFile[$j]}"
    logIt "MAIN" $LINENO "info" "origFile[$j] = ${origFile[$j]}"
    origFile[$j]="${outFile[$j]}"
    removeMP3=1
  fi

  if (( recodeFlag == 1 )); then
    logIt "MAIN" $LINENO "FUNC" "calling reEncode:  \"${origFile[$j]}\""
    reEncode "${origFile[$j]}"
    STATUS=$?

    if (( STATUS == 0 )); then
      logIt "MAIN" $LINENO "FUNC" "calling tagIt:  \"${origFile[$j]}\""
      tagIt "${outFile[$j]}"
    fi

    if (( move == 1 )); then
      logIt "MAIN" $LINENO "FUNC" "calling displayInfo: "
      displayInfo
      logIt "MAIN" $LINENO "FUNC" "calling moveIt:  \"${origFile[$j]}\""
      moveIt "${outFile[$j]}"
      # Update convertLog with book info
      echo "$(date +%Y.%m.%d), [$bookType], ${outFile[$j]}" >> $convertLog
    fi
  fi

  if (( removeMP3 == 1 )); then
    logIt "MAIN" $LINENO "TRACE" "rm \"${origFile[$j]}\""
    rm "${origFile[$j]}"
  fi
  removeMP3=0
  ((j++))
done

logIt "MAIN" $LINENO "FUNC" "calling cleanUp: "
cleanUp 0
