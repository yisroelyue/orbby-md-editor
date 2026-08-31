# 打包脚本：构建 Windows Release 版本并压缩到 dist/ 目录。
# 应用名、版本号自动从 pubspec.yaml 读取，dist/ 内只保留最新一个压缩包。
# 用法：.\package.ps1
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$pubspec = Get-Content (Join-Path $PSScriptRoot 'pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^name:\s*(\S+)') { throw '无法从 pubspec.yaml 读取应用名' }
$appName = $Matches[1]
if ($pubspec -notmatch '(?m)^version:\s*(\S+)') { throw '无法从 pubspec.yaml 读取版本号' }
$appVersion = $Matches[1] -split '\+' | Select-Object -First 1

$zipName = "${appName}_v${appVersion}_windows_x64.zip"
$distDir = Join-Path $PSScriptRoot 'dist'
$zipPath = Join-Path $distDir $zipName

Write-Host '== flutter build windows --release ==' -ForegroundColor Cyan
flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw '构建失败' }

$releaseDir = Join-Path $PSScriptRoot 'build\windows\x64\runner\Release'
if (-not (Get-ChildItem (Join-Path $releaseDir '*.exe') -ErrorAction SilentlyContinue)) {
    throw "未找到构建产物: $releaseDir"
}

# 先复制到暂存目录，让压缩包内带一层版本号文件夹，解压后文件不会散落一地
$stageDir = Join-Path $env:TEMP "${appName}_package_v${appVersion}"
$appDirName = "${appName}_v${appVersion}"
if (Test-Path $stageDir) { Remove-Item -Recurse -Force $stageDir }
New-Item -ItemType Directory -Force $stageDir | Out-Null
Copy-Item -Recurse -Force -Path $releaseDir -Destination (Join-Path $stageDir $appDirName)

New-Item -ItemType Directory -Force $distDir | Out-Null
if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
Compress-Archive -Path (Join-Path $stageDir $appDirName) -DestinationPath $zipPath
Remove-Item -Recurse -Force $stageDir

# 只保留最新版本压缩包，删掉 dist/ 里的旧版本
Get-ChildItem $distDir -Filter "${appName}_v*_windows_x64.zip" |
    Where-Object { $_.Name -ne $zipName } |
    Remove-Item -Force

# 同步 README 中的下载链接（README 里没有 dist 链接时自动跳过）
$readmePath = Join-Path $PSScriptRoot 'README.md'
if (Test-Path $readmePath) {
    $readme = [IO.File]::ReadAllText($readmePath)
    $pattern = "dist/${appName}_v[\d.]+_windows_x64\.zip"
    $updated = [regex]::Replace($readme, $pattern, "dist/$zipName")
    if ($updated -ne $readme) {
        [IO.File]::WriteAllText($readmePath, $updated, (New-Object System.Text.UTF8Encoding $false))
        Write-Host "已更新 README 下载链接: dist/$zipName"
    }
}

$sizeMb = '{0:N1}' -f ((Get-Item $zipPath).Length / 1MB)
Write-Host ''
Write-Host "打包完成: dist\$zipName ($sizeMb MB)" -ForegroundColor Green
