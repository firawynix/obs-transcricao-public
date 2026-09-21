<#
    falantes.ps1 - descobre QUEM falou cada trecho de uma reuniao do Teams.

    Como funciona: no Teams a miniatura de quem esta falando ganha uma borda
    azul-violeta, e o nome fica escrito num chip no canto da propria miniatura.
    O script amostra quadros do video gravado, acha essas bordas, le o nome com
    o OCR do Windows e cruza com os tempos da transcricao (.srt do whisper).

    Sai um arquivo "<video> - falas.txt" com "Nome: o que falou", e a legenda com
    nome vira o "<video>.srt" (a do whisper fica como "<video> - sem nomes.srt").
    Quem nao for identificavel vira "Nao identificado".

    Chamada 1:1 com a tela compartilhada nao tem miniatura para ler: ai o nome
    sai do titulo da janela, e o que nao for o seu microfone e da outra pessoa.

    Uso:  falantes.ps1 -Video "C:\...\reuniao.mp4"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Video,
    [string]$Srt = "",
    # so vale se o showinfo do ffmpeg nao devolver os tempos: a amostragem de
    # verdade e a dos keyframes do proprio video (~4s numa gravacao do OBS)
    [double]$Intervalo = 2.0,
    [int]$Corrida = 150,          # comprimento minimo da borda realcada (px)
    [int]$TolX = 24,              # tolerancia p/ juntar bordas da mesma miniatura

    # teams | meet | auto (auto = descobre sozinho na sondagem)
    [string]$Plataforma = "auto",

    # faixa 2 = microfone (quem esta na frente do OBS). Serve para identificar a
    # sua fala quando o Teams nao mostra/realca a sua miniatura.
    [string]$NomeLocal = "",      # vazio = deduz do usuario do Windows
    [double]$MicLimiarDb = -32,   # abaixo disso na faixa do mic e considerado silencio

    # quantos nucleos o ffmpeg pode ocupar (0 = decide aqui pelo teto padrao de 70%)
    [int]$Threads = 0
)

if ($Threads -le 0) {
    $Threads = [math]::Max(2, [int][math]::Floor([Environment]::ProcessorCount * 0.7))
}

$ErrorActionPreference = "Stop"

$Base    = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir  = if ($env:FIRAW_OBS_DATA_DIR) { Join-Path $env:FIRAW_OBS_DATA_DIR "logs" } else { Join-Path $Base "logs" }
$null = New-Item -ItemType Directory -Path $LogDir -Force
$LogFile = Join-Path $LogDir ("transcricao-" + (Get-Date -Format "yyyy-MM") + ".log")

function Log([string]$msg) {
    $linha = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Add-Content -Path $LogFile -Value $linha -Encoding utf8
    Write-Verbose $msg
}

. (Join-Path $Base "lib-quadro.ps1")
. (Join-Path $Base "lib-ocr.ps1")
. (Join-Path $Base "lib-ffmpeg.ps1")
. (Join-Path $Base "lib-progresso.ps1")
. (Join-Path $Base "lib-cpu.ps1")

$FFMPEG  = Get-Ffmpeg
$FFPROBE = Get-Ffprobe

# continua a barra que o transcrever.ps1 comecou (72% a 100%)
Use-Progresso -Pasta $LogDir -Video $Video

# ------------------------------------------------------ perfis de plataforma
#
# Cada plataforma marca quem fala com uma borda colorida na miniatura e escreve o
# nome num chip no canto inferior esquerdo dela. Muda a cor e a folga do recorte;
# a logica e a mesma. Cores medidas em gravacao real.
#
#   ATENCAO (Meet): em modo APRESENTACAO a borda fica em quem apresenta e nao
#   acompanha quem fala. So vale em modo grade.

$PERFIS = @{
    teams = [pscustomobject]@{ Nome = "Teams"; R = 130; G = 128; B = 225; Tol = 45; Dx = 4; Dy = 43 }
    meet  = [pscustomobject]@{ Nome = "Google Meet"; R = 180; G = 198; B = 227; Tol = 30; Dx = -8; Dy = 45 }
}

# UM rotulo so para quem nao deu para identificar ("Nao identificado", com o til
# montado por codigo para nao depender do encoding deste arquivo)
$SEM_NOME = "N" + [char]0x00E3 + "o identificado"

function Get-Caixas($imagem, $perfil, $corrida, $tolX, $largMax = 0) {
    $todas = @([Quadro]::BordasPorCor($imagem, $corrida, $perfil.R, $perfil.G, $perfil.B, $perfil.Tol, $tolX))
    # descarta o que nao tem cara de miniatura. Planilha/site compartilhado tem
    # muita linha clara e passava pelo filtro de tamanho; miniatura de gente tem
    # proporcao de video (entre 0,9 e 2,2), tabela de Excel nao.
    # E teto de largura: a AREA COMPARTILHADA tambem tem proporcao de video, e o
    # OCR dela injetava "gente" chamada "Party ref TMF BusinessPartner" na lista.
    # Miniatura de participante nao ocupa mais da metade de uma tela ultrawide.
    $bons = @($todas | Where-Object {
        $l = $_[2] - $_[0]; $a = $_[3] - $_[1]
        $l -ge 300 -and $a -ge 150 -and ($l / $a) -ge 0.9 -and ($l / $a) -le 2.2 -and
        ($largMax -le 0 -or $l -le $largMax)
    })
    # a virgula e obrigatoria: com UMA caixa o PowerShell desmonta o array e o
    # chamador acaba iterando sobre os 5 numeros da caixa em vez da caixa
    return , $bons
}

# ---------------------------------------------------------------- utilidades

function ConvertTo-Segundos([string]$hhmmss) {
    # "00:01:23,450" -> 83.45
    $m = [regex]::Match($hhmmss, '(\d+):(\d+):(\d+)[,.](\d+)')
    if (-not $m.Success) { return $null }
    [double]$m.Groups[1].Value * 3600 + [double]$m.Groups[2].Value * 60 +
    [double]$m.Groups[3].Value + [double]("0." + $m.Groups[4].Value)
}

function Format-Srt([double]$seg) {
    if ($seg -lt 0) { $seg = 0 }
    # conta em milissegundos inteiros: [int] no PowerShell ARREDONDA (0,5h virava 1h)
    [long]$ms = [math]::Round($seg * 1000)
    [long]$t = [math]::Floor($ms / 1000)
    "{0:00}:{1:00}:{2:00},{3:000}" -f [int][math]::Floor($t / 3600), [int][math]::Floor(($t % 3600) / 60), [int]($t % 60), [int]($ms % 1000)
}

# "Carlos Eduardo Monteiro do Vale" -> "Carlos" (ou "Carlos Vale" se houver
# outro Carlos). Nome inteiro na legenda come a tela toda.
function Get-NomesCurtos($nomes) {
    $porPrimeiro = @{}
    foreach ($nm in ($nomes | Select-Object -Unique)) {
        # "Nao identificado" nem vai para a legenda (sai so o texto da fala)
        if ($nm -eq $SEM_NOME) { continue }
        $p = ($nm -split '\s+')[0]
        if (-not $porPrimeiro.ContainsKey($p)) { $porPrimeiro[$p] = @() }
        $porPrimeiro[$p] += $nm
    }
    $curto = @{}
    foreach ($p in $porPrimeiro.Keys) {
        $lista = @($porPrimeiro[$p])
        if ($lista.Count -eq 1) {
            $curto[$lista[0]] = $p
        } else {
            foreach ($nm in $lista) {
                $partes = $nm -split '\s+'
                $curto[$nm] = if ($partes.Count -gt 1) { "$p $($partes[-1])" } else { $nm }
            }
        }
    }
    return $curto
}

function Format-Tempo([double]$seg) {
    if ($seg -lt 0) { $seg = 0 }
    [long]$t = [math]::Floor($seg)          # idem: nada de [int] em valor fracionario
    [int]$h = [math]::Floor($t / 3600)
    [int]$m = [math]::Floor(($t % 3600) / 60)
    [int]$s = $t % 60
    if ($h -ge 1) { return "{0}:{1:00}:{2:00}" -f $h, $m, $s }
    return "{0:00}:{1:00}" -f ($h * 60 + $m), $s
}

function Read-Srt([string]$caminho) {
    $texto = [System.IO.File]::ReadAllText($caminho, [System.Text.Encoding]::UTF8)
    # grupo SEM captura: com captura o -split devolve os separadores junto
    $blocos = $texto -split "(?:`r?`n){2,}"
    $segs = @()
    foreach ($bloco in $blocos) {
        $linhas = $bloco -split "`r?`n" | Where-Object { $_.Trim() -ne "" }
        if ($linhas.Count -lt 2) { continue }
        $tempo = $linhas | Where-Object { $_ -match '-->' } | Select-Object -First 1
        if (-not $tempo) { continue }
        $partes = $tempo -split '-->'
        $ini = ConvertTo-Segundos $partes[0]
        $fim = ConvertTo-Segundos $partes[1]
        if ($null -eq $ini) { continue }
        $idx = [array]::IndexOf($linhas, $tempo)
        $txt = ($linhas[($idx + 1)..($linhas.Count - 1)] -join " ").Trim()
        if ($txt -eq "") { continue }
        $segs += [pscustomobject]@{ Ini = $ini; Fim = $fim; Texto = $txt; Nome = $null }
    }
    return $segs
}

# duas leituras de OCR sao da mesma pessoa? ("Paulo Da Costa Ribeiro 'h" e
# "Rafael Augusto Moura" sao a mesma pessoa que "Paulo Da Costa Ribeiro" e
# "Rafael Augusto De Moura" - o OCR come e inventa letra em nome comprido)
function Get-Achatado([string]$s) {
    (($s.ToLower() -replace '[^\p{L}\p{M} ]', ' ') -replace '\s+', ' ').Trim()
}

function Test-MesmaPessoa([string]$a, [string]$b) {
    $x = Get-Achatado $a
    $y = Get-Achatado $b
    if ($x -eq "" -or $y -eq "") { return $false }
    if ($x -eq $y) { return $true }
    # um contido no outro (nome cortado pelo recorte), exigindo tamanho decente
    $curto = if ($x.Length -le $y.Length) { $x } else { $y }
    $longo = if ($x.Length -le $y.Length) { $y } else { $x }
    if ($curto.Length -ge 8 -and $longo.Contains($curto)) { return $true }

    # palavra a palavra, na mesma posicao. O OCR corta o fim do nome e troca uma
    # letra no meio ("Tiago Samue De" x "Tiago Samuel De Freitas", "Marlna Souza
    # Prado" x "Marina Souza Prado"): no texto inteiro a distancia de edicao
    # passa do limite, mas palavra a palavra fica evidente que e a mesma pessoa.
    $pa = @($x -split ' ' | Where-Object { $_ -ne "" })
    $pb = @($y -split ' ' | Where-Object { $_ -ne "" })
    $n = [math]::Min($pa.Count, $pb.Count)
    if ($n -ge 2) {
        $firmes = 0     # palavra que bate com folga pequena
        $frouxas = 0    # palavra que bate so com folga grande
        for ($i = 0; $i -lt $n; $i++) {
            $u = $pa[$i]; $v = $pb[$i]
            $c = if ($u.Length -le $v.Length) { $u } else { $v }
            $g = if ($u.Length -le $v.Length) { $v } else { $u }
            $d = Get-Distancia $u $v
            if ($g.StartsWith($c) -or $d -le [math]::Max(1, [int][math]::Floor($c.Length / 3))) { $firmes++; $frouxas++ }
            elseif ($d -le [math]::Max(2, [int][math]::Floor($c.Length / 2))) { $frouxas++ }
        }
        # TODAS as palavras tem de bater. Tentei tolerar uma palavra estropiada
        # ("Marlna Souza Prado" x "Marina Souza Prado", que sao a mesma
        # pessoa) e o teste mostrou o preco: "Luciana De Melo" e "Juliana De
        # Melo" - duas pessoas diferentes - viravam uma so. Duplicar uma pessoa
        # e um incomodo; juntar duas poe a fala de alguem na boca de outro.
        if ($firmes -eq $n) { return $true }
        $null = $frouxas
    }

    # ate 15% de letras diferentes (nome longo tolera mais erro que nome curto)
    $limite = [math]::Max(2, [int]($curto.Length * 0.15))
    return (Get-Distancia $x $y) -le $limite
}

# distancia de edicao, para juntar leituras de OCR quase iguais
function Get-Distancia([string]$a, [string]$b) {
    if ($a -eq $b) { return 0 }
    $n = $a.Length; $m = $b.Length
    if ($n -eq 0) { return $m }
    if ($m -eq 0) { return $n }
    $ant = New-Object int[] ($m + 1)
    $atu = New-Object int[] ($m + 1)
    for ($j = 0; $j -le $m; $j++) { $ant[$j] = $j }
    for ($i = 1; $i -le $n; $i++) {
        $atu[0] = $i
        for ($j = 1; $j -le $m; $j++) {
            $custo = if ($a[$i - 1] -eq $b[$j - 1]) { 0 } else { 1 }
            $atu[$j] = [math]::Min([math]::Min($atu[$j - 1] + 1, $ant[$j] + 1), $ant[$j - 1] + $custo)
        }
        [array]::Copy($atu, $ant, $m + 1)
    }
    return $ant[$m]
}

# Quantas faixas de audio o video tem. O OBS grava faixa 1 = mistura e, se estiver
# configurado, faixa 2 = so o microfone.
function Get-QtdFaixasAudio($video) {
    $saida = & $FFPROBE -v error -select_streams a -show_entries stream=index -of csv=p=0 "$video" 2>$null
    return @($saida | Where-Object { $_ -ne "" }).Count
}

# Intervalos em que o microfone TEM som, na faixa 2 (o complemento do silencio).
function Get-IntervalosMic($video, $limiarDb, $duracao, $tmpDir) {
    $err = Join-Path $tmpDir "silencio-mic.txt"
    # nao usar $args: e variavel automatica do PowerShell
    # numero SEMPRE com ToString(invariante): -f formata com virgula em pt-BR
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $argsFf = '-hide_banner -nostats -i "{0}" -map 0:a:1 -af silencedetect=noise={1}dB:d=0.4 -f null NUL' -f `
              $video, ([double]$limiarDb).ToString($inv)
    Start-Process -FilePath $FFMPEG -ArgumentList $argsFf -NoNewWindow -Wait -RedirectStandardError $err

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    # objetos com campo, e nao pares @(a,b): o "return" do PowerShell desmonta
    # array de arrays e os pares viram numeros soltos
    $silencios = New-Object System.Collections.ArrayList
    $ini = $null
    foreach ($linha in (Get-Content $err -ErrorAction SilentlyContinue)) {
        $m = [regex]::Match($linha, 'silence_start:\s*(-?[\d\.]+)')
        if ($m.Success) { $ini = [double]::Parse($m.Groups[1].Value, $inv); continue }
        $m = [regex]::Match($linha, 'silence_end:\s*([\d\.]+)')
        if ($m.Success -and $null -ne $ini) {
            $null = $silencios.Add([pscustomobject]@{ Ini = $ini; Fim = [double]::Parse($m.Groups[1].Value, $inv) })
            $ini = $null
        }
    }
    if ($null -ne $ini) { $null = $silencios.Add([pscustomobject]@{ Ini = $ini; Fim = $duracao }) }

    # complemento: onde NAO e silencio, o mic esta captando
    $comSom = New-Object System.Collections.ArrayList
    $pos = 0.0
    foreach ($s in $silencios) {
        if ($s.Ini -gt $pos) { $null = $comSom.Add([pscustomobject]@{ Ini = $pos; Fim = $s.Ini }) }
        $pos = [math]::Max($pos, $s.Fim)
    }
    if ($pos -lt $duracao) { $null = $comSom.Add([pscustomobject]@{ Ini = $pos; Fim = $duracao }) }

    # SEM a virgula de propósito. Ela serve para proteger array DE ARRAYS do
    # desmonte do PowerShell; aqui os elementos sao objetos, entao o desmonte e
    # inofensivo - e a virgula e que estragava: com varios trechos, o chamador
    # recebia UM elemento contendo o array inteiro, e "$iv.Fim - $iv.Ini"
    # explodia com "[System.Object[]] nao contem op_Subtraction".
    # Pior: so acontecia quando havia MAIS DE UM trecho de voz no microfone.
    return $comSom.ToArray()
}

function Get-SobreposicaoMic($intervalos, $ini, $fim) {
    if ($fim -le $ini) { return 0.0 }
    $soma = 0.0
    foreach ($iv in $intervalos) {
        $a = [math]::Max($ini, $iv.Ini)
        $b = [math]::Min($fim, $iv.Fim)
        if ($b -gt $a) { $soma += ($b - $a) }
    }
    return $soma / ($fim - $ini)
}

# O OCR erra feio quando o recorte pega icone ou borda: "Roberto Alves Lima"
# tambem saiu como "QRobêrtô.MtI Lima" e "BEfii'àrt AlvêLírna", e cada
# variante dessas virava "mais uma pessoa" na lista. Distancia de edicao nao
# salva leitura tao corrompida - o jeito e medir o quanto o texto PARECE nome de
# gente, descartar o que nao parece e ficar com a melhor de varias leituras.
$LIXO_DE_TELA = @(
    'abrir', 'visualiza', 'detalhada', 'segment', 'apresenta', 'compartilh',
    'participante', 'convidado', 'microfone', 'camera', 'reuniao', 'chat',
    'legenda', 'atividade', 'pessoas', 'informacoes', 'gravacao'
)
# de proposito FORA da lista: "tela" casaria com "Estela", "sala" com "Salatiel".
# Palavra curta demais para virar filtro por conter.

# 0 = nao parece nome; 1 = nome limpo, tipo "Beatriz da Silveira Campos"
function Get-QualidadeNome([string]$texto) {
    if ($null -eq $texto) { return 0.0 }
    $t = $texto.Trim()
    if ($t.Length -lt 4) { return 0.0 }

    $achatado = Get-Achatado $t
    foreach ($lixo in $LIXO_DE_TELA) { if ($achatado -like "*$lixo*") { return 0.0 } }

    # no Teams e no Meet o chip traz o nome completo: uma palavra so e legenda de tela
    $palavras = @($t -split '\s+' | Where-Object { $_ -ne "" })
    if ($palavras.Count -lt 2) { return 0.0 }

    $letras = ($t -replace '[^\p{L}\p{M} ]', '').Length
    $limpo = [double]$letras / $t.Length

    # -cmatch e obrigatorio: -match ignora maiuscula/minuscula e "MbãlEArád" passaria
    $boas = 0
    foreach ($p in $palavras) {
        if ($p -cmatch '^[\p{Lu}][\p{Ll}\p{M}]+$' -or $p -cmatch "^[\p{Lu}][\p{Ll}\p{M}]+['\-][\p{Lu}]?[\p{Ll}\p{M}]+$") { $boas++ }
    }
    $forma = [double]$boas / $palavras.Count

    return [math]::Round(($limpo * 0.4 + $forma * 0.6), 3)
}

function Get-NomeDaCaixa($quadro, $caixa, $tmpDir, $perfil) {
    $larg = [math]::Min(600, $caixa[2] - $caixa[0] - $perfil.Dx - 4)
    if ($larg -lt 40) { return "" }
    # le em duas ampliacoes e fica com a melhor: as vezes uma pega a primeira
    # letra que a outra perde ("Victor" virando "Ictor")
    $texto = ""
    foreach ($escala in @(4, 3)) {
        $png = Join-Path $tmpDir ("chip-" + [guid]::NewGuid().ToString("N") + ".png")
        try {
            [Quadro]::Recortar($quadro, $png, $caixa[0] + $perfil.Dx, $caixa[3] - $perfil.Dy, $larg, ($perfil.Dy - 3), $escala)
            $t = ((Get-LinhasOcr -Caminho $png | ForEach-Object { $_.Texto }) -join " ").Trim()
            if (($t -replace '[^\p{L}]', '').Length -gt ($texto -replace '[^\p{L}]', '').Length) { $texto = $t }
        } catch {
        } finally {
            Remove-Item $png -Force -ErrorAction SilentlyContinue
        }
    }
    # o chip as vezes traz icone (microfone, mao levantada) virando lixo no OCR
    $texto = ($texto -replace '[^\p{L}\p{M}\s\.\-'']', ' ') -replace '\s+', ' '
    $texto = $texto.Trim()

    # sobra de icone vira letra solta no fim ("... Pereira 'h"): corta pedaco de
    # ate 2 letras que nao seja particula de nome
    $particulas = @("de", "da", "do", "e", "di", "du", "del", "la")
    $partes = @($texto -split '\s+' | Where-Object { $_ -ne "" })
    while ($partes.Count -gt 1) {
        $ultimo = $partes[-1].Trim("'", ".", "-").ToLower()
        if ($ultimo.Length -le 2 -and $particulas -notcontains $ultimo) {
            $partes = @($partes[0..($partes.Count - 2)])
        } else { break }
    }
    # e no comeco tambem ("l Rafael Augusto"): nome nao comeca por particula,
    # entao pedaco curto na frente e sempre sobra de icone
    while ($partes.Count -gt 1 -and $partes[0].Trim("'", ".", "-").Length -le 2) {
        $partes = @($partes[1..($partes.Count - 1)])
    }
    # OCR pode nao devolver nada (miniatura sem chip, quadro escuro): sem isso,
    # o $partes[-1] abaixo estoura com "metodo em expressao de valor nulo"
    if ($partes.Count -eq 0) { return "" }

    # pontuacao pendurada na ponta ("Tiago Samuel De Freitas-")
    $partes[-1] = $partes[-1].TrimEnd("'", ".", "-", ",")
    $partes[0] = $partes[0].TrimStart("'", ".", "-", ",")
    return ($partes -join " ").Trim()
}

# o nome e de quem gravou? (usuario do Windows "Ana" x "Ana Paula ...")
function Test-EhVoce([string]$nome) {
    if (-not $nome) { return $false }
    if ($NomeLocal -and $nome -eq $NomeLocal) { return $true }
    $u = Get-Achatado $env:USERNAME
    if ($u -eq "") { return $false }
    $n = Get-Achatado $nome
    return ($n -eq $u) -or $n.StartsWith($u + " ")
}

# O titulo da janela do Teams e nome de UMA pessoa? Em chamada 1:1 e o nome da
# outra pessoa; em reuniao e "Ingresso na reuniao | Assunto" (o OCR le a barra
# como I ou l); em chamada de grupo vem a lista de nomes, que o OCR emenda com
# lixo no meio ("... Lima hv'llke de Brito Maga!haes"). Medido nas gravacoes reais.
function Test-TituloEhPessoa([string]$t) {
    if ($null -eq $t) { return $false }
    $t = $t.Trim()
    if ($t -match '[|,;:!?@#()\[\]0-9]' -or $t -match '\s[Il1]\s' -or $t -match '\s-\s') { return $false }
    # sem acento para comparar com a lista de lixo: o OCR le "reuniao" como "reuniào"
    $semAcento = -join ($t.Normalize([Text.NormalizationForm]::FormD).ToCharArray() |
        Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne [Globalization.UnicodeCategory]::NonSpacingMark })
    $achatado = Get-Achatado $semAcento
    foreach ($lixo in $LIXO_DE_TELA) { if ($achatado -like "*$lixo*") { return $false } }
    # nome de programa no titulo tem cara de nome de gente ("Microsoft Teams"
    # passava no teste): sem isto, janela principal do Teams virava "a outra pessoa"
    foreach ($prog in @('microsoft', 'teams', 'zoom', 'google', 'meet', 'webex', 'skype',
                        'discord', 'slack', 'whatsapp', 'studio', 'navegador', 'chrome', 'edge', 'opera')) {
        if (" $achatado " -like "* $prog *") { return $false }
    }

    $particulas = @("de", "da", "do", "das", "dos", "e", "di", "du", "del", "la", "van", "von")
    $palavras = @($t -split '\s+' | Where-Object { $_ -ne "" })
    # nome brasileiro comprido ("Maria Clara Castro e Albuquerque Lima") tem 6 palavras
    if ($palavras.Count -lt 2 -or $palavras.Count -gt 7) { return $false }
    $fortes = 0
    foreach ($p in $palavras) {
        if ($particulas -contains $p.ToLower()) { continue }
        # comeca com maiuscula e o resto e letra (de qualquer caixa): o OCR do titulo
        # leu "Albuquerque" como "AZupuerque" em 6 de 8 quadros, e exigir minuscula
        # derrubava a chamada inteira. Lixo do OCR comeca minusculo ("hv'llke") ou
        # traz simbolo, e isso continua fora. Aceita "D'Avila", "Jean-Luc".
        if ($p -cnotmatch "^(?:[\p{Lu}]['\-])?[\p{Lu}][\p{L}\p{M}]+(?:['\-][\p{L}\p{M}]+)?$") { return $false }
        $fortes++
    }
    return $fortes -ge 2
}

# Le o titulo da janela em 8 quadros espalhados pelo video. Devolve o nome so se
# ao menos 3 leituras concordarem - uma leitura solta nao decide nada.
function Get-NomeDaChamada($video, $duracao, $tmpDir) {
    $invC = [System.Globalization.CultureInfo]::InvariantCulture
    $leituras = New-Object System.Collections.ArrayList
    $lidos = 0
    for ($i = 1; $i -le 8; $i++) {
        $t = ($duracao * $i / 9.0).ToString("0.###", $invC)
        $img = Join-Path $tmpDir "titulo-$i.jpg"
        $png = Join-Path $tmpDir "titulo-$i.png"
        & $FFMPEG -hide_banner -loglevel error -y -ss $t -i "$video" -frames:v 1 -q:v 3 "$img" 2>$null
        if (-not (Test-Path $img)) { continue }
        $lidos++
        try {
            # barra de titulo do Teams maximizado: canto superior esquerdo, letra de ~12 px
            [Quadro]::Recortar($img, $png, 0, 0, 1300, 32, 3)
            $txt = ((Get-LinhasOcr -Caminho $png | ForEach-Object { $_.Texto }) -join " ").Trim()
            if (Test-TituloEhPessoa $txt) { $null = $leituras.Add($txt) }
        } catch {
        } finally {
            Remove-Item $img, $png -Force -ErrorAction SilentlyContinue
        }
    }
    if ($leituras.Count -lt 3) { return $null }

    # a mesma pessoa lida com letra trocada ("Galvao" x "Gafvao") e um voto so.
    # Nada de pipeline aqui: ele desmonta array de array (ver Get-Caixas)
    $grupos = New-Object System.Collections.ArrayList
    foreach ($l in $leituras) {
        $achou = $false
        for ($g = 0; $g -lt $grupos.Count; $g++) {
            if (Test-MesmaPessoa $grupos[$g][0] $l) { $null = $grupos[$g].Add($l); $achou = $true; break }
        }
        if (-not $achou) {
            $novo = New-Object System.Collections.ArrayList
            $null = $novo.Add($l)
            $null = $grupos.Add($novo)
        }
    }
    $maior = $null
    for ($g = 0; $g -lt $grupos.Count; $g++) {
        if ($null -eq $maior -or $grupos[$g].Count -gt $maior.Count) { $maior = $grupos[$g] }
    }
    if ($maior.Count -lt 3) { return $null }

    # Grafia oficial: votacao PALAVRA A PALAVRA entre as leituras com o mesmo
    # tamanho e o mesmo primeiro nome. Vence a grafia limpa (Maiuscula+minusculas)
    # mais frequente; so sem nenhuma limpa vale a mais frequente. Maioria simples
    # daria o erro: o OCR leu "AZupuerque" 6 vezes e "Albuquerque" 1.
    $primeira = @($maior[0] -split '\s+')[0]
    $tamanhos = @($maior | ForEach-Object { @($_ -split '\s+').Count })
    $n = [int](@($tamanhos | Group-Object | Sort-Object Count -Descending)[0].Name)
    $mesmas = @($leituras | Where-Object { $pp = @($_ -split '\s+'); $pp.Count -eq $n -and $pp[0] -eq $primeira })
    $palavras = @()
    for ($k = 0; $k -lt $n; $k++) {
        $cands = @($mesmas | ForEach-Object { @($_ -split '\s+')[$k] })
        $limpas = @($cands | Where-Object { $_ -cmatch '^[\p{Lu}][\p{Ll}\p{M}]+$' -or $_ -cmatch '^[\p{Ll}]+$' })
        $pool = if ($limpas.Count -gt 0) { $limpas } else { $cands }
        # Group-Object sai na ordem de primeira aparicao: no empate fica a que veio antes
        $vence = $null
        foreach ($g in ($pool | Group-Object)) { if ($null -eq $vence -or $g.Count -gt $vence.Count) { $vence = $g } }
        $palavras += $vence.Name
    }
    $oficial = $palavras -join " "
    return [pscustomobject]@{ Nome = $oficial; Votos = $maior.Count; Lidos = $lidos }
}

# ------------------------------------------------------------------ execucao

if (-not (Test-Path $Video)) { throw "video nao encontrado: $Video" }
if ($Srt -eq "") {
    # o "<video>.srt" pode ja ser a legenda COM nome de uma rodada anterior; a do
    # whisper, quando ja foi separada, esta em "- sem nomes.srt"
    $baseV = Join-Path (Split-Path -Parent $Video) ([System.IO.Path]::GetFileNameWithoutExtension($Video))
    $Srt = if (Test-Path -LiteralPath "$baseV - sem nomes.srt") { "$baseV - sem nomes.srt" } else { "$baseV.srt" }
}
if (-not (Test-Path $Srt)) { Log "falantes: sem .srt ($Srt) - nada a fazer"; exit 0 }

$segmentos = Read-Srt $Srt
if ($segmentos.Count -eq 0) { Log "falantes: .srt sem falas"; exit 0 }

$tmpDir = Join-Path $env:TEMP ("falantes-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

$inv = [System.Globalization.CultureInfo]::InvariantCulture

try {
    $dur = [double]::Parse((& $FFPROBE -v error -show_entries format=duration -of csv=p=0 "$Video"), $inv)

    # largura da tela gravada, para saber o que e miniatura e o que e area compartilhada
    $largTela = 0
    try { $largTela = [int](& $FFPROBE -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$Video") } catch { }
    $largMax = if ($largTela -gt 0) { [int]($largTela * 0.5) } else { 0 }

    # a leitura dos quadros e a parte cara (~3 min para 30 min de video). Guardamos o
    # resultado para reprocessar de graca se so quisermos mexer no cruzamento.
    $md5 = New-Object System.Security.Cryptography.MD5CryptoServiceProvider
    $hash = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($Video.ToLower()))).Replace("-", "").Substring(0, 8)
    $cacheCsv = Join-Path $LogDir ("linha-do-tempo-$hash.csv")

    $linhaDoTempo = @()
    $temCache = (Test-Path $cacheCsv) -and
                ((Get-Item $cacheCsv).LastWriteTime -gt (Get-Item $Video).LastWriteTime)

    if ($temCache) {
        foreach ($l in [System.IO.File]::ReadAllLines($cacheCsv, [Text.Encoding]::UTF8)) {
            if ($l.Trim() -eq "") { continue }
            $c = $l -split ';', 2
            $nm = if ($c.Count -gt 1 -and $c[1] -ne "") { $c[1] -split '\|' } else { @() }
            $linhaDoTempo += [pscustomobject]@{ T = [double]::Parse($c[0], $inv); Nomes = @($nm) }
        }
        Log "falantes: reaproveitando leitura de tela ja feita ($($linhaDoTempo.Count) amostras)"
    }
}
catch { throw }

$semTela = $false
$perfil = $null

try {
  if (-not $temCache) {
    # --- 1. sonda: que plataforma e essa (se e que e alguma)? ---
    $candidatos = if ($Plataforma -eq "auto") { @("teams", "meet") } else { @($Plataforma) }
    $placar = @{}

    $sondas = @()
    for ($i = 1; $i -le 8; $i++) {
        $t = $dur * $i / 9.0
        $img = Join-Path $tmpDir "sonda-$i.jpg"
        & $FFMPEG -hide_banner -loglevel error -y -ss $t -i "$Video" -frames:v 1 -q:v 4 "$img" 2>$null
        if (Test-Path $img) { $sondas += $img }
    }
    foreach ($nome in $candidatos) {
        $p = $PERFIS[$nome]
        if (-not $p) { throw "plataforma desconhecida: $nome" }
        $acertos = 0
        foreach ($img in $sondas) {
            if ((Get-Caixas $img $p $Corrida $TolX $largMax).Count -gt 0) { $acertos++ }
        }
        $placar[$nome] = $acertos
    }
    foreach ($img in $sondas) { Remove-Item $img -Force -ErrorAction SilentlyContinue }

    $melhor = $placar.Keys | Sort-Object { -$placar[$_] } | Select-Object -First 1
    if ($placar[$melhor] -lt 2) {
        # nenhuma plataforma reconhecida: ainda vale seguir SE houver faixa separada
        # de microfone, que ao menos marca a fala de quem gravou
        if ((Get-QtdFaixasAudio $Video) -lt 2) {
            Log "falantes: nenhum realce reconhecido e sem faixa de microfone - nada a fazer"
            exit 0
        }
        Log "falantes: nenhum realce reconhecido, mas ha faixa de microfone - sigo so com ela"
        $semTela = $true
    } else {
        $perfil = $PERFIS[$melhor]
        $detalhe = ($placar.Keys | ForEach-Object { "$_=$($placar[$_])/8" }) -join " "
        Log "falantes: plataforma $($perfil.Nome) ($detalhe), analisando quem fala..."
    }
  }

  if (-not $temCache -and -not $semTela) {

    # --- 2. extrai os quadros ---
    #
    # SO OS KEYFRAMES (-skip_frame nokey). Antes pediamos "fps=0.5", que obriga o
    # ffmpeg a decodificar o video INTEIRO para jogar 59 de cada 60 quadros fora -
    # numa gravacao de 3440x1440 a 60 fps isso custava 721s. Decodificando so os
    # quadros-chave o mesmo trabalho leva ~70s (medido: 12x), e a amostragem sai
    # a cada ~4s, que e o intervalo de keyframe que o OBS grava.
    #
    # O "showinfo" imprime o instante de cada quadro na MESMA passada, entao nao
    # precisamos de uma segunda leitura do arquivo so para saber os tempos
    # (a alternativa, ffprobe, custava 49s sozinha).
    $t0 = Get-Date
    $esperados = [math]::Max(1, [int]($dur / 4.0))
    $errQuadros = Join-Path $tmpDir "erro-quadros.txt"
    $ffArgs = '-hide_banner -loglevel info -y -threads {2} -skip_frame nokey -i "{0}" -fps_mode passthrough -vf showinfo -q:v 4 "{1}"' -f `
              $Video, (Join-Path $tmpDir "q-%06d.jpg"), $Threads
    $proc = Start-Process -FilePath $FFMPEG -ArgumentList $ffArgs -NoNewWindow -PassThru `
                          -RedirectStandardError $errQuadros
    $null = Set-AfinidadeNucleos -Processo $proc -Nucleos $Threads
    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 900
        $feitos = @(Get-ChildItem (Join-Path $tmpDir "q-*.jpg") -ErrorAction SilentlyContinue).Count
        # leitura dos quadros ocupa a faixa de 72% a 90% da barra
        Set-Progresso (72 + [int](18.0 * [math]::Min(1.0, $feitos / $esperados))) `
                      "lendo a tela" "$feitos de ~$esperados quadros"
    }
    $quadros = @(Get-ChildItem (Join-Path $tmpDir "q-*.jpg") -ErrorAction SilentlyContinue | Sort-Object Name)

    # instante de cada quadro, na ordem em que foram gravados
    $marcas = @([regex]::Matches((Get-Content $errQuadros -Raw -ErrorAction SilentlyContinue), 'pts_time:([\d\.]+)') |
                ForEach-Object { [double]::Parse($_.Groups[1].Value, $inv) })
    Log ("falantes: {0} quadros extraidos em {1}s ({2} marcas de tempo)" -f `
         $quadros.Count, [math]::Round(((Get-Date) - $t0).TotalSeconds, 0), $marcas.Count)

    # se as marcas nao baterem com os arquivos, e mais seguro espacar por igual
    # do que carimbar tempo errado em cada leitura
    if ($marcas.Count -ne $quadros.Count) {
        Log "falantes: AVISO - $($marcas.Count) marcas para $($quadros.Count) quadros; usando espacamento uniforme"
        $passo = if ($quadros.Count -gt 1) { $dur / $quadros.Count } else { $Intervalo }
        $marcas = @(0..([math]::Max(0, $quadros.Count - 1)) | ForEach-Object { $_ * $passo })
    }

    # sem quadro nao da para ler nome nenhum na tela. Nao e motivo para desistir:
    # a faixa do microfone ainda marca a propria fala, e o resto vira "Voz NN".
    if ($quadros.Count -eq 0) {
        $motivo = ((Get-Content $errQuadros -Raw -ErrorAction SilentlyContinue) -replace '\s+', ' ').Trim()
        Log "falantes: ERRO - ffmpeg nao extraiu quadro nenhum. ffmpeg disse: $motivo"
        $semTela = $true
    }

    # --- 3. detecta realce + le o nome ---
    $t0 = Get-Date
    $linhaDoTempo = @()      # { T, Nomes[] }
    $cache = @{}             # geometria da miniatura -> { Nome, Visto }
    $ocrs = 0

    $feitos = 0
    foreach ($q in $quadros) {
        # o instante vem do showinfo (keyframe nao cai em grade regular)
        $n = [int]($q.BaseName -replace '\D', '')
        $t = if (($n - 1) -lt $marcas.Count) { $marcas[$n - 1] } else { 0.0 }
        $nomes = @()
        $feitos++
        if ($feitos % 25 -eq 0) {
            Set-Progresso (90 + [int](8.0 * $feitos / [math]::Max(1, $quadros.Count))) `
                          "identificando quem falou" "$feitos de $($quadros.Count)"
        }

        foreach ($caixa in (Get-Caixas $q.FullName $perfil $Corrida $TolX $largMax)) {
            # chave fina: duas miniaturas diferentes nunca caem na mesma
            $chave = "{0}_{1}_{2}_{3}" -f [int]($caixa[0] / 8), [int]($caixa[1] / 8), [int]($caixa[2] / 8), [int]($caixa[3] / 8)
            $reg = $cache[$chave]
            if ($null -eq $reg) {
                $reg = [pscustomobject]@{ Nome = ""; Nota = 0.0; Visto = -9999.0; Leituras = 0; Votos = @{} }
                $cache[$chave] = $reg
            }
            # Le a MESMA miniatura varias vezes e fica com a melhor leitura. Antes
            # era uma leitura so a cada 300s: se ela saisse corrompida, a pessoa
            # virava "QBiSmarêk.MtI Araujo" pelos 5 minutos seguintes - foi assim
            # que uma reuniao de ~8 pessoas virou "23 pessoas identificadas".
            # As 6 primeiras leituras vem rapido; depois so de 5 em 5 min, porque
            # gente entra e sai e o mosaico se reorganiza.
            $espera = if ($reg.Leituras -lt 6) { 20 } else { 300 }
            if (($t - $reg.Visto) -gt $espera) {
                $bruto = Get-NomeDaCaixa $q.FullName $caixa $tmpDir $perfil
                $ocrs++
                $reg.Visto = $t
                $reg.Leituras++
                # 0,7 e o corte: nome de gente, mesmo com o OCR comendo letra,
                # ficou em 0,85 ou mais nas medicoes; texto de documento
                # compartilhado ("Party ref TMF Party BusinessPartner") deu 0,64
                $nota = Get-QualidadeNome $bruto
                if ($nota -ge 0.7) {
                    $reg.Votos[$bruto] = 1 + $reg.Votos[$bruto]
                    # melhor nota ganha; empate desempata por quem apareceu mais vezes
                    if ($nota -gt $reg.Nota -or
                        ($nota -eq $reg.Nota -and $reg.Votos[$bruto] -gt $reg.Votos[$reg.Nome])) {
                        $reg.Nome = $bruto
                        $reg.Nota = $nota
                    }
                }
            }
            if ($reg.Nome -ne "") { $nomes += $reg.Nome }
        }
        $linhaDoTempo += [pscustomobject]@{ T = $t; Nomes = @($nomes | Select-Object -Unique) }
    }
    Log ("falantes: analise em {0}s ({1} leituras de nome)" -f [math]::Round(((Get-Date) - $t0).TotalSeconds, 0), $ocrs)

    # guarda a leitura de tela: reprocessar depois sai de graca.
    # So grava se houver o que gravar: sem isso, leitura vazia virava cache vazio
    # "valido" (envenenando as proximas rodadas) e o WriteAllLines estourava com
    # "Valor nao pode ser nulo" - erro que escondia a causa de verdade.
    if ($linhaDoTempo.Count -gt 0) {
        $csv = @(foreach ($p in $linhaDoTempo) { "{0};{1}" -f $p.T.ToString($inv), ($p.Nomes -join "|") })
        [System.IO.File]::WriteAllLines($cacheCsv, [string[]]$csv, (New-Object System.Text.UTF8Encoding($false)))
    }
  }

    # --- 4. normaliza nomes parecidos (OCR erra uma letra aqui e ali) ---
    $contagem = @{}
    foreach ($p in $linhaDoTempo) { foreach ($nm in $p.Nomes) { $contagem[$nm] = 1 + $contagem[$nm] } }
    # o nome mais visto vira o oficial; leituras a <=2 letras de distancia colam nele
    # agrupa as variantes da mesma pessoa.
    # NADA de "$grupos | Where-Object": pipeline desmonta array de array e a
    # comparacao acaba sendo feita letra por letra.
    $grupos = New-Object System.Collections.ArrayList
    foreach ($nm in ($contagem.Keys | Sort-Object { -$contagem[$_] })) {
        $achou = $false
        for ($i = 0; $i -lt $grupos.Count; $i++) {
            if (Test-MesmaPessoa $grupos[$i][0] $nm) {
                $null = $grupos[$i].Add($nm)
                $achou = $true
                break
            }
        }
        if (-not $achou) {
            $novo = New-Object System.Collections.ArrayList
            $null = $novo.Add($nm)
            $null = $grupos.Add($novo)
        }
    }

    # o nome oficial do grupo NAO e o mais frequente, e o mais limpo: "Paulo Da
    # Costa Ribeiro 'h" aparecia mais vezes que "Paulo Da Costa Ribeiro"
    $mapaNome = @{}
    for ($i = 0; $i -lt $grupos.Count; $i++) {
        $variantes = @($grupos[$i])
        $oficial = $variantes |
            Sort-Object @{ Expression = { if ($_ -match "^[\p{L}\p{M}\s\.\-]+$") { 0 } else { 1 } } },
                        @{ Expression = { -$_.Length } },
                        @{ Expression = { -$contagem[$_] } } |
            Select-Object -First 1
        foreach ($nm in $variantes) { $mapaNome[$nm] = $oficial }
    }
    $canonicos = @($mapaNome.Values | Select-Object -Unique)
    foreach ($p in $linhaDoTempo) {
        $p.Nomes = @($p.Nomes | ForEach-Object { $mapaNome[$_] } | Select-Object -Unique)
    }

    # --- 5. cruza com os tempos da transcricao ---
    # As amostras NAO estao mais numa grade fixa (sao os keyframes), entao a busca
    # e binaria sobre os tempos ordenados - varrer as ~1500 amostras para cada um
    # dos ~4900 trechos de fala seria lento a toa.
    $linhaDoTempo = @($linhaDoTempo | Sort-Object T)
    $tempos = New-Object double[] $linhaDoTempo.Count
    for ($i = 0; $i -lt $linhaDoTempo.Count; $i++) { $tempos[$i] = $linhaDoTempo[$i].T }

    # duas passadas: primeiro colado no trecho; depois, para o que sobrou, uma janela
    # maior - o realce acende/apaga com um pouco de atraso em relacao a voz, e entre
    # dois keyframes ha ~4s
    foreach ($janela in @(1.5, 5.0)) {
        foreach ($seg in $segmentos) {
            if ($seg.Nome) { continue }
            $votos = @{}
            $k = [array]::BinarySearch($tempos, ($seg.Ini - $janela))
            if ($k -lt 0) { $k = -$k - 1 }
            while ($k -lt $tempos.Count -and $tempos[$k] -le ($seg.Fim + $janela)) {
                foreach ($nm in $linhaDoTempo[$k].Nomes) { $votos[$nm] = 1 + $votos[$nm] }
                $k++
            }
            if ($votos.Count -gt 0) {
                $seg.Nome = ($votos.Keys | Sort-Object { -$votos[$_] } | Select-Object -First 1)
            }
        }
    }

    # --- 5b. o que a tela nao identificou: a faixa do microfone resolve ---
    # (a tela vem primeiro de proposito: ela diz QUEM e; o mic so diz "foi daqui")
    $porMic = 0
    $qtdFaixas = Get-QtdFaixasAudio $Video
    if ($qtdFaixas -ge 2) {
        if ($NomeLocal -eq "") {
            # tenta casar o usuario do Windows com um nome lido na tela
            $eu = $env:USERNAME
            $achou = $canonicos | Where-Object { $_ -match ("^" + [regex]::Escape($eu) + "\b") } | Select-Object -First 1
            # "Voce (microfone)" com acento, sem depender do encoding deste arquivo
            $NomeLocal = if ($achou) { $achou } else { "Voc" + [char]0x00EA + " (microfone)" }
        }

        $intervalos = @(Get-IntervalosMic $Video $MicLimiarDb $dur $tmpDir)
        # cinto e suspensorio: se ainda assim vier embrulhado, desembrulha
        if ($intervalos.Count -eq 1 -and $intervalos[0] -is [array]) { $intervalos = @($intervalos[0]) }
        $intervalos = @($intervalos | Where-Object { $null -ne $_.Ini })
        $tempoMic = 0.0
        foreach ($iv in $intervalos) { $tempoMic += ($iv.Fim - $iv.Ini) }
        Log ("falantes: faixa de microfone presente, {0} trecho(s) com voz ({1} min)" -f `
             $intervalos.Count, [math]::Round($tempoMic / 60, 1))

        foreach ($seg in $segmentos) {
            if ($seg.Nome) { continue }
            if ((Get-SobreposicaoMic $intervalos $seg.Ini $seg.Fim) -ge 0.5) {
                $seg.Nome = $NomeLocal
                $porMic++
            }
        }
        if ($porMic -gt 0) { Log "falantes: $porMic fala(s) atribuida(s) a '$NomeLocal' pela faixa do microfone" }
    }

    # --- 5c. chamada 1:1: o que nao e o seu microfone e a outra pessoa ---
    # Com a tela compartilhada o Teams esconde as miniaturas: sem borda, sem nome
    # (medido: chamada de 1h37 com 91,7% das falas sem nome). Mas numa chamada
    # 1:1 o titulo da janela e o nome da outra pessoa, e a faixa do microfone ja
    # separou a sua voz - o que sobra so pode ser dela.
    # So vale COM faixa de microfone (sem ela a sua fala iria para a outra
    # pessoa) e quando a tela nao viu mais ninguem alem dela.
    $por1a1 = 0
    $faltam = @($segmentos | Where-Object { -not $_.Nome }).Count
    if ($qtdFaixas -ge 2 -and $faltam -gt 0) {
        $outros = @($canonicos | Where-Object { -not (Test-EhVoce $_) })
        if ($outros.Count -gt 1) {
            # reuniao com varias pessoas na tela: nao e 1:1
        } else {
            $chamada = Get-NomeDaChamada $Video $dur $tmpDir
            if ($null -eq $chamada) {
                Log "falantes: titulo da janela nao traz nome de uma pessoa so - nao trato como chamada 1:1"
            } elseif (Test-EhVoce $chamada.Nome) {
                Log "falantes: titulo da janela traz o seu proprio nome ('$($chamada.Nome)') - ignorado"
            } elseif ($outros.Count -eq 1 -and -not (Test-MesmaPessoa $outros[0] $chamada.Nome)) {
                Log "falantes: titulo diz '$($chamada.Nome)' mas a tela mostrou '$($outros[0])' - nao arrisco"
            } else {
                # se a tela ja leu a pessoa, fica a grafia da tela (uma pessoa, um nome)
                $nomeOutro = if ($outros.Count -eq 1) { $outros[0] } else { $chamada.Nome }
                foreach ($seg in $segmentos) {
                    if (-not $seg.Nome) { $seg.Nome = $nomeOutro; $por1a1++ }
                }
                Log ("falantes: chamada 1:1 com '{0}' (nome no titulo em {1} de {2} quadros) - {3} fala(s) atribuida(s)" -f `
                     $nomeOutro, $chamada.Votos, $chamada.Lidos, $por1a1)
            }
        }
    }

    # --- 6. quem sobrou sem nome: herda do vizinho ou fica "Nao identificado" ---
    # UM rotulo so. Antes cada trecho ganhava numero proprio ("Voz 275") e o tempo
    # de fala virava uma lista de centenas de "pessoas" que eram so trechos.
    for ($i = 0; $i -lt $segmentos.Count; $i++) {
        if ($segmentos[$i].Nome) { continue }

        # vizinho de verdade: "Nao identificado" ja atribuido nesta volta nao conta
        $ant = $null; $dep = $null
        for ($j = $i - 1; $j -ge 0; $j--) {
            if ($segmentos[$j].Nome -and $segmentos[$j].Nome -ne $SEM_NOME) { $ant = $segmentos[$j]; break }
        }
        for ($j = $i + 1; $j -lt $segmentos.Count; $j++) { if ($segmentos[$j].Nome) { $dep = $segmentos[$j]; break } }

        # cercado pela mesma pessoa dos dois lados e perto no tempo: era ela falando
        if ($ant -and $dep -and $ant.Nome -eq $dep.Nome -and
            ($segmentos[$i].Ini - $ant.Fim) -lt 15 -and ($dep.Ini - $segmentos[$i].Fim) -lt 15) {
            $segmentos[$i].Nome = $ant.Nome
            continue
        }
        $segmentos[$i].Nome = $SEM_NOME
    }

    # --- 7. junta falas seguidas da mesma pessoa e escreve o arquivo ---
    $blocos = @()
    foreach ($seg in $segmentos) {
        $ultimo = if ($blocos.Count -gt 0) { $blocos[$blocos.Count - 1] } else { $null }
        if ($ultimo -and $ultimo.Nome -eq $seg.Nome -and ($seg.Ini - $ultimo.Fim) -lt 20) {
            $ultimo.Texto = ($ultimo.Texto + " " + $seg.Texto).Trim()
            $ultimo.Fim = $seg.Fim
        } else {
            $blocos += [pscustomobject]@{ Nome = $seg.Nome; Ini = $seg.Ini; Fim = $seg.Fim; Texto = $seg.Texto }
        }
    }

    $tempoPorPessoa = @{}
    foreach ($b in $blocos) { $tempoPorPessoa[$b.Nome] = $tempoPorPessoa[$b.Nome] + ($b.Fim - $b.Ini) }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("Reuniao: " + [System.IO.Path]::GetFileNameWithoutExtension($Video))
    [void]$sb.AppendLine("Duracao: " + (Format-Tempo $dur))
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Tempo de fala:")
    # quem falou mais primeiro; "Nao identificado" sempre por ultimo
    $ordem = $tempoPorPessoa.Keys | Sort-Object @{ Expression = { if ($_ -eq $SEM_NOME) { 1 } else { 0 } } },
                                                @{ Expression = { -$tempoPorPessoa[$_] } }
    foreach ($nm in $ordem) {
        [void]$sb.AppendLine(("  {0,-40} {1}" -f $nm, (Format-Tempo $tempoPorPessoa[$nm])))
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine(("-" * 70))
    [void]$sb.AppendLine("")
    foreach ($b in $blocos) {
        [void]$sb.AppendLine("[" + (Format-Tempo $b.Ini) + "]  " + $b.Nome)
        [void]$sb.AppendLine($b.Texto)
        [void]$sb.AppendLine("")
    }

    $saida = Join-Path (Split-Path -Parent $Video) ([System.IO.Path]::GetFileNameWithoutExtension($Video) + " - falas.txt")
    [System.IO.File]::WriteAllText($saida, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))

    # --- 8. legenda com o nome de quem fala ---
    # Mesma marcacao de tempo do .srt do whisper, so que cada fala vem com o nome.
    # Ela VIRA o "<video>.srt": o player (o MPC-HC daqui, VLC...) carrega sozinho a
    # legenda com o mesmo nome do video e da prioridade a ela sobre a faixa
    # embutida. Enquanto esse arquivo era o do whisper, abria o video e aparecia a
    # legenda SEM nome. A do whisper fica guardada como "- sem nomes.srt".
    $curtos = Get-NomesCurtos ($segmentos | ForEach-Object { $_.Nome })
    $leg = New-Object System.Text.StringBuilder
    $i = 0
    foreach ($seg in $segmentos) {
        $i++
        $nome = if ($curtos.ContainsKey($seg.Nome)) { $curtos[$seg.Nome] } else { $seg.Nome }
        [void]$leg.AppendLine($i)
        [void]$leg.AppendLine((Format-Srt $seg.Ini) + " --> " + (Format-Srt $seg.Fim))
        # sem nome, sai so a fala: "Nao identificado:" em cada linha so polui a tela
        if ($seg.Nome -eq $SEM_NOME) { [void]$leg.AppendLine($seg.Texto) }
        else                         { [void]$leg.AppendLine($nome + ": " + $seg.Texto) }
        [void]$leg.AppendLine("")
    }
    $baseSaida = Join-Path (Split-Path -Parent $Video) ([System.IO.Path]::GetFileNameWithoutExtension($Video))
    $srtSemNomes = "$baseSaida - sem nomes.srt"
    if ([System.IO.Path]::GetFullPath($Srt) -ne [System.IO.Path]::GetFullPath($srtSemNomes)) {
        Copy-Item -LiteralPath $Srt -Destination $srtSemNomes -Force
    }
    $saidaSrt = "$baseSaida.srt"
    # legenda vai SEM BOM: player antigo engasga com BOM na primeira linha
    [System.IO.File]::WriteAllText($saidaSrt, $leg.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    # formato antigo: a legenda com nome morava em "- falas.srt"
    Remove-Item -LiteralPath "$baseSaida - falas.srt" -Force -ErrorAction SilentlyContinue
    $identificados = @($tempoPorPessoa.Keys | Where-Object { $_ -ne $SEM_NOME })
    $semNome = [math]::Round((@($segmentos | Where-Object { $_.Nome -eq $SEM_NOME }).Count / $segmentos.Count) * 100, 1)
    Log ("falantes: OK -> {0} ({1} blocos, {2} pessoas identificadas, {3}% das falas sem nome)" -f `
         $saida, $blocos.Count, $identificados.Count, $semNome)
}
finally {
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
