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
  ## Specify where and what output file.
  outFile[$i]="./mp3/${inFile[$i]%.*}.mp3"
  ((i++))
done 

if [[ ${inFile[0]} == "*.$inFileExt" ]]; then
  echo -e "\nERROR: No .$inFileExt files found here, bailing."
  exit 2
fi

## Create sub-directory for new mp3 files.
mkdir ./mp3 >/dev/null 2>&1

i=0
while [[ $i -lt ${#inFile[*]} ]]; do
  echo -e ">>> Processing file $((i + 1)) of ${#inFile[*]} <<<"
  echo -e "Re-copying ${inFile[$i]}..."
  #shellcheck disable=SC2086,SC2090
  ffmpeg -hide_banner -loglevel quiet -stats -y -i "${inFile[$i]}" -c:a copy "${outFile[$i]}"
  STATUS=$?
  echo -e "\n< inFile: ${inFile[$i]}"
  mediainfo "${inFile[$i]}" | sed -n '/^Audio/,/^Writing/p'
  echo -e "\n> outFile: ${inFile[$i]}"
  mediainfo "${outFile[$i]}" | sed -n '/^Audio/,/^Writing/p'
  if [[ $STATUS -eq 0 ]]; then
    ## Moving new file to original if no error.
    mv -f "${outFile[$i]}" "${inFile[$i]}"
  fi
  ((i++))
done

## Remove temp directory if empty.
rmdir ./mp3 >/dev/null 2>&1
