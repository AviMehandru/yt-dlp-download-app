<#
.SYNOPSIS
    Phase 2 of the GUI install: build the desktop app and put `ytdl-gui`
    on PATH. Shared by Linux, macOS and Windows.

.DESCRIPTION
    setup.sh and setup.ps1 are the bootstraps. They install the PIPELINE
    (phase 1) by running its own installer at the ref pinned in
    CLI_VERSION, then hand over here. By the time this runs, `ytdl` exists
    and pwsh exists -- this file can therefore assume both, which is why it
    is one cross-platform script rather than two.

    It keeps its own step numbering. The pipeline installer declares its
    own TOTAL_STEPS and its test suite asserts that its three halves agree
    on it, so renumbering its output from outside would mean breaking an
    invariant this repo does not own. Two labelled phases instead.

    SOURCE RESOLUTION, and why it has two modes. Run from a clone, the
    checkout beside setup.sh is the source and cargo builds in place --
    the ordinary way to work on a Rust project, and the mode that makes an
    edit-then-rebuild loop bearable. Run from a setup.sh downloaded on its
    own, there is no checkout, so the source files are fetched into the
    install root and built there. Same rule as the pipeline installer's
    "files beside the installer win and are never downloaded over".

.PARAMETER InstallRoot
    Where the pipeline is installed -- the thing this GUI drives. Not a
    place the GUI writes to, except for the fetched-source mode above.

.PARAMETER LocalBin
    The user-owned directory on PATH that already holds `ytdl` and
    `ytdl-view`, and will hold `ytdl-gui`.

.PARAMETER SourceDir
    Where the bootstrap lives. A checkout here is used as-is.

.PARAMETER RequiresArchiveLayout
    The archive layout version this GUI understands, from CLI_VERSION.
    Recorded in the summary so a later "why is my library empty" has a
    number to check against docs/archive-layout.md in the pipeline repo.
#>

param(
    [Parameter(Mandatory = $true)] [string] $InstallRoot,
    [Parameter(Mandatory = $true)] [string] $LocalBin,
    [Parameter(Mandatory = $true)] [string] $SourceDir,
    [int]    $RequiresArchiveLayout = 1,
    [string] $InheritedWarningsFile = ""
)

# Same keep-going principle as the pipeline installer.
$ErrorActionPreference = "Continue"

$Warnings = New-Object System.Collections.Generic.List[string]
if ($InheritedWarningsFile -and (Test-Path $InheritedWarningsFile)) {
    foreach ($w in (Get-Content -Path $InheritedWarningsFile -ErrorAction SilentlyContinue)) {
        if ($w -and $w.Trim()) { $Warnings.Add($w) | Out-Null }
    }
    Remove-Item -Path $InheritedWarningsFile -Force -ErrorAction SilentlyContinue
}

$TotalSteps = 5
$script:CurrentStep = 0
function Write-Step {
    param([string]$Message)
    $script:CurrentStep++
    Write-Host ""
    Write-Host ">>> GUI step $($script:CurrentStep)/$($TotalSteps): $Message"
}
function Write-Warn {
    param([string]$Message)
    Write-Host "WARNING: $Message"
    $Warnings.Add($Message) | Out-Null
}

$RepoRaw = "https://raw.githubusercontent.com/AviMehandru/yt-dlp-download-app/main"

# Every file the app is built from. Keep in sync with the repo tree; a
# file missing here simply is not fetched in the no-checkout mode, and the
# build then fails on a missing module rather than on anything obvious.
#
# That failure mode is not hypothetical. profiles.rs was added to the crate
# and never added here, so every no-checkout install from that commit until
# this one fetched a source tree that cannot compile -- `cargo build` stops
# at "file not found for module `profiles`", naming a file the user never
# knew was supposed to exist. A checkout install was unaffected, which is
# why it went unnoticed: the mode that is tested is not the mode that broke.
#
# Adding a module to src-tauri/src means adding a line here.
$SourceFiles = @(
    "src/index.html",
    "src/app.css",
    "src/app.js",
    "src-tauri/Cargo.toml",
    "src-tauri/Cargo.lock",
    "src-tauri/build.rs",
    "src-tauri/tauri.conf.json",
    "src-tauri/capabilities/default.json",
    "src-tauri/src/main.rs",
    "src-tauri/src/paths.rs",
    "src-tauri/src/pipeline.rs",
    "src-tauri/src/archive.rs",
    "src-tauri/src/media.rs",
    "src-tauri/src/health.rs",
    "src-tauri/src/profiles.rs",
    "src-tauri/icons/32x32.png",
    "src-tauri/icons/128x128.png",
    "src-tauri/icons/128x128@2x.png",
    "src-tauri/icons/icon.png",
    "src-tauri/icons/icon.ico"
)

# --- Step 1: prerequisites -------------------------------------------
Write-Step "Checking prerequisites"

# Rust is NOT installed for you here, deliberately. The pipeline
# installer installs pwsh, deno, Node and yt-dlp because those are
# dependencies of downloading. A Rust toolchain is a dependency only of
# this window, it is ~1.5 GB, and rustup's installer is an unverified
# curl-to-shell of exactly the kind the pipeline's SECURITY.md already
# accounts for one instance of. The bootstraps offer --install-rust for
# anyone who wants that trade; this script only ever FINDS a toolchain.
#
# Finding one is less trivial than Get-Command suggests. rustup's only
# PATH wiring is a line appended to the user's shell profile, so a
# toolchain installed minutes ago -- by --install-rust in the parent
# bootstrap, or by hand in this same terminal -- is on disk and not on
# PATH. That is the entire reason this used to end in "open a new
# terminal and run it again". Prepending the bin dir to the PATH of THIS
# process is enough: cargo is invoked as a child of it.
$CargoHome = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $HOME ".cargo" }
$CargoBin  = Join-Path $CargoHome "bin"

$CargoCmd = Get-Command cargo -ErrorAction SilentlyContinue
if (-not $CargoCmd -and (Test-Path $CargoBin)) {
    $env:PATH = $CargoBin + [System.IO.Path]::PathSeparator + $env:PATH
    $CargoCmd = Get-Command cargo -ErrorAction SilentlyContinue
    if ($CargoCmd) {
        Write-Host "Found a Rust toolchain in $CargoBin that was not yet on PATH."
        Write-Host "Using it for this build. New shells will pick it up from your profile."
    }
}

if (-not $CargoCmd) {
    Write-Host "Rust is not installed, so the GUI cannot be built."
    Write-Host "The pipeline itself is unaffected -- 'ytdl' and 'ytdl-view' work regardless."
    Write-Host ""
    Write-Host "Either let the bootstrap install it:"
    if ($IsWindows) {
        Write-Host "    .\setup.ps1 -SkipCli -InstallRust"
    } else {
        Write-Host "    ./setup.sh --skip-cli --install-rust"
    }
    Write-Host ""
    Write-Host "or install it yourself and re-run -- no new terminal needed either way:"
    Write-Host "    https://rustup.rs"
    exit 0
}
Write-Host "cargo: $($CargoCmd.Source)"

# The minimum is enforced by cargo anyway, but only after it has resolved
# the dependency graph, and its message names neither rustup nor the
# command that fixes it. Checked here so the fix is one line up from the
# failure. Read from the manifest when there is a checkout, so this can
# never drift from the value the build actually enforces.
$MinRust = "1.77"   # fallback for the no-checkout mode; keep = Cargo.toml rust-version
$LocalManifest = Join-Path $SourceDir "src-tauri/Cargo.toml"
if (Test-Path $LocalManifest) {
    $rv = [regex]::Match((Get-Content -LiteralPath $LocalManifest -Raw), '(?m)^\s*rust-version\s*=\s*"([0-9.]+)"')
    if ($rv.Success) { $MinRust = $rv.Groups[1].Value }
}
$RustcVersion = $null
$rustcOut = (& rustc --version 2>$null)
if ($LASTEXITCODE -eq 0 -and $rustcOut) {
    $m = [regex]::Match($rustcOut, 'rustc\s+([0-9]+\.[0-9]+\.[0-9]+)')
    if ($m.Success) { $RustcVersion = $m.Groups[1].Value }
}
if (-not $RustcVersion) {
    Write-Warn "cargo is on PATH but 'rustc --version' did not report a version. Building anyway; if it fails on a language feature, the toolchain is the first thing to check."
} elseif ([version]$RustcVersion -lt [version]$MinRust) {
    Write-Host "Rust $RustcVersion is older than the $MinRust this app requires, so the GUI cannot be built."
    Write-Host "The pipeline itself is unaffected -- 'ytdl' and 'ytdl-view' work regardless."
    Write-Host ""
    if (Get-Command rustup -ErrorAction SilentlyContinue) {
        Write-Host "Update it and re-run:"
        Write-Host "    rustup update stable"
    } else {
        # A distro-packaged rustc. rustup would install a second toolchain
        # rather than upgrade this one, so say which is which.
        Write-Host "This toolchain was not installed by rustup, so 'rustup update' does not apply."
        Write-Host "Upgrade it through whatever installed it, or install rustup from https://rustup.rs"
    }
    exit 0
}
Write-Host "rustc: $RustcVersion (requires >= $MinRust)"

if ($IsLinux) {
    # On Linux the webview is a SYSTEM library that cargo cannot fetch,
    # and its absence surfaces as a pkg-config error hundreds of lines
    # into a build. Checked up front so the message names the packages.
    $pkgConfig = Get-Command pkg-config -ErrorAction SilentlyContinue
    $webkitOk = $false
    if ($pkgConfig) {
        & pkg-config --exists webkit2gtk-4.1 2>$null
        if ($LASTEXITCODE -eq 0) { $webkitOk = $true }
    }
    if (-not $webkitOk) {
        Write-Host "The WebKitGTK development files are missing, so the GUI cannot be built."
        Write-Host "  Debian/Ubuntu: sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev librsvg2-dev patchelf"
        Write-Host "  Fedora:        sudo dnf install webkit2gtk4.1-devel gtk3-devel librsvg2-devel"
        Write-Host "Then re-run: ./setup.sh --skip-cli"
        exit 0
    }
    Write-Host "webkit2gtk-4.1: present"
}

# --- Step 2: resolve the source --------------------------------------
Write-Step "Locating the GUI source"

$GuiSource = $null
if (Test-Path (Join-Path $SourceDir "src-tauri/Cargo.toml")) {
    $GuiSource = $SourceDir
    Write-Host "Building from the checkout at $SourceDir (nothing will be downloaded)."
} else {
    $GuiSource = Join-Path $InstallRoot "gui"
    Write-Host "No checkout beside the installer; fetching the source into $GuiSource."
    foreach ($rel in $SourceFiles) {
        $dest = Join-Path $GuiSource ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $parent = Split-Path -Parent $dest
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $part = "$dest.part"
        try {
            Invoke-WebRequest -Uri "$RepoRaw/$rel" -OutFile $part -UseBasicParsing -ErrorAction Stop
            $item = Get-Item $part -ErrorAction SilentlyContinue
            if (-not $item -or $item.Length -eq 0) {
                Remove-Item $part -Force -ErrorAction SilentlyContinue
                Write-Warn "Downloaded '$rel' was empty -- treating as a failed download."
            } elseif ((Get-Content $part -TotalCount 1 -ErrorAction SilentlyContinue) -match '^\s*<(!doctype|html)') {
                # curl -f / Invoke-WebRequest both miss a captive portal
                # that answers 200 with its own page. None of these files
                # is HTML.
                Remove-Item $part -Force -ErrorAction SilentlyContinue
                Write-Warn "'$rel' came back as an HTML page rather than the file itself -- a proxy or captive portal answered instead of GitHub."
            } else {
                Move-Item -Path $part -Destination $dest -Force
            }
        } catch {
            Remove-Item $part -Force -ErrorAction SilentlyContinue
            Write-Warn "Could not download '$rel' ($($_.Exception.Message))."
        }
    }
}

$ManifestPath = Join-Path $GuiSource "src-tauri/Cargo.toml"
if (-not (Test-Path $ManifestPath)) {
    Write-Warn "No Cargo.toml at $ManifestPath -- the GUI was not built. The pipeline is unaffected."
    exit 1
}

# --- Step 3: build ----------------------------------------------------
Write-Step "Building the app (a first build compiles several hundred crates)"

$BuildOk = $false
try {
    & cargo build --release --manifest-path $ManifestPath
    $BuildOk = ($LASTEXITCODE -eq 0)
} catch {
    Write-Warn "The GUI build threw: $($_.Exception.Message)"
}
if (-not $BuildOk) {
    Write-Warn "The GUI build failed. The pipeline is unaffected -- 'ytdl' and 'ytdl-view' work regardless. Retry by hand with: cargo build --release --manifest-path `"$ManifestPath`""
    exit 1
}

$BinName = if ($IsWindows) { "ytdl-gui.exe" } else { "ytdl-gui" }
$Binary = Join-Path $GuiSource (Join-Path "src-tauri/target/release" $BinName)
if (-not (Test-Path $Binary)) {
    Write-Warn "cargo reported success but $Binary is not there."
    exit 1
}
Write-Host "Built: $Binary"

# --- Step 4: launcher -------------------------------------------------
Write-Step "Installing the ytdl-gui launcher"

New-Item -ItemType Directory -Path $LocalBin -Force | Out-Null
# Generated rather than shipped, matching how the pipeline writes
# ytdl-view: the entire body is one line, so a repo file would exist only
# to be copied and would be one more thing to keep in sync.
if ($IsWindows) {
    $Launcher = Join-Path $LocalBin "ytdl-gui.cmd"
    $body = @"
@echo off
REM Generated by setup-gui.ps1 -- thin launcher for the desktop GUI.
start "" "$Binary" %*
"@
    Set-Content -Path $Launcher -Value $body -Encoding ASCII
} else {
    $Launcher = Join-Path $LocalBin "ytdl-gui"
    $body = @"
#!/usr/bin/env bash
# Generated by setup-gui.ps1 -- thin launcher for the desktop GUI.
exec "$Binary" "`$@"
"@
    Set-Content -Path $Launcher -Value $body -Encoding UTF8
    & chmod +x $Launcher
}
Write-Host "Installed ytdl-gui -> $Launcher"

# --- Step 5: verify ---------------------------------------------------
Write-Step "Verifying"

$InstalledLayout = 1
$ppPath = Join-Path $InstallRoot "scripts/postprocess.ps1"
if (Test-Path $ppPath) {
    $m = [regex]::Match((Get-Content -LiteralPath $ppPath -Raw), '(?m)^\$ArchiveLayoutVersion\s*=\s*(\d+)')
    if ($m.Success) { $InstalledLayout = [int]$m.Groups[1].Value }
}

Write-Host "pipeline    : $InstallRoot"
Write-Host "ytdl        : $(if (Get-Command ytdl -ErrorAction SilentlyContinue) { (Get-Command ytdl).Source } else { 'NOT ON PATH (open a new shell if it was just installed)' })"
Write-Host "ytdl-gui    : $Launcher"
Write-Host "archive     : pipeline writes layout v$InstalledLayout; this GUI reads up to v$RequiresArchiveLayout"

if ($InstalledLayout -gt $RequiresArchiveLayout) {
    Write-Warn "The pipeline writes a NEWER archive layout than this GUI understands. Videos archived from now on may not appear in the library. See docs/archive-layout.md in the pipeline repo."
}

Write-Host ""
if ($Warnings.Count -gt 0) {
    Write-Host "Completed with $($Warnings.Count) warning(s):"
    foreach ($w in $Warnings) { Write-Host "  - $w" }
} else {
    Write-Host "Done. Start it with: ytdl-gui"
}
exit 0
