<# Interface de compatibilidade para iniciar a transcricao manual. #>
[CmdletBinding()]
param(
    [string]$Video = "",
    [switch]$Perguntar,
    [int]$CpuMax = 70,
    [string]$Idioma = "pt",
    [switch]$SemLegenda
)

$ErrorActionPreference = "Continue"
$Base = Split-Path -Parent $MyInvocation.MyCommand.Path
Add-Type -AssemblyName System.Windows.Forms

if ($Video -eq "" -or -not (Test-Path -LiteralPath $Video)) {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "Escolha o video para transcrever"
    $dlg.Filter = "Videos e audios|*.mp4;*.mkv;*.mov;*.avi;*.webm;*.m4a;*.mp3;*.wav|Todos (*.*)|*.*"
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { exit 0 }
    $Video = $dlg.FileName
}

if ($Perguntar) {
    $resposta = [System.Windows.Forms.MessageBox]::Show(
        "Gravacao encerrada:`n`n$([IO.Path]::GetFileName($Video))`n`nTranscrever agora?",
        "Transcrever video",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($resposta -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }
}

$opcoes = @{ Video = $Video; Forcar = $true; CpuMax = $CpuMax; Idioma = $Idioma }
if ($SemLegenda) { $opcoes.SemLegenda = $true }
& (Join-Path $Base "transcrever.ps1") @opcoes
exit $LASTEXITCODE
