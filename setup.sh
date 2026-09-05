#!/usr/bin/env bash
#
# Installer for the yt-dlp archive desktop GUI -- Linux and macOS.
#
# TWO PHASES, and the split is the whole architecture:
#
#   Phase 1  installs the PIPELINE, by downloading and running the
#            yt-dlp-download-automator installer at the ref pinned in
#            CLI_VERSION. This repo does not contain a copy of the
#            pipeline and never should: a vendored copy is a copy that
#            drifts, and the GUI's entire relationship with the pipeline
#            is that it shells out to the installed `ytdl` and reads the
#            archive `postprocess.ps1` writes.
#
#   Phase 2  builds and installs the GUI on top, via
#            scripts/setup-gui.ps1.
#
# The two phases keep their OWN step numbering rather than trying to
# present one continuous 1..N. The pipeline installer declares its own
# TOTAL_STEPS and asserts internally that its three halves agree on it
# (its 070-installer suite enforces exactly that), so renumbering its
# output from the outside would mean either patching a file this repo
# does not own or breaking an invariant it does own. Two clearly labelled
# phases are honest and cost nothing.
#
# DELIBERATELY NO `set -e`, matching the pipeline installer's own
# convention: every fallible step warns and continues, because a
# half-placed install is worse than a complete one with a warning list.

WARNINGS=()
warn() {
    echo "WARNING: $*"
    WARNINGS+=("$*")
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SKIP_CLI=0
INSTALL_RUST=0
CLI_REF_OVERRIDE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-cli)
            # For a machine that already has a working `ytdl` and only
            # wants the window added on top.
            SKIP_CLI=1; shift ;;
        --install-rust)
            # OPT-IN, and it stays opt-in. See the Phase 1.5 block below
            # for why this is a flag and not the default.
            INSTALL_RUST=1; shift ;;
        --cli-ref)
            CLI_REF_OVERRIDE="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: ./setup.sh [--skip-cli] [--install-rust] [--cli-ref REF]"
            echo
            echo "  --skip-cli      Do not install the pipeline; assume it is already there."
            echo "  --install-rust  Install or update the Rust toolchain needed to build the"
            echo "                  GUI (~1.5 GB) instead of stopping with instructions."
            echo "  --cli-ref REF   Install this pipeline ref instead of the one in CLI_VERSION."
            exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: ./setup.sh [--skip-cli] [--install-rust] [--cli-ref REF]" >&2
            exit 1 ;;
    esac
done

# --- Read the pin -----------------------------------------------------
PIN_FILE="$SCRIPT_DIR/CLI_VERSION"
if [ ! -f "$PIN_FILE" ]; then
    echo "ERROR: CLI_VERSION is missing from $SCRIPT_DIR." >&2
    echo "It records which pipeline this GUI expects; without it the install would be a guess." >&2
    exit 1
fi
# Comments and blank lines stripped; everything else is KEY=VALUE.
CLI_REPO="$(grep -E '^CLI_REPO=' "$PIN_FILE" | head -1 | cut -d= -f2-)"
CLI_REF="$(grep -E '^CLI_REF=' "$PIN_FILE" | head -1 | cut -d= -f2-)"
REQUIRES_ARCHIVE_LAYOUT="$(grep -E '^REQUIRES_ARCHIVE_LAYOUT=' "$PIN_FILE" | head -1 | cut -d= -f2-)"
[ -n "$CLI_REF_OVERRIDE" ] && CLI_REF="$CLI_REF_OVERRIDE"

if [ -z "$CLI_REPO" ] || [ -z "$CLI_REF" ]; then
    echo "ERROR: CLI_VERSION does not define CLI_REPO and CLI_REF." >&2
    exit 1
fi

echo "==============================================================="
echo " yt-dlp archive -- desktop GUI installer"
echo "==============================================================="
echo " pipeline : $CLI_REPO @ $CLI_REF"
echo " layout   : requires archive layout v$REQUIRES_ARCHIVE_LAYOUT"
echo

# --- Phase 1: the pipeline -------------------------------------------
echo ">>> Phase 1 of 2: installing the pipeline"
echo

if [ "$SKIP_CLI" -eq 1 ]; then
    echo "Skipping (--skip-cli). Assuming 'ytdl' is already installed."
else
    RAW_BASE="https://raw.githubusercontent.com/$CLI_REPO/$CLI_REF"
    TMP_DIR="$(mktemp -d)"
    CLI_SETUP="$TMP_DIR/setup.sh"

    # Downloaded to a FILE and then run, never piped into a shell. `curl
    # ... | sh` returns the shell's exit code rather than curl's, so a
    # failed download feeds sh an empty script, sh exits 0, and a failed
    # install is reported as a success. The pipeline repo learned this the
    # hard way; there is no reason to relearn it here.
    if ! curl -fsSL "$RAW_BASE/setup.sh" -o "$CLI_SETUP"; then
        echo "ERROR: could not download the pipeline installer from $RAW_BASE/setup.sh" >&2
        echo "Check the network, and that CLI_REF ('$CLI_REF') names a real branch or tag." >&2
        rm -rf "$TMP_DIR"
        exit 1
    fi
    # A proxy or captive portal can answer 200 with its own HTML page,
    # which curl -f does not catch. None of these files is HTML.
    if [ ! -s "$CLI_SETUP" ] || head -1 "$CLI_SETUP" | grep -qiE '^\s*<(!doctype|html)'; then
        echo "ERROR: the downloaded pipeline installer is empty or is an HTML page." >&2
        echo "Something (a proxy, captive portal, or DNS interception) answered instead of GitHub." >&2
        rm -rf "$TMP_DIR"
        exit 1
    fi

    chmod +x "$CLI_SETUP"
    echo "Running the pipeline installer ($CLI_REPO @ $CLI_REF)."
    echo "Its step numbering below is its own; this is Phase 1 of 2."
    echo
    bash "$CLI_SETUP"
    CLI_STATUS=$?
    rm -rf "$TMP_DIR"
    if [ $CLI_STATUS -ne 0 ]; then
        # Fatal, unlike most things here. The GUI drives the installed
        # ytdl.ps1; without a pipeline there is nothing for it to drive,
        # and a window that cannot download is worse than no window.
        echo >&2
        echo "ERROR: the pipeline installer exited with status $CLI_STATUS." >&2
        echo "The GUI drives the installed pipeline, so it is not installed either." >&2
        echo "Fix the pipeline install first, then re-run this with --skip-cli." >&2
        exit $CLI_STATUS
    fi
fi

# --- Locate the install ----------------------------------------------
# Must agree with the pipeline's own platform block: YTDLP_INSTALL_ROOT
# wins everywhere, then ~/yt-dlp on Linux and macOS.
if [ -n "$YTDLP_INSTALL_ROOT" ]; then
    INSTALL_ROOT="$YTDLP_INSTALL_ROOT"
else
    INSTALL_ROOT="$HOME/yt-dlp"
fi
LOCAL_BIN="$HOME/.local/bin"

if [ ! -f "$INSTALL_ROOT/scripts/ytdl.ps1" ]; then
    echo >&2
    echo "ERROR: no pipeline found at $INSTALL_ROOT (scripts/ytdl.ps1 is missing)." >&2
    echo "The GUI has nothing to drive. Install the pipeline first:" >&2
    echo "  https://github.com/$CLI_REPO" >&2
    exit 1
fi

# --- The layout contract ---------------------------------------------
# An install-time sanity check, not the real guard. The real one is per
# video at runtime in src-tauri/src/archive.rs, because an archive written
# across an upgrade legitimately contains more than one layout version.
INSTALLED_LAYOUT="$(grep -E '^\$ArchiveLayoutVersion\s*=' "$INSTALL_ROOT/scripts/postprocess.ps1" 2>/dev/null | head -1 | grep -oE '[0-9]+')"
if [ -z "$INSTALLED_LAYOUT" ]; then
    # Pre-dates the contract. That is layout 1 by definition.
    INSTALLED_LAYOUT=1
    echo "Note: the installed pipeline predates archive layout versioning; treating it as v1."
fi
if [ -n "$REQUIRES_ARCHIVE_LAYOUT" ] && [ "$INSTALLED_LAYOUT" -gt "$REQUIRES_ARCHIVE_LAYOUT" ]; then
    warn "The installed pipeline writes archive layout v$INSTALLED_LAYOUT, but this GUI understands up to v$REQUIRES_ARCHIVE_LAYOUT. Newer videos may not appear in the library. Update the GUI, or pin CLI_REF to a pipeline release that matches."
fi

# --- Phase 1.5: the Rust toolchain, only if asked ---------------------
# NOT numbered as a phase of its own, because on the default path it does
# not exist: without --install-rust this block is skipped entirely and the
# behaviour is exactly what it always was.
#
# Why opt-in rather than automatic. Phase 1 installs pwsh, deno, Node and
# yt-dlp without asking because those are dependencies of DOWNLOADING --
# the thing the user came for. A Rust toolchain is a dependency only of
# the window, it is ~1.5 GB, and rustup's installer is an unverified
# curl-to-shell. Fetching that silently because someone typed ./setup.sh
# is a different bargain from the one Phase 1 makes, so it gets a flag.
# What the flag removes is the manual dance, not the consent.
CARGO_BIN="${CARGO_HOME:-$HOME/.cargo}/bin"
# Do this unconditionally: a toolchain installed by hand in this same
# terminal is on disk but not on PATH until the profile is re-read, and
# that alone was the old "close this window and open a new one" step.
if [ -d "$CARGO_BIN" ]; then
    case ":$PATH:" in
        *":$CARGO_BIN:"*) ;;
        *) PATH="$CARGO_BIN:$PATH"; export PATH ;;
    esac
fi

if [ "$INSTALL_RUST" -eq 1 ]; then
    echo
    echo ">>> Rust toolchain (--install-rust)"
    echo

    # Checked BEFORE the download, not after. On Linux the webview is a
    # system library cargo cannot fetch, so without it the build fails no
    # matter what rustup does -- and finding that out after 1.5 GB is a
    # bad way to spend ten minutes. setup-gui.ps1 checks this too; that
    # copy is the real one, this is only about download ordering.
    if [ "$(uname -s)" = "Linux" ]; then
        if ! command -v pkg-config >/dev/null 2>&1 || ! pkg-config --exists webkit2gtk-4.1 2>/dev/null; then
            echo "ERROR: the WebKitGTK development files are missing, so the GUI cannot be" >&2
            echo "built even with Rust installed. Not downloading a toolchain you cannot use." >&2
            echo >&2
            echo "  Debian/Ubuntu: sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev librsvg2-dev patchelf" >&2
            echo "  Fedora:        sudo dnf install webkit2gtk4.1-devel gtk3-devel librsvg2-devel" >&2
            echo >&2
            echo "Then re-run: ./setup.sh --skip-cli --install-rust" >&2
            exit 1
        fi
    fi

    if command -v rustup >/dev/null 2>&1; then
        echo "rustup is already installed; updating the stable toolchain."
        rustup update stable || warn "'rustup update stable' failed. Building with whatever toolchain is already there."
    elif command -v cargo >/dev/null 2>&1; then
        # A distro or Homebrew rustc. Running rustup-init over it installs
        # a SECOND toolchain that shadows the first, which is a confusing
        # thing to do to someone's machine without being asked to.
        echo "cargo is already on PATH but was not installed by rustup: $(command -v cargo)"
        echo "Leaving it alone. setup-gui.ps1 will check whether it is new enough."
    else
        RUSTUP_TMP="$(mktemp -d)"
        RUSTUP_SH="$RUSTUP_TMP/rustup-init.sh"

        # Downloaded to a FILE and then run, for the same reason as the
        # pipeline installer above: `curl ... | sh` returns the shell's
        # exit code, so a failed download becomes a silent success.
        if ! curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o "$RUSTUP_SH"; then
            echo "ERROR: could not download the rustup installer from https://sh.rustup.rs" >&2
            rm -rf "$RUSTUP_TMP"
            exit 1
        fi
        if [ ! -s "$RUSTUP_SH" ] || head -1 "$RUSTUP_SH" | grep -qiE '^\s*<(!doctype|html)'; then
            echo "ERROR: the downloaded rustup installer is empty or is an HTML page." >&2
            echo "Something (a proxy, captive portal, or DNS interception) answered instead." >&2
            rm -rf "$RUSTUP_TMP"
            exit 1
        fi

        # -y                 : no interactive prompt. Without it the
        #                      installer stops on "1) Proceed with standard
        #                      installation" and a non-interactive run hangs.
        # --profile minimal  : rustc, cargo and the std library. Drops
        #                      rust-docs, clippy and rustfmt, which nothing
        #                      here builds with; `rustup component add` gets
        #                      them back. Meaningfully less than 1.5 GB.
        # --no-modify-path is deliberately NOT passed: someone who asked for
        # Rust wants `cargo` in tomorrow's shells too. This run does not
        # depend on that -- it sources the env below.
        echo "Installing rustup (stable, minimal profile)."
        sh "$RUSTUP_SH" -y --default-toolchain stable --profile minimal
        RUSTUP_STATUS=$?
        rm -rf "$RUSTUP_TMP"
        if [ $RUSTUP_STATUS -ne 0 ]; then
            echo "ERROR: the rustup installer exited with status $RUSTUP_STATUS." >&2
            exit $RUSTUP_STATUS
        fi
    fi

    # THE LINE THAT REPLACES "close this terminal and open a new one".
    # rustup's PATH wiring is an append to the shell profile, which the
    # already-running shell will never re-read. `env` is the same wiring
    # for the current process, and an exported PATH is inherited by the
    # pwsh child below -- so Phase 2 finds cargo in this same run.
    if [ -f "${CARGO_HOME:-$HOME/.cargo}/env" ]; then
        # shellcheck disable=SC1091
        . "${CARGO_HOME:-$HOME/.cargo}/env"
        export PATH
    fi

    if command -v cargo >/dev/null 2>&1; then
        echo "cargo: $(command -v cargo)"
    else
        warn "Rust was installed but cargo is still not on PATH. Phase 2 will report this and stop."
    fi
fi

# --- Phase 2: the GUI -------------------------------------------------
echo
echo ">>> Phase 2 of 2: building the desktop GUI"
echo

PWSH="$(command -v pwsh 2>/dev/null)"
if [ -z "$PWSH" ]; then
    echo "ERROR: pwsh is not on PATH even after the pipeline install." >&2
    echo "Phase 2 is a PowerShell script, as the rest of this project is." >&2
    exit 1
fi

WARN_FILE=""
if [ ${#WARNINGS[@]} -gt 0 ]; then
    # Passed as a FILE, not an array parameter: array parameters do not
    # survive `pwsh -File` (each argv entry binds separately, so the
    # second becomes a stray positional and the call fails). The pipeline
    # installer's own handoff does the same thing for the same reason.
    WARN_FILE="$(mktemp)"
    printf '%s\n' "${WARNINGS[@]}" > "$WARN_FILE"
fi

"$PWSH" -NoProfile -File "$SCRIPT_DIR/scripts/setup-gui.ps1" \
    -InstallRoot "$INSTALL_ROOT" \
    -LocalBin "$LOCAL_BIN" \
    -SourceDir "$SCRIPT_DIR" \
    -RequiresArchiveLayout "${REQUIRES_ARCHIVE_LAYOUT:-1}" \
    -InheritedWarningsFile "$WARN_FILE"
exit $?
