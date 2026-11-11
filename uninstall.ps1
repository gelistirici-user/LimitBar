# LimitBar kaldırma betiği
#
#    irm https://raw.githubusercontent.com/gelistirici-user/LimitBar/main/uninstall.ps1 | iex
#  veya
#    powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
#
# Uygulamayı kapatır, %LOCALAPPDATA%\LimitBar klasörünü ve kısayolları siler.
# Claude Code / Codex / Gemini oturum dosyalarına dokunmaz.
$ErrorActionPreference = 'Stop'

Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*LimitBar.ps1*' -and $_.ProcessId -ne $PID } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

$paths = @(
  (Join-Path ([Environment]::GetFolderPath('Programs')) 'LimitBar.lnk'),
  (Join-Path ([Environment]::GetFolderPath('Startup')) 'LimitBar.lnk'),
  (Join-Path $env:LOCALAPPDATA 'LimitBar')
)
foreach ($p in $paths) {
  if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force; Write-Host "Silindi: $p" }
}
Write-Host 'LimitBar kaldırıldı.' -ForegroundColor Green
