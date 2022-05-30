#!/bin/bash

## DESCRIPTION:  This script will simply re-copy existing audio files (mp3) and
##               organize ID3 tags to v2.4, default for ffmpeg. It does not 
##               change the original audio stream.

inFileExt=${1:-'mp3'}

deadJim()
{
  ## Perform trap condition actions.
  echo -e "\nRoger boss, bailing now..."
  echo -e "BREAK,\n\tBREAK,\n\t\tBREAK!"
  exit 5
}

## Kill off the remaining files is CTRL-C encountered.
trap 'deadJim' 1 2 3 15

i=0
#shellcheck disable=SC2231
for _FILE in *.$inFileExt; do
  inFile[$i]="$_FILE"
  artist=$(ffprobe "$_FILE" 2>&1 |grep 'artist' | awk -F': ' '{ print $2 }')
  album=$(ffprobe "$_FILE" 2>&1 |grep 'album' | awk -F': ' '{ print $2 }')
  title=$(ffprobe "$_FILE" 2>&1 |grep 'title' | awk -F': ' '{ print $2 }')
  track=$(ffprobe "$_FILE" 2>&1 |grep 'track' | awk -F': ' '{ print $2 }')
  track=$(printf '%02d' "$track")
  ## Specify where and what output file.
  if [[ $inFileExt == 'mp3' || $inFileExt == 'flac' ]]; then
    tmpOut="($artist) - $album - $track $title.mp3"
    #outFile[$i]="./tmp/${inFile[$i]%.*}.mp3"
  elif [[ $inFileExt == 'mp4' || $inFileExt == 'mkv' ]]; then
    tmpOut="($artist) - $album - $track $title.mp4"
    #outFile[$i]="./tmp/${inFile[$i]%.*}.mp4"
  fi
  outFile[$i]=${tmpOut//\//}
  ((i++))
done 

if [[ ${inFile[0]} == "*.$inFileExt" ]]; then
  echo -e "\nERROR: No .$inFileExt files found here, bailing."
  exit 2
fi

## Create sub-directory for new mp3 files.
mkdir ./"$album" >/dev/null 2>&1

i=0
while [[ $i -lt ${#outFile[*]} ]]; do
  echo -e ">>> Processing file $((i + 1)) of ${#inFile[*]} <<<"
  # normalize audio
  #  ffmpeg -hide_banner -y -i "${inFile[$i]}" -vn -sn -filter:a loudnorm=print_format=json \
  #    -f mp3 /dev/null 2>&1 | sed -n '/{/,/}/p' > .sample.json
  #
  #  input_i=$(jq -r '.input_i' < .sample.json)
  #  input_tp=$(jq -r '.input_tp' < .sample.json)
  #  input_lra=$(jq -r '.input_lra' < .sample.json)
  #  input_thresh=$(jq -r '.input_thresh' < .sample.json)
  #  aOpts="loudnorm=I=-16:TP=-1.5:LRA=11:measured_I=$input_i:measured_tp=$input_tp:measured_LRA=$input_lra:measured_thresh=$input_thresh"
  #  rm .sample.json

# Use the following to normalize audio file.
#  ffmpeg -hide_banner -loglevel quiet -stats -y -i "${inFile[$i]}" -sn -c:v copy \
#    -af loudnorm=I=-10:LRA=11:TP=-.2  "$album/${outFile[$i]}"
  #shellcheck disable=SC2086,SC2090
  ffmpeg -hide_banner -loglevel quiet -stats -y -i "${inFile[$i]}" -sn -c:v copy \
    -c:a copy "$album/${outFile[$i]}"
  #STATUS=$?
  echo -e "\n< inFile: ${inFile[$i]}"
  mediainfo "${inFile[$i]}" | sed -n '/^Audio/,/^Writing/p'
  echo -e "\n> outFile: ${outFile[$i]}"
  mediainfo "${outFile[$i]}" | sed -n '/^Audio/,/^Writing/p'
#   if [[ $STATUS -eq 0 ]]; then
#     ## Moving new file to original if no error.
#     mv -f "${outFile[$i]}" "${inFile[$i]}"
#   fi
  ((i++))
done

## Remove temp directory if empty.
# rmdir ./tmp >/dev/null 2>&1
