#!/bin/bash

# Written by Malcolm A. MacIver with assistance from German Espinosa
# Northwestern University
# https://robotics.northwestern.edu/

# Scratch files live under ~/.config/leafsync/run, NOT under /tmp. macOS runs
# /usr/libexec/tmp_cleaner from launchd nightly, deleting anything in /tmp whose
# atime, mtime AND ctime are all more than three days old. These files are only
# touched when a watched file changes, so a quiet stretch of a few days was
# enough for the cleaner to delete them out from under a running offleaf.
RUN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/leafsync/run"
mkdir -p "$RUN_DIR"
FSWATCH_OUTPUT_FILE_OVERLEAF=$(mktemp "$RUN_DIR/offline_leaf.XXXXXXXX")
last_successful_pull=$(mktemp "$RUN_DIR/last_successful_pull.XXXXXXXX")

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

# Stop the watcher we started. fswatch can sit blocked in the FSEvents run loop
# and ignore SIGTERM, so escalate to SIGKILL rather than let "wait" hang the
# caller forever; a plain kill+wait would turn Ctrl-C into a hang.
stop_fswatch() {
    [ -n "$FSWATCH_PID" ] || return 0
    kill "$FSWATCH_PID" 2>/dev/null
    for _ in 1 2 3; do
        kill -0 "$FSWATCH_PID" 2>/dev/null || break
        sleep 1
    done
    kill -0 "$FSWATCH_PID" 2>/dev/null && kill -9 "$FSWATCH_PID" 2>/dev/null
    wait "$FSWATCH_PID" 2>/dev/null
    FSWATCH_PID=""
}

function terminate_script {
    echo
    echo "Terminating background git pull process with PID: $GIT_PULL_PID"
    kill $GIT_PULL_PID
    # Kill the watcher too. Without this, every exit leaves an fswatch behind --
    # reparented to launchd, still recursively watching the repo and appending
    # to a scratch file nothing will ever read.
    stop_fswatch
    rm -f "$FSWATCH_OUTPUT_FILE_OVERLEAF"
    rm -f "$last_successful_pull"
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

# Reconcile edits made while offleaf was NOT running. fswatch only reports
# changes that occur after it starts, so on launch we commit/push any already
# modified or newly added .tex/.bib files that differ from the repo's HEAD.
function reconcile_startup {
    local relpath abs found=0
    echo "Checking for changes made while offleaf was not running..."
    # Pull first so any local commits build on the latest remote, and REPORT
    # what it brought down -- a common reason to start offleaf is to pick up
    # edits made in the Overleaf web editor, and those should be visible.
    local pull_out
    pull_out=$(git -C "$GIT_PATH" pull --no-edit 2>&1)
    if [[ "$pull_out" == *"Already up to date."* ]]; then
        echo "Local repository is already up to date with Overleaf."
    elif [[ "$pull_out" == *"fatal:"* || "$pull_out" == *"error:"* || "$pull_out" == *"CONFLICT"* ]]; then
        echo "Could not cleanly pull from Overleaf at startup (will retry in the background):"
        echo "$pull_out"
    else
        echo -e "${RED}Pulled updates from Overleaf into your local files:${RESET}"
        echo "$pull_out"
    fi
    # Modified-vs-HEAD tracked files plus untracked files; filtered to .tex/.bib.
    while IFS= read -r relpath; do
        [ -z "$relpath" ] && continue
        case "$relpath" in
            *.tex|*.bib) ;;
            *) continue ;;
        esac
        abs="${GIT_PATH}${relpath}"
        [ -f "$abs" ] || continue   # skip deletions; those are handled manually
        echo "Reconciling pre-existing change: $relpath"
        git_operations 1 "$abs"
        found=1
    done < <(
        {
            git -C "$GIT_PATH" -c core.quotepath=false diff --name-only HEAD 2>/dev/null
            git -C "$GIT_PATH" -c core.quotepath=false ls-files --others --exclude-standard 2>/dev/null
        } | sort -u
    )
    [ "$found" -eq 0 ] && echo "No local .tex/.bib changes to reconcile (any Overleaf-side edits were pulled above)."
}


# SIGHUP matters as much as SIGINT: closing the terminal window sends HUP, whose
# default action kills bash without running a SIGINT-only trap -- which is how
# stray fswatch processes were being orphaned.
trap 'terminate_script' SIGINT SIGTERM SIGHUP

if [ ! -f "$last_successful_pull" ]; then
    echo "No pull yet" > "$last_successful_pull"
fi

# Commit/push anything changed while offleaf was off, before starting the watcher.
reconcile_startup

git_pull_background &
GIT_PULL_PID=$!


# Start fswatch in the background and redirect its output to a file.
# Attending to .tex and .bib files.

# Note: Linux users may need to remove the exclude below
# Wrapped in a function so the main loop can restart the watcher if its output
# file goes missing; FSWATCH_PID lets terminate_script clean the child up.
start_fswatch() {
    $FSWATCH \
        --batch-marker \
        --latency 3 \
        --recursive \
        --extended \
        --exclude=".*" \
        --include="\\.tex$" \
        --include="\\.bib$" \
        "$WATCH_PATH_OVERLEAF" >"$FSWATCH_OUTPUT_FILE_OVERLEAF" &
    FSWATCH_PID=$!
}
start_fswatch


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
    # If the event file disappears, fswatch keeps writing to the now-unlinked
    # inode and this loop would never see another event -- alive, quiet, and
    # permanently deaf. Rebuild both instead.
    if [ ! -f "$FSWATCH_OUTPUT_FILE_OVERLEAF" ]; then
        echo "Event file $FSWATCH_OUTPUT_FILE_OVERLEAF disappeared; restarting the watcher."
        stop_fswatch
        mkdir -p "$RUN_DIR"
        : >"$FSWATCH_OUTPUT_FILE_OVERLEAF"
        CONSUMED_BYTES=0
        LAST_TOTAL_BYTES=0
        QUIET_SINCE=$SECONDS
        start_fswatch
    fi
    [ -f "$last_successful_pull" ] || echo "No pull yet" >"$last_successful_pull"
    CURRENT_TIME=$SECONDS
    # Default to 0: a failed read leaves TOTAL_BYTES empty, which bash treats as
    # 0 inside (( )) -- silently wedging the comparisons below rather than erroring.
    TOTAL_BYTES=$(wc -c <"$FSWATCH_OUTPUT_FILE_OVERLEAF" 2>/dev/null)
    TOTAL_BYTES=${TOTAL_BYTES:-0}
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
