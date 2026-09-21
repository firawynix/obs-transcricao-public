<#
    empacotar.ps1 - gera o instalador COMPLETO (com whisper e modelos dentro).

    Cola os arquivos grandes no fim do .exe leve, com um indice e um rodape:
        [exe][arquivo1][arquivo2]...[indice][offset:8][tamanho:8][ASSINATURA:8]

    Rode compilar.ps1 antes (o .exe leve e a base deste aqui).

        .\empacotar.ps1              -> ~1,6 GB, ffmpeg fica por conta da maquina
        .\empacotar.ps1 -ComFfmpeg   -> ~1,9 GB, nao baixa absolutamente nada
#>
param([switch]$ComFfmpeg)

$ErrorActionPreference = "Stop"

$aqui = Split-Path -Parent $MyInvocation.MyCommand.Path
$raiz = Split-Path -Parent $aqui
$leve = Join-Path $aqui "Instalar-Transcricao-OBS.exe"
$saida = if ($ComFfmpeg) { Join-Path $aqui "Instalar-Transcricao-OBS-Offline.exe" }
         else            { Join-Path $aqui "Instalar-Transcricao-OBS-Completo.exe" }

if (-not (Test-Path $leve)) { throw "compile primeiro: compilar.ps1" }

# --- o que vai junto ---
$incluir = @()
foreach ($f in Get-ChildItem (Join-Path $raiz "bin") -File) {
    # so o que a transcricao usa: o zip do whisper vem com uns 8 MB de demo e teste
    $usado = ($f.Name -eq "whisper-cli.exe") -or ($f.Extension -eq ".dll")
    if ($ComFfmpeg -and $f.Name -match '^(ffmpeg|ffprobe)\.exe$') { $usado = $true }
    if (-not $usado) { continue }
    $incluir += [pscustomobject]@{ Rel = "bin/$($f.Name)"; Caminho = $f.FullName }
}
foreach ($f in Get-ChildItem (Join-Path $raiz "modelos") -File -Filter "*.bin") {
    $incluir += [pscustomobject]@{ Rel = "modelos/$($f.Name)"; Caminho = $f.FullName }
}

if ($ComFfmpeg) {
    foreach ($n in @("ffmpeg", "ffprobe")) {
        if (-not ($incluir | Where-Object { $_.Rel -eq "bin/$n.exe" })) {
            $cmd = Get-Command $n -ErrorAction SilentlyContinue
            if (-not $cmd) { throw "-ComFfmpeg pediu $n.exe, mas nao achei nem em bin\ nem no PATH" }
            $incluir += [pscustomobject]@{ Rel = "bin/$n.exe"; Caminho = $cmd.Source }
        }
    }
}

$total = ($incluir | ForEach-Object { (Get-Item $_.Caminho).Length } | Measure-Object -Sum).Sum
"empacotando {0} arquivo(s), {1:N0} MB" -f $incluir.Count, ($total / 1MB)

# --- monta o executavel ---
Copy-Item $leve $saida -Force

$indice = New-Object System.Text.StringBuilder
$fs = [System.IO.File]::Open($saida, 'Open', 'Write')
try {
    $fs.Seek(0, 'End') | Out-Null
    $buf = New-Object byte[] (4MB)

    foreach ($item in $incluir) {
        $offset = $fs.Position
        $ent = [System.IO.File]::OpenRead($item.Caminho)
        try {
            while (($lido = $ent.Read($buf, 0, $buf.Length)) -gt 0) { $fs.Write($buf, 0, $lido) }
        } finally { $ent.Close() }
        $tam = $fs.Position - $offset
        [void]$indice.Append("$($item.Rel)|$offset|$tam`n")
        "  + {0,-38} {1,10:N0} bytes" -f $item.Rel, $tam
    }

    $bytesIndice = [System.Text.Encoding]::UTF8.GetBytes($indice.ToString())
    $offIndice = $fs.Position
    $fs.Write($bytesIndice, 0, $bytesIndice.Length)

    $fs.Write([BitConverter]::GetBytes([int64]$offIndice), 0, 8)
    $fs.Write([BitConverter]::GetBytes([int64]$bytesIndice.Length), 0, 8)
    $fs.Write([System.Text.Encoding]::ASCII.GetBytes("OBSTRAN1"), 0, 8)
}
finally { $fs.Close() }

""
"gerado: $saida"
"tamanho: {0:N0} MB" -f ((Get-Item $saida).Length / 1MB)


