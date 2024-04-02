function relative_path() {
    prefix="$1"
    string="$2"
    echo ${string#"$prefix"}
}


function git_operations {
    local apply_stash=$1 # First argument is now the apply_stash flag
    shift # Shift the arguments so $1 and onwards are as before
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
        d=$(cat "$last_successful_pull")
        echo "Pull failed: last successful pull at $d"
    else
        date > "$last_successful_pull"
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

    git -C "$GIT_PATH" gc # Garbage collect to fix hanging push
    output=$(git -C "$GIT_PATH" push 2>&1)  # Redirect stderr to stdout to capture all output
    if [[ $output == *"failed to push"* && $apply_stash -eq 1 ]]; then
        echo -e "${RED}Merge conflict detected during push."
        echo -e "Will apply stash.${RESET}"
        git -C "$GIT_PATH" stash
        git -C "$GIT_PATH" pull
        if [[ $? -eq 0 ]]; then
            date > .last_succesful_pull
        fi
        git -C "$GIT_PATH" stash apply 0
        git -C "$GIT_PATH" add "$rel_file"
        git -C "$GIT_PATH" commit -m "[Auto] Update $rel_file"
        git -C "$GIT_PATH" push
        echo " "
        echo " "
        echo -e "${RED}Check $rel_file for merge conflict text. The format is as follows: "
        echo " "
        echo -e "<<<<<<< HEAD"
        echo -e "[Your local version of the conflicted content]"
        echo -e "======="
        echo -e "[The conflicting content from the branch you're merging or pulling from]"
        echo -e ">>>>>>> [commit hash of the incoming changes]"
        echo " "
        echo -e "Manually resolve to the preferred edit.${RESET}"
        echo " "
        echo " "
    elif [[ $output == *"failed to push"* && $apply_stash -eq 0 ]]; then
        echo -e "${RED}Merge conflict detected during push."
        echo -e "Conflict is not being resolved: exiting.${RESET}"
        exit
    fi
    return 0
}
