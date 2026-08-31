#!/bin/bash

# Written by Malcolm A. MacIver with assistance from German Espinosa
# Northwestern University
# https://robotics.northwestern.edu/

# Call with path to environment variable file leaf_common.sh.
# Optionally: call with -push, which will push the detected figure
# file changes to the Overleaf repository

FSWATCH_OUTPUT_FILE_FIGLEAF=$(mktemp /tmp/offline_leaf.XXXXXXXX)
last_successful_pull=$(mktemp /tmp/last_successful_pull.XXXXXXXX)
# HASH_DIR (the persistent, per-project content-hash store) is set below,
# after the config file is sourced, since it is keyed by OVERLEAF_ID.

# DEBUG is set in the config file (offleaf_config.sh); default off if unset
# Check if at least one argument was provided
if [ "$#" -lt 1 ]; then
    echo "figleaf.sh needs path and name (offleaf_config.sh) of configuration file. Usage: $0 <path_to_env_variables_file> [-push]"
    exit 1
fi

# Ensure the first argument is a valid file reference
if [ ! -f "$1" ]; then
    echo "File \"$1\" not found."
    exit 1
fi

# If a second argument is provided, check if it's "-push"
if [ "$#" -gt 1 ] && [ "$2" != "-push" ]; then
    echo "Invalid second argument. Only '-push' is accepted as the optional second argument."
    exit 1
fi

source "$1"

# Read in some common functions between
# offleaf.sh and figleaf.sh
# Get the directory of the current script, resolving symlinks
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# Source the common function file from the same directory
source "${SCRIPT_DIR}/leaf_common.sh"

# Persistent, per-project store of the last-processed content hash of each
# figure master, keyed by OVERLEAF_ID so projects don't collide. Persisting it
# across runs is what lets reconcile_startup (below) tell which masters changed
# while figleaf was not running, and keeps duplicate/delayed events de-duped.
HASH_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/leafsync/hashes/${OVERLEAF_ID:-default}"
mkdir -p "$HASH_DIR"

function terminate_script {
    echo
    echo "Terminating figleaf; clearing temp files."
    rm "$FSWATCH_OUTPUT_FILE_FIGLEAF"
    rm "$last_successful_pull"
    exit
}

trap terminate_script SIGINT


shorten_path() {
    echo "$1" | awk -F'/' '{if(NF>2) print $(NF-2)"/"$(NF-1)"/"$NF; else print $0}'
}

# True (0) if the figure's content matches what we last processed -- i.e. this
# is a duplicate/stale fswatch event (common on cloud-synced folders such as
# Google Drive) and should be ignored. Read-only; checked when queueing so the
# queue (and the "N more queued" count) only ever reflects real work.
content_unchanged() {
    local f="$1" key stored
    key=$(printf '%s' "$f" | shasum | awk '{print $1}')
    [ -f "$HASH_DIR/$key" ] || return 1
    stored=$(cat "$HASH_DIR/$key")
    [ "$(shasum "$f" | awk '{print $1}')" = "$stored" ]
}

# Record the content hash of a figure we just processed, so subsequent
# duplicate events for the same content are ignored by content_unchanged.
# Recorded at process time (not queue time) so a rapid re-edit during the
# queue->process window doesn't leave a stale hash.
record_processed_hash() {
    local f="$1" key
    key=$(printf '%s' "$f" | shasum | awk '{print $1}')
    shasum "$f" | awk '{print $1}' >"$HASH_DIR/$key"
}

squeeze() {
    local overwrite=false

    # Check if the first argument is -o for overwriting
    if [[ "$1" == "-o" ]]; then
        overwrite=true
        shift # Shift arguments to remove the -o option
    fi

    for input_file in "$@"; do
        # Check if the file has a .pdf extension
        if [[ "${input_file##*.}" == "pdf" ]]; then
            base_name="${input_file%.*}"
        else
            base_name="$input_file"
            input_file="${input_file}.pdf"
        fi

        # Check if the file exists
        if [[ ! -f "$input_file" ]]; then
            echo "File not found: $input_file"
            continue
        fi

        # Check if the file is a PDF
        if [[ "${input_file##*.}" != "pdf" ]]; then
            echo "Not a pdf: aborting"
            continue
        fi

        # Determine the output file name
        local output_file
        if [[ "$overwrite" == true ]]; then
            output_file="${base_name}_temp.pdf"
        else
            output_file="${base_name}_sq.pdf"
        fi

        gs \
        -sDEVICE=pdfwrite \
        -q \
        -dBATCH \
        -dNOPAUSE \
        -dSAFER \
        -dPDFSETTINGS=/prepress \
        -dImageResolution=300 \
        -sOutputFile="$output_file" \
        -c '<</NeverEmbed []>> setdistillerparams' \
        -f "$input_file" \
        -c quit

        # If overwriting, move the temporary file to the original file
        if [[ "$overwrite" == true ]]; then
            mv "$output_file" "$input_file"
            short_path1=$(shorten_path "$input_file")
        fi
    done
}

if [ ! -f "$last_successful_pull" ]; then
    echo "No pull yet" >"$last_successful_pull"
fi

# Currently only scanning for updates to Illustrator files
# but excluding the temp files Illustrator creates
$FSWATCH \
    --recursive \
    --batch-marker \
    --latency 3 \
    --extended \
    --exclude=".*" \
    --include="\\.ai$" \
    --include="\\.pdf$" \
    --exclude="ai[0-9]+.*\\.ai$" \
    --exclude="ai[0-9]+.*\\.pdf$" \
    "$WATCH_PATH_CONVERT" >"$FSWATCH_OUTPUT_FILE_FIGLEAF" &

echo "Waiting for the next detected figure file change."


CHANGED_FILES=()
# Byte offset of the fswatch output file already consumed. We never truncate
# that file: fswatch holds it open and would keep writing at its previous
# offset, leaving a null-byte "hole" that corrupts later events. Instead we
# track how many bytes we've read and only process newly appended bytes.
# Using a byte offset checked with "wc -c" (an O(1) fstat) rather than "wc -l"
# keeps the per-poll cost constant even though the file grows over a session.
CONSUMED_BYTES=0
# Quiescence-based debounce. fswatch reports one save as a burst of events,
# often split across several NoOp-delimited batches and spread over a few
# seconds. We wait until the file has been unchanged for DEBOUNCE_SECONDS
# before reading, so the whole save is collected (and de-duplicated) in a
# single pass instead of processing the first batch while more still arrive.
LAST_TOTAL_BYTES=0
QUIET_SINCE=0

# Catch up on masters edited while figleaf was NOT running. fswatch only
# reports events that occur after it starts, so on launch we scan the watched
# tree and queue any master whose content differs from the last time it was
# processed (persistent hashes in HASH_DIR). On the very first run the store is
# empty, so every master is queued -- a full initial sync.
reconcile_startup() {
    local f base n=0
    echo "Checking for figure masters changed while figleaf was not running..."
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        case "$base" in ai[0-9]*) continue ;; esac   # skip Illustrator temp files
        content_unchanged "$f" && continue
        CHANGED_FILES+=("$f")
        n=$((n + 1))
    done < <(find "$WATCH_PATH_CONVERT" -type f \( -name '*.ai' -o -name '*.pdf' \) 2>/dev/null)
    if [ "$n" -gt 0 ]; then
        echo "Queued $n figure master(s) to process on startup."
    else
        echo "No figure masters need reconciling."
    fi
}
reconcile_startup

while true; do
    CURRENT_TIME=$SECONDS
    TOTAL_BYTES=$(wc -c <"$FSWATCH_OUTPUT_FILE_FIGLEAF")
    # Any new events restart the quiet timer.
    if (( TOTAL_BYTES != LAST_TOTAL_BYTES )); then
        LAST_TOTAL_BYTES=$TOTAL_BYTES
        QUIET_SINCE=$CURRENT_TIME
    fi
    # Read pending events only once they've been quiet long enough.
    if (( TOTAL_BYTES > CONSUMED_BYTES )) && (( CURRENT_TIME - QUIET_SINCE >= DEBOUNCE_SECONDS )); then
        if [ "$DEBUG" -eq 1 ]; then
            echo "fswatch output file: $FSWATCH_OUTPUT_FILE_FIGLEAF"
        fi
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
                    # Only queue real work. Skip: empty lines; vanished/transient
                    # paths; duplicate/stale events whose content we've already
                    # processed (dedups Google Drive's delayed FSEvents); and
                    # anything already in the queue (fswatch reports one save as
                    # several NoOp-delimited batches). This keeps the queue and
                    # its "N more queued" count honest.
                    [ -z "$file" ] && continue
                    [ -f "$file" ] || continue
                    content_unchanged "$file" && continue
                    already_queued=0
                    for queued in "${CHANGED_FILES[@]}"; do
                        if [ "$file" == "$queued" ]; then
                            already_queued=1
                            break
                        fi
                    done
                    [ "$already_queued" -eq 1 ] && continue
                    CHANGED_FILES+=("$file")
                done
              if [ "$DEBUG" -eq 1 ]; then
                echo "Current value of CHANGED_FILES"
                printf '%s\n' "${CHANGED_FILES[@]}"
              fi
                # Clear the batch
                batch_files=()
            else
                # Add file to batch
                batch_files+=("$line")
            fi

        done < <(tail -c +$((CONSUMED_BYTES + 1)) "$FSWATCH_OUTPUT_FILE_FIGLEAF")
        # Advance past the bytes we just consumed; never truncate the file.
        CONSUMED_BYTES=$TOTAL_BYTES
    fi

    # Process any queued files one at a time, independent of whether new
    # fswatch events arrived this cycle, so a queue of several changed files
    # drains fully (and the idle sleep is always reached, avoiding a busy loop).
    if [ ${#CHANGED_FILES[@]} -gt 0 ]; then
        file_to_process="${CHANGED_FILES[0]}"
        if [ -f "$file_to_process" ]; then
            file="$file_to_process"

            # Get the filename without extension
            short_path1=$(shorten_path "$file_to_process")
            echo
            echo
            echo "----------------------------------------------------------------------------"
            echo "Detected change in ""$short_path1"": Begin processing..."
            filename=$(basename -- "$file_to_process")
            filename="${filename%.*}"
            # Tracks whether every push for this figure actually landed. The
            # content hash is recorded only if it did: marking a figure as
            # processed after a failed push would mean it is never retried,
            # and Overleaf would silently keep the stale version.
            push_ok=1
            # Copy the .ai file to VECTOR_UPLOAD with a .pdf extension
            cp "$file" "$COPY_PATH_pdf$filename.pdf"
            short_path2=$(shorten_path "$COPY_PATH_pdf$filename.pdf")

            # Convert the .pdf file in the VECTOR_UPLOAD directory to an optimized PDF
            squeeze -o "$COPY_PATH_pdf$filename.pdf"

            if [[ "$2" == "-push" ]]; then
                cp "$COPY_PATH_pdf$filename.pdf" "$COPY_PATH_vector_push$filename.pdf"
                short_path3=$(shorten_path "$COPY_PATH_vector_push$filename.pdf")
                echo "$short_path2 copied to local Overleaf repo directory $short_path3 to push to cloud."
                git_operations 0 "$COPY_PATH_vector_push$filename.pdf"
                if [ $? -ne 0 ]; then
                    push_ok=0
                    echo
                    echo -e "${RED}Push of $filename.pdf to $OVERLEAF_ID did NOT complete.${RESET}"
                    echo
                else
                    echo "Committing file: $COPY_PATH_vector_push$filename.pdf"
                    echo
                    echo -e "${RED}Commit of $filename.pdf to $OVERLEAF_ID completed on $(now_stamp).${RESET}"
                    echo
                fi
            fi

            # Generate bitmap file
            outputfile="${TEMP_PATH}${filename}.jpg"
            # Convert the optimized PDF to a jpg file
            #

            $CONVERT -density 220 "$COPY_PATH_pdf$filename.pdf" -alpha remove -quality 100 "${outputfile}"

            # Move the jpg file to COPY_PATH_bitmap
            #
            mv "$TEMP_PATH$filename.jpg" "$COPY_PATH_bitmap$filename.jpg"

            if [[ "$2" == "-push" ]]; then
                # Small buffer between the two pushes. git_operations is
                # synchronous (the PDF push has already finished here), so this
                # is just a brief spacer between successive pushes to Overleaf.
                sleep 2
                cp "$COPY_PATH_bitmap$filename.jpg" "$COPY_PATH_bitmap_push$filename.jpg"
                short_path5=$(shorten_path "$COPY_PATH_bitmap$filename.jpg")
                short_path6=$(shorten_path "$COPY_PATH_bitmap_push$filename.jpg")
                echo "$short_path5 copied to $short_path6 for push to Overleaf"
                echo "Committing file: $COPY_PATH_bitmap_push$filename.jpg"
                git_operations 0 "$COPY_PATH_bitmap_push$filename.jpg"
                if [ $? -ne 0 ]; then
                    push_ok=0
                    echo
                    echo -e "${RED}Push of $filename.jpg to $OVERLEAF_ID did NOT complete.${RESET}"
                else
                    echo
                    echo -e "${RED}Commit of $filename.jpg to $OVERLEAF_ID completed on $(now_stamp).${RESET}"
                fi
            fi
            echo
            echo
            echo "----------------------------------------------------------------------------"
            # Record what we just processed so later duplicate events for the
            # same content are skipped at queue time -- but only if the pushes
            # succeeded. Recording a figure whose push failed would mark it done
            # for good, so it would never be retried and Overleaf would keep the
            # stale version with no further warning.
            if [ "$push_ok" -eq 1 ]; then
                record_processed_hash "$file_to_process"
            else
                echo -e "${RED}Not marking $filename as processed; it will be"
                echo -e "reprocessed on the next change, or on the next run.${RESET}"
            fi
        fi
        # Remove the just-processed file from the queue
        CHANGED_FILES=("${CHANGED_FILES[@]:1}")
        # Only announce "waiting" once the queue is actually empty; otherwise
        # report how many edits are still pending so the message isn't deceptive.
        if [ ${#CHANGED_FILES[@]} -gt 0 ]; then
            echo "${#CHANGED_FILES[@]} more queued figure change(s) to process..."
        else
            echo "Waiting for the next detected figure file change."
        fi
        echo
        # Sleep for the specified interval before the next commit
        sleep "$COMMIT_INTERVAL_SECONDS"
    else
        # Poll again after a pause. A longer interval means fewer CPU wakeups
        # (better battery); worst-case latency to notice a new edit is about
        # POLL_INTERVAL_SECONDS plus the debounce.
        sleep "$POLL_INTERVAL_SECONDS"
    fi
done
