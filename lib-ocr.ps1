<#
    lib-ocr.ps1 - OCR usando o motor nativo do Windows (Windows.Media.Ocr).
    Sem instalar nada: ja vem no Windows 10/11 e roda offline.

    Uso:  . lib-ocr.ps1 ;  Get-TextoOcr -Caminho "C:\imagem.png"
#>

Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null

$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Storage.StorageFile, Windows.Foundation, ContentType = WindowsRuntime]

$script:AsTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object {
        $_.Name -eq 'AsTask' -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]

function Wait-Winrt($operacao, $tipo) {
    $tarefa = $script:AsTask.MakeGenericMethod($tipo).Invoke($null, @($operacao))
    $null = $tarefa.Wait(-1)
    $tarefa.Result
}

$script:MotorOcr = $null

function Get-MotorOcr {
    if ($null -ne $script:MotorOcr) { return $script:MotorOcr }

    # tenta o idioma do usuario; se nao houver pacote de OCR, cai no ingles
    # (nome de pessoa e alfabeto latino, o idioma quase nao importa)
    $motor = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if ($null -eq $motor) {
        $lang = New-Object Windows.Globalization.Language "en-US"
        $motor = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
    }
    $script:MotorOcr = $motor
    return $motor
}

# Devolve as linhas reconhecidas: texto + retangulo (x, y, largura, altura)
function Get-LinhasOcr {
    param([Parameter(Mandatory = $true)][string]$Caminho)

    $motor = Get-MotorOcr
    if ($null -eq $motor) { throw "nenhum motor de OCR disponivel no Windows" }

    $arquivo = Wait-Winrt ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Caminho)) ([Windows.Storage.StorageFile])
    $stream   = Wait-Winrt ($arquivo.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder  = Wait-Winrt ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $bitmap   = Wait-Winrt ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $resultado = Wait-Winrt ($motor.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])

    $linhas = @()
    foreach ($linha in $resultado.Lines) {
        $x1 = [double]::MaxValue; $y1 = [double]::MaxValue; $x2 = 0.0; $y2 = 0.0
        foreach ($p in $linha.Words) {
            $r = $p.BoundingRect
            if ($r.X -lt $x1) { $x1 = $r.X }
            if ($r.Y -lt $y1) { $y1 = $r.Y }
            if (($r.X + $r.Width)  -gt $x2) { $x2 = $r.X + $r.Width }
            if (($r.Y + $r.Height) -gt $y2) { $y2 = $r.Y + $r.Height }
        }
        $linhas += [pscustomobject]@{
            Texto  = $linha.Text
            X      = [int]$x1
            Y      = [int]$y1
            Larg   = [int]($x2 - $x1)
            Alt    = [int]($y2 - $y1)
        }
    }

    $bitmap.Dispose()
    $stream.Dispose()
    return $linhas
}

function Get-TextoOcr {
    param([Parameter(Mandatory = $true)][string]$Caminho)
    (Get-LinhasOcr -Caminho $Caminho | ForEach-Object { $_.Texto }) -join "`n"
}
