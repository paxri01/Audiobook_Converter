#!/bin/bash
#
inFile=$1
bookInfo='/tmp/book.info'

fullTitle=$(grep -m1 '<title>' "$inFile")
grep 'ReleaseDate' "$inFile" | hxnormalize | sed '/^$/d' | sed '/href=/d' > "$bookInfo"

# Series
SeriesName=$(sed -rn 's/.*: (.[^,]*), Book.*/\1/p' <<< "$fullTitle")
SeriesNum=$(printf "%02d" "$(sed -rn 's/.*Book ([0-9]+).*/\1/p' <<< "$fullTitle")")
Series="$SeriesNum $SeriesName"

Title=$(grep -m1 '<title>' <<< "$fullTitle" | sed -rn 's/.*Amazon.com: (.[^,]*): .*Book.*/\1/p')
Author=$(grep -A2 Author "$bookInfo" | tail -1 | sed -rn 's/.*>(.*)<.*/\1/p')
Narrator=$(grep -A2 Narrator "$bookInfo" | tail -1 | sed -rn 's/.*>(.*)<.*/\1/p')
Publisher=$(grep -A2 Publisher "$bookInfo" | tail -1 | sed -rn 's/.*>(.*)<.*/\1/p')
Length=$(grep -A3 ListeningLength "$bookInfo" | tail -1 | sed -rn 's/.*<span>(.*)<\/span>/\1/p')
Date=$(grep -A3 ReleaseDate "$bookInfo" | tail -1 | sed -rn 's/.*<span>(.*)<\/span>/\1/p')
ASIN=$(grep -A1 ASIN "$bookInfo" | tail -1 | sed -rn 's/.*<span>(.*)<\/span>/\1/p')
Rating=$(grep 'averageStarRating' "$inFile"| sed -rn 's/.*icon-alt">(.*)<\/span><\/i><\/div>.*/\1/p')
Image=$(grep 'data-ssf-share-icon' "$inFile" | sed -rn 's/.*(https:\/\/m\.media.*\.jpg).*/\1/p')
Summary=$(sed -n '/book_description_expander/, /a-expander-header/p' /tmp/book.html |\
  hxnormalize | sed -n '/<p><span/, /<\/span>/p' | sed -n '/<p>/, /<\/div>/p' |\
  sed 's/<.*>//g; s/<span//g; s/<\/span//; s/>//g; s/  //g' | tr '\n' ' ' | fold -s )

cat << EOF
   Book Title: $Title
       Series: $Series
       Author: $Author
     Narrator: $Narrator
    Publisher: $Publisher
       Length: $Length
         Date: $Date
         ASIN: $ASIN
       Rating: $Rating
    Image URL: $Image

Summary:
$Summary
EOF

