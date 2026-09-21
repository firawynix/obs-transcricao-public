<#
    transcrever.ps1 - gera transcricao (.txt e .srt) de uma gravacao do OBS.

    Uso manual:
        powershell -ExecutionPolicy Bypass -File transcrever.ps1 -Video "C:\caminho\video.mp4"

    Chamado automaticamente pelo script Lua do OBS quando a gravacao para.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Video,

    [string]$Idioma = "pt",

    # numero de threads da CPU usadas pelo whisper (0 = metade dos processadores logicos)
    [int]$Threads = 0,

    # pula a etapa de descobrir quem falou (identificacao pela tela do Teams)
    [switch]$SemFalantes,

    # nao embute a legenda dentro do proprio video
    [switch]$SemLegenda,

    # refaz mesmo que ja exista transcricao (o botao manual do OBS usa isso)
    [switch]$Forcar,

    # teto de processador (0 = sem teto). Vale para ffmpeg e whisper tambem,
    # porque processo filho herda o limite deste aqui.
    [int]$CpuMax = 70
)

$ErrorActionPreference = "Stop"

$Base       = Split-Path -Parent $MyInvocation.MyCommand.Path
$WhisperExe = Join-Path $Base "bin\whisper-cli.exe"
$Modelo     = Join-Path $Base "modelos\ggml-large-v3-turbo.bin"
$ModeloVad  = Join-Path $Base "modelos\ggml-silero-v5.1.2.bin"
$LogDir     = if ($env:FIRAW_OBS_DATA_DIR) { Join-Path $env:FIRAW_OBS_DATA_DIR "logs" } else { Join-Path $Base "logs" }
$LogFile    = Join-Path $LogDir ("transcricao-" + (Get-Date -Format "yyyy-MM") + ".log")

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Log([string]$msg) {
    $linha = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Add-Content -Path $LogFile -Value $linha -Encoding utf8
}

. (Join-Path $Base "lib-ffmpeg.ps1")
. (Join-Path $Base "lib-cpu.ps1")
. (Join-Path $Base "lib-progresso.ps1")
. (Join-Path $Base "lib-legenda.ps1")
. (Join-Path $Base "lib-srt.ps1")

# Onde cortar o audio em pedacos: no meio do silencio mais longo perto de cada
# ponto ideal, para nao partir palavra (o "-p" do whisper cortava cego).
function Get-PontosDeCorte([string]$Wav, [double]$Duracao, [double]$Alvo, [int]$Minimo, [string]$Ffmpeg, [string]$Pasta) {
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $err = Join-Path $Pasta "silencio-cortes.txt"
    $a = '-hide_banner -nostats -i "{0}" -af silencedetect=noise=-35dB:d=0.3 -f null NUL' -f $Wav
    Start-Process -FilePath $Ffmpeg -ArgumentList $a -NoNewWindow -Wait -RedirectStandardError $err
    $sil = New-Object System.Collections.ArrayList
    $ini = $null
    foreach ($l in (Get-Content $err -ErrorAction SilentlyContinue)) {
        $m = [regex]::Match($l, 'silence_start:\s*(-?[\d\.]+)')
        if ($m.Success) { $ini = [double]::Parse($m.Groups[1].Value, $inv); continue }
        $m = [regex]::Match($l, 'silence_end:\s*([\d\.]+)')
        if ($m.Success -and $null -ne $ini) {
            $null = $sil.Add([pscustomobject]@{ Ini = $ini; Fim = [double]::Parse($m.Groups[1].Value, $inv) })
            $ini = $null
        }
    }
    $n = [math]::Max($Minimo, [int][math]::Ceiling($Duracao / $Alvo))
    $cortes = New-Object System.Collections.ArrayList
    for ($k = 1; $k -lt $n; $k++) {
        $t = $Duracao * $k / $n
        $melhor = $null
        foreach ($s in $sil) {
            $meio = ($s.Ini + $s.Fim) / 2
            if ([math]::Abs($meio - $t) -le 45 -and
                ($null -eq $melhor -or ($s.Fim - $s.Ini) -gt ($melhor.Fim - $melhor.Ini))) { $melhor = $s }
        }
        $null = $cortes.Add($(if ($melhor) { ($melhor.Ini + $melhor.Fim) / 2 } else { $t }))
    }
    return $cortes.ToArray()
}

# Um whisper para um pedaco ("<base>.wav" -> "<base>.srt/.txt"), com o proprio
# relogio (-p 1). Usa $Modelo/$Idioma/$tBloco/$prompt/$Threads deste script.
function Start-WhisperPedaco([string]$BasePedaco, [string]$Extra) {
    $a = '-m "{0}" -f "{1}.wav" -l {2} -t {3} -p 1 -otxt -osrt -of "{1}" --prompt "{4}"{5}' -f `
         $Modelo, $BasePedaco, $Idioma, $tBloco, $prompt, $Extra
    $pr = Start-Process -FilePath $WhisperExe -ArgumentList $a -NoNewWindow -PassThru `
                        -RedirectStandardOutput "$BasePedaco.out" -RedirectStandardError "$BasePedaco.err"
    $null = Set-AfinidadeNucleos -Processo $pr -Nucleos $Threads
    return $pr
}

# Espera o arquivo ficar livre: o OBS ainda esta finalizando/remuxando o mp4 quando o evento dispara.
function Wait-Unlocked([string]$path, [int]$timeoutSec = 300) {
    $limite = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $limite) {
        try {
            # FileShare.Read = "ninguem esta ESCREVENDO". O OBS gravando segura o
            # arquivo com escrita e continua barrando; programa que so LE (o Kdenlive
            # com o video aberto) passa. Com FileShare.None qualquer leitor barrava,
            # e retranscrever video aberto no editor desistia depois de 5 min.
            $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'Read')
            $fs.Close()
            return $true
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    return $false
}

Log "=== inicio: $Video"

# --- uma transcricao por vez (varias gravacoes seguidas entram na fila) ---
$mutex = New-Object System.Threading.Mutex($false, "Global\ObsTranscricao")
$temMutex = $false
try {
    $temMutex = $mutex.WaitOne([TimeSpan]::FromHours(6))
} catch [System.Threading.AbandonedMutexException] {
    $temMutex = $true
}

try {
    if (-not (Test-Path $WhisperExe)) { Log "ERRO: whisper-cli.exe nao encontrado em $WhisperExe"; exit 1 }
    if (-not (Test-Path $Modelo))     { Log "ERRO: modelo nao encontrado em $Modelo"; exit 1 }
    if (-not (Test-Path $Video))      { Log "ERRO: video nao encontrado: $Video"; exit 1 }

    try { $ffmpeg = Get-Ffmpeg } catch { Log "ERRO: $_"; exit 1 }

    if (-not (Wait-Unlocked $Video)) { Log "ERRO: o video continuou sendo gravado/alterado por 5 min (OBS ainda gravando?), desisti"; exit 1 }

    # teto de processador = teto de NUCLEOS ocupados. E o que da para garantir e
    # medir: job object com teto rigido aceita a configuracao e nao segura nada.
    $nucleos = [Environment]::ProcessorCount
    if ($Threads -le 0) {
        if ($CpuMax -gt 0 -and $CpuMax -lt 100) {
            $Threads = [math]::Max(2, [int][math]::Floor($nucleos * $CpuMax / 100.0))
        } else {
            $Threads = [math]::Max(4, [int]($nucleos / 2))
        }
    }

    $pasta   = Split-Path -Parent $Video
    $nome    = [System.IO.Path]::GetFileNameWithoutExtension($Video)
    $saida   = Join-Path $pasta $nome            # whisper acrescenta .txt / .srt

    # ja transcrito? nao gasta 10 min de CPU de novo (o OBS as vezes dispara duas vezes)
    if (-not $Forcar -and (Test-Path "$saida.txt") -and
        (Get-Item "$saida.txt").LastWriteTime -gt (Get-Item $Video).LastWriteTime) {
        Log "ja existe transcricao mais nova que o video - pulando (use -Forcar para refazer)"
        exit 0
    }
    $wav     = Join-Path $env:TEMP ("obs-transcricao-" + [guid]::NewGuid().ToString("N") + ".wav")

    $null = Start-Progresso -Pasta $LogDir -Video $Video
    Log ("teto de processador: $CpuMax% de $nucleos nucleos = $Threads em uso")

    # o OpenBLAS que vem com o whisper monta a PROPRIA legiao de threads e ignora
    # o -t; sem estas variaveis o teto vai por agua abaixo (medido: 30% virava 53%)
    $env:OPENBLAS_NUM_THREADS = $Threads
    $env:OMP_NUM_THREADS      = $Threads
    $env:GOTO_NUM_THREADS     = $Threads

    # --- 1. extrai audio mono 16 kHz (formato que o whisper espera) ---
    Set-Progresso 2 "preparando audio" ""
    Log "extraindo audio com ffmpeg..."
    # os argumentos vao como UMA string com aspas: o Start-Process do PS 5.1 nao poe
    # aspas sozinho, e todo nome de gravacao do OBS tem espaco ("2026-08-12 11-47-58.mp4")
    # -map 0:a:0 = SEMPRE a faixa 1 (a mistura). Sem isso o ffmpeg escolhe sozinho,
    # e a gravacao agora tem duas faixas - nao quero depender do criterio dele.
    # -threads: sem isso o ffmpeg toma todos os nucleos e estoura o teto
    $ffArgs = '-hide_banner -loglevel error -y -threads {2} -i "{0}" -map 0:a:0 -vn -ac 1 -ar 16000 -c:a pcm_s16le "{1}"' -f $Video, $wav, $Threads
    $ffErr  = Join-Path $LogDir "ultimo-erro-ffmpeg.txt"
    # extracao de audio dura ~1s: nao vale complicar para limitar nucleo aqui
    $ff = Start-Process -FilePath $ffmpeg -ArgumentList $ffArgs -NoNewWindow -Wait -PassThru `
                        -RedirectStandardError $ffErr
    if ($ff.ExitCode -ne 0 -or -not (Test-Path $wav)) {
        $detalhe = (Get-Content $ffErr -Raw -ErrorAction SilentlyContinue)
        Log "ERRO: ffmpeg falhou (codigo $($ff.ExitCode)) - $detalhe"
        exit 1
    }

    $dur = [math]::Round((Get-Item $wav).Length / (16000 * 2) / 60, 1)

    # Pedacos em paralelo: o whisper escala MAL acima de ~16 threads - medido
    # neste PC, 22 threads renderam so 10% a mais que 16. Rodar 4 pedacos do audio
    # ao mesmo tempo rende 1,45x com as mesmas threads (medido com o "-p 4", que
    # fazia isso por dentro e estragava os tempos - ver a etapa 2). O preco sao as
    # emendas (o whisper perde o contexto ali), agora cortadas no silencio; em
    # video curto nao compensa - por isso o piso de 8 min.
    $blocos = 1
    if ($Threads -ge 8 -and $dur -ge 8) { $blocos = 4 }
    $tBloco = [math]::Max(2, [int][math]::Floor($Threads / $blocos))
    $comoRoda = if ($blocos -gt 1) { "pedacos em paralelo ($blocos por vez x $tBloco threads)" } else { "$tBloco threads" }
    Log "audio extraido: $dur min. transcrevendo com $comoRoda (modelo large-v3-turbo, idioma $Idioma)..."

    # --- 2. transcreve ---
    $t0 = Get-Date
    $prompt = "Transcricao em portugues do Brasil, com pontuacao e acentuacao."

    # VAD: corta os trechos sem fala antes de transcrever. Sem isso o whisper inventa
    # texto no silencio (credito de legendador inventado, "Amara.org" e afins).
    $argsVad = ""
    if (Test-Path $ModeloVad) {
        $argsVad = ' --vad -vm "{0}" -vt 0.5 -vsd 300 -vp 200 -sns' -f $ModeloVad
    } else {
        Log "AVISO: modelo VAD ausente - silencio pode virar texto inventado"
    }

    $stdErr = Join-Path $LogDir "ultimo-erro-whisper.txt"
    $stdOut = Join-Path $LogDir "ultima-saida-whisper.txt"
    Set-Content $stdErr "" -Encoding utf8

    if ($blocos -gt 1) {
        # Pedacos cortados AQUI, e nao pelo "-p" do whisper. Medido em 2026-09-10:
        # "-p 4" junto com o VAD estraga os tempos do fim de gravacao longa - a
        # partir de certo ponto TODAS as legendas saem com o mesmo instante (0,7s,
        # 0,7s...), e a legenda de 1h37 terminava em 3900s. O texto vinha certo, so
        # o relogio quebrava (e com ele a legenda e a identificacao de quem falou).
        # Cada pedaco agora e um whisper separado (-p 1) com o proprio relogio, e
        # aqui somamos o inicio do pedaco. Ate ~10 min por pedaco: nesse tamanho o
        # VAD nunca falhou nos testes.
        $tmpPed = Join-Path $env:TEMP ("obs-transcricao-ped-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $tmpPed -Force | Out-Null
        try {
            $inv = [System.Globalization.CultureInfo]::InvariantCulture
            $durSeg = (Get-Item $wav).Length / (16000 * 2)
            $cortes = @(Get-PontosDeCorte -Wav $wav -Duracao $durSeg -Alvo 600 -Minimo $blocos -Ffmpeg $ffmpeg -Pasta $tmpPed)
            $limites = @(0.0) + $cortes + @($durSeg)
            $pedacos = @()
            for ($i = 0; $i -lt $limites.Count - 1; $i++) {
                $basePed = Join-Path $tmpPed ("p{0:00}" -f $i)
                $len = [double]$limites[$i + 1] - [double]$limites[$i]
                # numero para linha de comando SEMPRE invariante: -f poe virgula em pt-BR
                $a = '-hide_banner -loglevel error -y -ss {0} -i "{1}" -t {2} -c:a pcm_s16le "{3}.wav"' -f `
                     ([double]$limites[$i]).ToString("0.###", $inv), $wav, $len.ToString("0.###", $inv), $basePed
                Start-Process -FilePath $ffmpeg -ArgumentList $a -NoNewWindow -Wait
                $pedacos += [pscustomobject]@{ N = $i; Ini = [double]$limites[$i]; Dur = $len; Base = $basePed; Proc = $null; Feito = $false }
            }
            Log ("{0} pedacos (ate ~10 min, cortados no silencio), {1} por vez x {2} threads" -f $pedacos.Count, $blocos, $tBloco)

            # cada whisper com a sua parte: o OpenBLAS monta a propria legiao de
            # threads e ignora o -t, e a variavel e herdada na hora do Start-Process
            $env:OPENBLAS_NUM_THREADS = $tBloco
            $env:OMP_NUM_THREADS      = $tBloco
            $env:GOTO_NUM_THREADS     = $tBloco

            $previsto = [math]::Max(10.0, $durSeg / 3.0)
            $proximo = 0
            while ($true) {
                foreach ($p in $pedacos) { if ($p.Proc -and -not $p.Feito -and $p.Proc.HasExited) { $p.Feito = $true } }
                $rodando = @($pedacos | Where-Object { $_.Proc -and -not $_.Feito }).Count
                while ($rodando -lt $blocos -and $proximo -lt $pedacos.Count) {
                    $pedacos[$proximo].Proc = Start-WhisperPedaco $pedacos[$proximo].Base $argsVad
                    $proximo++
                    $rodando++
                }
                if ($proximo -ge $pedacos.Count -and $rodando -eq 0) { break }
                Start-Sleep -Milliseconds 800
                $prontos = @($pedacos | Where-Object { $_.Feito })
                $feito = ($prontos | Measure-Object -Property Dur -Sum).Sum
                if ($null -eq $feito) { $feito = 0 }
                $pctRelogio = 100.0 * ((Get-Date) - $t0).TotalSeconds / $previsto
                $pct = [math]::Min(95, [int][math]::Max($pctRelogio, 100.0 * $feito / $durSeg))
                Set-Progresso (5 + [int]($pct * 0.65)) "transcrevendo" ("{0} de {1} pedacos" -f $prontos.Count, $pedacos.Count)
            }

            # junta: cada pedaco comeca do zero, entao soma o inicio dele
            $todas = New-Object System.Collections.ArrayList
            $textos = New-Object System.Text.StringBuilder
            $faltou = 0
            foreach ($p in $pedacos) {
                $cues = @(Read-SrtCues "$($p.Base).srt")
                if ($cues.Count -gt 0 -and -not (Test-SrtSaudavel $cues $p.Dur)) {
                    Log ("AVISO: pedaco {0} voltou com os tempos quebrados - refazendo sem VAD" -f $p.N)
                    $pr = Start-WhisperPedaco $p.Base ""
                    $pr.WaitForExit()
                    $cues = @(Read-SrtCues "$($p.Base).srt")
                }
                if (-not (Test-Path "$($p.Base).srt")) {
                    $faltou++
                    $motivo = Get-Content "$($p.Base).err" -Raw -ErrorAction SilentlyContinue
                    Add-Content -Path $stdErr -Value ("--- pedaco {0}`n{1}" -f $p.N, $motivo) -Encoding utf8
                }
                foreach ($c in $cues) {
                    $null = $todas.Add([pscustomobject]@{ Ini = $c.Ini + $p.Ini; Fim = $c.Fim + $p.Ini; Texto = $c.Texto })
                }
                if (Test-Path "$($p.Base).txt") {
                    [void]$textos.Append([System.IO.File]::ReadAllText("$($p.Base).txt", [System.Text.Encoding]::UTF8))
                }
            }
            Write-SrtCues $todas.ToArray() "$saida.srt"
            [System.IO.File]::WriteAllText("$saida.txt", $textos.ToString(), (New-Object System.Text.UTF8Encoding($false)))
            if (-not (Test-SrtSaudavel $todas.ToArray() $durSeg)) { Log "AVISO: a legenda final ainda tem tempo fora de ordem - confira" }
            $codigo = if ($faltou -eq 0) { 0 } else { 1 }
            $deuCerto = ($faltou -eq 0)
        } finally {
            Remove-Item $tmpPed -Recurse -Force -ErrorAction SilentlyContinue
        }
    } else {

    # um whisper so, com todas as threads (video curto)
    # mesma regra do ffmpeg: uma string so, com aspas nos caminhos ($saida tem espaco)
    $wArgs = '-m "{0}" -f "{1}" -l {2} -t {3} -p 1 -otxt -osrt -of "{4}" --prompt "{5}"' -f `
             $Modelo, $wav, $Idioma, $tBloco, $saida, $prompt
    $wArgs += $argsVad
    $wArgs += " -pp"          # imprime o andamento, que vira barra na janela

    # sem -Wait: enquanto ele trabalha, leio o andamento que ele imprime
    $w = Start-Process -FilePath $WhisperExe -ArgumentList $wArgs -NoNewWindow -PassThru `
                       -RedirectStandardOutput $stdOut -RedirectStandardError $stdErr
    $null = Set-AfinidadeNucleos -Processo $w -Nucleos $Threads
    # Com -p o whisper quase nao imprime andamento (medido: 2 avisos na transcricao
    # inteira, "53%" e "100%"). Entao a barra anda pelo relogio, usando a velocidade
    # tipica desta maquina, e SALTA para a frente quando ele diz algo de verdade.
    # Trava em 95% ate terminar: barra que chega a 100% e fica parada mente pior
    # do que barra que demora no fim.
    $xTempoReal = if ($blocos -gt 1) { 3.0 } else { 2.2 }
    $previsto = [math]::Max(10.0, $dur * 60.0 / $xTempoReal)
    while (-not $w.HasExited) {
        Start-Sleep -Milliseconds 800
        try {
            $decorrido = ((Get-Date) - $t0).TotalSeconds
            $pct = [math]::Min(95, [int](100.0 * $decorrido / $previsto))
            $ultima = [regex]::Matches((Get-Content $stdErr -Raw -ErrorAction SilentlyContinue), 'progress\s*=\s*(\d+)%')
            if ($ultima.Count -gt 0) {
                $real = [int]$ultima[$ultima.Count - 1].Groups[1].Value
                if ($real -gt $pct) { $pct = $real }
            }
            $resta = if ($pct -ge 95) { "terminando" }
                     else { "faltam ~{0} min" -f [math]::Ceiling([math]::Max(0, $previsto - $decorrido) / 60) }
            # a transcricao ocupa a faixa de 5% a 70% da barra total
            Set-Progresso (5 + [int]($pct * 0.65)) "transcrevendo" $resta
        } catch { }
    }
    $w.WaitForExit()
    $mins = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)

    # sem -Wait, o PowerShell as vezes devolve ExitCode vazio mesmo tendo dado certo:
    # nesse caso quem decide e a existencia da transcricao
    $codigo = $null
    try { $codigo = $w.ExitCode } catch { }
    $deuCerto = if ($null -ne $codigo) { $codigo -eq 0 } else { Test-Path "$saida.txt" }
    }
    $mins = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)
    if (-not $deuCerto) {
        Log "ERRO: whisper falhou (codigo $codigo). Detalhes em $stdErr"
        exit 1
    }

    if (Test-Path "$saida.txt") {
        # o whisper grava UTF-8 sem BOM; com BOM o Bloco de Notas/Word abrem com acento certo
        $texto = [System.IO.File]::ReadAllText("$saida.txt", [System.Text.Encoding]::UTF8)

        if ($texto.Trim() -eq "") {
            # Um vídeo sem voz também é um resultado válido. Mantemos os dois
            # arquivos para que a pessoa não veja uma falsa conclusão sem saída.
            $semFala = "[Nenhuma fala detectada neste vídeo.]"
            $semFalaSrt = "1`r`n00:00:00,000 --> 00:00:02,000`r`n$semFala`r`n"
            [System.IO.File]::WriteAllText("$saida.txt", $semFala, (New-Object System.Text.UTF8Encoding($true)))
            [System.IO.File]::WriteAllText("$saida.srt", $semFalaSrt, (New-Object System.Text.UTF8Encoding($true)))
            Log "nenhuma fala detectada em $mins min - resultado explicativo salvo em TXT e SRT"
        } else {
            [System.IO.File]::WriteAllText("$saida.txt", $texto, (New-Object System.Text.UTF8Encoding($true)))
            $chars = (Get-Item "$saida.txt").Length
            Log "OK em $mins min -> $saida.txt ($chars bytes) e $saida.srt"

            # --- 3. se for reuniao, descobre quem falou cada trecho ---
            Set-Progresso 72 "procurando quem falou" ""
            $scriptFalantes = Join-Path $Base "falantes.ps1"
            if (-not $SemFalantes -and (Test-Path $scriptFalantes) -and (Test-Path "$saida.srt")) {
                try {
                    & $scriptFalantes -Video $Video -Srt "$saida.srt" -Threads $Threads
                } catch {
                    Log "AVISO: identificacao de quem falou falhou: $_"
                }
            }

            # --- 4. poe a legenda dentro do proprio video ---
            # "<video>.srt" ja e a legenda COM nome quando a identificacao rodou (o
            # falantes.ps1 guarda a do whisper como "- sem nomes.srt"); se nao
            # rodou, e a do whisper mesmo
            if (-not $SemLegenda) {
                Set-Progresso 96 "embutindo a legenda" ""
                $srtUsar = "$saida.srt"
                try {
                    $r = Add-LegendaNoVideo -Video $Video -Srt $srtUsar -Ffmpeg $ffmpeg `
                                            -Ffprobe (Get-Ffprobe) -PastaLog $LogDir
                    Log "legenda: $r"
                } catch {
                    Log "AVISO: nao consegui embutir a legenda: $_"
                }
            }
        }
    } else {
        Log "ERRO: whisper terminou sem gerar os arquivos de transcricao em $mins min"
        exit 1
    }
}
finally {
    Stop-Progresso
    if (Test-Path variable:wav) { Remove-Item $wav -Force -ErrorAction SilentlyContinue }
    if ($temMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
    Log "=== fim: $Video"
}
