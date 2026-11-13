param([string]$Output = "", [string]$Python = "")
$ErrorActionPreference = "Stop"
$Root = Split-Path $PSScriptRoot -Parent
if (!$Output) { $Output = Join-Path $Root '.build\windows' }
dotnet publish (Join-Path $Root 'windows\Tako.Windows.csproj') -c Release -r win-x64 --self-contained true -o $Output
if ($LASTEXITCODE -ne 0) { throw 'Windows build failed' }
New-Item -ItemType Directory -Force (Join-Path $Output 'brain') | Out-Null
Get-ChildItem (Join-Path $Root 'Sources\brain') -File | Copy-Item -Destination (Join-Path $Output 'brain')
New-Item -ItemType Directory -Force (Join-Path $Output 'brain\vendor') | Out-Null
Copy-Item (Join-Path $Root 'Sources\brain\vendor\*') (Join-Path $Output 'brain\vendor') -Recurse -Force
# A relocatable Python runtime is included, so users need no Python installation.
$PythonOutput = Join-Path $Output 'python'
New-Item -ItemType Directory -Force $PythonOutput | Out-Null
if ($Python) {
    Copy-Item (Join-Path $Python '*') $PythonOutput -Recurse -Force
} else {
    $Archive = Join-Path $Output 'python-embed.zip'
    Invoke-WebRequest 'https://www.python.org/ftp/python/3.14.10/python-3.14.10-embed-amd64.zip' -OutFile $Archive
    if ((Get-FileHash $Archive -Algorithm SHA256).Hash -ne '90905e64a840557d8c1bc4f5b74db3d7ee85e3ffb217611cac1c7813acea4159') { throw 'Python checksum mismatch' }
    Expand-Archive $Archive $PythonOutput -Force
    Remove-Item $Archive
}
if (!(Test-Path (Join-Path $PythonOutput 'python.exe'))) { throw 'Python runtime is missing' }
$PathFile = Get-ChildItem $PythonOutput -Filter 'python*._pth' | Select-Object -First 1
if (!$PathFile) { throw 'Supply an embedded Python runtime with a ._pth file' }
$Paths = @(Get-Content $PathFile.FullName)
if ($Paths -notcontains '../brain') { Add-Content $PathFile.FullName '../brain' }

Write-Output $Output
