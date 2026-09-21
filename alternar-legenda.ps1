<#
    alternar-legenda.ps1 - liga/desliga a legenda no player, para todos os videos.

    A legenda ja vem ligada: fica ao lado do video com o mesmo nome ("<video>.srt")
    e dentro dele como faixa padrao. Este botao (atalho "Legenda liga-desliga" na
    area de trabalho) muda a opcao do proprio player, entao vale para qualquer
    video e nao reescreve arquivo nenhum.

    Hoje cobre o MPC-HC (o player que abre .mp4 nesta maquina, via K-Lite): a
    opcao e "EnableSubtitles" em HKCU\Software\MPC-HC\MPC-HC\Settings.

    -SemJanela: so escreve no console (para testar sem caixa de dialogo).
#>
param([switch]$SemJanela)

$ErrorActionPreference = "Stop"

function Avisar([string]$texto, [string]$icone = "Information") {
    if ($SemJanela) { $texto; return }
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show($texto, "Legenda do video",
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::$icone)
}

$chave = "HKCU:\Software\MPC-HC\MPC-HC\Settings"
if (-not (Test-Path $chave)) {
    Avisar ("Nao achei a configuracao do MPC-HC neste computador.`n`n" +
            "Em outro player, a legenda liga e desliga pelo proprio menu dele " +
            "(no VLC, tecla V).") "Warning"
    exit 1
}

# o MPC-HC grava TODAS as opcoes ao fechar: mexer com ele aberto e perder a troca
if (Get-Process -Name "mpc-hc64", "mpc-hc" -ErrorAction SilentlyContinue) {
    Avisar ("Feche o player antes de usar este botao: ele grava as opcoes ao fechar " +
            "e desfaria a troca.`n`nCom o video aberto, a legenda tambem liga e desliga " +
            "pelo botao direito do mouse > Legendas.") "Warning"
    exit 2
}

$atual = (Get-ItemProperty $chave -Name "EnableSubtitles" -ErrorAction SilentlyContinue).EnableSubtitles
$novo = if ($atual -eq 0) { 1 } else { 0 }
Set-ItemProperty -Path $chave -Name "EnableSubtitles" -Value $novo -Type DWord

# legenda do lado do video tem prioridade: e ela que tem o nome de quem fala
if ($novo -eq 1) {
    Set-ItemProperty -Path $chave -Name "AutoloadSubtitles" -Value 1 -Type DWord
    Set-ItemProperty -Path $chave -Name "PrioritizeExternalSubtitles" -Value 1 -Type DWord
}

$estado = if ($novo -eq 1) { "LIGADA" } else { "DESLIGADA" }
Avisar ("Legenda $estado.`n`nVale para todos os videos, a partir da proxima vez que abrir o player.")
exit 0
