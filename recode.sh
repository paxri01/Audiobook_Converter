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
#shellcheck disable=SC2231
for _FILE in *.$inFileExt; do
  inFile[$i]="$_FILE"
  #echo "DEBUG: inFile=${_FILE}"
  artist=$(ffprobe "$_FILE" 2>&1 |grep -E '^ +[Aa]rtist' | awk -F': ' '{ print $2 }')
  #echo "DEBUG: Artist: '$artist'"
  album=$(ffprobe "$_FILE" 2>&1 |grep -E '^ +[Aa]lbum' | awk -F': ' '{ print $2 }')
  #echo "DEBUG: Album: '$album'"
  title=$(ffprobe "$_FILE" 2>&1 |grep -E '^ +[Tt]itle' | awk -F': ' '{ print $2 }')
  #echo "DEBUG: Title: '$title'"
  #track=$(ffprobe "$_FILE" 2>&1 |grep '[Tt]rack' | awk -F': ' '{ print $2 }')
  track=$(ffprobe "$_FILE" 2>&1 | sed -rn 's/.*track +: ([0-9]+).*/\1/p')
  track=$(printf '%02d' "$track")
  #echo "DEBUG: Track: '$track'"
  tmpOut="($artist) - $album - $track $title.mp3"
  tmpFlac="($artist) - $album - $track $title.flac"
  ## Specify where and what output file.
  outFile[$i]="./$album/mp3/$tmpOut"
  flacOut[$i]="./$album/flac/$tmpFlac"
  #echo "DEBUG: outFile=${outFile[$i]}"
  #echo "DEBUG: flacOut=${outFile[$i]}"
  ((i++))
done 

if [[ ! -d "./$album" ]]; then
  mkdir -p "./$album/mp3"
  mkdir -p "./$album/flac"
fi

i=0
while [[ $i -lt ${#inFile[*]} ]]; do
  #echo -e "DEBUG:\n  inFile: \"${inFile[$i]}\"\n  outFile: \"${flacOut[$i]}\""
  cp "${inFile[$i]}" "${flacOut[$i]}"
  ((i++))
done

if [[ ${inFile[0]} == "*.$inFileExt" ]]; then
  echo -e "\nERROR: No .$inFileExt files found here, bailing."
  exit 2
fi

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
