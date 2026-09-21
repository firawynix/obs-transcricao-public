<#
    lib-progresso.ps1 - publica o andamento num arquivinho que a janela le.

    Formato (uma linha): <percentual>|<fase>|<detalhe>
    Escrito em arquivo temporario e renomeado, para a janela nunca ler pela metade.
#>

$script:ArqProgresso = $null

function Start-Progresso {
    param([string]$Pasta, [string]$Video)
    $md5 = New-Object System.Security.Cryptography.MD5CryptoServiceProvider
    $h = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($Video.ToLower()))).Replace("-", "").Substring(0, 8)
    $script:ArqProgresso = Join-Path $Pasta "progresso-$h.txt"
    Set-Progresso 0 "comecando" ""
    return $script:ArqProgresso
}

# liga-se a um andamento que JA existe (o falantes.ps1 continua a barra que o
# transcrever.ps1 comecou, sem zerar)
function Use-Progresso {
    param([string]$Pasta, [string]$Video)
    $md5 = New-Object System.Security.Cryptography.MD5CryptoServiceProvider
    $h = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($Video.ToLower()))).Replace("-", "").Substring(0, 8)
    $script:ArqProgresso = Join-Path $Pasta "progresso-$h.txt"
}

function Set-Progresso {
    param([int]$Percentual, [string]$Fase, [string]$Detalhe = "")
    if (-not $script:ArqProgresso) { return }
    if ($Percentual -lt 0) { $Percentual = 0 }
    if ($Percentual -gt 100) { $Percentual = 100 }
    try {
        $tmp = "$script:ArqProgresso.tmp"
        [System.IO.File]::WriteAllText($tmp, "$Percentual|$Fase|$Detalhe", (New-Object System.Text.UTF8Encoding($false)))
        Move-Item $tmp $script:ArqProgresso -Force
    } catch { }
}

function Stop-Progresso {
    if (-not $script:ArqProgresso) { return }
    Set-Progresso 100 "pronto" ""
    Start-Sleep -Milliseconds 400          # da tempo da janela ler o 100%
    Remove-Item $script:ArqProgresso -Force -ErrorAction SilentlyContinue
}
