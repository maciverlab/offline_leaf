#!/bin/bash


GIT_PATH="/Users/maciver/Downloads/6604ab05a1dfc483ce5bbb9c/"


WATCH_PATH_OVERLEAF="$GIT_PATH"
WATCH_PATH_CONVERT="/Users/maciver/Library/CloudStorage/GoogleDrive-maciverlab@u.northwestern.edu/My Drive/habmeth_temp_test/figures/watched/"


#######
# No edits below this point should be needed
#######################################

COMMIT_INTERVAL_SECONDS=15 # Minimum gap between commits
GIT_PULL_INTERVAL_SECONDS=20 # Interval to perform git pull in background
DEBOUNCE_SECONDS=15 # After an fswatch event is detected, wait this long before detecting another


# Locations of fswatch and convert
FSWATCH="/opt/homebrew/bin/fswatch"
CONVERT="/opt/homebrew/bin/convert"

COPY_PATH_bitmap="${WATCH_PATH_CONVERT}../ignored_by_fswatch/prepress_bitmap/"
COPY_PATH_vector="${WATCH_PATH_CONVERT}../ignored_by_fswatch/prepress_vector/"
COPY_PATH_bitmap_push="${GIT_PATH}figures/bitmap/"
COPY_PATH_vector_push="${GIT_PATH}figures/vector/"
