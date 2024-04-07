#!/bin/bash

# Path to Overleaf project repository
GIT_PATH="/Users/maciver/Downloads/6604ab05a1dfc483ce5bbb9c/"

# Path to directory for figure file master versions, needed for figleaf.sh
WATCH_PATH_CONVERT="/Users/maciver/Library/CloudStorage/GoogleDrive-maciverlab@u.northwestern.edu/My Drive/habmeth_temp_test/figures/watched/"

# Path to temporary directory for optimized vector or converted bitmap files from figleaf.sh
TEMP_PATH="/tmp/"  # Temporary directory to store converted files

# Path to directories where the optimized vector and bitmap files are kept
COPY_PATH_bitmap="${WATCH_PATH_CONVERT}../ignored_by_fswatch/prepress_bitmap/"
COPY_PATH_vector="${WATCH_PATH_CONVERT}../ignored_by_fswatch/prepress_vector/"

# Path to directories where Overleaf repository keeps vector and bitmap files
COPY_PATH_bitmap_push="${GIT_PATH}figures/bitmap/"
COPY_PATH_vector_push="${GIT_PATH}figures/vector/"

#######################################
# No edits below this point should be needed
#######################################

COMMIT_INTERVAL_SECONDS=15 # Minimum gap between commits
GIT_PULL_INTERVAL_SECONDS=20 # Interval to perform git pull in background
DEBOUNCE_SECONDS=15 # After an fswatch event is detected, wait this long before detecting another

# Locations of fswatch and convert
FSWATCH="/opt/homebrew/bin/fswatch"
CONVERT="/opt/homebrew/bin/convert"

WATCH_PATH_OVERLEAF="$GIT_PATH"
OVERLEAF_ID=$(basename "$GIT_PATH")

# Bold red for select outputs
RED="\033[1;31m"
RESET="\033[0m"