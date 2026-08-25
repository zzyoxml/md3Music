#Requires -Version 5.1
<#
.SYNOPSIS
  MD3Music 脚本总入口：构建 / 导出 / 提交任务的统一命令行 + 键盘菜单。

.DESCRIPTION
  不带参数运行时进入键盘菜单：↑↓ 选子命令 → 空格勾选参数 → Enter 执行 → 返回菜单。
  带子命令时直接执行，余下参数原样透传，因此任务脚本仍可单独调用。

  子命令派发到 scripts/tasks/<name>.ps1，公共实现在 scripts/lib/common.ps1。

.EXAMPLE
  .\scripts\md3.ps1                      # 键盘菜单（双击运行也可用）
  .\scripts\md3.ps1 help                 # 文本帮助
  .\scripts\md3.ps1 android              # Rust 交叉编译（按需）+ Flutter 分包打包
  .\scripts\md3.ps1 android -ForceRust
  .\scripts\md3.ps1 windows              # Rust dll + Flutter Windows + 便携 zip
  .\scripts\md3.ps1 verify               # 否认清单闸门（只读自检）
  .\scripts\md3.ps1 export -PublicRemote <URL>
  .\scripts\md3.ps1 commit               # TUI 一键提交（勾选改动 / LLM 写提交信息 / 同步 / PR）
#>
# 刻意不声明 param()：PowerShell 会对已声明参数做严格绑定，未知的命名参数（-ForceRust /
# -Message 等）会在绑定阶段直接报错。完全不声明参数时全部实参落进自动变量 $args，
# 才能把子命令之后的参数原样透传给任务脚本。
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

$argv = @($args)
$Command = if ($argv.Count -gt 0) { [string]$argv[0] } else { '' }
$Rest = if ($argv.Count -gt 1) { $argv[1..($argv.Count - 1)] } else { @() }

# 子命令 -> tasks/<file>.ps1；别名一并登记
$Tasks = [ordered]@{
    'android' = @{ File = 'android.ps1';       Desc = 'Rust 交叉编译（按需）+ Flutter APK 分包打包'; Alias = @('apk') }
    'windows' = @{ File = 'windows.ps1';       Desc = 'Rust dll + Flutter Windows + 便携版 zip';     Alias = @('win') }
    'verify'  = @{ File = 'verify_public.ps1'; Desc = '否认清单闸门：自检当前仓库公开面是否干净';   Alias = @('check') }
    'export'  = @{ File = 'export_public.ps1'; Desc = '导出公开版本（可选推送 / 开 PR）';           Alias = @('public') }
    'commit'  = @{ File = 'commit.ps1';        Desc = 'TUI 一键提交：勾选改动 / LLM 提交信息 / 同步 / 开 PR'; Alias = @('ci') }
    'token'   = @{ File = 'token.ps1';         Desc = '管理 GitHub token（开 PR / 自动合并用）';      Alias = @('auth') }
}

# 各任务在菜单里可勾选的参数（与任务脚本的 param 块保持一致）
function Get-TaskOptions([string]$Key) {
    switch ($Key) {
        'android' { @(
            (New-TaskOption -Name '-ForceRust'   -Desc '忽略改动检测，强制重编 Rust'),
            (New-TaskOption -Name '-SkipFlutter' -Desc '只更新 jniLibs，不跑 flutter build'),
            (New-TaskOption -Name '-NdkPath'     -Kind value -Desc '手动指定 Android NDK 目录'),
            (New-TaskOption -Name '-NoPause'     -Desc '结束后不等待按键')
        ) }
        'windows' { @(
            (New-TaskOption -Name '-ForceRust' -Desc '忽略改动检测，强制重编 Rust dll'),
            (New-TaskOption -Name '-SkipRust'  -Desc '跳过 Rust 构建（dll 已存在时）'),
            (New-TaskOption -Name '-OutDir'    -Kind value -Desc 'zip 输出目录（默认 build\windows）'),
            (New-TaskOption -Name '-NoPause'   -Desc '结束后不等待按键')
        ) }
        'verify' { @(
            (New-TaskOption -Name '-Quiet' -Desc '只输出结论，不打印 deny 清单规模')
        ) }
        'export' { @(
            (New-TaskOption -Name '-PublicRemote' -Kind value -Desc '公开仓库 URL（不填=只导出不推送）'),
            (New-TaskOption -Name '-AsPr'         -Desc '推到临时分支并开 PR（否则 force push 覆盖）'),
            (New-TaskOption -Name '-PublicBranch' -Kind value -Desc '目标分支 / PR base（默认 main）'),
            (New-TaskOption -Name '-PrBranch'     -Kind value -Desc '-AsPr 的分支名（默认按时间戳生成）'),
            (New-TaskOption -Name '-OutDir'       -Kind value -Desc '导出目录（默认 .public_export）'),
            (New-TaskOption -Name '-NoPause'      -Desc '结束后不等待按键')
        ) }
        'commit' { @(
            (New-TaskOption -Name '-Message'      -Kind value -Desc '提交信息（不填=用候选信息确认环节）'),
            (New-TaskOption -Name '-NoLlm'        -Desc '不调 LLM，用模板候选信息'),
            (New-TaskOption -Name '-All'          -Desc '跳过勾选界面，提交全部改动'),
            (New-TaskOption -Name '-NoPush'       -Desc '只提交，不做任何同步'),
            (New-TaskOption -Name '-NoUpstreamSync' -Desc '同步阶段跳过 upstream，只对齐 origin'),
            (New-TaskOption -Name '-UpstreamBranch' -Kind value -Desc '从 upstream 拉取的分支（默认同名）'),
            (New-TaskOption -Name '-Pr'           -Desc '推送后向 upstream 开 PR'),
            (New-TaskOption -Name '-PrMerge'      -Desc '开 PR 并直接合并到 upstream（需 token）'),
            (New-TaskOption -Name '-PrBase'       -Kind value -Desc 'upstream PR 的 base 分支'),
            (New-TaskOption -Name '-NoSyncBack'   -Desc '合并后不把 upstream 结果拉回本地'),
            (New-TaskOption -Name '-PublicPr'     -Desc '提交后导出公开版并开 PR'),
            (New-TaskOption -Name '-PublicExport' -Desc '提交后导出公开版并 force push'),
            (New-TaskOption -Name '-SkipGate'     -Desc '跳过否认清单闸门'),
            (New-TaskOption -Name '-Yes'          -Desc '非交互：不询问后续动作')
        ) }
        'token' { @(
            (New-TaskOption -Name '-Show'   -Desc '查看当前 token 来源与状态'),
            (New-TaskOption -Name '-Set'    -Desc '设置 token（可永久保存或仅本次）'),
            (New-TaskOption -Name '-Test'   -Desc '验证 token 是否可用'),
            (New-TaskOption -Name '-Remove' -Desc '删除本机保存的 token')
        ) }
        default { @() }
    }
}

function Test-TaskAvailable([string]$Key) {
    Test-Path (Join-Path $PSScriptRoot "tasks\$($Tasks[$Key].File)")
}

function Show-Usage {
    Write-Host ''
    Write-Host 'MD3Music 脚本入口' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  用法: .\scripts\md3.ps1 [<子命令>] [参数...]'
    Write-Host '        不带子命令运行则进入交互界面（鼠标 + 键盘）'
    Write-Host ''
    Write-Host '  子命令:' -ForegroundColor Cyan
    foreach ($k in $Tasks.Keys) {
        $t = $Tasks[$k]
        $alias = if ($t.Alias) { " (别名: $($t.Alias -join ', '))" } else { '' }
        $ok = Test-TaskAvailable $k
        Write-Host ("   {0} {1,-9} {2}{3}" -f $(if ($ok) { ' ' } else { '-' }), $k, $t.Desc, $alias) `
            -ForegroundColor $(if ($ok) { 'White' } else { 'DarkGray' })
    }
    Write-Host ''
    Write-Host '  每个子命令的完整参数: Get-Help .\scripts\tasks\<file>.ps1 -Detailed' -ForegroundColor DarkGray
    Write-Host '  标记 - 的子命令在当前树中不存在（公开导出树会剥离私有侧工具）' -ForegroundColor DarkGray
    Write-Host ''
}

function Resolve-Task([string]$Name) {
    $key = $Name.ToLowerInvariant()
    if ($Tasks.Contains($key)) { return $key }
    foreach ($k in $Tasks.Keys) {
        if ($Tasks[$k].Alias -contains $key) { return $k }
    }
    return $null
}

# 菜单页脚：当前分支 + 未提交改动数，用于判断该不该先跑 commit
function Get-RepoStatusLine {
    if (-not (Test-HasCommand git)) { return '' }
    $root = Get-RepoRoot
    $branch = & git -C $root rev-parse --abbrev-ref HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    $st = @(& git -C $root status --porcelain 2>$null)
    "当前分支 $("$branch".Trim())  •  $($st.Count) 个未提交改动"
}

function Invoke-Task {
    param([Parameter(Mandatory)][string]$Key, [object[]]$TaskArgs)
    $taskPath = Join-Path $PSScriptRoot "tasks\$($Tasks[$Key].File)"
    if (-not (Test-Path $taskPath)) {
        # 公开导出树剥离了 export/verify/commit 等私有侧工具，这里给出明确解释而不是路径报错
        Write-Host "子命令 '$Key' 在当前树中不可用：缺少 $taskPath" -ForegroundColor Yellow
        Write-Host '若这是公开导出树，该任务属于私有侧工具链，已被导出脚本剥离，请在私有仓库执行。' -ForegroundColor Yellow
        return 3
    }
    try { $p = ConvertTo-TaskParams -ScriptPath $taskPath -ArgList @($TaskArgs) }
    catch {
        Write-Host "参数错误：$($_.Exception.Message)" -ForegroundColor Red
        Write-Host "查看该子命令的参数：Get-Help .\scripts\tasks\$($Tasks[$Key].File) -Detailed" -ForegroundColor Yellow
        return 2
    }
    $named = $p.Named
    $pos = @($p.Positional)
    & $taskPath @named @pos
    # 任务脚本正常结束且未调用过外部命令时 $LASTEXITCODE 可能为空，按成功处理
    if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
}

# 菜单模式：选任务 →（可选）配参数 → 执行 → 回菜单，直到退出
# 任务执行期间关掉鼠标模式，让 QuickEdit 恢复，构建日志仍可用鼠标选中复制。
function Invoke-MenuLoop {
    $lastCode = 0
    [void](Enable-ConsoleMouse)
    try {
        while ($true) {
            $items = @()
            foreach ($k in $Tasks.Keys) {
                $items += New-MenuItem -Key $k -Label $k -Desc $Tasks[$k].Desc -Enabled (Test-TaskAvailable $k)
            }
            $sel = Show-Menu -Items $items -Title 'MD3Music　脚本入口' -Footer (Get-RepoStatusLine) -WithConfig
            if (-not $sel) { Clear-Host; return $lastCode }

            $key = $items[$sel.Index].Key
            $taskArgs = @()
            if ($sel.Action -eq 'config') {
                $opts = Get-TaskOptions $key
                if (-not (Show-OptionPicker -Options $opts -Title "MD3Music › $key" -CommandPrefix "md3.ps1 $key")) {
                    continue    # 返回：回到任务列表
                }
                $taskArgs = Get-OptionArgs $opts
            }

            Disable-ConsoleMouse
            Clear-Host
            $lastCode = Invoke-Task -Key $key -TaskArgs $taskArgs
            if ($lastCode -ne 0) { Write-Host "`n[退出码 $lastCode]" -ForegroundColor Yellow }
            [void](Enable-ConsoleMouse)
            Wait-AnyKey '按任意键 / 点击窗口返回菜单...'
        }
    }
    finally { Disable-ConsoleMouse }
}

if (-not $Command) {
    # 非交互环境（管道/CI/被其他脚本调用）不进菜单，否则会阻塞在按键读取上
    if (-not (Test-InteractiveConsole)) {
        Write-Host '检测到非交互环境（输入或输出被重定向），跳过键盘菜单。' -ForegroundColor Yellow
        Show-Usage
        exit 0
    }
    exit (Invoke-MenuLoop)
}

if ($Command -in @('help', '-h', '--help', '/?', 'menu')) {
    if ($Command -eq 'menu') {
        if (-not (Test-InteractiveConsole)) {
            Write-Host '菜单需要交互式控制台：当前输入或输出被重定向。' -ForegroundColor Red
            Write-Host '请在 PowerShell 窗口中运行，或直接用子命令调用（.\scripts\md3.ps1 help 查看）。' -ForegroundColor Yellow
            exit 4
        }
        exit (Invoke-MenuLoop)
    }
    Show-Usage
    exit 0
}

$key = Resolve-Task $Command
if (-not $key) {
    Write-Host "未知子命令：$Command" -ForegroundColor Red
    Show-Usage
    exit 2
}
exit (Invoke-Task -Key $key -TaskArgs $Rest)
