# Downloads the Moonshine INT8 + Silero VAD models into assets/models/,
# mirroring what CI does. Only needed for LOCAL builds (CI does this itself).
# Usage:  pwsh ./scripts/get_models.ps1 [-Model base|tiny]
param(
    [ValidateSet('base', 'tiny')]
    [string]$Model = 'base'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$moonshineDir = Join-Path $root 'assets\models\moonshine'
$vadDir = Join-Path $root 'assets\models\vad'
New-Item -ItemType Directory -Force $moonshineDir, $vadDir | Out-Null

$archive = "sherpa-onnx-moonshine-$Model-en-int8"
$tmp = Join-Path $env:TEMP "$archive.tar.bz2"

Write-Host "Downloading Moonshine $Model INT8..." -ForegroundColor Cyan
Invoke-WebRequest -Uri "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$archive.tar.bz2" -OutFile $tmp
tar xjf $tmp -C $env:TEMP

Copy-Item (Join-Path $env:TEMP "$archive\preprocess.onnx")           (Join-Path $moonshineDir 'preprocess.onnx')
Copy-Item (Join-Path $env:TEMP "$archive\encode.int8.onnx")          (Join-Path $moonshineDir 'encode.onnx')
Copy-Item (Join-Path $env:TEMP "$archive\uncached_decode.int8.onnx") (Join-Path $moonshineDir 'uncached_decode.onnx')
Copy-Item (Join-Path $env:TEMP "$archive\cached_decode.int8.onnx")   (Join-Path $moonshineDir 'cached_decode.onnx')
Copy-Item (Join-Path $env:TEMP "$archive\tokens.txt")                (Join-Path $moonshineDir 'tokens.txt')

Write-Host "Downloading Silero VAD..." -ForegroundColor Cyan
Invoke-WebRequest -Uri 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx' -OutFile (Join-Path $vadDir 'silero_vad.onnx')

Write-Host "Done. Models in assets/models/." -ForegroundColor Green
