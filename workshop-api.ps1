function Get-WorkshopUri([string]$Value) {
  $uri = $null
  if (![uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or $uri.UserInfo) {
    throw 'Invalid Workshop API URL.'
  }
  if ($uri.Scheme -eq 'https' -or ($uri.Scheme -eq 'http' -and $uri.IsLoopback -and $env:RFMM_TEST_ALLOW_HTTP -eq '1')) {
    return $uri
  }
  throw 'The Workshop API requires HTTPS.'
}

function Read-WorkshopJson([IO.Stream]$Stream, [long]$Limit, [Threading.CancellationToken]$Cancellation) {
  $body = [IO.MemoryStream]::new()
  $buffer = [byte[]]::new(65536)
  try {
    while (($count = $Stream.ReadAsync($buffer, 0, $buffer.Length, $Cancellation).GetAwaiter().GetResult()) -gt 0) {
      if ($body.Length + $count -gt $Limit) { throw 'The Workshop response is too large.' }
      $body.Write($buffer, 0, $count)
    }
    $json = [Text.Encoding]::UTF8.GetString($body.ToArray()).TrimStart([char]0xFEFF)
    ConvertFrom-Json $json -ErrorAction Stop
  } finally { $body.Dispose() }
}

function Invoke-WorkshopApi {
  param(
    [Parameter(Mandatory)][string]$Uri, [hashtable]$Headers, [string]$UserAgent,
    [string]$Method = 'GET', [string]$Body, [string]$ContentType = 'application/json',
    [ValidateRange(1, 300)][int]$TimeoutSec = 30
  )
  $target = Get-WorkshopUri $Uri
  Add-Type -AssemblyName System.Net.Http
  $handler = [Net.Http.HttpClientHandler]::new()
  $handler.AllowAutoRedirect = $false
  $handler.AutomaticDecompression = [Net.DecompressionMethods]'GZip,Deflate'
  $client = [Net.Http.HttpClient]::new($handler)
  $timeout = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSec))
  $limit = 8MB
  try {
    for ($redirect = 0; $redirect -le 2; $redirect++) {
      $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method.ToUpperInvariant()), $target)
      $response = $null
      try {
        foreach ($header in $Headers.Keys) { $null = $request.Headers.TryAddWithoutValidation($header, [string]$Headers[$header]) }
        if ($UserAgent) { $null = $request.Headers.TryAddWithoutValidation('User-Agent', $UserAgent) }
        if ($PSBoundParameters.ContainsKey('Body')) {
          $request.Content = [Net.Http.StringContent]::new($Body, [Text.Encoding]::UTF8, $ContentType)
        }
        $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $timeout.Token).GetAwaiter().GetResult()
        $status = [int]$response.StatusCode
        if ($status -in 301,302,303,307,308 -and $response.Headers.Location) {
          if ($redirect -eq 2 -or ($Method -ne 'GET' -and $status -notin 307,308)) { throw 'Unexpected Workshop API redirect.' }
          $next = Get-WorkshopUri ([uri]::new($target, $response.Headers.Location).AbsoluteUri)
          if ($next.Authority -ne $target.Authority) { throw 'The Workshop API redirected to another host.' }
          $target = $next
          continue
        }
        $null = $response.EnsureSuccessStatusCode()
        if ($response.Content.Headers.ContentLength -gt $limit) { throw 'The Workshop response is too large.' }
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        try { return (Read-WorkshopJson $stream $limit $timeout.Token) } finally { $stream.Dispose() }
      } finally {
        if ($response) { $response.Dispose() }
        $request.Dispose()
      }
    }
  } finally {
    $timeout.Dispose()
    $client.Dispose()
  }
}

function ConvertFrom-WorkshopVersion([string]$Text) {
  if ($Text.Trim() -notmatch '^v?([0-9]+(?:\.[0-9]+){0,3})(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z.-]+)?$') {
    throw 'Unrecognized Workshop version.'
  }
  $suffix = $Matches[2]
  $components = @($Matches[1].Split('.') + @('0', '0', '0'))
  $core = [version]($components[0..3] -join '.')
  @{ core = $core; suffix = $suffix }
}

function Compare-WorkshopVersion([string]$Left, [string]$Right) {
  $a = ConvertFrom-WorkshopVersion $Left
  $b = ConvertFrom-WorkshopVersion $Right
  $comparison = $a.core.CompareTo($b.core)
  if ($comparison -ne 0) { return $comparison }
  if (!$a.suffix -or !$b.suffix) { return ([int](!$a.suffix) - [int](!$b.suffix)) }
  $partsA = $a.suffix.Split('.')
  $partsB = $b.suffix.Split('.')
  for ($index = 0; $index -lt [Math]::Min($partsA.Length, $partsB.Length); $index++) {
    $partA = $partsA[$index]
    $partB = $partsB[$index]
    $numericA = $partA -match '^\d+$'
    $numericB = $partB -match '^\d+$'
    if ($numericA -ne $numericB) { return ([int]$numericB - [int]$numericA) }
    if ($numericA) {
      $partA = $partA.TrimStart('0')
      $partB = $partB.TrimStart('0')
      if ($partA.Length -ne $partB.Length) { return $partA.Length.CompareTo($partB.Length) }
    }
    $comparison = [string]::CompareOrdinal($partA, $partB)
    if ($comparison -ne 0) { return $comparison }
  }
  $partsA.Length.CompareTo($partsB.Length)
}
