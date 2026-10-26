<#
.SYNOPSIS
    TerminalGlass — 调节 Windows Terminal 的磨砂/透明外观，并可精确还原。

.DESCRIPTION
    只改写 settings.json 中 profiles.defaults 下的两个外观键：
        opacity      0-100     窗口透过率（越低越"透"）
        useAcrylic   true/false 是否启用 Windows 亚克力模糊
    不安装驱动、不 hook DWM、不写注册表、不需要管理员权限。

    首次"应用"时记录这两个键原本的值；"还原"时把它们放回去
    （原本不存在的键会被删除），因此不会覆盖你在别处做的其他设置。

.PARAMETER Apply
    应用外观设置。

.PARAMETER Opacity
    0-100。配合 -Apply 使用。

.PARAMETER Acrylic
    是否启用亚克力，默认 $true。可写 -Acrylic:$false 或 -DisableAcrylic。

.PARAMETER Reset
    还原到使用本工具之前的状态。

.PARAMETER Status
    显示当前检测到的外观值与还原记录状态。

.PARAMETER SettingsPath
    手动指定 settings.json（默认自动查找）。

.PARAMETER StateDir
    手动指定状态/备份目录（默认 %LOCALAPPDATA%\TerminalGlass）。
#>
param(
    [switch]$Apply,
    [switch]$Reset,
    [switch]$Status,
    [switch]$Verify,
    [switch]$Repair,
    [int]$Opacity = -1,
    [bool]$Acrylic = $true,
    [switch]$DisableAcrylic,
    [string]$SettingsPath = '',
    [string]$StateDir = ''
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 路径

$script:StateDir = if ($StateDir) {
    $StateDir
} else {
    Join-Path $env:LOCALAPPDATA 'TerminalGlass'
}
$script:StateFile = Join-Path $script:StateDir 'state.json'
$script:BackupDir = Join-Path $script:StateDir 'backups'

function Find-SettingsPath {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
    )
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    throw '没有找到 Windows Terminal 的 settings.json。请确认已安装 Windows Terminal，或用 -SettingsPath 指定。'
}

# ---------------------------------------------------------------- JSON 扫描
# settings.json 允许注释和尾逗号（JSONC），所以这里用一个最小的扫描器
# 定位结构，而不是直接整文件 ConvertFrom-Json。

function Skip-Trivia {
    param([string]$S, [int]$I)
    while ($I -lt $S.Length) {
        $c = $S[$I]
        if ([char]::IsWhiteSpace($c)) { $I++; continue }
        if ($c -eq '/' -and ($I + 1) -lt $S.Length) {
            $n = $S[$I + 1]
            if ($n -eq '/') {
                $I += 2
                while ($I -lt $S.Length -and $S[$I] -ne "`n" -and $S[$I] -ne "`r") { $I++ }
                continue
            }
            if ($n -eq '*') {
                $I += 2
                while (($I + 1) -lt $S.Length -and -not ($S[$I] -eq '*' -and $S[$I + 1] -eq '/')) { $I++ }
                $I += 2
                continue
            }
        }
        break
    }
    return $I
}

function Get-StringEnd {
    param([string]$S, [int]$I)
    if ($I -ge $S.Length -or $S[$I] -ne '"') { throw "JSON 解析失败：$I 处应为字符串" }
    $I++
    while ($I -lt $S.Length) {
        $c = $S[$I]
        if ($c -eq '\') { $I += 2; continue }
        if ($c -eq '"') { return $I + 1 }
        $I++
    }
    throw 'JSON 解析失败：字符串没有闭合'
}

function Get-ContainerEnd {
    param([string]$S, [int]$I)
    $open = $S[$I]
    $close = if ($open -eq '{') { [char]'}' } else { [char]']' }
    $depth = 0
    while ($I -lt $S.Length) {
        $c = $S[$I]
        if ($c -eq '"') { $I = Get-StringEnd $S $I; continue }
        if ($c -eq '/' -and ($I + 1) -lt $S.Length -and ($S[$I + 1] -eq '/' -or $S[$I + 1] -eq '*')) {
            $I = Skip-Trivia $S $I
            continue
        }
        if ($c -eq $open) { $depth++ }
        elseif ($c -eq $close) {
            $depth--
            if ($depth -eq 0) { return $I + 1 }
        }
        $I++
    }
    throw 'JSON 解析失败：括号不匹配'
}

function Skip-Value {
    param([string]$S, [int]$I)
    $I = Skip-Trivia $S $I
    if ($I -ge $S.Length) { throw 'JSON 解析失败：意外的结尾' }
    $c = $S[$I]
    if ($c -eq '{' -or $c -eq '[') { return Get-ContainerEnd $S $I }
    if ($c -eq '"') { return Get-StringEnd $S $I }
    while ($I -lt $S.Length) {
        $c = $S[$I]
        if ($c -eq ',' -or $c -eq '}' -or $c -eq ']') { return $I }
        $I++
    }
    return $I
}

function Find-ObjectMember {
    param([string]$S, [int]$ObjStart, [string]$KeyName)
    if ($ObjStart -ge $S.Length -or $S[$ObjStart] -ne '{') { return $null }
    $I = $ObjStart + 1
    while ($I -lt $S.Length) {
        $I = Skip-Trivia $S $I
        if ($I -ge $S.Length) { break }
        $c = $S[$I]
        if ($c -eq '}') { break }
        if ($c -eq ',') { $I++; continue }
        $keyStart = $I
        $keyEnd = Get-StringEnd $S $I
        $rawKey = $S.Substring($keyStart, $keyEnd - $keyStart)
        $name = $rawKey.Substring(1, $rawKey.Length - 2)
        $I = Skip-Trivia $S $keyEnd
        if ($I -ge $S.Length -or $S[$I] -ne ':') { throw "JSON 解析失败：键 $name 后缺少冒号" }
        $I = Skip-Trivia $S ($I + 1)
        $valueStart = $I
        $valueEnd = Skip-Value $S $I
        if ($name -eq $KeyName) {
            return [pscustomobject]@{
                KeyStart   = $keyStart
                KeyEnd     = $keyEnd
                ValueStart = $valueStart
                ValueEnd   = $valueEnd
            }
        }
        $I = $valueEnd
    }
    return $null
}

function Get-DefaultsInfo {
    param([string]$Text)
    $root = Skip-Trivia $Text 0
    if ($root -ge $Text.Length -or $Text[$root] -ne '{') {
        throw 'settings.json 根节点不是对象，无法处理。'
    }
    $profiles = Find-ObjectMember $Text $root 'profiles'
    if (-not $profiles) { throw 'settings.json 里找不到 profiles 节点。' }
    if ($Text[$profiles.ValueStart] -ne '{') {
        throw 'profiles 是旧版数组格式，本工具只支持新版对象格式（profiles.defaults）。'
    }
    $defaults = Find-ObjectMember $Text $profiles.ValueStart 'defaults'
    if ($defaults -and $Text[$defaults.ValueStart] -ne '{') {
        throw 'profiles.defaults 不是对象，无法安全修改。'
    }
    return [pscustomobject]@{ Profiles = $profiles; Defaults = $defaults }
}

function Remove-JsonComments {
    param([string]$S)
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    while ($i -lt $S.Length) {
        $c = $S[$i]
        if ($c -eq '"') {
            $e = Get-StringEnd $S $i
            [void]$sb.Append($S.Substring($i, $e - $i))
            $i = $e
            continue
        }
        if ($c -eq '/' -and ($i + 1) -lt $S.Length) {
            if ($S[$i + 1] -eq '/') {
                while ($i -lt $S.Length -and $S[$i] -ne "`n") { $i++ }
                continue
            }
            if ($S[$i + 1] -eq '*') {
                $i += 2
                while (($i + 1) -lt $S.Length -and -not ($S[$i] -eq '*' -and $S[$i + 1] -eq '/')) { $i++ }
                $i += 2
                continue
            }
        }
        [void]$sb.Append($c)
        $i++
    }
    return $sb.ToString()
}

function Remove-TrailingCommas {
    # 字符串感知地去掉对象/数组末尾的逗号（JSONC 允许，JSON 不允许）
    param([string]$S)
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    while ($i -lt $S.Length) {
        $c = $S[$i]
        if ($c -eq '"') {
            $e = Get-StringEnd $S $i
            [void]$sb.Append($S.Substring($i, $e - $i))
            $i = $e
            continue
        }
        if ($c -eq ',') {
            $j = $i + 1
            while ($j -lt $S.Length -and [char]::IsWhiteSpace($S[$j])) { $j++ }
            if ($j -lt $S.Length -and ($S[$j] -eq '}' -or $S[$j] -eq ']')) { $i++; continue }
        }
        [void]$sb.Append($c)
        $i++
    }
    return $sb.ToString()
}

function Test-JsonC {
    param([string]$Text)
    try {
        $clean = Remove-JsonComments $Text
        $clean = Remove-TrailingCommas $clean
        $null = $clean | ConvertFrom-Json
        return $true
    }
    catch { return $false }
}

# ---------------------------------------------------------------- 读写

function Get-LineIndent {
    param([string]$Text, [int]$Index)
    if ($Index -le 0) { return '' }
    $ls = $Text.LastIndexOf("`n", $Index - 1)
    if ($ls -lt 0) { $ls = 0 } else { $ls = $ls + 1 }
    $prefix = $Text.Substring($ls, $Index - $ls)
    if ($prefix -match '^[ \t]*$') { return $prefix }
    return ''
}

function Read-DefaultsObject {
    param([string]$Text, $Info)
    if (-not $Info.Defaults) {
        return [pscustomobject]@{}
    }
    $raw = $Text.Substring($Info.Defaults.ValueStart, $Info.Defaults.ValueEnd - $Info.Defaults.ValueStart)
    $clean = Remove-JsonComments $raw
    $clean = Remove-TrailingCommas $clean
    if ([string]::IsNullOrWhiteSpace($clean) -or $clean.Trim() -eq '{}') {
        return [pscustomobject]@{}
    }
    return ($clean | ConvertFrom-Json)
}

function Format-JsonText {
    # 把 ConvertTo-Json 的输出重新缩进成整齐的 4 空格层级
    param([string]$Json, [string]$Unit = '    ')
    $sb = New-Object System.Text.StringBuilder
    $depth = 0
    $inStr = $false
    $esc = $false
    $i = 0
    $len = $Json.Length

    while ($i -lt $len) {
        $c = $Json[$i]
        if ($inStr) {
            [void]$sb.Append($c)
            if ($esc) { $esc = $false }
            elseif ($c -eq '\') { $esc = $true }
            elseif ($c -eq '"') { $inStr = $false }
            $i++
            continue
        }
        if ([char]::IsWhiteSpace($c)) { $i++; continue }

        if ($c -eq '"') {
            $inStr = $true
            [void]$sb.Append($c)
            $i++
            continue
        }
        if ($c -eq '{' -or $c -eq '[') {
            $closer = if ($c -eq '{') { '}' } else { ']' }
            $j = $i + 1
            while ($j -lt $len -and [char]::IsWhiteSpace($Json[$j])) { $j++ }
            if ($j -lt $len -and $Json[$j] -eq $closer) {
                [void]$sb.Append([string]$c + [string]$closer)
                $i = $j + 1
                continue
            }
            [void]$sb.Append($c)
            $depth++
            [void]$sb.Append("`n")
            [void]$sb.Append($Unit * $depth)
            $i++
            continue
        }
        if ($c -eq '}' -or $c -eq ']') {
            $depth--
            [void]$sb.Append("`n")
            [void]$sb.Append($Unit * $depth)
            [void]$sb.Append($c)
            $i++
            continue
        }
        if ($c -eq ',') {
            [void]$sb.Append(',')
            [void]$sb.Append("`n")
            [void]$sb.Append($Unit * $depth)
            $i++
            continue
        }
        if ($c -eq ':') {
            [void]$sb.Append(': ')
            $i++
            continue
        }
        [void]$sb.Append($c)
        $i++
    }
    return $sb.ToString()
}

function Format-JsonBlock {
    param([string]$Json, [string]$Prefix, [string]$Eol)
    $lines = $Json -split "`r?`n"
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($lines[0])
    for ($k = 1; $k -lt $lines.Count; $k++) {
        [void]$sb.Append($Eol)
        [void]$sb.Append($Prefix)
        [void]$sb.Append($lines[$k])
    }
    return $sb.ToString()
}

function Write-DefaultsObject {
    param([string]$Text, $Info, $Obj)
    $eol = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $props = @($Obj.PSObject.Properties)
    if ($props.Count -eq 0) {
        $json = '{}'
    }
    else {
        $json = $Obj | ConvertTo-Json -Depth 32
        $json = Format-JsonText $json
    }

    if ($Info.Defaults) {
        $indent = Get-LineIndent $Text $Info.Defaults.KeyStart
        $block = Format-JsonBlock $json $indent $eol
        return $Text.Substring(0, $Info.Defaults.ValueStart) + $block + $Text.Substring($Info.Defaults.ValueEnd)
    }

    # 没有 defaults：插到 profiles 对象的第一个成员之前
    $memberIndent = (Get-LineIndent $Text $Info.Profiles.KeyStart) + '    '
    $block = Format-JsonBlock $json $memberIndent $eol
    $open = $Info.Profiles.ValueStart
    $afterOpen = Skip-Trivia $Text ($open + 1)
    $parenText = [string]$Text[$afterOpen]

    if ($parenText -eq '}') {
        # profiles 是空对象：直接替换 {}
        return $Text.Substring(0, $open) + '{' + $eol + $memberIndent + '"defaults": ' + $block + $eol +
            (Get-LineIndent $Text $Info.Profiles.KeyStart) + '}' + $Text.Substring($afterOpen + 1)
    }

    $insert = $eol + $memberIndent + '"defaults": ' + $block + ','
    return $Text.Substring(0, $open + 1) + $insert + $Text.Substring($open + 1)
}

function Save-SettingsFile {
    param([string]$Path, [string]$Text)
    $tmp = "$Path.terminalglass.tmp"
    [System.IO.File]::WriteAllText($tmp, $Text, (New-Object System.Text.UTF8Encoding($false)))
    $last = $null
    for ($i = 0; $i -lt 4; $i++) {
        try {
            Copy-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            return
        }
        catch {
            $last = $_
            Start-Sleep -Milliseconds 150
        }
    }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    throw "写入 settings.json 失败（可能正被 Terminal 占用）：$($last.Exception.Message)"
}

function Backup-SettingsFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $script:BackupDir)) {
        New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dest = Join-Path $script:BackupDir "settings-$stamp.json"
    Copy-Item -LiteralPath $Path -Destination $dest -Force
    Get-ChildItem -LiteralPath $script:BackupDir -Filter 'settings-*.json' |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 20 |
        Remove-Item -Force -ErrorAction SilentlyContinue
    return $dest
}

# ---------------------------------------------------------------- 核心操作

function Get-CurrentSkin {
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path)
    $info = Get-DefaultsInfo $text
    $obj = Read-DefaultsObject $text $info
    if ($null -eq $obj) { $obj = [pscustomobject]@{} }

    $opacity = 100
    $useAcrylic = $false
    $p = $obj.PSObject.Properties['opacity']
    if ($p -and ($p.Value -is [int] -or $p.Value -is [long] -or $p.Value -is [double] -or $p.Value -is [string])) {
        $num = 0
        if ([int]::TryParse([string]$p.Value, [ref]$num)) { $opacity = $num }
    }
    $a = $obj.PSObject.Properties['useAcrylic']
    if ($a -and $a.Value -is [bool]) { $useAcrylic = [bool]$a.Value }

    return [pscustomobject]@{
        Opacity     = $opacity
        UseAcrylic  = $useAcrylic
        HasOpacity  = [bool]$p
        HasAcrylic  = [bool]$a
        HasDefaults = [bool]$info.Defaults
        Object      = $obj
        Text        = $text
        Info        = $info
    }
}

function Assert-SkinApplied {
    param([string]$Path, [int]$Opacity, [bool]$Acrylic, [string]$Backup)
    $check = Get-CurrentSkin -Path $Path
    if ($check.HasOpacity -and $check.HasAcrylic -and
        [int]$check.Opacity -eq $Opacity -and [bool]$check.UseAcrylic -eq $Acrylic) {
        return
    }
    Copy-Item -LiteralPath $Backup -Destination $Path -Force
    throw @"
写入后的自检未通过，已自动回滚到操作前快照。
期望：opacity=$Opacity，useAcrylic=$Acrylic
实际：opacity=$($check.Opacity)（$(if ($check.HasOpacity) { '存在' } else { '缺失' })），useAcrylic=$($check.UseAcrylic)（$(if ($check.HasAcrylic) { '存在' } else { '缺失' })）
回滚快照：$Backup
"@
}

function Assert-SkinRestored {
    param([string]$Path, $State, [string]$Backup)
    $check = Get-CurrentSkin -Path $Path
    $problem = $null

    foreach ($prop in $State.keys.PSObject.Properties) {
        $name = $prop.Name
        if ($name -ne 'opacity' -and $name -ne 'useAcrylic') { continue }
        $rec = $prop.Value

        if ($name -eq 'opacity') {
            if ($rec.present) {
                $want = 0
                if (-not [int]::TryParse([string]$rec.value, [ref]$want)) { continue }
                if (-not $check.HasOpacity -or [int]$check.Opacity -ne $want) {
                    $problem = "opacity 期望 $want，实际 $(if ($check.HasOpacity) { $check.Opacity } else { '缺失' })"
                }
            }
            elseif ($check.HasOpacity) {
                $problem = 'opacity 期望不存在，实际存在'
            }
        }
        elseif ($name -eq 'useAcrylic') {
            if ($rec.present) {
                if (-not $check.HasAcrylic -or [bool]$check.UseAcrylic -ne [bool]$rec.value) {
                    $problem = "useAcrylic 期望 $($rec.value)，实际 $(if ($check.HasAcrylic) { $check.UseAcrylic } else { '缺失' })"
                }
            }
            elseif ($check.HasAcrylic) {
                $problem = 'useAcrylic 期望不存在，实际存在'
            }
        }
    }

    if ($problem) {
        Copy-Item -LiteralPath $Backup -Destination $Path -Force
        throw "还原后的自检未通过（$problem），已自动回滚到还原前快照：$Backup"
    }
}

function Read-State {
    if (-not (Test-Path -LiteralPath $script:StateFile)) { return $null }
    try {
        $s = Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $s -or -not $s.settingsPath -or -not $s.keys) { throw '结构不完整' }
        return $s
    }
    catch {
        $bad = "$script:StateFile.corrupt-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        try { Move-Item -LiteralPath $script:StateFile -Destination $bad -Force } catch { }
        Write-Warning "还原记录已损坏，已另存为 $bad；本次会重新记录当前值。"
        return $null
    }
}

function Invoke-WithLock {
    # 防止两个实例同时写配置/状态
    param([scriptblock]$Action)
    $mutex = New-Object System.Threading.Mutex($false, 'Local\TerminalGlass.WriteLock')
    $acquired = $mutex.WaitOne(3000)
    if (-not $acquired) {
        $mutex.Dispose()
        throw '另一个 TerminalGlass 实例正在写入，请稍后再试。'
    }
    try {
        return (& $Action)
    }
    finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

function Save-State {
    param([string]$Path, $Prior)
    if (-not (Test-Path -LiteralPath $script:StateDir)) {
        New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
    }
    $state = [pscustomobject]@{
        tool         = 'TerminalGlass'
        settingsPath = $Path
        createdUtc   = (Get-Date).ToUniversalTime().ToString('o')
        keys         = $Prior
    }
    $state | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $script:StateFile -Encoding UTF8
}

function Set-Skin {
    param([string]$Path, [int]$Opacity, [bool]$Acrylic)

    if ($Opacity -lt 0 -or $Opacity -gt 100) { throw '不透明度必须在 0-100 之间。' }

    $current = Get-CurrentSkin -Path $Path
    $text = $current.Text
    $info = $current.Info
    $obj = $current.Object

    # 首次应用时记录两个键的原始值（含"原本不存在"）
    $state = Read-State
    $needState = -not $state -or $state.settingsPath -ne $Path
    $prior = $null
    if ($needState) {
        $prior = [ordered]@{}
        foreach ($k in @('opacity', 'useAcrylic')) {
            $p = $obj.PSObject.Properties[$k]
            if ($p) {
                $prior[$k] = [pscustomobject]@{ present = $true; value = $p.Value }
            } else {
                $prior[$k] = [pscustomobject]@{ present = $false }
            }
        }
    }

    $backup = Backup-SettingsFile -Path $Path

    $obj | Add-Member -NotePropertyName 'opacity' -NotePropertyValue $Opacity -Force
    $obj | Add-Member -NotePropertyName 'useAcrylic' -NotePropertyValue $Acrylic -Force

    $newText = Write-DefaultsObject -Text $text -Info $info -Obj $obj

    if (-not (Test-JsonC $newText)) {
        throw "生成的新配置无法通过 JSON 校验，已放弃写入。原文件备份：$backup"
    }

    if ($newText -ceq $text) {
        if ($needState) { Save-State -Path $Path -Prior $prior }
        return $backup
    }

    Save-SettingsFile -Path $Path -Text $newText

    if ($needState) {
        Save-State -Path $Path -Prior $prior
    }

    Assert-SkinApplied -Path $Path -Opacity $Opacity -Acrylic $Acrylic -Backup $backup
    return $backup
}

function Undo-Skin {
    param([string]$Path)

    $state = Read-State
    if (-not $state) {
        throw "没有找到本工具的还原记录（$script:StateFile）。`n如果配置被改坏，可以从备份目录手工恢复：$script:BackupDir"
    }
    if ($state.settingsPath -ne $Path) {
        throw "还原记录对应的是：`n$($state.settingsPath)`n当前目标却是：`n$Path`n为避免误改，已停止。请用 -SettingsPath 指定正确文件。"
    }

    $current = Get-CurrentSkin -Path $Path
    $text = $current.Text
    $info = $current.Info
    $obj = $current.Object

    $backup = Backup-SettingsFile -Path $Path

    $managed = @('opacity', 'useAcrylic')
    foreach ($prop in $state.keys.PSObject.Properties) {
        $name = $prop.Name
        if ($managed -notcontains $name) { continue }   # 只回滚本工具管理的键
        $rec = $prop.Value
        if ($rec.present) {
            if ($name -eq 'opacity') {
                $num = 0
                if (-not [int]::TryParse([string]$rec.value, [ref]$num) -or $num -lt 0 -or $num -gt 100) { continue }
                $obj | Add-Member -NotePropertyName $name -NotePropertyValue $num -Force
            }
            elseif ($name -eq 'useAcrylic') {
                if ($rec.value -isnot [bool]) { continue }
                $obj | Add-Member -NotePropertyName $name -NotePropertyValue ([bool]$rec.value) -Force
            }
        }
        else {
            $obj.PSObject.Properties.Remove($name)
        }
    }

    $newText = Write-DefaultsObject -Text $text -Info $info -Obj $obj
    if (-not (Test-JsonC $newText)) {
        throw "还原后的配置无法通过 JSON 校验，已放弃写入。原文件备份：$backup"
    }

    if ($newText -cne $text) {
        Save-SettingsFile -Path $Path -Text $newText
    }

    Assert-SkinRestored -Path $Path -State $state -Backup $backup
    Remove-Item -LiteralPath $script:StateFile -Force -ErrorAction SilentlyContinue
    return $backup
}

function Get-TerminalRunning {
    return [bool](Get-Process -Name WindowsTerminal -ErrorAction SilentlyContinue)
}

function Show-Status {
    $path = if ($SettingsPath) { $SettingsPath } else { Find-SettingsPath }
    $cur = Get-CurrentSkin -Path $path
    $state = Read-State

    Write-Host ''
    Write-Host '  TerminalGlass 状态' -ForegroundColor Cyan
    Write-Host '  ------------------------------------------'
    Write-Host "  配置文件   : $path"
    Write-Host "  当前不透明度: $($cur.Opacity)%"
    Write-Host "  当前亚克力  : $(if ($cur.UseAcrylic) { '开启' } else { '关闭' })"
    Write-Host "  profiles.defaults: $(if ($cur.HasDefaults) { '存在' } else { '不存在（应用时会创建）' })"
    Write-Host "  还原记录   : $(if ($state) { "有（创建于 $($state.createdUtc)）" } else { '无' })"
    Write-Host "  Terminal  : $(if (Get-TerminalRunning) { '正在运行（改完立即热重载）' } else { '未运行（下次启动生效）' })"
    Write-Host "  备份目录   : $script:BackupDir"
    Write-Host ''
}

function Repair-Defaults {
    # 清理"显式写出的默认值"：opacity=100 且 useAcrylic=false。
    # 这两项写入与否行为完全等价，但会让配置文件看起来被改过。
    param([string]$Path)

    $state = Read-State
    if ($state) {
        throw "存在还原记录（$script:StateFile）。请先执行 -Reset 回到基线，再运行 -Repair。"
    }

    $cur = Get-CurrentSkin -Path $Path
    $obj = $cur.Object
    $p = $obj.PSObject.Properties['opacity']
    $a = $obj.PSObject.Properties['useAcrylic']

    $isExplicitDefault = $false
    if ($p -and $a) {
        $num = 0
        $opacityOk = [int]::TryParse([string]$p.Value, [ref]$num) -and $num -eq 100
        $acrylicOk = ($a.Value -is [bool]) -and ([bool]$a.Value -eq $false)
        $isExplicitDefault = $opacityOk -and $acrylicOk
    }

    if (-not $isExplicitDefault) {
        return [pscustomobject]@{ Changed = $false; Backup = $null }
    }

    $backup = Backup-SettingsFile -Path $Path
    $obj.PSObject.Properties.Remove('opacity')
    $obj.PSObject.Properties.Remove('useAcrylic')

    $newText = Write-DefaultsObject -Text $cur.Text -Info $cur.Info -Obj $obj
    if (-not (Test-JsonC $newText)) {
        throw "修复后的配置无法通过 JSON 校验，已放弃写入。原文件备份：$backup"
    }
    Save-SettingsFile -Path $Path -Text $newText

    $check = Get-CurrentSkin -Path $Path
    if ($check.HasOpacity -or $check.HasAcrylic) {
        Copy-Item -LiteralPath $backup -Destination $Path -Force
        throw "修复自检未通过，已回滚。快照：$backup"
    }

    return [pscustomobject]@{ Changed = $true; Backup = $backup }
}

function Show-Verify {
    $path = if ($SettingsPath) { $SettingsPath } else { Find-SettingsPath }
    $cur = Get-CurrentSkin -Path $path
    $state = Read-State

    Write-Host ''
    Write-Host '  TerminalGlass 自检' -ForegroundColor Cyan
    Write-Host '  ------------------------------------------'
    Write-Host "  配置文件   : $path"
    Write-Host "  opacity    : $($cur.Opacity) $(if ($cur.HasOpacity) { '（文件里显式存在）' } else { '（文件里不存在，取内置默认 100）' })"
    Write-Host "  useAcrylic : $($cur.UseAcrylic) $(if ($cur.HasAcrylic) { '（文件里显式存在）' } else { '（文件里不存在，取内置默认 false）' })"

    if ($cur.HasOpacity -and $cur.HasAcrylic -and $cur.Opacity -eq 100 -and -not $cur.UseAcrylic) {
        Write-Host '  提示       : opacity=100 且 useAcrylic=false 是"显式写出的默认值"，行为与不存在完全等价。' -ForegroundColor DarkGray
    }

    if (-not $state) {
        Write-Host '  还原记录   : 无'
        Write-Host '  判定       : 当前外观就是基线，本工具没有留下可还原的改动。' -ForegroundColor Green
    }
    else {
        $same = $true
        foreach ($prop in $state.keys.PSObject.Properties) {
            $name = $prop.Name
            $rec = $prop.Value
            if ($name -eq 'opacity') {
                if ($rec.present) {
                    $want = 0
                    if ([int]::TryParse([string]$rec.value, [ref]$want)) {
                        if (-not $cur.HasOpacity -or $cur.Opacity -ne $want) { $same = $false }
                    }
                }
                elseif ($cur.HasOpacity) { $same = $false }
            }
            elseif ($name -eq 'useAcrylic') {
                if ($rec.present) {
                    if (-not $cur.HasAcrylic -or $cur.UseAcrylic -ne [bool]$rec.value) { $same = $false }
                }
                elseif ($cur.HasAcrylic) { $same = $false }
            }
        }

        Write-Host '  还原记录   : 有'
        foreach ($prop in $state.keys.PSObject.Properties) {
            if ($prop.Name -eq 'opacity' -or $prop.Name -eq 'useAcrylic') {
                $desc = if ($prop.Value.present) { [string]$prop.Value.value } else { '（原本不存在）' }
                Write-Host "    记录 $($prop.Name) : $desc"
            }
        }
        if ($same) {
            Write-Host '  判定       : 与记录一致，当前处于"未应用 / 已还原"状态。' -ForegroundColor Green
        }
        else {
            Write-Host '  判定       : 与记录不同，当前是应用后的外观；可点"还原"回到基线。' -ForegroundColor Yellow
        }
    }
    Write-Host "  备份目录   : $script:BackupDir"
    Write-Host ''
}

# ---------------------------------------------------------------- GUI

function Set-GuiMessage {
    param($TextBlock, [string]$Text, [string]$Color = '#0F6CBD')
    $TextBlock.Text = $Text
    try {
        $conv = New-Object Windows.Media.BrushConverter
        $TextBlock.Foreground = $conv.ConvertFromString($Color)
    }
    catch { }
}

function Update-GuiStatus {
    param([string]$Path, $Block)
    $c = Get-CurrentSkin -Path $Path
    $s = Read-State
    $lines = @()
    $lines += "配置文件  $Path"
    $lines += "当前外观  不透明度 $($c.Opacity)%   亚克力 $(if ($c.UseAcrylic) { '开启' } else { '关闭' })"
    $lines += "还原记录  $(if ($s) { '有，可还原到使用本工具之前' } else { '无' })"
    $lines += "Terminal  $(if (Get-TerminalRunning) { '运行中，应用后立即生效' } else { '未运行，下次启动生效' })"
    $lines += "备份目录  $($script:BackupDir)"
    $Block.Text = ($lines -join "`r`n")
}

function Start-Gui {
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
        throw '图形界面需要在 STA 线程下运行。请用 Launch.cmd 启动，或改用 powershell.exe（Windows PowerShell 5.1），不要用 pwsh。'
    }

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    try {
        Add-Type -Namespace TgNative -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -ErrorAction Stop
        [void][TgNative.Dpi]::SetProcessDPIAware()
    }
    catch { }

    $path = if ($SettingsPath) { $SettingsPath } else { Find-SettingsPath }
    $cur = Get-CurrentSkin -Path $path

    [xml]$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Terminal 外观"
    Width="540" Height="690"
    WindowStartupLocation="CenterScreen"
    ResizeMode="CanMinimize"
    Background="#F3F3F3"
    FontFamily="Microsoft YaHei UI, Segoe UI"
    UseLayoutRounding="True"
    SnapsToDevicePixels="True">

  <Window.Resources>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="BorderBrush" Value="#E9E9E9"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="18"/>
    </Style>

    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="#0F6CBD" CornerRadius="6" Padding="20,10">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#115EA3"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#0C4A82"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SecondaryBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#1F1F1F"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="White" BorderBrush="#D6D6D6" BorderThickness="1" CornerRadius="6" Padding="20,10">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#F5F5F5"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#EBEBEB"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="GhostBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#6B6B6B"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="Transparent" CornerRadius="6" Padding="16,10">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#E7E7E7"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Pill" TargetType="Button">
      <Setter Property="Foreground" Value="#1F1F1F"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="#F7F7F7" BorderBrush="#E3E3E3" BorderThickness="1" CornerRadius="14" Padding="14,6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#EFEFEF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#E5E5E5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="track" Width="42" Height="24" CornerRadius="12" Background="#C9C9C9">
                <Border x:Name="thumb" Width="18" Height="18" CornerRadius="9" Background="White"
                        HorizontalAlignment="Left" Margin="3,0,0,0"/>
              </Border>
              <ContentPresenter Margin="12,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="#0F6CBD"/>
                <Setter TargetName="thumb" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="thumb" Property="Margin" Value="0,0,3,0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SliderRepeat" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton">
            <Border Background="Transparent" Height="4" CornerRadius="2"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SliderFillRepeat" TargetType="RepeatButton" BasedOn="{StaticResource SliderRepeat}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton">
            <Border Background="#0F6CBD" Height="4" CornerRadius="2"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SliderThumb" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border Width="18" Height="18" CornerRadius="9" Background="White" BorderBrush="#0F6CBD" BorderThickness="2"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ModernSlider" TargetType="Slider">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid Height="22">
              <Border Height="4" CornerRadius="2" Background="#E4E4E4" VerticalAlignment="Center"/>
              <Track x:Name="PART_Track">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="{x:Static Slider.DecreaseLarge}" Style="{StaticResource SliderFillRepeat}"/>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="{x:Static Slider.IncreaseLarge}" Style="{StaticResource SliderRepeat}"/>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Style="{StaticResource SliderThumb}"/>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="22">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0" Margin="2,0,0,18">
      <TextBlock Text="Terminal 外观" FontSize="22" FontWeight="SemiBold" Foreground="#1B1B1B"/>
      <TextBlock Text="只修改 settings.json 的两个外观键，随时可以还原" FontSize="12" Foreground="#8A8A8A" Margin="0,4,0,0"/>
    </StackPanel>

    <Border Grid.Row="1" Style="{StaticResource Card}" Margin="0,0,0,12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0">
          <TextBlock Text="亚克力模糊" FontSize="14" FontWeight="SemiBold" Foreground="#1F1F1F"/>
          <TextBlock Text="Windows 的 Acrylic 材质，实时模糊窗口背后的内容" FontSize="12" Foreground="#8A8A8A" Margin="0,3,0,0" TextWrapping="Wrap"/>
        </StackPanel>
        <CheckBox x:Name="AcrylicSwitch" Grid.Column="1" Style="{StaticResource Switch}" VerticalAlignment="Center"/>
      </Grid>
    </Border>

    <Border Grid.Row="2" Style="{StaticResource Card}" Margin="0,0,0,12">
      <StackPanel>
        <Grid>
          <TextBlock Text="磨砂强度" FontSize="14" FontWeight="SemiBold" Foreground="#1F1F1F" VerticalAlignment="Center"/>
          <TextBlock x:Name="ValueText" Text="85%" FontSize="20" FontWeight="SemiBold" Foreground="#0F6CBD" HorizontalAlignment="Right" VerticalAlignment="Center"/>
        </Grid>
        <Slider x:Name="OpacitySlider" Style="{StaticResource ModernSlider}" Minimum="0" Maximum="100"
                IsSnapToTickEnabled="True" TickFrequency="1" Value="85" Margin="8,14,8,0"/>
        <StackPanel Orientation="Horizontal" Margin="0,14,0,0">
          <Button x:Name="P90" Content="轻 90%" Style="{StaticResource Pill}" Margin="0,0,8,0"/>
          <Button x:Name="P80" Content="中 80%" Style="{StaticResource Pill}" Margin="0,0,8,0"/>
          <Button x:Name="P65" Content="重 65%" Style="{StaticResource Pill}" Margin="0,0,8,0"/>
          <Button x:Name="P40" Content="全透 40%" Style="{StaticResource Pill}"/>
        </StackPanel>
        <TextBlock Text="数值越低越透。模糊半径由 Windows 固定，这里调的是透过率。" FontSize="11" Foreground="#8A8A8A" Margin="0,12,0,0" TextWrapping="Wrap"/>
      </StackPanel>
    </Border>

    <StackPanel Grid.Row="3" Orientation="Horizontal" Margin="0,2,0,10">
      <Button x:Name="ApplyButton" Content="应用" Style="{StaticResource PrimaryBtn}" Width="110"/>
      <Button x:Name="ResetButton" Content="还原" Style="{StaticResource SecondaryBtn}" Width="110" Margin="10,0,0,0"/>
      <Button x:Name="CloseButton" Content="关闭" Style="{StaticResource GhostBtn}" Width="80" Margin="10,0,0,0"/>
    </StackPanel>

    <TextBlock x:Name="MessageText" Grid.Row="4" Text="" FontSize="12" Foreground="#0F6CBD" Margin="2,0,0,8" TextWrapping="Wrap"/>

    <Border Grid.Row="5" Style="{StaticResource Card}" Padding="16" Background="#FAFAFA">
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <TextBlock x:Name="StatusText" FontSize="11.5" Foreground="#6B6B6B" TextWrapping="Wrap" LineHeight="20"/>
      </ScrollViewer>
    </Border>
  </Grid>
</Window>
'@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $win = [Windows.Markup.XamlReader]::Load($reader)

    $slider = $win.FindName('OpacitySlider')
    $valueText = $win.FindName('ValueText')
    $switch = $win.FindName('AcrylicSwitch')
    $msg = $win.FindName('MessageText')
    $status = $win.FindName('StatusText')
    $applyBtn = $win.FindName('ApplyButton')
    $resetBtn = $win.FindName('ResetButton')
    $closeBtn = $win.FindName('CloseButton')

    $slider.Value = [double]([Math]::Max(0, [Math]::Min(100, $cur.Opacity)))
    $valueText.Text = "$([int]$slider.Value)%"
    $switch.IsChecked = $cur.UseAcrylic

    $slider.Add_ValueChanged({
        $valueText.Text = "$([int]$slider.Value)%"
    }.GetNewClosure())

    foreach ($pair in @(@('P90', 90), @('P80', 80), @('P65', 65), @('P40', 40))) {
        $btn = $win.FindName([string]$pair[0])
        $val = [double]$pair[1]
        $btn.Add_Click({ $slider.Value = $val }.GetNewClosure())
    }

    $applyBtn.Add_Click({
        try {
            $v = [int]$slider.Value
            $a = [bool]$switch.IsChecked
            [void](Invoke-WithLock { Set-Skin -Path $path -Opacity $v -Acrylic $a })
            Update-GuiStatus -Path $path -Block $status
            Set-GuiMessage $msg "已应用：不透明度 $v%，亚克力$(if ($a) { '开启' } else { '关闭' })。Terminal 会自动热重载。" '#0F6CBD'
        }
        catch {
            Set-GuiMessage $msg ('应用失败：' + $_.Exception.Message) '#C42B1C'
        }
    }.GetNewClosure())

    $resetBtn.Add_Click({
        try {
            [void](Invoke-WithLock { Undo-Skin -Path $path })
            $c = Get-CurrentSkin -Path $path
            $slider.Value = [double]([Math]::Max(0, [Math]::Min(100, $c.Opacity)))
            $switch.IsChecked = $c.UseAcrylic
            Update-GuiStatus -Path $path -Block $status
            Set-GuiMessage $msg '已还原到使用本工具之前的外观。' '#0F6CBD'
        }
        catch {
            Set-GuiMessage $msg ('还原失败：' + $_.Exception.Message) '#C42B1C'
        }
    }.GetNewClosure())

    $closeBtn.Add_Click({ $win.Close() }.GetNewClosure())

    Update-GuiStatus -Path $path -Block $status
    $win.Add_Loaded({
        $win.Activate()
        $win.TopMost = $true
        $win.TopMost = $false
    }.GetNewClosure())

    [void]$win.ShowDialog()
}

# ---------------------------------------------------------------- 入口

$consoleMode = [bool]($Status -or $Verify -or $Repair -or $Reset -or $Apply -or ($Opacity -ge 0))

try {
    $script:TargetPath = if ($SettingsPath) { $SettingsPath } else { Find-SettingsPath }

    if ($Status) {
        Show-Status
        return
    }

    if ($Verify) {
        Show-Verify
        return
    }

    if ($Repair) {
        $r = Invoke-WithLock { Repair-Defaults -Path $script:TargetPath }
        if ($r.Changed) {
            Write-Host '已清理显式默认值（opacity=100 / useAcrylic=false）。' -ForegroundColor Green
            Write-Host "备份：$($r.Backup)"
        }
        else {
            Write-Host '没有需要清理的显式默认值。'
        }
        return
    }

    if ($Reset) {
        $backup = Invoke-WithLock { Undo-Skin -Path $script:TargetPath }
        Write-Host "已还原到使用本工具之前的外观。" -ForegroundColor Green
        Write-Host "还原前快照：$backup"
        return
    }

    if ($Apply -or $Opacity -ge 0) {
        $value = if ($Opacity -ge 0) { $Opacity } else { 85 }
        $useAcrylic = -not $DisableAcrylic -and $Acrylic
        $backup = Invoke-WithLock { Set-Skin -Path $script:TargetPath -Opacity $value -Acrylic $useAcrylic }
        Write-Host "已应用：不透明度 $value%，亚克力 $(if ($useAcrylic) { '开启' } else { '关闭' })" -ForegroundColor Green
        Write-Host "备份：$backup"
        return
    }

    Start-Gui
}
catch {
    if ($consoleMode) {
        Write-Host ('错误：' + $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    [void][System.Windows.Forms.MessageBox]::Show(
        $_.Exception.Message,
        'TerminalGlass 出错',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error)
}
