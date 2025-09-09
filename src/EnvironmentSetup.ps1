# Stop on errors
$ErrorActionPreference = "Stop"

Write-Host "=== Installing .NET WebAssembly Tools ==="

# Ensure dotnet is on PATH
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Error "dotnet CLI not found. Please install .NET SDK first."
    exit 1
}

# Update workloads
dotnet workload update

# Install wasm-tools workload
dotnet workload install wasm-tools

Write-Host "=== wasm-tools installation complete ==="