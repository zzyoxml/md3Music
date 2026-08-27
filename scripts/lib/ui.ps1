#Requires -Version 5.1
<#
.SYNOPSIS
  MD3Music 脚本的终端 UI 库：鼠标 + 键盘双操作的菜单 / 参数面板 / 勾选列表。

.DESCRIPTION
  由 lib/common.ps1 点源引入，所有交互界面共用一套事件循环与命中测试：

    - 控制台鼠标输入经 ReadConsoleInput + ENABLE_MOUSE_INPUT 开启（点击 / 双击 / 滚轮）
    - 键盘与鼠标事件走同一个 Read-UiEvent，任何界面都能只用键盘完成
    - 定点重绘（不 Clear-Host）：帧内容变化才重画，避免鼠标事件引起闪烁
    - 行级命中测试用行号，按钮命中测试用**显示宽度**（中文占 2 列，不能按字符数算）

  开不了鼠标（旧终端 / 输入被重定向 / QuickEdit 无法关闭）时自动退回纯键盘，不报错。
#>

if (-not ('Md3.ConsoleUi' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Md3 {
  [StructLayout(LayoutKind.Sequential)]
  public struct COORD { public short X; public short Y; }

  [StructLayout(LayoutKind.Sequential)]
  public struct KEY_EVENT_RECORD {
    public int bKeyDown;
    public ushort wRepeatCount;
    public ushort wVirtualKeyCode;
    public ushort wVirtualScanCode;
    public char UnicodeChar;
    public uint dwControlKeyState;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct MOUSE_EVENT_RECORD {
    public COORD dwMousePosition;
    public uint dwButtonState;
    public uint dwControlKeyState;
    public uint dwEventFlags;
  }

  [StructLayout(LayoutKind.Explicit)]
  public struct INPUT_RECORD {
    [FieldOffset(0)] public ushort EventType;
    [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
    [FieldOffset(4)] public MOUSE_EVENT_RECORD MouseEvent;
  }

  public static class ConsoleUi {
    public const ushort KEY_EVENT = 0x0001;
    public const ushort MOUSE_EVENT = 0x0002;
    public const uint ENABLE_PROCESSED_INPUT = 0x0001;
    public const uint ENABLE_MOUSE_INPUT = 0x0010;
    public const uint ENABLE_QUICK_EDIT_MODE = 0x0040;
    public const uint ENABLE_EXTENDED_FLAGS = 0x0080;

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr CreateFileW(string name, uint access, uint share,
      IntPtr sec, uint disp, uint flags, IntPtr templ);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleMode(IntPtr h, uint mode);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool ReadConsoleInputW(IntPtr h,
      [Out] INPUT_RECORD[] buf, uint len, out uint read);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetNumberOfConsoleInputEvents(IntPtr h, out uint n);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetStdHandle(int nStdHandle);

    // 输入被重定向时 STD_INPUT_HANDLE 不是控制台句柄，优先直接打开 CONIN$；
    // 个别宿主下 CONIN$ 打不开（返回 -1），再退回标准输入句柄。
    public static IntPtr OpenConsoleInput() {
      IntPtr h = CreateFileW("CONIN$", 0x80000000 | 0x40000000, 1 | 2, IntPtr.Zero, 3, 0, IntPtr.Zero);
      if (h == IntPtr.Zero || h == new IntPtr(-1)) {
        uint mode;
        IntPtr std = GetStdHandle(-10);
        if (std != IntPtr.Zero && std != new IntPtr(-1) && GetConsoleMode(std, out mode)) return std;
        return new IntPtr(-1);
      }
      return h;
    }

    public static INPUT_RECORD ReadOne(IntPtr h) {
      INPUT_RECORD[] buf = new INPUT_RECORD[1];
      uint read;
      ReadConsoleInputW(h, buf, 1, out read);
      return buf[0];
    }
  }
}
'@
}

# ---------- 环境探测 ----------
# 输入/输出被重定向（管道、CI、被其他脚本调用）时 RawUI.ReadKey 不抛错而是**阻塞**，
# 所以进任何界面前都要先探测，否则调用方看到的是无响应的挂起。
function Test-InteractiveConsole {
    try { if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { return $false } } catch { }
    try { $null = $Host.UI.RawUI.KeyAvailable; return $true } catch { return $false }
}

# 交互式 y/n 确认（非交互环境请走显式参数，勿调用本函数——Read-Host 会阻塞）
function Read-YesNo {
    param([Parameter(Mandatory)][string]$Prompt, [bool]$Default = $false)
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $a = Read-Host "$Prompt $hint"
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    $a.Trim().ToLowerInvariant() -in @('y', 'yes', '是')
}

# ---------- 鼠标输入 ----------
$script:UiMouseHandle = [IntPtr]::Zero
$script:UiMouseSavedMode = $null

function Enable-ConsoleMouse {
    if ($script:UiMouseHandle -ne [IntPtr]::Zero) { return $true }
    if (-not (Test-InteractiveConsole)) { return $false }
    try {
        $h = [Md3.ConsoleUi]::OpenConsoleInput()
        if ($h -eq [IntPtr]::Zero -or $h -eq [IntPtr]-1) { return $false }
        $mode = 0
        if (-not [Md3.ConsoleUi]::GetConsoleMode($h, [ref]$mode)) { return $false }
        # 必须同时关掉 QuickEdit（否则控制台自己吃掉点击做文本选择）并置 EXTENDED_FLAGS，
        # 否则 SetConsoleMode 对 QuickEdit 位的修改不生效。
        $new = ($mode -bor [Md3.ConsoleUi]::ENABLE_MOUSE_INPUT -bor [Md3.ConsoleUi]::ENABLE_EXTENDED_FLAGS) `
            -band (-bnot [Md3.ConsoleUi]::ENABLE_QUICK_EDIT_MODE)
        if (-not [Md3.ConsoleUi]::SetConsoleMode($h, $new)) { return $false }
        $script:UiMouseSavedMode = $mode
        $script:UiMouseHandle = $h
        return $true
    } catch { return $false }
}

function Disable-ConsoleMouse {
    if ($script:UiMouseHandle -eq [IntPtr]::Zero) { return }
    try { [void][Md3.ConsoleUi]::SetConsoleMode($script:UiMouseHandle, $script:UiMouseSavedMode) } catch { }
    $script:UiMouseHandle = [IntPtr]::Zero
    $script:UiMouseSavedMode = $null
}

function Test-MouseEnabled { $script:UiMouseHandle -ne [IntPtr]::Zero }

# ---------- 统一事件读取 ----------
# 把一条 INPUT_RECORD 解成界面事件；返回 $null 表示该记录应被忽略。
# 单独成函数是为了能不依赖真实控制台地验证 union 偏移与滚轮符号的解码。
function ConvertTo-UiEvent {
    param([Parameter(Mandatory)]$Record)
    if ($Record.EventType -eq [Md3.ConsoleUi]::KEY_EVENT) {
        if ($Record.KeyEvent.bKeyDown -eq 0) { return $null }
        # 单独的修饰键按下不算事件
        if ($Record.KeyEvent.wVirtualKeyCode -in @(16, 17, 18, 20, 91, 92)) { return $null }
        return [pscustomobject]@{
            Type = 'Key'; Code = [int]$Record.KeyEvent.wVirtualKeyCode
            Char = "$($Record.KeyEvent.UnicodeChar)"; X = -1; Y = -1; Delta = 0
        }
    }
    if ($Record.EventType -eq [Md3.ConsoleUi]::MOUSE_EVENT) {
        $m = $Record.MouseEvent
        $flags = $m.dwEventFlags
        if ($flags -band 0x4) {
            # MOUSE_WHEELED：滚动量在 dwButtonState 高 16 位，按有符号解释
            $delta = if (((([int64]$m.dwButtonState) -shr 16) -band 0x8000) -ne 0) { -1 } else { 1 }
            return [pscustomobject]@{ Type = 'Wheel'; Code = 0; Char = ''; X = [int]$m.dwMousePosition.X; Y = [int]$m.dwMousePosition.Y; Delta = $delta }
        }
        if ($flags -band 0x1) { return $null }        # MOUSE_MOVED：忽略，避免无谓重绘
        # 只响应左键（0x1）；抬起、右键、中键忽略，右键留给终端自身的复制粘贴
        if (-not ($m.dwButtonState -band 0x1)) { return $null }
        $type = if ($flags -band 0x2) { 'DoubleClick' } else { 'Click' }
        return [pscustomobject]@{ Type = $type; Code = 0; Char = ''; X = [int]$m.dwMousePosition.X; Y = [int]$m.dwMousePosition.Y; Delta = 0 }
    }
    $null
}

<#
  返回 [pscustomobject]：
    Type   = 'Key' | 'Click' | 'DoubleClick' | 'Wheel'
    Code   = 键的 VirtualKeyCode（Type=Key）
    Char   = 键的字符（Type=Key）
    X / Y  = 鼠标所在的**屏幕缓冲区**列 / 行（鼠标事件）
    Delta  = 滚轮方向 +1 上滚 / -1 下滚
  鼠标未开启时退化为纯键盘（$Host.UI.RawUI.ReadKey）。
#>
function Read-UiEvent {
    param([string]$FallbackHint = '请在 PowerShell 窗口中运行，或直接用命令行参数调用。')
    if (-not (Test-InteractiveConsole)) {
        throw "当前宿主不支持交互操作（非控制台环境）。$FallbackHint"
    }
    if (-not (Test-MouseEnabled)) {
        $k = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        return [pscustomobject]@{ Type = 'Key'; Code = $k.VirtualKeyCode; Char = "$($k.Character)"; X = -1; Y = -1; Delta = 0 }
    }
    while ($true) {
        $e = ConvertTo-UiEvent ([Md3.ConsoleUi]::ReadOne($script:UiMouseHandle))
        if ($e) { return $e }
    }
}

# 兼容旧调用点：只要一个按键
function Read-ConsoleKey {
    param([string]$FallbackHint = '请在 PowerShell 窗口中运行，或直接用命令行参数调用。')
    while ($true) {
        $e = Read-UiEvent -FallbackHint $FallbackHint
        if ($e.Type -eq 'Key') {
            return [pscustomobject]@{ VirtualKeyCode = $e.Code; Character = $e.Char }
        }
        if ($e.Type -in @('Click', 'DoubleClick')) {
            return [pscustomobject]@{ VirtualKeyCode = 13; Character = "`r" }
        }
    }
}

function Wait-AnyKey([string]$Msg = '按任意键继续（或点击窗口）...') {
    Write-Host ''
    Write-Host $Msg -ForegroundColor Cyan
    $null = Read-ConsoleKey
}

# ---------- 显示宽度 ----------
# 中文/全角字符占 2 列。按钮的点击列范围必须按显示宽度算，按字符数算会整体偏移。
function Get-DisplayWidth([string]$S) {
    $w = 0
    foreach ($ch in "$S".ToCharArray()) {
        $c = [int][char]$ch
        if ($c -ge 0x1100 -and (
                $c -le 0x115F -or $c -eq 0x2329 -or $c -eq 0x232A -or
                ($c -ge 0x2E80 -and $c -le 0xA4CF -and $c -ne 0x303F) -or
                ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
                ($c -ge 0xF900 -and $c -le 0xFAFF) -or
                ($c -ge 0xFE30 -and $c -le 0xFE6F) -or
                ($c -ge 0xFF00 -and $c -le 0xFF60) -or
                ($c -ge 0xFFE0 -and $c -le 0xFFE6))) { $w += 2 } else { $w += 1 }
    }
    $w
}

function Add-DisplayPad([string]$S, [int]$Width) {
    $pad = $Width - (Get-DisplayWidth $S)
    if ($pad -gt 0) { "$S" + (' ' * $pad) } else { "$S" }
}

# 按显示宽度截断（超长路径 / 长信息用）
function Limit-DisplayWidth([string]$S, [int]$Width, [switch]$FromEnd) {
    if ((Get-DisplayWidth $S) -le $Width) { return "$S" }
    $chars = "$S".ToCharArray()
    if ($FromEnd) {
        $acc = ''; $w = 0
        for ($i = $chars.Count - 1; $i -ge 0; $i--) {
            $cw = Get-DisplayWidth $chars[$i]
            if ($w + $cw -gt $Width - 1) { break }
            $acc = "$($chars[$i])$acc"; $w += $cw
        }
        return "…$acc"
    }
    $acc = ''; $w = 0
    foreach ($ch in $chars) {
        $cw = Get-DisplayWidth $ch
        if ($w + $cw -gt $Width - 1) { break }
        $acc += $ch; $w += $cw
    }
    "$acc…"
}

# ---------- 帧渲染与命中测试 ----------
# 定点重绘：Reset-UiScreen 记下起始行，之后每帧回到同一行覆盖写，不 Clear-Host（不闪）。
$script:UiTop = 0
$script:UiPrevLines = 0
$script:UiFrame = @()

function New-UiLine {
    param([string]$Text = '', [string]$Color = 'Gray', $Hit = $null)
    [pscustomobject]@{ Text = $Text; Color = $Color; Hit = $Hit }
}

function Reset-UiScreen {
    Clear-Host
    $script:UiTop = try { [Console]::CursorTop } catch { 0 }
    $script:UiPrevLines = 0
    $script:UiFrame = @()
}

function Get-UiViewportHeight {
    param([int]$Chrome = 8)
    $h = try { [Console]::WindowHeight } catch { 30 }
    [Math]::Max(3, $h - $Chrome)
}

function Write-UiFrame {
    param([Parameter(Mandatory)][object[]]$Lines)
    $w = try { [Math]::Max(20, [Console]::BufferWidth - 1) } catch { 100 }
    # 帧高超过窗口时先清屏重置起点，否则缓冲区滚动会让记录的起始行失效、点击错位
    $wh = try { [Console]::WindowHeight } catch { 30 }
    if ($Lines.Count -ge $wh) { Clear-Host; $script:UiTop = 0; $script:UiPrevLines = 0 }
    try { [Console]::SetCursorPosition(0, $script:UiTop) } catch { Reset-UiScreen }
    foreach ($l in $Lines) {
        Write-Host (Add-DisplayPad (Limit-DisplayWidth $l.Text $w) $w) -ForegroundColor $l.Color
    }
    for ($i = $Lines.Count; $i -lt $script:UiPrevLines; $i++) { Write-Host (' ' * $w) }
    $script:UiPrevLines = [Math]::Max($Lines.Count, $script:UiPrevLines)
    $script:UiFrame = $Lines
}

# 返回被点中的对象：@{Type='Item';Index=n} / @{Type='Button';Action='run'} / $null
function Get-UiHit {
    param([Parameter(Mandatory)]$UiEvent)
    $row = $UiEvent.Y - $script:UiTop
    if ($row -lt 0 -or $row -ge @($script:UiFrame).Count) { return $null }
    $hit = $script:UiFrame[$row].Hit
    if (-not $hit) { return $null }
    if ($hit.Type -eq 'Buttons') {
        foreach ($r in $hit.Regions) {
            if ($UiEvent.X -ge $r.S -and $UiEvent.X -le $r.E) { return @{ Type = 'Button'; Action = $r.Action } }
        }
        return $null
    }
    $hit
}

# 按钮行：$Buttons = @(@{Text='执行';Action='run'}, ...)；列范围按显示宽度计算
function New-ButtonRow {
    param([Parameter(Mandatory)][object[]]$Buttons, [int]$Indent = 2, [string]$Color = 'White')
    $text = ' ' * $Indent
    $regions = @()
    foreach ($b in $Buttons) {
        $s = Get-DisplayWidth $text
        $text += "[ $($b.Text) ]"
        $regions += @{ S = $s; E = (Get-DisplayWidth $text) - 1; Action = $b.Action }
        $text += '  '
    }
    New-UiLine -Text $text.TrimEnd() -Color $Color -Hit @{ Type = 'Buttons'; Regions = $regions }
}

function Get-MouseHintLine {
    if (Test-MouseEnabled) { New-UiLine -Text '  鼠标：单击选中 / 双击执行 / 点按钮 / 滚轮滚动　　键盘：↑↓ Enter Esc' -Color 'DarkGray' }
    else { New-UiLine -Text '  键盘操作（当前终端未启用鼠标）：↑↓ 移动   Enter 确认   Esc 返回' -Color 'DarkGray' }
}

# ---------- 单选菜单 ----------
function New-MenuItem {
    param([string]$Key, [string]$Label, [string]$Desc, [bool]$Enabled = $true)
    [pscustomobject]@{ Key = $Key; Label = $Label; Desc = $Desc; Enabled = $Enabled }
}

# 光标只停在 Enabled 项上，首尾循环
function Get-AdjacentEnabledIndex {
    param([Parameter(Mandatory)][object[]]$Items, [int]$From, [int]$Step)
    $n = $Items.Count
    for ($i = 1; $i -le $n; $i++) {
        $idx = (($From + $Step * $i) % $n + $n) % $n
        if ($Items[$idx].Enabled) { return $idx }
    }
    $From
}

<#
  返回 [pscustomobject]{ Index; Action }，Action = 'run'（直接执行）或 'config'（先配参数）；
  取消返回 $null。
#>
function Show-Menu {
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [string]$Title = '',
        [string]$Footer = '',
        [switch]$WithConfig
    )
    if (-not @($Items | Where-Object Enabled).Count) { throw '菜单没有可用项' }
    $cursor = Get-AdjacentEnabledIndex -Items $Items -From ($Items.Count - 1) -Step 1
    $width = ($Items | ForEach-Object { Get-DisplayWidth $_.Label } | Measure-Object -Maximum).Maximum
    Reset-UiScreen
    while ($true) {
        $lines = @()
        $lines += New-UiLine -Text "  $Title" -Color 'Cyan'
        $lines += New-UiLine
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $it = $Items[$i]
            $mark = if ($i -eq $cursor) { '>' } else { ' ' }
            $tag = if ($it.Enabled) { '' } else { '(当前树不可用) ' }
            $color = if (-not $it.Enabled) { 'DarkGray' } elseif ($i -eq $cursor) { 'Cyan' } else { 'White' }
            $lines += New-UiLine -Text ("  $mark " + (Add-DisplayPad $it.Label $width) + "   $tag$($it.Desc)") `
                -Color $color -Hit @{ Type = 'Item'; Index = $i }
        }
        $lines += New-UiLine
        $btns = @(@{ Text = '执行'; Action = 'run' })
        if ($WithConfig) { $btns += @{ Text = '参数'; Action = 'config' } }
        $btns += @{ Text = '退出'; Action = 'quit' }
        $lines += New-ButtonRow -Buttons $btns -Color 'Yellow'
        $lines += Get-MouseHintLine
        if ($WithConfig) { $lines += New-UiLine -Text '  空格 / 点[参数] 可先勾选参数再执行' -Color 'DarkGray' }
        if ($Footer) { $lines += New-UiLine -Text "  $Footer" -Color 'DarkGray' }
        Write-UiFrame -Lines $lines

        $e = Read-UiEvent
        if ($e.Type -eq 'Wheel') {
            $cursor = Get-AdjacentEnabledIndex -Items $Items -From $cursor -Step (-1 * $e.Delta)
            continue
        }
        if ($e.Type -in @('Click', 'DoubleClick')) {
            $hit = Get-UiHit -UiEvent $e
            if (-not $hit) { continue }
            if ($hit.Type -eq 'Button') {
                switch ($hit.Action) {
                    'run'    { return [pscustomobject]@{ Index = $cursor; Action = 'run' } }
                    'config' { return [pscustomobject]@{ Index = $cursor; Action = 'config' } }
                    'quit'   { return $null }
                }
                continue
            }
            if (-not $Items[$hit.Index].Enabled) { continue }
            $cursor = $hit.Index
            if ($e.Type -eq 'DoubleClick') { return [pscustomobject]@{ Index = $cursor; Action = 'run' } }
            continue
        }
        # 注意：不在 switch 里用 continue（PowerShell 的 switch 与循环共享 break/continue 语义，
        # 容易误跳出外层 while）。方向键的 Char 是 \0，落到下面的字符 switch 不会命中。
        switch ($e.Code) {
            38 { $cursor = Get-AdjacentEnabledIndex -Items $Items -From $cursor -Step -1 }
            40 { $cursor = Get-AdjacentEnabledIndex -Items $Items -From $cursor -Step 1 }
            13 { return [pscustomobject]@{ Index = $cursor; Action = 'run' } }
            27 { return $null }
            32 { if ($WithConfig) { return [pscustomobject]@{ Index = $cursor; Action = 'config' } } }
            9  { if ($WithConfig) { return [pscustomobject]@{ Index = $cursor; Action = 'config' } } }
        }
        switch ("$($e.Char)".ToLowerInvariant()) {
            'k' { $cursor = Get-AdjacentEnabledIndex -Items $Items -From $cursor -Step -1 }
            'j' { $cursor = Get-AdjacentEnabledIndex -Items $Items -From $cursor -Step 1 }
            'q' { return $null }
        }
    }
}

# ---------- 参数面板 ----------
# 参数项：switch = 开关；value = 需要取值（空格/点击进入输入，回车留空即清除）
function New-TaskOption {
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('switch', 'value')][string]$Kind = 'switch',
        [string]$Desc = '',
        [string]$Value = ''
    )
    [pscustomobject]@{ Name = $Name; Kind = $Kind; Desc = $Desc; Checked = $false; Value = $Value }
}

# 把勾选结果拼成参数数组（数组透传给任务脚本，值里的空格无需自行转义）
function Get-OptionArgs {
    param([object[]]$Options)
    $a = @()
    foreach ($o in @($Options)) {
        if ($o.Kind -eq 'switch') { if ($o.Checked) { $a += $o.Name } }
        elseif ($o.Value) { $a += @($o.Name, $o.Value) }
    }
    , $a
}

function Format-ArgPreview {
    param([object[]]$ArgList)
    (@($ArgList) | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
}

# 输入一行文本（临时让出界面，输入后回到帧渲染）
function Read-UiText {
    param([Parameter(Mandatory)][string]$Prompt)
    $mouseWasOn = Test-MouseEnabled
    if ($mouseWasOn) { Disable-ConsoleMouse }   # Read-Host 需要正常的行输入模式
    Clear-Host
    Write-Host ''
    Write-Host "  $Prompt" -ForegroundColor Cyan
    $v = Read-Host '  > '
    if ($mouseWasOn) { [void](Enable-ConsoleMouse) }
    Reset-UiScreen
    "$v".Trim()
}

# ---------- 多行文本编辑器 ----------
# 供 commit 的起草结果就地改写用：整段文本进来，改完出去，像文本编辑器一样移动光标。
# 编辑状态与按键处理拆成纯函数（New-TextBufferState / Invoke-TextBufferKey），
# 不依赖真实控制台，可在 ui.tests.ps1 里直接断言。

function New-TextBufferState {
    param([AllowEmptyString()][string]$Text = '')
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($l in @("$Text" -split "`r?`n")) { [void]$lines.Add("$l") }
    if ($lines.Count -eq 0) { [void]$lines.Add('') }
    [pscustomobject]@{ Lines = $lines; Row = 0; Col = 0; Top = 0; Dirty = $false }
}

function Get-TextBufferText { param([Parameter(Mandatory)]$State) ($State.Lines -join "`n") }

function Set-TextBufferCursor {
    param([Parameter(Mandatory)]$State, [int]$Row, [int]$Col)
    $State.Row = [Math]::Max(0, [Math]::Min($State.Lines.Count - 1, $Row))
    $State.Col = [Math]::Max(0, [Math]::Min($State.Lines[$State.Row].Length, $Col))
}

<#
  处理一个界面事件，就地更新 $State。返回动作：
    ''（继续编辑）/ 'save'（保存退出）/ 'cancel'（放弃）/ 'external'（转外部编辑器）
  $Page 是 PgUp/PgDn 的翻页行数（由调用方按视口高度传入）。
#>
function Invoke-TextBufferKey {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$UiEvent, [int]$Page = 10)
    if ($UiEvent.Type -eq 'Wheel') {
        Set-TextBufferCursor -State $State -Row ($State.Row - 3 * $UiEvent.Delta) -Col $State.Col
        return ''
    }
    if ($UiEvent.Type -ne 'Key') { return '' }
    $row = $State.Row
    $line = $State.Lines[$row]
    $ch = "$($UiEvent.Char)"
    $code = if ($ch.Length -eq 1) { [int][char]$ch } else { -1 }
    # Ctrl 组合：RawUI.ReadKey 给的是控制字符（Ctrl+S = 0x13、Ctrl+E = 0x05）
    if ($code -eq 19) { return 'save' }
    if ($code -eq 5)  { return 'external' }
    switch ($UiEvent.Code) {
        113 { return 'save' }        # F2
        27  { return 'cancel' }      # Esc
        37 {                         # ←
            if ($State.Col -gt 0) { $State.Col-- }
            elseif ($row -gt 0) { $State.Row--; $State.Col = $State.Lines[$State.Row].Length }
            return ''
        }
        39 {                         # →
            if ($State.Col -lt $line.Length) { $State.Col++ }
            elseif ($row -lt $State.Lines.Count - 1) { $State.Row++; $State.Col = 0 }
            return ''
        }
        38 { Set-TextBufferCursor -State $State -Row ($row - 1) -Col $State.Col; return '' }        # ↑
        40 { Set-TextBufferCursor -State $State -Row ($row + 1) -Col $State.Col; return '' }        # ↓
        36 { $State.Col = 0; return '' }                                                            # Home
        35 { $State.Col = $line.Length; return '' }                                                 # End
        33 { Set-TextBufferCursor -State $State -Row ($row - $Page) -Col $State.Col; return '' }     # PgUp
        34 { Set-TextBufferCursor -State $State -Row ($row + $Page) -Col $State.Col; return '' }     # PgDn
        13 {                         # Enter：在光标处断行
            $State.Lines[$row] = $line.Substring(0, $State.Col)
            $State.Lines.Insert($row + 1, $line.Substring($State.Col))
            $State.Row = $row + 1
            $State.Col = 0
            $State.Dirty = $true
            return ''
        }
        8 {                          # Backspace
            if ($State.Col -gt 0) {
                $State.Lines[$row] = $line.Remove($State.Col - 1, 1)
                $State.Col--
                $State.Dirty = $true
            }
            elseif ($row -gt 0) {
                $prev = $State.Lines[$row - 1]
                $State.Lines[$row - 1] = $prev + $line
                $State.Lines.RemoveAt($row)
                $State.Row = $row - 1
                $State.Col = $prev.Length
                $State.Dirty = $true
            }
            return ''
        }
        46 {                         # Delete
            if ($State.Col -lt $line.Length) {
                $State.Lines[$row] = $line.Remove($State.Col, 1)
                $State.Dirty = $true
            }
            elseif ($row -lt $State.Lines.Count - 1) {
                $State.Lines[$row] = $line + $State.Lines[$row + 1]
                $State.Lines.RemoveAt($row + 1)
                $State.Dirty = $true
            }
            return ''
        }
        9 {                          # Tab：两个空格，避免制表符在不同终端宽度不一
            $State.Lines[$row] = $line.Insert($State.Col, '  ')
            $State.Col += 2
            $State.Dirty = $true
            return ''
        }
    }
    if ($code -ge 32) {              # 可打印字符（含中文）
        $State.Lines[$row] = $line.Insert($State.Col, $ch)
        $State.Col += $ch.Length
        $State.Dirty = $true
    }
    ''
}

# 取一行在水平视窗 [$FromCol, $FromCol+$Width) 内的可见部分（按显示宽度算，中文占 2 列）
function Get-LineWindow {
    param([AllowEmptyString()][string]$Text, [int]$FromCol, [int]$Width)
    if ($FromCol -le 0 -and (Get-DisplayWidth $Text) -le $Width) { return "$Text" }
    $skip = 0; $w = 0
    foreach ($chunk in "$Text".ToCharArray()) {
        if ($w -ge $FromCol) { break }
        $w += (Get-DisplayWidth $chunk); $skip++
    }
    $rest = if ($skip -ge "$Text".Length) { '' } else { "$Text".Substring($skip) }
    $acc = ''; $w = 0
    foreach ($chunk in $rest.ToCharArray()) {
        $cw = Get-DisplayWidth $chunk
        if ($w + $cw -gt $Width) { break }
        $acc += $chunk; $w += $cw
    }
    $acc
}

<#
  找一个外部编辑器：MD3_EDITOR > VISUAL > EDITOR > git config core.editor > code --wait > notepad。
  返回 @{ Exe; Args }（$Args 里的 {} 占位由调用方替换成文件路径），找不到返回 $null。
  注意 code / codium 这类会立刻返回的启动器必须带 --wait，否则脚本会读到未编辑的文件。
#>
function Get-ExternalEditor {
    $cands = @()
    foreach ($v in @($env:MD3_EDITOR, $env:VISUAL, $env:EDITOR)) {
        if ($v) { $cands += "$v" }
    }
    try {
        $g = & git config --get core.editor 2>$null
        if ($LASTEXITCODE -eq 0 -and "$g".Trim()) { $cands += "$g".Trim() }
    } catch { }
    foreach ($c in $cands) {
        $exe = $c; $rest = ''
        if ($c -match '^\s*"([^"]+)"\s*(.*)$') { $exe = $Matches[1]; $rest = $Matches[2] }
        elseif ($c -match '^\s*(\S+)\s*(.*)$') { $exe = $Matches[1]; $rest = $Matches[2] }
        if (-not (Test-HasCommand $exe) -and -not (Test-Path -LiteralPath $exe)) { continue }
        $edArgs = @()
        if ($rest) { $edArgs += @($rest -split '\s+' | Where-Object { $_ }) }
        # 命令行里给的编辑器多半没写 --wait，补上（VS Code 系不等就读不到改动）
        if ($exe -match '(?i)(^|\\|/)(code|code-insiders|codium)(\.cmd|\.exe)?$' -and $edArgs -notcontains '--wait' -and $edArgs -notcontains '-w') {
            $edArgs += '--wait'
        }
        return @{ Exe = $exe; Args = $edArgs }
    }
    if (Test-HasCommand 'code') { return @{ Exe = 'code'; Args = @('--wait') } }
    if (Test-HasCommand 'notepad.exe') { return @{ Exe = 'notepad.exe'; Args = @() } }
    $null
}

# 用外部编辑器改一段文本：写临时文件 -> 等编辑器退出 -> 读回。找不到编辑器返回 $null。
function Edit-TextWithExternalEditor {
    param([AllowEmptyString()][string]$Text = '', [string]$Extension = '.md')
    $ed = Get-ExternalEditor
    if (-not $ed) { return $null }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("md3-edit-" + [Guid]::NewGuid().ToString('N') + $Extension)
    [IO.File]::WriteAllText($tmp, "$Text", (New-Object Text.UTF8Encoding($true)))
    try {
        Write-Host ''
        Write-Host "  已用 $($ed.Exe) 打开草稿，改完保存并关闭编辑器…" -ForegroundColor Cyan
        $p = Start-Process -FilePath $ed.Exe -ArgumentList (@($ed.Args) + @("`"$tmp`"")) -PassThru -Wait
        if ($p.ExitCode -ne 0) { Write-Warn "编辑器退出码 $($p.ExitCode)，仍按文件内容读取" }
        [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)
    }
    finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
}

<#
  终端内嵌的多行编辑器。返回改好的文本；按 Esc 放弃返回 $null。
  非交互控制台下直接返回原文（调用方自己决定退路）。
  按键：↑↓←→ / Home / End / PgUp / PgDn 移动，Enter 换行，Backspace / Delete 删除，
        Ctrl+S 或 F2 保存退出，Esc 放弃，Ctrl+E 转到外部编辑器；鼠标点击定位、滚轮滚动。
#>
function Show-TextEditor {
    param(
        [AllowEmptyString()][string]$Text = '',
        [string]$Title = '编辑内容',
        [string]$Extension = '.md'
    )
    if (-not (Test-InteractiveConsole)) { return "$Text" }
    $s = New-TextBufferState -Text $Text
    $mouse = Enable-ConsoleMouse
    $prevCursor = try { [Console]::CursorVisible } catch { $true }
    Reset-UiScreen
    try {
        while ($true) {
            $w = try { [Math]::Max(20, [Console]::BufferWidth - 1) } catch { 100 }
            $view = Get-UiViewportHeight -Chrome 7
            $bodyW = [Math]::Max(10, $w - 4)
            # 垂直滚动：光标始终留在视口内
            if ($s.Row -lt $s.Top) { $s.Top = $s.Row }
            if ($s.Row -ge $s.Top + $view) { $s.Top = $s.Row - $view + 1 }
            if ($s.Top -gt $s.Lines.Count - 1) { $s.Top = [Math]::Max(0, $s.Lines.Count - 1) }
            # 水平滚动：按光标前文本的显示宽度算，让光标列可见
            $curLine = $s.Lines[$s.Row]
            $curW = Get-DisplayWidth $curLine.Substring(0, $s.Col)
            $left = if ($curW -ge $bodyW) { $curW - $bodyW + 1 } else { 0 }

            $lines = @()
            $lines += New-UiLine -Text "  $Title" -Color 'Cyan'
            $lines += New-UiLine -Text "  行 $($s.Row + 1)/$($s.Lines.Count)   列 $($s.Col + 1)$(if ($s.Dirty) { '   (已修改)' })" -Color 'DarkGray'
            $lines += New-UiLine
            $bodyTop = $lines.Count
            for ($i = 0; $i -lt $view; $i++) {
                $idx = $s.Top + $i
                if ($idx -ge $s.Lines.Count) { $lines += New-UiLine; continue }
                $text = Get-LineWindow -Text $s.Lines[$idx] -FromCol $left -Width $bodyW
                $color = if ($s.Lines[$idx] -match '^===\s') { 'Yellow' }
                         elseif ($s.Lines[$idx] -match '^\s*#') { 'DarkGray' }
                         elseif ($idx -eq $s.Row) { 'White' } else { 'Gray' }
                $lines += New-UiLine -Text ('  ' + $text) -Color $color -Hit @{ Type = 'Item'; Index = $idx }
            }
            $lines += New-UiLine
            $lines += New-UiLine -Text '  Ctrl+S / F2 保存并继续　Esc 放弃修改　Ctrl+E 转外部编辑器' -Color 'DarkCyan'
            Write-UiFrame -Lines $lines

            # 把真实光标放到编辑位置（比自绘一个反色块稳，且中文宽度天然对齐）
            try {
                [Console]::CursorVisible = $true
                [Console]::SetCursorPosition(
                    [Math]::Min($w, 2 + ($curW - $left)),
                    $script:UiTop + $bodyTop + ($s.Row - $s.Top))
            } catch { }

            $e = Read-UiEvent
            if ($e.Type -in @('Click', 'DoubleClick')) {
                $hit = Get-UiHit -UiEvent $e
                if ($hit -and $hit.Type -eq 'Item') {
                    # 点击列 -> 字符位置：按显示宽度从行首累加
                    $targetW = [Math]::Max(0, $e.X - 2) + $left
                    $line = $s.Lines[$hit.Index]
                    $col = 0; $acc = 0
                    foreach ($c in $line.ToCharArray()) {
                        if ($acc -ge $targetW) { break }
                        $acc += (Get-DisplayWidth $c); $col++
                    }
                    Set-TextBufferCursor -State $s -Row $hit.Index -Col $col
                }
                continue
            }
            $act = Invoke-TextBufferKey -State $s -UiEvent $e -Page $view
            switch ($act) {
                'save'   { return (Get-TextBufferText -State $s) }
                'cancel' { return $null }
                'external' {
                    if ($mouse) { Disable-ConsoleMouse }
                    $r = Edit-TextWithExternalEditor -Text (Get-TextBufferText -State $s) -Extension $Extension
                    if ($null -eq $r) { Write-Warn '没找到可用的外部编辑器（可设 MD3_EDITOR / EDITOR 或 git config core.editor）'; Wait-AnyKey }
                    else { return $r }
                    if (-not (Test-MouseEnabled)) { $mouse = Enable-ConsoleMouse }
                    Reset-UiScreen
                }
            }
        }
    }
    finally {
        if ($mouse) { Disable-ConsoleMouse }
        try { [Console]::CursorVisible = $prevCursor } catch { }
        Clear-Host
    }
}

<#
  参数勾选面板。就地修改 $Options。返回 $true=执行 / $false=返回上一级。
  无可选参数时直接返回 $true（不让用户多按一次回车）。
#>
function Show-OptionPicker {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Options,
        [string]$Title = '',
        [string]$CommandPrefix = ''
    )
    if (-not @($Options).Count) { return $true }
    $cursor = 0
    $width = ($Options | ForEach-Object { Get-DisplayWidth $_.Name } | Measure-Object -Maximum).Maximum
    Reset-UiScreen
    while ($true) {
        $lines = @()
        $lines += New-UiLine -Text "  $Title" -Color 'Cyan'
        $lines += New-UiLine
        for ($i = 0; $i -lt $Options.Count; $i++) {
            $o = $Options[$i]
            $on = if ($o.Kind -eq 'switch') { $o.Checked } else { [bool]$o.Value }
            $box = if ($o.Kind -eq 'switch') { if ($o.Checked) { '[x]' } else { '[ ]' } }
                   elseif ($o.Value) { '[=]' } else { '[ ]' }
            $mark = if ($i -eq $cursor) { '>' } else { ' ' }
            $suffix = if ($o.Kind -eq 'value' -and $o.Value) { "   = $($o.Value)" }
                      elseif ($o.Kind -eq 'value') { '   （点击或空格输入）' } else { '' }
            $color = if ($i -eq $cursor) { 'Cyan' } elseif ($on) { 'White' } else { 'DarkGray' }
            $lines += New-UiLine -Text ("  $mark $box " + (Add-DisplayPad $o.Name $width) + "   $($o.Desc)$suffix") `
                -Color $color -Hit @{ Type = 'Item'; Index = $i }
        }
        $lines += New-UiLine
        $lines += New-ButtonRow -Buttons @(
            @{ Text = '执行'; Action = 'run' }
            @{ Text = '清空参数'; Action = 'clear' }
            @{ Text = '返回'; Action = 'back' }
        ) -Color 'Yellow'
        $preview = Format-ArgPreview (Get-OptionArgs $Options)
        $lines += New-UiLine -Text "  将执行：$CommandPrefix$(if ($preview) { " $preview" })" -Color 'Yellow'
        $lines += Get-MouseHintLine
        Write-UiFrame -Lines $lines

        $e = Read-UiEvent
        $act = $null
        if ($e.Type -eq 'Wheel') {
            $cursor = [Math]::Max(0, [Math]::Min($Options.Count - 1, $cursor - $e.Delta))
            continue
        }
        if ($e.Type -in @('Click', 'DoubleClick')) {
            $hit = Get-UiHit -UiEvent $e
            if (-not $hit) { continue }
            if ($hit.Type -eq 'Button') { $act = $hit.Action }
            else { $cursor = $hit.Index; $act = 'toggle' }
        }
        else {
            switch ($e.Code) {
                38 { $cursor = if ($cursor -gt 0) { $cursor - 1 } else { $Options.Count - 1 } }
                40 { $cursor = if ($cursor -lt $Options.Count - 1) { $cursor + 1 } else { 0 } }
                32 { $act = 'toggle' }
                13 { $act = 'run' }
                27 { $act = 'back' }
            }
            switch ("$($e.Char)".ToLowerInvariant()) {
                'k' { $cursor = if ($cursor -gt 0) { $cursor - 1 } else { $Options.Count - 1 } }
                'j' { $cursor = if ($cursor -lt $Options.Count - 1) { $cursor + 1 } else { 0 } }
                'q' { $act = 'back' }
            }
        }
        switch ($act) {
            'run'   { return $true }
            'back'  { return $false }
            'clear' { foreach ($o in $Options) { $o.Checked = $false; $o.Value = '' } }
            'toggle' {
                $o = $Options[$cursor]
                if ($o.Kind -eq 'switch') { $o.Checked = -not $o.Checked }
                else {
                    $tip = if ($o.Value) { "（当前 $($o.Value)；直接回车清除）" } else { '（直接回车取消）' }
                    $o.Value = Read-UiText -Prompt "输入 $($o.Name) 的值$tip"
                }
            }
        }
    }
}

# ---------- 勾选列表（带滚动，用于改动文件挑选） ----------
<#
  $Items 需带可写的 Checked 属性。
  $Format 传入单个 item，返回 @{ Code; Name; Info; Color }。
  $Summary 传入全部 items，返回统计行文本。
  $OnDetail 传入单个 item，用于双击 / d 键查看详情（如 diff）。
  返回 $true=确认 / $false=取消。
#>
function Show-CheckList {
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][scriptblock]$Format,
        [string]$Title = '',
        [string]$ConfirmText = '确认',
        [scriptblock]$Summary = $null,
        [scriptblock]$OnDetail = $null
    )
    $cursor = 0; $top = 0
    Reset-UiScreen
    while ($true) {
        $viewport = Get-UiViewportHeight -Chrome 9
        if ($cursor -lt $top) { $top = $cursor }
        if ($cursor -ge $top + $viewport) { $top = $cursor - $viewport + 1 }
        $last = [Math]::Min($Items.Count, $top + $viewport)

        $lines = @()
        $lines += New-UiLine -Text "  $Title" -Color 'Cyan'
        $lines += New-UiLine
        for ($i = $top; $i -lt $last; $i++) {
            $it = $Items[$i]
            $f = & $Format $it
            $mark = if ($i -eq $cursor) { '>' } else { ' ' }
            $box = if ($it.Checked) { '[x]' } else { '[ ]' }
            $color = if ($i -eq $cursor) { 'Cyan' } elseif (-not $it.Checked) { 'DarkGray' } else { $f.Color }
            $name = Limit-DisplayWidth $f.Name 56 -FromEnd
            $lines += New-UiLine -Text ("  $mark $box " + (Add-DisplayPad $f.Code 3) + ' ' + (Add-DisplayPad $name 57) + $f.Info) `
                -Color $color -Hit @{ Type = 'Item'; Index = $i }
        }
        if ($Items.Count -gt $viewport) {
            $lines += New-UiLine -Text ("     共 $($Items.Count) 项，显示 $($top + 1)-$last（滚轮 / PgUp PgDn 翻页）") -Color 'DarkGray'
        }
        $lines += New-UiLine
        $lines += New-ButtonRow -Buttons @(
            @{ Text = $ConfirmText; Action = 'ok' }
            @{ Text = '全选'; Action = 'all' }
            @{ Text = '全不选'; Action = 'none' }
            @{ Text = '反选'; Action = 'invert' }
            @{ Text = '查看 diff'; Action = 'detail' }
            @{ Text = '取消'; Action = 'cancel' }
        ) -Color 'Yellow'
        if ($Summary) { $lines += New-UiLine -Text ('  ' + (& $Summary $Items)) -Color 'Yellow' }
        $lines += Get-MouseHintLine
        Write-UiFrame -Lines $lines

        $e = Read-UiEvent
        $act = $null
        if ($e.Type -eq 'Wheel') {
            $step = 3 * $e.Delta
            $top = [Math]::Max(0, [Math]::Min([Math]::Max(0, $Items.Count - $viewport), $top - $step))
            $cursor = [Math]::Max($top, [Math]::Min($cursor, $top + $viewport - 1))
            continue
        }
        if ($e.Type -in @('Click', 'DoubleClick')) {
            $hit = Get-UiHit -UiEvent $e
            if (-not $hit) { continue }
            if ($hit.Type -eq 'Button') { $act = $hit.Action }
            else {
                $cursor = $hit.Index
                $act = if ($e.Type -eq 'DoubleClick') { 'detail' } else { 'toggle' }
            }
        }
        else {
            switch ($e.Code) {
                38 { if ($cursor -gt 0) { $cursor-- } }
                40 { if ($cursor -lt $Items.Count - 1) { $cursor++ } }
                33 { $cursor = [Math]::Max(0, $cursor - $viewport) }
                34 { $cursor = [Math]::Min($Items.Count - 1, $cursor + $viewport) }
                36 { $cursor = 0 }
                35 { $cursor = $Items.Count - 1 }
                32 { $act = 'toggle' }
                13 { $act = 'ok' }
                27 { $act = 'cancel' }
            }
            switch ("$($e.Char)".ToLowerInvariant()) {
                'k' { if ($cursor -gt 0) { $cursor-- } }
                'j' { if ($cursor -lt $Items.Count - 1) { $cursor++ } }
                'a' { $act = 'all' }
                'n' { $act = 'none' }
                'i' { $act = 'invert' }
                'd' { $act = 'detail' }
                'q' { $act = 'cancel' }
            }
        }
        switch ($act) {
            'ok'     { return $true }
            'cancel' { return $false }
            'toggle' { $Items[$cursor].Checked = -not $Items[$cursor].Checked }
            'all'    { foreach ($i in $Items) { $i.Checked = $true } }
            'none'   { foreach ($i in $Items) { $i.Checked = $false } }
            'invert' { foreach ($i in $Items) { $i.Checked = -not $i.Checked } }
            'detail' {
                if ($OnDetail) {
                    & $OnDetail $Items[$cursor]
                    Reset-UiScreen
                }
            }
        }
    }
}

