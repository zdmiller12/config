# Videos

> Currently just tooling for merging videos...

## TODO

- [ ] add content about installing / using
- [ ] make script format-specific, like example for merging MKV below

## Merging MKV Example

```sh
#!/bin/bash

# Advanced script to join MKV files with options
# Usage: ./join_mkv_advanced.sh [output_filename] [track_options]

OUTPUT_FILE="${1:-Over the Garden Wall (2014) - Complete Season 1.mkv}"

# Create a file list for mkvmerge
echo "Creating file list..."
ls -1 "Over the Garden Wall (2014) - S01E"*.mkv | sort > episode_list.txt

# Method 1: Using file list (simple concatenation)
echo "Joining files using file list method..."
mkvmerge -o "$OUTPUT_FILE" @episode_list.txt

echo "Done! Output file: $OUTPUT_FILE"
echo "File size:"
ls -lh "$OUTPUT_FILE" | awk '{print $5}'

# Clean up
rm episode_list.txt
```
