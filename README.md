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
**Ctrl-C** in its terminal, or by closing the window — both clean up the
`fswatch` child and the scratch files.

> `fswatch` used to be left behind on every exit, reparented to `launchd` and
> still recursively watching a cloud-synced folder forever; four had accumulated
> over a month. Closing the window was the main culprit, because it sends
> `SIGHUP`, which killed bash without running a `SIGINT`-only trap. The watchers
> now trap `SIGINT`, `SIGTERM` and `SIGHUP`, and escalate to `SIGKILL` if
> `fswatch` ignores the first signal (it can sit blocked in the FSEvents run
> loop). If you have strays from an older version, `pgrep -x fswatch` will show
> them — any with a parent PID of 1 is an orphan.

**Editing these scripts while they are running will break the running copy.**
bash reads a script from disk as it executes, tracking a byte offset, so
changing the file underneath a live watcher makes it resume at an offset that no
longer means anything — producing a syntax error on a line that may not even
exist in the version that started. Pull or edit, *then* restart. This also
matters because a running watcher reads `offleaf_config.sh` and
`leaf_common.sh` only once, at startup: a config fix or a script update has no
effect until you restart it.

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
- **Only the first artboard is published.** An Illustrator `.ai` saved with PDF
  compatibility *is* a PDF, so a master with N artboards arrives as an N-page
  PDF. Both outputs are cropped to page one — the JPG via ImageMagick's `[0]`
  selector, the PDF via Ghostscript's `-dFirstPage=1 -dLastPage=1`. The document
  shows one image per figure (`\includegraphics` with no `page=`), so the other
  artboards could never be displayed, and shipping them bloated every push: one
  7-artboard figure went from 7 pages and 1.5 MB to 1 page and 392 KB.
  If a master's later artboards are real content, split it into separate files.

  > Before this, a multi-page master produced no bitmap at all. ImageMagick
  > writes one file per page as `<name>-0.jpg`, `<name>-1.jpg`, … and never
  > `<name>.jpg`, so the move that followed failed and the figure was silently
  > left without its JPG.
- **One commit and one push per figure.** The PDF and the JPG are staged
  together and pushed once. Pushing them separately made every figure two
  independent races against Overleaf's moving ref, so a figure arrived whole
  only if *both* were won — the square of one race's odds, and the reason
  figures used to land half-synced with the vector in and the bitmap missing.
- **It refuses to start if it has nothing to watch.** An empty or nonexistent
  `WATCH_PATH_CONVERT` is reported and figleaf exits instead of running blind.
  That failure used to be silent and total: `fswatch` sits on a missing
  directory without erroring, and startup reconciliation sent `find`'s error to
  `/dev/null`, so figleaf printed a healthy startup — including "No figure
  masters need reconciling" — while being structurally unable to see a figure.
  An existing-but-empty tree only warns; that is normal for a new project.
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
- **A figure is only marked processed if its pushes succeeded.** If a push does
  not land, the hash is deliberately not recorded and figleaf says so, so the
  figure is retried on the next change or the next run. Otherwise a figure whose
  push failed would be marked done for good and Overleaf would silently keep the
  stale version.
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

Both scripts retry automatically, up to `PUSH_MAX_ATTEMPTS` times. Two shapes of
rejection are recognised: the usual non-fast-forward, and the tighter race where
the remote advances while the push is in flight (`cannot lock ref … is at X but
expected Y`). A failure that retrying cannot fix — authentication, network, a
rejecting hook — is reported immediately rather than retried.

Three things make the retry work in practice:

- **Exponential backoff with jitter.** The wait doubles each attempt (from
  `PUSH_RETRY_SLEEP`, capped at `PUSH_RETRY_MAX_SLEEP`) and its second half is
  randomised. A *fixed* delay was the original problem: the bridge commits every
  few seconds, so retrying on a fixed 3-second beat ran in lock step with the
  remote and lost every race — observed losing 5 for 5 against a burst of 8
  commits in 31 seconds.
- **It waits for a gap instead of guessing at one.** Before retrying, the
  scripts poll `git ls-remote` (a cheap, ref-only call) until Overleaf's ref
  holds still for `PUSH_QUIET_SECONDS`, then pull and push into that gap. This
  spends the same backoff budget but returns the moment a real gap opens.
  Set `PUSH_QUIET_SECONDS=0` to disable the gate and use the blind sleep.
- **Running out of attempts is not fatal.** figleaf reports it and keeps
  watching. The commit is already safe in the local clone, so nothing is lost;
  when the project next goes quiet, the idle loop pushes it (at most
  `FLUSH_INTERVAL_SECONDS` later) and says so.

  > This one used to call `exit`. A transient, self-healing race killed the
  > watcher, turning a delay of a minute into a sync that had silently stopped
  > until somebody noticed figleaf was gone.

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
| `PUSH_MAX_ATTEMPTS` | `6` | Attempts before deferring a push the remote keeps rejecting |
| `PUSH_RETRY_SLEEP` | `3` | First wait between attempts; each later one doubles |
| `PUSH_RETRY_MAX_SLEEP` | `60` | Cap on that doubling |
| `PUSH_QUIET_SECONDS` | `4` | How long Overleaf's ref must hold still to count as a gap; `0` disables the gate |
| `PUSH_QUIET_MAX_WAIT` | `30` | Longest wait for a gap before pushing anyway |
| `FLUSH_INTERVAL_SECONDS` | `60` | How often the idle loop retries commits a deferred push left behind |
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
- `run/` — scratch files for running watchers (the `fswatch` event stream and
  the last-successful-pull marker).

  > These used to live in `/tmp`, which macOS sweeps nightly via
  > `/usr/libexec/tmp_cleaner`: it deletes anything whose atime, mtime *and*
  > ctime are all more than three days old. Both files are only touched when a
  > figure changes, and the poll loop reads the event file with `wc -c` — an
  > `fstat` that does not refresh atime — so a quiet stretch of a few days was
  > enough for the cleaner to delete them out from under a *running* watcher.
  > `fswatch` then kept writing to an unlinked inode and no change was ever seen
  > again. The watchers now also rebuild these files and restart `fswatch` if
  > they vanish anyway.

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

### Run figleaf on one machine per project

Two figleaf instances on the same project watch the same shared figure tree and
both push, so they race each other as well as Overleaf, and both convert the
same masters. Pick one machine to push figures from; run `offleaf.sh` on the
others. Nothing in the code enforces this.

`leafsync.sh` does now protect the *setup* half of that mistake. A project is
identified by its Overleaf ID, never by the name you type at the prompt, so
entering a different name on a second machine no longer creates a second figure
tree or a second config. An existing clone or figure tree for that ID is adopted
whatever it is named, and the committed `FIGURES_SUBPATH` wins over the name you
typed; renaming requires explicit confirmation and moves the tree.

> Previously, entering a different name on a second machine created a whole
> second tree on the shared drive — empty, since the masters are in the first
> one — and overwrote the committed config to point *every* machine at it. The
> symptom was a watcher that started cleanly and never saw a figure again.

### Simultaneous editors are the real limit

Overleaf's git bridge gives one serialised ref to two unrelated activities:
people typing prose, and figleaf delivering binaries. A push is a
compare-and-swap on that ref, and the costs are asymmetric — one attempt costs
6–9 seconds (pull, then push multi-megabyte binaries), while the bridge mints a
commit every few seconds for free, per active typist.

If each editor produces a bridge commit every ~τ seconds and a push cycle takes
W, one attempt survives with probability roughly `e^(−N·W/τ)`. With measured
W ≈ 7 s and τ ≈ 7 s:

| Simultaneous editors | A figure lands (6 attempts) |
| --- | --- |
| 1 | ~80% |
| 2 | ~50% |
| 3 | ~20% |
| 4 | ~5% |

The retry machinery above makes a lost race a **delay** rather than a failure —
the commit waits locally and goes up at the next lull — but it cannot raise
those odds much, and no amount of tuning will: bursts can always be longer, and
contention grows with the number of people typing. Expect figure delivery to be
late, sometimes very late, during a busy multi-editor session.

The structural fix is to stop making figures contend with prose on one ref:
put figures in a **separate Overleaf project** referenced by cross-project file
linking, or use Overleaf's linked-files-from-external-source feature, so figure
delivery never touches the prose repo. That also stops the prose repo
accumulating a permanent binary blob for every version of every figure — worth
watching, since a project's `.git` can reach hundreds of megabytes this way and
Overleaf enforces repository size limits.

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
