# The desktop GUI (`ytdl-gui`)

**Optional.** Nothing else in this project depends on it. `ytdl` and
`ytdl-view` behave exactly the same whether or not it is installed, and the
installer skips building it without complaint when Rust is absent.

It is one window over the whole project: start downloads and watch them, queue
several, read the run history, browse the archive, and check that the pipeline
around it is healthy.

## What it is, and what it deliberately is not

It does **not** reimplement the pipeline. Starting a download builds a `ytdl`
command line and hands it to the installed `scripts/ytdl.ps1` — the single
argument parser, on every platform — exactly as a terminal would. Every
control maps one-to-one onto a flag `ytdl.ps1` already accepts, and the window
shows you the command before it runs it:

```
ytdl "https://www.youtube.com/@SomeChannel/videos" --sync --workers 3
```

That preview is rendered by the same Rust function that builds the real
argument list, not by a second copy of the logic in JavaScript, so it cannot
drift from what actually runs.

It **does** own its archive browsing. The library, comment threading,
transcript parsing and playback decisions are a native reimplementation of
what `archive-viewer.py` does in Python. That duplication is real and has a
cost: the archive layout now has three consumers to keep in step —
`postprocess.ps1` writes it, `archive-viewer.py` reads it, and
`src-tauri/src/archive.rs` reads it. The notes at the top of `src-tauri/src/archive.rs`
say what must stay equivalent.

The invariants it inherits from `archive-viewer.py`, none of them negotiable:

- **The archive is read-only.** Nothing is created, moved or modified under
  `Youtube Videos/`. `postprocess.ps1` writes a `checksums.sha256` covering
  every file in a video folder, so a derived file dropped in there would make
  that manifest stop verifying. Everything derived — the metadata index, the
  split-out comment files, playback copies — lives in a cache directory
  outside the archive.
- **The window never sends a filesystem path.** Content is addressed by an
  opaque key plus an index into a server-side file list, and the resolved path
  is re-checked against the video folder before anything is opened. There is
  no route that takes a path, which is what keeps traversal off the table
  rather than a filter that has to be right.
- **Nothing is re-encoded without being asked.**

## Installing

This repo installs **both halves**. `setup.sh` (Linux and macOS) or
`setup.ps1` (Windows) runs in two phases:

- **Phase 1** installs the pipeline, by downloading and running the
  `orchid-ochre` installer at the ref pinned in `CLI_VERSION`.
  This repo carries no copy of the pipeline; the GUI shells out to the
  installed `ytdl` and reads the archive `postprocess.ps1` writes.
- **Phase 2** builds this app and puts `ytdl-gui` on PATH.

The two phases keep their own step numbering. The pipeline installer declares
its own `TOTAL_STEPS` and its test suite asserts its three halves agree on it,
so renumbering its output from the outside would break an invariant this repo
does not own.

Rust is **not** installed by default. The pipeline installer installs pwsh,
deno, Node and yt-dlp without asking because those are dependencies of
*downloading*, the thing you came for; a Rust toolchain is a dependency only
of this window, it is ~1.5 GB, and rustup's installer is another unverified
curl-to-shell of the kind the pipeline's `SECURITY.md` already accounts for
one instance of. Fetching that silently because you typed `./setup.sh` is a
different bargain, so it is a flag rather than the default.

**`--install-rust` is that flag**, and with it the install is one command:

```
sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev librsvg2-dev patchelf   # Linux only
./setup.sh --install-rust
```

On Windows, `.\setup.ps1 -InstallRust`. The flag installs rustup's stable
toolchain with the **minimal** profile — rustc, cargo and the standard
library, without rust-docs, clippy or rustfmt, none of which this app builds
with. `rustup component add clippy rustfmt` gets them back. If rustup is
already installed the flag updates the stable toolchain instead, and if
`cargo` came from somewhere that is not rustup — a distro package, Homebrew —
it is left alone rather than shadowed by a second toolchain.

No new terminal is needed at any point. rustup's only PATH wiring is a line
appended to your shell profile, which the already-running shell will never
re-read; both bootstraps source the toolchain into their own process instead
and export it to the build. That also means installing Rust **by hand** and
re-running works in the same terminal: the prerequisite check looks in
`$CARGO_HOME`/`~/.cargo/bin` as well as on `PATH`.

Doing it by hand, from a clone:

1. Install Rust, if you have not already:

   ```
   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o rustup.sh
   sh rustup.sh -y
   ```

   `-y` matters: without it the installer stops on an interactive menu.

2. On **Linux only**, install the system webview. Tauri uses the OS's own
   webview rather than shipping a browser, and on Linux that is a system
   library cargo cannot fetch:

   ```
   sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev librsvg2-dev patchelf   # Debian/Ubuntu
   sudo dnf install webkit2gtk4.1-devel gtk3-devel librsvg2-devel              # Fedora
   ```

   macOS uses WKWebView and Windows uses WebView2; both are already there.
   On Windows the MSVC toolchain also needs the Visual Studio C++ build
   tools to link; rustup does not install those, and `-InstallRust` warns
   when it cannot find them.

3. Run `./setup.sh` (or `setup.ps1` on Windows).

Then `ytdl-gui`.

The toolchain minimum is `rust-version` in `src-tauri/Cargo.toml` (1.77).
The installer checks it up front and names `rustup update stable`, rather
than letting cargo fail on it later with a message that names neither.

With `--install-rust` on Linux the webview check runs **before** the
download, so a missing `libwebkit2gtk-4.1-dev` stops you in seconds rather
than after 1.5 GB of toolchain you could not have used.

A first build compiles several hundred crates and takes minutes. Rebuilds
after an edit take seconds.

### If the pipeline is already installed

`./setup.sh --skip-cli` skips phase 1 entirely and just adds the window.

### Pinning the pipeline

`CLI_VERSION` records which pipeline ref this GUI is built against, and the
archive layout version it can read. `--cli-ref REF` overrides the ref for one
run. Setting `CLI_REF` to a tag rather than `main` is the point of the file:
`main` means "whatever was pushed most recently", which is the version skew
the pin exists to remove.

### Building by hand

The installer's phase 2 is not much more than:

```
cargo build --release --manifest-path src-tauri/Cargo.toml
```

and the binary lands at `src-tauri/target/release/ytdl-gui`.

### Packaged installers

`src-tauri/tauri.conf.json` carries a complete bundle configuration, so
`cargo tauri build` produces a `.dmg`, `.msi`/`.exe` or `.AppImage`/`.deb`
depending on which platform you run it on. That path is configured but **not
exercised** — see Verification status below. Each installer has to be built on
the platform it targets; there is no cross-compilation here.

## The panes

### Download

A profile selector, the URL, the destination, options, and the command
preview. The options are exactly `ytdl.ps1`'s, in three groups.

**The destination** sits under the URL rather than inside the collapsed
options block, because it is not an advanced flag — it is where the files go.
It is the per-run `--path`; leaving it empty uses the data root from Settings,
and leaving that empty uses the pipeline's own default, which is the install
root. **Choose…** opens the platform's folder picker, **Open** opens the
resolved folder in the file manager, and the line underneath says what the
typed path actually resolves to: whether it exists, whether an archive was
found in it, and what `~` expanded to.

That last part was a real bug and not only a convenience. `run_ytdlp.ps1`
resolves `-DataRoot` with `[System.IO.Path]::GetFullPath`, which has no notion
of a home directory, so `~/Videos` reached it as a literal folder called `~`
under the pipeline process's working directory — while this app's own path
handling *did* expand it. The same typed path therefore meant two different
folders: the Library indexed one and the downloads went to the other, with
nothing reporting an error. The expansion now happens once, in
`RunOptions::to_args`, at the point a path leaves this process.

**Profiles** are every option on this page except the URL, saved under a name.
Pick one from the dropdown and every control below is set from it; change
anything and the bar says *unsaved changes*, at which point **Save** overwrites
that profile and **Revert** puts it back. **Save as…** names a new one,
**Rename** and **Delete** do what they say, and the profile in use when the
window closed is restored the next time it opens.

A profile is stored as a `RunOptions` — the same struct the runner takes —
which is why there is no list of profiled fields anywhere in the code: an
option added to the pipeline and wired up here becomes profileable without
anything else being updated, and a profile written before an option existed
simply does not set it. The URL is never stored, because a preset that quietly
replaced what you were about to download would be the one thing a preset must
never do.

Profiles live in `profiles.json` beside `settings.json` in the config
directory, written through a temp file and renamed — losing a set of profiles
built up over months is losing real work, unlike the five values in
`settings.json`.

**Session** — `--sync`, `--items`, `--after`, `--lazy`, `--workers`,
`--no-pot`, `--skip-pot-update`, `--pot-port`. Each carries the same caveat it
has in `docs/ytdl-usage.md`: `--sync` is only safe for newest-first listings,
`--lazy` does nothing when workers > 1, and raising workers multiplies your
aggregate request rate at YouTube.

**What to download** — `--mode`, `--quality`, `--codec`, `--container`, and
`--audio-codec`. `--mode audio-only` writes `Final Audio.<ext>` instead of
`Final Video.<ext>`; the metadata-only, comments-only and subs-only modes
download no media at all and still write the complete per-video folder around
it. `--codec` is a preference, not a filter — a video that offers no `avc1`
rendition still downloads.

**Leaving components out** — `--no-comments`, `--no-subs`, `--no-thumbnail`,
`--no-metadata`, plus the `--no-audio` / `--no-video` aliases for the two
single-stream modes. Below them, a box for raw `--ytdlp-arg` values, one per
line (one per line rather than space-separated because a real
`--match-filter` expression contains spaces and commas).

Options a mode makes meaningless are greyed out rather than hidden, with a
line saying why — `--quality` against `--mode comments-only`, for instance.
The window disables them rather than reproducing the pipeline's rejection
rules, so those rules stay written down in exactly one place: `ytdl.ps1`
refuses the combination if one reaches it anyway, and the error appears in the
run log like any other pipeline error.

Nothing in this window builds a yt-dlp format selector or knows that
`Final Audio` exists. Each control maps to one `ytdl` flag and the meaning
lives in `run_ytdlp.ps1`, on the far side of the `CLI_VERSION` pin — so
changing what a mode means is a pipeline change this window inherits without a
release of its own.

Below it, live output. yt-dlp redraws its progress line with a carriage return
and `yt-dlp.conf` sets no `--newline`, so the app reads the child's output
byte-wise and splits on both `\n` and `\r`: progress updates replace the
previous line instead of appending, and one download does not produce
thousands of near-identical log lines.

Cancelling kills the whole process tree, not just the child. `ytdl.ps1` starts
`run_ytdlp.ps1` as a child `pwsh`, which starts yt-dlp, which starts
`postprocess.ps1` and ffmpeg; killing only the top process would leave a
download running with nothing reading its output. On Unix the run gets its own
process group and the group is signalled; on Windows `taskkill /T` does it.

### Queue & history

**The queue runs strictly one at a time, and that is not a limitation to be
fixed.** Independent `ytdl` invocations race on shared state —
`global_manifest.json`, the channel manifests, the Channel Info refresh
throttle, `download.log` itself. `--workers N` is the supported way to get
real parallelism, because it enumerates every video up front so no two workers
are assigned the same one, and `postprocess.ps1` has matching file locking.
So "several at once" is the workers spinner; the queue never starts a second
process.

History rows carry the counts from `run_ytdlp.ps1`'s own session summary line
(videos touched, already-archived skips, errors, warnings) plus the exit code.
The queue and history survive restarts.

### Library

The archive, indexed. It tolerates the states a real run produces: a missing
or unparseable `info.json` (it falls back to parsing
`<uploader> - <date> - <id> - <title>` off the folder name, which is a
documented, stable part of the layout rather than a guess), a folder with no
video file at all, and `Pre-merge streams/` — which is skipped when choosing
the video, since `--keep-video` leaves video-only and audio-only files that
would otherwise be mistaken for the real one.

A video page gives you the player, threaded comments, a clickable transcript
that follows playback, description and chapters with seek links, the full
metadata, and the file list. **Verify checksums** re-hashes every file in the
folder against its own `checksums.sha256`.

Comments are threaded from the flat list yt-dlp writes, whose `parent` field
is either `"root"` or a parent id, in no guaranteed order — so a reply can
appear before its parent. A reply whose parent is genuinely absent (a deleted
comment, a truncated fetch) is shown at top level rather than dropped.

Transcripts strip the inline karaoke timestamps and collapse the rolling
two-line repetition in YouTube's auto-generated VTT, which is otherwise
unreadable as prose. Auto-generated tracks are told apart from human-written
ones by their *contents*, not their filenames — `--write-subs` and
`--write-auto-subs` both land in `Subtitles/` under the same base name.

#### About playback

`.mkv` cannot be played by any browser engine, and this pipeline produces
almost nothing else. Three outcomes, in order of cost:

1. **Direct.** VP8/VP9/AV1 + Opus/Vorbis inside Matroska is byte-compatible
   with WebM, so it is served straight from the archive with a WebM content
   type and costs nothing.
2. **A container rewrite.** `--merge-output-format mkv` writes an EBML header
   whose DocType is `matroska`. A strict demuxer reads that before it reads
   codecs and refuses the file even when the streams are perfectly playable.
   The app then stream-copies into a real `.webm` — every packet copied
   verbatim, only the header changed. This happens **automatically**, because
   there is nothing for you to weigh up: it is lossless and takes seconds.
3. **A re-encode.** Only ever offered as an explicit button, never automatic,
   and never for anything that could have been copied instead.

If all three fail, the app says so plainly and points you at **Open in
mpv/VLC** — mpv plays every codec combination this pipeline can produce and
reads the embedded subtitles and chapters.

Playback copies go to the cache directory, never into the archive.

### Health

Read-only, on purpose. It reports dependency versions and paths, which
pipeline files are actually installed (the repo holds the *sources*; editing a
file in a clone changes nothing until it is copied over), the PO token
provider's state, the installed `yt-dlp.conf` with its `CONFIG_VERSION`, and
archive statistics.

It does not install or update anything. `run_ytdlp.ps1` runs its own
once-per-24h dependency check, and a second updater racing it from a GUI is
exactly the kind of shared-state collision the rest of this project is built
to avoid.

**What it costs to open.** This pane used to be one command that did
everything and one `await` that waited for all of it, so the slowest
`--version` call on the machine decided when the first pixel appeared. It is
now two commands and three independent fills:

- The **dependency probe** spawns its seven `--version` subprocesses in
  parallel rather than one after another, gives each 8 seconds before killing
  it (a tool found on PATH that never answers is reported as found with no
  version, and the card says which), and the result is cached for five
  minutes. **Refresh** skips the cache — that is what it is for, and it is
  what you want after installing something that was missing.
- The **cheap half** — installed files, `yt-dlp.conf`, PO token state, archive
  statistics — paints immediately. The three archive counts used to be taken
  by building the entire library and measuring it, which clones every title,
  uploader and file list in the archive and throws all of it away; they are
  now counted from the index directly.
- **Log tails** are read by seeking to the end of the file. `download.log` is
  appended to by every run and never rotated, so reading it whole to keep the
  last 300 lines made this pane's cost grow with the age of the install, for a
  panel whose content is a fixed 300 lines.

Re-entering the tab repaints from what the last visit fetched instead of
starting over.

### Settings

Data root (the `ytdl --path` equivalent, and the default destination for every
download that does not set its own), an archive-root override for when
autodetection guesses wrong, default worker count, whether re-encoding is
offered at all, and the theme. Both path boxes have the same **Choose…**,
**Open** and resolved-path line as the Download pane's destination.

Saving a *changed* data or archive root re-indexes the library. Without that
the index in memory is still the old root's, so the Library keeps showing
videos from a folder the app is no longer pointed at — which reads as the
setting not having taken.

Settings, profiles, queue and history live in a platform config directory; the
index and playback copies live in a platform cache directory. The cache is
disposable — deleting it costs one re-index.

## Where things live

| | Linux | macOS | Windows |
|---|---|---|---|
| Source | this clone | this clone | this clone |
| Binary | `src-tauri/target/release/ytdl-gui` | same | `…\ytdl-gui.exe` |
| Settings, queue, history | `~/.config/ytdlp-gui` | `~/Library/Application Support/ytdlp-gui` | `%LOCALAPPDATA%\ytdlp-gui` |
| Index and playback copies | `~/.cache/ytdlp-gui` | `~/Library/Caches/ytdlp-gui` | `%LOCALAPPDATA%\Cache\ytdlp-gui` |

`YTDLP_INSTALL_ROOT` overrides the install root here as it does everywhere
else in the project.

The cache is deliberately a *different* directory from
`archive-viewer.py`'s `ytdlp-archive-viewer`: the two index formats are not
the same, and sharing a directory would mean each tool treating the other's
files as corrupt.

## Dependencies

Four crates: `tauri`, `serde`, `serde_json`, `sha2`, plus `libc` on Unix for
the process-group kill. No regex crate (hand-rolled scanners), no `walkdir`
(a recursive `read_dir`), no `rand` (pid plus a counter), no HTTP client
(nothing here talks to the network), no date library.

The frontend is plain HTML, CSS and ES2020 with **no build step and no
`package.json`** — `withGlobalTauri` exposes the API on `window`, so there is
no bundler, no `npm install`, and no lockfile. That was the point: choosing
Tauri already spends this project's "no build system" principle once, and
spending it again on a JavaScript toolchain would have made the GUI by far the
largest supply-chain surface in a repo that otherwise has almost none.

The capability set grants core window and event permissions and nothing else.
There is no filesystem plugin and no shell plugin, so the frontend cannot read
a path or run a command even in principle — it can only call the specific
commands `main.rs` chose to expose.

## Verification status

Honest, and narrower than the rest of this document might suggest:

- **Linux**: built and run. The window, the library index, comment threading,
  transcript parsing, the media protocol, the automatic WebM container
  rewrite, dependency detection and the health pane were all exercised against
  a fabricated archive and confirmed by screenshot.
- **Decode itself was never verified.** The test container has no audio device
  at all, so WebKitGTK cannot construct a playback pipeline and every video
  errors regardless of the file. The container rewrite was confirmed correct
  by inspecting the file it produced (valid VP9/Opus, DocType `webm`), not by
  watching it play.
- **No real download has ever been started through this window.** YouTube is
  unreachable from the environment it was built in. The command construction
  and process handling are covered by reasoning and by the pipeline's own test
  suite, not by a real run.
- **macOS and Windows have never been built or run**, matching the rest of the
  project. The platform branches — install root, launcher shape, `taskkill`
  instead of a process-group signal, and the `http://media.localhost` URL form
  that Windows rewrites custom schemes into — are reviewed and statically
  checked only.
- **The packaged-installer path is configured but unexercised.**

If you run it on macOS or Windows and something breaks, that is expected
rather than surprising, and the platform branch is the first place to look.
