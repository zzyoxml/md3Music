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

Write-Host ''
Write-Host "结果：$pass 通过 / $fail 失败" -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
exit $(if ($fail) { 1 } else { 0 })
