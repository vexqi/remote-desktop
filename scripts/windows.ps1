<#
Windows 统一入口: 配置远程桌面, Python, Cloudflare Tunnel 和可选 Warpscout 代理.
同时支持 GitHub Actions 与 Azure Pipelines。
主要环境变量: CLOUDFLARED_TOKEN, CLOUDFLARED_TUNNEL_URL, PASSWORD, RUNNER_USER, KRYVA_API_KEY, KRYVA_API_URL, WARPSCOUT_COUNTRY.
#>
param(
  [ValidateSet("Setup", "Check", "Cleanup")]
  [string]$Action = "Setup",
  [string]$CloudflaredVersion = "latest",
  [string]$RunnerUser = "",
  [string]$InstallDir = "$HOME\cloudflared"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# 输出安装步骤名称.
function Write-Step {
  param([string]$Message)
  Write-Host ""
  Write-Host "==> $Message"
}

# 读取环境变量; GitHub 空 Secret 与 Azure 未解析宏 $(NAME) 均视为未设置.
function Get-CiEnv {
  param([string]$Name)

  $value = [Environment]::GetEnvironmentVariable($Name)
  $unresolvedMacro = '$(' + $Name + ')'
  if ([string]::IsNullOrWhiteSpace($value) -or $value -eq $unresolvedMacro) {
    return $null
  }

  return $value
}

# 校验必填环境变量并返回其值.
function Require-Env {
  param([string]$Name)

  $value = Get-CiEnv -Name $Name
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "Missing required environment variable: $Name"
  }

  return $value
}

# 判断当前运行环境是否为 Azure Pipelines.
function Test-AzurePipelines {
  $tfBuild = [Environment]::GetEnvironmentVariable("TF_BUILD")
  if ($tfBuild -eq "True" -or $tfBuild -eq "true") {
    return $true
  }
  return -not [string]::IsNullOrWhiteSpace(
    [Environment]::GetEnvironmentVariable("SYSTEM_TEAMFOUNDATIONCOLLECTIONURI")
  )
}

# 官方托管 Windows 镜像的登录用户不同：GitHub 为 runneradmin，Azure 为 VssAdministrator。
# RUNNER_USER 可用于自托管 Runner 或镜像变更后的显式覆盖。
function Resolve-RunnerUser {
  param([string]$ConfiguredUser)

  if (-not [string]::IsNullOrWhiteSpace($ConfiguredUser)) {
    return $ConfiguredUser
  }

  $environmentUser = Get-CiEnv -Name "RUNNER_USER"
  if (-not [string]::IsNullOrWhiteSpace($environmentUser)) {
    return $environmentUser
  }

  if (Test-AzurePipelines) {
    return "VssAdministrator"
  }

  return "runneradmin"
}

# 将脚本运行后生成的状态写回流水线, 不用于桌面终端环境注入.
function Set-CiEnv {
  param(
    [string]$Name,
    [string]$Value
  )

  if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) {
    Add-Content -Path $env:GITHUB_ENV -Value "$Name=$Value"
  }

  if (Test-AzurePipelines) {
    Write-Host "##vso[task.setvariable variable=$Name]$Value"
  }
}

# 安全添加本地用户到指定用户组，失败时只记录警告。
function Add-LocalGroupMemberSafe {
  param(
    [string]$Group,
    [string]$Member
  )

  try {
    if (-not (Get-LocalGroupMember -Group $Group -Member $Member -ErrorAction SilentlyContinue)) {
      Add-LocalGroupMember -Group $Group -Member $Member -ErrorAction Stop
    }
  }
  catch {
    Write-Warning "Failed to add $Member to ${Group}: $($_.Exception.Message)"
  }
}

# 写入注册表配置项，缺失路径时自动创建。
function Set-RegistryValue {
  param(
    [string]$Path,
    [string]$Name,
    [Object]$Value
  )

  if (-not (Test-Path -Path $Path)) {
    New-Item -Path $Path -Force | Out-Null
  }

  Set-ItemProperty -Path $Path -Name $Name -Value $Value
}

# 按候选 URL 顺序下载，适配不同架构资产命名。
function Download-FirstAvailable {
  param(
    [string[]]$Urls,
    [string]$DestinationPath
  )

  foreach ($url in $Urls) {
    try {
      Invoke-WebRequest -Uri $url -OutFile $DestinationPath
      return $url
    }
    catch {
      Write-Host "Download failed: $url"
    }
  }

  throw "None of the candidate download URLs worked."
}

# 禁用本地密码限制并回读验证, 仅写入密码策略字段.
function Disable-LocalPasswordPolicy {
  Write-Step "Disabling local Windows password policy"
  $policy = [ordered]@{
    PasswordComplexity = 0
    MinimumPasswordLength = 0
    PasswordHistorySize = 0
    MinimumPasswordAge = 0
    MaximumPasswordAge = -1
  }
  $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("remote-desktop-policy-" + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tempDir | Out-Null
  try {
    $configPath = Join-Path $tempDir 'password.inf'
    $databasePath = Join-Path $tempDir 'password.sdb'
    $exportPath = Join-Path $tempDir 'effective.inf'
    $logPath = Join-Path $tempDir 'secedit.log'
    $config = @('[Unicode]', 'Unicode=yes', '[System Access]')
    foreach ($entry in $policy.GetEnumerator()) {
      $config += "$($entry.Key) = $($entry.Value)"
    }
    $config += @('[Version]', 'signature="$CHICAGO$"', 'Revision=1')
    Set-Content -LiteralPath $configPath -Value $config -Encoding Unicode

    # 使用独立安全数据库, 避免导入或覆盖无关的系统安全配置.
    secedit.exe /configure /db $databasePath /cfg $configPath /areas SECURITYPOLICY /log $logPath /quiet
    if ($LASTEXITCODE -ne 0) { throw "Failed to disable local password policy (secedit exit $LASTEXITCODE)." }
    secedit.exe /export /cfg $exportPath /areas SECURITYPOLICY /log $logPath /quiet
    if ($LASTEXITCODE -ne 0) { throw "Failed to read back local password policy (secedit exit $LASTEXITCODE)." }
    $effective = Get-Content -LiteralPath $exportPath -Raw
    foreach ($entry in $policy.GetEnumerator()) {
      $pattern = '(?m)^' + [regex]::Escape($entry.Key) + '\s*=\s*' + [regex]::Escape([string]$entry.Value) + '\s*$'
      if ($effective -notmatch $pattern) { throw "Local password policy was not applied: $($entry.Key)." }
    }
  }
  finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force
  }
}

# 配置 Windows 远程桌面和相关防火墙规则。
function Enable-RemoteDesktop {
  param(
    [string]$UserName,
    [string]$Password
  )

  Write-Step "Configuring Windows Remote Desktop"
  Write-Host "Remote login username: $UserName"
  if (-not (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue)) {
    throw "Windows user does not exist on this hosted image: $UserName"
  }
  Disable-LocalPasswordPolicy

  # 使用本地账户 API 设置密码, 避免原生命令行对特殊字符和选项的解析.
  $securePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force
  try {
    Set-LocalUser -Name $UserName -Password $securePassword -ErrorAction Stop
  }
  catch {
    # 区分策略配置后的密码拒绝, 不在日志中暴露 Secret.
    if ($_.Exception.GetType().Name -eq 'InvalidPasswordException' -or
        $_.FullyQualifiedErrorId -match 'InvalidPassword') {
      throw "Windows rejected PASSWORD for user: ${UserName} after configuring local password policy. Check the supplied credential and any externally enforced policy."
    }
    # 保留系统错误便于区分密码策略和权限问题, 同时避免输出密码原文.
    $reason = $_.Exception.Message.Replace($Password, "[REDACTED]")
    throw "Failed to set the password for Windows user: ${UserName}. ${reason}"
  }
  finally {
    $securePassword.Dispose()
  }
  Add-LocalGroupMemberSafe -Group "Remote Desktop Users" -Member $UserName
  Add-LocalGroupMemberSafe -Group "Administrators" -Member $UserName

  Set-RegistryValue `
    -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
    -Name "fDenyTSConnections" `
    -Value 0
  Set-RegistryValue `
    -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" `
    -Name "fDenyTSConnections" `
    -Value 0
  Set-RegistryValue `
    -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
    -Name "fSingleSessionPerUser" `
    -Value 0
  Set-RegistryValue `
    -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
    -Name "UserAuthentication" `
    -Value 0
  Set-RegistryValue `
    -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
    -Name "SecurityLayer" `
    -Value 0
  Set-RegistryValue `
    -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
    -Name "MinEncryptionLevel" `
    -Value 1
  Set-RegistryValue `
    -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
    -Name "PortNumber" `
    -Value 3389

  Enable-NetFirewallRule -DisplayGroup "Remote Desktop" | Out-Null
  Set-Service -Name TermService -StartupType Manual
  Set-Service -Name UmRdpService -StartupType Manual -ErrorAction SilentlyContinue
  Start-Service -Name TermService
  Start-Service -Name UmRdpService -ErrorAction SilentlyContinue
  Restart-Service -Name TermService -Force

  Write-Host "Remote Desktop enabled for user: $UserName"
  Write-Host "Use this username when connecting: .\$UserName"
}

# 固定使用安装用户主目录下的 .venv, 与 Git Bash 使用同一路径.
function Get-VenvDir {
  return (Join-Path $HOME '.venv')
}

# 用 Git Bash 调用 common.sh 中的函数.
function Invoke-CommonFunction {
  param([string]$Name)

  $bash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
  if (-not (Test-Path -LiteralPath $bash)) { throw "未找到 Git Bash, 无法执行 $Name" }
  $common = (Join-Path $PSScriptRoot 'common.sh').Replace('\', '/')
  & $bash --noprofile --norc -c "source '$common' && $Name"
  if ($LASTEXITCODE -ne 0) { throw "$Name 失败" }
}

# 用 uv 安装 Python 3.12 和浏览器依赖.
function Install-PythonApp {
  Write-Step 'Installing Python dependencies'
  Invoke-CommonFunction -Name 'install_python_app'
}

# 根据版本生成固定 AMD64 架构的 cloudflared 下载地址.
function Get-CloudflaredAssetUrls {
  param([string]$Version)

  $releasePath = if ($Version -eq "latest") {
    "latest/download"
  }
  else {
    "download/$Version"
  }

  return "https://github.com/cloudflare/cloudflared/releases/$releasePath/cloudflared-windows-amd64.exe"
}

# 安装官方 cloudflared 客户端。
function Install-Cloudflared {
  param(
    [string]$Version,
    [string]$DestinationDir
  )

  Write-Step "Installing cloudflared $Version"

  New-Item -ItemType Directory -Force -Path $DestinationDir | Out-Null
  $cloudflaredPath = Join-Path $DestinationDir "cloudflared.exe"
  $downloadedUrl = Download-FirstAvailable `
    -Urls (Get-CloudflaredAssetUrls -Version $Version) `
    -DestinationPath $cloudflaredPath

  Write-Host "cloudflared installed: $cloudflaredPath ($downloadedUrl)"
  return $cloudflaredPath
}

# 增量输出完整日志行, 将读取位置保存到文件供每轮独立保活进程复用.
function Write-CloudflaredLogUpdates {
  param([string]$Path, [string]$Token)

  Write-Host "Cloudflare Tunnel log: $Path"
  if (-not (Test-Path -LiteralPath $Path)) { throw "Cloudflare Tunnel log is missing: $Path" }
  $cursorPath = "$Path.cursor"
  $consumed = 0
  if (Test-Path -LiteralPath $cursorPath) {
    if (-not [int]::TryParse((Get-Content -LiteralPath $cursorPath -Raw).Trim(), [ref]$consumed) -or $consumed -lt 0) {
      throw "Invalid Cloudflare Tunnel log cursor: $cursorPath"
    }
  }
  $content = [string](Get-Content -LiteralPath $Path -Raw -Encoding utf8)
  $lines = $content -split "`n"
  # 最后一个未结束的日志行等待下轮, 避免截断 UTF-8 文本或尚未写完整的令牌.
  $complete = $lines.Count - 1
  if ($consumed -gt $complete) { $consumed = 0 }
  for ($index = $consumed; $index -lt $complete; $index++) {
    $line = $lines[$index].TrimEnd("`r")
    if (-not [string]::IsNullOrEmpty($Token)) { $line = $line.Replace($Token, '[REDACTED]') }
    Write-Host $line
  }
  Set-Content -LiteralPath $cursorPath -Value $complete -Encoding ascii
}

# 先输出 Tunnel 新日志, 再验证记录的进程和 WARP 出口.
function Test-WindowsSession {
  Write-Step 'Checking Cloudflare Tunnel'
  $token = Get-CiEnv -Name CLOUDFLARED_TOKEN
  Write-CloudflaredLogUpdates -Path (Require-Env CLOUDFLARED_LOG_PATH) -Token $token
  Write-CloudflaredLogUpdates -Path (Require-Env CLOUDFLARED_ERROR_LOG_PATH) -Token $token
  $tunnelPid = 0
  if (-not [int]::TryParse((Require-Env CLOUDFLARED_PID), [ref]$tunnelPid) -or $tunnelPid -le 0) {
    throw 'Invalid CLOUDFLARED_PID'
  }
  $process = Get-Process -Id $tunnelPid -ErrorAction SilentlyContinue
  if (-not $process -or $process.ProcessName -ne 'cloudflared') {
    throw 'Cloudflare Tunnel process is no longer running'
  }
  Write-Host "Cloudflare Tunnel process is running, pid=$tunnelPid"
  # [已停用] WARP 出口验证已由 Warpscout 出口验证取代, 保留以便恢复.
  #Test-WarpConnection | Out-Null
  if ((Get-ProxyMode) -ne 'off') {
    $egressIp = Test-WarpscoutConnection
    Write-Host "Warpscout 出口已验证: $egressIp"
  }
}

# 有令牌时启动受管 Tunnel，否则启动 Quick Tunnel。
function Start-Cloudflared {
  param(
    [string]$Binary,
    [string]$Token,
    [string]$TunnelUrl
  )

  Write-Step "Starting Cloudflare Tunnel"

  $stdoutPath = Join-Path $env:TEMP "cloudflared.log"
  $stderrPath = Join-Path $env:TEMP "cloudflared-error.log"
  Set-Content -LiteralPath "$stdoutPath.cursor" -Value 0 -Encoding ascii
  Set-Content -LiteralPath "$stderrPath.cursor" -Value 0 -Encoding ascii
  $arguments = if ([string]::IsNullOrWhiteSpace($Token)) {
    @("tunnel", "--no-autoupdate", "--url", $TunnelUrl)
  }
  else {
    @("tunnel", "--no-autoupdate", "run", "--token", $Token)
  }
  $process = Start-Process `
    -FilePath $Binary `
    -ArgumentList $arguments `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -WindowStyle Hidden `
    -PassThru

  # 将进程号和实际日志路径传给后续步骤, 不依赖不同步骤的 TEMP 短路径表示.
  Set-CiEnv -Name CLOUDFLARED_PID -Value ([string]$process.Id)
  Set-CiEnv -Name CLOUDFLARED_LOG_PATH -Value $stdoutPath
  Set-CiEnv -Name CLOUDFLARED_ERROR_LOG_PATH -Value $stderrPath

  Start-Sleep -Seconds 5
  if ($process.HasExited) {
    if (Test-Path -Path $stdoutPath) {
      Get-Content -Path $stdoutPath -Tail 120 | Write-Host
    }
    if (Test-Path -Path $stderrPath) {
      Get-Content -Path $stderrPath -Tail 120 | Write-Host
    }
    throw "cloudflared exited immediately with code $($process.ExitCode)."
  }

  if ([string]::IsNullOrWhiteSpace($Token)) {
    $quickTunnelUrl = $null
    for ($attempt = 1; $attempt -le 60; $attempt++) {
      $logContent = @(
        if (Test-Path -Path $stdoutPath) { Get-Content -Path $stdoutPath -Raw }
        if (Test-Path -Path $stderrPath) { Get-Content -Path $stderrPath -Raw }
      ) -join "`n"
      $urlMatches = [regex]::Matches($logContent, 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com')
      if ($urlMatches.Count -gt 0) {
        $quickTunnelUrl = $urlMatches[$urlMatches.Count - 1].Value
        Write-Host "Cloudflare Quick Tunnel URL: $quickTunnelUrl"
        break
      }
      if ($process.HasExited) {
        throw "cloudflared exited before publishing a Quick Tunnel URL with code $($process.ExitCode)."
      }
      Start-Sleep -Seconds 1
    }

    if ([string]::IsNullOrWhiteSpace($quickTunnelUrl)) {
      throw "Unable to obtain a Cloudflare Quick Tunnel URL within 60 seconds."
    }
  }

  Write-Host "Cloudflare Tunnel is running, pid=$($process.Id), log=$stdoutPath"
}

# [已停用] 以下 WARP (warp-cli) 代码由 Warpscout 代理取代, 保留以便恢复.
# 严格读取 WARP 模式, 空配置默认使用全局隧道.
#function Get-WarpMode {
#  $value = Get-CiEnv -Name "WARP_ENABLED"
#  if ([string]::IsNullOrWhiteSpace($value)) { return 'tun' }
#  if ($value -cnotin @('off', 'proxy', 'tun')) {
#    throw "WARP_ENABLED 必须为 off, proxy 或 tun"
#  }
#  return $value
#}
#
## 使用官方默认安装位置定位 WARP 客户端.
#function Get-WarpCli {
#  $binary = Join-Path $env:ProgramFiles "Cloudflare\Cloudflare WARP\warp-cli.exe"
#  if (-not (Test-Path -LiteralPath $binary)) { throw "未找到 WARP 客户端" }
#  return $binary
#}
#
## 对原生命令设置超时并检查退出码, 避免交互提示阻塞流水线.
#function Invoke-Warp {
#  param([string[]]$Arguments)
#  $info = [System.Diagnostics.ProcessStartInfo]::new()
#  $info.FileName = Get-WarpCli
#  $info.UseShellExecute = $false
#  $info.RedirectStandardOutput = $true
#  $info.RedirectStandardError = $true
#  $info.ArgumentList.Add("--accept-tos")
#  foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
#  $process = [System.Diagnostics.Process]::new()
#  $process.StartInfo = $info
#  try {
#    [void]$process.Start()
#    $stdout = $process.StandardOutput.ReadToEndAsync()
#    $stderr = $process.StandardError.ReadToEndAsync()
#    if (-not $process.WaitForExit(30000)) {
#      $process.Kill($true)
#      throw "WARP 命令执行超时"
#    }
#    if ($process.ExitCode -ne 0) { throw "WARP 命令失败, 退出码 $($process.ExitCode)" }
#    [void]$stderr.GetAwaiter().GetResult()
#    return $stdout.GetAwaiter().GetResult().Trim()
#  }
#  finally { $process.Dispose() }
#}
#
## 解析实际出口验证结果, 不将 Disconnected 或 IP 变化当作成功.
#function ConvertFrom-WarpTrace {
#  param([string]$Trace)
#  $fields = @{}
#  foreach ($line in ($Trace -split '\r?\n')) {
#    if ($line -match '^([^=]+)=(.*)$') { $fields[$Matches[1]] = $Matches[2] }
#  }
#  if ($fields['warp'] -notin @('on', 'plus') -or [string]::IsNullOrWhiteSpace($fields['ip'])) {
#    throw "WARP 未通过出站验证"
#  }
#  return $fields['ip']
#}
#
## 根据模式验证真实出口, 代理模式使用 HTTP CONNECT 访问 HTTPS 地址.
#function Test-WarpConnection {
#  $mode = Get-WarpMode
#  if ($mode -eq 'off') { return }
#  $request = @{
#    Uri = 'https://www.cloudflare.com/cdn-cgi/trace'
#    TimeoutSec = 15
#  }
#  if ($mode -eq 'proxy') {
#    $request.Proxy = 'http://127.0.0.1:40000'
#  }
#  else { $request.NoProxy = $true }
#  $response = Invoke-WebRequest @request
#  return ConvertFrom-WarpTrace -Trace ([string]$response.Content)
#}
#
## 断开本次作业安装的隧道, 无状态标记时不影响现有系统.
#function Stop-SessionWarp {
#  $state = Get-CiEnv -Name "WINDOWS_WARP_STATE"
#  if ([string]::IsNullOrWhiteSpace($state) -or -not (Test-Path -LiteralPath $state)) { return }
#  Invoke-Warp -Arguments @('disconnect') | Out-Null
#  Remove-Item -LiteralPath $state
#}
#
## 根据模式配置客户端, 在连接前固定本地代理端口.
#function Set-WarpMode {
#  switch (Get-WarpMode) {
#    'off' { return }
#    'proxy' {
#      Invoke-Warp -Arguments @('mode', 'proxy') | Out-Null
#      Invoke-Warp -Arguments @('proxy', 'port', '40000') | Out-Null
#    }
#    'tun' { Invoke-Warp -Arguments @('mode', 'warp') | Out-Null }
#  }
#}
#
## 安装 Cloudflare 签名 MSI, 禁止自动重启 runner.
#function Install-Warp {
#  $existing = Join-Path $env:ProgramFiles "Cloudflare\Cloudflare WARP\warp-cli.exe"
#  if (Test-Path -LiteralPath $existing) { throw "请使用未安装 WARP 的干净 runner" }
#  if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
#    throw "此 WARP 安装入口仅支持 Windows x64"
#  }
#  Write-Step "Installing Cloudflare WARP"
#  $work = Join-Path $env:TEMP ("remotelab-warp-" + [guid]::NewGuid().ToString('N'))
#  New-Item -ItemType Directory -Path $work | Out-Null
#  $package = Join-Path $work 'Cloudflare_WARP.msi'
#  Invoke-WebRequest -Uri 'https://1111-releases.cloudflareclient.com/windows/Cloudflare_WARP_Release-x64.msi' -OutFile $package -TimeoutSec 300
#  $signature = Get-AuthenticodeSignature -FilePath $package
#  if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?i)Cloudflare') {
#    throw "WARP 安装包签名验证失败"
#  }
#  $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$package`"", '/qn', '/norestart') -PassThru
#  try {
#    if (-not $process.WaitForExit(180000)) {
#      $process.Kill($true)
#      throw "WARP 安装超时"
#    }
#    if ($process.ExitCode -eq 3010) { throw "WARP 安装要求重启, 当前临时 runner 无法继续该会话" }
#    if ($process.ExitCode -ne 0) { throw "WARP 安装失败, MSI 退出码 $($process.ExitCode)" }
#  }
#  finally { $process.Dispose() }
#  $env:WINDOWS_WARP_STATE = Join-Path $work 'active'
#  New-Item -ItemType File -Path $env:WINDOWS_WARP_STATE | Out-Null
#  Set-CiEnv -Name WINDOWS_WARP_STATE -Value $env:WINDOWS_WARP_STATE
#  Start-Service -Name 'CloudflareWARP'
#  $registered = $false
#  for ($attempt = 0; $attempt -lt 15; $attempt++) {
#    try {
#      Invoke-Warp -Arguments @('registration', 'new') | Out-Null
#      $registered = $true
#      break
#    }
#    catch { Start-Sleep -Seconds 2 }
#  }
#  if (-not $registered) { throw "WARP 注册失败" }
#  Set-WarpMode
#  Invoke-Warp -Arguments @('connect') | Out-Null
#  for ($attempt = 0; $attempt -lt 18; $attempt++) {
#    try {
#      $warpIp = Test-WarpConnection
#      Set-CiEnv -Name WARP_IP -Value $warpIp
#      Write-Host "WARP 出口已验证: $warpIp"
#      return
#    }
#    catch { Start-Sleep -Seconds 3 }
#  }
#  throw "WARP 未通过出站验证"
#}

# 严格读取代理模式; 沿用 WARP_ENABLED 变量名, 空配置默认启用 Warpscout 代理.
# 已注释的 WARP 代码支持 tun 全局隧道, Warpscout 只提供本地 SOCKS5 代理.
function Get-ProxyMode {
  $value = Get-CiEnv -Name "WARP_ENABLED"
  if ([string]::IsNullOrWhiteSpace($value)) { return 'proxy' }
  if ($value -ceq 'tun') { throw "WARP_ENABLED=tun 依赖已注释的 WARP 代码, 请改用 off 或 proxy" }
  if ($value -cnotin @('off', 'proxy')) { throw "WARP_ENABLED 必须为 off 或 proxy" }
  return $value
}

# 读取 Warpscout 端点扫描使用的国家代码.
function Get-WarpscoutCountry {
  $value = Get-CiEnv -Name "WARPSCOUT_COUNTRY"
  if ([string]::IsNullOrWhiteSpace($value)) { return 'US' }
  return $value
}

# 返回 Warpscout 状态目录, 与 Bash 侧的 ~/.local/state/warpscout 保持一致.
function Get-WarpscoutState {
  return (Join-Path $HOME '.local\state\warpscout')
}

# 生成 Warpscout 压缩包下载地址, 与 docker/desktop 使用同一发行包.
function Get-WarpscoutArchiveUrl {
  param([string]$Version)

  $normalized = $Version.TrimStart('v')
  if ([string]::IsNullOrWhiteSpace($normalized)) { throw "Warpscout 版本不能为空" }
  return "https://github.com/vernette/warpscout/releases/download/v$normalized/warpscout_${normalized}_windows_amd64.zip"
}

# 下载并解压 Warpscout, 返回可执行文件路径.
function Install-Warpscout {
  param([string]$Version)

  $installDir = Join-Path $HOME 'warpscout'
  $exe = Join-Path $installDir 'warpscout.exe'
  if (Test-Path -LiteralPath $exe) { throw "请使用未安装 Warpscout 的干净 runner" }
  if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
    throw "此 Warpscout 安装入口仅支持 Windows x64"
  }
  Write-Step "Installing Warpscout $Version"
  $archive = Join-Path $env:TEMP ("warpscout-" + [guid]::NewGuid().ToString('N') + '.zip')
  try {
    Invoke-WebRequest -Uri (Get-WarpscoutArchiveUrl -Version $Version) -OutFile $archive -TimeoutSec 600
    Expand-Archive -LiteralPath $archive -DestinationPath $installDir -Force
  }
  finally {
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
  }
  if (-not (Test-Path -LiteralPath $exe)) { throw "Warpscout 解压后未找到可执行文件: $exe" }
  & $exe version
  if ($LASTEXITCODE -ne 0) { throw "Warpscout 无法运行, 退出码 $LASTEXITCODE" }
  Set-CiEnv -Name WARPSCOUT_EXE -Value $exe
  return $exe
}

# 注册账号, 扫描端点并在后台启动 Warpscout SOCKS5 代理.
function Start-WarpscoutProxy {
  param([string]$Exe)

  $stateDir = Get-WarpscoutState
  New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
  $accountFile = Join-Path $stateDir 'account.json'
  if (-not (Test-Path -LiteralPath $accountFile)) {
    & $Exe register -a $accountFile
    if ($LASTEXITCODE -ne 0) { throw "Warpscout 注册失败, 退出码 $LASTEXITCODE" }
  }
  $country = Get-WarpscoutCountry
  $scanOutput = & $Exe scan -a $accountFile -p awg -P -country $country -best
  if ($LASTEXITCODE -ne 0) { throw "Warpscout 端点扫描失败, 退出码 $LASTEXITCODE" }
  $endpoint = $scanOutput |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Last 1
  if ([string]::IsNullOrWhiteSpace($endpoint)) { throw "Warpscout 未找到可用端点" }
  $endpoint = ([string]$endpoint).Trim()

  # 固定本地代理端口, 与 docker/desktop 的 socks5://127.0.0.1:40000 保持一致.
  $stdoutPath = Join-Path $stateDir 'proxy.log'
  $stderrPath = Join-Path $stateDir 'proxy-error.log'
  $process = Start-Process `
    -FilePath $Exe `
    -ArgumentList @('socks', '-a', "`"$accountFile`"", '-p', 'awg', '-e', $endpoint, '-l', '127.0.0.1', '-P', '40000') `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -WindowStyle Hidden `
    -PassThru

  Start-Sleep -Seconds 2
  if ($process.HasExited) {
    if (Test-Path -Path $stdoutPath) { Get-Content -Path $stdoutPath -Tail 60 | Write-Host }
    if (Test-Path -Path $stderrPath) { Get-Content -Path $stderrPath -Tail 60 | Write-Host }
    throw "Warpscout 代理启动后立即退出, 退出码 $($process.ExitCode)"
  }
  Set-CiEnv -Name WARPSCOUT_PID -Value ([string]$process.Id)
  Set-CiEnv -Name WARPSCOUT_STATE_DIR -Value $stateDir
  Write-Host "Warpscout proxy started: PID $($process.Id), socks5://127.0.0.1:40000, log=$stdoutPath"
}

# 停止本次作业启动的代理; 无状态记录时不影响现有系统.
function Stop-WarpscoutProxy {
  $pidText = Get-CiEnv -Name "WARPSCOUT_PID"
  if ([string]::IsNullOrWhiteSpace($pidText)) { return }
  $proxyPid = 0
  if (-not [int]::TryParse($pidText, [ref]$proxyPid) -or $proxyPid -le 0) {
    throw 'Invalid WARPSCOUT_PID'
  }
  $process = Get-Process -Id $proxyPid -ErrorAction SilentlyContinue
  if (-not $process) { return }
  if ($process.ProcessName -ne 'warpscout') {
    throw "WARPSCOUT_PID 不属于 Warpscout 进程: $($process.ProcessName)"
  }
  Stop-Process -Id $proxyPid
  for ($attempt = 0; $attempt -lt 50; $attempt++) {
    if (-not (Get-Process -Id $proxyPid -ErrorAction SilentlyContinue)) {
      Write-Host "Warpscout proxy stopped: PID $proxyPid"
      return
    }
    Start-Sleep -Milliseconds 100
  }
  throw "Warpscout 代理未在 5 秒内停止: PID $proxyPid"
}

# 解析实际出口验证结果, 不将 Disconnected 或 IP 变化当作成功.
function ConvertFrom-ProxyTrace {
  param([string]$Trace)
  $fields = @{}
  foreach ($line in ($Trace -split '\r?\n')) {
    if ($line -match '^([^=]+)=(.*)$') { $fields[$Matches[1]] = $Matches[2] }
  }
  if ($fields['warp'] -notin @('on', 'plus') -or [string]::IsNullOrWhiteSpace($fields['ip'])) {
    throw "Warpscout 未通过出站验证"
  }
  return $fields['ip']
}

# 经本地 SOCKS5 代理验证真实出口; 关闭模式直接返回.
function Test-WarpscoutConnection {
  $mode = Get-ProxyMode
  if ($mode -eq 'off') { return }
  $arguments = @(
    '--fail', '--silent', '--show-error',
    '--proxy', 'socks5h://127.0.0.1:40000',
    '--connect-timeout', '5', '--max-time', '10',
    'https://www.cloudflare.com/cdn-cgi/trace'
  )
  $trace = ((& curl.exe @arguments) -join "`n")
  if ($LASTEXITCODE -ne 0) { throw "Warpscout 代理未通过出站验证, curl 退出码 $LASTEXITCODE" }
  return ConvertFrom-ProxyTrace -Trace $trace
}

# 将虚拟环境激活段写入 Git Bash 和 zsh 启动文件.
function Add-VenvActivationToShellProfiles {
  param([string]$ProfilePath)

  $marker = '# remote-desktop managed virtual environment'
  $block = @'

# remote-desktop managed virtual environment
remote_desktop_venv="$(cygpath -u '__PYTHON_ENV_PATH__')"
if [ -r "$remote_desktop_venv/Scripts/activate" ]; then
  . "$remote_desktop_venv/Scripts/activate"
elif [ -r "$remote_desktop_venv/bin/activate" ]; then
  . "$remote_desktop_venv/bin/activate"
fi
unset remote_desktop_venv
'@
  # 对路径中的单引号做 Bash 转义, 将安装路径直接写入启动文件.
  $escapedPath = (Get-VenvDir).Replace("'", "'" + [char]92 + "''")
  $block = $block.Replace('__PYTHON_ENV_PATH__', $escapedPath)
  $utf8 = [System.Text.UTF8Encoding]::new($false)
  foreach ($name in @('.bash_profile', '.bashrc', '.zshenv')) {
    $path = Join-Path $ProfilePath $name
    $existing = if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path) } else { '' }
    if (-not $existing.Contains($marker)) {
      [IO.File]::AppendAllText($path, $block, $utf8)
    }
  }
}

# 将流水线传入的变量写入目标用户终端环境, 供下次桌面登录继承.
function Set-DesktopEnvironment {
  param([string]$UserName)

  Write-Step 'Configuring Windows desktop environment variables'
  $account = Get-LocalUser -Name $UserName -ErrorAction Stop
  $profileKey = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($account.SID.Value)"
  $profilePath = [Environment]::ExpandEnvironmentVariables((Get-ItemPropertyValue -LiteralPath $profileKey -Name ProfileImagePath))
  $userKey = [Microsoft.Win32.Registry]::Users.OpenSubKey($account.SID.Value, $true)
  if ($null -eq $userKey) { throw "The user registry hive is not loaded for: $UserName" }
  try {
    $environmentKey = $userKey.CreateSubKey('Environment')
    try {
      foreach ($name in @('KRYVA_API_KEY', 'KRYVA_API_URL')) {
        $value = Get-CiEnv -Name $name
        if ([string]::IsNullOrEmpty($value)) {
          $environmentKey.DeleteValue($name, $false)
        }
        else {
          # 使用普通字符串类型, 避免配置中的百分号被注册表当作变量展开.
          $environmentKey.SetValue($name, $value, [Microsoft.Win32.RegistryValueKind]::String)
        }
      }
    }
    finally { $environmentKey.Dispose() }
  }
  finally { $userKey.Dispose() }
  Add-VenvActivationToShellProfiles -ProfilePath $profilePath
  Write-Host "Desktop environment configured for $UserName`: KRYVA_API_KEY, KRYVA_API_URL. Sign out and sign in again to update an existing desktop session."
}

# 安装桌面环境前确定代理模式, 使随后启动的 Tunnel 和 Warpscout 使用稳定的出口.
function Install-WindowsDesktop {
  $proxyMode = Get-ProxyMode
  $cloudflaredToken = Get-CiEnv -Name "CLOUDFLARED_TOKEN"
  $cloudflaredTunnelUrl = Get-CiEnv -Name "CLOUDFLARED_TUNNEL_URL"
  if ([string]::IsNullOrWhiteSpace($cloudflaredTunnelUrl)) {
    $cloudflaredTunnelUrl = "rdp://127.0.0.1:3389"
  }
  $password = Require-Env "PASSWORD"
  $resolvedRunnerUser = Resolve-RunnerUser -ConfiguredUser $RunnerUser
  # [已停用] WARP 安装已由 Warpscout 安装取代, 保留以便恢复.
  #if ($warpMode -ne 'off') { Install-Warp }
  Install-PythonApp
  Set-DesktopEnvironment -UserName $resolvedRunnerUser
  Enable-RemoteDesktop -UserName $resolvedRunnerUser -Password $password
  $cloudflaredPath = Install-Cloudflared `
    -Version $CloudflaredVersion `
    -DestinationDir $InstallDir

  Set-CiEnv -Name "CLOUDFLARED_EXE" -Value $cloudflaredPath
  Set-CiEnv -Name "RUNNER_USER" -Value $resolvedRunnerUser
  Start-Cloudflared `
    -Binary $cloudflaredPath `
    -Token $cloudflaredToken `
    -TunnelUrl $cloudflaredTunnelUrl

  if ($proxyMode -ne 'off') {
    $warpscoutPath = Install-Warpscout -Version 'v0.16.0'
    Start-WarpscoutProxy -Exe $warpscoutPath
    $egressIp = $null
    for ($attempt = 0; $attempt -lt 18; $attempt++) {
      try {
        $egressIp = Test-WarpscoutConnection
        break
      }
      catch {
        if ($attempt -eq 17) { throw }
        Start-Sleep -Seconds 3
      }
    }
    Set-CiEnv -Name WARP_IP -Value $egressIp
    Write-Host "Warpscout 出口已验证: $egressIp"
  }

  Write-Step "Windows install and startup complete"
  Write-Step 'Installation paths'
  Write-Host "SCRIPT_DIR: $PSScriptRoot"
  Write-Host "Python environment: $(Get-VenvDir)"
}

# 点加载仅提供函数, 便于在不修改系统的条件下验证配置与错误处理.
if ($MyInvocation.InvocationName -ne '.') {
  switch ($Action) {
    'Setup' {
      try { Install-WindowsDesktop }
      catch {
        # [已停用] WARP 清理已由 Warpscout 代理停止取代, 保留以便恢复.
        #try { Stop-SessionWarp } catch { Write-Warning "WARP 清理失败, 后续 Cleanup 步骤将重试" }
        try { Stop-WarpscoutProxy } catch { Write-Warning "Warpscout 代理清理失败, 后续 Cleanup 步骤将重试" }
        throw
      }
    }
    'Check' { Test-WindowsSession }
    'Cleanup' { Stop-WarpscoutProxy }
  }
}
