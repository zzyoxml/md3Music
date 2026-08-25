#Requires -Version 5.1
# lib/ui.ps1 的事件解码回归测试：powershell -File scripts\lib\ui.tests.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

# 构造 INPUT_RECORD 并直接过 ConvertTo-UiEvent，不需要真实控制台：
# 验证 union 字段偏移（KeyEvent / MouseEvent 共享 offset 4）与滚轮符号解码。
function New-KeyRecord([int]$Vk, [char]$Ch, [int]$Down = 1) {
    $r = New-Object Md3.INPUT_RECORD
    $r.EventType = 1
    $k = New-Object Md3.KEY_EVENT_RECORD
    $k.bKeyDown = $Down; $k.wRepeatCount = 1; $k.wVirtualKeyCode = $Vk; $k.UnicodeChar = $Ch
    $r.KeyEvent = $k
    $r
}
function New-MouseRecord([int]$X, [int]$Y, [uint32]$Buttons, [uint32]$Flags) {
    $r = New-Object Md3.INPUT_RECORD
    $r.EventType = 2
    $m = New-Object Md3.MOUSE_EVENT_RECORD
    $c = New-Object Md3.COORD; $c.X = $X; $c.Y = $Y
    $m.dwMousePosition = $c; $m.dwButtonState = $Buttons; $m.dwEventFlags = $Flags
    $r.MouseEvent = $m
    $r
}

$pass = 0; $fail = 0
function Check([string]$Name, $Record, [scriptblock]$Assert) {
    $e = ConvertTo-UiEvent $Record
    $ok = & $Assert $e
    if ($ok) { $script:pass++ } else { $script:fail++ }
    $desc = if ($null -eq $e) { '(忽略)' } else { "Type=$($e.Type) Code=$($e.Code) Char=[$($e.Char)] X=$($e.X) Y=$($e.Y) Delta=$($e.Delta)" }
    Write-Host ("  {0,-22} {1,-58} {2}" -f $Name, $desc, $(if ($ok) { 'PASS' } else { 'FAIL' })) `
        -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
}

Write-Host '--- 事件解码 ---' -ForegroundColor Cyan
Check '下箭头键'      (New-KeyRecord 40 ([char]0))  { param($e) $e -and $e.Type -eq 'Key' -and $e.Code -eq 40 }
Check '字符键 a'      (New-KeyRecord 65 'a')        { param($e) $e -and $e.Type -eq 'Key' -and $e.Char -eq 'a' -and $e.Code -eq 65 }
Check '按键抬起(忽略)' (New-KeyRecord 40 ([char]0) 0) { param($e) $null -eq $e }
Check 'Shift(忽略)'   (New-KeyRecord 16 ([char]0))  { param($e) $null -eq $e }
Check '左键单击(7,3)'  (New-MouseRecord 7 3 1 0)     { param($e) $e -and $e.Type -eq 'Click' -and $e.X -eq 7 -and $e.Y -eq 3 }
Check '左键双击(2,9)'  (New-MouseRecord 2 9 1 2)     { param($e) $e -and $e.Type -eq 'DoubleClick' -and $e.X -eq 2 -and $e.Y -eq 9 }
Check '右键(忽略)'     (New-MouseRecord 5 5 2 0)     { param($e) $null -eq $e }
Check '鼠标抬起(忽略)' (New-MouseRecord 5 5 0 0)     { param($e) $null -eq $e }
Check '纯移动(忽略)'   (New-MouseRecord 5 5 0 1)     { param($e) $null -eq $e }
Check '滚轮上滚'      (New-MouseRecord 4 4 ([uint32]0x00780000) 4) { param($e) $e -and $e.Type -eq 'Wheel' -and $e.Delta -eq 1 }
Check '滚轮下滚'      (New-MouseRecord 4 4 ([uint32]4286578688) 4) { param($e) $e -and $e.Type -eq 'Wheel' -and $e.Delta -eq -1 }   # 0xFF880000

# 内嵌编辑器：按键状态机不依赖控制台，直接喂事件断言缓冲区
function New-KeyEvent([int]$Vk, [string]$Ch = '') {
    [pscustomobject]@{ Type = 'Key'; Code = $Vk; Char = $Ch; X = -1; Y = -1; Delta = 0 }
}
function CheckEd([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:pass++ } else { $script:fail++ }
    Write-Host ("  {0,-26} {1,-54} {2}" -f $Name, $Detail, $(if ($Ok) { 'PASS' } else { 'FAIL' })) `
        -ForegroundColor $(if ($Ok) { 'Green' } else { 'Red' })
}

Write-Host ''
Write-Host '--- 内嵌编辑器 ---' -ForegroundColor Cyan

$s = New-TextBufferState -Text "abc`ndef"
CheckEd '初始行数/光标' ($s.Lines.Count -eq 2 -and $s.Row -eq 0 -and $s.Col -eq 0) "行=$($s.Lines.Count)"

# 插入字符（含中文）
$null = Invoke-TextBufferKey -State $s -UiEvent (New-KeyEvent 88 'X')
$null = Invoke-TextBufferKey -State $s -UiEvent (New-KeyEvent 0 '中')
CheckEd '插入字符（含中文）' ((Get-TextBufferText -State $s) -eq "X中abc`ndef") "$($s.Lines[0])"
CheckEd '插入后标记已修改' ($s.Dirty) "Dirty=$($s.Dirty)"

# End / Backspace
$null = Invoke-TextBufferKey -State $s -UiEvent (New-KeyEvent 35)
$null = Invoke-TextBufferKey -State $s -UiEvent (New-KeyEvent 8)
CheckEd 'End + Backspace 删末字符' ($s.Lines[0] -eq 'X中ab') "$($s.Lines[0])"

# Enter 断行
$null = Invoke-TextBufferKey -State $s -UiEvent (New-KeyEvent 36)      # Home
$null = Invoke-TextBufferKey -State $s -UiEvent (New-KeyEvent 39)      # →
$null = Invoke-TextBufferKey -State $s -UiEvent (New-KeyEvent 13)      # Enter
CheckEd 'Enter 在光标处断行' ((Get-TextBufferText -State $s) -eq "X`n中ab`ndef") "行=$($s.Lines.Count)"
CheckEd 'Enter 后光标到新行首' ($s.Row -eq 1 -and $s.Col -eq 0) "R=$($s.Row) C=$($s.Col)"

# 行首 Backspace 并上一行
$null = Invoke-TextBufferKey -State $s -UiEvent (New-KeyEvent 8)
CheckEd '行首 Backspace 合并上一行' ((Get-TextBufferText -State $s) -eq "X中ab`ndef" -and $s.Col -eq 1) "C=$($s.Col)"

# 行尾 Delete 并下一行
$null = Invoke-TextBufferKey -State $s -UiEvent (New-KeyEvent 35)
$null = Invoke-TextBufferKey -State $s -UiEvent (New-KeyEvent 46)
CheckEd '行尾 Delete 合并下一行' ((Get-TextBufferText -State $s) -eq 'X中abdef') "$($s.Lines[0])"

# ← 跨行回到上一行行尾
$s2 = New-TextBufferState -Text "ab`ncd"
Set-TextBufferCursor -State $s2 -Row 1 -Col 0
$null = Invoke-TextBufferKey -State $s2 -UiEvent (New-KeyEvent 37)
CheckEd '← 跨行到上一行行尾' ($s2.Row -eq 0 -and $s2.Col -eq 2) "R=$($s2.Row) C=$($s2.Col)"

# ↓ 到短行时列被夹住
$s3 = New-TextBufferState -Text "abcdef`nxy"
Set-TextBufferCursor -State $s3 -Row 0 -Col 6
$null = Invoke-TextBufferKey -State $s3 -UiEvent (New-KeyEvent 40)
CheckEd '↓ 列夹到短行长度' ($s3.Row -eq 1 -and $s3.Col -eq 2) "R=$($s3.Row) C=$($s3.Col)"

# Tab 两个空格
$s4 = New-TextBufferState -Text 'a'
$null = Invoke-TextBufferKey -State $s4 -UiEvent (New-KeyEvent 9 "`t")
CheckEd 'Tab 插入两个空格' ($s4.Lines[0] -eq '  a') "[$($s4.Lines[0])]"

# 动作键：Ctrl+S / F2 / Esc / Ctrl+E
CheckEd 'Ctrl+S 保存' ((Invoke-TextBufferKey -State $s4 -UiEvent (New-KeyEvent 83 ([string][char]19))) -eq 'save')
CheckEd 'F2 保存' ((Invoke-TextBufferKey -State $s4 -UiEvent (New-KeyEvent 113)) -eq 'save')
CheckEd 'Esc 放弃' ((Invoke-TextBufferKey -State $s4 -UiEvent (New-KeyEvent 27)) -eq 'cancel')
CheckEd 'Ctrl+E 转外部编辑器' ((Invoke-TextBufferKey -State $s4 -UiEvent (New-KeyEvent 69 ([string][char]5))) -eq 'external')

# 滚轮滚动只移动光标行，不改内容
$s5 = New-TextBufferState -Text (1..20 -join "`n")
$null = Invoke-TextBufferKey -State $s5 -UiEvent ([pscustomobject]@{ Type = 'Wheel'; Code = 0; Char = ''; X = 0; Y = 0; Delta = -1 })
CheckEd '滚轮下滚 3 行' ($s5.Row -eq 3 -and -not $s5.Dirty) "R=$($s5.Row)"

# 水平视窗：按显示宽度取可见片段（中文占 2 列）
CheckEd '水平视窗 不超宽原样' ((Get-LineWindow -Text 'abcd' -FromCol 0 -Width 10) -eq 'abcd')
CheckEd '水平视窗 截到宽度' ((Get-LineWindow -Text 'abcdef' -FromCol 0 -Width 3) -eq 'abc')
CheckEd '水平视窗 左偏移' ((Get-LineWindow -Text 'abcdef' -FromCol 2 -Width 3) -eq 'cde')
CheckEd '水平视窗 中文按 2 列' ((Get-LineWindow -Text '中文abc' -FromCol 0 -Width 5) -eq '中文a')
CheckEd '水平视窗 偏移越过中文' ((Get-LineWindow -Text '中文abc' -FromCol 4 -Width 5) -eq 'abc')

Write-Host ''
Write-Host "结果：$pass 通过 / $fail 失败" -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
exit $(if ($fail) { 1 } else { 0 })