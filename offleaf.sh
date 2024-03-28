#!/bin/bash

# Written by Malcolm A. MacIver with assistance from German Espinosa
# Northwestern University
# https://robotics.northwestern.edu/


# Check if an argument was provided
if [ "$#" -ne 1 ]; then
    echo "offline_leaf needs the name of your environment variable file. Usage: $0 <path_to_env_variables_file>"
    exit 1
fi

# Source the provided environment variables file
source "$1"

RED="\033[1;31m"
RESET="\033[0m"

function terminate_script {
    echo
    echo "Terminating background git pull process with PID: $GIT_PULL_PID"
    kill $GIT_PULL_PID
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
            date > .last_successful_pull
        else
            echo "Error pulling changes from Overleaf."
            d=$(cat .last_successful_pull)
            echo "Pull failed: last successful pull at $d"
        fi
        sleep "$GIT_PULL_INTERVAL_SECONDS"
    done
}

function relative_path() {
    prefix="$1"
    string="$2"
    echo ${string#"$prefix"}
}


trap 'terminate_script' SIGINT

git_pull_background &
GIT_PULL_PID=$!

if [ ! -f ".last_successful_pull" ]; then
    echo "No pull yet" >.last_successful_pull
fi

function git_operations {
    REPOSITORY_URL=$(git -C "$GIT_PATH" remote get-url "origin")
    git ls-remote $REPOSITORY_URL &> /dev/null

    if [ $? -eq 0 ]; then
        echo "Repository is accessible."
    else
        return 1
    fi

    git -C "$GIT_PATH" pull --no-edit
    result=$?
    if [[ $result -eq 1 ]]; then
        echo "Error pulling changes from the repository."
        d=$(cat .last_successful_pull)
        echo "Pull failed: last successful pull at $d"
    else
        date >.last_successful_pull
    fi

    rel_file=$(relative_path "$GIT_PATH" "$1")

    git -C "$GIT_PATH" add "$rel_file"
    if [[ $? -ne 0 ]]; then
        echo "Error adding file $1 to the repository."
    fi

    git -C "$GIT_PATH" commit -m "[Auto] Update $rel_file"
    result=$?
    if [[ $result -ne 0 && $result -ne 1 ]]; then
        echo "$result Error committing file $1 to the repository."
    fi

    git -C "$GIT_PATH" gc # Detheridge @Overleaf to fix hanging push
    git -C "$GIT_PATH" push
    if [[ $? -ne 0 ]]; then
        echo "Error pushing changes to the repository. Will apply stash"
        git -C "$GIT_PATH" stash
        git -C "$GIT_PATH" pull
        if [[ $? -eq 0 ]]; then
            date >.last_succesful_pull
        fi
        git -C "$GIT_PATH" stash apply 0
        git -C "$GIT_PATH" add "$rel_file"
        git -C "$GIT_PATH" commit -m "[Auto] Update $rel_file"
        git -C "$GIT_PATH" push
        echo " "
        echo " "
        echo "${RED}Check $rel_file for merge conflict text. The format is as follows: "
        echo " "
        echo "<<<<<<< HEAD"
        echo "[Your local version of the conflicted content]"
        echo "======="
        echo "[The conflicting content from the branch you're merging or pulling from]"
        echo ">>>>>>> [commit hash of the incoming changes]"
        echo " "
        echo "Manually resolve to the preferred edit.${RESET}"
        echo " "
        echo " "
    fi
    return 0
}

# Start fswatch in the background and redirect its output to a file
# Currently, only attending to .tex files. 

$FSWATCH --batch-marker --recursive --extended \
    --include="\\.tex$" \
    "$WATCH_PATH_OVERLEAF" >"$FSWATCH_OUTPUT_FILE_OVERLEAF" &


LAST_PROCESSED_TIME=0
CHANGED_FILES=()

while true; do
    CURRENT_TIME=$(date +%s)
    if [ -s "$FSWATCH_OUTPUT_FILE_OVERLEAF" ] && [ $(($CURRENT_TIME - $LAST_PROCESSED_TIME)) -ge "$DEBOUNCE_SECONDS" ]; then

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
                    CHANGED_FILES+=("$file")
                done
                # Clear the batch
                batch_files=()
            else
                # Add file to batch
                batch_files+=("$line")
            fi

        done <"$FSWATCH_OUTPUT_FILE_OVERLEAF"
        echo "" >"$FSWATCH_OUTPUT_FILE_OVERLEAF" # Clear the fswatch output file

        LAST_PROCESSED_TIME=$CURRENT_TIME

        # Process the files in the queue one by one
        if [ ${#CHANGED_FILES[@]} -gt 0 ]; then
            file_to_commit="${CHANGED_FILES[0]}"
            if [ -f "$file_to_commit" ]; then

                echo "Calling git_operations for:  \"$file_to_commit\""

                while :; do
                    git_operations "$file_to_commit"
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
            # Sleep for a short period before checking for changes again
            sleep 1 
        fi
    fi
done
