# A local stand-in for agent_api.php and the /status/ file download, for the
# agent.ps1 tests only. It runs inside the test container on 127.0.0.1.
#
#   POST (a report)        -> answers with $Dir/response.txt: first line the HTTP
#                             status, the rest the body. Re-read on every request,
#                             so a test changes the answer between agent runs.
#   POST (action_result)   -> 200 "{}"; the agent ignores the answer.
#   GET /files/<name>      -> the bytes of $Dir/files/<name>, or 404.
#
# Every POST body is appended to $Dir/requests.log (one compact JSON per line)
# and every GET to $Dir/downloads.log, so a test can see what the agent sent
# and whether it downloaded anything at all.
param(
    [int]$Port = 18080,
    [string]$Dir = "/work/mock"
)

$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path (Join-Path $Dir "files") | Out-Null
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Set-Content -Path (Join-Path $Dir "ready") -Value "1"

function Send-Bytes($ctx, [int]$code, [byte[]]$bytes, [string]$type) {
    $ctx.Response.StatusCode = $code
    $ctx.Response.ContentType = $type
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    try {
        $req = $ctx.Request
        if ($req.HttpMethod -eq "POST") {
            $reader = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8)
            $body = $reader.ReadToEnd()
            $line = $body
            try { $line = $body | ConvertFrom-Json | ConvertTo-Json -Compress -Depth 20 } catch {}
            Add-Content -Path (Join-Path $Dir "requests.log") -Value $line
            if ($body -match '"action_result"') {
                Send-Bytes $ctx 200 ([System.Text.Encoding]::UTF8.GetBytes("{}")) "application/json"
            } else {
                $answer = Get-Content -Raw -Path (Join-Path $Dir "response.txt")
                $nl = $answer.IndexOf("`n")
                $code = [int]$answer.Substring(0, $nl).Trim()
                $json = $answer.Substring($nl + 1)
                Send-Bytes $ctx $code ([System.Text.Encoding]::UTF8.GetBytes($json)) "application/json"
            }
        } elseif ($req.HttpMethod -eq "GET" -and $req.Url.AbsolutePath -like "/files/*") {
            $name = [System.IO.Path]::GetFileName($req.Url.AbsolutePath)
            Add-Content -Path (Join-Path $Dir "downloads.log") -Value $name
            $path = Join-Path (Join-Path $Dir "files") $name
            if (Test-Path -LiteralPath $path) {
                Send-Bytes $ctx 200 ([System.IO.File]::ReadAllBytes($path)) "application/octet-stream"
            } else {
                Send-Bytes $ctx 404 ([byte[]]@()) "text/plain"
            }
        } else {
            Send-Bytes $ctx 404 ([byte[]]@()) "text/plain"
        }
    } catch {
        # A broken test request must not take the mock down for every later test.
        try { Send-Bytes $ctx 500 ([System.Text.Encoding]::UTF8.GetBytes("mock error: $_")) "text/plain" } catch {}
    } finally {
        try { $ctx.Response.Close() } catch {}
    }
}
