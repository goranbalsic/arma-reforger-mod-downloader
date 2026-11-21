function Invoke-WorkshopApi {
  param(
    [Parameter(Mandatory)][string]$Uri, [hashtable]$Headers, [string]$UserAgent,
    [string]$Method, [string]$Body, [string]$ContentType, [int]$TimeoutSec
  )
  # Windows PowerShell guesses a legacy encoding when application/json omits charset.
  $ProgressPreference = 'SilentlyContinue'
  $response = Invoke-WebRequest @PSBoundParameters -UseBasicParsing -ErrorAction Stop
  $json = [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray()).TrimStart([char]0xFEFF)
  ConvertFrom-Json $json -ErrorAction Stop
}
