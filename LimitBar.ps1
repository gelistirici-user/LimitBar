#Requires -Version 5.1
<#
  LimitBar - Windows tepsi uygulaması: Claude Code, Codex ve Gemini CLI kullanım limitleri.
  CodexBar (steipete) fikrinden esinlenmiştir; ek kurulum gerektirmez (PowerShell + WinForms).
  https://github.com/gelistirici-user/LimitBar

  Kullanım:
    LimitBar.ps1                 Tepsi uygulamasını başlatır
    LimitBar.ps1 -Once           Limitleri bir kez çekip konsola JSON yazar
    LimitBar.ps1 -NoRefresh      Süresi dolmuş tokenları yenilemez (kimlik dosyalarına yazmaz)
    LimitBar.ps1 -Demo           Gerçek hesaplar yerine örnek verilerle çalışır
    LimitBar.ps1 -Screenshot x.png   Paneli bir kez çizip PNG olarak kaydeder ve çıkar
#>
param(
  [switch]$Once,
  [switch]$NoRefresh,
  [switch]$Demo,
  [string]$Screenshot
)

$ErrorActionPreference = 'Stop'
$LBVersion = '1.0.0'
$RepoUrl = 'https://github.com/gelistirici-user/LimitBar'

# ---------------------------------------------------------------------------
#  Veri çekme (arka plan runspace'inde çalışır)
# ---------------------------------------------------------------------------
$FetchScript = {
  param([bool]$NoRefresh)
  $ErrorActionPreference = 'Stop'
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $H = $env:USERPROFILE

  function New-Result($name) {
    [pscustomobject]@{ Name = $name; Plan = $null; Windows = @(); Error = $null; Note = $null }
  }
  function New-Window($label, $used, $resetAt, $secs = 0) {
    [pscustomobject]@{ Label = $label; Used = [double]$used; ResetAt = $resetAt; Secs = $secs }
  }
  function Set-Prop($obj, $name, $value) {
    if ($obj.PSObject.Properties[$name]) { $obj.$name = $value }
    else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value }
  }
  function Read-Json($path) {
    Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
  }
  function Write-JsonFile($path, $obj) {
    $tmp = "$path.limitbar.tmp"
    [IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $path -Force
  }
  function FromUnix($s) {
    if ($null -eq $s) { return $null }
    [DateTimeOffset]::FromUnixTimeSeconds([int64]$s).LocalDateTime
  }
  function FromIso($s) {
    if (-not $s) { return $null }
    if ($s -is [datetime]) { return $s.ToLocalTime() }
    [DateTimeOffset]::Parse([string]$s, [Globalization.CultureInfo]::InvariantCulture).LocalDateTime
  }
  function Format-Plan($p) {
    if (-not $p) { return $null }
    (Get-Culture).TextInfo.ToTitleCase(([string]$p).Replace('_', ' ').ToLower())
  }
  function Get-WindowLabel($secs) {
    $s = [int64]$secs
    if ($s -eq 18000) { return '5 saatlik' }
    if ($s -eq 86400) { return 'Günlük' }
    if ($s -eq 604800) { return 'Haftalık' }
    if ($s -gt 0 -and $s % 86400 -eq 0) { return "$($s / 86400) günlük" }
    if ($s -gt 0) { return "$([math]::Round($s / 3600, 1)) saatlik" }
    'Limit'
  }

  function Invoke-Api($Method, $Uri, $Headers, $Body, $ContentType) {
    $p = @{ Method = $Method; Uri = $Uri; Headers = $Headers; TimeoutSec = 20; UseBasicParsing = $true }
    if ($Body) { $p.Body = $Body; $p.ContentType = $ContentType }
    try { return Invoke-RestMethod @p }
    catch {
      $status = 0; $text = ''
      $resp = $_.Exception.Response
      if ($resp) {
        $status = [int]$resp.StatusCode
        try { $text = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } catch {}
      }
      $msg = if ($status) { "HTTP $status" } else { "Bağlantı hatası: $($_.Exception.Message)" }
      $e = New-Object Exception($msg)
      $e.Data['Status'] = $status
      $e.Data['Body'] = $text
      if ($resp) { $e.Data['RetryAfter'] = $resp.Headers['Retry-After'] }
      throw $e
    }
  }

  function Get-ErrorText($err, $relogin) {
    $ex = $err.Exception
    $status = $ex.Data['Status']
    if ($status -eq 401 -or $status -eq 403) { return "Yetki reddedildi ($status). $relogin" }
    if ($status -eq 429) { return 'Çok fazla istek (429). Bir sonraki yenilemede tekrar denenecek.' }
    $m = $ex.Message
    if ($m.Length -gt 180) { $m = $m.Substring(0, 180) + '…' }
    $m
  }

  # ----------------------------- Claude Code -------------------------------
  function Get-Claude {
    $dir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $H '.claude' }
    $path = Join-Path $dir '.credentials.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $r = New-Result 'Claude'
    $relogin = 'Terminalde "claude" çalıştırıp /login ile giriş yapın.'
    try {
      $j = Read-Json $path
      $c = $j.claudeAiOauth
      if (-not $c -or -not $c.accessToken) { throw "Claude Code oturumu bulunamadı. $relogin" }
      $r.Plan = Format-Plan $c.subscriptionType

      $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      if (-not $c.expiresAt -or [int64]$c.expiresAt -lt $nowMs + 60000) {
        if ($NoRefresh) { throw 'Token süresi dolmuş (yenileme kapalı: -NoRefresh).' }
        if (-not $c.refreshToken) { throw "Token süresi dolmuş. $relogin" }
        $busyMsg = 'Claude token yenileme sunucusu çok fazla istek dedi (429). Terminalde bir kez "claude" çalıştırırsan Claude Code tokenı kendisi yeniler; LimitBar sonra otomatik okur.'
        # 429 sonrası sunucuyu her 5 dakikada bir yormamak için bekle
        if ($global:LB_ClaudeRefreshBlockedUntil -and (Get-Date) -lt $global:LB_ClaudeRefreshBlockedUntil) {
          throw ($busyMsg + ' Sonraki deneme: ' + $global:LB_ClaudeRefreshBlockedUntil.ToString('HH:mm'))
        }
        $body = 'grant_type=refresh_token&refresh_token=' + [uri]::EscapeDataString($c.refreshToken) +
                '&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e'
        try {
          $t = Invoke-Api 'POST' 'https://platform.claude.com/v1/oauth/token' @{ Accept = 'application/json'; 'User-Agent' = 'claude-cli/2.1.0 (external, cli)' } $body 'application/x-www-form-urlencoded'
          $global:LB_ClaudeRefreshBlockedUntil = $null
        } catch {
          if ([string]$_.Exception.Data['Body'] -match 'invalid_grant') { throw "Claude oturumu sona ermiş. $relogin" }
          if ($_.Exception.Data['Status'] -eq 429) {
            $wait = 30
            $ra = [string]$_.Exception.Data['RetryAfter']
            $sec = 0
            if ([int]::TryParse($ra, [ref]$sec) -and $sec -gt 0) { $wait = [math]::Max(1, [math]::Ceiling($sec / 60)) }
            $global:LB_ClaudeRefreshBlockedUntil = (Get-Date).AddMinutes($wait)
            throw ($busyMsg + ' Sonraki deneme: ' + $global:LB_ClaudeRefreshBlockedUntil.ToString('HH:mm'))
          }
          throw
        }
        # Claude Code'un kendisinin yaptığı gibi yeni tokenı aynı dosyaya geri yaz
        $c.accessToken = $t.access_token
        if ($t.refresh_token) { $c.refreshToken = $t.refresh_token }
        Set-Prop $c 'expiresAt' ($nowMs + [int64]$t.expires_in * 1000)
        Write-JsonFile $path $j
      }

      $hdr = @{
        Authorization    = "Bearer $($c.accessToken)"
        Accept           = 'application/json'
        'anthropic-beta' = 'oauth-2025-04-20'
        'User-Agent'     = 'claude-code/2.1.0'
      }
      $u = Invoke-Api 'GET' 'https://api.anthropic.com/api/oauth/usage' $hdr
      $map = @(
        @('five_hour', '5 saatlik'),
        @('seven_day', 'Haftalık'),
        @('seven_day_opus', 'Haftalık · Opus'),
        @('seven_day_sonnet', 'Haftalık · Sonnet')
      )
      foreach ($k in $map) {
        $w = $u.($k[0])
        if ($w -and $null -ne $w.utilization) {
          $r.Windows += New-Window $k[1] $w.utilization (FromIso $w.resets_at)
        }
      }
      if ($u.extra_usage -and $u.extra_usage.is_enabled -and $null -ne $u.extra_usage.utilization) {
        $r.Note = "Ek kullanım: %$([math]::Round([double]$u.extra_usage.utilization))"
      }
      if ($r.Windows.Count -eq 0 -and -not $r.Note) { $r.Note = 'Limit bilgisi döndürülmedi.' }
    } catch { $r.Error = Get-ErrorText $_ $relogin }
    $r
  }

  # -------------------------------- Codex ----------------------------------
  function Get-JwtExp($jwt) {
    try {
      $p = $jwt.Split('.')[1].Replace('-', '+').Replace('_', '/')
      switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
      ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json).exp
    } catch { $null }
  }

  function Add-CodexWindows($r, $rl, $prefix) {
    if (-not $rl) { return }
    $list = @()
    foreach ($w in @($rl.primary_window, $rl.secondary_window)) {
      if ($w -and $null -ne $w.used_percent) {
        $label = Get-WindowLabel $w.limit_window_seconds
        if ($prefix) { $label = "$prefix · $label" }
        $list += New-Window $label $w.used_percent (FromUnix $w.reset_at) ([int64]$w.limit_window_seconds)
      }
    }
    $r.Windows += @($list | Sort-Object Secs)
  }

  function Get-Codex {
    $dir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $H '.codex' }
    $path = Join-Path $dir 'auth.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $r = New-Result 'Codex'
    $relogin = 'Codex uygulamasında / "codex login" ile yeniden giriş yapın.'
    try {
      $j = Read-Json $path
      $t = $j.tokens
      if (-not $t -or -not $t.access_token) {
        if ($j.OPENAI_API_KEY) { throw 'Codex API anahtarı modunda; abonelik limiti yok.' }
        throw "Codex oturumu bulunamadı. $relogin"
      }

      $exp = Get-JwtExp $t.access_token
      $nowS = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
      if ($exp -and [int64]$exp -lt $nowS + 300) {
        if ($NoRefresh) { throw 'Token süresi dolmuş (yenileme kapalı: -NoRefresh).' }
        $clientId = 'app_EMoamEEZ73f0CkXaXp7hrann'
        if ($t.oauth_provenance -and $t.oauth_provenance.client_id) { $clientId = $t.oauth_provenance.client_id }
        $body = @{ client_id = $clientId; grant_type = 'refresh_token'; refresh_token = $t.refresh_token; scope = 'openid profile email' } | ConvertTo-Json -Compress
        try {
          $n = Invoke-Api 'POST' 'https://auth.openai.com/oauth/token' @{ Accept = 'application/json' } $body 'application/json'
        } catch {
          if ([string]$_.Exception.Data['Body'] -match 'refresh_token_(expired|reused|invalidated)|invalid_grant') { throw "Codex oturumu sona ermiş. $relogin" }
          throw
        }
        $t.access_token = $n.access_token
        if ($n.refresh_token) { $t.refresh_token = $n.refresh_token }
        if ($n.id_token) { Set-Prop $t 'id_token' $n.id_token }
        Set-Prop $j 'last_refresh' ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'))
        Write-JsonFile $path $j
      }

      $hdr = @{ Authorization = "Bearer $($t.access_token)"; Accept = 'application/json'; 'User-Agent' = 'LimitBar' }
      if ($t.account_id) { $hdr['ChatGPT-Account-Id'] = $t.account_id }
      $u = Invoke-Api 'GET' 'https://chatgpt.com/backend-api/wham/usage' $hdr
      $r.Plan = Format-Plan $u.plan_type
      Add-CodexWindows $r $u.rate_limit $null
      foreach ($a in @($u.additional_rate_limits)) {
        if ($a) {
          $name = if ($a.limit_name) { $a.limit_name } else { $a.metered_feature }
          Add-CodexWindows $r $a.rate_limit $name
        }
      }
      if ($u.credits -and $u.credits.has_credits) {
        $r.Note = if ($u.credits.unlimited) { 'Kredi: sınırsız' } else { "Kredi bakiyesi: $($u.credits.balance)" }
      }
      if ($r.Windows.Count -eq 0 -and -not $r.Note) { $r.Note = 'Limit bilgisi döndürülmedi.' }
    } catch { $r.Error = Get-ErrorText $_ $relogin }
    $r
  }

  # ------------------------------- Gemini ----------------------------------
  # Gemini CLI'nin OAuth istemci bilgisi koda gömülmez; ortam değişkenlerinden
  # veya bilgisayarda kurulu gemini-cli paketinin kendi dosyalarından okunur.
  function Get-GeminiOAuthClient {
    if ($env:GEMINI_OAUTH_CLIENT_ID -and $env:GEMINI_OAUTH_CLIENT_SECRET) {
      return @($env:GEMINI_OAUTH_CLIENT_ID, $env:GEMINI_OAUTH_CLIENT_SECRET)
    }
    if ($global:LB_GeminiClient) { return $global:LB_GeminiClient }
    $roots = @()
    if ($env:APPDATA) { $roots += Join-Path $env:APPDATA 'npm\node_modules\@google\gemini-cli' }
    $cmd = Get-Command gemini -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.Source) {
      $roots += Join-Path (Split-Path $cmd.Source) 'node_modules\@google\gemini-cli'
      $roots += Split-Path (Split-Path $cmd.Source)
    }
    $files = @()
    foreach ($root in ($roots | Select-Object -Unique)) {
      if (-not (Test-Path -LiteralPath $root)) { continue }
      $files += @(
        (Join-Path $root 'node_modules\@google\gemini-cli-core\dist\src\code_assist\oauth2.js'),
        (Join-Path $root 'dist\src\code_assist\oauth2.js')
      ) | Where-Object { Test-Path -LiteralPath $_ }
      $bundle = Join-Path $root 'bundle'
      if (Test-Path -LiteralPath $bundle) { $files += @(Get-ChildItem -LiteralPath $bundle -Filter *.js | ForEach-Object FullName) }
    }
    foreach ($f in $files) {
      $txt = [IO.File]::ReadAllText($f)
      $id = [regex]::Match($txt, 'OAUTH_CLIENT_ID\s*=\s*[''"]([^''"]+)[''"]')
      $sec = [regex]::Match($txt, 'OAUTH_CLIENT_SECRET\s*=\s*[''"]([^''"]+)[''"]')
      if ($id.Success -and $sec.Success) {
        $global:LB_GeminiClient = @($id.Groups[1].Value, $sec.Groups[1].Value)
        return $global:LB_GeminiClient
      }
    }
    $null
  }

  function Get-Gemini {
    $dir = Join-Path $H '.gemini'
    $path = Join-Path $dir 'oauth_creds.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $r = New-Result 'Gemini'
    $relogin = 'Terminalde "gemini" çalıştırıp Google ile giriş yapın.'
    try {
      $sp = Join-Path $dir 'settings.json'
      if (Test-Path -LiteralPath $sp) {
        $st = Read-Json $sp
        $sel = $null
        if ($st.security -and $st.security.auth) { $sel = $st.security.auth.selectedType }
        if ($sel -and $sel -ne 'oauth-personal') { throw 'Gemini API anahtarı / Vertex modunda; limit okunamıyor.' }
      }
      $c = Read-Json $path
      $tok = $c.access_token
      $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      if (-not $tok -or ($c.expiry_date -and [int64]$c.expiry_date -lt $nowMs + 60000)) {
        if ($NoRefresh) { throw 'Token süresi dolmuş (yenileme kapalı: -NoRefresh).' }
        $client = Get-GeminiOAuthClient
        if (-not $client) { throw 'Gemini token süresi dolmuş ve gemini-cli paketi bulunamadı. Terminalde "gemini" çalıştırın (token yenilenir) veya GEMINI_OAUTH_CLIENT_ID / GEMINI_OAUTH_CLIENT_SECRET ortam değişkenlerini ayarlayın.' }
        $cid = $client[0]; $sec = $client[1]
        $body = 'client_id=' + [uri]::EscapeDataString($cid) + '&client_secret=' + [uri]::EscapeDataString($sec) +
                '&refresh_token=' + [uri]::EscapeDataString($c.refresh_token) + '&grant_type=refresh_token'
        $n = Invoke-Api 'POST' 'https://oauth2.googleapis.com/token' @{ Accept = 'application/json' } $body 'application/x-www-form-urlencoded'
        $tok = $n.access_token   # yalnızca bellekte tutulur; dosyaya yazılmaz
      }

      $hdr = @{ Authorization = "Bearer $tok"; Accept = 'application/json' }
      $la = Invoke-Api 'POST' 'https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist' $hdr '{"metadata":{"ideType":"GEMINI_CLI","pluginType":"GEMINI"}}' 'application/json'
      $proj = $la.cloudaicompanionProject
      if ($proj -and $proj -isnot [string]) { $proj = if ($proj.id) { $proj.id } else { $proj.projectId } }
      if ($la.paidTier -and $la.paidTier.name) { $r.Plan = $la.paidTier.name }
      elseif ($la.currentTier) {
        switch ($la.currentTier.id) {
          'free-tier'     { $r.Plan = 'Ücretsiz' }
          'standard-tier' { $r.Plan = 'Standard' }
          'legacy-tier'   { $r.Plan = 'Legacy' }
          default         { $r.Plan = $la.currentTier.name }
        }
      }
      $qb = if ($proj) { @{ project = $proj } | ConvertTo-Json -Compress } else { '{}' }
      $q = Invoke-Api 'POST' 'https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota' $hdr $qb 'application/json'

      $groups = [ordered]@{ 'Pro' = $null; 'Flash' = $null; 'Flash-Lite' = $null }
      foreach ($b in @($q.buckets)) {
        if (-not $b -or -not $b.modelId -or $null -eq $b.remainingFraction) { continue }
        $id = ([string]$b.modelId).ToLower()
        $g = if ($id -match 'flash-lite') { 'Flash-Lite' } elseif ($id -match 'flash') { 'Flash' } elseif ($id -match 'pro') { 'Pro' } else { $null }
        if (-not $g) { continue }
        if (-not $groups[$g] -or [double]$b.remainingFraction -lt [double]$groups[$g].remainingFraction) { $groups[$g] = $b }
      }
      foreach ($g in $groups.Keys) {
        $b = $groups[$g]
        if ($b) { $r.Windows += New-Window "Günlük · $g" ((1 - [double]$b.remainingFraction) * 100) (FromIso $b.resetTime) }
      }
      if ($r.Windows.Count -eq 0) { $r.Note = 'Kota bilgisi döndürülmedi.' }
    } catch {
      $body = ([string]$_.Exception.Data['Body']).ToLower()
      if ($body -match 'unsupported_client|ineligibletiererror' -or ($body -match 'no longer supported' -and $body -match 'gemini code assist')) {
        $r.Error = 'Google, kişisel hesaplarda Gemini CLI OAuth kotasını artık desteklemiyor (yalnızca Workspace / Code Assist).'
      } else { $r.Error = Get-ErrorText $_ $relogin }
    }
    $r
  }

  @(Get-Claude; Get-Codex; Get-Gemini) | Where-Object { $_ }
}

if ($Demo) {
  $FetchScript = {
    param([bool]$NoRefresh)
    $now = Get-Date
    function W($label, $used, $resetAt) { [pscustomobject]@{ Label = $label; Used = [double]$used; ResetAt = $resetAt; Secs = 0 } }
    @(
      [pscustomobject]@{ Name = 'Claude'; Plan = 'Max'; Error = $null; Note = $null; Windows = @(
        (W '5 saatlik' 42 $now.AddHours(2).AddMinutes(13)),
        (W 'Haftalık' 71 $now.AddDays(3).AddHours(5)),
        (W 'Haftalık · Opus' 18 $now.AddDays(3).AddHours(5))) }
      [pscustomobject]@{ Name = 'Codex'; Plan = 'Pro'; Error = $null; Note = $null; Windows = @(
        (W '5 saatlik' 12 $now.AddHours(4).AddMinutes(40)),
        (W 'Haftalık' 93 $now.AddDays(1).AddHours(7))) }
      [pscustomobject]@{ Name = 'Gemini'; Plan = 'Standard'; Error = $null; Note = $null; Windows = @(
        (W 'Günlük · Pro' 30 $now.Date.AddDays(1)),
        (W 'Günlük · Flash' 5 $now.Date.AddDays(1))) }
    )
  }
}

if ($Once) {
  & $FetchScript ([bool]$NoRefresh) | ConvertTo-Json -Depth 6
  return
}

# ---------------------------------------------------------------------------
#  Arayüz
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
if (-not ('LBNative' -as [type])) {
  Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class LBNative {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
  [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
}
'@
}
[void][LBNative]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()

$createdNew = $false
$script:Mutex = New-Object Threading.Mutex($true, 'Local\LimitBar.SingleInstance', [ref]$createdNew)
if (-not $createdNew -and -not $Screenshot) { return }

$gfx = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$script:Scale = $gfx.DpiX / 96.0
$gfx.Dispose()
function S([double]$n) { [int][math]::Round($n * $script:Scale) }

$TR = [Globalization.CultureInfo]::GetCultureInfo('tr-TR')
$C = @{
  Bg     = [Drawing.Color]::FromArgb(32, 32, 32)
  Track  = [Drawing.Color]::FromArgb(58, 58, 58)
  Sep    = [Drawing.Color]::FromArgb(50, 50, 50)
  Text   = [Drawing.Color]::FromArgb(240, 240, 240)
  Sub    = [Drawing.Color]::FromArgb(160, 160, 160)
  Link   = [Drawing.Color]::FromArgb(120, 180, 255)
  Green  = [Drawing.Color]::FromArgb(63, 185, 80)
  Amber  = [Drawing.Color]::FromArgb(222, 162, 40)
  Red    = [Drawing.Color]::FromArgb(240, 82, 72)
  Gray   = [Drawing.Color]::FromArgb(110, 110, 110)
}
$F = @{
  Title = New-Object Drawing.Font('Segoe UI Semibold', 11)
  Name  = New-Object Drawing.Font('Segoe UI Semibold', 10)
  Body  = New-Object Drawing.Font('Segoe UI', 9)
  Small = New-Object Drawing.Font('Segoe UI', 8.25)
}

function Get-LevelColor([double]$v) {
  if ($v -ge 90) { return $C.Red }
  if ($v -ge 70) { return $C.Amber }
  $C.Green
}

function Format-Reset($dt) {
  if (-not $dt) { return '' }
  $span = $dt - (Get-Date)
  if ($span.TotalSeconds -le 0) { $rel = 'şimdi sıfırlanıyor' }
  elseif ($span.TotalDays -ge 1) { $rel = '{0}g {1}sa sonra' -f [int][math]::Floor($span.TotalDays), $span.Hours }
  elseif ($span.TotalHours -ge 1) { $rel = '{0}sa {1}dk sonra' -f [int][math]::Floor($span.TotalHours), $span.Minutes }
  else { $rel = '{0}dk sonra' -f [int][math]::Ceiling($span.TotalMinutes) }
  "Sıfırlanma: $rel · " + $dt.ToString('ddd HH:mm', $TR)
}

$script:Results = @()
$script:Loading = $false
$script:LastUpdate = $null
$script:Job = $null
$script:IconHandle = [IntPtr]::Zero
$script:LastHide = [datetime]::MinValue

# ----------------------------- Panel (popup) --------------------------------
$script:Popup = New-Object Windows.Forms.Form
$Popup.FormBorderStyle = 'None'
$Popup.ShowInTaskbar = $false
$Popup.TopMost = $true
$Popup.StartPosition = 'Manual'
$Popup.BackColor = $C.Bg
$Popup.ClientSize = New-Object Drawing.Size((S 340), (S 200))
$Popup.Text = 'LimitBar'
$Popup.Add_HandleCreated({
  $v = 2  # DWMWCP_ROUND (Windows 11 yuvarlak köşeler)
  [void][LBNative]::DwmSetWindowAttribute($Popup.Handle, 33, [ref]$v, 4)
})
$Popup.Add_Deactivate({ $Popup.Hide(); $script:LastHide = Get-Date })

function Add-Label($text, $x, $y, $font, $color, $maxW = 0) {
  $l = New-Object Windows.Forms.Label
  $l.UseMnemonic = $false
  $l.AutoSize = $true
  if ($maxW) { $l.MaximumSize = New-Object Drawing.Size($maxW, 0) }
  $l.Font = $font
  $l.ForeColor = $color
  $l.BackColor = $C.Bg
  $l.Text = $text
  $l.Location = New-Object Drawing.Point($x, $y)
  $Popup.Controls.Add($l)
  $l
}
function Add-RightLabel($text, $right, $y, $font, $color) {
  $l = Add-Label $text 0 $y $font $color
  $l.Left = $right - $l.PreferredSize.Width
  $l
}
function Add-Bar($x, $y, $w, [double]$pct) {
  $p = New-Object Windows.Forms.Panel
  $p.SetBounds($x, $y, $w, (S 6))
  $p.BackColor = $C.Track
  $p.Tag = $pct
  $p.Add_Paint({
    param($s, $e)
    $v = [math]::Max(0, [math]::Min(100, [double]$s.Tag))
    $fw = [int]($s.Width * $v / 100)
    if ($fw -gt 0) {
      $b = New-Object Drawing.SolidBrush (Get-LevelColor $v)
      $e.Graphics.FillRectangle($b, 0, 0, $fw, $s.Height)
      $b.Dispose()
    }
  })
  $Popup.Controls.Add($p)
}
function Add-Separator($x, $y, $w) {
  $p = New-Object Windows.Forms.Panel
  $p.SetBounds($x, $y, $w, 1)
  $p.BackColor = $C.Sep
  $Popup.Controls.Add($p)
}

function Build-Popup {
  $Popup.SuspendLayout()
  while ($Popup.Controls.Count) { $Popup.Controls[0].Dispose() }
  $pad = S 16
  $right = $Popup.ClientSize.Width - $pad
  $w = $right - $pad
  $y = $pad

  [void](Add-Label 'LimitBar' $pad $y $F.Title $C.Text)
  $refreshText = if ($script:Loading) { 'Yenileniyor…' } else { 'Yenile' }
  $rl = Add-RightLabel $refreshText $right ($y + (S 3)) $F.Body $C.Link
  $rl.Cursor = [Windows.Forms.Cursors]::Hand
  $rl.Add_Click({ Start-Refresh })
  $y += S 34

  if (@($script:Results).Count -eq 0) {
    $msg = if ($script:Loading) { 'Limitler yükleniyor…' } else { 'Claude Code, Codex veya Gemini CLI oturumu bulunamadı.' }
    $l = Add-Label $msg $pad $y $F.Body $C.Sub $w
    $y += $l.PreferredSize.Height + (S 12)
  }

  $first = $true
  foreach ($r in $script:Results) {
    if (-not $first) { Add-Separator $pad $y $w; $y += S 12 }
    $first = $false
    [void](Add-Label $r.Name $pad $y $F.Name $C.Text)
    if ($r.Plan) { [void](Add-RightLabel $r.Plan $right ($y + (S 2)) $F.Small $C.Sub) }
    $y += S 26
    if ($r.Error) {
      $l = Add-Label $r.Error $pad $y $F.Small $C.Amber $w
      $y += $l.PreferredSize.Height + (S 8)
    }
    foreach ($win in $r.Windows) {
      [void](Add-Label $win.Label $pad $y $F.Body $C.Text)
      [void](Add-RightLabel ('%{0} kullanıldı' -f [math]::Round($win.Used)) $right $y $F.Body (Get-LevelColor $win.Used))
      $y += S 22
      Add-Bar $pad $y $w $win.Used
      $y += S 10
      $rs = Format-Reset $win.ResetAt
      if ($rs) {
        [void](Add-Label $rs $pad $y $F.Small $C.Sub)
        $y += S 20
      }
      $y += S 6
    }
    if ($r.Note) {
      $l = Add-Label $r.Note $pad $y $F.Small $C.Sub $w
      $y += $l.PreferredSize.Height + (S 6)
    }
  }

  Add-Separator $pad $y $w
  $y += S 10
  $foot = if ($script:LastUpdate) { 'Son güncelleme: ' + $script:LastUpdate.ToString('HH:mm', $TR) + ' · 5 dakikada bir yenilenir' } else { '' }
  if ($foot) { [void](Add-Label $foot $pad $y $F.Small $C.Sub); $y += S 18 }

  $Popup.ClientSize = New-Object Drawing.Size($Popup.ClientSize.Width, ($y + $pad - (S 4)))
  $wa = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
  $Popup.Location = New-Object Drawing.Point(($wa.Right - $Popup.Width - (S 12)), ($wa.Bottom - $Popup.Height - (S 12)))
  $Popup.ResumeLayout()
}

function Show-Popup {
  if (((Get-Date) - $script:LastHide).TotalMilliseconds -lt 300) { return }  # aynı tıkla kapanıp tekrar açılmasın
  Build-Popup
  $Popup.Show()
  $Popup.Activate()
}

# ------------------------------- Tepsi ikonu --------------------------------
$script:Tray = New-Object Windows.Forms.NotifyIcon
$Tray.Text = 'LimitBar'

function Set-TrayIcon {
  $max = $null
  foreach ($r in $script:Results) { foreach ($w in $r.Windows) { if ($null -eq $max -or $w.Used -gt $max) { $max = $w.Used } } }
  $bmp = New-Object Drawing.Bitmap 32, 32
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $g.TextRenderingHint = 'AntiAliasGridFit'
  $col = if ($null -eq $max) { $C.Gray } else { Get-LevelColor $max }
  $path = New-Object Drawing.Drawing2D.GraphicsPath
  $rad = 12
  $path.AddArc(0, 0, $rad, $rad, 180, 90); $path.AddArc(31 - $rad, 0, $rad, $rad, 270, 90)
  $path.AddArc(31 - $rad, 31 - $rad, $rad, $rad, 0, 90); $path.AddArc(0, 31 - $rad, $rad, $rad, 90, 90)
  $path.CloseFigure()
  $br = New-Object Drawing.SolidBrush $col
  $g.FillPath($br, $path)
  if ($null -eq $max) { $txt = if ($script:Loading) { '…' } else { '?' } }
  elseif ($max -ge 99.5) { $txt = '!' }
  else { $txt = [string][int][math]::Round($max) }
  $font = New-Object Drawing.Font('Segoe UI', $(if ($txt.Length -ge 2) { 17 } else { 20 }), [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
  $sf = New-Object Drawing.StringFormat
  $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
  $g.DrawString($txt, $font, [Drawing.Brushes]::White, (New-Object Drawing.RectangleF(0, 1, 32, 32)), $sf)
  $g.Dispose(); $br.Dispose(); $font.Dispose(); $path.Dispose()
  $h = $bmp.GetHicon()
  $bmp.Dispose()
  $Tray.Icon = [Drawing.Icon]::FromHandle($h)
  if ($script:IconHandle -ne [IntPtr]::Zero) { [void][LBNative]::DestroyIcon($script:IconHandle) }
  $script:IconHandle = $h

  $parts = @()
  foreach ($r in $script:Results) {
    $m = ($r.Windows | Measure-Object -Property Used -Maximum).Maximum
    if ($null -ne $m) { $parts += ('{0} %{1}' -f $r.Name, [math]::Round($m)) }
    elseif ($r.Error) { $parts += "$($r.Name) hata" }
  }
  $tip = if ($parts.Count) { 'LimitBar · ' + ($parts -join ' · ') } else { 'LimitBar' }
  if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
  $Tray.Text = $tip
}

function Update-UI {
  Set-TrayIcon
  if ($Popup.Visible) { Build-Popup }
}

# ---------------------------- Arka plan yenileme ----------------------------
$script:Runspace = [runspacefactory]::CreateRunspace()
$Runspace.Open()

function Start-Refresh {
  if ($script:Job) { return }
  $ps = [PowerShell]::Create()
  $ps.Runspace = $script:Runspace
  [void]$ps.AddScript($FetchScript.ToString()).AddArgument([bool]$NoRefresh)
  $script:Job = @{ PS = $ps; Handle = $ps.BeginInvoke() }
  $script:Loading = $true
  Update-UI
}

$script:Poll = New-Object Windows.Forms.Timer
$Poll.Interval = 400
$Poll.Add_Tick({
  if (-not $script:Job -or -not $script:Job.Handle.IsCompleted) { return }
  try {
    $out = $script:Job.PS.EndInvoke($script:Job.Handle)
    $script:Results = @($out | Where-Object { $_ })
  } catch {
    $script:Results = @([pscustomobject]@{ Name = 'LimitBar'; Plan = $null; Windows = @(); Error = $_.Exception.Message; Note = $null })
  } finally {
    $script:Job.PS.Dispose()
    $script:Job = $null
    $script:Loading = $false
    $script:LastUpdate = Get-Date
  }
  Update-UI
  if ($Screenshot) {
    Build-Popup
    $Popup.Location = New-Object Drawing.Point(-4000, -4000)
    $Popup.Show()
    $bmp = New-Object Drawing.Bitmap $Popup.Width, $Popup.Height
    $Popup.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $Popup.Width, $Popup.Height)))
    $bmp.Save($Screenshot, [Drawing.Imaging.ImageFormat]::Png)
    $ico = $Tray.Icon.ToBitmap(); $ico.Save(($Screenshot -replace '\.png$', '-icon.png'), [Drawing.Imaging.ImageFormat]::Png)
    $script:Tray.Visible = $false
    [Windows.Forms.Application]::Exit()
  }
})
$Poll.Start()

$script:Every = New-Object Windows.Forms.Timer
$Every.Interval = 5 * 60 * 1000
$Every.Add_Tick({ Start-Refresh })
$Every.Start()

# ------------------------------ Sağ tık menüsü ------------------------------
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'LimitBar.lnk'
$Launcher = Join-Path $PSScriptRoot 'LimitBar.vbs'

function Set-Autostart([bool]$on) {
  if ($on) {
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($StartupLnk)
    $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
    $lnk.Arguments = '"' + $Launcher + '"'
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.Description = 'LimitBar'
    $lnk.Save()
  } elseif (Test-Path -LiteralPath $StartupLnk) {
    Remove-Item -LiteralPath $StartupLnk -Force
  }
}

$menu = New-Object Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add('Limitleri göster')
$miOpen.Font = New-Object Drawing.Font($miOpen.Font, [Drawing.FontStyle]::Bold)
$miOpen.Add_Click({ $script:LastHide = [datetime]::MinValue; Show-Popup })
$miRefresh = $menu.Items.Add('Şimdi yenile')
$miRefresh.Add_Click({ Start-Refresh })
$miAuto = New-Object Windows.Forms.ToolStripMenuItem('Windows ile başlat')
$miAuto.Checked = Test-Path -LiteralPath $StartupLnk
$miAuto.Add_Click({
  try { Set-Autostart (-not $miAuto.Checked); $miAuto.Checked = Test-Path -LiteralPath $StartupLnk }
  catch { [Windows.Forms.MessageBox]::Show("Başlangıç kısayolu ayarlanamadı: $($_.Exception.Message)", 'LimitBar') | Out-Null }
})
[void]$menu.Items.Add($miAuto)
$miRepo = $menu.Items.Add("GitHub sayfası (v$LBVersion)")
$miRepo.Add_Click({ Start-Process $RepoUrl })
[void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$miExit = $menu.Items.Add('Çıkış')
$miExit.Add_Click({
  $script:Tray.Visible = $false
  [Windows.Forms.Application]::Exit()
})
$Tray.ContextMenuStrip = $menu

$Tray.Add_MouseUp({
  param($s, $e)
  if ($e.Button -eq [Windows.Forms.MouseButtons]::Left) {
    if ($Popup.Visible) { $Popup.Hide() } else { Show-Popup }
  }
})

Set-TrayIcon
$Tray.Visible = -not [bool]$Screenshot
Start-Refresh

[Windows.Forms.Application]::Run()

$Tray.Visible = $false
$Tray.Dispose()
if ($script:IconHandle -ne [IntPtr]::Zero) { [void][LBNative]::DestroyIcon($script:IconHandle) }
$Runspace.Close()
try { $script:Mutex.ReleaseMutex() } catch {}
