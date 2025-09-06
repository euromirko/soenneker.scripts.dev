<# .SYNOPSIS
     One‑stop, order‑optimised cleanup for a Windows .NET / Visual Studio dev box.
     Flip the booleans below to enable / disable heavy sections.
#>

# ── TOGGLES ─────────────────────────────────────────────────────────
$WipeVsCaches       = $true
$WipeVsCodeCaches   = $true
$WipeCursorCaches   = $true
$WipeDevCerts       = $true
$RunGitClean        = $true
$WipeDeepVsCaches   = $true
$WipeXamarinCaches  = $true      # NEW: Xamarin / MAUI‑specific caches
# ────────────────────────────────────────────────────────────────────

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

function Remove-Dirs([string[]]$names){
    Get-ChildItem -Path . -Dir -Recurse -Force -EA SilentlyContinue |
        ?{ $names -contains $_.Name } | Remove-Item -Recurse -Force -EA Stop
}

######## STOP PROCESSES #############################################
Invoke-Safe "Stopping VS Code…"              { foreach($n in 'Code','Code - Insiders','code'){ Stop-App $n } }
Invoke-Safe "Stopping Cursor IDE…"           { Stop-App 'Cursor' }
Invoke-Safe "Stopping Visual Studio…"        { Stop-App 'devenv' }
Invoke-Safe "Stopping ReSharper helpers…"    { foreach($n in 'JetBrains.ReSharper.TaskRunner','jb_eap_agent','JetBrains.Etw.Collector'){ Stop-App $n } }
Invoke-Safe "Stopping build servers…"        { dotnet build-server shutdown }
Invoke-Safe "Stopping stray dotnet.exe…"     { Get-Process dotnet -EA SilentlyContinue | Stop-Process -Force }
Invoke-Safe "Stopping build / test orphans…" { Stop-BuildOrphans }

######## REPO‑LOCAL ##################################################
Invoke-Safe "Cleaning repo artifacts…" {
    Remove-Dirs @('bin','obj','.vs','TestResults','artifacts','publish','out','coverage','dist','node_modules')
    Get-ChildItem -Recurse -Include '*.user','*.suo','*.cache' | Remove-Item -Force -EA Stop
}

if ($RunGitClean -and (Test-Path .git)) {
    Invoke-Safe "Running git clean -xfd…" { git clean -xfd }
}

if (Test-Path .git) {
    Invoke-Safe "Pruning stale remote branches…" { git remote prune origin }
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
    Get-ChildItem "$env:LOCALAPPDATA\Temp" -Dir -Filter 'aspnetcore-*' |
        Remove-Item -Recurse -Force -EA Stop
}
Invoke-Safe "Cleaning MSBuild / BuildCache…" {
    foreach($dir in 'MSBuild','BuildCache'){
        $p=Join-Path "$env:LOCALAPPDATA\Microsoft" $dir
        if(Test-Path $p){ Remove-Item $p -Recurse -Force -EA Stop }
    }
}

######## VISUAL STUDIO CACHES ########################################
if ($WipeVsCaches) {
    Invoke-Safe "Cleaning VS ComponentModel / Roslyn caches…" {
        $root="$env:LOCALAPPDATA\Microsoft\VisualStudio"
        if(Test-Path $root){
            Get-ChildItem $root -Dir -EA SilentlyContinue | %{
                foreach($s in 'ComponentModelCache','Roslyn'){
                    $p=Join-Path $_.FullName $s
                    if(Test-Path $p){ Remove-Item $p -Recurse -Force -EA Stop }
                }
            }
        }
    }

    function Get-DevenvPaths {
        $vswhere="${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
        if(-not(Test-Path $vswhere)){ $vswhere=(Get-Command vswhere.exe -EA SilentlyContinue)?.Source }
        if(-not $vswhere){ return @() }
        & $vswhere -all -products * -property productPath -format value | ?{ Test-Path $_ }
    }

    foreach($exe in Get-DevenvPaths){
        Invoke-Safe "Cleaning VS cache via $([IO.Path]::GetFileName($exe))…" { & $exe /clearcache; & $exe /updateconfiguration }
    }

    Invoke-Safe "Cleaning ReSharper caches…" {
        Get-ChildItem -Path . -Dir -Force | ?{ $_.Name -like '_ReSharper*' } | Remove-Item -Recurse -Force -EA Stop
        $jet="$env:LOCALAPPDATA\JetBrains"
        if(Test-Path $jet){
            Get-ChildItem "$jet\Transient" -Dir -Force -EA SilentlyContinue | ?{ $_.Name -like 'ReSharper*' } |
                Remove-Item -Recurse -Force -EA Stop
            Get-ChildItem "$jet" -Dir -Force -EA SilentlyContinue | ?{ $_.Name -like 'ReSharperPlatformVs*' } |
                %{
                    $c=Join-Path $_.FullName 'Cache'
                    if(Test-Path $c){ Remove-Item $c -Recurse -Force -EA Stop }
                }
        }
    }

    if($WipeDeepVsCaches){
        function Clean-VsDeepCaches{
            $vs="$env:LOCALAPPDATA\Microsoft\VisualStudio"
            if(Test-Path $vs){
                Get-ChildItem $vs -Dir | %{
                    Remove-Item "$($_.FullName)\ProjectTemplatesCache","$($_.FullName)\ItemTemplatesCache","$($_.FullName)\AnalyzerCache","$($_.FullName)\Diagnostics" -Recurse -Force -EA SilentlyContinue
                }
            }
            Remove-Item "$env:USERPROFILE\.vs-lsp-cache" -Recurse -Force -EA SilentlyContinue
            Remove-Item "$env:LOCALAPPDATA\Temp\SymbolCache" -Recurse -Force -EA SilentlyContinue
        }
        Invoke-Safe "Cleaning deep VS caches…" { Clean-VsDeepCaches }
    }
}

######## VS CODE CACHE ################################################
if ($WipeVsCodeCaches) {
    Invoke-Safe "Cleaning VS Code caches…" {
        foreach($base in "$env:APPDATA\Code","$env:APPDATA\Code - Insiders"){
            if(Test-Path $base){
                foreach($s in 'Cache*','GPUCache','CachedData','User\workspaceStorage'){
                    $p=Join-Path $base $s
                    if(Test-Path $p){ Remove-Item $p -Recurse -Force -EA Stop }
                }
            }
        }
        Get-ChildItem "$env:USERPROFILE\.vscode\extensions" -Dir -EA SilentlyContinue |
            Get-ChildItem -Dir -Recurse -Filter '.cache' -Force -EA SilentlyContinue | Remove-Item -Recurse -Force -EA Stop
        Remove-Item "$env:USERPROFILE\.vscode-server*" -Recurse -Force -EA SilentlyContinue
    }
}

######## CURSOR CACHE ################################################
if ($WipeCursorCaches) {
    Invoke-Safe "Cleaning Cursor IDE caches…" {
        $cur="$env:APPDATA\Cursor"
        if(Test-Path $cur){
            foreach($s in 'Cache*','GPUCache','CachedData','User\workspaceStorage'){
                $p=Join-Path $cur $s; if(Test-Path $p){ Remove-Item $p -Recurse -Force -EA Stop }
            }
        }
        $ext="$env:USERPROFILE\.cursor\extensions"
        if(Test-Path $ext){
            Get-ChildItem $ext -Dir -Recurse -Filter '.cache' -EA SilentlyContinue | Remove-Item -Recurse -Force -EA Stop
        }
        Get-ChildItem "$env:USERPROFILE" -Dir -Filter '.cursor-server*' -EA SilentlyContinue |
            Remove-Item -Recurse -Force -EA SilentlyContinue
    }
}

######## XAMARIN / MAUI CACHES #######################################
if ($WipeXamarinCaches) {

    # Xamarin.BuildDownload task cache (native‑AAR downloads, etc.)
    Invoke-Safe "Cleaning XamarinBuildDownload cache…" {
        $xbd = "$env:LOCALAPPDATA\XamarinBuildDownloadCache"
        if (Test-Path $xbd) { Remove-Item $xbd -Recurse -Force -EA Stop }
    }

    # General Xamarin framework caches (designer images, device logs, MTBS, etc.)
    Invoke-Safe "Cleaning Xamarin framework caches…" {
        $xam = "$env:LOCALAPPDATA\Xamarin"
        if (Test-Path $xam) {
            foreach ($s in 'Cache','Cache*','Logs','DeviceLogs','MTBS') {
                $p = Join-Path $xam $s
                if (Test-Path $p) { Remove-Item $p -Recurse -Force -EA Stop }
            }
        }
    }

    # .NET Hot‑Reload artefacts (used heavily by MAUI)
    Invoke-Safe "Cleaning .NET hot‑reload caches…" {
        $hr = "$env:LOCALAPPDATA\Microsoft\dotnet-hot-reload"
        if (Test-Path $hr) { Remove-Item $hr -Recurse -Force -EA Stop }
    }

    # Android‑side designer / device caches placed by the Android SDK
    Invoke-Safe "Cleaning AVD / Android designer caches…" {
        $android = "$env:LOCALAPPDATA\Android"
        if (Test-Path $android) {
            foreach ($d in 'Cache','adb','device-cache') {
                $p = Join-Path $android $d
                if (Test-Path $p) { Remove-Item $p -Recurse -Force -EA Stop }
            }
        }
    }
}

Log "==== CLEAN COMPLETE ===="
