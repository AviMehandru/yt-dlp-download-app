# ytdl-gui

A desktop front end for the [yt-dlp archival
pipeline](https://github.com/AviMehandru/orchid-ochre): start
downloads and watch them, queue several, read the run history, browse the
archive, and check the health of the pipeline underneath.

**This repo is the app. The pipeline lives in its own repo, and this one
installs it.** `./setup.sh` runs in two phases — phase 1 installs the
pipeline at the ref pinned in `CLI_VERSION`, phase 2 builds this app on top.
If you only want the command line, install the pipeline directly and ignore
this repo entirely.

## What it does, and does not, own

It does **not** reimplement downloading. Starting a download builds a `ytdl`
command line and hands it to the installed `ytdl.ps1` — the pipeline's single
argument parser — exactly as a terminal would, and the window shows the
command before it runs it.

It **does** own reading the archive: the library index, comment threading,
transcript parsing and playback decisions are native Rust here. That is a
duplicate of what the pipeline's `archive-viewer.py` does in Python, and the
duplication is the price of one integrated window instead of a shell around a
second server.

Because the two halves are versioned separately, the archive layout is a
**contract**, not an assumption. The pipeline records
`archive_layout_version` in every `manifest.json`; this app records the
highest it can read in `SUPPORTED_ARCHIVE_LAYOUT` and in `CLI_VERSION`. A
video written by a newer pipeline is listed and visibly flagged rather than
silently missing, and `cargo test` fails here the moment the contract moves.
See `docs/archive-layout.md` in the pipeline repo.

## Install

Needs a Rust toolchain and, on Linux, the WebKitGTK development packages.
Rust is not installed by default — it is a dependency only of this window,
not of downloading — but `--install-rust` opts in, and the whole install then
runs as one command in one terminal.

```
./setup.sh                     # installs the pipeline, then builds the app
./setup.sh --install-rust      # ... and installs Rust too, if it is missing
./setup.sh --skip-cli          # pipeline already installed; just add the window
```

On Windows the switch is `-InstallRust`. If you install Rust yourself
instead, you do not need to open a new terminal before re-running: the
installer looks in `~/.cargo/bin` as well as on `PATH`.

Then:

```
ytdl-gui
```

Full instructions, the panes, playback behaviour and the verification status
are in [`docs/gui-usage.md`](docs/gui-usage.md).

## Building and testing

```
cargo build --release --manifest-path src-tauri/Cargo.toml
cargo test  --manifest-path src-tauri/Cargo.toml
```

The tests are conformance tests against the archive layout: they build a
fixture tree in the documented shape and assert this reader still finds it,
including the states the contract says a consumer must tolerate — a missing
`info.json`, a folder with no video file, and `Pre-merge streams/`.

## Status

Built and run on Linux only. macOS and Windows are supported in code and have
never been executed, matching the pipeline project. Playback decode was never
verified in the build environment. See the verification section of
`docs/gui-usage.md`, which is deliberately specific about what was and was not
actually run.
