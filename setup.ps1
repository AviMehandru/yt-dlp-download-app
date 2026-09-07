<#
.SYNOPSIS
    Installer for the yt-dlp archive desktop GUI -- Windows.

.DESCRIPTION
    The Windows counterpart of setup.sh, and the same two phases:

      Phase 1  installs the PIPELINE, by downloading and running the
               orchid-ochre installer at the ref pinned in
               CLI_VERSION. This repo carries no copy of the pipeline;
               the GUI shells out to the installed `ytdl` and reads the
               archive `postprocess.ps1` writes.

      Phase 2  builds and installs the GUI, via scripts\setup-gui.ps1.

    MUST STAY WINDOWS POWERSHELL 5.1 COMPATIBLE, for exactly the reason
    the pipeline's own setup.ps1 must: this runs BEFORE pwsh 7 is
    guaranteed to exist -- phase 1 is what installs it. So no ternary, no
    null-coalescing, no ForEach-Object -Parallel, and no $IsWindows.
    scripts\setup-gui.ps1 runs under pwsh 7 and has none of those limits.

.PARAMETER SkipCli
    Do not install the pipeline; assume `ytdl` is already there.

.PARAMETER CliRef
    Install this pipeline ref instead of the one pinned in CLI_VERSION.

.PARAMETER InstallRust
    Install or update the Rust toolchain the GUI is built with, instead of
    stopping with instructions. Opt-in, and the counterpart of setup.sh's
    --install-rust; see the block below for why it is a switch.
#>

param(
    [switch] $SkipCli,
    [switch] $InstallRust,
    [string] $CliRef = ""
)

$ErrorActionPreference = "Continue"
$Warnings = New-Object System.Collections.Generic.List[string]
function Write-Warn {
    param([string]$Message)
    Write-Host "WARNING: $Message"
    $Warnings.Add($Message) | Out-Null
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# --- Read the pin -----------------------------------------------------
$PinFile = Join-Path $ScriptDir "CLI_VERSION"
if (-not (Test-Path $PinFile)) {
    Write-Host "ERROR: CLI_VERSION is missing from $ScriptDir."
    Write-Host "It records which pipeline this GUI expects; without it the install would be a guess."
    exit 1
}
$PinText = Get-Content -LiteralPath $PinFile -Raw
function Get-Pin {
    param([string]$Key)
    $m = [regex]::Match($PinText, "(?m)^$Key=(.*)$")
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return ""
}
$CliRepo  = Get-Pin "CLI_REPO"
$CliRefIn = Get-Pin "CLI_REF"
$RequiresArchiveLayout = Get-Pin "REQUIRES_ARCHIVE_LAYOUT"
if ($CliRef -ne "") { $CliRefIn = $CliRef }
if ($RequiresArchiveLayout -eq "") { $RequiresArchiveLayout = "1" }

if ($CliRepo -eq "" -or $CliRefIn -eq "") {
    Write-Host "ERROR: CLI_VERSION does not define CLI_REPO and CLI_REF."
    exit 1
}

Write-Host "==============================================================="
Write-Host " yt-dlp archive -- desktop GUI installer"
Write-Host "==============================================================="
Write-Host " pipeline : $CliRepo @ $CliRefIn"
Write-Host " layout   : requires archive layout v$RequiresArchiveLayout"
Write-Host ""

# --- Phase 1: the pipeline -------------------------------------------
Write-Host ">>> Phase 1 of 2: installing the pipeline"
Write-Host ""

if ($SkipCli) {
    Write-Host "Skipping (-SkipCli). Assuming 'ytdl' is already installed."
} else {
    $RawBase  = "https://raw.githubusercontent.com/$CliRepo/$CliRefIn"
    $TmpDir   = Join-Path ([System.IO.Path]::GetTempPath()) ("ytdl-gui-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null
    $CliSetup = Join-Path $TmpDir "setup.ps1"

    # TLS 1.2 explicitly: Windows PowerShell 5.1 still defaults to older
    # protocols on some builds, and GitHub refuses those outright.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch { }

    $ok = $true
    try {
        Invoke-WebRequest -Uri "$RawBase/setup.ps1" -OutFile $CliSetup -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Host "ERROR: could not download the pipeline installer from $RawBase/setup.ps1"
        Write-Host "  $($_.Exception.Message)"
        Write-Host "Check the network, and that CLI_REF ('$CliRefIn') names a real branch or tag."
        $ok = $false
    }
    if ($ok) {
        $item = Get-Item $CliSetup -ErrorAction SilentlyContinue
        # A proxy or captive portal can answer 200 with its own HTML page,
        # which the request above does not treat as an error.
        if (-not $item -or $item.Length -eq 0) {
            Write-Host "ERROR: the downloaded pipeline installer is empty."
            $ok = $false
        } elseif ((Get-Content $CliSetup -TotalCount 1 -ErrorAction SilentlyContinue) -match '^\s*<(!doctype|html)') {
            Write-Host "ERROR: the downloaded pipeline installer is an HTML page -- a proxy, captive portal or DNS interception answered instead of GitHub."
            $ok = $false
        }
    }
    if (-not $ok) {
        Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    }

    # Files fetched over the internet carry the Zone.Identifier stream, and
    # a .ps1 marked that way is refused outright by the default
    # RemoteSigned execution policy -- which would fail with a security
    # error rather than anything pointing at the real cause.
    Unblock-File -Path $CliSetup -ErrorAction SilentlyContinue

    Write-Host "Running the pipeline installer ($CliRepo @ $CliRefIn)."
    Write-Host "Its step numbering below is its own; this is Phase 1 of 2."
    Write-Host ""
    & powershell -NoProfile -ExecutionPolicy Bypass -File $CliSetup
    $CliStatus = $LASTEXITCODE
    Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($CliStatus -ne 0) {
        # Fatal: the GUI drives the installed pipeline, and a window that
        # cannot download anything is worse than no window.
        Write-Host ""
        Write-Host "ERROR: the pipeline installer exited with status $CliStatus."
        Write-Host "The GUI drives the installed pipeline, so it is not installed either."
        Write-Host "Fix the pipeline install first, then re-run this with -SkipCli."
        exit $CliStatus
    }
}

# --- Locate the install ----------------------------------------------
# Must agree with the pipeline's platform block: YTDLP_INSTALL_ROOT wins,
# then C:\yt-dlp on Windows -- which is NOT under the user profile,
# because a per-video path here reaches ~240 characters before the data
# root is prefixed and MAX_PATH is real.
$InstallRoot = $env:YTDLP_INSTALL_ROOT
if ([string]::IsNullOrWhiteSpace($InstallRoot)) { $InstallRoot = "C:\yt-dlp" }
$LocalBin = Join-Path $env:USERPROFILE ".local\bin"

if (-not (Test-Path (Join-Path $InstallRoot "scripts\ytdl.ps1"))) {
    Write-Host ""
    Write-Host "ERROR: no pipeline found at $InstallRoot (scripts\ytdl.ps1 is missing)."
    Write-Host "The GUI has nothing to drive. Install the pipeline first:"
    Write-Host "  https://github.com/$CliRepo"
    exit 1
}

# --- Phase 1.5: the Rust toolchain, only if asked ---------------------
# The counterpart of setup.sh's --install-rust block, and opt-in for the
# same reason: Phase 1 installs pwsh, deno, Node and yt-dlp without asking
# because those are dependencies of DOWNLOADING, the thing the user came
# for. A Rust toolchain is a dependency only of the window and is ~1.5 GB.
# The switch removes the manual dance, not the consent.
$CargoHome = $env:CARGO_HOME
if ([string]::IsNullOrWhiteSpace($CargoHome)) { $CargoHome = Join-Path $env:USERPROFILE ".cargo" }
$CargoBin = Join-Path $CargoHome "bin"

# Unconditional, like the bash side: rustup's PATH wiring is a change to
# the user environment, which an already-running process never re-reads.
# Fixing PATH for THIS process is what removes "close this window and open
# a new one" -- pwsh below inherits it, and so does cargo under that.
if ((Test-Path $CargoBin) -and ($env:PATH -notlike "*$CargoBin*")) {
    $env:PATH = $CargoBin + [System.IO.Path]::PathSeparator + $env:PATH
}

if ($InstallRust) {
    Write-Host ""
    Write-Host ">>> Rust toolchain (-InstallRust)"
    Write-Host ""

    $RustupCmd = Get-Command rustup -ErrorAction SilentlyContinue
    $CargoCmd  = Get-Command cargo  -ErrorAction SilentlyContinue

    if ($RustupCmd) {
        Write-Host "rustup is already installed; updating the stable toolchain."
        & rustup update stable
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "'rustup update stable' failed. Building with whatever toolchain is already there."
        }
    } elseif ($CargoCmd) {
        # Installing rustup over a cargo that came from somewhere else adds
        # a SECOND toolchain that shadows the first -- a confusing thing to
        # do to someone's machine unasked.
        Write-Host "cargo is already on PATH but was not installed by rustup: $($CargoCmd.Source)"
        Write-Host "Leaving it alone. setup-gui.ps1 will check whether it is new enough."
    } else {
        $Arch = $env:PROCESSOR_ARCHITECTURE
        if ($Arch -eq "ARM64") { $RustupUrl = "https://win.rustup.rs/aarch64" }
        else                   { $RustupUrl = "https://win.rustup.rs/x86_64" }

        $TmpDir2 = Join-Path ([System.IO.Path]::GetTempPath()) ("rustup-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $TmpDir2 -Force | Out-Null
        $RustupExe = Join-Path $TmpDir2 "rustup-init.exe"

        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        } catch { }

        $rok = $true
        try {
            Invoke-WebRequest -Uri $RustupUrl -OutFile $RustupExe -UseBasicParsing -ErrorAction Stop
        } catch {
            Write-Host "ERROR: could not download the rustup installer from $RustupUrl"
            Write-Host "  $($_.Exception.Message)"
            $rok = $false
        }
        # An .exe, so the HTML sniff the .ps1 downloads use does not apply;
        # the MZ header is the equivalent check. A captive portal answering
        # 200 with its own page would otherwise be run as a program.
        if ($rok) {
            $item2 = Get-Item $RustupExe -ErrorAction SilentlyContinue
            if (-not $item2 -or $item2.Length -eq 0) {
                Write-Host "ERROR: the downloaded rustup installer is empty."
                $rok = $false
            } else {
                $head = [System.IO.File]::ReadAllBytes($RustupExe)[0..1]
                if ($head[0] -ne 0x4D -or $head[1] -ne 0x5A) {
                    Write-Host "ERROR: the downloaded rustup installer is not an executable -- a proxy, captive portal or DNS interception answered instead."
                    $rok = $false
                }
            }
        }
        if (-not $rok) {
            Remove-Item $TmpDir2 -Recurse -Force -ErrorAction SilentlyContinue
            exit 1
        }

        Unblock-File -Path $RustupExe -ErrorAction SilentlyContinue

        # -y                : no interactive prompt, or a non-interactive
        #                     run hangs on the "1) Proceed" menu.
        # --profile minimal : rustc, cargo, std. Nothing here builds with
        #                     clippy or rustfmt; `rustup component add`
        #                     gets them back.
        Write-Host "Installing rustup (stable, minimal profile)."
        & $RustupExe -y --default-toolchain stable --profile minimal
        $RustupStatus = $LASTEXITCODE
        Remove-Item $TmpDir2 -Recurse -Force -ErrorAction SilentlyContinue
        if ($RustupStatus -ne 0) {
            Write-Host "ERROR: the rustup installer exited with status $RustupStatus."
            exit $RustupStatus
        }

        # rustup-init writes the user PATH but cannot change this process's,
        # which is the whole point of the block above -- redo it now that
        # the directory exists.
        if ((Test-Path $CargoBin) -and ($env:PATH -notlike "*$CargoBin*")) {
            $env:PATH = $CargoBin + [System.IO.Path]::PathSeparator + $env:PATH
        }
    }

    $CargoCmd = Get-Command cargo -ErrorAction SilentlyContinue
    if ($CargoCmd) {
        Write-Host "cargo: $($CargoCmd.Source)"
    } else {
        Write-Warn "Rust was installed but cargo is still not on PATH. Phase 2 will report this and stop."
    }

    # The MSVC toolchain links against the Microsoft linker, which rustup
    # does NOT install. Its absence surfaces as "link.exe not found" at the
    # very end of a long build, so it is worth saying up front. A warning
    # and not an error: this detection is a heuristic, and a machine with
    # the tools installed somewhere unusual should not be blocked by it.
    $VsWhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    $HasMsvc = $false
    if (Test-Path $VsWhere) {
        $found = & $VsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
        if ($found) { $HasMsvc = $true }
    }
    if (-not $HasMsvc) {
        Write-Warn "The Visual Studio C++ build tools were not detected. Rust's MSVC toolchain needs them to link, and the build will fail at the linker without them. Install the 'Desktop development with C++' workload from https://visualstudio.microsoft.com/downloads/ (Build Tools is enough), then re-run with -SkipCli."
    }
}

# --- Phase 2: the GUI -------------------------------------------------
Write-Host ""
Write-Host ">>> Phase 2 of 2: building the desktop GUI"
Write-Host ""

$Pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $Pwsh) {
    Write-Host "ERROR: pwsh is not on PATH even after the pipeline install."
    Write-Host "Phase 2 is a PowerShell 7 script, as the rest of this project is."
    Write-Host "Open a new terminal (PATH was just updated) and re-run with -SkipCli."
    exit 1
}

$WarnFile = ""
if ($Warnings.Count -gt 0) {
    # A FILE, not an array parameter: array parameters do not survive
    # `pwsh -File` -- each argv entry binds separately, so the second
    # becomes a stray positional and the call fails.
    $WarnFile = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $WarnFile -Value $Warnings -Encoding UTF8
}

& $Pwsh.Source -NoProfile -File (Join-Path $ScriptDir "scripts\setup-gui.ps1") `
    -InstallRoot $InstallRoot `
    -LocalBin $LocalBin `
    -SourceDir $ScriptDir `
    -RequiresArchiveLayout $RequiresArchiveLayout `
    -InheritedWarningsFile $WarnFile
exit $LASTEXITCODE
