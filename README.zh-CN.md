# Blackout

**[English](README.md) · [简体中文](README.zh-CN.md)**

按 `Ctrl + Shift + \``，整屏变黑，白色巨大文字逐行列出今天要办的事。按 `Esc`，消失。

不是屏保，也不是又一个你永远想不起来打开的待办应用。它是一份随叫随到、看完就走的清单，
平时缩在托盘里。给那些明明知道该干什么、却就是不干的人用。

![Blackout 全屏黑底白字显示三条待办](docs/screenshot-hero.png)

**132 KB，单个可执行文件。不装也能用，没有运行时，没有任何依赖。缩在托盘里只占 124 KB 内存。**

也有 macOS 版：同样的热键、同样的行为，见 [macOS](#macos)。

---

## 安装

从 [最新 Release](https://github.com/CharlesGuooo/blackout/releases/latest) 下载：

| 文件 | 什么时候用 |
| --- | --- |
| `Blackout-x.y.z-Setup.exe` | 常规选择。只装给当前用户，不需要管理员权限，不弹 UAC |
| `Blackout-x.y.z-portable.zip` | 你更想解压一个文件直接跑。放哪都行，清单就存在它旁边 |

### Windows 一定会拦你，原因和处理

SmartScreen 会弹出 **"Windows 已保护你的电脑"** 并拒绝运行安装包。
点 **更多信息 → 仍要运行**。

原因是这个文件没有代码签名。签名证书一年 200–400 美元，而且新证书在攒够信誉之前照样被拦。
一个免费的 132 KB 小工具，这笔账算不过来。

不想盲信可以自己核对：每个 Release 都附带 `SHA256SUMS.txt`。

```powershell
Get-FileHash .\Blackout-1.0.0-Setup.exe -Algorithm SHA256
```

跟公布的哈希对一下。你也可以把这个仓库的源码从头读一遍——总共就一个 C 文件——然后自己编译。

---

## 用法

第一次打开时，清单里已经有四行字，内容就是教你怎么用。学会一条删一条。

| 操作 | 效果 |
| --- | --- |
| `Ctrl + Shift + \`` | 弹出 / 收起全屏清单 |
| 直接打字 | 增删待办，一行一条 |
| `Enter` | 换行——**换行位置完全由你决定，程序不会自动折行** |
| `Esc` | 保存并收起 |
| 切到别的窗口（Alt-Tab） | 自动保存并收起 |
| 托盘图标左键 | 弹出 / 收起 |
| 托盘图标右键 | 显示 · 打开 todo.txt · 开机自动启动 · 退出 |

**没有"完成打勾"这个功能，这是故意的。** 事情办完了就把那行删掉——一个待办清单不该是
已完成事项的墓地。

**不会自动换行。** 一个回车 = 屏幕上的一行。某条任务写得太长时，全体字号会一起变小——
那就是在提醒你该把它拆成两条。

文字自动撑满屏幕：3 条任务时行高约 700 像素，12 条时缩到约 120 像素。
多显示器时弹在鼠标所在的那块屏上。

清单就是一个叫 `todo.txt` 的普通 UTF-8 文本文件，躺在 exe 旁边。想用记事本改就改，
下次按热键时 Blackout 会自动重新加载。

---

## 配置

`todo.ini`，和 exe 同目录，改完重启生效。

```ini
[hotkey]
mods=ctrl+shift            ; ctrl / alt / shift / win 任意组合
key=`                      ; 单个字符，或 0x## 形式的虚拟键码

[display]
font=Microsoft YaHei UI
bold=1
minsize=24                 ; 字号下限（像素）
maxsize=400                ; 字号上限（像素）
```

**关于默认热键：** `Ctrl+Shift+\`` 是 VS Code / Cursor 的"新建终端"。全局热键优先级更高，
Blackout 运行期间那个快捷键会失效。需要的话把 `mods` 改成 `ctrl+alt`，这个组合几乎不跟谁冲突。

另外中文 Windows 上 `Ctrl+Shift` 常被绑为"切换输入法"，偶尔可能打架。

热键被别的程序占了的话，启动时会弹窗告诉你，不会静默失败。

数据存在 exe 旁边。如果那个目录不可写——比如你把便携版解压进了 `Program Files`——
所有文件会自动改存到 `%LOCALAPPDATA%\Blackout\`。

---

## 为什么能这么小

在 2560×1600 屏幕上实测。**"工作集"才是任务管理器给你看的那个数字**，也就是真正占用的物理内存；
"提交"是申请的地址空间，绝大部分从不进内存。

| | |
| --- | --- |
| 可执行文件 | 132 KB，含图标 |
| 缩在托盘、从未弹出过 | 工作集 **124 KB** |
| 弹出过一次之后 | 工作集 **约 3 MB** |
| 空闲 CPU | 0%——无定时器、无线程、无键盘钩子 |

作为参照：同样功能用 Electron 做是 200–300 MB，用 C# WinForms 是 20–40 MB。

它是纯 C 直接调 Win32 API。全屏覆盖层就是一个窗口套一个标准 `EDIT` 控件——
所以光标、选中、中文输入法、撤销全都不用写一行代码就有了。隐藏时调
`SetProcessWorkingSetSize` 把内存还给系统。

唯一躲不掉的开销：覆盖层第一次显示时，Windows 会往进程里加载约 25 个 DLL——
DirectWrite/Direct2D 文本渲染栈、TSF 输入法框架，以及你装的第三方输入法。
任何带文本框的 Win32 程序都要付这笔钱，而且这些 DLL 加载后不会卸载。

---

## 自己编译

只需要装了 C++ 工作负载的 Visual Studio 2022 Build Tools，别的都不用。

```
build.bat
```

产物在 `bin\Blackout.exe`。构建脚本通过 `vswhere` 定位 Visual Studio，
所以在任何机器上和 CI 上都能跑。

### 测试

```
bin\Blackout.exe --selftest                                   22 项单元断言
powershell -ExecutionPolicy Bypass -File tools\e2e_test.ps1   45 项端到端断言
powershell -ExecutionPolicy Bypass -File tools\fallback_test.ps1    9 项断言
```

端到端测试驱动的是真程序：合成真实按键触发全局热键，然后截下覆盖层做**像素断言**——
把含亮像素的屏幕行聚成"文字带"，断言带数等于清单的行数。少一条 = 有行被滚出了屏幕，
多一条 = 发生了不该有的自动折行。几何断言抓不到这两种情况，因为两种情况下控件矩形都是对的，
错的是控件**内部**的内容。

测试跑的是 `%TEMP%` 里的 exe 副本，绝不碰你真实的 `todo.txt`。但它会停掉所有正在运行的
Blackout 实例——全局热键只能属于一个进程。

`fallback_test.ps1` 用 ACL 拒绝写入来复刻"安装目录不可写"的场景，覆盖那条回退路径。

> 那几个 `.ps1` 必须存成 **带 BOM 的 UTF-8**。Windows PowerShell 5.1 对无 BOM 的脚本
> 按 ANSI 代码页解码，里面的中文会被拆坏成语法错误。

---

## 已知限制

- **独占全屏（exclusive fullscreen）的游戏盖不住。** 这是 Windows 的限制，
  任何非游戏程序都做不到。窗口化 / 无边框全屏的程序都能盖住。
- **一条任务写得越长，全屏所有文字就越小**，因为字号要保证最长那行完整放下。
  这是设计如此，也是提示你该拆条。真要写长就把 `todo.ini` 里的 `minsize` 调低。
- 逐显示器 DPI 需要 Windows 10 1703 或更新。更老的系统照样能跑，只是不做 DPI 感知。
- 一个纯文本文件。没有多清单、标签、截止日期、同步。这也是刻意的——
  出了任何问题，记事本都能修。

---

## macOS

同一个程序，用 AppKit 重写：一个 Objective-C 文件（`mac/main.m`），
同样的热键、同样的行为、同样的 `todo.ini` 配置项。

### 安装

从 [最新 Release](https://github.com/CharlesGuooo/blackout/releases/latest) 下载
`Blackout-x.y.z-mac.zip`，解压，把 `Blackout.app` 拖进"应用程序"，打开。
第一次打开会直接弹出教程清单，之后它就待在菜单栏里。

需要 macOS 13 Ventura 或更新。一个通用二进制同时支持 Apple 芯片和 Intel。

#### macOS 一定会拦你，原因和处理

这个 app 没有做公证（notarization）。公证需要 Apple 开发者会员，一年 99 美元，
和 Windows 签名证书是同一笔算不过来的账。第一次打开时 macOS 会拒绝：点 **完成**，
然后到 **系统设置 → 隐私与安全性**，往下拉，点 **仍要打开**。或者在终端里：

```sh
xattr -dr com.apple.quarantine /Applications/Blackout.app
```

不想盲信，就对一下 `SHA256SUMS.txt`：

```sh
shasum -a 256 Blackout-1.1.0-mac.zip
```

### Mac 上有什么不同

| | Windows | macOS |
| --- | --- | --- |
| 待在哪 | 托盘 | 菜单栏。左键弹出 / 收起，右键（或 Ctrl+点按）打开菜单 |
| `todo.txt`、`todo.ini` | exe 旁边 | `~/Library/Application Support/Blackout/`。往签过名的 `.app` 里写文件会把它弄坏。菜单里的 **打开 todo.txt** 会用"文本编辑"打开它 |
| 文件格式 | 带 BOM 的 UTF-8，CRLF | UTF-8，LF。两边都读得懂对方的文件，清单可以直接拷过去 |
| 开机自动启动 | 注册表 Run 键 | 登录项（系统设置 → 通用 → 登录项） |
| 全选 / 复制 / 粘贴 / 撤销 | Ctrl | ⌘ |

其余都一样：`Ctrl + Shift + \`` 弹出 / 收起，`Esc` 保存并收起，切到别的程序自动保存并收起，
不自动换行，字号自动撑满鼠标所在的那块屏幕（菜单栏和 Dock 一起盖住）。
输入法照常用；正在打拼音时按 `Esc` 先取消组字，再按一次才收起清单。

### 配置

`todo.ini`，在上面那个文件夹里，改完重启生效。

```ini
[hotkey]
mods=ctrl+shift            ; ctrl / alt（= option）/ shift / win（= cmd）任意组合
key=`                      ; 单个字符，或 0x32 这样的 Mac 键码

[display]
font=PingFang SC           ; 任何已安装的字体族；找不到就用系统字体
bold=1
minsize=24                 ; 字号下限（点）
maxsize=400                ; 字号上限（点）
```

- 键码是 Mac 的虚拟键码（`kVK_*`），不是 Windows 的。`0x32` 就是反引号那个键。
- macOS 15 起，只用 Option 或 Option + Shift 作修饰键的热键会被系统拒绝，请带上 Ctrl 或 Cmd。
- 热键被别的程序注册过的话，启动时会弹窗告诉你。但被 macOS 自己占用的快捷键
  （比如 ⌘空格）检测不到，系统会直接赢。
- `Ctrl + Shift + \`` 在 Mac 上也是 VS Code 的"新建终端"。

### 有多小

在 2560×1600 屏幕的 MacBook、macOS 14.6 上实测：

| | |
| --- | --- |
| App 包 | 252 KB，通用二进制加图标 |
| 待在菜单栏、从未弹出过 | footprint **约 10 MB** |
| 弹出过之后 | **约 17 MB**，反复弹出收起也不涨 |
| 空闲 CPU | 0%：隐藏时没有定时器，没有键盘钩子 |

footprint 就是活动监视器里"内存"那一列。Windows 版的数字在 Mac 上做不到：
一个只在菜单栏放个图标、别的什么都不干的空 AppKit 程序就已经占 8.9 MB，
所以那 10 MB 里 Blackout 自己只占 1 MB 左右；隐藏后也没有 `SetProcessWorkingSetSize`
这种把内存还给系统的接口。

热键用的是 Carbon 的 `RegisterEventHotKey`，不需要"辅助功能"权限，空闲时零开销。
覆盖层是一个无边框窗口套一个 `NSTextView`，和 Windows 版用 `EDIT` 控件是同一个道理：
光标、选中、输入法、撤销全都白送。

### 自己编译

只需要 Xcode 命令行工具（`xcode-select --install`），别的都不用。

```sh
./build.sh
```

产物是 `bin/Blackout.app`，通用二进制，已做 ad-hoc 签名。

### 测试

```
bin/Blackout.app/Contents/MacOS/Blackout --selftest    74 项单元断言
tools/e2e_test.sh                                      30 项端到端断言
                                                       （有屏幕录制权限时另加 12 项像素断言）
```

`--selftest` 里包含 Windows 端到端测试那套"文字带"像素断言，在进程内完成：
用同样几份清单，把覆盖层按 1440×900 离屏画出来数带数。不需要任何权限，CI 上也能跑。

`tools/e2e_test.sh` 在真实桌面上驱动真程序。运行它的终端需要 **辅助功能** 权限（合成按键），
要在真实屏幕上做像素断言还需要 **屏幕录制**。它用临时的 `--data-dir`，绝不碰你真实的清单；
但会停掉所有正在运行的 Blackout——全局热键只能属于一个进程。文字一律通过剪贴板粘贴
（输入法会截走合成的字母键），剪贴板里原来的文字测完会还原。

### macOS 上的已知限制

- 独占显示器的游戏盖不住，和 Windows 一样。
- 没有公证，见上文。

---

## 许可证

MIT，见 [LICENSE](LICENSE)。
