# Audiobook_Converter

DESCRIPTION:  Linux shell script to combine/reformat various audiobooks files
              into a single .mp3 with tags and info.


PURPOSE:  This script is used to reformat multiple audio files (.mp3, .m4a,
          .m4b) into a single .mp3 file that includes the book cover, IDv3 
          tags and book description from Goodreads.com site.


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
   -u || --update    : Only update book information (title, info, etc.) for an
                       already converted book (eg. change series info, title).
   -v || --verify    : Will prompt for verification of detected book information.
   -x || --remove    : Remove source files after conversion (DANGEROUS!).


REQUIREMENTS:  The following packages are require to use this script.

   ffmpeg & ffprobe  : https://ffmpeg.org/
   mid3v2            : http://mutagen.readthedocs.io/en/latest/man/mid3v2.html
   fancy_audio       : https://rubygems.org/gems/fancy_audio/versions/0.0.4
   googler           : https://github.com/jarun/googler
   curl              : Your distro repository
   lame              : http://lame.sourceforge.net/


NOTE: You will also need to modify the user parameters to set outgoing directories
      and log locations.


