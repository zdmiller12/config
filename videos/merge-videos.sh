#!/bin/bash
#
# script to combine multiple video files
#
# all files must be in same directory and should be named in such a way that 'sort'
# will properly order the files
#
# i.e. if files are 1.mp4, 2.mp4, ..., 10.mp4, 11.mp4, then the single-digit filenames
# should be updated to 01.mp4, 02.mp4, etc.
#
set -eux

INPUT_DIR="${1}"
cd "${INPUT_DIR}"

# optional argument for extension, which defaults to '.mp4'
EXTENSION="${2:-.mp4}"

# for reference, see previous approach 1
VIDEOS_FILE="${INPUT_DIR}videos.txt"
MERGED_FILE="${INPUT_DIR}/$(date '+%Y-%m-%d')_merged${EXTENSION}"

# cleanup before processing
rm -rf $VIDEOS_FILE $MERGED_FILE *.ts

# remove spaces from filenames
python3 ~/rename.py --path="${INPUT_DIR}"

touch "${VIDEOS_FILE}"
for VIDEO in $(find "${INPUT_DIR}" -type f -name "*${EXTENSION}" -not -path "*/2*_merged.*" | sort)
do
    # previous approach 1
	#echo "file '$(realpath "${VIDEO}")'" >> "${VIDEOS_FILE}"
	VIDEO_FILE=$( basename "${VIDEO}" )
	ffmpeg -y -ignore_unknown -loglevel error -fflags +discardcorrupt -i $VIDEO_FILE -c copy -bsf:v h264_mp4toannexb -f mpegts $VIDEO_FILE.ts
done

# previous approach 1
#ffmpeg -fflags +discardcorrupt -f concat -safe 0 -i "${VIDEOS_FILE}" -c copy -bsf:a aac_adtstoasc "${MERGED_FILE}"

CONCAT=$(echo $(ls *.ts) | sed -e "s/ /|/g")
ffmpeg -y -loglevel error -fflags +discardcorrupt -i "concat:$CONCAT" -c copy -bsf:a aac_adtstoasc "${MERGED_FILE}"

rm -f *.ts $VIDEOS_FILE