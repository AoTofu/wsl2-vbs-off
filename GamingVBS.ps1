#Requires -Version 5.1
<#
.SYNOPSIS
  WSL2 を使えるまま、VBS（仮想化ベースのセキュリティ）とメモリ整合性のオーバーヘッドを外す設定を
  一括で「適用 / 確認 / 元に戻す」スクリプト。

.DESCRIPTION
  適用後の状態
    ハイパーバイザー        : 起動する（WSL2 / 仮想マシン プラットフォームが使える）
    VBS（セキュアカーネル）  : 停止
    メモリ整合性（HVCI）     : 停止

  変更するもの
    HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard 以下の値
    BCD の hypervisorlaunchtype（Auto にする）
    Windows の機能「仮想マシン プラットフォーム」（無効なら有効化。-SkipVMP で省略）

  初回の適用時に元の状態を %ProgramData%\GamingVBS\Backup に保存し、-Mode Undo で戻せます。

.PARAMETER Mode
  Apply（既定）: 設定を適用する
  Verify       : 今の状態を確認する（再起動後に実行）
  Undo         : 適用前の状態に戻す

.PARAMETER SkipVMP
  仮想マシン プラットフォームを有効にしない（WSL2 を使わない PC 向け）

.NOTES
  セキュリティ機能を弱める設定です。自己責任で使ってください。
  VBS や Credential Guard が UEFI ロック付きで有効になっている PC（企業の管理 PC、一部の Secured-core PC）や、
  グループポリシーで VBS が強制されている PC では効きません。
#>
param(
    [ValidateSet('Apply', 'Verify', 'Undo')]
    [string]$Mode = 'Apply',
    [switch]$SkipVMP
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 管理者でなければ、管理者として自分を起動し直す
# ---------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Mode', $Mode)
    if ($SkipVMP) { $argList += '-SkipVMP' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    exit
}

# ---------------------------------------------------------------------------
# 定数
# ---------------------------------------------------------------------------
$DG        = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'
$DGNative  = 'HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard'
$Scen      = "$DG\Scenarios"
$DGPolicy  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard'
$Lsa       = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
$BackupDir = Join-Path $env:ProgramData 'GamingVBS\Backup'
$StateFile = Join-Path $BackupDir 'state.json'
$RegFile   = Join-Path $BackupDir 'DeviceGuard.reg'

# ---------------------------------------------------------------------------
# 補助関数
# ---------------------------------------------------------------------------
function Write-Step([string]$Text) {
    Write-Host ""
    Write-Host "== $Text ==" -ForegroundColor Cyan
}

function Set-Dword([string]$Path, [string]$Name, [int]$Value) {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
    $short = $Path -replace '^HKLM:\\SYSTEM\\CurrentControlSet\\Control\\', ''
    Write-Host ("  {0}\{1} = {2}" -f $short, $Name, $Value)
}

# Get-ItemProperty -Name は環境によって値を取りこぼすことがあるので、キーから直接読む
function Get-RegValue([string]$Path, [string]$Name) {
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $key) { return $null }
    return $key.GetValue($Name, $null)
}

# reg.exe は成功メッセージを標準エラーに出すので、別プロセスで実行して終了コードだけを見る
function Invoke-Reg([string[]]$Arguments) {
    $out = [IO.Path]::GetTempFileName()
    $err = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath 'reg.exe' -ArgumentList $Arguments -Wait -PassThru -NoNewWindow `
                           -RedirectStandardOutput $out -RedirectStandardError $err
        return $p.ExitCode
    } finally {
        Remove-Item $out, $err -Force -ErrorAction SilentlyContinue
    }
}

function Get-HvLaunchType {
    $m = (& bcdedit.exe /enum '{current}') | Select-String -Pattern '^\s*hypervisorlaunchtype\s+(\S+)'
    if ($m) { return $m.Matches[0].Groups[1].Value }
    return 'NotSet'
}

function Get-VmpState {
    try { return (Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform).State.ToString() }
    catch { return 'Unknown' }
}

function Get-DeviceGuard {
    Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
}

function Get-LastVbsBootEvent {
    Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Boot'; Id = 153 } `
                 -MaxEvents 1 -ErrorAction SilentlyContinue
}

function New-Check([string]$Item, $Current, [string]$Expected) {
    $cur = "$Current"
    if ($null -eq $Current) { $cur = '(なし)' }
    [pscustomobject]@{
        判定 = $(if ($cur -eq $Expected) { 'OK' } else { 'NG' })
        項目 = $Item
        現在 = $cur
        期待 = $Expected
    }
}

function Ask-Restart {
    $ans = Read-Host '今すぐ再起動しますか？ (y/N)'
    if ($ans -match '^[yY]') { Restart-Computer -Force }
}

# ---------------------------------------------------------------------------
# 適用
# ---------------------------------------------------------------------------
function Invoke-Apply {
    Write-Host 'WSL2 を使えるまま VBS とメモリ整合性を止める設定を適用します。' -ForegroundColor Green
    Write-Host 'セキュリティ機能を弱める設定なので、理解したうえで使ってください。' -ForegroundColor Yellow

    Write-Step '1/4 元の状態をバックアップ'
    if (Test-Path $StateFile) {
        Write-Host "  前回のバックアップがあるので、それを残します: $BackupDir"
    } else {
        New-Item -Path $BackupDir -ItemType Directory -Force | Out-Null
        $hadKey = Test-Path $DG
        if ($hadKey) {
            $code = Invoke-Reg @('export', "`"$DGNative`"", "`"$RegFile`"", '/y')
            if ($code -ne 0) { throw "DeviceGuard キーのバックアップに失敗しました（reg.exe 終了コード $code）。" }
        }
        & bcdedit.exe /export (Join-Path $BackupDir 'bcd.bak') | Out-Null
        $state = [ordered]@{
            Date                   = (Get-Date).ToString('s')
            Build                  = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
            HadDeviceGuardKey      = $hadKey
            HypervisorLaunchType   = Get-HvLaunchType
            VirtualMachinePlatform = Get-VmpState
            LsaCfgFlags            = Get-RegValue $Lsa 'LsaCfgFlags'
        }
        $state | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
        Write-Host "  保存先: $BackupDir"
    }

    Write-Step '2/4 VBS とメモリ整合性を止める（ハイパーバイザーは残す）'
    Set-Dword $DG 'EnableVirtualizationBasedSecurity' 0
    Set-Dword $DG 'HyperVVirtualizationBasedSecurityOptout' 1      # ハイパーバイザー起動時に VBS を自動で有効にしない
    Set-Dword "$Scen\HypervisorEnforcedCodeIntegrity" 'Enabled' 0  # メモリ整合性（HVCI）
    Set-Dword "$Scen\WindowsHello" 'Enabled' 0                     # Windows Hello の VBS 保護（24H2 以降、これが VBS を起動する）
    Set-Dword "$Scen\KernelShadowStacks" 'Enabled' 0               # カーネルのシャドウスタック（HVCI が前提）
    if (Test-Path "$Scen\CredentialGuard") { Set-Dword "$Scen\CredentialGuard" 'Enabled' 0 }
    if ($null -ne (Get-RegValue $Lsa 'LsaCfgFlags')) { Set-Dword $Lsa 'LsaCfgFlags' 0 }

    if ((Get-RegValue "$Scen\HypervisorEnforcedCodeIntegrity" 'Locked') -eq 1) {
        Write-Warning 'メモリ整合性が UEFI ロックされています。レジストリだけでは止まらない可能性があります。'
    }
    if (Test-Path $DGPolicy) {
        $pol = Get-ItemProperty $DGPolicy
        if ($pol.EnableVirtualizationBasedSecurity -eq 1) {
            Write-Warning 'グループポリシーで VBS が有効にされています（HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard）。ポリシー側も無効にしないと VBS は止まりません。'
        }
    }

    Write-Step '3/4 ハイパーバイザーを自動起動にする（WSL2 用）'
    & bcdedit.exe /set '{current}' hypervisorlaunchtype auto | Out-Null
    Write-Host "  hypervisorlaunchtype = $(Get-HvLaunchType)"

    Write-Step '4/4 仮想マシン プラットフォーム（WSL2 に必要）'
    if ($SkipVMP) {
        Write-Host '  -SkipVMP が指定されたので変更しません。'
    } elseif ((Get-VmpState) -eq 'Enabled') {
        Write-Host '  すでに有効です。'
    } else {
        Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart | Out-Null
        Write-Host '  有効にしました（再起動後に反映されます）。'
    }

    Write-Host ""
    Write-Host '完了しました。再起動したあとに Verify.cmd で状態を確認してください。' -ForegroundColor Green
    Ask-Restart
}

# ---------------------------------------------------------------------------
# 確認
# ---------------------------------------------------------------------------
function Invoke-Verify {
    $dgInfo = Get-DeviceGuard
    $cs  = Get-CimInstance Win32_ComputerSystem
    $vbs = -1
    $hvciRunning = $false
    if ($dgInfo) {
        $vbs = [int]$dgInfo.VirtualizationBasedSecurityStatus
        $hvciRunning = (@($dgInfo.SecurityServicesRunning) -contains 2)
    }
    $vmp = Get-VmpState

    $rows = @(
        (New-Check 'ハイパーバイザー（WSL2 用）'        $cs.HypervisorPresent 'True'),
        (New-Check 'VBS（0=停止 2=実行中）'             $vbs                  '0'),
        (New-Check 'メモリ整合性（HVCI）実行中'         $hvciRunning          'False'),
        (New-Check 'hypervisorlaunchtype'               (Get-HvLaunchType)    'Auto'),
        (New-Check '仮想マシン プラットフォーム'        $vmp                  'Enabled'),
        (New-Check 'レジストリ: HyperV opt-out'         (Get-RegValue $DG 'HyperVVirtualizationBasedSecurityOptout') '1'),
        (New-Check 'レジストリ: WindowsHello'           (Get-RegValue "$Scen\WindowsHello" 'Enabled') '0'),
        (New-Check 'レジストリ: HVCI'                   (Get-RegValue "$Scen\HypervisorEnforcedCodeIntegrity" 'Enabled') '0')
    )

    $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

    $ng = @($rows | Where-Object { $_.判定 -eq 'NG' })
    if ($ng.Count -eq 0) {
        Write-Host 'ゲーム特化（WSL2 使用可）の状態になっています。' -ForegroundColor Green
    } else {
        Write-Host '期待と違う項目があります。' -ForegroundColor Yellow
        Write-Host '  - 適用後にまだ再起動していないなら、再起動してからもう一度確認してください。'
        if (($vbs -eq 0) -and $cs.HypervisorPresent) {
            Write-Host '  - VBS は停止しハイパーバイザーも動いているので、実際の動作は目的どおりです。'
        }
        if ($vmp -ne 'Enabled') {
            Write-Host '  - WSL2 を使わない（-SkipVMP）なら、ハイパーバイザーと仮想マシン プラットフォームの NG は問題ありません。'
        }
        if ($vbs -eq 2) {
            Write-Host '  - VBS が動いています。下の「起動時の記録」に、VBS が有効になった理由が出ます。'
        }
    }

    $ev = Get-LastVbsBootEvent
    if ($ev) {
        Write-Host ""
        Write-Host "起動時の記録（$($ev.TimeCreated)）:"
        Write-Host "  $($ev.Message)"
    }
    Write-Host ""
    Write-Host 'Windows の大型アップデートのあとは、設定が戻っていないかこの確認をもう一度実行してください。'
    Read-Host 'Enter キーで閉じます' | Out-Null
}

# ---------------------------------------------------------------------------
# 元に戻す
# ---------------------------------------------------------------------------
function Invoke-Undo {
    if (-not (Test-Path $StateFile)) { throw "バックアップが見つかりません: $BackupDir" }
    $state = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host "適用前（$($state.Date)）の状態に戻します。" -ForegroundColor Green

    Write-Step '1/3 DeviceGuard の設定を戻す'
    if ($state.HadDeviceGuardKey -and (Test-Path $RegFile)) {
        Invoke-Reg @('delete', "`"$DGNative`"", '/f') | Out-Null
        $code = Invoke-Reg @('import', "`"$RegFile`"")
        if ($code -ne 0) { throw "レジストリの復元に失敗しました（reg.exe 終了コード $code）。$RegFile を手動で取り込んでください。" }
        Write-Host '  バックアップから復元しました。'
    } elseif (-not $state.HadDeviceGuardKey) {
        Invoke-Reg @('delete', "`"$DGNative`"", '/f') | Out-Null
        Write-Host '  元はキーがなかったので削除しました（Windows が既定値で作り直します）。'
    }
    if ($null -ne $state.LsaCfgFlags) { Set-Dword $Lsa 'LsaCfgFlags' ([int]$state.LsaCfgFlags) }

    Write-Step '2/3 hypervisorlaunchtype を戻す'
    if ($state.HypervisorLaunchType -eq 'NotSet') {
        & bcdedit.exe /deletevalue '{current}' hypervisorlaunchtype | Out-Null
    } else {
        & bcdedit.exe /set '{current}' hypervisorlaunchtype $state.HypervisorLaunchType | Out-Null
    }
    Write-Host "  hypervisorlaunchtype = $(Get-HvLaunchType)"

    Write-Step '3/3 仮想マシン プラットフォーム'
    if (("$($state.VirtualMachinePlatform)" -like 'Disabled*') -and ((Get-VmpState) -eq 'Enabled')) {
        Disable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart | Out-Null
        Write-Host '  元は無効だったので、無効に戻しました。'
    } else {
        Write-Host '  変更しません。'
    }

    # 次に適用するときに新しくバックアップを取れるよう、使い終わったバックアップは名前を変えて残す
    $done = "$BackupDir`_undone_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Rename-Item -Path $BackupDir -NewName (Split-Path $done -Leaf)
    Write-Host "  使ったバックアップは $done に残しました。"

    Write-Host ""
    Write-Host '元に戻しました。再起動すると反映されます。' -ForegroundColor Green
    Ask-Restart
}

# ---------------------------------------------------------------------------
# 実行
# ---------------------------------------------------------------------------
try {
    switch ($Mode) {
        'Apply'  { Invoke-Apply }
        'Verify' { Invoke-Verify }
        'Undo'   { Invoke-Undo }
    }
} catch {
    Write-Host ""
    Write-Host "エラー: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host 'Enter キーで閉じます' | Out-Null
    exit 1
}
