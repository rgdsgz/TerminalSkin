# TerminalGlass

[English](README.md) | 简体中文

给 Windows Terminal 调磨砂/透明外观的小工具，带精确还原。

- 只用 PowerShell + .NET 文件读写
- 不装驱动、不 hook DWM、不写注册表、不需要管理员权限
- 只改 `settings.json` 里 `profiles.defaults` 的两个键，其他内容原样保留

## 能做什么 / 不能做什么

| | |
|---|---|
| ✅ 开关亚克力（Acrylic）模糊 | 调用 Windows Terminal 官方设置项 |
| ✅ 调"磨砂浓淡"（窗口不透明度 0-100） | 数值越低，背后内容透出越多 |
| ✅ 精确还原到用这个工具之前的状态 | 只回滚自己改过的键，不覆盖你的其他设置 |
| ✅ 自动备份、写入前校验 | 校验不过就不写 |
| ❌ 调模糊半径 | Windows 的 acrylic 半径是系统写死的，官方没有开放 |
| ❌ 液态玻璃 / 折射 | 系统不提供，微软明确表示不做 |
| ❌ 只模糊某个 pane | Terminal 的材质永远作用于整窗 |

滑块调的是**透过率**，不是半径。观感上"越透越像磨砂玻璃"，但严格说它控制的是背景色的 alpha。

## 环境要求

- Windows 10 / 11，且已安装 [Windows Terminal](https://aka.ms/terminal)
- Windows PowerShell 5.1（系统自带）
- 图形界面用 WPF（.NET Framework 4.8，系统自带），无需额外安装

## 用法

### 图形界面

双击 `Launch.cmd`。

- 勾选/取消「启用亚克力模糊」
- 拖动滑块或用预设（轻 90% / 中 80% / 重 65% / 全透 40%）
- 点「应用」——Terminal 会自动热重载，不用重启
- 点「还原」——回到用本工具之前的状态
- 右上角 **中文 / EN** 按钮切换界面语言，选择会被记住

### 命令行

```powershell
# 查看当前状态
.\Launch.cmd -Status

# 自检：当前值和还原记录是否一致、文件里有没有"显式默认值"
.\Launch.cmd -Verify

# 清理显式写出的默认值（opacity=100 且 useAcrylic=false），
# 这两个值写不写行为一样，但会让文件看起来被改过
.\Launch.cmd -Repair

# 应用：85% 不透明度 + 亚克力
.\Launch.cmd -Apply -Opacity 85

# 应用：70% 且不用亚克力（只是半透明，不模糊）
.\Launch.cmd -Apply -Opacity 70 -DisableAcrylic

# 还原
.\Launch.cmd -Reset
```

也可以直接调脚本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\TerminalGlass.ps1 -Apply -Opacity 85
```

### 语言

内置中文和英文，优先级：

1. 命令行 `-Language zh` / `-Language en`
2. 图形界面里最后一次用 **中文 / EN** 按钮选的语言（记在 `prefs.json`）
3. 系统显示语言（`zh*` → 中文，其余 → 英文）

```powershell
.\Launch.cmd -Status -Language en
.\Launch.cmd -Apply -Opacity 80 -Language zh
```

## 还原的确切含义

第一次「应用」时，工具会把 `opacity` 和 `useAcrylic` 这两个键**原本的值**记下来（包括"原本根本不存在"这种情况），存到：

```
%LOCALAPPDATA%\TerminalGlass\state.json
```

「还原」时把这些值原样放回去；原本不存在的键会被删掉。因此：

- 你在别处改的字体、配色、标签、快捷键**不会被动到**
- 用工具之前如果你自己设过 `opacity: 100`，还原后还是 `100`，不会被删
- 用工具之前没有这两个键，还原后它们会消失，Terminal 回到内置默认
- 如果原本整个 `profiles.defaults` 块都不存在，还原后会留下一个空的 `"defaults": {}`（等价于默认，不影响任何行为）

每次写入前都会在 `%LOCALAPPDATA%\TerminalGlass\backups\` 存一份完整快照（保留最近 20 份）。

## 安全边界

- 写入前会重新解析整份配置做 JSON 校验（字符串感知的 JSONC 解析），校验失败直接放弃写入
- **写入后会回读自检**：应用后检查两个键是否等于目标值，还原后检查是否等于记录值；对不上自动用快照回滚并报错
- 写文件用"临时文件 + 覆盖"，不会出现写一半的情况
- 只定位并替换 `profiles.defaults` 这一个块，文件其余部分逐字节保留
- `profiles.defaults` 块内部的注释会在改写时被规范化掉（块外注释不受影响）
- 老版 `profiles` 数组格式、或 `defaults` 不是对象时，会明确报错，不会乱改
- 两个实例同时写入时用系统互斥体排队，不会互相覆盖
- `state.json` 损坏会自动改名留存，不会导致还原错乱
- 还原时只接受 `opacity` / `useAcrylic` 两个已知键，并校验取值范围
- 还原记录里记录的配置文件路径与实际不一致时直接拒绝，避免改错文件
- 界面用 WPF（系统自带 .NET Framework 4.8），不需要额外安装运行时

## 生效条件排查

如果应用后看着没变化：

1. **设置 → 个性化 → 颜色 → 透明效果** 必须是开
2. **省电模式/电池节能** 会自动关掉透明效果
3. `opacity` 必须是 100 以下，100 就完全看不到效果
4. 窗口必须运行在 **Windows Terminal** 里，传统 conhost 窗口没有这能力
5. Terminal 没在运行时，设置要等下次启动才生效

## 文件

```
TerminalGlass.ps1   主程序（GUI + 命令行）
Launch.cmd          启动器
%LOCALAPPDATA%\TerminalGlass\prefs.json      语言偏好
%LOCALAPPDATA%\TerminalGlass\state.json      还原记录
%LOCALAPPDATA%\TerminalGlass\backups\        每次写入前的快照
```

## 手工恢复

如果 state.json 丢了：

```powershell
copy "$env:LOCALAPPDATA\TerminalGlass\backups\settings-<时间戳>.json" `
     "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
```

或者在图形界面里直接点「还原」——只要 `state.json` 还在就能精确回滚。

## 许可证

MIT，见 [LICENSE](LICENSE)。
