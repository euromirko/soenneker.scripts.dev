<# .SYNOPSIS
     One-stop, order-optimised cleanup for a Windows .NET / Visual Studio dev box.
     Recursively nukes bin/obj/.vs under C:\git and wipes VS caches for all versions.
#>

# ── SETTINGS ────────────────────────────────────────────────────────
$GitRoot              = 'C:\git'  # ← change if needed

# Toggle sections
$WipeVsCaches         = $true
$WipeVsCodeCaches     = $true
$WipeCursorCaches     = $true
$WipeDevCerts         = $false     # set true if you want dev-cert reset too
$RunGitClean          = $false     # set true if you want 'git clean -xfd' per repo
$WipeDeepVsCaches     = $true
$WipeXamarinCaches    = $true
# ───────────────────────────────────────────────────────────────────

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Log { param($m) Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $m" }

function Invoke-Safe {
    param([string]$Label,[scriptblock]$Action)
    Log $Label
    try {
        $global:LASTEXITCODE = 0
        & $Action
        if ($LASTEXITCODE -ne 0) { throw "Exit code $LASTEXITCODE" }
    } catch {
        Write-Host "❌  $Label failed:" -ForegroundColor Red
        $_ | Format-List * -Force
        throw
    }
}

######## HELPERS #####################################################
function Stop-App ($name){
    Get-Process -Name $name -EA SilentlyContinue | % { $_.CloseMainWindow() | Out-Null }
    Start-Sleep 2
    Get-Process -Name $name -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
}

function Stop-BuildOrphans{
    Log "Stopping stray build / test processes…"
    foreach($p in 'MSBuild','VBCSCompiler','vstest.console','MSTest','xunit.console','testhost*','EdgeWebView2'){
        Get-Process -Name $p -EA SilentlyContinue | Stop-Process -Force
    }
}

function Remove-NamedDirsUnder {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$Names
    )
    if (!(Test-Path $Root)) { return }
    # Use -Depth unlimited; filter by exact name match for speed/precision
    Get-ChildItem -Path $Root -Directory -Recurse -Force -EA SilentlyContinue |
        Where-Object { $Names -contains $_.Name } |
        ForEach-Object {
            try {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -EA Stop
            } catch {
                # try to reset attributes then retry once (handles R/O or long paths)
                try {
                    $_.Attributes = 'Directory'
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force -EA Stop
                } catch { Write-Warning "Failed to remove: $($_.FullName)  ($_)" }
            }
        }
}

function Get-DevenvPaths {
    $vswhere="${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if(-not(Test-Path $vswhere)){ $vswhere=(Get-Command vswhere.exe -EA SilentlyContinue)?.Source }
    if(-not $vswhere){ return @() }
    & $vswhere -all -products * -property productPath -format value | ?{ Test-Path $_ }
}

######## STOP PROCESSES #############################################
Invoke-Safe "Stopping VS Code…"              { foreach($n in 'Code','Code - Insiders','code'){ Stop-App $n } }
Invoke-Safe "Stopping Cursor IDE…"           { Stop-App 'Cursor' }
Invoke-Safe "Stopping Visual Studio…"        { Stop-App 'devenv' }
Invoke-Safe "Stopping ReSharper helpers…"    { foreach($n in 'JetBrains.ReSharper.TaskRunner','jb_eap_agent','JetBrains.Etw.Collector'){ Stop-App $n } }
Invoke-Safe "Stopping build servers…"        { dotnet build-server shutdown }
Invoke-Safe "Stopping stray dotnet.exe…"     { Get-Process dotnet -EA SilentlyContinue | Stop-Process -Force }
Invoke-Safe "Stopping build / test orphans…" { Stop-BuildOrphans }

######## C:\git REPO CLEAN ################################################
Invoke-Safe "Cleaning repo artifacts under $GitRoot (bin/obj/.vs)…" {
    Remove-NamedDirsUnder -Root $GitRoot -Names @('bin','obj','.vs')
}

Invoke-Safe "Removing *.user/*.suo/*.cache files under $GitRoot…" {
    if (Test-Path $GitRoot) {
        Get-ChildItem -Path $GitRoot -Recurse -Force -Include '*.user','*.suo','*.cache' -File -EA SilentlyContinue |
            Remove-Item -Force -EA SilentlyContinue
    }
}

if ($RunGitClean -and (Test-Path $GitRoot)) {
    Invoke-Safe "Running 'git clean -xfd' in each git repo under $GitRoot…" {
        Get-ChildItem -Path $GitRoot -Directory -Recurse -Force -EA SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName '.git') } |
            ForEach-Object {
                Push-Location $_.FullName
                try { git clean -xfd | Out-Null } finally { Pop-Location }
            }
    }
}

######## DOTNET / NUGET ##############################################
Invoke-Safe "Cleaning NuGet locals…"              { dotnet nuget locals all --clear }
Invoke-Safe "Pruning orphaned workload packs…"    { dotnet workload clean --all }
Invoke-Safe "Updating workload packs…"            { dotnet workload update }

Invoke-Safe "Removing ~/.dotnet/store…" {
    $store="$env:USERPROFILE\.dotnet\store"; if(Test-Path $store){ Remove-Item $store -Recurse -Force -EA Stop }
}
Invoke-Safe "Cleaning global tool cache…" {
    $toolStore="$env:USERPROFILE\.dotnet\tools\.store"; if(Test-Path $toolStore){ Remove-Item $toolStore -Recurse -Force -EA Stop }
}

######## ASP.NET / MSBUILD CACHE #####################################
Invoke-Safe "Cleaning legacy ASP.NET temp…" {
    $legacy = Join-Path "$env:LOCALAPPDATA\Temp" 'Temporary ASP.NET Files'
    if(Test-Path $legacy){ Remove-Item $legacy -Recurse -Force -EA Stop }
}
Invoke-Safe "Cleaning ASP.NET Core temp…" {
    Get-ChildItem "$env:LOCALAPPDATA\Temp" -Dir -Filter 'aspnetcore-*' -EA SilentlyContinue |
        Remove-Item -Recurse -Force -EA SilentlyContinue
}
Invoke-Safe "Cleaning MSBuild / BuildCache…" {
    foreach($dir in 'MSBuild','BuildCache'){
        $p=Join-Path "$env:LOCALAPPDATA\Microsoft" $dir
        if(Test-Path $p){ Remove-Item $p -Recurse -Force -EA Stop }
    }
}

######## VISUAL STUDIO CACHES (ALL VERSIONS) #########################
if ($WipeVsCaches) {

    # 1) Instance-aware cache clear via devenv (all installs)
    foreach($exe in Get-DevenvPaths){
        Invoke-Safe "VS cache clear via $([IO.Path]::GetFileName($exe))…" { & $exe /clearcache; & $exe /updateconfiguration }
    }

    # 2) Nuke known cache subfolders under all version hives
    Invoke-Safe "Cleaning VS ComponentModel/Roslyn/etc. caches…" {
        $roots = @("$env:LOCALAPPDATA\Microsoft\VisualStudio","$env:APPDATA\Microsoft\VisualStudio")
        foreach($root in $roots){
            if(!(Test-Path $root)){ continue }
            Get-ChildItem $root -Dir -EA SilentlyContinue | %{
                foreach($s in 'ComponentModelCache','Roslyn','MEFCacheBackup','ActivityLog','Designer','Cache','ProjectTemplatesCache','ItemTemplatesCache','AnalyzerCache','Diagnostics','ServerHub','Extensions','ImageLibrary','ImageService','VBCSCompiler'){
                    $p=Join-Path $_.FullName $s
                    if(Test-Path $p){ Remove-Item $p -Recurse -Force -EA SilentlyContinue }
                }
            }
        }
        # Language server / symbol caches
        Remove-Item "$env:USERPROFILE\.vs-lsp-cache" -Recurse -Force -EA SilentlyContinue
        Remove-Item "$env:LOCALAPPDATA\Temp\SymbolCache" -Recurse -Force -EA SilentlyContinue
        Remove-Item "$env:LOCALAPPDATA\Microsoft\VSApplicationInsights" -Recurse -Force -EA SilentlyContinue
        Remove-Item "$env:LOCALAPPDATA\Microsoft\VSCommon\Cache" -Recurse -Force -EA SilentlyContinue
    }

    # 3) ReSharper caches (solution & user-profile)
    Invoke-Safe "Cleaning ReSharper caches…" {
        # solution-local caches under C:\git already removed via .vs/_ReSharper*, but do a belt-and-braces sweep:
        Remove-NamedDirsUnder -Root $GitRoot -Names @('_ReSharper.Caches','_ReSharper*')
        $jet="$env:LOCALAPPDATA\JetBrains"
        if(Test-Path $jet){
            Get-ChildItem "$jet\Transient" -Dir -Force -EA SilentlyContinue | ?{ $_.Name -like 'ReSharper*' } |
                Remove-Item -Recurse -Force -EA SilentlyContinue
            Get-ChildItem "$jet" -Dir -Force -EA SilentlyContinue | ?{ $_.Name -like 'ReSharperPlatformVs*' } |
                %{
                    $c=Join-Path $_.FullName 'Cache'
                    if(Test-Path $c){ Remove-Item $c -Recurse -Force -EA SilentlyContinue }
                }
        }
    }

    if($WipeDeepVsCaches){
        Invoke-Safe "Cleaning deep VS caches…" {
            # anything VS puts in %LOCALAPPDATA%\Microsoft\VisualStudio\<instance>\*
            $vs="$env:LOCALAPPDATA\Microsoft\VisualStudio"
            if(Test-Path $vs){
                Get-ChildItem $vs -Dir -EA SilentlyContinue | %{
                    foreach($s in 'ComponentModelCache','Roslyn','ProjectTemplatesCache','ItemTemplatesCache','AnalyzerCache','Diagnostics','Cache','ServerHub','Extensions'){
                        $p = Join-Path $_.FullName $s
                        if(Test-Path $p){ Remove-Item $p -Recurse -Force -EA SilentlyContinue }
                    }
                }
            }
        }
    }
}

######## VS CODE CACHE ################################################
if ($WipeVsCodeCaches) {
    Invoke-Safe "Cleaning VS Code caches…" {
        foreach($base in "$env:APPDATA\Code","$env:APPDATA\Code - Insiders"){
            if(Test-Path $base){
                foreach($s in 'Cache*','GPUCache','CachedData','User\workspaceStorage'){
                    $p=Join-Path $base $s
                    if(Test-Path $p){ Remove-Item $p -Recurse -Force -EA SilentlyContinue }
                }
            }
        }
        if (Test-Path "$env:USERPROFILE\.vscode\extensions") {
            Get-ChildItem "$env:USERPROFILE\.vscode\extensions" -Dir -EA SilentlyContinue |
                Get-ChildItem -Dir -Recurse -Filter '.cache' -Force -EA SilentlyContinue |
                Remove-Item -Recurse -Force -EA SilentlyContinue
        }
        Remove-Item "$env:USERPROFILE\.vscode-server*" -Recurse -Force -EA SilentlyContinue
    }
}

######## CURSOR CACHE ################################################
if ($WipeCursorCaches) {
    Invoke-Safe "Cleaning Cursor IDE caches…" {
        $cur="$env:APPDATA\Cursor"
        if(Test-Path $cur){
            foreach($s in 'Cache*','GPUCache','CachedData','User\workspaceStorage'){
                $p=Join-Path $cur $s; if(Test-Path $p){ Remove-Item $p -Recurse -Force -EA SilentlyContinue }
            }
        }
        $ext="$env:USERPROFILE\.cursor\extensions"
        if(Test-Path $ext){
            Get-ChildItem $ext -Dir -Recurse -Filter '.cache' -EA SilentlyContinue | Remove-Item -Recurse -Force -EA SilentlyContinue
        }
        Get-ChildItem "$env:USERPROFILE" -Dir -Filter '.cursor-server*' -EA SilentlyContinue |
            Remove-Item -Recurse -Force -EA SilentlyContinue
    }
}

######## XAMARIN / MAUI CACHES #######################################
if ($WipeXamarinCaches) {
    Invoke-Safe "Cleaning XamarinBuildDownload cache…" {
        $xbd = "$env:LOCALAPPDATA\XamarinBuildDownloadCache"
        if (Test-Path $xbd) { Remove-Item $xbd -Recurse -Force -EA SilentlyContinue }
    }
    Invoke-Safe "Cleaning Xamarin framework caches…" {
        $xam = "$env:LOCALAPPDATA\Xamarin"
        if (Test-Path $xam) {
            foreach ($s in 'Cache','Cache*','Logs','DeviceLogs','MTBS') {
                $p = Join-Path $xam $s
                if (Test-Path $p) { Remove-Item $p -Recurse -Force -EA SilentlyContinue }
            }
        }
    }
    Invoke-Safe "Cleaning .NET hot-reload caches…" {
        $hr = "$env:LOCALAPPDATA\Microsoft\dotnet-hot-reload"
        if (Test-Path $hr) { Remove-Item $hr -Recurse -Force -EA SilentlyContinue }
    }
    Invoke-Safe "Cleaning AVD / Android designer caches…" {
        $android = "$env:LOCALAPPDATA\Android"
        if (Test-Path $android) {
            foreach ($d in 'Cache','adb','device-cache') {
                $p = Join-Path $android $d
                if (Test-Path $p) { Remove-Item $p -Recurse -Force -EA SilentlyContinue }
            }
        }
    }
}

######## OPTIONAL: DEV CERTS #########################################
if ($WipeDevCerts) {
    Invoke-Safe "Resetting HTTPS dev certs (dotnet)…" { dotnet dev-certs https --clean; dotnet dev-certs https --trust }
}

Log "==== CLEAN COMPLETE ===="
