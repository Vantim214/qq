#Requires -Version 5.1
<#
    Налаштування ігрового ПК після переустановки Windows.
    7800X3D · RTX 5070 · B650 AORUS ELITE AX V2 · Windows 11 Pro

    Що робить:
      * перевіряє поточний стан (нічого не змінює);
      * виставляє ті самі налаштування, що й у «Параметрах» Windows,
        і перед кожною зміною питає дозволу;
      * ставить програми через winget з офіційних джерел;
      * відкриває офіційні сайти для того, що треба качати руками.

    Чого НЕ робить: твіків реєстру «для FPS», вимкнення служб, Defender,
    Memory Integrity, C-states, файлу підкачки, ручних напруг.

    Запуск: START.cmd (сам попросить права адміністратора).
#>

param([switch]$CheckOnly)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$Host.UI.RawUI.WindowTitle = 'Налаштування ігрового ПК'

# ---------------------------------------------------------------- адмін-права
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Потрібні права адміністратора. Зараз Windows попросить дозвіл...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($CheckOnly) { $argList += '-CheckOnly' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
    exit
}

$ScriptDir = Split-Path -Parent $PSCommandPath
$LogDir = Join-Path $ScriptDir 'logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$LogFile = Join-Path $LogDir ('zmin-' + (Get-Date -Format 'yyyy-MM-dd_HH-mm') + '.txt')

# ---------------------------------------------------------------- WinAPI
if (-not ('PcSetup.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace PcSetup {
    public static class Native {
        [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
        public static extern bool SpiGetInt(uint action, uint param, ref int value, uint winIni);

        [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
        public static extern bool SpiSetPtr(uint action, uint param, IntPtr value, uint winIni);

        [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
        public static extern bool SpiArray(uint action, uint param, [In, Out] int[] value, uint winIni);

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT { public int Left, Top, Right, Bottom; }

        [StructLayout(LayoutKind.Sequential)]
        public struct APPBARDATA {
            public int cbSize;
            public IntPtr hWnd;
            public uint uCallbackMessage;
            public uint uEdge;
            public RECT rc;
            public IntPtr lParam;
        }

        [DllImport("shell32.dll")]
        public static extern UIntPtr SHAppBarMessage(uint msg, ref APPBARDATA data);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr FindWindow(string cls, string title);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, UIntPtr wParam, string lParam,
                                                       uint flags, uint timeout, out UIntPtr result);

        public static int GetTaskbarState() {
            APPBARDATA d = new APPBARDATA();
            d.cbSize = Marshal.SizeOf(typeof(APPBARDATA));
            d.hWnd = FindWindow("Shell_TrayWnd", null);
            return (int)SHAppBarMessage(4, ref d).ToUInt32();       // ABM_GETSTATE
        }

        public static void SetTaskbarState(int state) {
            APPBARDATA d = new APPBARDATA();
            d.cbSize = Marshal.SizeOf(typeof(APPBARDATA));
            d.hWnd = FindWindow("Shell_TrayWnd", null);
            d.lParam = (IntPtr)state;
            SHAppBarMessage(10, ref d);                              // ABM_SETSTATE
        }

        public static void BroadcastSettingChange(string area) {
            UIntPtr r;
            SendMessageTimeout((IntPtr)0xffff, 0x001A, UIntPtr.Zero, area, 0x0002, 3000, out r);
        }
    }
}
'@
}

# SystemParametersInfo
$SPI_GETMOUSE = 0x0003; $SPI_SETMOUSE = 0x0004
$SPI_GETMOUSESPEED = 0x0070; $SPI_SETMOUSESPEED = 0x0071
$SPIF_SAVE = 0x01 -bor 0x02   # UPDATEINIFILE | SENDCHANGE — так само, як робить панель керування

$GUID_BALANCED = '381b4222-f694-41f0-9665-5b5bb12a0b6d'

# ---------------------------------------------------------------- допоміжне
function Write-Log([string]$text) {
    $line = (Get-Date -Format 'HH:mm:ss') + '  ' + $text
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Write-Title([string]$text) {
    Write-Host ''
    Write-Host ('  ' + $text) -ForegroundColor Cyan
    Write-Host ('  ' + ('─' * $text.Length)) -ForegroundColor DarkCyan
}

function Write-Status([string]$state, [string]$name, [string]$detail) {
    switch ($state) {
        'ok'   { $mark = '  [ OK ] '; $color = 'Green' }
        'bad'  { $mark = '  [ !! ] '; $color = 'Red' }
        'warn' { $mark = '  [ ?? ] '; $color = 'Yellow' }
        default { $mark = '  [ -- ] '; $color = 'Gray' }
    }
    Write-Host $mark -ForegroundColor $color -NoNewline
    Write-Host $name -NoNewline
    if ($detail) { Write-Host ('  →  ' + $detail) -ForegroundColor DarkGray } else { Write-Host '' }
}

$script:YesToAll = $false
function Confirm-Change([string]$question) {
    if ($script:YesToAll) { return $true }
    while ($true) {
        Write-Host ('      ' + $question) -ForegroundColor White
        $a = Read-Host '      [Т] так   [Н] ні   [В] так для всіх наступних'
        switch -Regex ($a.Trim().ToLower()) {
            '^(т|t|y|д|так|yes)$' { return $true }
            '^(н|n|ні|no)$'       { return $false }
            '^(в|v|a|all)$'       { $script:YesToAll = $true; return $true }
        }
    }
}

function Get-Reg([string]$path, [string]$name) {
    try {
        $item = Get-ItemProperty -Path $path -Name $name -ErrorAction Stop
        return $item.$name
    } catch { return $null }
}

function Set-Reg([string]$path, [string]$name, $value, [string]$type = 'DWord') {
    $old = Get-Reg $path $name
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    New-ItemProperty -Path $path -Name $name -Value $value -PropertyType $type -Force | Out-Null
    $oldText = if ($null -eq $old) { '(не було)' } else { "$old" }
    Write-Log ("REG  $path\$name : $oldText  ->  $value")
}

function Pause-Key {
    Write-Host ''
    Read-Host '  Натисни Enter, щоб повернутись у меню' | Out-Null
}

# DirectXUserGlobalSettings: рядок "Ключ=Значення;Ключ=Значення;"
$DX_PATH = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
function Get-DxSettings {
    $map = [ordered]@{}
    $raw = Get-Reg $DX_PATH 'DirectXUserGlobalSettings'
    if ($raw) {
        foreach ($pair in ($raw -split ';')) {
            if ($pair -match '^\s*([^=]+)=(.*)$') { $map[$Matches[1].Trim()] = $Matches[2].Trim() }
        }
    }
    return $map
}
function Set-DxSetting([string]$key, [string]$value) {
    $map = Get-DxSettings
    $map[$key] = $value
    $text = (($map.Keys | ForEach-Object { "$_=$($map[$_])" }) -join ';') + ';'
    Set-Reg $DX_PATH 'DirectXUserGlobalSettings' $text 'String'
}

# Шкала швидкості миші: 11 поділок у «Параметрах вказівника» ↔ значення 1..20
function Convert-MouseSpeedToTick([int]$v) {
    if ($v -le 2) { return $v }
    return [int][math]::Floor($v / 2) + 1
}

function Get-MonitorTimeoutAC {
    $out = (powercfg /q SCHEME_CURRENT SUB_VIDEO VIDEOIDLE) -join "`n"
    $hex = [regex]::Matches($out, '0x[0-9a-fA-F]{8}')
    # Порядок: мінімум, максимум, крок, потім індекс AC, потім DC
    if ($hex.Count -ge 4) { return [Convert]::ToInt32($hex[3].Value, 16) }
    return $null
}

function Get-ActiveScheme {
    $out = (powercfg /getactivescheme) -join ' '
    if ($out -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s*\((.+)\)') {
        return @{ Guid = $Matches[1].ToLower(); Name = $Matches[2] }
    }
    return @{ Guid = ''; Name = $out }
}

function Get-BootMgr {
    $out = (bcdedit /enum '{bootmgr}') -join "`n"
    $menu = $null; $timeout = $null
    if ($out -match '(?im)^\s*displaybootmenu\s+(\S+)') { $menu = $Matches[1] }
    if ($out -match '(?im)^\s*timeout\s+(\d+)') { $timeout = [int]$Matches[1] }
    return @{ Menu = $menu; Timeout = $timeout }
}

# ---------------------------------------------------------------- налаштування
# Кожен пункт: Group, Name, Want (що має бути), Check -> @{ Ok; Now }, Apply
$Settings = @(
    @{
        Group = 'Миша і завантаження'
        Name  = 'Швидкість вказівника 6/11'
        Want  = '6 з 11 (значення 10, стандарт Windows)'
        Check = {
            [int]$v = 0
            [void][PcSetup.Native]::SpiGetInt($SPI_GETMOUSESPEED, 0, [ref]$v, 0)
            @{ Ok = ($v -eq 10); Now = ('{0}/11 (значення {1})' -f (Convert-MouseSpeedToTick $v), $v) }
        }
        Apply = {
            [void][PcSetup.Native]::SpiSetPtr($SPI_SETMOUSESPEED, 0, [IntPtr]10, $SPIF_SAVE)
            Write-Log 'SPI  швидкість миші -> 10 (6/11)'
        }
    },
    @{
        Group = 'Миша і завантаження'
        Name  = '«Підвищена точність вказівника»'
        Want  = 'вимкнено'
        Check = {
            $arr = New-Object int[] 3
            [void][PcSetup.Native]::SpiArray($SPI_GETMOUSE, 0, $arr, 0)
            @{ Ok = ($arr[2] -eq 0); Now = $(if ($arr[2] -eq 0) { 'вимкнено' } else { 'увімкнено' }) }
        }
        Apply = {
            $arr = [int[]](0, 0, 0)
            [void][PcSetup.Native]::SpiArray($SPI_SETMOUSE, 0, $arr, $SPIF_SAVE)
            Write-Log 'SPI  підвищена точність вказівника -> вимк.'
        }
    },
    @{
        Group = 'Миша і завантаження'
        Name  = 'Текстове меню завантаження Windows'
        Want  = 'не показувати, таймаут 3 с'
        Check = {
            $b = Get-BootMgr
            $menuOk = ($null -eq $b.Menu) -or ($b.Menu -match '^(No|Ні)$')
            $menuTxt = if ($null -eq $b.Menu) { 'за замовчуванням' } else { $b.Menu }
            @{ Ok = ($menuOk -and $b.Timeout -eq 3); Now = "displaybootmenu: $menuTxt, timeout: $($b.Timeout)" }
        }
        Apply = {
            $b = Get-BootMgr
            bcdedit /set '{bootmgr}' displaybootmenu no | Out-Null
            bcdedit /timeout 3 | Out-Null
            Write-Log "BCD  displaybootmenu $($b.Menu) -> no; timeout $($b.Timeout) -> 3"
        }
    },
    @{
        Group = 'Ігрові налаштування'
        Name  = 'Ігровий режим (Game Mode)'
        Want  = 'увімкнено'
        Check = {
            $v = Get-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled'
            @{ Ok = ($null -eq $v -or $v -eq 1); Now = $(if ($v -eq 0) { 'вимкнено' } elseif ($null -eq $v) { 'увімкнено (стандарт)' } else { 'увімкнено' }) }
        }
        Apply = { Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1 }
    },
    @{
        Group = 'Ігрові налаштування'
        Name  = 'Фоновий запис Game Bar («Записати те, що сталося»)'
        Want  = 'вимкнено'
        Check = {
            $v = Get-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'HistoricalCaptureEnabled'
            @{ Ok = ($v -ne 1); Now = $(if ($v -eq 1) { 'увімкнено' } else { 'вимкнено' }) }
        }
        Apply = { Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'HistoricalCaptureEnabled' 0 }
    },
    @{
        Group = 'Ігрові налаштування'
        Name  = 'Апаратне планування GPU (HAGS)'
        Want  = 'увімкнено (після перезавантаження)'
        Check = {
            $v = Get-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
            $now = switch ($v) { 2 { 'увімкнено' } 1 { 'вимкнено' } default { 'за замовчуванням драйвера' } }
            @{ Ok = ($v -eq 2); Now = $now }
        }
        Apply = { Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2; $script:NeedReboot = $true }
    },
    @{
        Group = 'Ігрові налаштування'
        Name  = 'Оптимізації для віконних ігор'
        Want  = 'увімкнено'
        Check = {
            $m = Get-DxSettings
            @{ Ok = ($m['SwapEffectUpgradeEnable'] -eq '1'); Now = $(if ($m['SwapEffectUpgradeEnable'] -eq '1') { 'увімкнено' } else { 'вимкнено / не задано' }) }
        }
        Apply = { Set-DxSetting 'SwapEffectUpgradeEnable' '1' }
    },
    @{
        Group = 'Ігрові налаштування'
        Name  = 'Змінна частота оновлення (VRR)'
        Want  = 'увімкнено'
        Check = {
            $m = Get-DxSettings
            @{ Ok = ($m['VRROptimizeEnable'] -eq '1'); Now = $(if ($m['VRROptimizeEnable'] -eq '1') { 'увімкнено' } else { 'вимкнено / не задано' }) }
        }
        Apply = { Set-DxSetting 'VRROptimizeEnable' '1' }
    },
    @{
        Group = 'Вигляд і OLED'
        Name  = 'Темна тема (Windows і програми)'
        Want  = 'темна'
        Check = {
            $p = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
            $a = Get-Reg $p 'AppsUseLightTheme'; $s = Get-Reg $p 'SystemUsesLightTheme'
            @{ Ok = ($a -eq 0 -and $s -eq 0); Now = ('програми: {0}, система: {1}' -f $(if ($a -eq 0) { 'темна' } else { 'світла' }), $(if ($s -eq 0) { 'темна' } else { 'світла' })) }
        }
        Apply = {
            $p = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
            Set-Reg $p 'AppsUseLightTheme' 0
            Set-Reg $p 'SystemUsesLightTheme' 0
            [PcSetup.Native]::BroadcastSettingChange('ImmersiveColorSet')
        }
    },
    @{
        Group = 'Вигляд і OLED'
        Name  = 'Автоматично приховувати панель завдань'
        Want  = 'увімкнено'
        Check = {
            $st = [PcSetup.Native]::GetTaskbarState()
            @{ Ok = (($st -band 1) -eq 1); Now = $(if (($st -band 1) -eq 1) { 'приховується' } else { 'завжди видно' }) }
        }
        Apply = {
            [PcSetup.Native]::SetTaskbarState(1)
            Start-Sleep -Milliseconds 500
            if (([PcSetup.Native]::GetTaskbarState() -band 1) -eq 1) {
                Write-Log 'TASKBAR  автоприховування -> увімк.'
            } else {
                # Запасний варіант: той самий прапорець, який пише «Параметри», + перезапуск Провідника
                $p = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3'
                $v = Get-Reg $p 'Settings'
                if ($v) {
                    Write-Host '      Потрібно перезапустити Провідник (панель завдань моргне).' -ForegroundColor Yellow
                    if (Confirm-Change 'Перезапустити Провідник?') {
                        $v[8] = 3
                        Set-ItemProperty -Path $p -Name 'Settings' -Value $v
                        Write-Log 'TASKBAR  StuckRects3[8] -> 3 (автоприховування), перезапуск explorer'
                        Stop-Process -Name explorer -Force
                    }
                } else {
                    Write-Host '      Не вийшло. Зроби вручну: Параметри → Персоналізація → Панель завдань → Поведінка.' -ForegroundColor Yellow
                }
            }
        }
    },
    @{
        Group = 'Вигляд і OLED'
        Name  = 'Вимикати екран через 5 хв (захист OLED)'
        Want  = '5 хв'
        Check = {
            $s = Get-MonitorTimeoutAC
            $now = if ($null -eq $s) { 'не вдалося прочитати' } elseif ($s -eq 0) { 'ніколи' } else { '{0} хв' -f [math]::Round($s / 60, 1) }
            @{ Ok = ($s -eq 300); Now = $now }
        }
        Apply = {
            $old = Get-MonitorTimeoutAC
            powercfg /change monitor-timeout-ac 5 | Out-Null
            Write-Log "POWER  вимкнення екрана (AC) $old с -> 300 с"
        }
    },
    @{
        Group = 'План живлення'
        Name  = 'План живлення «Збалансований» (стандартний Windows)'
        Want  = 'активний «Збалансований», без змін усередині'
        Check = {
            $a = Get-ActiveScheme
            @{ Ok = ($a.Guid -eq $GUID_BALANCED); Now = $a.Name }
        }
        Apply = {
            $old = Get-ActiveScheme
            powercfg /setactive $GUID_BALANCED 2>$null | Out-Null
            if ((Get-ActiveScheme).Guid -ne $GUID_BALANCED) {
                Write-Host '      Плану «Збалансований» немає в системі (його видалив твікер?).' -ForegroundColor Yellow
                Write-Host '      Можна повернути стандартні плани Windows. Усі нестандартні плани буде видалено.' -ForegroundColor Yellow
                if (Confirm-Change 'Відновити стандартні плани живлення?') {
                    powercfg -restoredefaultschemes | Out-Null
                    powercfg /setactive $GUID_BALANCED | Out-Null
                    Write-Log 'POWER  powercfg -restoredefaultschemes'
                }
            }
            Write-Log "POWER  активний план $($old.Name) -> Збалансований"
            # Вимкнення екрана прив'язане до плану, тому перевиставляємо 5 хв і тут
            powercfg /change monitor-timeout-ac 5 | Out-Null
        }
    }
)

function Show-SettingsStatus {
    Write-Title 'Налаштування Windows'
    $group = ''
    foreach ($s in $Settings) {
        if ($s.Group -ne $group) { $group = $s.Group; Write-Host ''; Write-Host ('  ' + $group) -ForegroundColor DarkYellow }
        try { $r = & $s.Check } catch { $r = @{ Ok = $false; Now = 'помилка читання' } }
        if ($r.Ok) { Write-Status 'ok' $s.Name $r.Now } else { Write-Status 'bad' $s.Name ("зараз: $($r.Now)  |  треба: $($s.Want)") }
    }
}

function Invoke-ApplySettings {
    Write-Title 'Застосування налаштувань Windows'
    Write-Host '  Перед кожною зміною буде питання. Що вже стоїть правильно — пропускається.' -ForegroundColor Gray
    Write-Host "  Старі значення записуються в $LogFile" -ForegroundColor Gray
    $script:YesToAll = $false
    $script:NeedReboot = $false
    $changed = 0
    $group = ''
    foreach ($s in $Settings) {
        if ($s.Group -ne $group) { $group = $s.Group; Write-Host ''; Write-Host ('  ' + $group) -ForegroundColor DarkYellow }
        try { $r = & $s.Check } catch { $r = @{ Ok = $false; Now = 'помилка читання' } }
        if ($r.Ok) { Write-Status 'ok' $s.Name $r.Now; continue }
        Write-Status 'bad' $s.Name ("зараз: $($r.Now)")
        if (Confirm-Change ("Змінити на: $($s.Want)?")) {
            try {
                & $s.Apply
                $r2 = & $s.Check
                if ($r2.Ok) { Write-Status 'ok' '      готово' $r2.Now; $changed++ }
                else { Write-Status 'warn' '      застосовано, перевір після перезавантаження' $r2.Now; $changed++ }
            } catch {
                Write-Status 'bad' '      помилка' $_.Exception.Message
                Write-Log "ПОМИЛКА  $($s.Name): $($_.Exception.Message)"
            }
        } else {
            Write-Status 'skip' '      пропущено' ''
        }
    }
    Write-Host ''
    Write-Host "  Змінено пунктів: $changed" -ForegroundColor Cyan
    if ($script:NeedReboot) { Write-Host '  HAGS запрацює після перезавантаження ПК.' -ForegroundColor Yellow }
    Write-Host '  Тема і панель завдань іноді оновлюються лише після виходу з акаунта.' -ForegroundColor Gray
}

# ---------------------------------------------------------------- перевірка заліза і безпеки
function Show-SystemStatus {
    Write-Title 'Залізо, драйвери, безпека (лише читання)'

    # Windows
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    Write-Status 'info' 'Windows' ("{0} {1}, збірка {2}.{3}" -f $cv.ProductName, $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR)

    # CPU
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    Write-Status $(if ($cpu.Name -match '7800X3D') { 'ok' } else { 'warn' }) 'Процесор' $cpu.Name.Trim()

    # RAM
    $mods = @(Get-CimInstance Win32_PhysicalMemory)
    $totalGb = [math]::Round((($mods | Measure-Object Capacity -Sum).Sum) / 1GB)
    $speed = ($mods | Select-Object -First 1).ConfiguredClockSpeed
    $ramOk = ($speed -ge 5900 -and $totalGb -ge 32)
    $ramMsg = "$totalGb ГБ, $($mods.Count) планки, $speed MT/s"
    if ($speed -lt 5900) { $ramMsg += '  ← EXPO не ввімкнений? (має бути 6000)' }
    Write-Status $(if ($ramOk) { 'ok' } else { 'bad' }) 'Оперативна пам''ять' $ramMsg

    # NVIDIA
    $smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
    if (Test-Path $smi) {
        $q = (& $smi --query-gpu=name,driver_version,temperature.gpu --format=csv,noheader 2>$null) -split ','
        if ($q.Count -ge 3) {
            Write-Status 'ok' 'Відеокарта' ("{0}, драйвер {1}, {2} °C" -f $q[0].Trim(), $q[1].Trim(), $q[2].Trim())
        }
        $full = (& $smi -q -d MEMORY 2>$null) -join "`n"
        if ($full -match '(?s)BAR1 Memory Usage.*?Total\s*:\s*(\d+)\s*MiB') {
            $bar = [int]$Matches[1]
            Write-Status $(if ($bar -gt 256) { 'ok' } else { 'bad' }) 'Resizable BAR' $(if ($bar -gt 256) { "працює (BAR1 $bar MiB)" } else { "не працює (BAR1 $bar MiB) → BIOS: Above 4G + Re-Size BAR, CSM Disabled" })
        }
    } else {
        Write-Status 'bad' 'Драйвер NVIDIA' 'не знайдено nvidia-smi → постав драйвер з nvidia.com'
    }

    # Монітор
    $vc = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1
    if ($vc -and $vc.CurrentRefreshRate) {
        $mOk = ($vc.CurrentHorizontalResolution -eq 2560 -and $vc.CurrentVerticalResolution -eq 1440 -and $vc.CurrentRefreshRate -ge 239)
        Write-Status $(if ($mOk) { 'ok' } else { 'bad' }) 'Монітор' ("{0}×{1} @ {2} Гц  (треба 2560×1440 @ 240)" -f $vc.CurrentHorizontalResolution, $vc.CurrentVerticalResolution, $vc.CurrentRefreshRate)
    }

    # AMD Chipset
    $uninst = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $apps = Get-ItemProperty $uninst -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName }
    $chip = $apps | Where-Object { $_.DisplayName -match 'AMD Chipset Software' } | Select-Object -First 1
    if ($chip) { Write-Status 'ok' 'AMD Chipset Driver' $chip.DisplayVersion } else { Write-Status 'bad' 'AMD Chipset Driver' 'не знайдено → amd.com (лише Chipset)' }

    foreach ($bad in @('Ryzen Master', 'AMD Software', 'Driver Booster', 'Process Lasso', 'Danskyi')) {
        $hit = $apps | Where-Object { $_.DisplayName -match [regex]::Escape($bad) } | Select-Object -First 1
        if ($hit) { Write-Status 'warn' "Знайдено «$($hit.DisplayName)»" 'за твоїми правилами це не потрібно' }
    }

    # Secure Boot / TPM
    try {
        $sb = Confirm-SecureBootUEFI -ErrorAction Stop
        Write-Status $(if ($sb) { 'ok' } else { 'bad' }) 'Secure Boot' $(if ($sb) { 'увімкнено' } else { 'вимкнено → потрібен для Vanguard' })
    } catch { Write-Status 'bad' 'Secure Boot' 'не UEFI або не вдалося прочитати (CSM має бути Disabled)' }
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        Write-Status $(if ($tpm.TpmReady) { 'ok' } else { 'bad' }) 'fTPM' $(if ($tpm.TpmReady) { 'готовий' } else { 'не готовий → BIOS: AMD CPU fTPM Enabled' })
    } catch { Write-Status 'warn' 'fTPM' 'не вдалося прочитати' }

    # Vanguard
    $vgc = Get-Service -Name vgc -ErrorAction SilentlyContinue
    if ($vgc) { Write-Status 'ok' 'Riot Vanguard' "служба є ($($vgc.Status))" } else { Write-Status 'info' 'Riot Vanguard' 'не встановлено (з''явиться разом з Valorant)' }

    # Defender / Memory Integrity — тільки показуємо
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        Write-Status $(if ($mp.RealTimeProtectionEnabled) { 'ok' } else { 'warn' }) 'Microsoft Defender' $(if ($mp.RealTimeProtectionEnabled) { 'захист у реальному часі працює' } else { 'захист у реальному часі вимкнено' })
    } catch { Write-Status 'info' 'Microsoft Defender' 'не вдалося прочитати' }
    $hvci = Get-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled'
    Write-Status 'info' 'Цілісність пам''яті (Memory Integrity)' $(if ($hvci -eq 1) { 'увімкнено (не чіпати)' } else { 'вимкнено / стандарт (не чіпати)' })

    # WHEA
    $since = (Get-Date).AddDays(-30)
    $whea = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $since } -ErrorAction SilentlyContinue)
    if ($whea.Count -eq 0) { Write-Status 'ok' 'Помилки WHEA за 30 днів' '0' }
    else { Write-Status 'bad' 'Помилки WHEA за 30 днів' ("{0}, остання {1:dd.MM HH:mm} → підозра на CO/таймінги, див. довідник" -f $whea.Count, $whea[0].TimeCreated) }

    # Диски
    foreach ($d in Get-PhysicalDisk -ErrorAction SilentlyContinue) {
        $st = if ($d.HealthStatus -eq 'Healthy') { 'ok' } else { 'bad' }
        Write-Status $st ('Диск: ' + $d.FriendlyName) ("{0}, {1} ГБ, {2}" -f $d.HealthStatus, [math]::Round($d.Size / 1GB), $d.BusType)
    }

    # Автозапуск
    $startup = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue)
    if ($startup.Count) {
        Write-Status 'info' "Автозапуск ($($startup.Count))" (($startup | Select-Object -ExpandProperty Name -Unique) -join ', ')
        Write-Host '          Лишити: Vanguard, NVIDIA, аудіо. Решту вимкни в Диспетчері завдань → Автозавантаження.' -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------- програми
$Apps = @(
    @{ Id = 'OCBase.OCCT.Personal';               Name = 'OCCT (тести стабільності CPU / RAM / GPU)'; Default = $true },
    @{ Id = 'Klocman.BulkCrapUninstaller';        Name = 'BCUninstaller (видалення програм)';         Default = $true },
    @{ Id = 'RiotGames.Valorant.EU';              Name = 'Valorant (Riot Client, регіон EU)';         Default = $true },
    @{ Id = 'Google.Chrome';                      Name = 'Google Chrome';                            Default = $false },
    @{ Id = 'Wagnardsoft.DisplayDriverUninstaller'; Name = 'DDU (лише якщо треба знести драйвер NVIDIA)'; Default = $false },
    @{ Id = 'Resplendence.LatencyMon';            Name = 'LatencyMon (перевірка затримок драйверів)'; Default = $false }
)

function Test-AppInstalled([string]$id) {
    $out = winget list --id $id --exact --accept-source-agreements 2>$null | Out-String
    return ($LASTEXITCODE -eq 0 -and $out -match [regex]::Escape($id))
}

function Invoke-InstallApps {
    Write-Title 'Встановлення програм через winget'
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host '  winget не знайдено. Онови «App Installer» (Інсталятор програм) у Microsoft Store і запусти ще раз.' -ForegroundColor Yellow
        Start-Process 'ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1'
        return
    }
    Write-Host '  Усі пакети качаються з офіційних сайтів розробників.' -ForegroundColor Gray
    Write-Host '  MSI Afterburner (у winget він з дзеркала, не з msi.com) і Samsung Magician (немає в winget)' -ForegroundColor Gray
    Write-Host '  ставляться руками: пункт 4 меню.' -ForegroundColor Gray
    Write-Host ''
    for ($i = 0; $i -lt $Apps.Count; $i++) {
        $a = $Apps[$i]
        $mark = if ($a.Default) { '[*]' } else { '[ ]' }
        $inst = if (Test-AppInstalled $a.Id) { '  (вже встановлено)' } else { '' }
        Write-Host ("  {0}. {1} {2}" -f ($i + 1), $mark, $a.Name) -NoNewline
        Write-Host $inst -ForegroundColor Green
    }
    Write-Host ''
    Write-Host '  [*] — рекомендовано. Enter = поставити рекомендовані.' -ForegroundColor Gray
    $sel = Read-Host '  Або введи номери через пробіл (напр. 1 2 4), 0 = скасувати'
    $sel = $sel.Trim()
    if ($sel -eq '0') { return }
    if ($sel -eq '') { $pick = @($Apps | Where-Object { $_.Default }) }
    else {
        $pick = @()
        foreach ($n in ($sel -split '[\s,;]+')) {
            $k = 0
            if ([int]::TryParse($n, [ref]$k) -and $k -ge 1 -and $k -le $Apps.Count) { $pick += $Apps[$k - 1] }
        }
    }
    foreach ($a in $pick) {
        Write-Host ''
        if (Test-AppInstalled $a.Id) { Write-Status 'ok' $a.Name 'вже встановлено, пропускаю'; continue }
        Write-Host ("  → {0}" -f $a.Name) -ForegroundColor Cyan
        winget install --id $a.Id --exact --source winget --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -eq 0) { Write-Status 'ok' $a.Name 'встановлено'; Write-Log "WINGET  $($a.Id) встановлено" }
        else { Write-Status 'bad' $a.Name "winget повернув код $LASTEXITCODE"; Write-Log "WINGET  $($a.Id) помилка $LASTEXITCODE" }
    }
}

# ---------------------------------------------------------------- офіційні сайти
$Links = @(
    @{ Name = 'Драйвер NVIDIA (RTX 5070, WHQL)';                 Url = 'https://www.nvidia.com/en-us/drivers/' },
    @{ Name = 'AMD Chipset Driver (AM5 / B650, тільки Chipset)'; Url = 'https://www.amd.com/en/support/downloads/drivers.html/chipsets/am5/b650.html' },
    @{ Name = 'MSI Afterburner (msi.com)';                       Url = 'https://www.msi.com/Landing/afterburner/graphics-cards' },
    @{ Name = 'Samsung Magician';                                Url = 'https://semiconductor.samsung.com/consumer-storage/support/tools/' },
    @{ Name = 'Драйвер миші Attack Shark R5 Ultra';              Url = 'https://xvalleyinno.top/AttackShark' },
    @{ Name = 'Драйвер клавіатури Attack Shark X65HE';           Url = 'https://qmk.top' },
    @{ Name = 'Gigabyte B650 AORUS ELITE AX V2 (BIOS, LAN, Wi-Fi)'; Url = 'https://www.gigabyte.com/Motherboard/B650-AORUS-ELITE-AX-V2' },
    @{ Name = 'Visual C++ Redistributable (лише з сайту Microsoft)'; Url = 'https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist' }
)

function Open-Links {
    Write-Title 'Офіційні сайти для ручного завантаження'
    for ($i = 0; $i -lt $Links.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), $Links[$i].Name) }
    Write-Host ''
    $sel = Read-Host '  Номери через пробіл (напр. 1 2 3), Enter = 1-4, 0 = назад'
    $sel = $sel.Trim()
    if ($sel -eq '0') { return }
    $nums = if ($sel -eq '') { 1..4 } else { $sel -split '[\s,;]+' }
    foreach ($n in $nums) {
        $k = 0
        if ([int]::TryParse("$n", [ref]$k) -and $k -ge 1 -and $k -le $Links.Count) { Start-Process $Links[$k - 1].Url }
    }
}

# ---------------------------------------------------------------- точка відновлення
function New-RestorePoint {
    Write-Title 'Точка відновлення'
    Write-Host '  Дозволяє відкотити зміни реєстру і системи через «Відновлення системи».' -ForegroundColor Gray
    if (-not (Confirm-Change 'Створити точку відновлення зараз?')) { return }
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description 'Перед налаштуванням ігрового ПК' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Status 'ok' 'Точку відновлення створено' ''
        Write-Log 'RESTORE  точку відновлення створено'
    } catch {
        Write-Status 'warn' 'Не вдалося' $_.Exception.Message
        Write-Host '  Windows дозволяє одну точку на 24 години. Якщо вже є свіжа — це нормально.' -ForegroundColor Gray
    }
}

# ---------------------------------------------------------------- меню
if ($CheckOnly) { Show-SettingsStatus; Show-SystemStatus; Pause-Key; exit }

while ($true) {
    Clear-Host
    Write-Host ''
    Write-Host '   НАЛАШТУВАННЯ ІГРОВОГО ПК' -ForegroundColor Cyan
    Write-Host '   7800X3D · RTX 5070 · B650 AORUS ELITE AX V2 · MAG 274QP' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '   1  Перевірити все (нічого не змінює)'
    Write-Host '   2  Застосувати налаштування Windows (питає перед кожним)'
    Write-Host '   3  Встановити програми (winget)'
    Write-Host '   4  Відкрити офіційні сайти (драйвери, Afterburner, Magician, миша, клава)'
    Write-Host '   5  Створити точку відновлення'
    Write-Host '   6  Відкрити довідник (guide.html)'
    Write-Host '   0  Вихід'
    Write-Host ''
    $c = Read-Host '   Вибір'
    switch ($c.Trim()) {
        '1' { Show-SettingsStatus; Show-SystemStatus; Pause-Key }
        '2' { Invoke-ApplySettings; Pause-Key }
        '3' { Invoke-InstallApps; Pause-Key }
        '4' { Open-Links }
        '5' { New-RestorePoint; Pause-Key }
        '6' {
            $g = Join-Path $ScriptDir 'guide.html'
            if (Test-Path $g) { Start-Process $g } else { Write-Host '  guide.html не знайдено поруч зі скриптом.' -ForegroundColor Yellow; Pause-Key }
        }
        '0' { exit }
    }
}
