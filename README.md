# offline_leaf — local editing & figure sync for Overleaf projects

A small set of `bash` scripts that let you work on an Overleaf project from your
local machine — editing `.tex`/`.bib` in your own environment and building
figures locally — while changes sync to Overleaf automatically. It uses
Overleaf's [git integration](https://www.overleaf.com/learn/how-to/Git_Integration_and_GitHub_Synchronization).

There are three scripts you run, plus two helpers:

- **`leafsync.sh`** — the single entry point. Pick a recent project (or set up a
  new one) from a menu, and it launches the right watchers for you. New-project
  setup is fully automated.
- **`offleaf.sh`** — watches the project's `.tex` and `.bib` files and
  commits/pushes changes to Overleaf; pulls remote changes in the background and
  helps you resolve conflicts.
- **`figleaf.sh`** — watches your figure *masters* (Adobe Illustrator `.ai`, or
  `.pdf`), and on each change produces an optimized PDF and a JPG, pushing both
  into the Overleaf project so figures stay current without manual uploads.
- **`leaf_common.sh`** — shared git logic (sourced by the others).
- **`offleaf_config.template.sh`** — the per-project config template
  `leafsync.sh` fills in.

Target use: intermittent/no connectivity, a preference for a local LaTeX
toolchain, and figure-heavy papers where manual figure uploads to Overleaf
become tedious.

---

## Key idea: scripts are central, config is per-project

The scripts live in **one** location (a single clone of this repo, ideally on
your `PATH`) and are **never copied into individual Overleaf projects**. This
avoids stale, divergent copies as the scripts improve. The only thing that lives
inside each Overleaf project is its own `offleaf_config.sh`, which
`leafsync.sh` generates from the template.

(Older versions of this system copied the scripts into a `nonCloudEditing/`
folder inside each project. That is no longer needed; `leafsync.sh` can migrate
such projects — see *Migrating older projects* below.)

---

## Requirements

macOS with `bash`, and these tools on your `PATH`:

- **git**
- **fswatch** (filesystem watcher)
- **Ghostscript** (`gs`) — used by `figleaf.sh` to optimize PDFs
- **ImageMagick** (`magick`) — used by `figleaf.sh` to make JPGs

Install (choose one):

```bash
# Homebrew
brew install git fswatch ghostscript imagemagick

# MacPorts
sudo port install git fswatch ghostscript ImageMagick
```

`leafsync.sh` runs a preflight check and tells you if any of these are missing.

---

## Getting started

1. Clone this repo somewhere permanent and add it to your `PATH`, e.g.:

   ```bash
   git clone git@github.com:maciverlab/offline_leaf.git
   # then, in your ~/.zshrc or ~/.bashrc:
   export PATH="$PATH:/full/path/to/offline_leaf"
   ```

2. Run it:

   ```bash
   leafsync.sh          # if on PATH
   # or
   bash /full/path/to/offline_leaf/leafsync.sh
   ```

`leafsync.sh` is interactive. With no arguments it shows a menu of up to your
five most-recently-used projects (press **Enter** to pick the most recent),
plus an option to set up a **new** project.

### Setting up a new project

Choose **n** (new project). You'll be prompted for:

- the **Overleaf project ID** (from the project URL, e.g. the
  `65cf7db8c9d209bdc5f3a039` in `https://www.overleaf.com/project/65cf7db8c9d209bdc5f3a039`), and
- a short **descriptive name**.

`leafsync.sh` then does everything the old manual checklist did:

- creates the project folder and figure directories,
- clones the Overleaf repo,
- sets recommended git options (`pull.rebase false`, larger `http.postBuffer`),
- ensures the project `.gitignore` has the standard LaTeX ignores,
- generates and commits `offleaf_config.sh`,
- seeds `figures/vector/` and `figures/bitmap/` in the repo (git can't track
  empty dirs, so a `.gitkeep` is added), and
- records the project in your recent list, then starts syncing.

### Working on an existing project

Pick a project from the menu; you then choose what to run:

| Option | What it does |
| --- | --- |
| **1. figleaf** | Watch figure masters, convert, and **push** to Overleaf |
| **2. offleaf** | Watch `.tex`/`.bib` and push to Overleaf |
| **3. both** | figleaf + offleaf, each in its own terminal window |
| **4. figleaf (local only)** | Convert locally but do **not** push |

"Both" opens two terminal windows (it detects iTerm2 vs Terminal.app); if it
can't, it prints the two commands for you to run in two terminals yourself. The
first time it opens a window, macOS may ask permission to control your terminal.

Use option 4 to convert figures locally without pushing. Stop a watcher with
**Ctrl-C** in its terminal.

---

## Directory layout (new projects)

A project lives in **two** places, and the split is deliberate.

**1. Figure masters — on a shared cloud drive** (`FIGURES_BASE_DIR`, e.g. Google
Drive), so several people can edit them at once:

```
_OVERLEAF_PROJECTS/<name>_<id>/
└── figures/
    ├── watched/                       # figure MASTERS (watched by figleaf)
    │   ├── prepress_vector/           #   e.g. Illustrator .ai files here
    │   ├── prepress_pdf/
    │   └── prepress_bitmap/
    └── unwatched/                     # generated staging (not watched)
        ├── prepress_pdf/              #   optimized PDFs land here
        ├── prepress_vector/
        └── prepress_bitmap/           #   JPGs land here
```

**2. The Overleaf git clone — on local disk** (`PROJECTS_BASE_DIR`), one per
machine, never in a syncing folder:

```
~/overleaf_projects/<name>_<id>/
└── <id>/                              # the Overleaf git clone  (= GIT_PATH)
    ├── offleaf_config.sh              #   the ONLY per-project script/config
    └── figures/
        ├── vector/                    #   optimized PDFs pushed here
        └── bitmap/                    #   JPGs pushed here
```

`leafsync.sh` asks for both base directories the first time and remembers them
in `~/.config/leafsync/leafsync.conf`.

The figure **masters** live outside the git repo (under `figures/watched/`), so
they're never committed to Overleaf — only their optimized PDF/JPG outputs are.

Why the clone is *not* on the cloud drive: Overleaf's git remote is already the
sync layer, and a second one racing on the same `.git` is actively harmful.
`index.lock` gives no mutual exclusion across machines, whole-file sync latency
loses ref and index updates, and `git gc --auto` can repack objects another
machine has not yet received. Sync clients also leave conflict copies (e.g.
`main (1).tex`) that `offleaf.sh` would happily commit. Each machine therefore
clones separately and they coordinate through Overleaf, as intended. Setting up
a project a second time on another machine reuses the existing shared figure
tree untouched and clones fresh locally.

---

## `figleaf.sh` details

- Watches `figures/watched/` (recursively) for `.ai`/`.pdf` masters, ignoring
  Illustrator's temporary `ai#####…` files.
- On a change: copies the master to a staging PDF, optimizes it with Ghostscript
  (`-dPDFSETTINGS=/prepress`), renders a JPG with ImageMagick, and — in push
  mode — commits/pushes the PDF to `figures/vector/` and the JPG to
  `figures/bitmap/` in the Overleaf repo.
- **Change detection is content-based.** figleaf keeps a per-project hash of the
  last-processed content of each master (under `~/.config/leafsync/hashes/<id>/`,
  persistent across runs). A figure is only reconverted/pushed when its content
  actually changes, so duplicate or delayed filesystem events (common on
  cloud-synced folders like Google Drive) don't cause redundant commits.
- **Startup reconciliation.** Because a filesystem watcher only sees changes
  that happen *while it's running*, figleaf scans your masters on startup and
  processes any that changed while it was off — so you don't have to re-save or
  "touch" them. On the **very first run for a project** the hash store is empty,
  so **every** master is processed once (a full initial sync); subsequent runs
  only process what actually changed.
- **No auto-merge.** Masters are assumed to be edited by one person at a time.
  On a genuine conflict figleaf reports it and exits (binary auto-merge would be
  unsafe). It pulls before pushing but does not copy Overleaf's copies back over
  your masters.
- **Rejected pushes are retried, not fatal.** See *Rejected pushes vs. real
  conflicts* below — a rejection no longer stops figleaf.

## `offleaf.sh` details

- Watches the Overleaf clone for `.tex` **and** `.bib` changes and
  commits/pushes them.
- Pulls from Overleaf in the background on an interval and reports whether your
  local copy is in sync.
- **Conflict handling:** on a genuine conflict it stashes, pulls, re-applies, and
  tells you how to resolve any remaining merge markers in the affected file. A
  merely *rejected* push is retried instead — see below.
- **Startup reconciliation:** on launch it commits/pushes any `.tex`/`.bib`
  that were modified or added while offleaf was not running.

---

## Rejected pushes vs. real conflicts

These are different problems and are handled differently.

**A rejected push** means the Overleaf remote gained commits between our pull
and our push. While anyone is typing in the Overleaf web editor, the git bridge
mints an `Update on Overleaf.` commit every few seconds, so with a collaborator
active this is routine rather than exceptional. Nothing is conflicted: the files
the scripts write (`figures/*`, or one `.tex`) are not the ones the collaborator
touched. The fix is simply to pull and push again.

Both scripts now do that automatically, retrying up to `PUSH_MAX_ATTEMPTS` times
with `PUSH_RETRY_SLEEP` seconds between attempts (defaults `5` and `3`; override
either in `offleaf_config.sh`). Two shapes of rejection are recognised: the usual
non-fast-forward, and the tighter race where the remote advances while the push
is in flight (`cannot lock ref … is at X but expected Y`). A failure that
retrying cannot fix — authentication, network, a rejecting hook — is reported
immediately rather than retried.

> Earlier versions treated *any* push failure as a merge conflict, because the
> check matched the string `failed to push`, which git prints in both cases.
> figleaf would print "Merge conflict detected during push" and exit, on what
> was usually just a stale ref. If you see that message from an old copy, this
> is what it meant.

**A real conflict** means two sides changed the same lines, and a person has to
choose. This surfaces in the **pull**, not the push, so that is where it is
detected — via `git ls-files --unmerged`. When it happens the scripts stop
immediately, name the conflicted files, and leave the repository untouched:
nothing is added, committed, or pushed. Resolve the markers by hand and commit.

> A conflicted pull used to fall through to `git add` and `git commit`, which
> staged the file with its `<<<<<<<` markers still in it, recorded that as the
> resolution, and pushed the markers to Overleaf. If a `.tex` in your project
> ever acquired stray conflict markers, this was why.

---

## Configuration (`offleaf_config.sh`)

`leafsync.sh` generates this per project from `offleaf_config.template.sh`; you
rarely need to edit it by hand.

This file is committed into the Overleaf project and is **machine-independent**:
it stores nothing that differs between machines, so the same file is correct
everywhere and no machine's push can clobber another's. It holds only two
substituted values, both project-invariant:

| Variable | Meaning |
| --- | --- |
| `FIGURES_SUBPATH` | Figure masters dir *relative to* this machine's `FIGURES_BASE_DIR`, e.g. `myproject_<id>/figures/watched/` |
| `OVERLEAF_ID` | The Overleaf project ID |

Everything else that used to be hard-coded is now derived at run time:

| Variable | Derived from |
| --- | --- |
| `GIT_PATH` | The directory this config file sits in (`BASH_SOURCE`) — the clone locates itself |
| `WATCH_PATH_CONVERT` | `FIGURES_BASE_DIR` (per machine, from `~/.config/leafsync/leafsync.conf`) + `FIGURES_SUBPATH` |
| `FSWATCH` / `CONVERT` | `command -v`, falling back to the Homebrew paths |

If `FIGURES_BASE_DIR` has never been recorded on a machine, the config says so
and leaves `WATCH_PATH_CONVERT` empty. `offleaf.sh` still runs (it only needs
the clone); `figleaf.sh` needs it, so run `leafsync.sh` once on that machine.

Other settings (sensible defaults shown):

| Variable | Default | Meaning |
| --- | --- | --- |
| `COMMIT_INTERVAL_SECONDS` | `3` | Minimum gap between commits |
| `GIT_PULL_INTERVAL_SECONDS` | `90` | Background pull interval (offleaf); higher = fewer network wakeups |
| `DEBOUNCE_SECONDS` | `5` | Quiet period after an edit before processing (so one save = one commit) |
| `POLL_INTERVAL_SECONDS` | `3` | How often the loop wakes when idle; higher = better battery |
| `PUSH_MAX_ATTEMPTS` | `5` | Attempts before giving up on a push the remote keeps rejecting |
| `PUSH_RETRY_SLEEP` | `3` | Seconds between those attempts |
| `DEBUG` | `0` | Set to `1` for verbose diagnostics |

> **Note:** because `offleaf_config.sh` is machine-independent, a collaborator
> on a different machine can use the committed file as-is. They only need
> `leafsync.sh` to have recorded their own `FIGURES_BASE_DIR` once.

---

## State created on your machine

`leafsync.sh` keeps cross-project state under `~/.config/leafsync/`:

- `recent.tsv` — the recent-projects list (up to 5).
- `leafsync.conf` — remembered defaults (e.g. your projects base directory).
- `hashes/<id>/` — figleaf's persistent per-project content hashes.
- `locks/` — per-project run locks (so you don't accidentally start two
  watchers on the same project).

Deleting `hashes/<id>/` makes the next figleaf run do a full initial sync again.

---

## Collaboration

Keep the **figure** folder (`FIGURES_BASE_DIR/<name>_<id>/figures/`) on a shared
cloud drive and give collaborators read/write access to it. The git clone stays
local to each machine and is not shared this way. Workflow:

1. Do early figure edits in `figures/unwatched/prepress_vector/` (or `_pdf` /
   `_bitmap`) — nothing there is watched or pushed.
2. When a figure is ready for the paper, start `figleaf.sh` (via `leafsync.sh`)
   and move the master into `figures/watched/…`; it will be converted and
   pushed.

This works as long as **two people don't edit the same watched master at the
same time** — because figures are binary, that produces conflicts that can't be
auto-merged. Coordinate who "owns" a figure while editing it.

---

## LaTeX side (once per project)

Add the two pushed figure folders to your document's graphics path so it can
find the synced figures, e.g. in your preamble:

```latex
\graphicspath{ {./figures/bitmap/}{./figures/vector/} }
```

Use the bitmap JPGs for fast Overleaf compiles and the vector PDFs for the final
build. (Many projects use a small macro to switch between the two.)

---

## Migrating older projects

If a project still contains a `nonCloudEditing/` folder with copies of these
scripts, `leafsync.sh` can detect it and offer to move its `offleaf_config.sh`
to the repo root and remove the old copies — only with your explicit
confirmation. Nothing is changed automatically.

---

## Manual use (without `leafsync.sh`)

You can run the watchers directly. Ensure the project has an
`offleaf_config.sh` (copy `offleaf_config.template.sh` into the clone and fill
in `FIGURES_SUBPATH` and `OVERLEAF_ID`, keeping the trailing slash on the
former), then:

```bash
# figures, with push to Overleaf:
bash figleaf.sh /path/to/project/offleaf_config.sh -push

# .tex/.bib, with push to Overleaf:
bash offleaf.sh /path/to/project/offleaf_config.sh

# figures, local only (no push): omit -push
bash figleaf.sh /path/to/project/offleaf_config.sh
```

Notes:
- Invoke with `bash <script>` rather than `./<script>`. Overleaf's git bridge
  strips the executable bit, so relying on `chmod +x` for scripts that pass
  through it is fragile; `bash` sidesteps that.
- `offleaf.sh` takes **only** the config path (no `-push`); it always pushes.
- Recommended once per clone (leafsync does this for you):
  `git config pull.rebase false` and `git config http.postBuffer 10485760`.
- A suggested `.gitignore` for the Overleaf project is in
  `GITIGNORE_CONTENTS.txt`.

---

*Written by Malcolm A. MacIver*
