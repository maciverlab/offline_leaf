#!/bin/bash
#
# leafsync.sh -- one entry point for the offline_leaf Overleaf sync system.
#
# With no arguments it shows a menu of the (up to 5) most recently used
# projects, defaulting to the most recent on a bare Enter, plus an option to
# set up a brand-new project. Existing project -> launch figleaf/offleaf/both
# against that project's offleaf_config.sh. New project -> run the full setup
# (create dirs, clone the Overleaf repo, fix .gitignore, generate and commit
# offleaf_config.sh, seed figures/{vector,bitmap}) then start syncing.
#
# Design: this script lives centrally alongside figleaf.sh, offleaf.sh and
# leaf_common.sh and is NEVER copied into a project. Only offleaf_config.sh is
# per-project. Requires bash, git, fswatch, ghostscript (gs) and ImageMagick
# (magick). Written for macOS / bash 3.2. Invoke sibling scripts with `bash`
# (not ./) so the Overleaf-bridge-stripped executable bit never matters.

# Directory containing this script and its siblings, resolving symlinks.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Cross-project state (recent list, saved defaults, run locks).
STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/leafsync"
RECENT_FILE="$STATE_DIR/recent.tsv"
CONF_FILE="$STATE_DIR/leafsync.conf"
LOCK_DIR="$STATE_DIR/locks"

# Base of the Overleaf git remote. Overridable (e.g. for testing against a
# local bare repo) via LEAFSYNC_GIT_BASE.
GIT_REMOTE_BASE="${LEAFSYNC_GIT_BASE:-https://git@git.overleaf.com}"

MAX_RECENT=5

# ANSI-C quoting ($'...') so these hold real ESC bytes and print correctly
# via printf '%s' (unlike plain "\033..." which would print literally).
RED=$'\033[1;31m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

# Canonical .gitignore entries for an Overleaf LaTeX project.
GITIGNORE_ENTRIES='.DS_Store
*.out
*.tmp
*.aux
*.bbl
*.blg
*.fdb_latexmk
*.fls
*.log
*.spl
*.synctex*
*.swp
*.toc
*.swo
/*.pdf
default.profraw'

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
info() { printf '%s\n' "$*"; }
warn() { printf "${RED}%s${RESET}\n" "$*" >&2; }
die()  { warn "$*"; exit 1; }

# Prompt with a message, echoing the raw reply.
ask() {
    local prompt="$1" reply
    printf '%s' "$prompt" >&2
    IFS= read -r reply
    printf '%s' "$reply"
}

# ---------------------------------------------------------------------------
# Config / state files
# ---------------------------------------------------------------------------
ensure_state_dir() {
    mkdir -p "$STATE_DIR" "$LOCK_DIR" || die "Cannot create state dir: $STATE_DIR"
}

load_conf() {
    [ -f "$CONF_FILE" ] && . "$CONF_FILE"
}

# save_conf_var KEY VALUE  (rewrites CONF_FILE atomically, no sed -i)
save_conf_var() {
    local key="$1" val="$2" tmp
    tmp="$(mktemp "$STATE_DIR/conf.XXXXXX")" || return 1
    if [ -f "$CONF_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                "$key="*) ;;                       # drop old value
                *) printf '%s\n' "$line" >> "$tmp" ;;
            esac
        done < "$CONF_FILE"
    fi
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    mv "$tmp" "$CONF_FILE"
}

# ---------------------------------------------------------------------------
# Recent-projects list  (TSV: name  id  config_path  repo_path  last_used)
# ---------------------------------------------------------------------------
# Parallel arrays populated by load_recent.
R_NAME=(); R_ID=(); R_CONFIG=(); R_REPO=(); R_TS=(); R_COUNT=0

load_recent() {
    R_NAME=(); R_ID=(); R_CONFIG=(); R_REPO=(); R_TS=(); R_COUNT=0
    [ -f "$RECENT_FILE" ] || return 0
    local n i c r t
    while IFS=$'\t' read -r n i c r t || [ -n "$n" ]; do
        [ -z "$i" ] && continue
        R_NAME[$R_COUNT]="$n"; R_ID[$R_COUNT]="$i"
        R_CONFIG[$R_COUNT]="$c"; R_REPO[$R_COUNT]="$r"; R_TS[$R_COUNT]="$t"
        R_COUNT=$((R_COUNT + 1))
    done < "$RECENT_FILE"
}

# bump_recent NAME ID CONFIG REPO  (dedup by id, prepend, truncate to MAX_RECENT)
bump_recent() {
    local name="$1" id="$2" config="$3" repo="$4" ts tmp count n i c r t
    ts="$(date +"%Y-%m-%d %H:%M")"
    tmp="$(mktemp "$STATE_DIR/recent.XXXXXX")" || return 1
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$id" "$config" "$repo" "$ts" > "$tmp"
    count=1
    if [ -f "$RECENT_FILE" ]; then
        while IFS=$'\t' read -r n i c r t || [ -n "$n" ]; do
            [ -z "$i" ] && continue
            [ "$i" = "$id" ] && continue
            printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$i" "$c" "$r" "$t" >> "$tmp"
            count=$((count + 1))
            [ "$count" -ge "$MAX_RECENT" ] && break
        done < "$RECENT_FILE"
    fi
    mv "$tmp" "$RECENT_FILE"
}

# ---------------------------------------------------------------------------
# Tool preflight
# ---------------------------------------------------------------------------
FSWATCH_BIN=""; CONVERT_BIN=""; GS_BIN=""
preflight_check() {
    local ok=1
    FSWATCH_BIN="$(command -v fswatch 2>/dev/null)"
    CONVERT_BIN="$(command -v magick 2>/dev/null)"
    GS_BIN="$(command -v gs 2>/dev/null)"
    if [ -z "$FSWATCH_BIN" ]; then warn "Missing 'fswatch' (brew install fswatch)."; ok=0; fi
    if [ -z "$CONVERT_BIN" ]; then warn "Missing ImageMagick 'magick' (brew install imagemagick)."; ok=0; fi
    if [ -z "$GS_BIN" ]; then warn "Missing Ghostscript 'gs' (brew install ghostscript)."; ok=0; fi
    return $((1 - ok))
}

# ---------------------------------------------------------------------------
# Launching figleaf / offleaf
# ---------------------------------------------------------------------------
# Build a self-contained runner script in /tmp (path has no spaces, so it is
# safe to embed in an AppleScript string). The runner takes a per-project run
# lock, cds into the repo, and runs the sync script in the foreground so its
# own SIGINT cleanup traps fire. Echoes the runner path.
#   make_runner LABEL LOCKFILE REPO SCRIPT CONFIG PUSH(0|1)
make_runner() {
    local label="$1" lockfile="$2" repo="$3" script="$4" config="$5" push="$6"
    local runner pushflag=""
    [ "$push" = "1" ] && pushflag=" -push"
    runner="$(mktemp /tmp/leafsync_run.XXXXXXXX)" || return 1
    {
        printf '#!/bin/bash\n'
        printf 'LOCKFILE=%q\n' "$lockfile"
        printf 'if [ -f "$LOCKFILE" ] && kill -0 "$(cat "$LOCKFILE" 2>/dev/null)" 2>/dev/null; then\n'
        printf '  echo "A sync for %s already appears to be running (PID $(cat "$LOCKFILE")); not starting another."\n' "$label"
        printf '  echo "Press Enter to close."; read _; exit 0\n'
        printf 'fi\n'
        printf 'echo $$ > "$LOCKFILE"\n'
        printf 'trap "rm -f \\"$LOCKFILE\\"" EXIT\n'
        printf 'cd %q || { echo "Repo not found: %s"; exit 1; }\n' "$repo" "$repo"
        printf 'echo "=== leafsync: %s ==="\n' "$label"
        printf 'bash %q %q%s\n' "$script" "$config" "$pushflag"
    } > "$runner"
    printf '%s' "$runner"
}

# Open a command (a runner path) in a new terminal window. Returns non-zero if
# it could not (caller falls back). Detects iTerm vs Terminal.app.
open_in_new_terminal() {
    local runner="$1"
    case "$TERM_PROGRAM" in
        iTerm.app)
            osascript \
                -e 'tell application "iTerm"' \
                -e '  create window with default profile' \
                -e "  tell current session of current window to write text \"bash '$runner'\"" \
                -e 'end tell' >/dev/null 2>&1
            ;;
        *)
            osascript -e "tell application \"Terminal\" to do script \"bash '$runner'\"" >/dev/null 2>&1
            ;;
    esac
}

# Run figleaf (and/or offleaf) for a project.
#   run_sync REPO CONFIG NAME ID MODE
# MODE: figleaf-push | figleaf-local | offleaf | both
run_sync() {
    local repo="$1" config="$2" name="$3" id="$4" mode="$5"
    local fig_lock="$LOCK_DIR/$id-figleaf.pid"
    local off_lock="$LOCK_DIR/$id-offleaf.pid"
    local fig_runner off_runner

    case "$mode" in
        figleaf-push|figleaf-local)
            local push=1; [ "$mode" = "figleaf-local" ] && push=0
            fig_runner="$(make_runner "figleaf ($name)" "$fig_lock" "$repo" "$SCRIPT_DIR/figleaf.sh" "$config" "$push")"
            info "Starting figleaf (Ctrl-C to stop)."
            bash "$fig_runner"
            rm -f "$fig_runner"
            ;;
        offleaf)
            off_runner="$(make_runner "offleaf ($name)" "$off_lock" "$repo" "$SCRIPT_DIR/offleaf.sh" "$config" "0")"
            info "Starting offleaf (Ctrl-C to stop)."
            bash "$off_runner"
            rm -f "$off_runner"
            ;;
        both)
            fig_runner="$(make_runner "figleaf ($name)" "$fig_lock" "$repo" "$SCRIPT_DIR/figleaf.sh" "$config" "1")"
            off_runner="$(make_runner "offleaf ($name)" "$off_lock" "$repo" "$SCRIPT_DIR/offleaf.sh" "$config" "0")"
            if open_in_new_terminal "$fig_runner" && open_in_new_terminal "$off_runner"; then
                info "Launched figleaf and offleaf in two new terminal windows."
                info "Close those windows (or Ctrl-C in each) to stop syncing."
            else
                warn "Could not open new terminal windows automatically."
                info "Open two terminals and run, one in each:"
                info "  bash \"$fig_runner\""
                info "  bash \"$off_runner\""
            fi
            ;;
        *) warn "Unknown mode: $mode" ;;
    esac
}

# Sub-menu shown once a project is selected/created.
project_menu() {
    local repo="$1" config="$2" name="$3" id="$4" choice
    while :; do
        info ""
        info "${BOLD}Project: $name${RESET}  ($id)"
        info "  1) figleaf  -- watch figures, convert, and PUSH to Overleaf   [default]"
        info "  2) offleaf  -- watch .tex files and push to Overleaf"
        info "  3) both     -- figleaf + offleaf in two terminal windows"
        info "  4) figleaf (local only, NO push)"
        info "  q) quit"
        choice="$(ask 'Choose [1]: ')"
        [ -z "$choice" ] && choice=1
        case "$choice" in
            1) run_sync "$repo" "$config" "$name" "$id" "figleaf-push"; return 0 ;;
            2) run_sync "$repo" "$config" "$name" "$id" "offleaf"; return 0 ;;
            3) run_sync "$repo" "$config" "$name" "$id" "both"; return 0 ;;
            4) run_sync "$repo" "$config" "$name" "$id" "figleaf-local"; return 0 ;;
            q|Q) return 0 ;;
            *) warn "Invalid choice: $choice" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# New-project setup
# ---------------------------------------------------------------------------
# Ensure the clone's .gitignore contains all canonical entries; commit/push if changed.
ensure_gitignore() {
    local repo="$1" gi="$1/.gitignore" changed=0 entry
    [ -f "$gi" ] || : > "$gi"
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        if ! grep -qxF "$entry" "$gi" 2>/dev/null; then
            printf '%s\n' "$entry" >> "$gi"
            changed=1
        fi
    done <<EOF
$GITIGNORE_ENTRIES
EOF
    if [ "$changed" = "1" ]; then
        git -C "$repo" add .gitignore
        git -C "$repo" commit -m "update .gitignore" >/dev/null 2>&1
        git -C "$repo" push >/dev/null 2>&1
        info "Updated .gitignore."
    fi
}

# Ensure figures/vector and figures/bitmap exist in the repo and are tracked
# (git cannot track empty dirs, so seed a .gitkeep); commit/push if created.
ensure_pushed_figure_dirs() {
    local repo="$1" changed=0 d
    for d in figures/vector figures/bitmap; do
        mkdir -p "$repo/$d"
        if [ ! -f "$repo/$d/.gitkeep" ] && [ -z "$(ls -A "$repo/$d" 2>/dev/null)" ]; then
            : > "$repo/$d/.gitkeep"
            git -C "$repo" add "$d/.gitkeep"
            changed=1
        fi
    done
    if [ "$changed" = "1" ]; then
        git -C "$repo" commit -m "add figures/vector and figures/bitmap" >/dev/null 2>&1
        git -C "$repo" push >/dev/null 2>&1
        info "Seeded figures/vector and figures/bitmap."
    fi
}

# Generate offleaf_config.sh from the template (bash substitution, no sed).
write_project_config() {
    local config_out="$1" git_path="$2" watch_path="$3" overleaf_id="$4"
    local fswatch="$5" convert="$6" tmpl
    tmpl="$(cat "$SCRIPT_DIR/offleaf_config.template.sh")" || return 1
    tmpl="${tmpl//__GIT_PATH__/$git_path}"
    tmpl="${tmpl//__WATCH_PATH_CONVERT__/$watch_path}"
    tmpl="${tmpl//__OVERLEAF_ID__/$overleaf_id}"
    tmpl="${tmpl//__FSWATCH__/$fswatch}"
    tmpl="${tmpl//__CONVERT__/$convert}"
    printf '%s\n' "$tmpl" > "$config_out"
}

# Resolve the base directory that holds all projects, prompting/persisting once.
resolve_base_dir() {
    if [ -n "$PROJECTS_BASE_DIR" ] && [ -d "$PROJECTS_BASE_DIR" ]; then
        printf '%s' "$PROJECTS_BASE_DIR"; return 0
    fi
    local guess reply
    guess="$(ls -d "$HOME"/Library/CloudStorage/GoogleDrive-*/My\ Drive/_OVERLEAF_PROJECTS 2>/dev/null | head -1)"
    if [ -n "$guess" ]; then
        reply="$(ask "Base directory for projects:  ($guess) [default] ")"
        [ -z "$reply" ] && reply="$guess"
    else
        reply="$(ask "Base directory for projects (none detected; enter a path): ")"
    fi
    [ -z "$reply" ] && { warn "No base directory given."; return 1; }
    [ -d "$reply" ] || mkdir -p "$reply" || { warn "Cannot create $reply"; return 1; }
    save_conf_var "PROJECTS_BASE_DIR" "$reply"
    PROJECTS_BASE_DIR="$reply"
    printf '%s' "$reply"
}

new_project() {
    local id name base project_dir repo watch fswatch convert sane

    id="$(ask 'Overleaf project ID: ')"
    case "$id" in
        ''|*[!A-Za-z0-9]*) die "Invalid project ID (expected letters/digits): '$id'";;
    esac
    name="$(ask 'Short descriptive name: ')"
    [ -z "$name" ] && die "A descriptive name is required."
    # Sanitize name: keep alnum, dash, underscore; other -> underscore.
    sane="$(printf '%s' "$name" | tr -c 'A-Za-z0-9_-' '_')"

    base="$(resolve_base_dir)" || exit 1
    project_dir="$base/${sane}_${id}"
    repo="$project_dir/$id"           # flatter layout: clone dir named <id>
    watch="$project_dir/figures/watched/"

    if [ -e "$project_dir" ]; then
        local ov; ov="$(ask "Project dir already exists: $project_dir -- continue anyway? [y/N]: ")"
        case "$ov" in y|Y) ;; *) die "Aborted." ;; esac
    fi

    info "Creating figure directories under $project_dir/figures ..."
    mkdir -p \
        "$project_dir/figures/unwatched/prepress_bitmap" \
        "$project_dir/figures/unwatched/prepress_pdf" \
        "$project_dir/figures/unwatched/prepress_vector" \
        "$project_dir/figures/watched/prepress_bitmap" \
        "$project_dir/figures/watched/prepress_pdf" \
        "$project_dir/figures/watched/prepress_vector" || die "mkdir failed."

    if [ -d "$repo/.git" ]; then
        info "Clone already present at $repo -- skipping clone."
    else
        info "Cloning Overleaf project $id ..."
        git clone "$GIT_REMOTE_BASE/$id" "$repo" || die "git clone failed."
    fi

    # Recommended git settings for the Overleaf gitsync workflow.
    git -C "$repo" config pull.rebase false
    git -C "$repo" config http.postBuffer 10485760

    ensure_gitignore "$repo"

    fswatch="${FSWATCH_BIN:-/opt/homebrew/bin/fswatch}"
    convert="${CONVERT_BIN:-/opt/homebrew/bin/magick}"
    info "Writing offleaf_config.sh ..."
    write_project_config "$repo/offleaf_config.sh" "$repo/" "$watch" "$id" "$fswatch" "$convert" \
        || die "Could not write config."
    git -C "$repo" add offleaf_config.sh
    git -C "$repo" commit -m "changes to configuration" >/dev/null 2>&1
    git -C "$repo" push >/dev/null 2>&1

    ensure_pushed_figure_dirs "$repo"

    bump_recent "$sane" "$id" "$repo/offleaf_config.sh" "$repo/"
    info "Project ready."
    project_menu "$repo/" "$repo/offleaf_config.sh" "$sane" "$id"
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------
main_menu() {
    load_recent
    info "${BOLD}leafsync${RESET} -- Overleaf figure/tex sync"
    info ""
    if [ "$R_COUNT" -gt 0 ]; then
        info "Recent projects:"
        local idx=0
        while [ "$idx" -lt "$R_COUNT" ]; do
            local mark=""
            [ "$idx" -eq 0 ] && mark="  [default]"
            info "  $((idx + 1))) ${R_NAME[$idx]}  (${R_ID[$idx]})$mark"
            idx=$((idx + 1))
        done
    else
        info "No recent projects yet."
    fi
    info "  n) set up a NEW project"
    info "  q) quit"

    local choice
    choice="$(ask 'Choose [1]: ')"
    [ -z "$choice" ] && choice=1

    case "$choice" in
        n|N) new_project ;;
        q|Q) exit 0 ;;
        *[!0-9]*|'') warn "Invalid choice: $choice"; exit 1 ;;
        *)
            local sel=$((choice - 1))
            if [ "$sel" -lt 0 ] || [ "$sel" -ge "$R_COUNT" ]; then
                die "No such project number: $choice"
            fi
            local repo="${R_REPO[$sel]}" config="${R_CONFIG[$sel]}"
            local name="${R_NAME[$sel]}" id="${R_ID[$sel]}"
            if [ ! -f "$config" ]; then
                warn "Config not found for this project: $config"
                die "It may have moved. Set it up again as a new project, or fix the path in $RECENT_FILE."
            fi
            bump_recent "$name" "$id" "$config" "$repo"
            project_menu "$repo" "$config" "$name" "$id"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------
# LEAFSYNC_TEST=1 lets a test harness source this file for its functions
# without running the interactive entry point.
if [ -z "$LEAFSYNC_TEST" ]; then
    [ -t 0 ] || die "leafsync.sh is interactive; run it in a terminal."
    ensure_state_dir
    load_conf
    if ! preflight_check; then
        reply="$(ask 'Some required tools are missing (see above). Continue anyway? [y/N]: ')"
        case "$reply" in y|Y) ;; *) exit 1 ;; esac
    fi
    main_menu
fi
