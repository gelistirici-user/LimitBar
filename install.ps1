# LimitBar kurulum betiği
#
#  İnternetten tek satırla:
#    irm https://raw.githubusercontent.com/gelistirici-user/LimitBar/main/install.ps1 | iex
#
#  İndirilmiş klasörden:
#    powershell -ExecutionPolicy Bypass -File .\install.ps1 [-NoAutostart]
#
#  Uygulamayı %LOCALAPPDATA%\LimitBar klasörüne kopyalar, Başlat menüsüne ve
#  (istenmezse -NoAutostart / LIMITBAR_NO_AUTOSTART=1) Windows başlangıcına kısayol ekler.
param([switch]$NoAutostart)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$RawBase = 'https://raw.githubusercontent.com/gelistirici-user/LimitBar/main'
$Files = @('LimitBar.ps1', 'LimitBar.vbs')
$dst = Join-Path $env:LOCALAPPDATA 'LimitBar'
if ($env:LIMITBAR_NO_AUTOSTART -eq '1') { $NoAutostart = $true }

# Çalışan eski sürümü kapat
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*LimitBar.ps1*' -and $_.ProcessId -ne $PID } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

New-Item -ItemType Directory -Force $dst | Out-Null

$local = $PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'LimitBar.ps1'))
foreach ($f in $Files) {
  $target = Join-Path $dst $f
  if ($local) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $f) -Destination $target -Force
  } else {
    Write-Host "İndiriliyor: $f"
    Invoke-WebRequest -UseBasicParsing -Uri "$RawBase/$f" -OutFile $target
  }
  Unblock-File -LiteralPath $target -ErrorAction SilentlyContinue
}

$sh = New-Object -ComObject WScript.Shell
$links = @(Join-Path ([Environment]::GetFolderPath('Programs')) 'LimitBar.lnk')
if (-not $NoAutostart) { $links += Join-Path ([Environment]::GetFolderPath('Startup')) 'LimitBar.lnk' }
foreach ($p in $links) {
  $l = $sh.CreateShortcut($p)
  $l.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
  $l.Arguments = '"' + (Join-Path $dst 'LimitBar.vbs') + '"'
  $l.WorkingDirectory = $dst
  $l.Description = 'LimitBar'
  $l.IconLocation = (Join-Path $env:WINDIR 'System32\imageres.dll') + ',150'
  $l.Save()
  Write-Host "Kısayol: $p"
}

Start-Process (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"' + (Join-Path $dst 'LimitBar.vbs') + '"')
Write-Host ''
Write-Host "LimitBar kuruldu ve başlatıldı: $dst" -ForegroundColor Green
Write-Host 'Saatin yanındaki renkli ikona tıklayın (görünmüyorsa görev çubuğundaki ^ okuna bakın).'
