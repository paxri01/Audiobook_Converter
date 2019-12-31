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
logDir=/var/log/ccab                             # Working directory (logs and such)
baseDir=/audio/audiobooks                        # Base directory to move encoded files to.
convertLog="$logDir/converted.log"               # Successful encoding log file.
logFile="$logDir/ccab.log"                       # Normal log file
traceFile="$(date +%F)_trace.log"                # Debug log
workDir=/tmp/ccab.tmp

### END OF USER OPTIONS ###

mkdir -p "$logDir" >/dev/null 2>&1
mkdir -p "$workDir" >/dev/null 2>&1
#umask 0022

# Declare global variables
typeset bookAuthor bookGenre bookSeries bookTitle baseName bookType fileList fullName lookupResults lookupInfo outFile rPID
typeset -i i=0 j=0 concat=0 verify=0 move=0 moveOnly=0 recurse=0 update=0 remove=0 result=0 debug_level=0

options=$*
searchType=".*\(mp3\|m4a\|m4b\)$"

# Remove any previous run temp files.
## rm ./*.cc > /dev/null 2>&1

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

# -----------------------------------------------
# Check for required packages.
# -----------------------------------------------
command -v ffprobe >/dev/null 2>&1 || { echo "ERROR: Unable to detect ffprobe, bailing." >&2; exit 1; }
command -v ffmpeg >/dev/null 2>&1 || { echo "ERROR: Unable to detect ffmpeg, bailing." >&2; exit 1; }
command -v mid3v2 >/dev/null 2>&1 || { echo "ERROR: Unable to detect mid3v2, bailing." >&2; \
  echo "  > git clone https://github.com/quodlibet/mutagen.git /downloads/mid3v2"; exit 1; }
command -v fancy_audio >/dev/null 2>&1 || { echo "ERROR: Unable to detect fancy_audio, bailing." >&2; \
  echo "  > gem install fancy_audio"; exit 1; }
command -v googler >/dev/null 2>&1 || { echo "ERROR: Unable to detect googler, bailing." >&2; \
  echo "  > git clone https://github.com/jarun/googler.git /downloads/googler"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: Unable to detect curl, bailing." >&2; exit 1; }
command -v lame >/dev/null 2>&1 || { echo "ERROR: Unable to detect lame, bailing." >&2; exit 1; }

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
      concat=1
      shift
      ;;
    -d | --debug) # Set debug level
      if [[ -n $2 ]]; then
        debug_level=$2
        shift 2
      else
        debug_level=1
        shift
      fi
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
    -flac) # only search for mp3 files
      searchType=".*\(flac\)$"
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
    *)  # Unknown option
      echo -e "${C5}ERROR: 10 - Unknown option '$1'${C0}"
      exit 10
      ;;
  esac
done

# -----------------------------------------------
# Define script functions
# -----------------------------------------------
logIt ()
{
  msg=$1
  if (( debug_level > 0 )); then
    echo -e "${C8} INFO: $msg${C0}" | tee -a "$logFile"
  fi
}

debugIt()
{
  msg=$1
  if (( debug_level > 1 )); then
    echo -e "${C2}DEBUG: $msg${C0}" | tee -a "$traceFile"
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
    # shellcheck disable=2059
    printf "${C2}$Text1${C0} ${C7}$Text2${C0}"
    printf '%*.*s' 0 $((padlength - ${#Text1} - ${#Text2} - 7 )) "$pad"
  else
    # shellcheck disable=2059
    printf "${C2}${Text1}${C0}"
    printf '%*.*s' 0 $((padlength - ${#Text1} - 6 )) "$pad"
  fi
#  rotate &
#  rPID=$!
  return 0
}

rotate ()
{
  # Interval between movements
  interval=.5

  trap 'abort' 1 2 3 15

  #shellcheck disable=SC1003
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

  kill -9 "$rPID"
  wait "$rPID" 2>/dev/null
  echo -e "\b\b\c"
  tput cnorm

  case $FLAG in
    "0") echo -e "[${C1}  OK  ${C0}]"
      if [[ $# -gt 1 ]]; then
        echo -e "  ${C1}$MSG${C0}"
      fi
      ;;
    "1") echo -e "[${C5}ERROR!${C0}]"
      if [[ $# -gt 1 ]]; then
        echo -e "  ${C5}$MSG${C0}"
      fi
      ;;
    "2") echo -e "[${C4} WARN ${C0}]"
      if [[ $# -gt 1 ]]; then
        echo -e "  ${C4}$MSG${C0}"
      fi
      ;;
    "3") echo -e "[${C3} WAIT ${C0}]"
      if [[ $# -gt 1 ]]; then
        echo -e "  ${C4}$MSG${C0}"
      fi
      ;;
    *) echo -e "[${C6}UNKWN!${C0}]"
      if [[ $# -gt 1 ]]; then
        echo -e "  ${C6}$MSG${C0}"
      fi
      ;;
  esac
  return 0
}

abort()
{
  #killWait 1 "User abort detected!"
  tput cnorm
  # rm cc.log error.log *.url *.info
  # rm cc.log
  exit 9
}

cleanUp()
{
  STATUS=$1

  if (( STATUS == 0 )); then
    if (( concat == 1 && m4bFile == 1 )); then
      while read -r LINE; do
        echo -e " INFO: rm \"$(awk -F\"['']\" '{print $1}' <<< "$LINE")\""
        ## rm "$(awk -F"['']" '{print $1}' <<< "$LINE")"
      done < "$(grep '\.mp3' "$fileList")"
    fi

    echo -e " INFO: Cleaning temp files"
    #rm -f ccab_concat.mp3 ccab_concat.lst >/dev/null 2>&1
    rm -rf "$workDir" >/dev/null 2>&1
  fi

  echo -e "${C1}\nDone!${C0} STATUS: ${C3}$STATUS${C0}"
  exit "$STATUS"
}

getFiles()
{
  # Setup file lists
  tmpFileList=$workDir/ccab_files.tmp
  fileList=$workDir/ccab_files.list

  # Find all audio files in current or recursive directories.
  if (( moveOnly == 1 )); then
    debugIt "find -maxdepth 1 -iregex '.*\\.abr[0-9][0-9]\\.mp3' \
      -fprintf $fileList '%h/%f\\n'"
    find . -maxdepth 1 -iregex ".*\.abr[0-9][0-9].mp3" -fprintf "$fileList" '%h/%f\n'
  elif (( recurse == 1 )); then
    debugIt "find -iregex '.*.$searchType' \
      -fprintf $fileList '%h/%f\\n'"
    find . -iregex "$searchType" -fprintf "$fileList" '%h/%f\n'
  else
    debugIt "find -maxdepth 1 -iregex '.*.$searchType' \
      -fprintf $fileList '%h/%f\\n'"
    find . -maxdepth 1 -iregex "$searchType" -fprintf "$fileList" '%h/%f\n'
  fi

  if (( concat == 1 )); then
    # Remove already concatenated file from list
    logIt "[getFiles.$LINENO] Sorting ${C3}$fileList${C0}"
    sed -i '/ccab_concat.mp3/d' "$fileList"
    grep ' [1-9]\.' < "$fileList" | sort -h > "$tmpFileList"
    grep -v ' [1-9]\.' "$fileList" | sort -h >> "$tmpFileList"
    mv -f "$tmpFileList" "$fileList"
    if (( verify == 1 )); then
      vim "$fileList"
    fi
  fi
  
  # Restructure list for use with ffmpeg (build list as "file '<FILENAME>'")
  i=0
  while read -r FILE; do
    origFile[$i]=$FILE
    j=$((i+1))
    logIt "[getFiles.$LINENO] Concat file [$j]: ${C3}${origFile[$i]}${C0}"
    if (( concat == 1 )); then
      echo "file '$FILE'" >> ./ccab_concat.lst
    fi
    ((i++))
  done < "$fileList"

  if (( concat == 1 )); then
    # Fix for apostropes in file name for ffmpeg
    debugIt "sed -i \"s/'s/'\\\'s/g\" ./ccab_concat.lst"
    sed -i "s/'s/'\\\''s/g" ./ccab_concat.lst
    sed -i "s/'v/'\\\''v/g" ./ccab_concat.lst
    #rm -f "$fileList"
  fi

  return 0
}

probeFile()
{
  # Gather information on the book (title, series, info, etc.).

  # set -x
  in="$1"

  logIt "[probeFile.$LINENO] Collecting ID tag information for: ${C3}$in${C0}"

  ffprobe -hide_banner "$in" >"./probe.tmp" 2>&1

  title=$(grep -m 1 'title' ./probe.tmp | awk -F':' '{ print $2 }' | cut -c 2-)
  artist=$(grep 'artist' ./probe.tmp | awk -F':' '{ print $2 }' | cut -c 2-)
  album=$(grep 'album' ./probe.tmp | awk -F':' '{ print $2 }' | cut -c 2-)
  albumArtist=$(grep 'album_artist' ./probe.tmp | awk -F':' '{ print $2 }' | cut -c 2-)
  date=$(grep 'date' ./probe.tmp | awk -F':' '{ print $2 }' | cut -c 2-)

  ## Set bookTitle to album if set, otherwise title.
  bookTitle="${album:-$title}"
#    # Various filters to strip tags to base bookTitle.
#    bookTitle=$(sed -r 's/^Ch[0-9]{2}\s-\s//' <<< "$bookTitle")
#    bookTitle=$(sed -r 's/^Track\s[0-9]{1,2}//' <<< "$bookTitle")
#    bookTitle=$(sed -r 's/^[0-9]{2}.[0-9]{2}\s//' <<< "$bookTitle")
#    bookTitle=$(sed -r 's/ [0-9]{2}.*$//' <<< "$bookTitle")
  if [[ -z $bookTitle ]]; then
    echo -e "${C3}Enter the title of the book${C0} [$bookTitle]: \c"
    read -r tempTitle
    bookTitle=${tempTitle:-$bookTitle}
  fi
  logIt "[probeFile.$LINENO] bookTitle = ${C3}$bookTitle${C0}"

  ## Set bookAuthor to album_artist if set, otherwise artist.
  bookAuthor="${albumArtist:-$artist}"
  ## Fix accented names
  bookAuthor=${bookAuthor/É/E}
  if [[ -z $bookAuthor ]]; then
    echo -e "${C3}Enter the author of the book${C0} [$bookAuthor]: \c"
    read -r tempAuthor
    bookTitle=${tempAuthor:-$bookAuthor}
  fi
  logIt "[probeFile.$LINENO] bookTitle = ${C3}$bookTitle${C0}"

  logIt "[probeFile.$LINENO] bookAuthor = ${C3}$bookAuthor${C0}"
  
  ## Reverse author name and strip any ending '.'
  bookAuthorReverse=$(awk '{$1=$NF", "$1;NF--} 1' <<< "$bookAuthor" | sed 's/\.$//')
  logIt "[probeFile.$LINENO] bookAuthorReverse = ${C3}$bookAuthorReverse${C0}"

  ## Set book duration
  bookDuration=$(grep -m 1 'Duration' ./probe.tmp | sed -rn 's/.*([0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{2}).*/\1/p')
  logIt "[probeFile.$LINENO] bookDuration = ${C3}$bookDuration${C0}"

  origBitrate=$(grep 'Audio:' ./probe.tmp | awk -F',' '{ print $5 }' | awk '{ print $1 }')
  if (( origBitrate > targetBitrate )); then
    bookBitrate=$targetBitrate
  elif (( bookBitrate > 40 )); then
    bookBitrate=48
  else
    bookBitrate=32
  fi
  logIt "[probeFile.$LINENO] Original bookBitrate = ${C3}$origBitrate${C0}"
  logIt "[probeFile.$LINENO] Adjusted bookBitrate = ${C3}$bookBitrate${C0}"

  bookDate="$date"
  logIt "[probeFile.$LINENO] bookDate = ${C3}$bookDate${C0}"

  if [[ -z $bookTitle || -z $bookAuthor ]]; then
    echo -e "${C5}ERROR:${C0} No book information found."
    rm ./probe.tmp
    return 1
  else
    logIt "[probeFile.$LINENO] Found book information."
    rm ./probe.tmp
    return 0
  fi
}

checkFile()
{
  # Function to strip file name and determine type for further processing.
  in="$1"
  inExt=$(awk -F '.' '{print $NF}' <<< "$in")
  inExt=$(echo "$inExt" | tr '[:upper:]' '[:lower:]')
  baseName="$(sed 's/\....$//' <<< "$in")"
  out="${baseName}.mp3"

  logIt "[checkFile.$LINENO] Checking file: ${C3}$in${C0}"
  debugIt "\$in = $in"
  debugIt "\$out = $out"
  debugIt "\$inExt = $inExt"
  debugIt "\$baseName = $baseName"

  if [[  $inExt = "m4b" || $inExt = "m4a" ]]; then

    if [[ -s $out || -s ccab_concat.mp3 ]]; then
      # File already converted.
      echo -e "${C4}WARNING: ${C3}$in${C0} previously converted."
      
      #return 3
      return 1

    else
      # Need to convert.
      logIt "[checkFile.$LINENO] ${C3}$in${C0} needs to be converted."
      return 1
    fi

  else 

    if [[ $(find . -path "${baseName}.abr??.mp3" | wc -l) -gt 0 ]]; then
      # m4a/m4b file already encoded.
      logIt "[checkFile.$LINENO] ${C3}$in${C0} already encoded."
      #return 0
      return 2
    else
      # m4a/m4b file already converted to mp3 format 
      return 2
    fi

  fi
}

promptTags()
{
  echo -e "${C3}Collect ID3 tags for $1${C0}"
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

concatFiles()
{
  # Function to concatenate separate files into single file
  echo -e "${C3}Concatenating discovered audio files${C0}"

  if [[ ! -s ./ccab_concat.mp3 ]]; then
    # Due to ffmpeg issues, must have concat list in same dir as concat files.
    # ffmpeg -loglevel fatal -y -safe 0 -f concat -i ./ccab_concat.lst -vn -sn -c copy ccab_concat.mp3
    debugIt "ffmpeg -loglevel fatal -y -safe 0 -f concat -i ./ccab_concat.lst -vn -sn ccab_concat.mp3"
    ffmpeg -loglevel quiet -y -stats -safe 0 -f concat -i ./ccab_concat.lst -vn -sn ccab_concat.mp3
    STATUS=$?
  else
    STATUS=0
  fi

  if (( STATUS > 0 )); then
    echo -e "${C5}ERROR: ${C3}$STATUS${C0} concatenating files."
    return $STATUS
  elif (( remove == 1 )); then
    echo -e "${C1}   OK:${C0} Concatenated files encoded successfully."
    while read -r LINE; do
      debugIt "rm \"$(awk -F\' '{print $2}' <<< "$LINE")\""
      rm "$(awk -F\' '{print $2}' <<< "$LINE")" 
    done < ./ccab_concat.lst
  else
    echo -e "${C1}   OK:${C0} Concatenated files encoded successfully."
  fi

  debugIt "bookDuration=\$(ffprobe ./ccab_concat.mp3 2>&1 |grep 'Duration' | awk -F',' '{print \$1}' | awk '{print \$2}')"
  bookDuration=$(ffprobe ./ccab_concat.mp3 2>&1 |grep 'Duration' | awk -F',' '{print $1}' | awk '{print $2}')
  echo -e " INFO: Concatenated bookDuration = ${C3}$bookDuration${C0}"

  debugIt "rm -f ./ccab_concat.lst"
  ## rm -f ./ccab_concat.lst
  
  return 0
}

tagIt()
{
  in=$1
  echo -e "Applying ID3 tags to: $in"

  # Set tags to discovered tags
  author=$bookAuthor
  logIt "[tagIt.$LINENO] author = ${C3}$author${C0}"
  title=$bookTitle
  logIt "[tagIt.$LINENO] title = ${C3}$title${C0}"
  series=$bookSeries
  logIt "[tagIt.$LINENO] series = ${C3}$series${C0}"

  if [[ -z $author || -z $title ]]; then
    echo -e "${C5}ERROR:${C0} No tag information to apply, bailing."
    return 1
  fi

  # Attempted to use several command line tag editors, mid3v2 does most of what I needed, but has some 
  # issues with cover art....

  debugIt "mid3v2 --delete-all \"$in\""
  mid3v2 --delete-all "$in" >/dev/null 2>&1

  # Add book cover image and tags or...
  if [[ -s "$bookCover" ]]; then
    # Failing back to fancy_audio for cover art :/.
    debugIt "fancy_audio \"$in\" \"$bookCover\""
    fancy_audio "$in" "$bookCover"

    debugIt "mid3v2 -a \"$author\" -A \"$series\" -t \"$title\" -g \"audiobook\" -T 1 -c \"Comment\":\"$goodreadsURL\":\"eng\" \
      -c \"Rating\":\"$bookRating\":\"eng\" -c \"Encoded by\":\"theGh0st\":\"eng\" \"$in\""
    #  shellcheck disable=2140
    mid3v2 -a "$author" -A "$series" -t "$title" -g "audiobook" -T 1 -c "Comment":"$goodreadsURL":"eng" -c "Rating":"$bookRating":"eng" -c "Encoded by":"theGh0st":"eng" "$in" >/dev/null
    STATUS=$?

    if (( STATUS > 0 )); then
      echo -e "${C5}ERROR${C0}:$STATUS Failed to tag ${C3}$in${C0}"
      return $STATUS
    else
      echo -e "${C1}   OK:${C0} Tagging of ${C3}$in${C0} successfull."
      return 0
    fi

  else

    # ... Only add IDv3 tags without book cover.
    debugIt "mid3v2 -a \"$author\" -A \"$series\" -t \"$title\" -g \"audiobook\" -T 1 -c \"Comment\":\"$goodreadsURL\":\"eng\" \
      -c \"Rating\":\"$bookRating\":\"eng\" -c \"Encoded by\":\"theGh0st\":\"eng\" \"$in\""

    #  shellcheck disable=2140
    mid3v2 -a "$author" -A "$series" -t "$title" -g "audiobook" -T 1 -c "Comment":"$goodreadsURL":"eng" -c "Rating":"$bookRating":"eng" -c "Encoded by":"theGh0st":"eng" "$in" >/dev/null
    STATUS=$?

    if (( STATUS > 0 )); then
      echo -e "${C5}ERROR:${C0}$STATUS Failed to tag ${C3}$in${C0}"
      return $STATUS
    else
      echo -e "${C1}   OK:${C0} Tagging of ${C3}$in${C0} successful."
      return 0
    fi
  fi
}

convert()
{
  in=$1
  out="$(sed 's/....$//' <<< "$in").mp3"
  outFile[$j]=$out
  logIt "[convert.$LINENO] Converting ${C3}$(basename "$in")${C0} to mp3."

  if [[ ! -s $out ]]; then
    debugIt "ffmpeg -loglevel error -i \"${in}\" -vn -sn -map_metadata -1 \"${out}\""
    echo "      ${C3}book duration: $bookDuration (may not be accurate)${C0}"
    ffmpeg -hide_banner -loglevel error -stats -i "${in}" -vn -sn -map_metadata -1 "${out}" 
    STATUS=$?
  else
    echo -e "${C4}WARNING: ${C3}$out${C0} already exist."
    STATUS=0
  fi

  # echo -e "${C0}"
  if (( STATUS > 0 )); then
    echo -e "${C5}ERROR:${C0}$STATUS: Failed to convert ${C3}$in${C0}."
    return 1
  else
    echo -e "${C1}   OK:${C0} File ${C3}$in${C0} converted."

    # Set flag for m4b/m4a conversion success.
    m4bFile=1

    # Add converted file to concat list if option set.
    if (( concat == 1 )); then
      echo "file '$out'" >> "$fileList"
      ## rm ccab_concat.mp3 > /dev/null 2>&1
    fi
    return 0
  fi
}

displayInfo()
{
  #prompt=$1
  if [[ -z $bookAuthor || -z $bookTitle ]]; then
    logIt "displayInfo" $LINENO "ERROR!" "No information to display."
    echo -e "${C5}Nothing to display.${C0}"
    return 1
  fi
  debugIt "[displayInfo.$LINENO] bookAuthor=${C3}$bookAuthor${C0}; bookTitle=${C3}$bookTitle${C0}"

  cat << EOT

    Author:   ${C3}$bookAuthor${C0}
    Reverse:  ${C3}$bookAuthorReverse${C0}
    Title:    ${C3}$bookTitle${C0}
    Series:   ${C3}$bookSeries${C0}
    Rating:   ${C3}$bookRating${C0}
    Year:     ${C3}$bookYear${C0}
    Bitrate:  ${C3}$bookBitrate${C0}
    Duration: ${C3}$bookDuration${C0}
    URL:      ${C3}$goodreadsURL${C0}
EOT

  if [[ -s $bookGenre ]]; then
    echo -e "\n  Classifications:"
    while read -r LINE; do
      echo -e "    ${C3}$(sed -r 's/^[0-9]{2} / &/; s/^[0-9] /  &/' <<< "$LINE" )${C0}"
    done < "$bookGenre"
  echo ""
  fi

}

getInfo()
{
  bookGenre="$workDir/goodreads.genre"
  bookInfo="${baseName}.info"
  logIt "[getInfo.$LINENO] Collecting book information from goodreads.com"
  if [[ ! -s $lookupInfo ]]; then
    echo -e "${C5}ERROR:${C0} No ${C3}$lookupInfo${C0} file to search, bailing."
    return 1
  fi

  origIFS="$IFS"
  IFS=$'\n'
  grep -E 'people shelved this book' "$lookupInfo" | sed 's/&#39;//g' |awk -F'"' '{print $2}' | head -5 > "$bookGenre"
  IFS="$origIFS"

  cat <<EO_Info > "$bookInfo"
Author:    $bookAuthor
Title:     $bookTitle
Series:    $bookSeries
Rating:    $bookRating
Duration:  $bookDuration
URL:       $goodreadsURL

Classifications:
EO_Info

  while read -r LINE; do
    echo "  $(sed -r 's/^[0-9]{3} / &/; s/^[0-9]{2} /  &/; s/^[0-9] /   &/' <<< "$LINE")" >> "$bookInfo"
  done < "$bookGenre"
  echo -e "\nSummary:" >> "$bookInfo"

  # Attempt to get the full book summary information.
  debugIt "bookID=\$(grep -m 1 -E '^.*freeTextContainer.*>' \"$lookupInfo\" | awk -F'[\"\"]' '{print \$2}' | sed 's/Container//')"
  bookID=$(grep -m 1 -E '^.*freeTextContainer.*>' "$lookupInfo" | awk -F'[""]' '{print $2}' | sed 's/Container//')
  if (( $(grep -c "$bookID" "$lookupInfo") == 0 )); then
    bookID=$(sed 's/freeText/freeTextContainer/' <<< "$bookID")
  fi

  grep "$bookID" "$lookupInfo" | sed "s/<br>/\n/g; s/<[^>]*>//g; s/\xE2\x80//g; s/\x99/'/g; s/\x94/\-/g" | fold -w 80 -s >> "$bookInfo"
  sed -i 's/\xE2\x80\x9C/"/g; s/\xE2\x80\x9D/"/g; s/\xC3\x82//g; s/\xC5\x93/"/g; s/\xC2\x9D/"/g' "$bookInfo"
  
  # Replace extended characters with apostrophe
  # echo "X" | od -t x1c  # Display hex codes
  
  # Download book cover image
  if [[ ! -s "${bookCover}" ]]; then
    debugIt "curl -s -o \"$bookCover\" \"$imageSource\""
    curl -s -o "$bookCover" "$imageSource" 
    STATUS=$?

    if (( STATUS > 0 )); then
      echo -e "${C5}ERROR:${C0} Unable to download book cover image."
    else
      echo -e "${C1}   OK:${C0} Downloaded book cover image."
    fi
  else
    echo -e "${C4} INFO:${C0} Using existing cover art ${C3}${bookCover}${C0}"
  fi

  # Create shortcut to goodreads url
  urlName="${baseName}.goodreads.url"
  logIt "[getInfo.$LINENO] URL file = ${C3}$urlName${C0}"

  cat <<EO_URL >"$urlName"
[{000214A0-0000-0000-C000-000000000046}]
Prop3=19,2
[InternetShortcut]
IDList=
URL=$goodreadsURL
EO_URL

  return 0
}

lookupMP3()
{
  # Function to lookup book on goodreads.com

  #set -e

  inFile="$1"
  lookupResults="$workDir/goodreads.results"
  lookupInfo="$workDir/goodreads.normalized"
  htmlInfo="$workDir/goodreads.html"

  searchString="$bookTitle $bookAuthor"
    # Various filters for book titles before search, ideally only book title and author.
    searchString=$(sed 's/([Uu]nabridged)//' <<< "$searchString")
  debugIt "googler -n 5 --np -C -w www.goodreads.com $searchString > $lookupResults"
  googler -n 5 --np -w www.goodreads.com "$searchString" > "$lookupResults"
  #googler -n 5 --np -C -w goodreads.com "$searchString" > "$lookupResults"
  
  while [[ ! -s "$lookupResults" ]]; do
    echo -e "${C4} WARN:${C0} No results found using $searchString\n"
    echo -e "${C3} Enter direct URL: \c"
    read -r goodreadsURL
    echo "$goodreadsURL" > "$lookupResults"
#    echo -e "  ${C3}Enter new book title [${C4}$bookTitle${C0}]: ${C4}\c"
#    read tmpBookTitle
#    bookTitle=${tmpBookTitle:-$bookTitle}
#    echo -e "  ${C3}Enter new book author [${C4}$bookAuthor${C0}]: ${C4}\c"
#    read tmpBookAuthor
#    bookAuthor=${tmpBookAuthor:-$bookAuthor}
#    searchString="$bookTitle $bookAuthor"
#
#    echo -e "Looking up: ${C3}$searchString${C0}"
#    googler -n 5 --np -w https://www.goodreads.com "$searchString" > "$lookupResults"
#    #googler -n 5 -C --np -w goodreads.com "$searchString" > "$lookupResults"
#    STATUS=$?
  done

  ## # Grab first result from results (Need to fix color issue)
  ## goodreadsURL=$(grep -E '(http|https):.*book' "$lookupResults" | head -n 1)

  if [[ -z $goodreadsURL || $verify -eq 1 ]]; then
    echo -e "  ${C7}Current directory: ${C3}$PWD${C0}"
    echo -e "  ${C7}Current file: ${C3}$(basename "$inFile")${C0}\n"
    sed 's/ - Goodreads//' "$lookupResults"
    echo -e "${C6}Pick the number of the link results to use for info ('6' for new search, '7' direct URL):${C0} \c"
    read -r result 

    ## BAD RESULT
    while [[ $result -lt 1 || $result -gt 5 ]]; do
      if [[ $result -eq 6 ]]; then
        echo -e "${C4}Enter new search string: ${C0}\c"
        read -r searchString
        googler -n 5 --np -w https://www.goodreads.com "$searchString" > "$lookupResults" 2>/dev/null
        cat "$lookupResults"
        result=0
      elif [[ $result -eq 7 ]]; then
        echo -e "${C4}Enter book URL manually: ${C0}\c"
        read -r goodreadsURL
        break
      else
        echo -e "${C6}Pick the number of the link results to use for info ('6' for new search, '7' direct URL):${C0} \c"
        read -r result
      fi
    done

    ## OKAY RESULT
    if [[ $result -gt 0 && $result -lt 6 ]]; then
      debugIt "goodreadURL=\$(grep -m 1 -A 1 \"^ $result\" \"$lookupResults\" | awk '{ print \$1 }')"
      # Strip ASCII color codes from output (could use -C on googler, but like colors)
      sed -i -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K]//g" "$lookupResults"
      goodreadsURL=$(grep -A 1 "^ ${result}." "$lookupResults" | tail -1 | awk '{ print $1 }')
    fi

  fi

  logIt "[lookupMP3.$LINENO] goodreadsURL = ${C3}$goodreadsURL${C0}"

  if [[ -n $goodreadsURL ]]; then
    debugIt "curl -sL $goodreadsURL -o \"$htmlInfo\""
    #shellcheck disable=SC2086
    curl -sL $goodreadsURL -o "$htmlInfo"
    hxnormalize -l 9999 -x "$htmlInfo" > "$lookupInfo"

    if [[ ! -s "$lookupInfo" ]]; then
      echo -e "${C5}ERROR:${C0}$STATUS [$LINENO] Unable to obtain page data from URL"
      return 1
    else
      echo -e "${C1}   OK:${C0} Obtained goodreads.com URL for book"
    fi

    debugIt "fullTitle=\$(grep \"property='og:title'\" \"$lookupInfo\")"
    title1=$(hxselect -ic title < "$lookupInfo" | awk -F' by ' '{ print $1 }')
    title2=$(grep 'property=.og:title.' "$lookupInfo" |awk -F"['']" '{ print $2 }')
    fullTitle=${title1:-$title2}

    ## Normalize title
    fullTitle=$(sed 's/\&amp;/\&/' <<< "$fullTitle" | tr '#' '0' | tr -d ',' | tr ':' ',' | tr '/' '-')

    logIt "[lookupMP3.$LINENO] fullTitle = ${C3}$fullTitle${C0}"
   
    debugIt "author=\$(hxselect -ic title <\"$lookupInfo\" | awk -F' by ' '{ print $2 }')"
    author=$(hxselect -ic title < "$lookupInfo" | awk -F' by ' '{ print $2 }')
    bookAuthor=${author:-$bookAuthor}
    
    # Fix accented names
    bookAuthor=${bookAuthor/É/E}
    logIt "[lookupMP3.$LINENO] bookAuthor = ${C3}$bookAuthor${C0}"
    
    debugIt "bookAuthorReverse=\$(awk '{$1=$NF\", \"$1;NF--} 1' <<< \"$bookAuthor\" | sed 's/\.$//')"
    bookAuthorReverse=$(awk '{$1=$NF", "$1;NF--} 1' <<< "$bookAuthor" | sed 's/\.$//')
    logIt "[lookupMP3.$LINENO] bookAuthorReverse = ${C3}$bookAuthorReverse${C0}"
   
    debugIt "bookSeries=\$(hxselect -ic h2 < \"$lookupInfo\" | awk -F'[()]' '{ print $2 }')"
    bookSeries=$(hxselect -ic h2 <"$lookupInfo" | awk -F'[()]' '{ print $2 }')
    ## Normalize series
    bookSeries=$(sed 's/\&amp;/\&/' <<< "$bookSeries" | tr '#' '0' | tr -d ',' | tr ':' ',' | tr '/' '-')
    logIt "[lookupMP3.$LINENO] bookSeries = ${C3}$bookSeries${C0}"
    
    debugIt "bookTitle=\$(awk -F'(' '{print $1}' <<< \"$fullTitle\" | sed 's/ $//')"
    bookTitle=$(awk -F'(' '{print $1}' <<< "$fullTitle" | sed 's/ $//')
    logIt "[lookupMP3.$LINENO] bookTitle = ${C3}$bookTitle${C0}"

    # A whole lot of manipulation to get padded series numbers and or .x versions
    debugIt "bookSeriesNum=\$(awk '{print $NF}' <<< \"$bookSeries\" | sed 's/^0//' | tr -d ')')"
    bookSeriesNum=$(awk '{print $NF}' <<< "$bookSeries" | sed 's/^0//' | tr '/' '-' | tr -d ')')

    majorNum=$(awk -F'.' '{printf "%.2d", "$1"}' <<< "$bookSeriesNum")
    if [[ $majorNum = "00" ]]; then
      majorNum=$(printf "%.2d" "$bookSeriesNum" 2>/dev/null) 
    fi
    logIt "[lookupMP3.$LINENO] majorNum = ${C3}$majorNum${C0}"

    minorNum=$(awk -F'.' '{print $2}' <<< "$bookSeriesNum")
    logIt "[lookupMP3.$LINENO] minorNum = ${C3}$minorNum${C0}"

    if [[ -n $minorNum ]]; then
      bookSeriesNum="${majorNum}.${minorNum}"
    else
      bookSeriesNum="${majorNum}"
    fi
    logIt "[lookupMP3.$LINENO] bookSeriesNum = ${C3}$bookSeriesNum${C0}"

    debugIt "bookSeries=\"\$(awk 'NF{NF--};1' <<< \"$bookSeries\") $bookSeriesNum\""
    bookSeries="$(awk 'NF{NF--};1' <<< "$bookSeries") $bookSeriesNum"
    logIt "[lookupMP3.$LINENO] bookSeries = ${C3}$bookSeries${C0}"

    # Still testing this  
    debugIt "bookYear=\$(grep -m 1 'Published' \"$lookupInfo\" | sed -rn 's/.*([0-9]{4}).*/\1/p')"
    bookYear=$(grep -m 1 'Published' "$lookupInfo" | sed -rn 's/.*([0-9]{4}).*/\1/p')
    logIt "[lookupMP3.$LINENO] bookYear = ${C3}$bookYear${C0}"

    # Set year if not a series
    if [[ $bookSeries == ' 00' ]]; then
      # bookSeries="00"
      bookSeries=$bookYear
      logIt "[lookupMP3.$LINENO] bookSeries = ${C3}$bookSeries${C0}"
    fi

    # Get book rating from goodreads info.
    debugIt "bookRating=\$(grep 'ratingValue' \"$lookupInfo\" | sed -rn 's/.*([0-9]\.[0-9]{2}).*/\1/p')"
    #bookRating=$(grep 'ratingValue' "$lookupInfo" | sed 's/.*<.*ratingValue">//; s/<\/.*>//')
    bookRating=$(grep 'ratingValue' "$lookupInfo" | sed -rn 's/.*([0-9]\.[0-9]{2}).*/\1/p')
    logIt "[lookupMP3.$LINENO] bookRating = ${C3}$bookRating${C0}"

    # Get book cover from goodreads info.
    debugIt "imageSource=\$(grep 'og:image' \"$lookupInfo\" | awk -F'[\"\"]' '{ print $2 }')"
    image1=$(grep 'og:image' "$lookupInfo" | awk -F'[""]' '{ print $2 }')
    image2=$(grep -i -m 1 'coverimage' "$lookupInfo" | awk -F'src=' '{ print $2 }' | awk -F'[""]' '{ print $2 }')
    imageSource=${image1:-$image2}
    logIt "[lookupMP3.$LINENO] imageSource = ${C3}$imageSource${C0}"

    # Set new baseName based on goodreads info.
    baseName="${bookAuthor} - ${bookSeries} - ${bookTitle}"
    logIt "[lookupMP3.$LINENO] baseName = ${C3}$baseName${C0}"

    bookCover="${baseName}.cover.jpg"
    logIt "[lookupMP3.$LINENO] bookCover = ${C3}$(basename "$bookCover")${C0}"
    
  fi

  return 0
}

reEncode()
{
  in=$1

  logIt "[reEncode.$LINENO] Encoding: ${C3}$in${C0}"
  # Reset name of output file (append bitrate info).
  baseName="${bookAuthor} - ${bookSeries} - ${bookTitle}"
  logIt "[reEncode.$LINENO] baseName = ${C3}$baseName${C0}"

  # Multiple in files may be passed to reEncode, array maintains out file.
  outFile[$j]="${baseName}.abr${bookBitrate}.mp3"
  logIt "[reEncode.$LINENO] outFile[$j] = ${C3}${outFile[$j]}${C0}"

  # Check converted.log for already converted.
  if grep -q "${outFile[$j]}" "$convertLog"; then
    echo -e "${C4}WARNING: ${C3}${outFile[$j]}${C0} has already been converted."
    #return 1
  fi

  # Re-encode input file with my parameters.
  if [[ ! -s ${outFile[$j]} ]]; then
    #debugIt "lame --nohist -m m --abr $bookBitrate --resample \"$bookSample\" \"$in\" \"${outFile[$j]}\""
    debugIt "lame --nohist -m m --abr $bookBitrate \"$in\" \"${outFile[$j]}\""
    echo -e "${C2}"
    lame --nohist -m m -V 6 "$in" "${outFile[$j]}" 
    STATUS=$?
    echo -e "${C0}"
  else
    # File previously encoded.
    echo -e "${C4}WARNING: ${C3}$in${C0} already encoded."
    STATUS=2
  fi

  logIt "[reEncore.$LINENO] Checking encoding status"
  if (( STATUS == 1 )); then
    echo -e "${C5}ERROR:${C3}$STATUS${C0} Unknown error during lame encoding."
    return $STATUS
  else
    echo -e "${C1}   OK:${C0} lame encoding successful."
    echo "${outFile[$j]}" >> done.txt
    return 0
  fi
}

moveIt ()
{
  # set -x
  inFile="$1"
  logIt "[moveIt.$LINENO] inFile = ${C3}$inFile${C0}"

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
        echo -e "\nUnknown catagory type [$catagory]"
        unset catagory
        ;;
    esac
  fi

  # Prompt for book catagory if not specified.
  while [[ -z $catagory ]]; do
    echo -e "\n${C4}Available book types${C0}\n"

    # shellcheck disable=2034
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
  PS3=$PS3_Orig

  baseDir=$(sed 's/\/$//' <<< $baseDir)
  outDir="$baseDir/$bookType/$bookAuthorReverse/$bookSeries - $bookTitle"
  logIt "[moveIt.$LINENO] outDir = ${C3}$outDir${C0}"

  baseName="$bookAuthor - $bookSeries - $bookTitle"
  logIt "[moveIt.$LINENO] baseName = ${C3}$baseName${C0}"

  if [[ -e "${outDir}/${baseName}\.abr[0-9][0-9]\.mp3" ]]; then
    echo -e "${C4}WARNING ${C3}$outDir/${baseName}.abr??.mp3${C0} already exists, skipping move"
    return 1
  fi

  logIt "[moveIt.$LINENO] Moving to: ${C3}$outDir${C0}"
  mkdir -p "$outDir"
  chown -R admin:qnap "$baseDir/$bookType/$bookAuthorReverse"

  if [[ ! -e "$inFile" ]]; then
    echo -e "${C5}ERROR:${C0} Unable to find ${C3}${baseName}*${C0} files to move."
    return 1
  fi
  
  if [[ -s "$outDir/$inFile" ]]; then
    echo -e "${C5}ERROR:${C0} Output files already exist"
    return 1
  fi

  IFS=$'\n'
  # shellcheck disable=2044
  for LINE in $(find . -name "${baseName}.*"); do
    debugIt "mv \"$LINE\" \"$outDir/\""
    mv "$LINE" "$outDir/"
  done

#   while IFS= read -r -d '' LINE; do
#     logIt "moveIt" $LINENO "TRACE" "mv \"$LINE\" \"$outDir\""
#     mv "$LINE" "$outDir" 
#   done < "$(find . -name "${baseName}*")"
  STATUS=$?

  if (( STATUS > 0 )); then
    echo -e "${C5}ERROR:${C3}$STATUS${C0} Error attempting to move files."
    return $STATUS
  else
    chown -R admin:qnap "$outDir"
    chmod 775 "$outDir"
    chmod 664 "$outDir"/*
    echo -e "${C1}   OK:${C0} Move encoded files to ${C3}$outDir${C0}"
    return 0
  fi
}

# -----------------------------------------------
# MAIN
# -----------------------------------------------
echo -e " MAIN: $0 options = ${C3}$options${C0}"
echo -e " MAIN: calling ${C6}getFiles()${C0}"
getFiles
j=0

# -----------------------------------------------
# Move only.
# -----------------------------------------------
if (( moveOnly == 1 )); then
  i=0
  while (( i < ${#origFile[*]} )); do
    echo -e " MAIN: calling ${C6}probeFile()${C0}"
    probeFile "${origFile[$i]}"
    # cat "$bookAuthor - $bookSeries - $bookTitle.info"
    echo -e " MAIN: calling ${C6}moveIt() ${C0}${origFile[$i]}"
    moveIt "${origFile[$i]}"
    # Update convertLog with move information.
    echo "$(date +%b\ %d,\ %Y), [$bookType], ${origFile[$j]}" >> $convertLog
    ((i++))
  done
  echo -e " MAIN: calling ${C6}cleanUp()${C0} 0"
  cleanUp 0
fi
# -----------------------------------------------
# Update only.
# -----------------------------------------------
if (( update == 1 )); then
  echo -e " MAIN: inFile = ${C6}${origFile[0]}${C0}"
  inFile="${origFile[0]}"

  echo -e " MAIN: calling ${C6}probeFile() ${C3}$inFile${C0}"
  probeFile "$inFile"

  echo -e " MAIN: calling ${C6}lookupMP3() ${C3}$inFile${C0}"
  lookupMP3 "$inFile"
  echo -e " MAIN: calling ${C6}getInfo()${C0}"
  getInfo

  ext=$(echo "$inFile" | awk -F'.' '{print $(NF-1)"."$NF}')
  echo -e " MAIN: ext = ${C3}\$ext${C0}"
  outFile[$j]="${bookAuthor} - ${bookSeries} - ${bookTitle}.${ext}"
  echo -e " MAIN: outFile = ${C3}\${outFile[$j]}${C0}"

  # displayInfo
  echo -e "\n${C3}SOURCE: ${C4}${origFile[0]}${C0}"
  echo -e "${C3}TARGET: ${C6}${outFile[$j]}${C0}"

  if [[ "$inFile" != "./${outFile[$j]}" ]]; then
    debugIt "mv \"$inFile\" \"${outFile[$j]}\""
    mv "$inFile" "${outFile[$j]}"
    echo -e " MAIN: calling tagIt:  \"${outFile[$j]}\""
    tagIt "${outFile[$j]}"
  fi

  if (( move == 1 )); then
    echo -e " MAIN: calling ${C6}moveIt() ${C3}\${outFile[$j]}${C0}"
    moveIt "${outFile[$j]}"
  fi

  echo -e " MAIN: calling ${C6}cleanUp() ${C3}0${C0}"
  cleanUp 0
fi

# -----------------------------------------------
# Concatenate files if option set.
# -----------------------------------------------
if (( concat == 1 )); then
  echo -e " MAIN: calling ${C6}probeFile() ${C3}${origFile[0]}${C0}"
  probeFile "${origFile[0]}"
  STATUS=$?

  if (( STATUS > 0 )); then
    echo -e " MAIN: calling ${C6}displayInfo()${C0}"
    displayInfo
    echo -e " MAIN: calling ${C6}promptTags() ${C3}${origFile[0]}${C0}"
    promptTags "${origFile[0]}"
  fi

  j=0
  while (( j < ${#origFile[*]} )); do
    echo -e " MAIN: calling ${C6}checkFile() ${C3}${origFile[$j]}${C0}"
    checkFile "${origFile[$j]}"
    CHECK=$?
    echo -e " MAIN: checkFile: status = ${C3}$CHECK${C0}"

    if (( CHECK == 1 )); then
      echo -e " MAIN: calling ${C6}convert() ${C3}${origFile[$j]}${C0}"
      convert "${origFile[$j]}"
    fi
    ((j++))
  done

  echo -e " MAIN: calling ${C6}concatFiles()${C0}"
  concatFiles
  STATUS=$?

  if (( STATUS > 0 )); then
    echo -e " MAIN: ${C5}ERROR:${C3}$STATUS${C0} ${C6}concatFiles()${C0} returned error"
    exit 1
  fi

  j=0
  unset "origFile[*]"
  origFile[0]="ccab_concat.mp3"
  echo -e " MAIN: origFile[0] = ${C3}${origFile[0]}${C0}"

  echo -e " MAIN: calling ${C6}lookupMP3() ${C3}${origFile[0]}${C0}"
  lookupMP3 "${origFile[0]}"
  STATUS=$?

  while (( STATUS > 0 )); do
    echo -e " MAIN: calling ${C6}promptTags() ${C3}${origFile[0]}${C0}"
    promptTags "${origFile[0]}"
    echo -e " MAIN: calling ${C6}lookupMP3() ${C3}${origFile[0]}${C0}"
    lookupMP3 "${origFile[0]}"
    STATUS=$?
  done

  echo -e " MAIN: calling ${C6}getInfo()${C0}"
  getInfo

  echo -e "${C3}Found the following information:${C0}"
  echo -e " MAIN: calling ${C6}displayInfo()${C0}"
  displayInfo

  if (( tags == 1 )); then
    echo -e "${C3}Change book author = ${C4}$bookAuthor${C3}:${C0} \c"
    read -r newAuthor
    bookAuthor=${newAuthor:-$bookAuthor}
    echo -e "${C3}Change book title = ${C4}$bookTitle${C3}:${C0} \c"
    read -r newTitle
    bookTitle=${newTitle:-$bookTitle}
    echo -e "${C3}Change series name = ${C4}$bookSeries${C3}:${C0} \c"
    read -r newSeries
    bookSeries=${newSeries:-$bookSeries}

    # Update already created support files
    if [[ -e "$bookAuthor - 00 - $bookTitle.info" ]]; then
      mv "$bookAuthor - 00 - $bookTitle.info" "$bookAuthor - $bookSeries - $bookTitle.info" > /dev/null 2>&1
      mv "$bookAuthor - 00 - $bookTitle.goodreads.url" "$bookAuthor - $bookSeries - $bookTitle.goodreads.url" > /dev/null 2>&1
      mv "$bookAuthor - 00 - $bookTitle.cover.jpg" "$bookAuthor - $bookSeries - $bookTitle.cover.jpg" > /dev/null 2>&1
    fi
  fi

  echo -e " MAIN: calling ${C6}reEncode() ${C3}${origFile[0]}${C0}"
  reEncode "${origFile[0]}"
  STATUS=$?

  if (( STATUS == 0 )); then
    echo -e " MAIN: calling ${C6}tagIt() ${C3}${origFile[0]}${C0}"
    tagIt "${outFile[0]}"
  fi

  # TODO Fix 'list.cc' file
  if (( remove == 1 )); then
    while read -r LINE; do
      debugIt "rm \"$LINE\""
      rm "$LINE"
    done < list.cc
  fi

  if (( move == 1 )); then
    echo -e " MAIN: calling ${C6}displayInfo()${C0}"
    displayInfo
    echo -e " MAIN: calling ${C6}moveIt() ${C3}${origFile[0]}${C0}"
    moveIt "${outFile[0]}"
    echo "$(date +%Y.%m.%d), [$bookType], ${outFile[$j]}" >> $convertLog
  fi

  echo -e " MAIN: calling ${C6}cleanUp() ${C3}0${C0}"
  cleanUp 0
fi

# -----------------------------------------------
# Process various files one at a time.
# -----------------------------------------------
j=0
while (( j < ${#origFile[*]} )); do
  echo -e " MAIN: calling ${C6}probeFile() ${C3}\${origFile[$j]}${C0}"
  probeFile "${origFile[$j]}"
  STATUS=$?

  if (( STATUS > 0 )); then
    echo -e " MAIN: calling ${C6}promptTags() ${C3}\${origFile[$j]}${C0}"
    promptTags "${origFile[$j]}"
  fi

  echo -e " MAIN: calling ${C6}checkFile() ${C3}\${origFile[$j]}${C0}"
  checkFile "${origFile[$j]}"
  STATUS=$?

  echo -e " MAIN: checkFile status = ${C3}$STATUS${C0}"
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

  echo -e " MAIN: calling ${C6}lookupMP3() ${C3}\${origFile[$j]}${C0}"
  lookupMP3 "${origFile[$j]}"
  STATUS=$?

  while (( STATUS > 0 )); do
    echo -e " MAIN: calling ${C6}promptTags() ${C3}\${origFile[$j]}${C0}"
    promptTags "${origFile[$j]}"
    echo -e " MAIN: calling ${C6}lookupMP3() ${C3}\${origFile[$j]}${C0}"
    lookupMP3 "${origFile[$j]}"
    STATUS=$?
  done

  echo -e " MAIN: calling ${C6}getInfo()${C0}"
  getInfo

  echo -e " MAIN: calling ${C6}displayInfo()${C0}"
  displayInfo

  if [[ $recodeFlag -eq 1 && $m4bFlag -eq 1 ]]; then
    echo -e " MAIN: calling ${C6}convert() ${C3}\${origFile[$j]}${C0}"
    convert "${origFile[$j]}"
    echo -e " MAIN: calling ${C6}tagIt() ${C3}\${origFile[$j]}${C0}"
    tagIt "${outFile[$j]}"
    origFile[$j]=${outFile[$j]}
    removeMP3=1
  fi

  if (( recodeFlag == 1 )); then
    echo -e " MAIN: calling ${C6}reEncode() ${C3}\${origFile[$j]}${C0}"
    reEncode "${origFile[$j]}"
    STATUS=$?

    if (( STATUS == 0 )); then
      echo -e " MAIN: calling ${C6}tagIt() ${C3}\${origFile[$j]}${C0}"
      tagIt "${outFile[$j]}"
    fi

    if (( move == 1 )); then
      echo -e " MAIN: calling ${C6}moveIt() ${C3}\${origFile[$j]}${C0}"
      moveIt "${outFile[$j]}"
      # Update convertLog with book info
      echo "$(date +%Y.%m.%d), [$bookType], ${outFile[$j]}" >> $convertLog
    fi
  fi

  if (( removeMP3 == 1 )); then
    debugIt "rm \"${origFile[$j]}\""
    rm "${origFile[$j]}"
  fi
  removeMP3=0
  ((j++))
done

echo -e " MAIN: calling ${C6}cleanUp() ${C3}0${C0}"
cleanUp 0

