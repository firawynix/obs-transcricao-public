param(
    [string]$Raiz = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)),
    [int]$Porta = 8765
)

$ErrorActionPreference = "Stop"
$raizFinal = [System.IO.Path]::GetFullPath($Raiz).TrimEnd('\')
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Porta/")
$listener.Start()

$tipos = @{
    '.html'='text/html; charset=utf-8'; '.css'='text/css; charset=utf-8';
    '.js'='application/javascript; charset=utf-8'; '.png'='image/png';
    '.ico'='image/x-icon'; '.svg'='image/svg+xml'; '.exe'='application/octet-stream'
}

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        try {
            $rel = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath).TrimStart('/')
            if ($rel -eq '') {
                $ctx.Response.StatusCode = 302
                $ctx.Response.RedirectLocation = '/site/'
                $ctx.Response.OutputStream.Close()
                continue
            }
            if ($rel.EndsWith('/')) { $rel += 'index.html' }
            $arquivo = [System.IO.Path]::GetFullPath((Join-Path $raizFinal $rel.Replace('/', '\')))
            if (-not $arquivo.StartsWith($raizFinal, [System.StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-Path -LiteralPath $arquivo -PathType Leaf)) {
                $ctx.Response.StatusCode = 404
                $bytes = [Text.Encoding]::UTF8.GetBytes('Arquivo não encontrado')
            } else {
                $ext = [System.IO.Path]::GetExtension($arquivo).ToLowerInvariant()
                $ctx.Response.ContentType = if ($tipos.ContainsKey($ext)) { $tipos[$ext] } else { 'application/octet-stream' }
                if ($ext -eq '.exe') { $ctx.Response.AddHeader('Content-Disposition', 'attachment; filename="' + [IO.Path]::GetFileName($arquivo) + '"') }
                $bytes = [System.IO.File]::ReadAllBytes($arquivo)
            }
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        } catch {
            $ctx.Response.StatusCode = 500
        } finally {
            $ctx.Response.OutputStream.Close()
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
