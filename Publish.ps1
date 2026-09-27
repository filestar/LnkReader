#Requires -Version 7
<#
.SYNOPSIS
    Publishes LnkReader.Net6 to the Filestar NuGet feed on Sliplane.

.DESCRIPTION
    Replaces Azure DevOps pipeline 28 ("filestar.LnkReader"), which
    built this package on every push to master AND every pull request, and pushed it to the
    Azure feed - so an unmerged PR could publish a version. azure-pipelines.yml is gone; this script is the only way to publish.

    Run it from this checkout. It does five things, in order:

      1. Checks the commit. The package is built from HEAD, never from the working
         tree, so what is on the feed is always exactly one commit. That commit has
         to be on origin/master - the branch everything is built from - so a commit
         that is only local, or only on another branch, stops -Execute. Uncommitted
         changes are reported but cannot reach the package.
      2. Asks the feed which versions it already has. A version that is there is
         never replaced - the feed answers 409 - so -Execute stops before building.
         A dry run warns and carries on, so it still shows whether the package builds.
      3. Checks out HEAD into a temporary folder and packs it in Release there.
      4. Pushes the package. Only with -Execute; without it, the run stops here and
         says what it would have pushed.
      5. Reads the package back from the feed and compares its SHA-256 with the
         one it pushed. The feed stores the uploaded bytes unchanged, so anything
         other than a match means the push did not land as sent.

    The version is the <Version> in LnkReader.csproj as committed.

    The tests are not run: most need local folders or downloads. Check a reader change
    by hand before publishing.

    The push key is NUGET_PUSH_API_KEY in the Dopbase environment
    filestar-tools/production, the same key `ftools plugin build` uses. With
    -Execute the script re-runs itself under `dopbase run`: the key is in that run's
    environment only, never written to disk, never on a command line, and the push
    request is made with debug and verbose output switched off so its headers are
    never printed. A dry run needs no vault at all.

    What to do when it fails:
      - "already on the feed": bump <Version> in the csproj, commit, merge to master, run again.
      - "not on origin/master": merge the commit into master first.
        -AllowUnpushed overrides this, but then no commit on master matches the feed.
      - "build input above the build folder": a Directory.Build.props, global.json or
        similar sits in a parent of the temporary folder and would change the build.
        Remove it or run with a different TEMP.
      - 403 from the feed: the key in the vault does not match the feed's. Check
        NUGET_PUSH_API_KEY in filestar-tools/production against filestar-nugets/production.
      - the vault run fails: sign in with `dopbase login` inside WSL, or run with
        -NoDopbase after setting NUGET_PUSH_API_KEY yourself.
      - hash mismatch after the push: do not use that version. Bump and publish again.

.PARAMETER Execute
    Push the package. Without it the run is a dry run that builds and packs but
    pushes nothing.

.PARAMETER AllowUnpushed
    Publish a commit that is not on origin/master.

.PARAMETER FeedUrl
    The feed's root (without /nuget). Defaults to the Sliplane service by its managed
    name, which keeps working after nuget.filestar.com moves to it.

.PARAMETER DopbaseEnv
    Where the push key lives.

.PARAMETER DopbaseCommand
    The Dopbase CLI. On Windows it is a shim into WSL.

.PARAMETER NoDopbase
    Do not re-run under the vault; NUGET_PUSH_API_KEY must already be set.

.EXAMPLE
    .\Publish.ps1
    Dry run: checks, builds, packs, and says what it would push.

.EXAMPLE
    .\Publish.ps1 -Execute
    Publishes the version in the committed csproj.

.NOTES
    There is no rollback. A version on the feed is never replaced or deleted by
    this script, because a client that has downloaded it keeps its copy - one
    version number must always mean one package. A bad package is fixed by
    publishing the next version.

    Consumers in filestar/Filestar restore from the Sliplane feed (NuGet.config): take a new
    version with `dotnet add package LnkReader.Net6 --version <v>`, bump the plugin, and release it
    through the normal plugin release.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Execute,
    [switch]$AllowUnpushed,
    [string]$FeedUrl = 'https://filestar-nugets.sliplane.app',
    [string]$DopbaseEnv = 'filestar-tools/production',
    [string]$DopbaseCommand = 'dopbase-filestar',
    [switch]$NoDopbase
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# git writes UTF-8; read it as UTF-8 whatever code page the console started in.
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# $PSBoundParameters read inside a function is that function's, not the script's.
$ScriptArgs = $PSBoundParameters

$PackageId   = 'LnkReader.Net6'
$ProjectPath = 'LnkReader/LnkReader.csproj'
$Branch      = 'origin/master'
$FeedUrl     = $FeedUrl.TrimEnd('/')

function Write-Step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    $m" -ForegroundColor DarkGray }

function ConvertTo-WslPath {
    param([string]$WindowsPath)
    $p = $WindowsPath -replace '\\', '/'
    if ($p -match '^([A-Za-z]):/(.*)$') { return "/mnt/$($Matches[1].ToLower())/$($Matches[2])" }
    return $p
}

# --- running under the vault --------------------------------------------------
#
# The same shape as Filestar-Hangfire/Run-Tests.ps1, for the same three reasons:
# Dopbase has no Windows build, so `dopbase-filestar` forwards into WSL and the
# Windows pwsh has to be named by its /mnt/c path; WSL passes only the variables
# named in WSLENV to a Windows process; and WSL strips backslashes from arguments,
# so a script path or parameter must use forward slashes.
#
# Only this script's own parameters are passed on. $PSBoundParameters also holds
# common parameters such as -Debug, and a -Debug in the run that holds the key
# would make Invoke-WebRequest print the request headers - the key among them.

$OwnParameters = @('Execute', 'AllowUnpushed', 'FeedUrl', 'DopbaseEnv', 'DopbaseCommand', 'NoDopbase')

function Invoke-UnderDopbase {
    param([hashtable]$Arguments)

    $dopbase = Get-Command $DopbaseCommand -ErrorAction SilentlyContinue
    if (-not $dopbase) {
        throw ("$DopbaseCommand is not on PATH. Install the Dopbase CLI, or set " +
               'NUGET_PUSH_API_KEY yourself and re-run with -NoDopbase.')
    }

    $argv = @()
    foreach ($kv in $Arguments.GetEnumerator()) {
        if ($OwnParameters -notcontains $kv.Key) { continue }
        $value = $kv.Value
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) { $argv += "-$($kv.Key)" }
            continue
        }
        if ("$value" -match '\\') {
            throw ("-$($kv.Key) contains a backslash, which WSL strips crossing into the vault run. " +
                   'Use forward slashes.')
        }
        $argv += "-$($kv.Key)"; $argv += "$value"
    }

    Write-Step "Fetching the push key from $DopbaseEnv"
    Write-Ok 'held in this run''s environment only - never written to disk or put on a command line'

    & $dopbase.Source run $DopbaseEnv -- `
        env 'WSLENV=NUGET_PUSH_API_KEY:LNKREADER_PUBLISH_UNDER_DOPBASE' 'LNKREADER_PUBLISH_UNDER_DOPBASE=1' `
        (ConvertTo-WslPath ([Environment]::ProcessPath)) -NoProfile -File ($PSCommandPath -replace '\\', '/') @argv

    exit $LASTEXITCODE
}

if ($Execute -and -not $WhatIfPreference -and -not $NoDopbase -and -not $env:LNKREADER_PUBLISH_UNDER_DOPBASE) {
    Invoke-UnderDopbase -Arguments $ScriptArgs
}

# --- the feed -----------------------------------------------------------------

function Get-FeedVersions {
    # FindPackagesById pages at 25 entries and links the next page. Reading only
    # the first page makes a package look several versions behind.
    $versions = @()
    $url = "$FeedUrl/nuget/FindPackagesById()?id='$PackageId'"
    while ($url) {
        [xml]$doc = (Invoke-WebRequest -Uri $url -UseBasicParsing).Content
        $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
        $ns.AddNamespace('a', 'http://www.w3.org/2005/Atom')
        $ns.AddNamespace('m', 'http://schemas.microsoft.com/ado/2007/08/dataservices/metadata')
        $ns.AddNamespace('d', 'http://schemas.microsoft.com/ado/2007/08/dataservices')
        foreach ($v in $doc.SelectNodes('/a:feed/a:entry/m:properties/d:Version', $ns)) { $versions += $v.InnerText }
        $next = $doc.SelectSingleNode("/a:feed/a:link[@rel='next']", $ns)
        $url = if ($next) { $next.GetAttribute('href') } else { $null }
    }
    return $versions
}

function Invoke-Git {
    $output = git -C $PSScriptRoot @args
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed. Run this from the LnkReader checkout." }
    return $output
}

$work = Join-Path ([IO.Path]::GetTempPath()) "lnkreader-$([guid]::NewGuid().ToString('n').Substring(0, 8))"
$src  = Join-Path $work 'src'
$out  = Join-Path $work 'out'

try {

# --- 1. the commit ----------------------------------------------------------------

Write-Step 'Checking the commit'

$head = Invoke-Git rev-parse HEAD
# The csproj starts with a byte-order mark, which [xml] refuses as the first node.
# Depending on the console code page it arrives as U+FEFF or as three other
# characters, so parse from the first '<' rather than trimming one spelling of it.
$csprojText = (Invoke-Git show "HEAD:$ProjectPath") -join "`n"
[xml]$csproj = $csprojText.Substring([Math]::Max(0, $csprojText.IndexOf('<')))
$versionNode = $csproj.SelectSingleNode('/Project/PropertyGroup/Version')
if (-not $versionNode -or -not $versionNode.InnerText.Trim()) { throw "No <Version> in $ProjectPath at HEAD." }
$version = $versionNode.InnerText.Trim()
Write-Ok "$PackageId $version, from commit $($head.Substring(0, 9))"

$dirty = Invoke-Git status --porcelain --untracked-files=all
if ($dirty) {
    Write-Warning ("Uncommitted changes are NOT in the package - it is built from HEAD:`n" + ($dirty -join "`n"))
}

# --prune, so a branch deleted on GitHub cannot still vouch for a commit here.
Invoke-Git fetch --prune --quiet origin | Out-Null
git -C $PSScriptRoot merge-base --is-ancestor $head $Branch
$onBranch = $LASTEXITCODE -eq 0
if (-not $onBranch) {
    $message = "commit $($head.Substring(0, 9)) is not on $Branch - merge it into master first"
    if ($Execute -and -not $AllowUnpushed) { throw "Not publishing: $message" }
    Write-Warning $message
}

# --- 2. the feed ----------------------------------------------------------------

Write-Step "Asking $FeedUrl what it has"
$existing = @(Get-FeedVersions)
$newest = $existing | Sort-Object { try { [version]($_ -replace '-.*$', '') } catch { [version]'0.0' } } | Select-Object -Last 3
Write-Ok "$($existing.Count) version(s) on the feed, newest: $($newest -join ', ')"
$alreadyThere = $existing -contains $version
if ($alreadyThere) {
    $message = ("$PackageId $version is already on the feed, and a published version is never replaced. " +
                'Bump <Version> in LnkReader.csproj, commit, merge to master and run again.')
    # A dry run carries on, so it still answers "does it build and pack?".
    if ($Execute) { throw $message }
    Write-Warning $message
}

# --- 3. build and pack from the commit -------------------------------------------

Write-Step "Packing commit $($head.Substring(0, 9))"
Invoke-Git worktree add --quiet --detach $src $head | Out-Null

# MSBuild and the SDK also read Directory.Build.* and global.json from every folder
# ABOVE the project. Inside the checkout those are committed; above it they would be
# someone's local file shaping the package.
$inputs = 'Directory.Build.props', 'Directory.Build.targets', 'Directory.Packages.props', 'global.json'
$dir = Split-Path -Parent $src
while ($dir) {
    foreach ($name in $inputs) {
        $candidate = Join-Path $dir $name
        if (Test-Path -LiteralPath $candidate) { throw "Build input above the build folder: $candidate. Remove it or set TEMP elsewhere." }
    }
    $dir = Split-Path -Parent $dir
}

dotnet pack (Join-Path $src $ProjectPath) --configuration Release --output $out --nologo
if ($LASTEXITCODE -ne 0) { throw 'dotnet pack failed; the output above says why.' }

$nupkg = Join-Path $out "$PackageId.$version.nupkg"
if (-not (Test-Path -LiteralPath $nupkg)) {
    throw "Expected $nupkg, found: $((Get-ChildItem $out).Name -join ', ')"
}
$hash = (Get-FileHash -LiteralPath $nupkg -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Ok "$((Get-Item -LiteralPath $nupkg).Length) bytes, sha256 $hash"

# --- 4. push --------------------------------------------------------------------

if (-not $Execute) {
    Write-Step 'Dry run - nothing pushed'
    # The same conditions the real run refuses on.
    if ($alreadyThere -or (-not $onBranch -and -not $AllowUnpushed)) {
        Write-Ok '-Execute would refuse: see the warnings above.'
    } else {
        Write-Ok "Run with -Execute to publish $PackageId $version to $FeedUrl."
    }
    return
}
if (-not $PSCmdlet.ShouldProcess("$FeedUrl/nuget", "Push $PackageId $version")) { return }

$key = $env:NUGET_PUSH_API_KEY
if (-not $key) {
    throw ("NUGET_PUSH_API_KEY is empty. Either $DopbaseEnv does not hold it, or the vault run " +
           'did not forward it. With -NoDopbase, set it yourself first.')
}

Write-Step "Pushing to $FeedUrl"
# -Debug:$false and -Verbose:$false override any inherited preference: with debug
# output on, Invoke-WebRequest prints the request headers, and X-NuGet-ApiKey is one.
$response = Invoke-WebRequest -Method Put -Uri "$FeedUrl/nuget" -Headers @{ 'X-NuGet-ApiKey' = $key.Trim() } `
    -Form @{ package = Get-Item -LiteralPath $nupkg } -SkipHttpErrorCheck -UseBasicParsing `
    -Debug:$false -Verbose:$false
switch ([int]$response.StatusCode) {
    201     { Write-Ok '201 Created' }
    409     { throw "409: $PackageId $version was pushed by someone else since step 2. Bump the version." }
    403     { throw "403: the feed refused the key. Compare NUGET_PUSH_API_KEY in $DopbaseEnv with filestar-nugets/production." }
    default { throw "The feed answered $([int]$response.StatusCode): $($response.Content)" }
}

# --- 5. read it back -------------------------------------------------------------

Write-Step 'Reading it back'
$check = Join-Path $work 'from-feed.nupkg'
Invoke-WebRequest -Uri "$FeedUrl/nuget/Packages(Id='$PackageId',Version='$version')/Download" -OutFile $check -UseBasicParsing
$feedHash = (Get-FileHash -LiteralPath $check -Algorithm SHA256).Hash.ToLowerInvariant()
if ($feedHash -ne $hash) {
    throw "The feed serves a different file (sha256 $feedHash, pushed $hash). Do not use $version; bump and publish again."
}
if ((Get-FeedVersions) -notcontains $version) { throw "$version downloads but is not listed by FindPackagesById." }
Write-Ok 'listed, and byte-identical to what was pushed'

Write-Step "Published $PackageId $version from commit $($head.Substring(0, 9))"
Write-Ok 'Consumers pick it up with dotnet add package, a plugin version bump and a plugin release.'

}
finally {
    if (Test-Path -LiteralPath $src) { git -C $PSScriptRoot worktree remove --force $src 2>$null | Out-Null }
    if (Test-Path -LiteralPath $work) { Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue }
}
