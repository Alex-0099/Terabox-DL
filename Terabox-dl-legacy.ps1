<#
.SYNOPSIS
    Downloads files and folders from TeraBox shared links using the unofficial API and your ndus cookie.

.DESCRIPTION
    This script interacts with TeraBox's internal web API endpoints to:
      1. Resolve a shared link via /api/shorturlinfo
      2. List files (including folder contents) via /share/list
      3. Obtain direct download links (dlink)
      4. Download files with retry, resume, and progress indication

    Configuration is loaded in this priority order (highest wins):
      1. CLI arguments (always override everything)
      2. Config file  (terabox-dl.config.json next to this script)
      3. .env file    (for cookies — path set in config or next to script)
      4. Environment variables ($env:TERABOX_NDUS)
      5. Built-in defaults

    HOW TO GET YOUR ndus COOKIE:
      1. Log in to https://www.terabox.com in your browser
      2. Open Developer Tools (F12) -> Application tab -> Cookies
      3. Find the 'ndus' cookie value under terabox.com
      4. Paste it in the .env file or pass with -NdusCookie

.PARAMETER Url
    The TeraBox shared link URL (e.g. https://www.terabox.com/s/1ABC123xyz)

.PARAMETER NdusCookie
    Your ndus session cookie value. Overrides .env and config file.

.PARAMETER OutputDir
    Directory to save downloaded files. Overrides config file.

.PARAMETER ListOnly
    If specified, only lists file info without downloading.

.PARAMETER MaxRetries
    Maximum number of retry attempts per download. Overrides config file.

.PARAMETER NoResume
    If specified, disables resume for partial downloads (re-downloads from scratch).

.PARAMETER ConfigFile
    Path to a custom config JSON file. Defaults to terabox-dl.config.json next to this script.

.PARAMETER NoLog
    If specified, disables download logging even if logFile is set in config.

.EXAMPLE
    .\Terabox-dl.ps1 -Url "https://www.terabox.com/s/1ABC123"

.EXAMPLE
    .\Terabox-dl.ps1 -Url "https://terabox.com/s/1ABC123" -OutputDir "D:\Downloads"

.EXAMPLE
    .\Terabox-dl.ps1 -Url "https://www.terabox.com/s/1ABC123" -ListOnly

.NOTES
    WARNING: This uses unofficial/reverse-engineered API endpoints.
    - These endpoints may break at any time if TeraBox updates their service.
    - Using automated tools may violate TeraBox's Terms of Service.
    - Never share your ndus cookie value — it grants full access to your account.
    - Use at your own risk and only for your own files/content.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Url,

    [Parameter()]
    [string]$NdusCookie,

    [Parameter()]
    [string]$OutputDir,

    [Parameter()]
    [switch]$ListOnly,

    [Parameter()]
    [int]$MaxRetries = -1,

    [Parameter()]
    [switch]$NoResume,

    [Parameter()]
    [string]$ConfigFile,

    [Parameter()]
    [switch]$NoLog,

    [Parameter()]
    [switch]$NoArchive,

    [Parameter()]
    [int]$Threads = 3,

    [Parameter()]
    [switch]$Interactive
)

# ══════════════════════════════════════════════════════════════════════════════
# ── CONFIGURATION LOADING ────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════

$ErrorActionPreference = "Stop"

$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# ── Defaults ───────────────────────────────────────────────────────────────────

$script:Config = @{
    OutputDir   = "."
    MaxRetries  = 10
    Resume      = $true
    TimeoutSec  = 600
    LogFile     = $null
    LogLevel    = "all"
    EnvFile     = $null
    UserAgent   = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    AppId       = "250528"
    NdusCookie  = $null
    ArchiveFile = "terabox-dl.archive.txt"
    Threads     = 3
}

# ── Load config file ──────────────────────────────────────────────────────────

function Import-ConfigFile([string]$Path) {
    if (-not (Test-Path $Path)) { return }

    try {
        $json = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json

        # Map JSON keys to config (skip comment keys starting with "//")
        if ($null -ne $json.outputDir)   { $script:Config.OutputDir   = $json.outputDir }
        if ($null -ne $json.maxRetries)  { $script:Config.MaxRetries  = [int]$json.maxRetries }
        if ($null -ne $json.resume)      { $script:Config.Resume      = [bool]$json.resume }
        if ($null -ne $json.timeoutSec)  { $script:Config.TimeoutSec  = [int]$json.timeoutSec }
        if ($null -ne $json.logFile)     { $script:Config.LogFile     = $json.logFile }
        if ($null -ne $json.logLevel)    { $script:Config.LogLevel    = $json.logLevel }
        if ($null -ne $json.envFile)     { $script:Config.EnvFile     = $json.envFile }
        if ($null -ne $json.userAgent)   { $script:Config.UserAgent   = $json.userAgent }
        if ($null -ne $json.appId)       { $script:Config.AppId       = $json.appId }
        if ($null -ne $json.archiveFile) { $script:Config.ArchiveFile = $json.archiveFile }
        if ($null -ne $json.threads)     { $script:Config.Threads     = [int]$json.threads }

        return $true
    }
    catch {
        Write-Host "  ⚠ Failed to parse config file: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

# Determine config file path
if ($ConfigFile) {
    $cfgPath = $ConfigFile
}
else {
    $cfgPath = Join-Path $script:ScriptDir "terabox-dl.config.json"
}

$cfgLoaded = $false
if (Test-Path $cfgPath) {
    $cfgLoaded = Import-ConfigFile -Path $cfgPath
}

# ── Load .env file ────────────────────────────────────────────────────────────

function Import-EnvFile([string]$Path) {
    if (-not (Test-Path $Path)) { return }

    $envContent = Get-Content -Path $Path -Encoding UTF8
    foreach ($line in $envContent) {
        $line = $line.Trim()

        # Skip empty lines and comments
        if (-not $line -or $line.StartsWith('#')) { continue }

        # Parse KEY=VALUE
        $eqIndex = $line.IndexOf('=')
        if ($eqIndex -gt 0) {
            $key   = $line.Substring(0, $eqIndex).Trim()
            $value = $line.Substring($eqIndex + 1).Trim()

            # Strip surrounding quotes if present
            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
                ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }

            switch ($key) {
                "TERABOX_NDUS" {
                    if ($value -and $value -ne "your_ndus_cookie_value_here") {
                        $script:Config.NdusCookie = $value
                    }
                }
                "TERABOX_JSTOKEN" {
                    if ($value) {
                        $script:Config.JsToken = $value
                    }
                }
            }
        }
    }
}

# Determine .env file path
$envPath = $null
if ($script:Config.EnvFile) {
    if ([System.IO.Path]::IsPathRooted($script:Config.EnvFile)) {
        $envPath = $script:Config.EnvFile
    }
    else {
        $envPath = Join-Path $script:ScriptDir $script:Config.EnvFile
    }

    # Fallback to local .env if the configured path does not exist
    if (-not (Test-Path $envPath)) {
        $localEnv = Join-Path $script:ScriptDir ".env"
        if (Test-Path $localEnv) {
            $envPath = $localEnv
        }
    }
}
else {
    # Default: look next to script
    $envPath = Join-Path $script:ScriptDir ".env"
}

$envLoaded = $false
if ($envPath -and (Test-Path $envPath)) {
    Import-EnvFile -Path $envPath
    $envLoaded = $true
}

# ── Apply CLI overrides ──────────────────────────────────────────────────────

# CLI -NdusCookie overrides .env and config
if ($NdusCookie) {
    $script:Config.NdusCookie = $NdusCookie
}
# Fallback to $env:TERABOX_NDUS if still empty
if (-not $script:Config.NdusCookie -and $env:TERABOX_NDUS) {
    $script:Config.NdusCookie = $env:TERABOX_NDUS
}

# CLI -OutputDir overrides config
if ($OutputDir) {
    $script:Config.OutputDir = $OutputDir
}

# CLI -MaxRetries overrides config (default param is -1 = not specified)
if ($MaxRetries -ge 0) {
    $script:Config.MaxRetries = $MaxRetries
}

# CLI -NoResume overrides config
if ($NoResume) {
    $script:Config.Resume = $false
}

# CLI -NoLog overrides config
if ($NoLog) {
    $script:Config.LogFile = $null
}

# CLI -NoArchive overrides config
if ($NoArchive) {
    $script:Config.ArchiveFile = $null
}

# CLI -Threads overrides config
if ($Threads -gt 0) {
    $script:Config.Threads = $Threads
}

# ── Finalize resolved config values ─────────────────────────────────────────

$script:BaseUrl    = "https://www.terabox.com"
$script:AppId      = $script:Config.AppId
$script:TimeoutSec = $script:Config.TimeoutSec
$script:MaxRetries = $script:Config.MaxRetries

# Resolve LogFile path robustly
if ($script:Config.LogFile) {
    if (-not [System.IO.Path]::IsPathRooted($script:Config.LogFile)) {
        $script:Config.LogFile = Join-Path $script:ScriptDir $script:Config.LogFile
    }
    else {
        $parentDir = Split-Path -Parent $script:Config.LogFile
        if ($parentDir -and -not (Test-Path $parentDir)) {
            $logName = Split-Path -Leaf $script:Config.LogFile
            if (-not $logName) { $logName = "terabox-dl.log.csv" }
            $script:Config.LogFile = Join-Path $script:ScriptDir $logName
        }
    }
}

# Resolve ArchiveFile path
$script:ArchiveFilePath = $null
if ($script:Config.ArchiveFile) {
    if ([System.IO.Path]::IsPathRooted($script:Config.ArchiveFile)) {
        $script:ArchiveFilePath = $script:Config.ArchiveFile
    }
    else {
        $script:ArchiveFilePath = Join-Path $script:ScriptDir $script:Config.ArchiveFile
    }
}

$script:Headers = @{
    "User-Agent"       = $script:Config.UserAgent
    "Accept"           = "application/json, text/plain, */*"
    "Accept-Language"  = "en-US,en;q=0.9"
    "Referer"          = "https://www.terabox.com/"
    "X-Requested-With" = "XMLHttpRequest"
}

# Track stats
$script:Stats = @{
    TotalFiles = 0
    Downloaded = 0
    Skipped    = 0
    Failed     = 0
    TotalBytes = [long]0
    StartTime  = $null
}

$script:DownloadQueue = [System.Collections.Generic.List[PSCustomObject]]::new()

# ══════════════════════════════════════════════════════════════════════════════
# ── LOGGING ──────────────────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════

function Initialize-LogFile {
    if (-not $script:Config.LogFile) { return }

    $logDir = Split-Path -Parent $script:Config.LogFile
    if ($logDir -and -not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    # Create CSV header if file doesn't exist
    if (-not (Test-Path $script:Config.LogFile)) {
        "Timestamp,Status,ShareUrl,FileName,FileSize,DownloadedBytes,Speed,Duration,OutputPath,ErrorMessage" |
            Out-File -FilePath $script:Config.LogFile -Encoding UTF8
    }
}

function Write-LogEntry {
    param(
        [string]$Status,       # SUCCESS, SKIPPED, FAILED, INFO
        [string]$ShareUrl,
        [string]$FileName,
        [long]$FileSize        = 0,
        [long]$DownloadedBytes = 0,
        [string]$Speed         = "",
        [string]$Duration      = "",
        [string]$OutputPath    = "",
        [string]$ErrorMessage  = ""
    )

    if (-not $script:Config.LogFile) { return }

    # Apply log level filter
    $level = $script:Config.LogLevel
    if ($level -eq "errors" -and $Status -ne "FAILED") { return }
    if ($level -eq "downloads" -and $Status -eq "INFO") { return }

    # Escape CSV fields
    $escapeCsv = { param($s) if ($s -match '[,"\n]') { '"{0}"' -f ($s -replace '"', '""') } else { $s } }

    $entry = @(
        (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),
        $Status,
        (& $escapeCsv $ShareUrl),
        (& $escapeCsv $FileName),
        $FileSize,
        $DownloadedBytes,
        $Speed,
        $Duration,
        (& $escapeCsv $OutputPath),
        (& $escapeCsv $ErrorMessage)
    ) -join ","

    $entry | Out-File -FilePath $script:Config.LogFile -Encoding UTF8 -Append
}

# ══════════════════════════════════════════════════════════════════════════════
# ── HELPERS ──────────────────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════

function Format-FileSize([long]$Bytes) {
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Format-Speed([double]$BytesPerSec) {
    if ($BytesPerSec -ge 1MB) { return "{0:N2} MB/s" -f ($BytesPerSec / 1MB) }
    if ($BytesPerSec -ge 1KB) { return "{0:N2} KB/s" -f ($BytesPerSec / 1KB) }
    return "{0:N0} B/s" -f $BytesPerSec
}

function Format-Duration([TimeSpan]$Duration) {
    if ($Duration.TotalHours -ge 1) {
        return "{0:N0}h {1:N0}m {2:N0}s" -f $Duration.TotalHours, $Duration.Minutes, $Duration.Seconds
    }
    if ($Duration.TotalMinutes -ge 1) {
        return "{0:N0}m {1:N0}s" -f [Math]::Floor($Duration.TotalMinutes), $Duration.Seconds
    }
    return "{0:N1}s" -f $Duration.TotalSeconds
}

function Write-ColorLine([string]$Text, [ConsoleColor]$Color = "White") {
    Write-Host $Text -ForegroundColor $Color
}

function Get-SafeFileName([string]$Name) {
    if ([string]::IsNullOrEmpty($Name)) { return "unnamed_file" }
    $clean = [System.IO.Path]::GetFileName($Name)
    $clean = $clean -replace '[<>:"/\\|?*\x00-\x1F]', '_'
    if ([string]::IsNullOrEmpty($clean) -or $clean -eq "." -or $clean -eq "..") {
        return "file_" + [Guid]::NewGuid().ToString().Substring(0,8)
    }
    return $clean
}

# Helper function to check if a share key is archived
function Test-IsKeyArchived([string]$Key) {
    if (-not $script:ArchiveFilePath -or -not (Test-Path $script:ArchiveFilePath)) {
        return $false
    }
    try {
        $content = Get-Content -Path $script:ArchiveFilePath
        foreach ($line in $content) {
            if ($line.Trim() -eq $Key) {
                return $true
            }
        }
    }
    catch {}
    return $false
}

# Helper function to archive a share key
function Add-KeyToArchive([string]$Key) {
    if (-not $script:ArchiveFilePath) { return }
    try {
        # Ensure parent directory exists
        $dir = Split-Path -Parent $script:ArchiveFilePath
        if ($dir -and -not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $Key | Out-File -FilePath $script:ArchiveFilePath -Append -Encoding utf8
    }
    catch {
        Write-ColorLine "⚠ Failed to write to archive file: $($_.Exception.Message)" Yellow
    }
}

function Write-Banner {
    Write-Host ""
    Write-ColorLine "╔══════════════════════════════════════════╗" Cyan
    Write-ColorLine "║         TeraBox Downloader v2.1          ║" Cyan
    Write-ColorLine "║     Unofficial API · Cookie Auth         ║" Cyan
    Write-ColorLine "║  Config · .env · Log · Retry · Resume    ║" Cyan
    Write-ColorLine "╚══════════════════════════════════════════╝" Cyan
    Write-Host ""
}

# ── Error code mapping ─────────────────────────────────────────────────────────

function Get-TeraboxErrorMessage([int]$ErrorCode) {
    $errorMap = @{
        -1      = "Server error or rate limited. Try again later."
        -3      = "Invalid or missing parameters in request."
        -6      = "Share link has expired or been removed."
        -7      = "File or share requires a password."
        -9      = "File does not exist or has been deleted."
        -12     = "Insufficient storage space on your account."
        -20     = "Session expired. Please refresh your ndus cookie."
        -21     = "Share link has been banned/restricted."
        -32     = "Exceeded download frequency limit. Wait and retry."
        -33     = "File too large for free-tier download."
        2       = "Download link expired. Re-fetching..."
        4       = "Request too frequent. Please wait."
        12      = "Access denied — cookie may be invalid or expired."
        31      = "Sign/token verification failed. Cookie may need refresh."
        105     = "Invalid share link format."
        112     = "Session expired or cookie invalid. Please re-authenticate."
        118     = "Download quota exceeded for this file."
        400210  = "jsToken missing or invalid. Will auto-refresh."
        4000023 = "jsToken expired. Will auto-refresh."
    }

    if ($errorMap.ContainsKey($ErrorCode)) {
        return $errorMap[$ErrorCode]
    }
    return "Unknown API error (code: $ErrorCode)."
}

# ── Create a session with cookies ──────────────────────────────────────────────

function New-TeraboxSession([string]$Ndus) {
    $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()

    $ndusCk = [System.Net.Cookie]::new("ndus", $Ndus, "/", ".terabox.com")
    $langCk = [System.Net.Cookie]::new("lang", "en", "/", ".terabox.com")

    $session.Cookies.Add($ndusCk)
    $session.Cookies.Add($langCk)

    return $session
}

# ── Fetch jsToken from TeraBox pages ───────────────────────────────────────────
# TeraBox embeds a jsToken in HTML inside a URL-encoded script tag.
# This method fetches from the target page (e.g. share link) and falls back to the homepage.

function Get-JsToken {
    param(
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [string]$TargetUrl = $null
    )

    $urlsToTry = @()
    if ($TargetUrl) {
        $urlsToTry += $TargetUrl
    }
    if ($TargetUrl -ne $script:BaseUrl) {
        $urlsToTry += $script:BaseUrl
    }

    foreach ($url in $urlsToTry) {
        Write-ColorLine "⟳ Fetching jsToken from $url..." Yellow
        try {
            $resp = Invoke-WebRequest -Uri $url `
                -Headers $script:Headers `
                -WebSession $Session `
                -TimeoutSec 30 `
                -MaximumRedirection 5 `
                -UseBasicParsing

            $html = $resp.Content

            # ── Primary pattern (AList method) ─────────────────────────────────
            # The markers include literal backtick characters (` ) around the URL-encoded JS.
            $startMarker = '`function%20fn%28a%29%7Bwindow.jsToken%20%3D%20a%7D%3Bfn%28%22'
            $endMarker   = '%22%29`'

            $startIdx = $html.IndexOf($startMarker)
            if ($startIdx -ge 0) {
                $tokenStart = $startIdx + $startMarker.Length
                $endIdx = $html.IndexOf($endMarker, $tokenStart)
                if ($endIdx -gt $tokenStart) {
                    $token = $html.Substring($tokenStart, $endIdx - $tokenStart)
                    if ($token -and $token.Length -gt 0) {
                        Write-ColorLine "✓ jsToken acquired ($($token.Length) chars)" Green
                        return $token
                    }
                }
            }

            # ── Fallback 1: without backticks ──────────────────────────────────
            $startMarkerAlt = 'function%20fn%28a%29%7Bwindow.jsToken%20%3D%20a%7D%3Bfn%28%22'
            $endMarkerAlt   = '%22%29'

            $startIdx = $html.IndexOf($startMarkerAlt)
            if ($startIdx -ge 0) {
                $tokenStart = $startIdx + $startMarkerAlt.Length
                $endIdx = $html.IndexOf($endMarkerAlt, $tokenStart)
                if ($endIdx -gt $tokenStart) {
                    $token = $html.Substring($tokenStart, $endIdx - $tokenStart)
                    if ($token -and $token.Length -gt 0) {
                        Write-ColorLine "✓ jsToken acquired via alt pattern ($($token.Length) chars)" Green
                        return $token
                    }
                }
            }

            # ── Fallback 2: decoded JS patterns ───────────────────────────────
            if ($html -match 'window\.jsToken\s*=\s*["\u0027]([a-zA-Z0-9_.-]+)["\u0027]') {
                $token = $Matches[1]
                if ($token -and $token.Length -gt 0) {
                    Write-ColorLine "✓ jsToken acquired via window.jsToken ($($token.Length) chars)" Green
                    return $token
                }
            }

            if ($html -match '["\u0027]jsToken["\u0027]\s*:\s*["\u0027]([a-zA-Z0-9_.-]+)["\u0027]') {
                $token = $Matches[1]
                if ($token -and $token.Length -gt 0) {
                    Write-ColorLine "✓ jsToken acquired via JSON pattern ($($token.Length) chars)" Green
                    return $token
                }
            }

            # ── Fallback 3: fn("TOKEN") pattern ───────────────────────────────
            if ($html -match 'fn\(\s*["\u0027]([a-zA-Z0-9_.-]{16,})["\u0027]\s*\)') {
                $token = $Matches[1]
                if ($token -and $token.Length -gt 0) {
                    Write-ColorLine "✓ jsToken acquired via fn() pattern ($($token.Length) chars)" Green
                    return $token
                }
            }

            Write-ColorLine "⚠ Could not extract jsToken from $url." Yellow
        }
        catch {
            Write-ColorLine "⚠ Failed to fetch jsToken from $($url): $($_.Exception.Message)" Yellow
        }
    }

    Write-ColorLine "✗ Could not extract jsToken from any source." Red
    Write-ColorLine "  You can manually set TERABOX_JSTOKEN in your .env file." DarkGray
    return $null
}

# ── Extract the short-url key from various link formats ────────────────────────

function Get-ShortUrlKey([string]$RawUrl) {
    # Normalise: strip trailing slashes/whitespace
    $RawUrl = $RawUrl.Trim().TrimEnd('/')

    # Handle formats:
    #   https://www.terabox.com/s/1ABCxyz
    #   https://terabox.com/s/1ABCxyz
    #   https://www1.terabox.com/s/1ABCxyz
    #   https://www.terabox.app/s/1ABCxyz
    #   https://teraboxapp.com/s/1ABCxyz
    #   https://1024terabox.com/s/1ABCxyz
    #   https://freeterabox.com/s/1ABCxyz
    #   1ABCxyz  (bare key)

    if ($RawUrl -match '[/]s[/](.+)$') {
        return $Matches[1]
    }

    # If it looks like a bare key (no slashes, no protocol)
    if ($RawUrl -notmatch '[:/]') {
        return $RawUrl
    }

    Write-ColorLine "✗ Could not extract share key from URL: $RawUrl" Red
    throw "Invalid TeraBox URL format."
}

# ── API request with retry ─────────────────────────────────────────────────────

function Invoke-TeraboxApi {
    param(
        [string]$Uri,
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [string]$Description = "API call",
        [int]$Retries = 3
    )

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            $resp = Invoke-RestMethod -Uri $Uri -Headers $script:Headers -WebSession $Session -Method Get -TimeoutSec 30
            return $resp
        }
        catch {
            if ($attempt -lt $Retries) {
                $waitSec = [Math]::Pow(2, $attempt) + (Get-Random -Minimum 0.0 -Maximum 1.0)
                Write-ColorLine "  ⚠ $Description failed (attempt $attempt/$Retries): $($_.Exception.Message)" Yellow
                Write-ColorLine "    Retrying in $([Math]::Round($waitSec, 1))s..." DarkGray
                Start-Sleep -Milliseconds ([int]($waitSec * 1000))
            }
            else {
                Write-ColorLine "  ✗ $Description failed after $Retries attempts: $($_.Exception.Message)" Red
                throw
            }
        }
    }
}

# ── Step 1: Resolve the shared link ────────────────────────────────────────────

function Get-ShareInfo {
    param(
        [string]$ShortUrl,
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session
    )

    Write-ColorLine "⟳ Resolving shared link..." Yellow

    $params = @{
        shorturl = $ShortUrl
        root     = "1"
        app_id   = $script:AppId
        web      = "1"
        channel  = "dubox"
        clienttype = "0"
    }
    if ($script:JsToken) {
        $params["jsToken"] = $script:JsToken
    }

    $uri = "$($script:BaseUrl)/api/shorturlinfo?$( ($params.GetEnumerator() | ForEach-Object { "$($_.Key)=$([uri]::EscapeDataString($_.Value))" }) -join '&' )"

    $resp = Invoke-TeraboxApi -Uri $uri -Session $Session -Description "Resolve share link" -Retries $script:MaxRetries

    # Handle jsToken refresh errors
    if ($resp.errno -and ($resp.errno -eq 400210 -or $resp.errno -eq 4000023)) {
        Write-ColorLine "  ⚠ jsToken invalid/expired — refreshing..." Yellow
        $script:JsToken = Get-JsToken -Session $Session -TargetUrl "https://www.terabox.com/s/$ShortUrl"
        if ($script:JsToken) {
            # Rebuild URI with new jsToken
            $params["jsToken"] = $script:JsToken
            $uri = "$($script:BaseUrl)/api/shorturlinfo?$( ($params.GetEnumerator() | ForEach-Object { "$($_.Key)=$([uri]::EscapeDataString($_.Value))" }) -join '&' )"
            $resp = Invoke-TeraboxApi -Uri $uri -Session $Session -Description "Resolve share link (retry)" -Retries $script:MaxRetries
        }
    }

    if ($resp.errno -and $resp.errno -ne 0) {
        $errMsg = Get-TeraboxErrorMessage -ErrorCode $resp.errno
        Write-ColorLine "✗ $errMsg" Red
        Write-LogEntry -Status "FAILED" -ShareUrl $Url -FileName "(resolve)" -ErrorMessage $errMsg
        throw $errMsg
    }

    $shareInfo = [PSCustomObject]@{
        ShareId   = $resp.shareid
        Uk        = $resp.uk
        Sign      = $resp.sign
        Timestamp = $resp.timestamp
        Randsk    = $resp.randsk
        Title     = $resp.title
        FileList  = $resp.list
    }

    Write-ColorLine "✓ Share resolved: $($shareInfo.Title ?? 'Shared Files')" Green
    Write-LogEntry -Status "INFO" -ShareUrl $Url -FileName "(resolved: $($shareInfo.Title ?? 'Shared Files'))"

    return $shareInfo
}

# ── Step 2: List files in a folder (for directory entries) ─────────────────────

function Get-FolderContents {
    param(
        [string]$ShareId,
        [string]$Uk,
        [string]$Sign,
        [string]$Timestamp,
        [string]$Dir,
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [int]$Page = 1,
        [int]$Limit = 100
    )

    $allItems = @()
    $currentPage = $Page

    # Paginate through all results
    do {
        $params = @{
            shareid    = $ShareId
            uk         = $Uk
            sign       = $Sign
            timestamp  = $Timestamp
            dir        = $Dir
            root       = if ($Dir -eq "/") { "1" } else { "0" }
            app_id     = $script:AppId
            web        = "1"
            channel    = "dubox"
            clienttype = "0"
            page       = $currentPage
            num        = $Limit
            order      = "name"
        }
        if ($script:JsToken) {
            $params["jsToken"] = $script:JsToken
        }

        $uri = "$($script:BaseUrl)/share/list?$( ($params.GetEnumerator() | ForEach-Object { "$($_.Key)=$([uri]::EscapeDataString("$($_.Value)"))" }) -join '&' )"

        try {
            $resp = Invoke-TeraboxApi -Uri $uri -Session $Session -Description "List folder '$Dir' (page $currentPage)" -Retries $script:MaxRetries
        }
        catch {
            Write-ColorLine "  ✗ Failed to list folder '$Dir': $($_.Exception.Message)" Red
            return $allItems
        }

        # Handle jsToken refresh errors
        if ($resp.errno -and ($resp.errno -eq 400210 -or $resp.errno -eq 4000023)) {
            Write-ColorLine "  ⚠ jsToken invalid/expired — refreshing..." Yellow
            $script:JsToken = Get-JsToken -Session $Session -TargetUrl "https://www.terabox.com/s/$($script:CurrentShortUrl)"
            if ($script:JsToken) {
                # Rebuild URI with new jsToken and retry
                $params["jsToken"] = $script:JsToken
                $uri = "$($script:BaseUrl)/share/list?$( ($params.GetEnumerator() | ForEach-Object { "$($_.Key)=$([uri]::EscapeDataString("$($_.Value)"))" }) -join '&' )"
                $resp = Invoke-TeraboxApi -Uri $uri -Session $Session -Description "List folder '$Dir' (page $currentPage, retry)" -Retries $script:MaxRetries
            }
        }

        if ($resp.errno -and $resp.errno -ne 0) {
            $errMsg = Get-TeraboxErrorMessage -ErrorCode $resp.errno
            Write-ColorLine "  ✗ Folder listing error: $errMsg" Red
            return $allItems
        }

        if ($resp.list -and $resp.list.Count -gt 0) {
            $allItems += $resp.list
            $currentPage++
        }
        else {
            break
        }

        # If we got fewer than the limit, we've reached the end
    } while ($resp.list.Count -eq $Limit)

    return $allItems
}

# ── Get download link via sharedownload API ───────────────────────────────────

function Get-TeraboxDownloadLink {
    param(
        [string]$FsId,
        [string]$ShareId,
        [string]$Uk,
        [string]$Sign,
        [string]$Timestamp,
        [string]$Randsk,
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [string]$AppId = $null,
        [Hashtable]$Headers = $null
    )

    $decodedRandsk = $Randsk
    if ($decodedRandsk -like "*%*") {
        $decodedRandsk = [uri]::UnescapeDataString($decodedRandsk)
    }

    $activeAppId = if ($AppId) { $AppId } else { $script:AppId }
    $activeHeaders = if ($Headers) { $Headers } else { $script:Headers }

    $extra = '{"sekey":"' + $decodedRandsk + '"}'
    $extraEscaped = [uri]::EscapeDataString($extra)
    $data = "encrypt=0&extra=$extraEscaped&fid_list=[$FsId]&primaryid=$ShareId&uk=$Uk&product=share&type=nolimit"

    $uri = "https://www.terabox.com/api/sharedownload?app_id=$($activeAppId)&channel=chunlei&clienttype=12&sign=$Sign&timestamp=$Timestamp&web=1"

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $resp = Invoke-RestMethod -Uri $uri -Headers $activeHeaders -WebSession $Session -Method Post -ContentType "application/x-www-form-urlencoded" -Body $data -TimeoutSec 15
            if ($resp.errno -eq 0 -and $resp.list -and $resp.list.Count -gt 0) {
                return $resp.list[0].dlink
            }
            $errMsg = if ($resp.errmsg) { $resp.errmsg } else { "errno $($resp.errno)" }
            Write-ColorLine "  ⚠ sharedownload API error: $errMsg" Yellow
        }
        catch {
            Write-ColorLine "  ⚠ sharedownload request failed (attempt $attempt/3): $($_.Exception.Message)" Yellow
            Start-Sleep -Seconds 1
        }
    }
    return $null
}

# ── Step 3: Download a single file with retry and resume ───────────────────────

function Save-TeraboxFile {
    param(
        [PSCustomObject]$FileItem,
        [string]$DestDir,
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [string]$ShareId,
        [string]$Uk,
        [string]$Sign,
        [string]$Timestamp,
        [string]$Randsk,
        [string]$Url = $null
    )

    $activeUrl = if ($Url) { $Url } else { $script:Url }
    $fileName = Get-SafeFileName $FileItem.server_filename
    $fileSize = [long]$FileItem.size
    $dlink    = $FileItem.dlink

    if (-not $dlink) {
        if ($ShareId -and $Uk -and $Sign -and $Timestamp -and $Randsk) {
            Write-ColorLine "  ⟳ Fetching direct download link for '$fileName'..." Yellow
            $dlink = Get-TeraboxDownloadLink -FsId $FileItem.fs_id -ShareId $ShareId -Uk $Uk -Sign $Sign -Timestamp $Timestamp -Randsk $Randsk -Session $Session
        }
    }

    if (-not $dlink) {
        Write-ColorLine "  ⚠ No download link available for '$fileName' — skipping." Yellow
        Write-LogEntry -Status "FAILED" -ShareUrl $activeUrl -FileName $fileName -FileSize $fileSize -ErrorMessage "No dlink available"
        $script:Stats.Failed++
        return
    }

    $destPath = Join-Path $DestDir $fileName

    # Skip if file already exists and matches size
    if (Test-Path $destPath) {
        $existing = Get-Item $destPath
        if ($existing.Length -eq $fileSize) {
            Write-ColorLine "  ⊘ Already exists (same size): $fileName" DarkGray
            Write-LogEntry -Status "SKIPPED" -ShareUrl $activeUrl -FileName $fileName -FileSize $fileSize -OutputPath $destPath
            $script:Stats.Skipped++
            return
        }
    }

    $sizeStr = Format-FileSize $fileSize

    # Retry loop
    for ($attempt = 1; $attempt -le $script:MaxRetries; $attempt++) {
        try {
            # Check for resume capability
            $resumeBytePos = [long]0
            if ($script:Config.Resume -and (Test-Path $destPath)) {
                $resumeBytePos = (Get-Item $destPath).Length
                if ($resumeBytePos -gt 0 -and $resumeBytePos -lt $fileSize) {
                    $remainStr = Format-FileSize ($fileSize - $resumeBytePos)
                    Write-ColorLine "  ↓ Resuming: $fileName ($remainStr remaining of $sizeStr)" Cyan
                }
                elseif ($resumeBytePos -ge $fileSize) {
                    # File is already fully downloaded or larger
                    Write-ColorLine "  ⊘ Already exists: $fileName" DarkGray
                    Write-LogEntry -Status "SKIPPED" -ShareUrl $activeUrl -FileName $fileName -FileSize $fileSize -OutputPath $destPath
                    $script:Stats.Skipped++
                    return
                }
            }
            else {
                Write-ColorLine "  ↓ Downloading: $fileName ($sizeStr)$(if ($attempt -gt 1) { " [retry $attempt/$($script:MaxRetries)]" })" Cyan
            }

            # Build the download request
            $dlHeaders = $script:Headers.Clone()

            # Add Range header for resume
            if ($resumeBytePos -gt 0) {
                $dlHeaders["Range"] = "bytes=$resumeBytePos-"
            }

            $dlStartTime = [DateTime]::Now

            # Initialize HttpClient with cookie container
            $handler = [System.Net.Http.HttpClientHandler]::new()
            $handler.CookieContainer = $Session.Cookies
            $handler.UseProxy = $true
            
            $client = [System.Net.Http.HttpClient]::new($handler)
            $client.Timeout = [TimeSpan]::FromSeconds($script:TimeoutSec)

            # Build request message
            $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $dlink)
            foreach ($key in $dlHeaders.Keys) {
                $null = $request.Headers.TryAddWithoutValidation($key, $dlHeaders[$key])
            }

            # Add Range header for resume
            if ($resumeBytePos -gt 0) {
                $request.Headers.Range = [System.Net.Http.Headers.RangeHeaderValue]::new($resumeBytePos, $null)
            }

            $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $null = $response.EnsureSuccessStatusCode()

            $isAppend = $response.StatusCode -eq [System.Net.HttpStatusCode]::PartialContent
            $responseStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()

            # Prepare file stream
            $mode = if ($isAppend) { [System.IO.FileMode]::OpenOrCreate } else { [System.IO.FileMode]::Create }
            $fileStream = [System.IO.FileStream]::new($destPath, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            
            if ($isAppend) {
                $fileStream.Seek($resumeBytePos, [System.IO.SeekOrigin]::Begin) | Out-Null
                $startPos = $resumeBytePos
            } else {
                $startPos = [long]0
            }

            # Chunked download loop with speed meter
            $chunkSize = 64 * 1024 # 64 KB
            $buffer = [byte[]]::new($chunkSize)
            $totalBytesRead = $startPos
            $bytesReadThisPeriod = 0

            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $lastPeriodTime = $stopwatch.ElapsedMilliseconds

            try {
                while ($true) {
                    $read = $responseStream.Read($buffer, 0, $buffer.Length)
                    if ($read -eq 0) { break }

                    $fileStream.Write($buffer, 0, $read)
                    $totalBytesRead += $read
                    $bytesReadThisPeriod += $read

                    $currentTime = $stopwatch.ElapsedMilliseconds
                    $elapsedPeriod = $currentTime - $lastPeriodTime

                    if ($elapsedPeriod -ge 1000) { # Update speed every 1 second
                        $speedBytesPerSec = ($bytesReadThisPeriod / $elapsedPeriod) * 1000
                        $speedStr = Format-Speed $speedBytesPerSec

                        $percent = 0
                        if ($fileSize -gt 0) {
                            $percent = [int](($totalBytesRead / $fileSize) * 100)
                        }

                        # ASCII progress bar (15 chars wide)
                        $barLength = 15
                        $completedLength = [int](($percent / 100) * $barLength)
                        $remainingLength = $barLength - $completedLength
                        $bar = ("█" * $completedLength) + ("░" * $remainingLength)

                        $progressStr = "  ↓ Downloading: $fileName | [$bar] | $percent% | $speedStr"
                        Write-Host -NoNewline "`r$($progressStr.PadRight(115))"

                        $bytesReadThisPeriod = 0
                        $lastPeriodTime = $currentTime
                    }
                }
            }
            finally {
                $fileStream.Close()
                $responseStream.Close()
                $client.Dispose()
                $stopwatch.Stop()
            }

            # Print a newline to complete the progress line
            Write-Host ""

            $dlDuration = ([DateTime]::Now - $dlStartTime)

            # Verify download
            if (Test-Path $destPath) {
                $dlSize = (Get-Item $destPath).Length
                if ($dlSize -gt 0) {
                    $speedStr = if ($dlDuration.TotalSeconds -gt 0) { Format-Speed ($dlSize / $dlDuration.TotalSeconds) } else { "instant" }
                    $durationStr = Format-Duration $dlDuration

                    # Size verification
                    if ($fileSize -gt 0 -and $dlSize -ne $fileSize) {
                        Write-ColorLine "  ⚠ Size mismatch: expected $(Format-FileSize $fileSize), got $(Format-FileSize $dlSize)" Yellow
                    }
                    else {
                        Write-ColorLine "  ✓ Saved: $fileName ($(Format-FileSize $dlSize), $speedStr, $durationStr)" Green
                    }

                    Write-LogEntry -Status "SUCCESS" -ShareUrl $activeUrl -FileName $fileName `
                        -FileSize $fileSize -DownloadedBytes $dlSize `
                        -Speed $speedStr -Duration $durationStr -OutputPath $destPath

                    $script:Stats.Downloaded++
                    $script:Stats.TotalBytes += $dlSize
                    return  # Success — exit retry loop
                }
                else {
                    Write-ColorLine "  ⚠ Downloaded file is empty: $destPath" Yellow
                    Remove-Item $destPath -Force -ErrorAction SilentlyContinue
                }
            }
        }
        catch {
            $errMsg = $_.Exception.Message

            # Check for specific retriable errors
            $isRetriable = $errMsg -match "timeout|timed out|connection was closed|reset|503|502|429|rate"

            if ($attempt -lt $script:MaxRetries) {
                $waitSec = [Math]::Pow(2, $attempt) + (Get-Random -Minimum 0.0 -Maximum 2.0)
                Write-ColorLine "  ⚠ Download failed (attempt $attempt/$($script:MaxRetries)): $errMsg" Yellow

                if (-not $isRetriable) {
                    Write-ColorLine "    Error may not be retriable, but will try anyway..." DarkGray
                }

                Write-ColorLine "    Retrying in $([Math]::Round($waitSec, 1))s..." DarkGray
                Start-Sleep -Milliseconds ([int]($waitSec * 1000))
            }
            else {
                Write-ColorLine "  ✗ Download failed after $($script:MaxRetries) attempts for '$fileName': $errMsg" Red

                Write-LogEntry -Status "FAILED" -ShareUrl $activeUrl -FileName $fileName `
                    -FileSize $fileSize -ErrorMessage $errMsg

                # Clean up partial download only if resume is disabled
                if (-not $script:Config.Resume -and (Test-Path $destPath)) {
                    Remove-Item $destPath -Force -ErrorAction SilentlyContinue
                }
                elseif (Test-Path $destPath) {
                    $partialSize = (Get-Item $destPath).Length
                    if ($partialSize -gt 0) {
                        Write-ColorLine "    Partial file kept ($(Format-FileSize $partialSize)) — re-run to resume." DarkGray
                    }
                    else {
                        Remove-Item $destPath -Force -ErrorAction SilentlyContinue
                    }
                }

                $script:Stats.Failed++
            }
        }
    }
}

# ── Recursive processor for files/folders ──────────────────────────────────────

function Invoke-ProcessItems {
    param(
        [array]$Items,
        [string]$DestDir,
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session,
        [string]$ShareId,
        [string]$Uk,
        [string]$Sign,
        [string]$Timestamp,
        [string]$Randsk,
        [string]$Url,
        [int]$Depth = 0
    )

    $indent = "  " * $Depth

    foreach ($item in $Items) {
        $isDir = $item.isdir -eq 1

        if ($isDir) {
            $folderName = $item.server_filename
            $folderPath = $item.path

            Write-ColorLine "${indent}📁 $folderName/" Yellow

            if (-not $ListOnly) {
                $subDir = Join-Path $DestDir $folderName
                if (-not (Test-Path $subDir)) {
                    New-Item -ItemType Directory -Path $subDir -Force | Out-Null
                }
            }

            # Recursively list and process folder contents
            $subItems = Get-FolderContents `
                -ShareId $ShareId `
                -Uk $Uk `
                -Sign $Sign `
                -Timestamp $Timestamp `
                -Dir $folderPath `
                -Session $Session

            if ($subItems -and @($subItems).Count -gt 0) {
                Invoke-ProcessItems `
                    -Items $subItems `
                    -DestDir $(if ($ListOnly) { $DestDir } else { $subDir }) `
                    -Session $Session `
                    -ShareId $ShareId `
                    -Uk $Uk `
                    -Sign $Sign `
                    -Timestamp $Timestamp `
                    -Randsk $Randsk `
                    -Url $Url `
                    -Depth ($Depth + 1)
            }
            else {
                Write-ColorLine "${indent}  (empty folder)" DarkGray
            }
        }
        else {
            $name = $item.server_filename
            $size = Format-FileSize ([long]$item.size)
            $script:Stats.TotalFiles++

            if ($ListOnly) {
                Write-ColorLine "${indent}📄 $name  ($size)" White
            }
            else {
                Write-ColorLine "${indent}📄 $name  ($size) [queued]" DarkGray
                $script:DownloadQueue.Add([PSCustomObject]@{
                    FileItem  = $item
                    DestDir   = $DestDir
                    ShareId   = $ShareId
                    Uk        = $Uk
                    Sign      = $Sign
                    Timestamp = $Timestamp
                    Randsk    = $Randsk
                    Url       = $Url
                })
            }
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
# ── MAIN ──────────────────────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════

Write-Banner

# ── Show config sources ──────────────────────────────────────────────────────
Write-ColorLine "── Configuration ────────────────────────────" DarkCyan
if ($cfgLoaded) {
    Write-ColorLine "   Config:  $cfgPath" DarkGray
}
else {
    Write-ColorLine "   Config:  (none found — using defaults)" DarkGray
}
if ($envLoaded) {
    Write-ColorLine "   Env:     $envPath" DarkGray
}
else {
    Write-ColorLine "   Env:     (none found)" DarkGray
}
if ($script:Config.LogFile) {
    Write-ColorLine "   Log:     $($script:Config.LogFile)" DarkGray
}
else {
    Write-ColorLine "   Log:     (disabled)" DarkGray
}
Write-Host ""

# ── Validate ndus cookie ──────────────────────────────────────────────────────
if (-not $script:Config.NdusCookie) {
    Write-ColorLine "✗ No ndus cookie provided!" Red
    Write-Host ""
    Write-Host "You must provide your TeraBox session cookie. Options:" -ForegroundColor Yellow
    Write-Host "  1) Add it to the .env file:  TERABOX_NDUS=your_value" -ForegroundColor Gray
    Write-Host "  2) Pass -NdusCookie 'your_value'" -ForegroundColor Gray
    Write-Host "  3) Set `$env:TERABOX_NDUS = 'your_value'" -ForegroundColor Gray
    Write-Host ""
    Write-Host ".env file location:" -ForegroundColor Yellow
    Write-Host "  $envPath" -ForegroundColor Gray
    Write-Host ""
    Write-Host "To get your ndus cookie:" -ForegroundColor Yellow
    Write-Host "  1. Log in at https://www.terabox.com" -ForegroundColor Gray
    Write-Host "  2. Open DevTools (F12) → Application → Cookies" -ForegroundColor Gray
    Write-Host "  3. Copy the 'ndus' value from terabox.com" -ForegroundColor Gray
    Write-Host ""
    exit 1
}

# ── Initialize logging ───────────────────────────────────────────────────────
Initialize-LogFile

# ── Parse URL or Input File ───────────────────────────────────────────────────
$urlsToProcess = @()
if (Test-Path $Url -PathType Leaf) {
    $fileContent = Get-Content -Path $Url
    foreach ($line in $fileContent) {
        if ($line -match 'https?://[^\s"''<>]+') {
            $urlsToProcess += $Matches[0]
        }
    }
    if ($urlsToProcess.Count -eq 0) {
        Write-ColorLine "✗ No valid URLs found in file: $Url" Red
        exit 1
    }
    Write-ColorLine "📄 Batch Mode: Found $($urlsToProcess.Count) URLs in file: $Url" Green
    Write-Host ""
}
else {
    if ($Url -match 'https?://[^\s"''<>]+') {
        $urlsToProcess += $Matches[0]
    }
    else {
        $urlsToProcess += $Url
    }
}

# ── Create session ─────────────────────────────────────────────────────────────
$session = New-TeraboxSession -Ndus $script:Config.NdusCookie

# ── Prepare output directory ──────────────────────────────────────────────────
$resolvedOutputDir = $script:Config.OutputDir
if (-not [System.IO.Path]::IsPathRooted($resolvedOutputDir)) {
    $resolvedOutputDir = Join-Path $script:ScriptDir $resolvedOutputDir
}
$resolvedOutputDir = [IO.Path]::GetFullPath($resolvedOutputDir)
$drive = Split-Path -Qualifier $resolvedOutputDir
if ($drive -and -not (Test-Path $drive)) {
    $fallbackDir = Join-Path $script:ScriptDir "Downloads"
    Write-ColorLine "⚠ Configured output directory points to a non-existent drive '$drive'." Yellow
    Write-ColorLine "  Falling back to script directory: $fallbackDir" Yellow
    $resolvedOutputDir = $fallbackDir
}

if (-not $ListOnly) {
    if (-not (Test-Path $resolvedOutputDir)) {
        try {
            New-Item -ItemType Directory -Path $resolvedOutputDir -Force | Out-Null
        }
        catch {
            $fallbackDir = Join-Path $script:ScriptDir "Downloads"
            Write-ColorLine "⚠ Failed to create '$resolvedOutputDir': $($_.Exception.Message)" Yellow
            Write-ColorLine "  Falling back to script directory: $fallbackDir" Yellow
            $resolvedOutputDir = $fallbackDir
            if (-not (Test-Path $resolvedOutputDir)) {
                New-Item -ItemType Directory -Path $resolvedOutputDir -Force | Out-Null
            }
        }
    }
    Write-ColorLine "📂 Output: $resolvedOutputDir" DarkGray
}

$script:Stats.StartTime = [DateTime]::Now

if ($ListOnly) {
    Write-ColorLine "── File Listing (no download) ────────────────" DarkCyan
}
else {
    Write-ColorLine "── Downloading ──────────────────────────────" DarkCyan
}

$script:DownloadQueue.Clear()
$urlIdx = 1
$totalUrls = $urlsToProcess.Count

foreach ($currentUrl in $urlsToProcess) {
    # Reassign script parameter so all downstream functions use the active URL
    $Url = $currentUrl

    if ($totalUrls -gt 1) {
        Write-ColorLine "`n[Link $urlIdx/$totalUrls] Processing: $currentUrl" Cyan
    }

    try {
        # ── Parse the URL ──────────────────────────────────────────────────────────
        $shortUrlKey = Get-ShortUrlKey -RawUrl $Url
        $script:CurrentShortUrl = $shortUrlKey

        # ── Check if already archived ──────────────────────────────────────────────
        if (Test-IsKeyArchived -Key $shortUrlKey) {
            Write-ColorLine "⊘ Already fully downloaded (archived): $shortUrlKey" Green
            $urlIdx++
            continue
        }

        Write-ColorLine "🔗 Share key: $shortUrlKey" DarkGray

        # ── Fetch jsToken ──────────────────────────────────────────────────────────
        if ($script:Config.JsToken) {
            $script:JsToken = $script:Config.JsToken
        }
        else {
            $script:JsToken = Get-JsToken -Session $session -TargetUrl "https://www.terabox.com/s/$shortUrlKey"
        }

        # ── Resolve the shared link ───────────────────────────────────────────────
        $shareInfo = Get-ShareInfo -ShortUrl $shortUrlKey -Session $session

        if (-not $shareInfo.FileList -or $shareInfo.FileList.Count -eq 0) {
            Write-ColorLine "✗ No files found in this shared link." Red
            $urlIdx++
            continue
        }

        # ── Interactive Selector ───────────────────────────────────────────────────
        if ($Interactive) {
            Write-ColorLine "`n── Interactive Selector ──────────────────────" Cyan
            $selectIdx = 1
            foreach ($item in $shareInfo.FileList) {
                $isDir = $item.isdir -eq 1
                $sizeStr = if ($isDir) { "(folder)" } else { Format-FileSize $item.size }
                if ($isDir) {
                    Write-Host "  [$selectIdx] " -NoNewline
                    Write-ColorLine "📁 $($item.server_filename)/" Yellow
                } else {
                    Write-Host "  [$selectIdx] " -NoNewline
                    Write-Host "$($item.server_filename) " -NoNewline
                    Write-ColorLine "($sizeStr)" DarkGray
                }
                $selectIdx++
            }
            Write-Host ""
            $selection = Read-Host "Select items to download (comma-separated numbers, e.g. 1,3 or 'all')"
            if ($selection.Trim() -and $selection.Trim() -ne "all") {
                $indices = $selection.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
                $filteredList = @()
                foreach ($idxVal in $indices) {
                    if ($idxVal -ge 1 -and $idxVal -lt $selectIdx) {
                        $filteredList += $shareInfo.FileList[$idxVal - 1]
                    }
                }
                if ($filteredList.Count -eq 0) {
                    Write-ColorLine "⚠ No valid items selected. Skipping this URL." Yellow
                    $urlIdx++
                    continue
                }
                $shareInfo.FileList = $filteredList
            }
        }

        # ── Summary for this URL ───────────────────────────────────────────────────
        $totalFiles   = ($shareInfo.FileList | Where-Object { $_.isdir -ne 1 }).Count
        $totalFolders = ($shareInfo.FileList | Where-Object { $_.isdir -eq 1 }).Count
        $totalSize    = ($shareInfo.FileList | Where-Object { $_.isdir -ne 1 } | Measure-Object -Property size -Sum).Sum

        Write-ColorLine "   Contents: $totalFiles files, $totalFolders folders ($(Format-FileSize $totalSize))" DarkGray

        # ── Process items ──────────────────────────────────────────────────────────
        Invoke-ProcessItems `
            -Items $shareInfo.FileList `
            -DestDir $resolvedOutputDir `
            -Session $session `
            -ShareId $shareInfo.ShareId `
            -Uk $shareInfo.Uk `
            -Sign $shareInfo.Sign `
            -Timestamp $shareInfo.Timestamp `
            -Randsk $shareInfo.Randsk `
            -Url $Url
    }
    catch {
        Write-ColorLine "✗ Failed to process URL $($currentUrl): $($_.Exception.Message)" Red
    }

    $urlIdx++
}

# ── Execute downloads for all queued files ─────────────────────────────────────
if (-not $ListOnly -and $script:DownloadQueue.Count -gt 0) {
    $threads = $script:Config.Threads
    $failuresBefore = $script:Stats.Failed

    if ($script:DownloadQueue.Count -eq 1 -or $threads -le 1) {
        # Sequential mode (for single file or when forced, with live speed meter)
        foreach ($queueItem in $script:DownloadQueue) {
            Save-TeraboxFile `
                -FileItem $queueItem.FileItem `
                -DestDir $queueItem.DestDir `
                -Session $session `
                -ShareId $queueItem.ShareId `
                -Uk $queueItem.Uk `
                -Sign $queueItem.Sign `
                -Timestamp $queueItem.Timestamp `
                -Randsk $queueItem.Randsk `
                -Url $queueItem.Url
        }
    }
    else {
        # Parallel mode
        Write-ColorLine "`n⚡ Downloading $($script:DownloadQueue.Count) files in parallel (Threads: $threads)..." Cyan
        
        # Setup shared variables
        $headers = $script:Headers
        $timeoutSec = $script:TimeoutSec
        $maxRetries = $script:MaxRetries
        $resume = $script:Config.Resume
        $appId = $script:AppId
        
        $results = $script:DownloadQueue | ForEach-Object -Parallel {
            $queueItem = $_
            $fileName = $queueItem.FileItem.server_filename
            $fileSize = [long]$queueItem.FileItem.size
            $dlink    = $queueItem.FileItem.dlink
            $destPath = Join-Path $queueItem.DestDir $fileName

            # Fetch variables from using
            $session = $using:session
            $shareId = $queueItem.ShareId
            $uk = $queueItem.Uk
            $sign = $queueItem.Sign
            $timestamp = $queueItem.Timestamp
            $randsk = $queueItem.Randsk
            $headers = $using:headers
            $timeoutSec = $using:timeoutSec
            $maxRetries = $using:maxRetries
            $resume = $using:resume
            $appId = $using:appId
            $url = $queueItem.Url

            # ── Fetch direct link if needed ─────────────────────────────────
            if (-not $dlink -and $shareId -and $uk -and $sign -and $timestamp -and $randsk) {
                Write-Host "  [$fileName] ⟳ Fetching direct link..." -ForegroundColor Yellow
                
                $decodedRandsk = $randsk
                if ($decodedRandsk -like "*%*") {
                    $decodedRandsk = [uri]::UnescapeDataString($decodedRandsk)
                }
                $extra = '{"sekey":"' + $decodedRandsk + '"}'
                $extraEscaped = [uri]::EscapeDataString($extra)
                $data = "encrypt=0&extra=$extraEscaped&fid_list=[$($queueItem.FileItem.fs_id)]&primaryid=$shareId&uk=$uk&product=share&type=nolimit"
                $apiUri = "https://www.terabox.com/api/sharedownload?app_id=$appId&channel=chunlei&clienttype=12&sign=$sign&timestamp=$timestamp&web=1"
                
                for ($dlAttempt = 1; $dlAttempt -le 3; $dlAttempt++) {
                    try {
                        $apiResp = Invoke-RestMethod -Uri $apiUri -Headers $headers -WebSession $Session -Method Post -ContentType "application/x-www-form-urlencoded" -Body $data -TimeoutSec 15
                        if ($apiResp.errno -eq 0 -and $apiResp.list -and $apiResp.list.Count -gt 0) {
                            $dlink = $apiResp.list[0].dlink
                            break
                        }
                    }
                    catch {
                        Start-Sleep -Seconds 1
                    }
                }
            }

            if (-not $dlink) {
                Write-Host "  [$fileName] ✗ Failed: No direct link available" -ForegroundColor Red
                return [PSCustomObject]@{
                    Status       = "FAILED"
                    FileName     = $fileName
                    FileSize     = $fileSize
                    Bytes        = 0
                    ErrorMessage = "No dlink available"
                    OutputPath   = $destPath
                    ShareUrl     = $url
                }
            }

            # ── Pre-existence skip check ────────────────────────────────────
            if (Test-Path $destPath) {
                $existing = Get-Item $destPath
                if ($existing.Length -eq $fileSize) {
                    Write-Host "  [$fileName] ⊘ Already exists (same size)" -ForegroundColor Gray
                    return [PSCustomObject]@{
                        Status     = "SKIPPED"
                        FileName   = $fileName
                        FileSize   = $fileSize
                        Bytes      = 0
                        OutputPath = $destPath
                        ShareUrl   = $url
                    }
                }
            }

            # ── Download Loop ────────────────────────────────────────────────
            $finalStatus = "FAILED"
            $errorMsg = "Unknown error"
            $dlBytes = [long]0
            $dlSpeedBytesPerSec = [double]0
            $dlDurationSec = [double]0

            for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
                try {
                    $resumeBytePos = [long]0
                    if ($resume -and (Test-Path $destPath)) {
                        $resumeBytePos = (Get-Item $destPath).Length
                        if ($resumeBytePos -ge $fileSize) {
                            Write-Host "  [$fileName] ⊘ Already exists (same size)" -ForegroundColor Gray
                            return [PSCustomObject]@{
                                Status     = "SKIPPED"
                                FileName   = $fileName
                                FileSize   = $fileSize
                                Bytes      = 0
                                OutputPath = $destPath
                                ShareUrl   = $url
                            }
                        }
                    }

                    $dlHeaders = $headers.Clone()
                    if ($resumeBytePos -gt 0) {
                        $dlHeaders["Range"] = "bytes=$resumeBytePos-"
                    }

                    if ($resumeBytePos -gt 0) {
                        Write-Host "  [$fileName] ↓ Resuming ($($fileSize - $resumeBytePos) bytes remaining)..." -ForegroundColor Cyan
                    } else {
                        Write-Host "  [$fileName] ↓ Downloading..." -ForegroundColor Cyan
                    }

                    $handler = [System.Net.Http.HttpClientHandler]::new()
                    $handler.CookieContainer = $Session.Cookies
                    $handler.UseProxy = $true
                    $client = [System.Net.Http.HttpClient]::new($handler)
                    $client.Timeout = [TimeSpan]::FromSeconds($timeoutSec)

                    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $dlink)
                    foreach ($key in $dlHeaders.Keys) {
                        $null = $request.Headers.TryAddWithoutValidation($key, $dlHeaders[$key])
                    }

                    $dlStartTime = [DateTime]::Now
                    $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                    $null = $response.EnsureSuccessStatusCode()

                    $isAppend = $response.StatusCode -eq [System.Net.HttpStatusCode]::PartialContent
                    $responseStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()

                    $mode = if ($isAppend) { [System.IO.FileMode]::OpenOrCreate } else { [System.IO.FileMode]::Create }
                    $fileStream = [System.IO.FileStream]::new($destPath, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

                    if ($isAppend) {
                        $fileStream.Seek($resumeBytePos, [System.IO.SeekOrigin]::Begin) | Out-Null
                        $startPos = $resumeBytePos
                    } else {
                        $startPos = [long]0
                    }

                    $chunkSize = 64 * 1024
                    $buffer = [byte[]]::new($chunkSize)
                    $totalBytesRead = $startPos

                    $progressId = [Math]::Abs($fileName.GetHashCode()) % 60000 + 100
                    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                    $lastPeriodTime = $stopwatch.ElapsedMilliseconds
                    $bytesReadThisPeriod = 0

                    try {
                        while ($true) {
                            $read = $responseStream.Read($buffer, 0, $buffer.Length)
                            if ($read -eq 0) { break }
                            $fileStream.Write($buffer, 0, $read)
                            $totalBytesRead += $read
                            $bytesReadThisPeriod += $read

                            $currentTime = $stopwatch.ElapsedMilliseconds
                            $elapsedPeriod = $currentTime - $lastPeriodTime
                            if ($elapsedPeriod -ge 1000) {
                                $speedBytesPerSec = ($bytesReadThisPeriod / $elapsedPeriod) * 1000
                                $speedStr = if ($speedBytesPerSec -gt 1MB) {
                                    [Math]::Round($speedBytesPerSec / 1MB, 1).ToString() + " MB/s"
                                } else {
                                    [Math]::Round($speedBytesPerSec / 1KB, 1).ToString() + " KB/s"
                                }

                                $percent = 0
                                if ($fileSize -gt 0) {
                                    $percent = [int](($totalBytesRead / $fileSize) * 100)
                                }

                                Write-Progress `
                                    -Activity "Downloading $fileName" `
                                    -Status "$percent% complete ($speedStr)" `
                                    -PercentComplete $percent `
                                    -Id $progressId

                                $bytesReadThisPeriod = 0
                                $lastPeriodTime = $currentTime
                            }
                        }
                    }
                    finally {
                        Write-Progress -Activity "Downloading $fileName" -Completed -Id $progressId
                        $fileStream.Close()
                        $responseStream.Close()
                        $client.Dispose()
                    }

                    $duration = [DateTime]::Now - $dlStartTime
                    $dlDurationSec = $duration.TotalSeconds

                    if (Test-Path $destPath) {
                        $dlBytes = (Get-Item $destPath).Length
                        if ($dlBytes -gt 0) {
                            $dlSpeedBytesPerSec = if ($dlDurationSec -gt 0) { $dlBytes / $dlDurationSec } else { 0 }
                            $finalStatus = "SUCCESS"
                            
                            Write-Host "  [$fileName] ✓ Saved" -ForegroundColor Green
                            break
                        }
                    }
                }
                catch {
                    $errorMsg = $_.Exception.Message
                    if ($attempt -lt $maxRetries) {
                        Write-Host "  [$fileName] ⚠ Attempt $attempt failed: $errorMsg. Retrying..." -ForegroundColor Yellow
                        Start-Sleep -Seconds 2
                    } else {
                        Write-Host "  [$fileName] ✗ Failed: $errorMsg" -ForegroundColor Red
                    }
                }
            }

            return [PSCustomObject]@{
                Status       = $finalStatus
                FileName     = $fileName
                FileSize     = $fileSize
                Bytes        = $dlBytes
                SpeedBytes   = $dlSpeedBytesPerSec
                DurationSec  = $dlDurationSec
                OutputPath   = $destPath
                ErrorMessage = $errorMsg
                ShareUrl     = $url
            }
        } -ThrottleLimit $threads

        # Process results in main thread to update stats and write logs
        foreach ($res in $results) {
            if ($null -eq $res) { continue }
            if ($res.Status -eq "SUCCESS") {
                $script:Stats.Downloaded++
                $script:Stats.TotalBytes += $res.Bytes
                
                $speedStr = if ($res.SpeedBytes -gt 0) { Format-Speed $res.SpeedBytes } else { "unknown" }
                $durationStr = Format-Duration ([TimeSpan]::FromSeconds($res.DurationSec))

                Write-LogEntry -Status "SUCCESS" -ShareUrl $res.ShareUrl -FileName $res.FileName `
                    -FileSize $res.FileSize -DownloadedBytes $res.Bytes `
                    -Speed $speedStr -Duration $durationStr -OutputPath $res.OutputPath
            }
            elseif ($res.Status -eq "SKIPPED") {
                $script:Stats.Skipped++
                Write-LogEntry -Status "SKIPPED" -ShareUrl $res.ShareUrl -FileName $res.FileName -FileSize $res.FileSize -OutputPath $res.OutputPath
            }
            else {
                $script:Stats.Failed++
                Write-LogEntry -Status "FAILED" -ShareUrl $res.ShareUrl -FileName $res.FileName `
                    -FileSize $res.FileSize -ErrorMessage $res.ErrorMessage
            }
        }
    }

    # Archive successfully completed URLs
    if ($results) {
        $resultsByUrl = $results | Group-Object -Property ShareUrl
        foreach ($group in $resultsByUrl) {
            $failedCount = ($group.Group | Where-Object { $_.Status -eq "FAILED" }).Count
            if ($failedCount -eq 0) {
                $key = Get-ShortUrlKey -RawUrl $group.Name
                Add-KeyToArchive -Key $key
                Write-ColorLine "✓ Added to archive database: $key" Green
            }
        }
    }
    elseif ($script:DownloadQueue.Count -gt 0 -and $script:Stats.Failed -eq $failuresBefore) {
        $resultsByUrl = $script:DownloadQueue | Group-Object -Property Url
        foreach ($group in $resultsByUrl) {
            $key = Get-ShortUrlKey -RawUrl $group.Name
            Add-KeyToArchive -Key $key
            Write-ColorLine "✓ Added to archive database: $key" Green
        }
    }
}


# ── Final Summary ────────────────────────────────────────────────────────────
$elapsed = [DateTime]::Now - $script:Stats.StartTime

Write-Host ""
Write-ColorLine "══════════════════════════════════════════════" DarkCyan
if ($ListOnly) {
    Write-ColorLine "✓ Listing complete. ($($script:Stats.TotalFiles) files found)" Green
}
else {
    Write-ColorLine "── Summary ──────────────────────────────────" DarkCyan
    Write-ColorLine "   Downloaded: $($script:Stats.Downloaded) files ($(Format-FileSize $script:Stats.TotalBytes))" Green
    if ($script:Stats.Skipped -gt 0) {
        Write-ColorLine "   Skipped:    $($script:Stats.Skipped) files (already existed)" DarkGray
    }
    if ($script:Stats.Failed -gt 0) {
        Write-ColorLine "   Failed:     $($script:Stats.Failed) files" Red
    }
    Write-ColorLine "   Duration:   $(Format-Duration $elapsed)" White
    if ($elapsed.TotalSeconds -gt 0 -and $script:Stats.TotalBytes -gt 0) {
        Write-ColorLine "   Avg Speed:  $(Format-Speed ($script:Stats.TotalBytes / $elapsed.TotalSeconds))" White
    }
    Write-ColorLine "   Saved to:   $resolvedOutputDir" DarkGray
    if ($script:Config.LogFile) {
        Write-ColorLine "   Log file:   $($script:Config.LogFile)" DarkGray
    }
    Write-ColorLine "══════════════════════════════════════════════" DarkCyan

    # Log session summary
    Write-LogEntry -Status "INFO" -ShareUrl $Url `
        -FileName "(session complete: $($script:Stats.Downloaded) ok, $($script:Stats.Skipped) skipped, $($script:Stats.Failed) failed)" `
        -DownloadedBytes $script:Stats.TotalBytes `
        -Duration (Format-Duration $elapsed)

    if ($script:Stats.Failed -gt 0) {
        Write-Host ""
        Write-ColorLine "⚠ Some files failed. Re-run the same command to retry/resume." Yellow
    }
    else {
        Write-ColorLine "✓ All downloads complete!" Green
    }
}
Write-Host ""
