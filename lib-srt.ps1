<#
    lib-srt.ps1 - le e escreve .srt, e confere se os tempos fazem sentido.

    Existe por causa da transcricao em pedacos (transcrever.ps1): cada pedaco sai
    com o proprio relogio comecando do zero, e aqui somamos o inicio do pedaco.
#>

function ConvertFrom-TempoSrt([string]$s) {
    # "00:01:23,450" -> 83.45 (cast de string e invariante no PowerShell)
    $m = [regex]::Match($s, '(\d+):(\d+):(\d+)[,.](\d+)')
    if (-not $m.Success) { return $null }
    return [double]$m.Groups[1].Value * 3600 + [double]$m.Groups[2].Value * 60 +
           [double]$m.Groups[3].Value + [double]("0." + $m.Groups[4].Value)
}

function ConvertTo-TempoSrt([double]$seg) {
    if ($seg -lt 0) { $seg = 0 }
    # milissegundo inteiro + Floor: [int] no PowerShell ARREDONDA (0,5h virava 1h)
    [long]$ms = [math]::Round($seg * 1000)
    [long]$t = [math]::Floor($ms / 1000)
    "{0:00}:{1:00}:{2:00},{3:000}" -f [int][math]::Floor($t / 3600), [int][math]::Floor(($t % 3600) / 60), [int]($t % 60), [int]($ms % 1000)
}

# Devolve { Ini, Fim, Texto } na ordem do arquivo. Arquivo ausente = lista vazia.
function Read-SrtCues([string]$Caminho) {
    if (-not (Test-Path -LiteralPath $Caminho)) { return @() }
    $texto = [System.IO.File]::ReadAllText($Caminho, [System.Text.Encoding]::UTF8)
    $cues = New-Object System.Collections.ArrayList
    # grupo SEM captura: com captura o -split devolve os separadores junto
    foreach ($bloco in ($texto -split "(?:`r?`n){2,}")) {
        $linhas = @($bloco -split "`r?`n" | Where-Object { $_.Trim() -ne "" })
        $idx = -1
        for ($i = 0; $i -lt $linhas.Count; $i++) { if ($linhas[$i] -match '-->') { $idx = $i; break } }
        if ($idx -lt 0) { continue }
        $p = $linhas[$idx] -split '-->'
        $ini = ConvertFrom-TempoSrt $p[0]
        $fim = ConvertFrom-TempoSrt $p[1]
        if ($null -eq $ini -or $null -eq $fim) { continue }
        if ($idx + 1 -ge $linhas.Count) { continue }
        $txt = ($linhas[($idx + 1)..($linhas.Count - 1)] -join "`n").Trim()
        if ($txt -eq "") { continue }
        $null = $cues.Add([pscustomobject]@{ Ini = $ini; Fim = $fim; Texto = $txt })
    }
    # sem virgula: elementos sao objetos (a virgula so protege array de arrays)
    return $cues.ToArray()
}

function Write-SrtCues($Cues, [string]$Caminho) {
    $sb = New-Object System.Text.StringBuilder
    $n = 0
    foreach ($c in $Cues) {
        $n++
        [void]$sb.Append("$n`n" + (ConvertTo-TempoSrt $c.Ini) + " --> " + (ConvertTo-TempoSrt $c.Fim) + "`n" + $c.Texto + "`n`n")
    }
    # SEM BOM: player antigo engasga com BOM na primeira linha
    [System.IO.File]::WriteAllText($Caminho, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
}

# Os tempos fazem sentido? Pega o defeito medido em 2026-09-10 com "-p 4" + VAD:
# a partir de certo ponto todas as legendas saem com o MESMO instante (0,7s, 0,7s,
# 0,7s...) e a legenda de uma gravacao de 1h37 terminava em 3900s.
function Test-SrtSaudavel($Cues, [double]$Duracao) {
    $ant = -1.0
    $iguais = 0
    foreach ($c in $Cues) {
        if ($c.Ini -lt $ant - 1) { return $false }           # voltou no tempo
        if ($c.Fim -gt $Duracao + 2) { return $false }        # passou do fim do audio
        if ([math]::Abs($c.Ini - $ant) -lt 0.05) {
            $iguais++
            if ($iguais -ge 4) { return $false }              # relogio parado
        } else { $iguais = 0 }
        $ant = $c.Ini
    }
    return $true
}
