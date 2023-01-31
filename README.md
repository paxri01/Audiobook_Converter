# Audiobook Converter

### DESCRIPTION

Linux shell script to combine/reformat various audiobooks files into a single
.mp3 with tags and info.

### PURPOSE

This script is used to reformat multiple audio files (.mp3, .m4a, .m4b) into a
single .mp3 file that includes the book cover, IDv3 tags and book description
from goodreads.com site.

### USAGE

```bash
ccab.sh [-c ||--concat] [-m ||--move] [-mo] [-mp3] [-m4b] [-r] [-v]

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
   -x || --remove    : Remove source files after conversion (DANGEROUS!).
```

### REQUIREMENTS

The following packages are require to use this script.

* ffmpeg & ffprobe  <https://ffmpeg.org/>
* mid3v2            <http://mutagen.readthedocs.io/en/latest/man/mid3v2.html>
* fancy_audio       <https://rubygems.org/gems/fancy_audio/versions/0.0.4>
* googler           <https://github.com/jarun/googler>
* curl              *Your distro repository*
* lame              <http://lame.sourceforge.net/>

**NOTE:** You will also need to modify the user parameters to set outgoing
directories and log locations.

## CHANGES

### CHG0002 - 2023.01.31
* Rework GR parser logic to latest results.
* Auto prompt for input on key missing fields (title, author, series, etc.)
* Code cleanup.

### CHG0001 - 2018.05.15

* Cleanup file list after completion.
* Fix apostrophes in concatenated file list.
* Set permissions on output directory.
* Update README.md

### DETAILS

What you have before:

```
> ls
'Better Off Dead-Cover.jpg'   'Better Off Dead-Part03.mp3'  'Better Off Dead-Part07.mp3'
'Better Off Dead.jpg'         'Better Off Dead-Part04.mp3'  'Better Off Dead-Part08.mp3'
'Better Off Dead-Part01.mp3'  'Better Off Dead-Part05.mp3'
'Better Off Dead-Part02.mp3'  'Better Off Dead-Part06.mp3'
```

What you do:

```
> ccab -c -m 5
>>> probing Better Off Dead-Part01.mp3
  In File: Better Off Dead-Part01.mp3
  Directory: Child, Lee/26 Jack Reacher
  Found Title: Better Off Dead  A Jack Reacher Novel
  Found Author: Andrew Child
  Found Bitrate: 48
  Found Date: 

>>> Searching for: 'Better+Off+Dead++A+Jack+Reacher+Novel+Andrew+Child'

https://www.goodreads.com/search?q=Better+Off+Dead++A+Jack+Reacher+Novel+Andrew+Child
1. Summary of Better Off Dead: A Jack Reacher Novel: Lee Child and Andrew Child
   https://www.goodreads.com/book/show/59606070-summary-of-better-off-dead

2. Summary of Better Off Dead: A Jack Reacher Novel by Lee Child and Andrew Child
   https://www.goodreads.com/book/show/60107562-summary-of-better-off-dead

3. Summary Of Better Off Dead: A Jack Reacher Novel By Lee Child and Andrew Child
   https://www.goodreads.com/book/show/92159327-summary-of-better-off-dead

Choose result number for info or '0' for direct URL: s

 Enter new search criteria: Better Off Dead Lee Child

>>> Searching for: 'Better+Off+Dead+Lee+Child'

https://www.goodreads.com/search?q=Better+Off+Dead+Lee+Child
1. Summary of Jack Reacher: Better Off Dead by Lee Child and Andrew Child
   https://www.goodreads.com/book/show/59640197-summary-of-jack-reacher

2. SUMMARY Better Off Dead by Lee Child and Andrew Child: novel
   https://www.goodreads.com/book/show/59490497-summary-better-off-dead-by-lee-child-and-andrew-child

3. SUMMARY: JACK REACHER: Better Off Dead BY LEE CHILD, ANDREW CHILD
   https://www.goodreads.com/book/show/59750006-summary

4. Better Off Dead (Jack Reacher, #26)
   https://www.goodreads.com/book/show/56663329-better-off-dead

5. Summary of Better Off Dead: A Jack Reacher Novel: Lee Child and Andrew Child
   https://www.goodreads.com/book/show/59606070-summary-of-better-off-dead

6. Summary of Better Off Dead: A Jack Reacher Novel by Lee Child and Andrew Child
   https://www.goodreads.com/book/show/60107562-summary-of-better-off-dead

7. Better Off Dead: Free eBook Sampler
   https://www.goodreads.com/book/show/59384945-better-off-dead

8. Summary Of Better Off Dead: A Jack Reacher Novel By Lee Child and Andrew Child
   https://www.goodreads.com/book/show/92159327-summary-of-better-off-dead

9. Summary of Better off Dead: A Jack Reacher Novel by Lee Child
   https://www.goodreads.com/book/show/64344554-summary-of-better-off-dead

10. Summary of Better Off Dead: A Jack Reacher Novel: By Lee Child
   https://www.goodreads.com/book/show/60245303-summary-of-better-off-dead

Choose result number for info or '0' for direct URL: 4

INFO: bookURL = https://www.goodreads.com/book/show/56663329-better-off-dead

>>> Retrieving book information...
>>> Parsing information...
parse method #1
++fullSeries=Jack Reacher, #26
  bookAuthor: Lee Child
  bookTitle: Better Off Dead
  bookSeries: Jack Reacher 26
  bookYear: 2021
  bookRating: 3.84
  bookCover: https://images-na.ssl-images-amazon.com/images/S/compressed.photo.goodreads.com/books/1610609548i/56663329.jpg
  bookGenre: Fiction, Thriller, Mystery, Crime, Action, Suspense, Audiobook, Mystery Thriller, Adventure, Adult

  bookSummary: 
  Reacher never backs down from a problem. And he's about to find a big one, on a 
deserted Arizona road, where a Jeep has crashed into the only tree for miles 
around. Under the merciless desert sun, nothing is as it seems. Minutes later 
Reacher is heading into the nearby border town, a backwater that has seen 
better days. Next to him is Michaela Fenton, an army veteran turned FBI agent, 
who is trying to find her twin brother. He might have got mixed up with some 
dangerous people. And Reacher might just need to pay them a visit. Their leader 
has burrowed his influence deep into the town. Just to get in and meet the 
mysterious Dendoncker, Reacher is going to have to achieve the impossible. To 
get answers will be even harder. There are people in this hostile, empty place 
who would rather die than reveal their secrets. But then, if Reacher is coming 
after you, you might be better off dead.
Converting now
>>> Checking book catagory...
  bookCategory: Thriller 
>>> Adding /data/qBittorrent/Child, Lee/26 Jack Reacher/Better Off Dead-Part01.mp3
>>> Adding /data/qBittorrent/Child, Lee/26 Jack Reacher/Better Off Dead-Part02.mp3
>>> Adding /data/qBittorrent/Child, Lee/26 Jack Reacher/Better Off Dead-Part03.mp3
>>> Adding /data/qBittorrent/Child, Lee/26 Jack Reacher/Better Off Dead-Part04.mp3
>>> Adding /data/qBittorrent/Child, Lee/26 Jack Reacher/Better Off Dead-Part05.mp3
>>> Adding /data/qBittorrent/Child, Lee/26 Jack Reacher/Better Off Dead-Part06.mp3
>>> Adding /data/qBittorrent/Child, Lee/26 Jack Reacher/Better Off Dead-Part07.mp3
>>> Adding /data/qBittorrent/Child, Lee/26 Jack Reacher/Better Off Dead-Part08.mp3
>>> Encoding Lee Child - Jack Reacher 26 - Better Off Dead...
LAME 3.100 64bits (http://lame.sf.net)
Autoconverting from stereo to mono. Setting encoding to mono mode.
Using polyphase lowpass filter, transition band: 16538 Hz - 17071 Hz
Encoding /tmp/ccab/tmp.ykDqx/Lee Child - Jack Reacher 26 - Better Off Dead.concat.mp3
      to /tmp/ccab/tmp.ykDqx/Lee Child - Jack Reacher 26 - Better Off Dead.abr48.mp3
Encoding as 44.1 kHz single-ch MPEG-1 Layer III VBR(q=6)
    Frame          |  CPU time/estim | REAL time/estim | play/CPU |    ETA 
161700/1266413 (13%)|    1:01/    8:00|    1:01/    8:01|   68.817x|    7:00 hip: bitstream problem, resyncing skipping 3813 bytes...
308400/1266413 (24%)|    1:56/    7:59|    1:57/    8:00|   68.992x|    6:03 hip: bitstream problem, resyncing skipping 3813 bytes...
449200/1266413 (35%)|    2:50/    7:59|    2:50/    8:00|   69.017x|    5:09 hip: bitstream problem, resyncing skipping 3813 bytes...
616100/1266413 (49%)|    3:53/    7:59|    3:53/    8:00|   69.030x|    4:06 hip: bitstream problem, resyncing skipping 3813 bytes...
757700/1266413 (60%)|    4:46/    7:59|    4:47/    8:00|   68.989x|    3:13 hip: bitstream problem, resyncing skipping 3813 bytes...
925400/1266413 (73%)|    5:50/    7:59|    5:51/    8:00|   68.957x|    2:09 hip: bitstream problem, resyncing skipping 3813 bytes...
1094100/1266413 (86%)|    6:54/    7:59|    6:55/    8:01|   68.923x|    1:05 hip: bitstream problem, resyncing skipping 3813 bytes...
1266267/1266413(100%)|    7:59/    8:00|    8:01/    8:01|   68.916x|    0:00 
Writing LAME Tag...done
ReplayGain: -0.4dB
lame encoding completed
>>> Removing original ID3 tags
>>> Adding book cover image
>>> Adding ID3 tags
>>> bookType=Thriller
>>> outDir[0]=/audio/audiobooks/Thriller/Child, Lee/Jack Reacher 26 - Better Off Dead
>>> Moving encoded files to .../Child, Lee/Better Off Dead
Files moved successfully
>>> Setting file/directory permissions
>>> Updating convert log
>>> Cleaning temp files
[RC:0] Done!
```

What you get after:

```
[18:11 user@host /audio/audiobooks/Thriller/Child, Lee/Jack Reacher 26 - Better Off Dead] 
> ls -l
total 204M
-rw-rw-r--+ 1 user admins 203M Jan 31 17:22 'Lee Child - Jack Reacher 26 - Better Off Dead.abr48.mp3'
-rw-rw-r--+ 1 user admins 1.4K Jan 31 17:14 'Lee Child - Jack Reacher 26 - Better Off Dead.info'
-rw-rw-r--+ 1 user admins 1.1M Jan 31 17:14 'Lee Child - Jack Reacher 26 - Better Off Dead.jpg'
```
