#!/bin/bash

## DESCRIPTION:
##          This script will convert .flac files to .mp3 (leaving existing
##          .flac files in-place).  This script will also normalize the
##          the audio to typical levels.
##
## REQUIRED PACKAGES:
##          - ffmpeg (w/libmp3lame encoder & loudnorm enabled)
##          - mediainfo (to display audio differences)
##
## DATE:    2019.12.30 - rlp
##

inFileExt=${1:-'flac'}

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
for _FILE in *."$inFileExt"; do
  inFile[i]="$_FILE"
  # echo "DEBUG: inFile=${_FILE}"
  artist=$(ffprobe "$_FILE" 2>&1 |grep '[Aa]rtist' | awk -F': ' '{ print $2 }')
  album=$(ffprobe "$_FILE" 2>&1 |grep '[Aa]lbum' | awk -F': ' '{ print $2 }')
  title=$(ffprobe "$_FILE" 2>&1 |grep '[Tt]itle' | awk -F': ' '{ print $2 }')
  track=$(ffprobe "$_FILE" 2>&1 |grep '[Tt]rack' | awk -F': ' '{ print $2 }')
  track=$(printf '%02d' "$track")
  tmpOut="($artist) - $album - $track $title.mp3"
  ## Specify where and what output file.
  outFile[i]="./$album/$tmpOut"
  # echo "DEBUG: outFile=${outFile[$i]}"
  ((i++))
done 

if [[ ${inFile[0]} == "*.$inFileExt" ]]; then
  echo -e "\nERROR: No .$inFileExt files found here, bailing."
  exit 2
fi

## Create sub-directory for new mp3 files.
mkdir ./"$album" >/dev/null 2>&1

i=0
while [[ $i -lt ${#inFile[*]} ]]; do
  echo -e ">>> Processing file $((i + 1)) of ${#inFile[*]} <<<"
  echo -e "Normalizing ${inFile[$i]}..."
  ffmpeg -hide_banner -y -i "${inFile[$i]}" -filter:a loudnorm=print_format=json \
    -f mp3 /dev/null 2>&1 | sed -n '/{/,/}/p' > sample.json

  input_i=$(jq .input_i < sample.json | tr -d '"')
  input_tp=$(jq .input_tp < sample.json | tr -d '"')
  input_lra=$(jq .input_lra < sample.json | tr -d '"')
  input_thresh=$(jq .input_thresh < sample.json | tr -d '"')
  
  ## Desired output level of the file. (Change to match your preferences)
  outLevel="linear=true:I=-9:TP=-.2:LRA=11"
  ## Set measured levels.
  aOpts="-filter_complex loudnorm=${outLevel}:measured_I=$input_i:measured_tp=$input_tp:measured_LRA=$input_lra:measured_thresh=${input_thresh}[aOut]"
  #shellcheck disable=SC2089
  metaData='encoded_by="ffmpeg_N-95918"'

  echo -e "Re-encoding ${inFile[$i]}..."
  #shellcheck disable=SC2086,SC2090
  ffmpeg -hide_banner -loglevel warning -stats -y -i "${inFile[$i]}" \
    -c:a libmp3lame -q:a 1 $aOpts -ar 44100 -map [aOut] \
    -metadata $metaData "${outFile[$i]}"

  ## Display audio characteristics between in and out files.
  echo -e "\n< inFile: ${inFile[$i]}"
  mediainfo "${inFile[$i]}" | sed -n '/^Audio/,/^Writing/p'
  echo -e "\n> outFile: ${inFile[$i]}"
  mediainfo "${outFile[$i]}" | sed -n '/^Audio/,/^Writing/p'

  rm ./sample.json
  ((i++))
done
