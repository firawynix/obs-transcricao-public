<#
    lib-legenda.ps1 - poe a legenda DENTRO do proprio video, como faixa.

    Sem recodificar (-c copy): leva segundos e nao mexe em um pixel da imagem.
    Medido: 1,5s num video de 14,7 min / 652 MB.

    NAO existe versao "ao vivo" disso, por dois motivos: o nome de quem fala so
    aparece depois de ler a tela e cruzar com a transcricao, e faixa nova nao
    entra em arquivo que o OBS ainda esta gravando.
#>

function Add-LegendaNoVideo {
    param(
        [Parameter(Mandatory = $true)][string]$Video,
        [Parameter(Mandatory = $true)][string]$Srt,
        [Parameter(Mandatory = $true)][string]$Ffmpeg,
        [string]$Ffprobe = "",
        [string]$PastaLog = $env:TEMP
    )

    if (-not (Test-Path $Srt)) { return "nao havia legenda para embutir" }
    if ((Get-Item $Srt).Length -lt 10) { return "legenda vazia, nada a embutir" }

    # mp4/mov carregam legenda como mov_text; mkv carrega srt de verdade
    $ext = [System.IO.Path]::GetExtension($Video).ToLower()
    $codec = switch ($ext) {
        ".mp4" { "mov_text" }
        ".mov" { "mov_text" }
        ".mkv" { "srt" }
        default { "" }
    }
    if ($codec -eq "") { return "formato $ext nao aceita faixa de legenda" }

    $pasta = Split-Path -Parent $Video
    $base  = [System.IO.Path]::GetFileNameWithoutExtension($Video)
    $tmp   = Join-Path $pasta ($base + ".legendando" + $ext)
    $err   = Join-Path $PastaLog "ultimo-erro-legenda.txt"

    # "-map 0:v -map 0:a" e NAO "-map 0": assim uma faixa de legenda que ja
    # exista fica de fora, e rodar de novo troca a legenda em vez de empilhar.
    $a = ('-hide_banner -loglevel error -y -i "{0}" -i "{1}" -map 0:v -map 0:a -map 1:0 ' +
          '-c copy -c:s {2} -metadata:s:s:0 language=por -metadata:s:s:0 "title=Quem falou" ' +
          '-disposition:s:0 default "{3}"') -f $Video, $Srt, $codec, $tmp

    $p = Start-Process -FilePath $Ffmpeg -ArgumentList $a -NoNewWindow -Wait -PassThru -RedirectStandardError $err
    if ($p.ExitCode -ne 0 -or -not (Test-Path $tmp)) {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        $motivo = ((Get-Content $err -Raw -ErrorAction SilentlyContinue) -replace '\s+', ' ').Trim()
        return "falhou, video intacto ($motivo)"
    }

    # CONFERE ANTES DE TROCAR. O original e a gravacao do usuario: nenhuma
    # legenda vale perder isso. Exige faixa de legenda presente e tamanho
    # parecido; qualquer duvida, o arquivo novo vai embora e o original fica.
    $ok = $true
    if ((Get-Item $tmp).Length -lt ((Get-Item $Video).Length * 0.95)) { $ok = $false }
    if ($ok -and $Ffprobe -ne "" -and (Test-Path $Ffprobe)) {
        $tipos = & $Ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$tmp" 2>$null
        if (@($tipos) -notcontains "subtitle") { $ok = $false }
    }
    if (-not $ok) {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        return "arquivo novo nao passou na conferencia - video original mantido"
    }

    try {
        Move-Item $tmp $Video -Force
        return "embutida no proprio video"
    } catch {
        # nao deu para trocar (OneDrive segurando o arquivo, por exemplo):
        # em vez de perder o trabalho, deixa a versao legendada ao lado
        $aoLado = Join-Path $pasta ($base + " (com legenda)" + $ext)
        try { Move-Item $tmp $aoLado -Force; return "video original em uso - salvei como '$([System.IO.Path]::GetFileName($aoLado))'" }
        catch { Remove-Item $tmp -Force -ErrorAction SilentlyContinue; return "nao consegui gravar: $_" }
    }
}
