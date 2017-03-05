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
#  USAGE:   ccab.sh [-c ||--concat] [-m ||--move] [-mo] [-mp3] [-m4b] [-r] [-v]
#
#  -c || --concat	: Will combine detected files into a single .mp3
#  -m || --move	: After re-encoding, will move new files to specified
#                     directory (baseDir). May add option value on the command
#                     line to avoid prompting if book type is know before hand
#                     (-m #).
#  -mo			: Will move previously encoded files to target directory.
#  -mp3			: Will limit search of input files to .mp3 files only.
#  -m4b			: Will limit search of input files to .m4a or .m4b files
#                     only.
#  -r               : Will search subdirectories for input files, make sure
#                     subdirectories or zero padded if more that 9 subs (ex.
#                     /disk 1 ==> /disk 01).
#  -v               : Will prompt for verification of detected book information.
#
#                   NOTE: Other options are not fully implemented.
#
#########################################################################################
#
#  TRACING: The details of the file processing is logged to $ccLog output for
#           debugging or tracing processing. $debugLog has limited value as 
#           only odd errors typically get logged to it, but may be worth
#           checking if problems occur.
#
#  CONVERTED: If $convertLog specified, successful encodes will be logged to
#             this file, to track what files have been processed.
#
#########################################################################################

### START OF USER OPTIONS ###

targetBitrate=48							# Set this to desired bitrate for output files.
ffOptions="-loglevel fatal -hide_banner -y"		# Don't change this unless you know ffmpeg.
ccLog=./cc.log								# Output tracing file.
m4bLog=/mnt/vuze/m4b-convert.log				# Only used for m4b logging.
debugLog=./error.log						# Major error log, should remain empty and removed.
convertLog=/mnt/vuze/converted.log				# Successful encoding log file.
baseDir=/mnt/audiobooks						# Base directory to move encoded files to.

### END OF USER OPTIONS ###

typeset bookAuthor bookSeries bookTitle baseName bookType fullName outFile LOOP
typeset -i concat=0 verify=0 m4b=0 m4bx=0 mp3=0 move=0 moveOnly=0 recurse=0 update=0 remove=0 result=0
umask=0022
startTime=$(date +%H:%M:%S" on "%Y.%m.%d)
echo "ccab log started @ $startTime" > $ccLog
options=$*

searchType=".*\(mp3\|m4a\|m4b\)$"

# Remove any previous run temp files.
rm *.cc error.log > /dev/null 2>&1

trap 'CleanUp' 1 2 3 15

# Define custom colors
Grey='\033[38;5;244m'
Red='\033[38;5;160m'
Blue='\033[38;5;69m'
Green='\033[38;5;82m'
Yellow='\033[38;5;226m'
Cyan='\033[38;5;014m'
Pink='\033[38;5;163m'
C0='\033[0;00m'

# Check for command line arguments.
if [ "$#" -lt 1 ]; then
	cat << EOM
	USAGE:   ccab.sh [-c ||--concat] [-m ||--move] [-mo] [-mp3] [-m4b] [-r] [-v]

	  -c || --concat	: Will combine detected files into a single .mp3
	  -m || --move		: After re-encoding, will move new files to specified
	                      directory (baseDir). May add option value on the command
	                      line to avoid prompting if book type is know before hand
	                      (-m #).
	  -mo			: Will move previously encoded files to target directory.
	  -mp3			: Will limit search of input files to .mp3 files only.
	  -m4b			: Will limit search of input files to .m4a or .m4b files
	                      only.
	  -r || --recurse   : Will search subdirectories for input files, make sure
	                      subdirectories or zero padded if more that 9 subs (ex.
	                      /disk 1 ==> /disk 01).
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
		-c | --concat)	# Concat all files found
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
		*)	# Unknown option
			echo -e "${Red}ERROR: 10 - Unknown option '$1'${C0}"
			exit 10
			;;
	esac
done


logIt ()
{
	echo -e "$(date +%H:%M:%S) - $1" >> $ccLog
}

WAIT ()
{
	tput civis
	echo -e "[ $(tput sc)       ]\c"
	tput rc
}


killWait ()
{
	# set -e
	# sleep .2
	key2="$1"
	case $key2 in
	0) # OK
#		kill -s 16 $WPID
		echo -e $(tput rc; tput sgr0; tput setaf 2)"\b   OK   "
		tput sgr0; tput cnorm
		return 0 ;;
	1) # ERROR
#		kill -s 17 $WPID
		echo -e $(tput rc; tput sgr0; tput setaf 1)"\b ERROR! \a"
		tput sgr0; tput cnorm
		echo -e "${Pink}  $2  ${C0}"
		return 1 ;;
	2) # WARNING
#		kill -s 17 $WPID
		echo -e $(tput rc; tput sgr0; tput setaf 3)"\b  WARN  "
		tput sgr0; tput cnorm
		echo -e "${Pink}  $2${C0}"
		return 2 ;;
	3) # DONE
#		kill -s 16 $WPID 2>/dev/null
		echo -e $(tput rc; tput sgr0; tput setaf 2)"\b  DONE  "
		tput sgr0; tput cnorm
		return 0 ;;
	4) # NONE
#		kill -s 16 $WPID 2>/dev/null
		echo -e $(tput rc; tput sgr0; tput setaf 2)"\b  NONE  "
		tput sgr0; tput cnorm
		return 0 ;;
	5) # WARNING
		echo -e $(tput rc; tput sgr0; tput setaf 3)"\b  WAIT  "
		tput sgr0; tput cnorm
		return 0 ;;
	*) # Unknown
#		kill -s 17 $WPID
		echo -e $(tput rc; tput sgr0; tput setaf 1)"\b  FAIL  "
		tput sgr0; tput cnorm
		return 1 ;;
	esac
}

CleanUp ()
{
	killWait 1 "User abort detected!"
	tput cnorm
	# rm cc.log error.log *.url *.info
	rm cc.log
	exit 5
}

cleanUp ()
{
	if (( concat == 1 && m4bFile == 1 )); then
		while read LINE; do
			rm "$(awk -F"['']" '{print $1}' <<< $LINE)"
		done < cat.cc
	fi
	rm *.cc >/dev/null 2>&1
	if [[ -s $debugLog ]]; then
		echo -e "${Red}Warning, errors detected during processing, check $debugLog.${C0}"
		echo -e "ccab finished @ $(date +%H:%M:%S" on "%Y.%m.%d)" >> $ccLog
	else
		rm $debugLog >/dev/null 2>&1
		rm ccConcat.mp3 cc.log >/dev/null 2>&1
	fi
	echo -e "${Green}\ndOnE!${C0}"
	# exit 0
}

display ()
{
	# Function used to format and display status.
	trap 'CleanUp' 1 2 3 15
	width=$(echo "scale=0;$(tput cols)-10" | bc)
	echo -e "`tput sc`${Cyan}${1}...${C0}`tput rc ; tput cuf $width`\c"
        WAIT &
        WPID=$!
	   return 0
}

getFiles ()
{
	# Find all audio files in current or recursive directories.
	rm list.cc temp.cc >/dev/null 2>&1
	if (( moveOnly == 1 )); then
		find -maxdepth 1 -iregex ".*\.abr[0-9][0-9].mp3" -fprintf temp.cc '%h/%f\n'
	elif (( recurse == 1 )); then
		logIt "${LINENO}.[trace ].[getFiles]find -iregex '.*.$searchType' -fprintf temp.cc '%h/%f\\\\n'"
		find -iregex "$searchType" -fprintf temp.cc '%h/%f\n'
	else
		logIt "${LINENO}.[trace ].[getFiles]find -maxdepth 1 -iregex '.*.$searchType' -fprintf temp.cc '%h/%f\\\\n'"
		find -maxdepth 1 -iregex "$searchType" -fprintf temp.cc '%h/%f\n'
	fi

	# Remove already converted files from list
	if (( moveOnly == 0 && update == 0 )); then
		sed -r -i '/(\.abr[0-9]{2,3}\.mp3$)/d' temp.cc
	fi
	# Remove already concatenated file from list
	sed -i '/ccConcat.mp3/d' temp.cc

	# Restructure list for use with ffmpeg
	COUNT=0
	while read FILE; do
		origFile[$COUNT]=$FILE
		if (( concat == 1 )); then
			echo "file '$FILE'" >> list.cc
		fi
		((COUNT++))
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
	display "Checking file $in"
	logIt "${LINENO}.[trace ].[checkFile] in=$in"
	logIt "${LINENO}.[trace ].[checkFile] out=$out"
	logIt "${LINENO}.[trace ].[checkFile] inExt=$inExt"
	logIt "${LINENO}.[trace ].[checkFile] baseName=$baseName"

	if (( concat == 1 )); then
		echo "file '$out'" >> cat.cc
	fi

	if [[  $inExt = "m4b" || $inExt = "m4a" ]]; then

		if [[ -s $out || -s ccConcat.mp3 ]]; then
			# File already converted.
			logIt "${LINENO}.[  ok  ].[checkFile] $in previously converted."
			
			if (( concat == 1 )); then
				# Check if next file the same as $out to avoid duplicates.
				let COUNT=$LOOP+1
				if [[ ${origFile[$COUNT]} = "$out" ]]; then
					logIt "${LINENO}.[trace ].[checkFile] unset origFile[$COUNT]"
					unset origFile[$COUNT]
				fi
			fi

			killWait 3
			return 3
		else
			# Need to convert.
			logIt "${LINENO}.[trace ].[checkFile] Need to convert ${in}."
			killWait 2 "Need to convert $in."
			return 1
		fi
	else 
		if [[ $(find . -path "${baseName}.abr??.mp3" | wc -l) -gt 0 ]]; then
			# mp3 file already encoded.
			logIt "${LINENO}.[trace ].[checkFile] *** $in already encoded. ***"
			killWait 3
			return 0
		else
			logIt "${LINENO}.[trace ].[checkFile] Need to encode $in."
			killWait 3 "File $in has not been re-encoded."
			return 2
		fi
	fi
}

probeFile ()
{
	# Gather information on the book (title, series, info, etc.).

	# set -x
	in="$1"
	display "Collecting tag information"

	# Get Book Title from IDv3 tags (if available)
	bookTitle=$(ffprobe "$in" 2>&1 | grep -e '^ \{4\}title' | sed 's/  //g' | sed 's/title : //')
		bookTitle=$(sed -r 's/^Ch[0-9]{2}\s-\s//' <<< $bookTitle)
		bookTitle=$(sed -r 's/^Track\s[0-9]{1,2}//' <<< $bookTitle)
		bookTitle=$(sed -r 's/^[0-9]{2}.[0-9]{2}\s//' <<< $bookTitle)
		# bookTitle=$(echo $bookTitle | sed -r 's/ [0-9]{2}.*$//')

	# Get Book Authro
	bookAuthor=$(ffprobe "$in" 2>&1 | grep -e '^ \{4\}artist' | sed 's/  //g' | sed 's/artist: //')
	bookAuthorReverse=$(echo $bookAuthor | awk '{$1=$NF", "$1;NF--} 1' | sed 's/\.$//')

	# Get Book Series
	bookSeries=$(ffprobe "$in" 2>&1 | grep -e '^ \{4\}album\s*:' | sed 's/  //g' | sed 's/album : //')

	bookDuration=$(ffprobe "$in" 2>&1 |grep 'Duration' | awk -F',' '{print $1}' | awk '{print $2}')
	bookBitrate=$(ffprobe "$in" 2>&1 |grep 'Duration' | awk -F',' '{print $3}' | awk '{print $2}')
	if (( bookBitrate > targetBitrate )); then
		bookBitrate=$targetBitrate
	elif (( bookBitrate > 40 )); then
		bookBitrate=48
	else
		bookBitrate=32
	fi
	bookSize=$(ffprobe -v error -select_streams a:0 -show_entries format=size -of default=noprint_wrappers=1 "$in" 2>>$debugLog | awk -F '=' '{print $2}')
	bookSize="$(echo "scale=2;$bookSize/1048576" | bc) MB"
	audioStream=$(ffprobe "$in" 2>&1 | grep -E 'Stream.*Audio' | sed 's/^.*Stream //')
	bookSample=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of default=noprint_wrappers=1 "$in" 2>>$debugLog | awk -F '=' '{print $2}')
	bookSample=$(echo "scale=2;$bookSample/1000" | bc)

	# Log discovered file information
	logIt "${LINENO}.[trace ].[probeFile]in=$in"
	logIt "${LINENO}.[trace ].[probeFile]  bookTitle=$bookTitle"
	logIt "${LINENO}.[trace ].[probeFile]  bookAuthor=$bookAuthor"
	logIt "${LINENO}.[trace ].[probeFile]  bookSeries=$bookSeries"
	logIt "${LINENO}.[trace ].[probeFile]  bookDuration=$bookDuration"
	logIt "${LINENO}.[trace ].[probeFile]  bookBitrate=$bookBitrate"
	logIt "${LINENO}.[trace ].[probeFile]  bookSize=$bookSize"
	logIt "${LINENO}.[trace ].[probeFile]  audioStream=$audioStream"
	logIt "${LINENO}.[trace ].[probeFile]  bookSample=$bookSample"

	if [[ -z $bookTitle || -z $bookAuthor ]]; then
		logIt "${LINENO}.[ WARN ].[probeFile] No book information found."
		killWait 2 "No book information found for $in."
		return 1
	else
		killWait 3
		return 0
	fi
}

promptTags ()
{
	echo -e "${Cyan}Collect ID3 tags for $1${C0}"
	tempTitle=$bookTitle
	echo -e "${Cyan}  Please enter a title for this book: [${Yellow}${tempTitle}${Cyan}]${C0}\c"
	read bookTitle
	bookTitle=${bookTitle:-$tempTitle}
	logIt "${LINENO}.[trace ].[promptTags] bookTitle=$bookTitle"

	tempAuthor=$bookAuthor
	echo -e "${Cyan}  Please enter an author for this book: [${Yellow}${tempAuthor}${Cyan}]${C0}\c"
	read bookAuthor
	bookAuthor=${bookAuthor:-$tempAuthor}
	logIt "${LINENO}.[trace ].[promptTags] bookAuthor=$bookAuthor"

	#TODO add logic for no series
#	tempSeries=$bookSeries
#	echo -e "${Cyan}  Please enter the series for this book: [${Yellow}${tempSeries}${Cyan}]${C0}\c"
#	read bookSeries
#	bookSeries=${bookSeries:-$tempSeries}
#	logIt "${LINENO}.[trace ].[promptTags] bookSeries=$bookSeries"
	
	fullName="$bookAuthor - $bookSeries - $bookTitle"
	logIt "${LINENO}.[trace ].[promptTags] fullName=$fullName"
	return 0
}

concatFiles ()
{
	display "Concatenating discovered audio files"
	outCat="ccConcat.mp3"
	# Fix apostrophes in title for ffmpeg
	sed -i "s/'s/'\\\''s/g" cat.cc
	cat cat.cc | grep ' [1-9]\.' | sort -h > cat2.cc
	cat cat.cc | grep -v ' [1-9]\.' | sort -h >> cat2.cc
	mv cat2.cc cat.cc
	if (( verify == 1 )); then
		vi cat.cc
	fi
	if [[ ! -s $outCat ]]; then
		killWait 5
		ffmpeg -loglevel fatal -y -safe 0 -f concat -i cat.cc -vn -sn -c copy "$outCat"
		STATUS=$?
	else
		killWait 0
		STATUS=0
	fi

	if (( STATUS > 0 )); then
		logIt "${LINENO}.[ERROR!].[concatFiles] $STATUS: ffmpeg -loglevel error -y -safe 0 -f concat -i cat.cc -vn -sn -c copy \"$outCat\""
		# killWait 1 "Failed to concatenate audio files."
		echo -e "${Red}ERROR: $STATUS concatenating files."
		return $STATUS
	elif (( remove == 1 )); then
		logIt "${LINENO}.[  ok  ].[concatFiles] ffmpeg -loglevel error -y -safe 0 -f concat -i cat.cc -vn -sn -c copy \"$outCat\""
		while read LINE; do
			logIt "${LINENO}.[  ok  ].[concatFiles] rm "$(awk -F\' '{print $2}' <<< $LINE)" >>$debugLog 2>&1"
			rm "$(awk -F\' '{print $2}' <<< $LINE)" >>$debugLog 2>&1
		done < cat.cc
		rm cat.cc
	else
		logIt "${LINENO}.[  ok  ].[concatFiles] ffmpeg -loglevel error -y -safe 0 -f concat -i cat.cc -vn -sn -c copy \"$outCat\""
	fi
	bookDuration=$(ffprobe "$outCat" 2>&1 |grep 'Duration' | awk -F',' '{print $1}' | awk '{print $2}')
	return 0
}

tagIt ()
{
	in=$1
	display "Applying ID3 tags to $in"
	logIt "${LINENO}.[trace ].[tagIt] in=$in"
	# Set tags to discovered tags
	author=$bookAuthor
	title=$bookTitle
	series=$bookSeries
	logIt "${LINENO}.[trace ].[tagIt] author=$author"
	logIt "${LINENO}.[trace ].[tagIt] title=$title"
	logIt "${LINENO}.[trace ].[tagIt] series=$series"
	logIt "${LINENO}.[trace ].[tagIt] bookCover=$bookCover"
	if [[ -z $author || -z $title ]]; then
		killWait 1 "No tag information to apply, bailing."
		return 1
	fi

  # Attempted to use several command line tag editors, mid3v2 does most of what I needed, but has some 
  # issues with cover art....

#	eyeD3 --no-color --remove-all "$in" >/dev/null 2>>$ccLog
	mid3v2 --delete-all "$in" >/dev/null 2>>$ccLog
	if [[ -s "$bookCover" ]]; then
		# Failing back to fancy_audio for cover art :/.
		# eyeD3 --no-color -a "$author" -A "$series" -t "$title" -G 101 -n 1 -c eng:encoder:theGh0st "$in" >/dev/null 2>&1
		fancy_audio "$in" "$bookCover" 1>>$debugLog 2>&1
		mid3v2 -a "$author" -A "$series" -t "$title" -g "audiobook" -T 1 -c "Comment":"$goodreadsURL":"eng" -c "Rating":"$bookRating":"eng" -c "Encoded by":"theGh0st":"eng" "$in" >/dev/null 2>>$debugLog
		STATUS=$?
		if (( STATUS > 0 )); then
			logIt "${LINENO}.[ERROR!].[tagIt] $STATUS: mid3v2 -a \"$author\" -A \"$series\" -t \"$title\" -g "audiobook" -T 1 -c \"Comment\":\"$goodreadsURL\":\"eng\" -c \"Rating\":\"$bookRating\":\"eng\" -c \"encoder\":\"theGh0st\":\"eng\" \"$in\""
			killWait 1 "Error adding tags to $in."
			return $STATUS
		else
			logIt "${LINENO}.[  ok  ].[tagIt] tagging completed successfully."
			killWait 0
			return 0
		fi
	else
		# eyeD3 --no-color -a "$author" -A "$series" -t "$title" -G 101 -n 1 -c eng:encoder:theGh0st "${in}" >/dev/null 2>&1
		mid3v2 -a "$author" -A "$series" -t "$title" -g "audiobook" -T 1 -c "Comment":"$goodreadsURL":"eng" -c "Rating":"$bookRating":"eng" -c "Encoded by":"theGh0st":"eng" "$in" >/dev/null 2>>$debugLog
		STATUS=$?
		if (( STATUS > 0 )); then
			logIt "${LINENO}.[ERROR!].[tagIt] $STATUS: mid3v2 -a \"$author\" -A \"$series\" -t \"$title\" -g "audiobook" -T 1 -c \"Comment\":\"$goodreadsURL\":\"eng\" -c \"Rating\":\"$bookRating\":\"eng\" -c \"encoder\":\"theGh0st\":\"eng\" \"$in\""
			killWait 1 "Error adding tags to $in."
			return $STATUS
		else
			logIt "${LINENO}.[  ok  ].[tagIt] eyeD3 -a \"$author\" -A \"$series\" -t \"$title\" -G 101 -n 1 -c eng:encoder:theGh0st \"${in}\""
			killWait 0
			return 0
		fi
	fi
}

convert ()
{
	in=$1
	out="$(sed 's/....$//' <<< $in).mp3"
	outFile[$LOOP]=$out
	echo -e "${Cyan}Converting $in to .mp3${C0}"
	logIt "${LINENO}.[trace ].[convert] in=$in"
	logIt "${LINENO}.[trace ].[convert] out=$out"
	# echo -e "${Grey}"
	# ffmpeg ${ffOptions} -i "${in}" -vn -sn -map_metadata -1 "${tmpOut}" 
	if [[ ! -s $out ]]; then
		ffmpeg -loglevel error -i "${in}" -vn -sn -map_metadata -1 "${out}" 
		STATUS=$?
	else
		logIt "${LINENO}.[ WARN ].[convert] $out already exist."
		STATUS=0
	fi
	# echo -e "${C0}"
	if (( STATUS > 0 )); then
		logIt "${LINENO}.[ERROR!].[convert] $STATUS: ffmpeg ${ffOptions} -i \"${in}\" -vn -sn -map_metadata -1 \"${out}\""
		echo -e "${Red}File conversion failed for ${in}.${C0}"
		return 1
	else
		logIt "${LINENO}.[  ok  ].[convert] ffmpeg ${ffOptions} -i \"${in}\" -vn -sn -map_metadata -1 \"${out}\""
		echo "$(date +%Y.%m.%d' @ '%H:%M.%S) ${in}" >> $m4bLog
		# Set flag for m4b/m4a conversion success.
		m4bFile=1
		# Add converted file to concat list if option set.
		if (( concat == 1 )); then
			echo "file '$out'" >> cat.cc
		fi
		if (( concat == 1 )); then
			rm ccConcat.mp3 > /dev/null 2>&1
		fi
		return 0
	fi
}

displayInfo ()
{
	prompt=$1
	if [[ -z $bookAuthor || -z $bookTitle ]]; then
		logIt "${LINENO}.[ERROR!].[displayInfo] No information to display."
		echo -e "${Red}Nothing to display, bailing."
		return 1
	fi
	logIt "${LINENO}.[trace ].[displayInfo] bookAuthor=$bookAuthor; bookTitle=$bookTitle"

	echo ""
	echo -e "  ${Yellow}Author:  ${Pink}$bookAuthor${C0}"
	echo -e "  ${Yellow}Reverse: ${Pink}$bookAuthorReverse${C0}"
	echo -e "  ${Yellow}Title:   ${Pink}$bookTitle${C0}"
	echo -e "  ${Yellow}Series:  ${Pink}$bookSeries${C0}"
	echo -e "  ${Yellow}Rating:  ${Pink}$bookRating${C0}"
	echo -e "  ${Yellow}Stream:   ${Pink}$audioStream${C0}"
	echo -e "  ${Yellow}Bitrate:  ${Pink}$bookBitrate${C0}"
	echo -e "  ${Yellow}Sample:   ${Pink}$bookSample${C0}"
	echo -e "  ${Yellow}Duration: ${Pink}$bookDuration${C0}"
	echo -e "  ${Yellow}Size:     ${Pink}$bookSize${C0}"
	echo -e "  ${Yellow}URL:      ${Pink}$goodreadsURL${C0}"
	if [[ -s genre.cc ]]; then
		echo -e "  ${Yellow}Classifications:${C0}"
		while read LINE; do
			echo -e "    ${Pink}$(sed -r 's/^[0-9]{2} / &/; s/^[0-9] /  &/' <<< $LINE )${C0}"
		done < genre.cc
	fi
	echo ""
	if [[ -n $prompt ]]; then
		unset prompt
		echo -e "${Cyan}Do you want to change values?${C0} [n]\b\b\c"
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
	if [[ ! -s info.cc ]]; then
		logIt "${LINENO}.[ERROR!].[getInfo] No info.cc file to search, bailing."
		return 1
	fi
	logIt "${LINENO}.[trace ].[getInfo] baseName=$baseName"
	logIt "${LINENO}.[trace ].[getInfo] > write genre.cc and book info"
	origIFS="$IFS"
	IFS=$'\n'
	grep -E 'people shelved this book' info.cc | sed 's/&#39;//g' |awk -F'"' '{print $2}' | head -5 > genre.cc
	IFS="$origIFS"

	echo "Author:    $bookAuthor" > "${baseName}.info"
	echo "Title:     $bookTitle" >> "${baseName}.info" 
	echo "Series:    $bookSeries" >> "${baseName}.info" 
	echo "Rating:    $bookRating" >> "${baseName}.info" 
	echo "Duration:  $bookDuration" >> "${baseName}.info" 
	echo "URL:       $goodreadsURL" >> "${baseName}.info" 
	echo -e "\nClassifications:" >> "${baseName}.info" 
	while read LINE; do
		echo "  $(sed -r 's/^[0-9]{3} / &/; s/^[0-9]{2} /  &/; s/^[0-9] /   &/' <<< $LINE)" >> "${baseName}.info"
	done < genre.cc
	echo -e "\nSummary:" >> "${baseName}.info" 

	# grep -m 1 -E '^.*<span id.*:none">' info.cc | sed "s/<br>/\n/g; s/<[^>]*>//g; s/\xE2\x80\x99/\'/g; s/\xE2\x80\x94/\-/g" | fold -w 80 -s >> "${baseName}.info"
	# Attempt to get the full book summary information.
	bookID=$(grep -m 1 -E '^.*freeTextContainer.*>' info.cc | awk -F'[""]' '{print $2}' | sed 's/Container//')
	if (( $(grep -c $bookID info.cc) == 0 )); then
		bookID=$(sed 's/freeText/freeTextContainer/' <<< $bookID)
	fi
	# grep $bookID info.cc | sed "s/<br>/\n/g; s/<[^>]*>//g; s/\xE2\x80\x99/\'/g; s/\xE2\x80\x94/\-/g" | fold -w 80 -s >> "${baseName}.info"
	logIt "${LINENO}.[trace ].[getInfo] bookID=$bookID"
	grep $bookID info.cc | sed "s/<br>/\n/g; s/<[^>]*>//g; s/\xE2\x80//g; s/\x99/'/g; s/\x94/\-/g" | fold -w 80 -s >> "${baseName}.info"
	logIt "${LINENO}.[trace ].[getInfo] >grep $bookID info.cc | sed \"s/<br>/\\\n/g; s/<[^>]*>//g; s/\xE2\x80//g; s/\x99/'/g; s/\x94/\-/g\" | fold -w 80 -s >> \"${baseName}.info\""
	sed -i 's/\xE2\x80\x9C/"/g; s/\xE2\x80\x9D/"/g; s/\xC3\x82//g; s/\xC5\x93/"/g; s/\xC2\x9D/"/g' "${baseName}.info"
	logIt "${LINENO}.[trace ].[getInfo] >sed -i 's/\xE2\x80\x9C/\"/g; s/\xE2\x80\x9D/\"/g; s/\xC3\x82//g' \"${baseName}.info\""
	
	# Replace extended characters with apostrophe
	# echo "X" | od -t x1c  # Display hex codes
	
	# Download book cover image
	if [[ ! -s "${bookCover}" ]]; then
		curl -s -o "${bookCover}" $imageSource 1>>$debugLog 2>&1
		STATUS=$?
		if (( STATUS > 0 )); then
			logIt "${LINENO}.[ERROR!].[getInfo] $STATUS: curl -s -o \"$bookCover\" $imageSource"
		else
			logIt "${LINENO}.[  ok  ].[getInfo] curl -s -o \"$bookCover\" $imageSource"
		fi
	else
		logIt "${LINENO}.[trace ].[getInfo] Using existing cover art ${bookCover}"
	fi

	# Create shortcut to goodreads url
	urlName="${baseName}.goodreads.url"
	logIt "${LINENO}.[trace ].[getInfo] *** Creating ${urlName}.goodreads.url ***"
	echo "[{000214A0-0000-0000-C000-000000000046}]" > "${urlName}"
	echo "Prop3=19,2" >> "${urlName}"
	echo "[InternetShortcut]" >> "${urlName}"
	echo "IDList=" >> "${urlName}"
	echo "URL=$goodreadsURL" >> "${urlName}"
	return 0
}

lookupMP3 ()
{
	in="$1"
	echo -e "${Cyan}Looking up \"$bookTitle\" + \"$bookAuthor\"${C0}"
	searchString="$bookTitle $bookAuthor"
		# Various filters for book titles before search, ideally only book title and author.
		searchString=$(sed 's/([Uu]nabridged)//' <<< "$searchString")
	logIt "${LINENO}.[trace ].[lookupMP3] googler -n 5 --np -C -w goodreads.com \"$searchString\""
	googler -n 5 --np -C -w goodreads.com "$searchString" > results.cc 2>/dev/null
	while [[ ! -s results.cc ]]; do
		echo -e "${Red}No results found using search: ${Yellow}$searchString${C0}"
		echo -e "${Cyan}Enter new book title [${Yellow}$bookTitle${C0}]: ${Yellow}\c"
		read tmpBookTitle
		bookTitle=${tmpBookTitle:-$bookTitle}
		echo -e "${Cyan}Enter new book author [${Yellow}$bookAuthor${C0}]: ${Yellow}\c"
		read tmpBookAuthor
		bookAuthor=${tmpBookAuthor:-$bookAuthor}
		searchString="$bookTitle $bookAuthor"
		echo -e "${Cyan}Searching for $searchString.${C0}"
		googler -n 5 -C --np -w goodreads.com "$searchString" > results.cc
		STATUS=$?
	done

	goodreadsURL=$(grep -E '(http|https):.*book' results.cc | head -n 1)
	if [[ -z $goodreadsURL || $verify -eq 1 ]]; then
		echo -e "${C0}"
		cat results.cc
		echo -e "${Yellow}Pick the number of the link results to use for info ('6' for new search, '7' direct URL): \c${C0}"
		read result 
		while [[ $result -lt 1 || $result -gt 5 ]]; do
			if [[ $result -eq 6 ]]; then
				echo -e "${Cyan}Enter new search string: ${C0}\c"
				read searchString
				googler -n 5 --np -C -w goodreads.com "$searchString" > results.cc 2>/dev/null
				cat results.cc
				result=0
			elif [[ $result -eq 7 ]]; then
				echo -e "${Cyan}Enter book URL manually: ${C0}\c"
				read goodreadsURL
#				echo "DEBUG: URL=$goodreadsURL"
#				echo "DEBUG: result=$result"
				break
			else
				echo -e "${Yellow}Pick the number of the link results to use for info ('6' for new search): \c${C0}"
				read result
		#		goodreadsURL=$(grep -A 1 "^ $result" results.cc | tail -1)
			fi
		done
		if [[ $result -gt 0 && $result -lt 6 ]]; then
			goodreadsURL=$(grep -A 1 "^ $result" results.cc | tail -1)
		fi
	fi
	logIt "${LINENO}.[trace ].[lookupMP3] goodreadsURL=${goodreadsURL}"

	if [[ -n ${goodreadsURL} ]]; then
		rm info.cc 2>/dev/null
		curl -s ${goodreadsURL} -o info.cc 1>>$debugLog 2>&1
		STATUS=$?
		if (( STATUS > 0 )); then
			logIt "${LINENO}.[ERROR!].[lookupMP3] $STATUS: curl -s $goodreadsURL -o info.cc"
			return $STATUS
		else
			logIt "${LINENO}.[  ok  ].[lookupMP3] curl -s $goodreadsURL -o info.cc"
		fi
		logIt "${LINENO}.[trace ].[lookupMP3] bookSeries> grep -A 1 -E 'class=\\\"greyText.*\/series\/' info.cc | tail -1 | sed 's/(Publication) //' | awk -F '[()]' '{print \$2}' | tr -d '#'"
		bookSeries=$(grep -A 1 -E 'class=\"greyText.*\/series\/' info.cc | tail -1 | sed 's/(Publication) //' | sed 's/(Part .)//; s/\&amp;/\&/g' | awk -F '[()]' '{print $2}' | tr '#' '0' | tr '/' '-' | tr ':' ',')
		if [[ -z $bookSeries ]]; then
			# try 2nd approach
			bookSeries=$(grep -A 1 -E '<h1 id="bookTitle" class="bookTitle"' info.cc | tail -1 | awk -F'[()]' '{print $2}' | sed 's/\&amp;/\&/' | tr '/' '-' | tr ':' ',')
		fi
		# A whole lot of manipulation to get padded series numbers and or .x versions
		bookSeriesNum=$(awk '{print $NF}' <<< $bookSeries | sed 's/^0//')
		majorNum=$(awk -F'.' '{printf "%.2d", "$1"}' <<< $bookSeriesNum)
		if [[ $majorNum = "00" ]]; then
			majorNum=$(printf "%.2d" "$bookSeriesNum" 2>/dev/null) 
		fi
		logIt "${LINENO}.[trace ].[lookupMP3] majorNum=$majorNum"
		minorNum=$(awk -F'.' '{print $2}' <<< $bookSeriesNum)
		if [[ -n $minorNum ]]; then
			bookSeriesNum="${majorNum}.${minorNum}"
			logIt "${LINENO}.[trace ].[lookupMP3] minorNum=$minorNum"
		else
			bookSeriesNum="${majorNum}"
		fi
		logIt "${LINENO}.[trace ].[lookupMP3] bookSeriesNum=$bookSeriesNum"
		bookSeries="$(awk 'NF{NF--};1' <<< $bookSeries) $bookSeriesNum"

		if [[ $bookSeries == ' 00' ]]; then
			bookSeries="00"
		fi
		logIt "${LINENO}.[trace ].[lookupMP3] bookSeries=${bookSeries}"

		logIt "${LINENO}.[trace ].[lookupMP3] bookTitle>grep -A 1 'id=\"bookTitle\" class=\"bookTitle\" itemprop=\"name\"' info.cc |tail -1 | sed 's/^[[:space:]]*//'"
		bookTitle=$(grep -A 1 'id="bookTitle" class="bookTitle" itemprop="name"' info.cc |tail -1 | sed 's/^[[:space:]]*//' | awk -F'[()]' '{print $1}' | sed 's/\&amp;/\&/g; s/ $//; s/\//-/g; s/\\/-/g' | tr ':' '-' | tr -d '?')
		logIt "${LINENO}.[trace ].[lookupMP3] bookTitle=${bookTitle}"

		logIt "${LINENO}.[trace ].[lookupMP3] bookAuthor>grep 'class=\"authorName\" itemprop=\"url\"' info.cc | awk -F'>' '{print \$3}' | sed 's/<.*$//; s/  / /g' | head -1"
		bookAuthor=$(grep 'class="authorName" itemprop="url"' info.cc | awk -F'>' '{print $3}' | sed 's/<.*$//; s/  / /g' | head -1)
		bookAuthorReverse=$(awk '{$1=$NF", "$1;NF--} 1' <<< ${bookAuthor} | sed 's/\.$//')
		logIt "${LINENO}.[trace ].[lookupMP3] bookAuthor=$bookAuthor"
		logIt "${LINENO}.[trace ].[lookupMP3] bookAuthorReverse=${bookAuthorReverse}"

		bookRating=$(grep 'ratingValue' info.cc | sed 's/.*<.*ratingValue">//; s/<\/.*>//')
		logIt "${LINENO}.[trace ].[lookupMP3] bookRating=${bookRating}"

		imageSource=$(grep -m 1 'Audible' info.cc |sed 's/\\n/\n/g' |grep 'img src' | awk -F'"' '{print $2}' | tr -d '\\')
		if [[ -z ${imageSource} ]]; then
			imageSource=$(grep -m 1 '\"coverImage\"' info.cc |sed 's/ /\n/g' |grep 'src' |awk -F'"' '{print $2}')
			logIt "${LINENO}.[trace ].[lookupMP3] Using default image source"
		else
			logIt "${LINENO}.[trace ].[lookupMP3] Using Audible image source"
		fi
		logIt "${LINENO}.[trace ].[lookupMP3] imageSource=${imageSource}"
		baseName="${bookAuthor} - ${bookSeries} - ${bookTitle}"
		logIt "${LINENO}.[trace ].[lookupMP3] baseName=${baseName}"
		bookCover="${baseName}.cover.jpg"
		logIt "${LINENO}.[trace ].[lookupMP3] bookCover=${bookCover}"
	fi
	return 0
}

reEncode ()
{
	in=$1
	display "Encoding $in"
	# Reset name of output file (append bitrate info).
	baseName="${bookAuthor} - ${bookSeries} - ${bookTitle}"
	outFile[$LOOP]="${baseName}.abr${bookBitrate}.mp3"

	logIt "${LINENO}.[trace ].[reEncode] in=$in"
	logIt "${LINENO}.[trace ].[reEncode] baseName=$baseName"
	logIt "${LINENO}.[trace ].[reEncode] outFile[$LOOP]=${outFile[$LOOP]}"
	logIt "${LINENO}.[trace ].[reEncode] bookAuthor=$bookAuthor"
	logIt "${LINENO}.[trace ].[reEncode] bookSeries=$bookSeries"
	logIt "${LINENO}.[trace ].[reEncode] bookTitle=$bookTitle"
	logIt "${LINENO}.[trace ].[reEncode] bookSample=$bookSample"

	# Re-encode input file with my parameters.
	killWait 5
	echo -e "${Grey}"
   	logIt "${LINENO}.[trace ].[reEncode] lame --nohist -m m --abr $bookBitrate --resample $bookSample \"$in\" \"${outFile[$LOOP]}\""
	if [[ ! -s ${outFile[$LOOP]} ]]; then
	   	lame --nohist -m m --abr $bookBitrate --resample $bookSample "$in" "${outFile[$LOOP]}" 
		STATUS=$?
	else
		# File previously encoded.
		echo -e "${Yellow}${outFile[$LOOP]} already encoded, skipping.${C0}"
		logIt "${LINENO}.[  ok  ].[reEncode] File already encoded."
		STATUS=2
	fi
	echo -e "${C0}"

	display "Check encoding status"
	if (( STATUS == 1 )); then
		killWait 1 "Error during re-encode!"
		logIt "${LINENO}.[ERROR!].[reEncode] $STATUS: Unknown error during lame encoding."
		return $STATUS
	else
#		if [[ $in = 'ccConcat.mp3' ]]; then
#			rm $in
#		fi
		logIt "${LINENO}.[  ok  ].[reEncode] lame encoding success."
		killWait 0
		return 0
	fi
}

moveIt ()
{
	inFile="$1"
	PS3_Orig=$PS3
	PS3="Select book type: "

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

	while [[ -z $catagory ]]; do
		echo -e "\n${Yellow}Available book types${C0}\n"

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

	baseDir=$(sed 's/\/$//' <<< ${baseDir})
	outDir="$baseDir/$bookType/$bookAuthorReverse/$bookSeries - $bookTitle/"
	baseName="$bookAuthor - $bookSeries - $bookTitle"
	if [[ -e "${outDir}/${baseName}\.abr[0-9][0-9]\.mp3" ]]; then
		logIt "${LINENO}.[ WARN ].[moveIt] ${outDir}" already exist, skipping move.
		killWait 1 "${outDir}/${baseName}.abr??.mp3 already exist, skipping move."
		return 1
	fi
	display "Moving to $outDir"
	mkdir -p "$outDir" 1>>$debugLog 2>&1

	logIt "${LINENO}.[trace ].[moveIt] outDir=${outDir}"
	logIt "${LINENO}.[trace ].[moveIt] baseName=${baseName}"

	if [[ ! -e "$inFile" ]]; then
		killWait 2 "No '${baseName}*' files found to move."
		logIt "${LINENO}.[ERROR!].[moveIt] *** '${baseName}*' files not found. ***"
		return 1
	fi
	
	if [[ -s "$outDir/$inFile" ]]; then
		killWait 1 "Output file already exist, bailing"
		logIt "${LINENO}.[ERROR!].[moveIt] *** '${outDir}/${baseName}*' files already exist. ***"
		return 1
	fi
	IFS=$'\n'
	for LINE in $(find . -name "${baseName}.*"); do
		mv "$LINE" "$outDir" 1>>$debugLog 2>&1
	done
	STATUS=$?
	if (( STATUS > 0 )); then
		logIt "${LINENO}.[ERROR!].[moveIt] $STATUS: mv \"${baseName}\"* \"$outDir\""
		killWait 1 "Unable to move files to $outDir"
		return $STATUS
	else
		logIt "${LINENO}.[  ok  ].[moveIt] mv \"${baseName}\"* \"$outDir\""
		killWait 3
		rm genre.cc info.cc >/dev/null 2>&1
		return 0
	fi
}


# MAIN
logIt "${LINENO}.[trace ].[ MAIN ] options=$options"
getFiles
LOOP=0

# Move only.
if (( moveOnly == 1 )); then
	COUNT=0
	while (( COUNT < ${#origFile[*]} )); do
		probeFile "${origFile[$COUNT]}"
		# lookupMP3 
		# displayInfo 
		cat "$bookAuthor - $bookSeries - $bookTitle.info"
		moveIt "${origFile[$COUNT]}"
		echo "$(date +%Y.%m.%d), [$bookType], ${origFile[$LOOP]}" >> $convertLog
		((COUNT++))
	done
	cleanUp
	exit 0
fi


# Update only.
if (( update == 1 )); then
	inFile="${origFile[0]}"
	probeFile "$inFile"
	if [[ -z $bookAuthor || -z $bookTitle ]]; then
		echo "No tags for $inFile, bailing."
		echo -e "$inFile" >> no_tags.txt
		exit 1
	fi
	lookupMP3
	getInfo
	ext=$(echo $inFile | awk -F'.' '{print $(NF-1)"."$NF}')
	outFile="${bookAuthor} - ${bookSeries} - ${bookTitle}.${ext}"
	# displayInfo
	echo -e "\n${Cyan}SOURCE: ${Yellow}${origFile[0]}${C0}"
	echo -e "${Cyan}TARGET: ${Pink}${outFile}${C0}"
	echo -e "${Yellow}Sleeping...${C0}\n"
#	sleep 2
	if [[ "$inFile" != "./$outFile" ]]; then
		mv "$inFile" "$outFile"
		tagIt "$outFile"
	fi
	if (( move == 1 )); then
		displayInfo
		moveIt "$outFile"
	fi
	cleanUp
	rm cc.log
	exit 0
fi


# Concatenate files if option set.
if (( concat == 1 )); then
	logIt "${LINENO}.[trace ].[ MAIN ] Concatenating Files."
	probeFile "${origFile[0]}"
	STATUS=$?
	if (( STATUS > 0 )); then
		displayInfo
		promptTags "${origFile[0]}"
	fi
	LOOP=0
	while (( LOOP < ${#origFile[*]} )); do
		checkFile "${origFile[$LOOP]}"
		CHECK=$?
		logIt "${LINENO}.[trace ].[ MAIN ] checkFile status: $CHECK"
		if (( CHECK == 1 )); then
			convert "${origFile[$LOOP]}"
		fi
		((LOOP++))
	done
	concatFiles
	STATUS=$?
	if (( STATUS > 0 )); then
		exit 1
	fi
	LOOP=0
	unset origFile[*]
	origFile[0]="ccConcat.mp3"

	lookupMP3 
	STATUS=$?
	while (( STATUS > 0 )); do
		displayInfo
		promptTags "${origFile[0]}"
		lookupMP3
		STATUS=$?
	done
	getInfo
	echo -e "${Cyan}Found the following information:${C0}"
	displayInfo
	if (( verify == 1 )); then
		echo -e "${Cyan}Change book author = ${Yellow}$bookAuthor${Cyan}:${C0} \c"
		read newAuthor
		bookAuthor=${newAuthor:-$bookAuthor}
		echo -e "${Cyan}Change book title = ${Yellow}$bookTitle${Cyan}:${C0} \c"
		read newTitle
		bookTitle=${newTitle:-$bookTitle}
		echo -e "${Cyan}Change series name = ${Yellow}$bookSeries${Cyan}:${C0} \c"
		read newSeries
		bookSeries=${newSeries:-$bookSeries}
		if [[ -e "$bookAuthor - 00 - $bookTitle.info" ]]; then
			mv "$bookAuthor - 00 - $bookTitle.info" "$bookAuthor - $bookSeries - $bookTitle.info" > /dev/null 2>&1
			mv "$bookAuthor - 00 - $bookTitle.goodreads.url" "$bookAuthor - $bookSeries - $bookTitle.goodreads.url" > /dev/null 2>&1
			mv "$bookAuthor - 00 - $bookTitle.cover.jpg" "$bookAuthor - $bookSeries - $bookTitle.cover.jpg" > /dev/null 2>&1
		fi
	fi
	reEncode "${origFile[0]}"
	STATUS=$?
	if (( STATUS == 0 )); then
		tagIt "${outFile[0]}"
	fi
	if (( remove == 1 )); then
		while read LINE; do
			rm "$LINE"
		done < list.cc
	fi
	if (( move == 1 )); then
		displayInfo
		moveIt "${outFile[0]}"
		echo "$(date +%Y.%m.%d), [$bookType], ${outFile[$LOOP]}" >> $convertLog
	fi
	cleanUp
	exit 0
fi


# Process various files one at a time.
LOOP=0
logIt "${LINENO}.[trace ].[ MAIN ] Encoding Files."
while (( LOOP < ${#origFile[*]} )); do
	logIt "****  Start LOOP: $LOOP  ****"
	probeFile "${origFile[$LOOP]}"
	STATUS=$?
	if (( STATUS > 0 )); then
		displayInfo
		promptTags "${origFile[$LOOP]}"
	fi

	checkFile "${origFile[$LOOP]}"
	STATUS=$?
	logIt "${LINENO}.[trace ].[ MAIN ] checkFile STATUS=$STATUS"
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
		   ((LOOP++))
		   continue
#		   origFile[$LOOP]="${outFile[$LOOP]}"
		   ;;
		0) # mp3 file, already converted
		   recodeFlag=0
		   m4bFlag=0
		   ;;
		*) # Unknown status, bailing
		   #TODO, fix this.
		   echo -e "${Red}Unknown status, skipping.${C0}"
		   ((LOOP++))
		   break
		   ;;
	esac

	lookupMP3
	while (( STATUS > 0 )); do
		displayInfo
		promptTags "${origFile[$LOOP]}"
		lookupMP3
		STATUS=$?
	done
	getInfo
	echo -e "${Cyan}Found the following information:${C0}"
	displayInfo

	if [[ $recodeFlag -eq 1 && $m4bFlag -eq 1 ]]; then
		convert "${origFile[$LOOP]}"
		tagIt "${outFile[$LOOP]}"
		origFile[$LOOP]="${outFile[$LOOP]}"
		removeMP3=1
	fi

	if (( recodeFlag == 1 )); then
		reEncode "${origFile[$LOOP]}"
		STATUS=$?
		if (( STATUS == 0 )); then
			tagIt "${outFile[$LOOP]}"
		fi
		if (( move == 1 )); then
			displayInfo
			moveIt "${outFile[$LOOP]}"
			echo "$(date +%Y.%m.%d), [$bookType], ${outFile[$LOOP]}" >> $convertLog
		fi
	fi
	if (( removeMP3 == 1 )); then
		rm "${origFile[$LOOP]}"
	fi
	removeMP3=0
	((LOOP++))
done
cleanUp
