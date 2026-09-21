# DEBUG comes from the config file (offleaf_config.sh); default to off if not set
DEBUG=${DEBUG:-0}


function relative_path() {
    prefix="$1"
    string="$2"
    echo ${string#"$prefix"}
}


# How many times to retry a push that was rejected because the remote moved,
# and how long to wait between attempts. PUSH_RETRY_SLEEP is the FIRST wait;
# each later one doubles it, up to PUSH_RETRY_MAX_SLEEP. Overridable from
# offleaf_config.sh.
PUSH_MAX_ATTEMPTS=${PUSH_MAX_ATTEMPTS:-6}
PUSH_RETRY_SLEEP=${PUSH_RETRY_SLEEP:-3}
PUSH_RETRY_MAX_SLEEP=${PUSH_RETRY_MAX_SLEEP:-60}

# How often the idle loop retries commits stranded by an exhausted push.
FLUSH_INTERVAL_SECONDS=${FLUSH_INTERVAL_SECONDS:-60}

# Quiescence gate: how long Overleaf's ref must hold still before we treat the
# moment as a gap worth pushing into, and the longest we will wait for one
# before pushing anyway. Set PUSH_QUIET_SECONDS=0 to disable the gate.
PUSH_QUIET_SECONDS=${PUSH_QUIET_SECONDS:-4}
PUSH_QUIET_MAX_WAIT=${PUSH_QUIET_MAX_WAIT:-30}

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

# Wait until the Overleaf ref stops moving, then return so the caller can pull
# and push into the gap.
#
# This measures contention instead of guessing at it. A blind sleep is a bet on
# the remote being quiet when it expires; ls-remote is a cheap, ref-only network
# call that simply asks. Under no contention it costs one quiet interval; under
# contention it returns the moment a real gap opens, rather than burning a whole
# backoff step and then colliding again.
#
# $1 seconds the ref must hold still, $2 total budget. Returns 0 once quiet,
# 1 if the budget ran out (caller should go ahead and try regardless).
function wait_for_quiet_remote {
    local quiet="${1:-$PUSH_QUIET_SECONDS}" budget="${2:-$PUSH_QUIET_MAX_WAIT}"
    local waited=0 prev cur
    [ "$quiet" -le 0 ] && return 0
    prev=$(git -C "$GIT_PATH" ls-remote origin HEAD 2>/dev/null | awk '{print $1}')
    [ -z "$prev" ] && return 1        # cannot reach the remote; let the push report it
    while [ "$waited" -lt "$budget" ]; do
        sleep "$quiet"
        waited=$((waited + quiet))
        cur=$(git -C "$GIT_PATH" ls-remote origin HEAD 2>/dev/null | awk '{print $1}')
        [ -z "$cur" ] && return 1
        [ "$cur" = "$prev" ] && return 0
        prev="$cur"
    done
    return 1
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
    local attempt=1 rc delay half
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
        # Exponential backoff with jitter. A FIXED delay is precisely the problem
        # it replaces: Overleaf's bridge mints a commit every few seconds while
        # anyone is typing, so retrying on a fixed ~3s beat runs in lock step
        # with the remote and loses every race -- observed losing 5 for 5 against
        # a burst of 8 commits in 31s. Doubling the wait, and randomising its
        # second half, pulls the retries out of phase and outlasts the burst,
        # which is always short.
        delay=$(( PUSH_RETRY_SLEEP << (attempt - 1) ))
        [ "$delay" -gt "$PUSH_RETRY_MAX_SLEEP" ] && delay=$PUSH_RETRY_MAX_SLEEP
        # Spend the backoff budget WAITING FOR A GAP rather than sleeping blind:
        # returns early the moment Overleaf stops moving, and otherwise costs the
        # same as the sleep it replaces. Falls back to a jittered sleep if the
        # gate is disabled or the remote is unreachable.
        if ! wait_for_quiet_remote "$PUSH_QUIET_SECONDS" "$delay"; then
            half=$(( delay / 2 )); [ "$half" -lt 1 ] && half=1
            [ "$PUSH_QUIET_SECONDS" -le 0 ] && sleep $(( half + RANDOM % (half + 1) ))
        fi
        attempt=$((attempt + 1))
    done
}

# Local date and time for user-facing notices, e.g. "Aug 31 at 9:53 am".
# One date call, then the AM/PM suffix is lowercased on its own so the month
# abbreviation keeps its capital letter.
function now_stamp {
    local s
    s=$(date '+%b %-d at %-I:%M %p')
    printf '%s %s' "${s% *}" "$(printf '%s' "${s##* }" | tr '[:upper:]' '[:lower:]')"
}

# Push commits that an earlier exhausted retry left stranded locally. Called
# from the idle path, so it only ever runs when there is no figure to process.
# Cheap and silent when there is nothing pending: one revision count, no network.
#
# Returns 0 if nothing was pending or everything was pushed, 1 otherwise.
function flush_pending_commits {
    local ahead
    ahead=$(git -C "$GIT_PATH" rev-list --count '@{u}'..HEAD 2>/dev/null) || return 0
    case "$ahead" in ''|*[!0-9]*) return 0 ;; esac
    [ "$ahead" -eq 0 ] && return 0
    echo
    echo "$ahead commit(s) still waiting to reach $OVERLEAF_ID; retrying now."
    push_with_retry
    case $? in
        0) echo -e "${RED}Pending commits reached $OVERLEAF_ID on $(now_stamp).${RESET}"
           echo
           return 0 ;;
        1) echo -e "${RED}A genuine conflict is blocking the pending commits;"
           echo -e "resolve it by hand in $GIT_PATH.${RESET}"
           echo
           return 1 ;;
        *) echo "Overleaf still busy; will try again in ${FLUSH_INTERVAL_SECONDS}s."
           echo
           return 1 ;;
    esac
}

function git_operations {
    local apply_stash=$1 # First argument is now the apply_stash flag
    shift # Shift the arguments so $1 and onwards are as before
    local f rel_files
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

    # Every path we were given, staged together so one figure costs ONE commit
    # and ONE push. Pushing the PDF and the JPG separately made each figure two
    # independent races against Overleaf, so the chance of a figure arriving
    # whole was the SQUARE of the chance of winning one race -- which is why
    # figures kept landing half-synced, the vector in and the bitmap missing.
    rel_files=()
    for f in "$@"; do
        [ -n "$f" ] || continue
        rel_files+=("$(relative_path "$GIT_PATH" "$f")")
    done
    # Human-readable list for commit messages and notices.
    rel_file=$(printf '%s, ' "${rel_files[@]}"); rel_file=${rel_file%, }

    git -C "$GIT_PATH" add -- "${rel_files[@]}"
    if [[ $? -ne 0 ]]; then
        echo "Error adding $rel_file to the repository."
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
        # Do NOT exit. The commit is already safe in the local repository, and
        # a lost push race is transient: Overleaf's bridge mints a commit every
        # few seconds while anyone types, so the remote simply moved under us
        # again. Exiting turned a delay of a minute into a dead watcher that
        # silently stopped syncing until a human noticed. The caller treats a
        # non-zero return as "not pushed", so the figure's hash is not recorded
        # and it will be retried; flush_pending_commits pushes the commit itself
        # once the project goes quiet.
        echo -e "${RED}Push to $OVERLEAF_ID did not succeed after $PUSH_MAX_ATTEMPTS attempts"
        echo -e "on $(now_stamp). Overleaf is busy; the commit is safe locally and will be"
        echo -e "pushed automatically once the project goes quiet. Still watching.${RESET}"
        return 2
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
        git -C "$GIT_PATH" add -- "${rel_files[@]}"
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
