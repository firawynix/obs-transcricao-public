$aqui = Split-Path -Parent $MyInvocation.MyCommand.Path
$raiz = Split-Path -Parent $aqui
$porta = 8765
$online = $false
try { $online = (Test-NetConnection 127.0.0.1 -Port $porta -WarningAction SilentlyContinue).TcpTestSucceeded } catch { }
if (-not $online) {
    $argsServidor = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Raiz "{1}" -Porta {2}' -f `
                    (Join-Path $aqui 'servidor.ps1'), $raiz, $porta
    Start-Process powershell.exe -ArgumentList $argsServidor -WindowStyle Hidden
    Start-Sleep -Milliseconds 700
}
Start-Process "http://127.0.0.1:$porta/"
