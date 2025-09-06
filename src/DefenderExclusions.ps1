<# 
.SYNOPSIS
Adds developer-friendly Microsoft Defender exclusions for Visual Studio, .NET, NuGet, Node, and common dev roots.

.NOTES
- Run as Administrator.
- Uses Add-MpPreference and only appends missing items.
- You can remove later via Remove-MpPreference (same params).

.PARAMETER WhatIf
Provided automatically when SupportsShouldProcess is enabled. Use -WhatIf to preview changes.
#>

[CmdletBinding(SupportsShouldProcess)]
param()  # <-- no custom WhatIf here

function Assert-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw "This script must be run as Administrator." }
}

function Add-ExclusionItems {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string[]]$Paths = @(),
        [string[]]$Processes = @(),
        [string[]]$Extensions = @()
    )

    try {
        $pref = Get-MpPreference
    } catch {
        throw "Unable to read Defender preferences. Are Microsoft Defender features installed/enabled? $_"
    }

    $existingPaths      = @($pref.ExclusionPath)      + @()
    $existingProcesses  = @($pref.ExclusionProcess)   + @()
    $existingExtensions = @($pref.ExclusionExtension) + @()

    $toAddPaths      = $Paths      | Where-Object { $_ -and -not ($existingPaths -icontains $_) }
    $toAddProcesses  = $Processes  | Where-Object { $_ -and -not ($existingProcesses -icontains $_) }
    $toAddExtensions = $Extensions | Where-Object { $_ -and -not ($existingExtensions -icontains $_) }

    if ($toAddPaths.Count -gt 0) {
        foreach ($p in $toAddPaths) {
            if ($PSCmdlet.ShouldProcess($p, "Add to Defender ExclusionPath")) {
                Add-MpPreference -ExclusionPath $p
            }
        }
    }

    if ($toAddProcesses.Count -gt 0) {
        foreach ($proc in $toAddProcesses) {
            if ($PSCmdlet.ShouldProcess($proc, "Add to Defender ExclusionProcess")) {
                Add-MpPreference -ExclusionProcess $proc
            }
        }
    }

    if ($toAddExtensions.Count -gt 0) {
        foreach ($ext in $toAddExtensions) {
            if ($PSCmdlet.ShouldProcess($ext, "Add to Defender ExclusionExtension")) {
                Add-MpPreference -ExclusionExtension $ext
            }
        }
    }

    $after = Get-MpPreference
    $pathsCount      = @($after.ExclusionPath).Count
    $procCount       = @($after.ExclusionProcess).Count
    $extCount        = @($after.ExclusionExtension).Count

    Write-Host "Done. Current exclusion counts => Paths: $pathsCount, Processes: $procCount, Extensions: $extCount" -ForegroundColor Green
}

Assert-Admin

# Resolve common dev roots if present (only add existing)
$devRoots = @(
    "C:\git"
) | Where-Object { Test-Path $_ }

# Visual Studio + build tooling + caches
$vsPaths = @(
    "$env:ProgramFiles\Microsoft Visual Studio",
    "$env:ProgramFiles(x86)\Microsoft Visual Studio",
    "$env:ProgramFiles\MSBuild",
    "$env:ProgramData\Microsoft\VisualStudio\Packages",      # VS installer cache
    "$env:LOCALAPPDATA\Microsoft\VisualStudio",
    "$env:LOCALAPPDATA\Temp\VS",
    "$env:LOCALAPPDATA\Temp\VisualStudio",
    "$env:LOCALAPPDATA\Temp\MsBuild",
    "$env:TEMP\VS",
    "$env:TEMP\MsBuild"
) | Where-Object { $_ -and (Test-Path $_) }

# .NET / NuGet
$dotnetNugetPaths = @(
    "$env:ProgramFiles\dotnet",
    "$env:USERPROFILE\.dotnet",
    "$env:USERPROFILE\.nuget\packages",
    "$env:LOCALAPPDATA\NuGet\Cache",
    "$env:APPDATA\NuGet\Cache",
    "$env:TEMP\nuget"
) | Where-Object { Test-Path $_ }

# Node ecosystem (optional but commonly helpful)
$nodePaths = @(
    "$env:APPDATA\npm",
    "$env:LOCALAPPDATA\npm-cache",
    "$env:USERPROFILE\AppData\Local\Yarn",
    "$env:LOCALAPPDATA\pnpm-store"
) | Where-Object { Test-Path $_ }

# You likely do NOT want blanket extension exclusions. Keep minimal.
$extensions = @(
    ".nupkg",
    ".snupkg"
)

# Common processes used in builds/dev loops (curated)
$processes = @(
    "devenv.exe",
    "MSBuild.exe",
    "VBCSCompiler.exe",
    "ServiceHub.RoslynCodeAnalysisService.exe",
    "dotnet.exe",
    "git.exe",
    "pwsh.exe",
    "powershell.exe",
    "node.exe",
    "npm.exe",
    "npx.exe",
    "pnpm.exe",
    "bun.exe",
    "deno.exe",
    "tsc.exe",
    "gulp.exe",
    "esbuild.exe",
    "webpack.exe",
    "python.exe"
)

# Combine all path candidates and keep only those that exist (Defender allows non-existing, but keeping clean)
$paths = @()
$paths += $devRoots
$paths += $vsPaths
$paths += $dotnetNugetPaths
$paths += $nodePaths

# Also add per-dev-root transient heavy dirs if present
foreach ($root in $devRoots) {
    foreach ($sub in @(".vs","bin","obj","packages","node_modules\.cache")) {
        $p = Join-Path $root $sub
        if (Test-Path $p) { $paths += $p }
    }
}

$paths = $paths | Sort-Object -Unique

# No explicit -WhatIf here; it's automatic with SupportsShouldProcess
Add-ExclusionItems -Paths $paths -Processes $processes -Extensions $extensions

Write-Warning @"
Review: Exclusions improve build/test throughput but reduce scanning on these targets.
If you maintain untrusted repos, consider limiting dev-root exclusions.
Remove with: Remove-MpPreference -ExclusionPath ... / -ExclusionProcess ... / -ExclusionExtension ...
"@
