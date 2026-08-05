#!/bin/bash

# Path to Overleaf project repository
GIT_PATH="/Users/maciver/Library/CloudStorage/GoogleDrive-maciverlab@u.northwestern.edu/My Drive/_OVERLEAF_PROJECTS/peeking_68b9eb799a68dcb7c6433ec7/overleaf/68b9eb799a68dcb7c6433ec7/"

# Path to directory for figure file master versions, needed for figleaf.sh
WATCH_PATH_CONVERT="/Users/maciver/Library/CloudStorage/GoogleDrive-maciverlab@u.northwestern.edu/My Drive/_OVERLEAF_PROJECTS/peeking_68b9eb799a68dcb7c6433ec7/figures/watched/"



#######################################
# Edits below this point should rarely if ever be needed
#######################################

# Path to directories where the optimized vector and bitmap files are kept
COPY_PATH_bitmap="${WATCH_PATH_CONVERT}../unwatched/prepress_bitmap/"
COPY_PATH_pdf="${WATCH_PATH_CONVERT}../unwatched/prepress_pdf/"

# Path to directories where Overleaf repository keeps vector and bitmap files
COPY_PATH_bitmap_push="${GIT_PATH}figures/bitmap/"
COPY_PATH_vector_push="${GIT_PATH}figures/vector/"

# Path to temporary directory for optimized vector or converted bitmap files from figleaf.sh
TEMP_PATH="/tmp/"  # Temporary directory to store converted files

COMMIT_INTERVAL_SECONDS=3 # Minimum gap between commits
GIT_PULL_INTERVAL_SECONDS=90 # Interval to perform git pull in background (offleaf.sh); higher = fewer network wakeups
DEBOUNCE_SECONDS=5 # After an fswatch event is detected, wait this long before detecting another
POLL_INTERVAL_SECONDS=3 # How often the main loop wakes to check for changes when idle; higher = better battery

# Set to 1 for verbose diagnostic output from offleaf.sh/figleaf.sh, 0 to silence
DEBUG=0

# Locations of fswatch and convert
FSWATCH="/opt/homebrew/bin/fswatch"
CONVERT="/opt/homebrew/bin/magick"

WATCH_PATH_OVERLEAF="$GIT_PATH"
OVERLEAF_ID=$(basename "$GIT_PATH")

# Bold red for select outputs
RED="\033[1;31m"
RESET="\033[0m"
