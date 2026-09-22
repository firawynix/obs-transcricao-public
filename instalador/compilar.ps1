<#
    compilar.ps1 - gera o Instalar-Transcricao-OBS.exe

    Empacota os scripts atuais (em Base64, para nao sofrer com aspas/acentos) e
    compila com o compilador C# que ja vem no Windows. Rode depois de mexer em
    qualquer .ps1/.lua para o instalador levar a versao nova.
#>
$ErrorActionPreference = "Stop"

$aqui = Split-Path -Parent $MyInvocation.MyCommand.Path
$raiz = Split-Path -Parent $aqui
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$icone = Join-Path $raiz "assets\transcricao-logo.ico"

# A interface grafica vai junto no instalador e tambem fica pronta na raiz do
# projeto para teste/uso local. Ela usa o mesmo tema do site.
$helperExe = Join-Path $raiz "FirawAutoUpdate.exe"
$argsHelper = @(
    "/nologo", "/target:winexe", "/platform:anycpu", "/optimize+", "/out:$helperExe",
    (Join-Path $aqui "FirawAutoUpdate.cs")
)
& $csc $argsHelper
if ($LASTEXITCODE -ne 0) { throw "compilacao do auxiliar de atualizacao falhou" }
"  atualizador: FirawAutoUpdate.exe"

$appExe = Join-Path $raiz "Transcrever-Video.exe"
$argsApp = @(
    "/nologo", "/target:winexe", "/optimize+", "/out:$appExe",
    "/r:System.Windows.Forms.dll", "/r:System.Drawing.dll", "/r:System.Web.Extensions.dll", "/win32icon:$icone",
    (Join-Path $aqui "AppTranscrever.cs"),
    (Join-Path $aqui "AutoUpdate.cs")
)
& $csc $argsApp
if ($LASTEXITCODE -ne 0) { throw "compilacao da interface falhou" }
"  interface: Transcrever-Video.exe"

$embutir = @(
    "Transcrever-Video.exe",
    "FirawAutoUpdate.exe",
    "transcrever.ps1",
    "falantes.ps1",
    "lib-ocr.ps1",
    "lib-quadro.ps1",
    "lib-ffmpeg.ps1",
    "lib-cpu.ps1",
    "lib-progresso.ps1",
    "lib-legenda.ps1",
    "lib-srt.ps1",
    "transcrever-console.ps1",
    "alternar-legenda.ps1",
    "obs-transcrever.lua"
)

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("// gerado por compilar.ps1 - nao editar a mao")
[void]$sb.AppendLine("using System.Collections.Generic;")
[void]$sb.AppendLine("public static partial class Instalador {")
[void]$sb.AppendLine("    static Dictionary<string,string> Arquivos() {")
[void]$sb.AppendLine("        Dictionary<string,string> d = new Dictionary<string,string>();")

foreach ($nome in $embutir) {
    $caminho = Join-Path $raiz $nome
    if (-not (Test-Path $caminho)) { throw "faltou o arquivo $nome" }
    $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($caminho))
    [void]$sb.AppendLine("        d[""$nome""] = ""$b64"";")
    "  embutido: {0,-22} {1,7:N0} bytes" -f $nome, (Get-Item $caminho).Length
}

[void]$sb.AppendLine("        return d;")
[void]$sb.AppendLine("    }")
[void]$sb.AppendLine("}")
[System.IO.File]::WriteAllText((Join-Path $aqui "Payload.cs"), $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

$exe = Join-Path $aqui "Instalar-Transcricao-OBS.exe"

$refs = @("System.IO.Compression.FileSystem.dll", "System.IO.Compression.dll")
$argsCsc = @("/nologo", "/target:exe", "/optimize+", "/out:$exe", "/win32icon:$icone")
foreach ($r in $refs) { $argsCsc += "/r:$r" }
$argsCsc += (Join-Path $aqui "Instalador.cs")
$argsCsc += (Join-Path $aqui "Payload.cs")

& $csc $argsCsc
if ($LASTEXITCODE -ne 0) { throw "compilacao falhou" }

""
"gerado: $exe  ({0:N0} KB)" -f ((Get-Item $exe).Length / 1KB)


