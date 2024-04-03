#!/bin/bash

# Written by Malcolm A. MacIver with assistance from German Espinosa
# Northwestern University
# https://robotics.northwestern.edu/

# Call with path to environment variable file leaf_common.sh.
# Optionally: call with -push, which will push the detected figure
# file changes to the Overleaf repository

FSWATCH_OUTPUT_FILE_FIGLEAF=$(mktemp /tmp/offline_leaf.XXXXXXXX)
last_successful_pull=$(mktemp /tmp/last_successful_pull.XXXXXXXX)

# Check if at least one argument was provided
if [ "$#" -lt 1 ]; then
    echo "figleaf needs the name of your environment variable file. Usage: $0 <path_to_env_variables_file> [-push]"
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
source ./leaf_common.sh

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

        gs -sDEVICE=pdfwrite -q -dBATCH -dNOPAUSE -dSAFER -dPDFSETTINGS=/prepress -dImageResolution=300 -sOutputFile="$output_file" -c '<</NeverEmbed []>> setdistillerparams' -f "$input_file" -c quit

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
$FSWATCH --batch-marker --extended \
    --exclude=".*" \
    --include="\\.ai$" \
    --include="\\.pdf$" \
    --exclude="ai[0-9]+.*\\.ai$" \
    --exclude="ai[0-9]+.*\\.pdf$" \
    "$WATCH_PATH_CONVERT" >"$FSWATCH_OUTPUT_FILE_FIGLEAF" &

LAST_PROCESSED_TIME=0
CHANGED_FILES=()

while true; do
    CURRENT_TIME=$(date +%s)
    if [ -s "$FSWATCH_OUTPUT_FILE_FIGLEAF" ] && [ $(($CURRENT_TIME - $LAST_PROCESSED_TIME)) -ge "$DEBOUNCE_SECONDS" ]; then

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
                        echo "DEBUG UNIQUE FILE $FILE"
                    fi
                done
                #FIX

                for file in "${unique_files[@]}"; do
                    CHANGED_FILES+=("$file")
                done
                # Clear the batch
                batch_files=()
            else
                # Add file to batch
                batch_files+=("$line")
            fi

        done <"$FSWATCH_OUTPUT_FILE_FIGLEAF"
        echo "" >"$FSWATCH_OUTPUT_FILE_FIGLEAF" # Clear the fswatch output file

        LAST_PROCESSED_TIME=$CURRENT_TIME

        # Process the files in the queue one by one
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
                # Copy the .ai file to VECTOR_UPLOAD with a .pdf extension
                cp "$file" "$COPY_PATH_vector$filename.pdf"
                short_path2=$(shorten_path "$COPY_PATH_vector$filename.pdf")
                # echo "$short_path1 copied to $short_path2 for optimization"

                # Convert the .pdf file in the VECTOR_UPLOAD directory to an optimized PDF
                squeeze -o "$COPY_PATH_vector$filename.pdf"

                if [[ "$2" == "-push" ]]; then
                    cp "$COPY_PATH_vector$filename.pdf" "$COPY_PATH_vector_push$filename.pdf"
                    short_path3=$(shorten_path "$COPY_PATH_vector_push$filename.pdf")
                    echo "$short_path2 copied to $short_path3 for push to Overleaf"
                    echo "Committing file: $COPY_PATH_vector_push$filename.pdf"
                    git_operations 0 "$COPY_PATH_vector_push$filename.pdf"
                    echo "Commit of $COPY_PATH_vector_push$filename.pdf completed"
                fi

                # Generate bitmap file
                outputfile="${TEMP_PATH}${filename}.jpg"
                # Convert the optimized PDF to a jpg file
                #

                $CONVERT -density 220 "$COPY_PATH_vector$filename.pdf" -alpha remove -quality 100 "${outputfile}"

                # Move the jpg file to COPY_PATH_bitmap
                #
                mv "$TEMP_PATH$filename.jpg" "$COPY_PATH_bitmap$filename.jpg"

                if [[ "$2" == "-push" ]]; then
                    # Need a pause here since after the push conditional above for
                    # the pdf file, it will take time to commit the change and the
                    # fswatch command for sync to Overleaf will not be detecting
                    # the change during the commit
                    sleep 20
                    cp "$COPY_PATH_bitmap$filename.jpg" "$COPY_PATH_bitmap_push$filename.jpg"
                    short_path5=$(shorten_path "$COPY_PATH_bitmap$filename.jpg")
                    short_path6=$(shorten_path "$COPY_PATH_bitmap_push$filename.jpg")
                    echo "$short_path5 copied to $short_path6 for push to Overleaf"
                    echo "Committing file: $COPY_PATH_bitmap_push$filename.jpg"
                    git_operations 0 "$COPY_PATH_bitmap_push$filename.jpg"
                    echo "Commit of $COPY_PATH_bitmap_push$filename.jpg completed"
                fi
                echo "Processing completed"
                echo
                echo
                echo "----------------------------------------------------------------------------"
            fi
            # Remove the file from the queue
            CHANGED_FILES=("${CHANGED_FILES[@]:1}")
            # Sleep for the specified interval before the next commit
            sleep "$COMMIT_INTERVAL_SECONDS"
        else
            # Sleep for a short period before checking for changes again
            sleep 1
        fi
    fi
done
