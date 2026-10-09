# Rebuilds gpu-watch.exe from GpuWatch.cs with the C# compiler that ships with Windows.
# /target:winexe = no console window. Stop the running logger first or the exe is locked:
#   Stop-ScheduledTask -TaskName 'GPU Watch crash logger'
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $csc /nologo /target:winexe /optimize+ /platform:x64 "/out:$(Join-Path $root 'gpu-watch.exe')" (Join-Path $root 'GpuWatch.cs')
if ($LASTEXITCODE -ne 0) { throw "build failed ($LASTEXITCODE)" }
