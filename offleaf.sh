#!/bin/bash

# Written by Malcolm A. MacIver with assistance from German Espinosa
# Northwestern University
# https://robotics.northwestern.edu/

FSWATCH_OUTPUT_FILE_OVERLEAF=$(mktemp /tmp/offline_leaf.XXXXXXXX)
last_successful_pull=$(mktemp /tmp/last_successful_pull.XXXXXXXX)

# Read in some common functions between
# offleaf.sh and figleaf.sh
# Get the directory of the current script, resolving symlinks
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# Source the common function file from the same directory
source "${SCRIPT_DIR}/leaf_common.sh"

# Check if an argument was provided
if [ "$#" -ne 1 ]; then
    echo "offleaf.sh needs path and name (offleaf_config.sh) of configuration file. Usage: $0 <path_to_env_variables_file>"
    exit 1
fi

# Source the provided environment variables file
if [ ! -f "$1" ]; then
  echo "File \"$1\" not found."
  exit 1
fi

source "$1"

function terminate_script {
    echo
    echo "Terminating background git pull process with PID: $GIT_PULL_PID"
    kill $GIT_PULL_PID
    rm "$FSWATCH_OUTPUT_FILE_OVERLEAF"
    rm "$last_successful_pull"
    exit
}

function git_pull_background {
    while true; do
        output=$(git -C "$GIT_PATH" pull --no-edit 2>&1) # Redirect stderr to stdout to capture all output
        if [[ $output == *"Already up to date."* ]]; then
            echo "Your repository is synchronized with Overleaf as of $(date +"%Y-%m-%d %H:%M:%S")."
        elif [[ "$output" == *"fatal:"* ]]; then
            # This checks for any message starting with "fatal:" and replaces it with the custom message.
            echo "Cannot reach Overleaf."
        else
            echo "$output"
        fi

        if [[ $? -eq 0 ]]; then
            date > "$last_successful_pull"
        else
            echo "Error pulling changes from Overleaf."
            d=$(cat "$last_successful_pull")
            echo "Pull failed: last successful pull at $d"
        fi
        sleep "$GIT_PULL_INTERVAL_SECONDS"
    done
}


trap 'terminate_script' SIGINT

git_pull_background &
GIT_PULL_PID=$!

if [ ! -f "$last_successful_pull" ]; then
    echo "No pull yet" > "$last_successful_pull"
fi


# Start fswatch in the background and redirect its output to a file
# Currently, only attending to .tex files.

# Note: Linux users may need to remove the exclude below
$FSWATCH \
    --batch-marker \
    --latency 3 \
    --recursive \
    --extended \
    --exclude=".*" \
    --include="\\.tex$" \
    "$WATCH_PATH_OVERLEAF" >"$FSWATCH_OUTPUT_FILE_OVERLEAF" &


CHANGED_FILES=()
# Byte offset of the fswatch output file already consumed. We never truncate
# that file (fswatch holds it open); tracking a byte offset checked with
# "wc -c" (an O(1) fstat) keeps the per-poll cost constant as the file grows.
CONSUMED_BYTES=0
# Quiescence-based debounce: wait until the file has been unchanged for
# DEBOUNCE_SECONDS before reading, so a save reported as several batches is
# collected (and de-duplicated) in one pass rather than processed piecemeal.
LAST_TOTAL_BYTES=0
QUIET_SINCE=0

while true; do
    CURRENT_TIME=$SECONDS
    TOTAL_BYTES=$(wc -c <"$FSWATCH_OUTPUT_FILE_OVERLEAF")
    # Any new events restart the quiet timer.
    if (( TOTAL_BYTES != LAST_TOTAL_BYTES )); then
        LAST_TOTAL_BYTES=$TOTAL_BYTES
        QUIET_SINCE=$CURRENT_TIME
    fi
    # Read pending events only once they've been quiet long enough.
    if (( TOTAL_BYTES > CONSUMED_BYTES )) && (( CURRENT_TIME - QUIET_SINCE >= DEBOUNCE_SECONDS )); then

        batch_files=()
        while read -r line; do
            if [ "$line" == "NoOp" ]; then
                # Process unique files from batch_files
                #FIX
                unique_files=()
                for FILE in "${batch_files[@]}"; do
                    found=0
                    for ALREADY_ADDED in "${unique_files[@]}"; do
                        if [ "$FILE" == "$ALREADY_ADDED" ]; then
                            found=1
                        fi
                    done
                    if [ "$found" == "0" ]; then
                        unique_files+=("$FILE")
                    fi
                done
                #FIX

                for file in "${unique_files[@]}"; do
                    # Skip empties and anything already queued, so a single edit
                    # reported by fswatch as several NoOp-delimited batches isn't
                    # committed/pushed more than once.
                    [ -z "$file" ] && continue
                    already_queued=0
                    for queued in "${CHANGED_FILES[@]}"; do
                        if [ "$file" == "$queued" ]; then
                            already_queued=1
                            break
                        fi
                    done
                    if [ "$already_queued" -eq 0 ]; then
                        CHANGED_FILES+=("$file")
                    fi
                done
                # Clear the batch
                batch_files=()
            else
                # Add file to batch
                batch_files+=("$line")
            fi

        done < <(tail -c +$((CONSUMED_BYTES + 1)) "$FSWATCH_OUTPUT_FILE_OVERLEAF")
        # Advance past the bytes we just consumed; never truncate the file.
        CONSUMED_BYTES=$TOTAL_BYTES
    fi

    # Process any queued files one at a time, independent of whether new
    # fswatch events arrived this cycle, so a queue of several changed files
    # drains fully (and the idle sleep is always reached, avoiding a busy loop).
    if [ ${#CHANGED_FILES[@]} -gt 0 ]; then
        file_to_commit="${CHANGED_FILES[0]}"
        if [ -f "$file_to_commit" ]; then

            echo "Calling git_operations for:  \"$file_to_commit\""

            while :; do
                git_operations 1 "$file_to_commit"
                if [ $? -eq 0 ]; then
                    break
                fi
                sleep 60
            done

            echo "Finished calling git operations"
            # Sleep for the specified interval before the next commit
             sleep "$COMMIT_INTERVAL_SECONDS"
        fi
        # Remove the file from the queue
        CHANGED_FILES=("${CHANGED_FILES[@]:1}")
    else
        # Poll again after a pause. A longer interval means fewer CPU wakeups
        # (better battery); worst-case latency to notice a new edit is about
        # POLL_INTERVAL_SECONDS plus the debounce.
        sleep "$POLL_INTERVAL_SECONDS"
    fi
done
