<#
    lib-ffmpeg.ps1 - acha o ffmpeg/ffprobe sem depender do PATH.

    Ordem: o que veio junto na instalacao (bin\), depois o PATH, depois o winget.
    Assim a instalacao funciona em maquina que nunca teve ffmpeg.
#>

function Get-Ferramenta {
    param([Parameter(Mandatory = $true)][string]$Nome)   # "ffmpeg" ou "ffprobe"

    $raiz = Split-Path -Parent $PSCommandPath

    $proprio = Join-Path $raiz "bin\$Nome.exe"
    if (Test-Path $proprio) { return $proprio }

    $noPath = Get-Command $Nome -ErrorAction SilentlyContinue
    if ($noPath) { return $noPath.Source }

    $winget = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter "$Nome.exe" `
                            -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($winget) { return $winget.FullName }

    throw "$Nome nao encontrado (nem em bin\, nem no PATH, nem no winget)"
}

function Get-Ffmpeg  { Get-Ferramenta -Nome "ffmpeg" }
function Get-Ffprobe { Get-Ferramenta -Nome "ffprobe" }
