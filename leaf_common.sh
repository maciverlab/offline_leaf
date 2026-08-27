# DEBUG comes from the config file (offleaf_config.sh); default to off if not set
DEBUG=${DEBUG:-0}


function relative_path() {
    prefix="$1"
    string="$2"
    echo ${string#"$prefix"}
}


# How many times to retry a push that was rejected because the remote moved,
# and how long to wait between attempts. Overridable from offleaf_config.sh.
PUSH_MAX_ATTEMPTS=${PUSH_MAX_ATTEMPTS:-5}
PUSH_RETRY_SLEEP=${PUSH_RETRY_SLEEP:-3}

# True if the push failed only because the remote has commits we do not have
# (a non-fast-forward rejection), rather than for some other reason such as
# authentication, a network failure, or a rejecting hook. Retrying helps only
# in the first case.
function is_non_fast_forward {
    case "$1" in
        # The common case: our pull was already stale by the time we pushed.
        *"non-fast-forward"*|*"fetch first"*|*"Updates were rejected"*|*"[rejected]"*)
            return 0 ;;
        # The tighter race: the remote advanced while our push was in flight, so
        # the server could not lock the ref at the value we had. Same cause, and
        # the same fix -- pull and push again.
        *"cannot lock ref"*|*"failed to update ref"*|*"[remote rejected]"*|*"stale info"*)
            return 0 ;;
        *) return 1 ;;
    esac
}

# True if the working tree has unmerged paths -- a real conflict that a person
# has to resolve. This is the test that separates a genuine conflict from the
# routine rejection above; the old code could not tell them apart because it
# only matched the string "failed to push", which git prints for both.
function has_unmerged_paths {
    [ -n "$(git -C "$GIT_PATH" ls-files --unmerged)" ]
}

# Push, pulling and retrying when the remote moved under us.
#
# Overleaf's git bridge mints a commit every few seconds while anyone is typing
# in the web editor, so the remote routinely advances between our pull and our
# push. That is not a conflict: the files we write (figures/*, or one .tex) are
# not the ones the collaborator touched, so pulling and pushing again succeeds.
# A genuine conflict shows up in the PULL, which is where we test for it.
#
# Returns: 0 pushed; 1 genuine conflict (merge aborted, tree left clean);
#          2 gave up (retries exhausted, or a failure retrying cannot fix).
# Leaves the last relevant git output in PUSH_OUTPUT.
function push_with_retry {
    local attempt=1 rc
    while :; do
        PUSH_OUTPUT=$(git -C "$GIT_PATH" push 2>&1)
        rc=$?
        [ $rc -eq 0 ] && return 0
        if ! is_non_fast_forward "$PUSH_OUTPUT"; then
            return 2
        fi
        if [ "$attempt" -ge "$PUSH_MAX_ATTEMPTS" ]; then
            return 2
        fi
        echo "Push rejected: Overleaf moved ahead of us (attempt $attempt of $PUSH_MAX_ATTEMPTS). Pulling and retrying."
        PUSH_OUTPUT=$(git -C "$GIT_PATH" pull --no-edit 2>&1)
        if has_unmerged_paths; then
            # Restore a clean tree so the caller's own recovery path (and the
            # human) start from a known state rather than a half-merge.
            git -C "$GIT_PATH" merge --abort 2>/dev/null
            return 1
        fi
        date > "$last_successful_pull"
        attempt=$((attempt + 1))
        sleep "$PUSH_RETRY_SLEEP"
    done
}

function git_operations {
    local apply_stash=$1 # First argument is now the apply_stash flag
    shift # Shift the arguments so $1 and onwards are as before
    REPOSITORY_URL=$(git -C "$GIT_PATH" remote get-url "origin")
    git ls-remote $REPOSITORY_URL &> /dev/null

    if [ $? -eq 0 ]; then
        echo "Overleaf repo $OVERLEAF_ID is accessible."
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

    # A conflicted pull has to stop here. Without this guard the code carried
    # straight on: "git add" staged the file with its <<<<<<< markers still in
    # it, "git commit" recorded that as the resolution of the merge, and the
    # markers were pushed to Overleaf inside the .tex.
    if has_unmerged_paths; then
        echo -e "${RED}Merge conflict pulling $OVERLEAF_ID. Conflicted file(s):"
        git -C "$GIT_PATH" ls-files --unmerged | awk '{print "  " $4}' | sort -u
        echo -e "Nothing has been added, committed or pushed."
        echo -e "Resolve by hand, then commit. Conflicts look like this:"
        echo -e "<<<<<<< HEAD"
        echo -e "[Your local version of the conflicted content]"
        echo -e "======="
        echo -e "[The conflicting content from Overleaf]"
        echo -e ">>>>>>> [commit hash of the incoming changes]${RESET}"
        exit
    fi

    rel_file=$(relative_path "$GIT_PATH" "$1")

    git -C "$GIT_PATH" add "$rel_file"
    if [[ $? -ne 0 ]]; then
        echo "Error adding file $1 to the repository."
    fi

    # Only commit if the add actually staged something. Otherwise git prints a
    # noisy "nothing added to commit ... Untracked files:" status dump -- which
    # happens whenever a watched file was changed by a pull (not by us), so
    # there is nothing of ours to record.
    if git -C "$GIT_PATH" diff --cached --quiet; then
        : # nothing staged; skip the commit (and its noise)
    else
        git -C "$GIT_PATH" commit -m "[Auto] Update $rel_file"
        result=$?
        if [[ $result -ne 0 && $result -ne 1 ]]; then
            echo "$result Error committing file $1 to the repository."
        fi
    fi

    git -C "$GIT_PATH" gc --auto # Garbage collect only when needed (safety net for hanging push)

    push_with_retry
    push_status=$?
    output="$PUSH_OUTPUT"

    if [[ $push_status -eq 0 ]]; then
        return 0
    fi

    if [[ $push_status -eq 2 ]]; then
        if [ "$DEBUG" -eq 1 ]; then
            echo "$output"
        fi
        if [[ $apply_stash -eq 1 ]]; then
            # offleaf retries the whole operation on a non-zero return.
            echo -e "${RED}Push to $OVERLEAF_ID did not succeed; will retry.${RESET}"
            return 1
        fi
        echo -e "${RED}Push to $OVERLEAF_ID failed and retrying did not help: exiting.${RESET}"
        echo "$output"
        exit
    fi

    # push_status 1: a genuine conflict. The merge was aborted, so the tree is
    # clean again and the recovery path below behaves as it always has.
    if [[ $apply_stash -eq 1 ]]; then
        echo -e "${RED}Merge conflict detected during push."
        echo -e "Will apply stash.${RESET}"
        git -C "$GIT_PATH" stash
        git -C "$GIT_PATH" pull
        if [[ $? -eq 0 ]]; then
            date > "$last_successful_pull"
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
    else
        if [ "$DEBUG" -eq 1 ]; then
          echo "                         "
          echo "                         "
          echo "$output"
          echo "                         "
          echo "                         "
        fi
        echo -e "${RED}Merge conflict detected in $rel_file."
        echo -e "Conflict is not being resolved: exiting.${RESET}"
        exit
    fi
    return 0
}
