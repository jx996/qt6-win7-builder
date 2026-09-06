# qt6-win7-builder

用 GitHub Actions 自动编译**可在 Windows 7 x64 上运行的 Qt 6**，并把产物打包成
`Qt-<版本>-msvc2022-Windows7x64-shared-Release.7z` 自动发布到 Releases。

- **仅动态库（shared / .dll）**，Release 构建。
- **全部社区开源模块，不含任何商业模块**。
- 触发时**只需要填 Qt 版本号**（默认 `6.8.4`），其余参数都已设好默认值。

核心的 Windows 7 兼容层来自上游项目 [crystalidea/qt6windows7](https://github.com/crystalidea/qt6windows7)：
它把 Qt 6 里那些在 Windows 7 上不存在的 API（WinRT、`SetTimerEx`、`DnsQueryEx`、D3D12 等）
改成运行时 `GetProcAddress` 加回退实现，从而让同一份 Qt 在 Windows 7 / 8 / 10 / 11 上都能跑。

本仓库不改动 Qt 的授权，只提供**编译脚本 + CI 流水线**。

---

## 快速开始

1. 打开 **Actions** → **Build Qt 6 for Windows 7** → **Run workflow**。
2. 在 **`qt_version`** 里填要编译的 Qt 版本号（默认 `6.8.4`；只填这一项即可）。
3. 点 **Run workflow**。

> 默认配置是 **`all` + `release` + 动态库（shared）**，编译全部社区开源模块并产出 Release 动态库。
> 完整全量构建需要 4 ~ 8 小时和数十 GB 磁盘，**GitHub 托管 runner 磁盘不够，必须用自托管 runner**。
> 详见[耗时与磁盘](#耗时与磁盘)与[自托管 runner](#自托管-runner)。
4. 编译结束后：
   - 工作流构件（Artifacts）里有 `Qt-6.8.4-msvc2022-Windows7x64-shared-Release.7z`
   - 同时在 **Releases** 里自动生成 `v6.8.4-win7` 版本并附带同名资产

```text
Qt-6.8.4-msvc2022-Windows7x64-shared-Release.7z          # 打包好的 Qt（bin/lib/plugins/include/mkspecs ...）
Qt-6.8.4-msvc2022-Windows7x64-shared-Release.7z.sha256   # 校验值
```

解包（需要 7-Zip）：

```bat
mkdir C:\Qt\6.8.4-win7
7z x Qt-6.8.4-msvc2022-Windows7x64-shared-Release.7z -oC:\Qt\6.8.4-win7
```

---

## 触发参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `qt_version` | `6.8.4` | **必填**。要编译的 Qt 版本，如 `6.8.4`、`6.10.3` |
| `patch_ref` | `master` | 上游补丁仓库的分支 / tag / commit。建议固定成 commit 以保证可复现 |
| `arch` | `x64` | `x64` 或 `x86`（x86 产物名为 `Windows7x86`；x86 不支持 WebEngine / Pdf） |
| `build_type` | `release` | `release` / `debug` / `debug-and-release`。Qt 始终编译为**动态库(shared)** |
| `module_preset` | `all` | `base`（仅 qtbase）/ `essential`（常用桌面模块）/ `all`（全部社区开源模块） |
| `extra_modules` | 全部社区版模块 | 在模块集基础上追加，空格分隔。默认已列出 Qt 开源版全部模块 |
| `skip_modules` | `qtopcua` | 要跳过的模块，空格分隔。默认跳过 `qtopcua`，原因见[已知模块限制](#已知模块限制) |
| `openssl_mode` | `static` | `static`（从源码静态编译 OpenSSL，并链接进 QtNetwork）/ `none` |
| `openssl_version` | `3.0.13` | 静态编译时使用的 OpenSSL 版本 |
| `ffmpeg_url` | 空 | 预编译 FFmpeg 前缀的 zip 地址，编译 `qtmultimedia` 时用 |
| `build_webengine` | `false` | 额外编译 QtWebEngine + QtPdf（**必须用自托管 runner**；Chromium 无法在 Win7 运行） |
| `publish_release` | `true` | 是否发布/更新 GitHub Release |
| `release_latest` | `false` | 是否把该 Release 标记为 latest |
| `retention_days` | `7` | 工作流构件保留天数 |
| `runs_on` | `windows-latest` | 运行器标签，可填自托管 runner 标签 |
| `clean_build_dir` | `false` | 安装后删除构建目录以释放磁盘 |
| `timeout_minutes` | `360` | 任务超时。GitHub 托管 runner 上限就是 360；自托管可调大 |

模块集说明：

| 预设 | 包含模块 |
|---|---|
| `base` | `qtbase` |
| `essential` | `qtbase` `qtshadertools` `qtdeclarative` `qtsvg` `qttools` `qtimageformats` `qt5compat` |
| `all` | 源码包里检测到的全部模块 |

默认 `extra_modules` 覆盖了 Qt 开源版（LGPL/GPL）的全部模块：

`qtbase` `qtdeclarative` `qtshadertools` `qttools` `qtsvg` `qtimageformats` `qt5compat`
`qtactiveqt` `qtcharts` `qtdatavis3d` `qtgraphs` `qt3d` `qtquick3d` `qtquick3dphysics`
`qtquicktimeline` `qtquickeffectmaker` `qtlottie` `qtnetworkauth` `qtcoap` `qtmqtt` `qtopcua`
`qtgrpc` `qthttpserver` `qtlanguageserver` `qtscxml` `qtremoteobjects` `qtserialbus`
`qtserialport` `qtwebsockets` `qtwebchannel` `qtwebview` `qtpositioning` `qtlocation`
`qtsensors` `qtspeech` `qtconnectivity` `qtvirtualkeyboard` `qtdoc` `qttranslations`

> 写进去但源码包里不存在的模块名会被自动忽略，所以同一份清单可以跨版本复用。

**两个例外，需要单独开启：**

- **`qtwebengine`**（含 QtPdf）：Chromium 体积巨大，走单独的二遍编译，用 `build_webengine` 开关控制。
- **`qtmultimedia`**：Qt 6.8 起 Windows 上只剩 FFmpeg 后端，**没有 FFmpeg 会直接配置失败**。
  用法：在 `extra_modules` 里加上 `qtmultimedia`，同时在 `ffmpeg_url` 填一个预编译的
  FFmpeg 前缀 zip（目录结构是 `include/` + `lib/` + `bin/`）。

`qtwayland` 是 Linux 专用，恒定跳过。

---

## 已知模块限制

| 模块 | 状态 | 说明 |
|---|---|---|
| `qtwayland` | 始终跳过 | Linux 专用 |
| `qtwebengine` / `qtpdf` | 默认跳过 | 需 `build_webengine=true` 二次编译；且 Chromium 已不支持 Windows 7 |
| `qtmultimedia` / `qtspeech` | 无 `ffmpeg_url` 时跳过 | Qt 6.8 起 Windows 仅剩 FFmpeg 后端；`qtspeech` 硬依赖 `qtmultimedia`，两者必须同进同出。提供 `ffmpeg_url` 后会自动编入 |
| `qtopcua` | **默认跳过** | **Qt 6.8.x + MSVC 的上游 bug（[QTBUG-131516](https://bugreports.qt.io/browse/QTBUG-131516)）**：`QOpcUa::NodeIds` 枚举过大，moc 生成的代码超出 MSVC 编译器限制（`C1106: only 16000 function parameters are allowed`）。官方修复只进了 **Qt 6.9.0**。构建 6.8.x 请把 `skip_modules` 保持默认；升级到 6.9+ 后可清空该项 |
| `qtconnectivity` | **默认跳过** | Windows 版 QtBluetooth **只有 WinRT 后端**，而 WinRT 是 Windows 8+ 才有的，Windows 7 上不存在——就算编出来在 Win7 也用不了。另外用新 MSVC 编译时它会撞 `<experimental/coroutine>` 的 `STL1011` 硬错误（该头文件已被微软标记即将移除）。**结论：Win7 目标下不要编蓝牙** |

> 想验证 `qtopcua` 是否仍失败，把 `skip_modules` 清空再跑一次即可，报错会直接指向
> `qopcuanodeids.cpp`。

### 🚨 最重要的一条：必须用 VS 2022（MSVC 14.4x），不能用 VS 2026

这不是"编译能不能过"的问题，而是**产出的 Qt 在 Windows 7 上能不能运行**的问题：

| 工具链 | VC++ 运行库 | Win7 支持 | 结论 |
|---|---|---|---|
| **VS 2022 / MSVC 14.4x** | v14.4x | ✅ 支持 Windows 7 SP1（需 KB3033929） | ✅ **可用** |
| VS 2026 / MSVC 14.51 | v14.50+ | ❌ **仅 Windows 10 / 11 与 Server 2016+** | ❌ **出来的 Qt 在 Win7 上跑不起来** |

微软官方《Latest supported Visual C++ Redistributable downloads》明确写明：
> The latest version of the Visual C++ v14 Redistributable included with Visual Studio 2026
> supports only: Windows 10 and 11, Windows Server 2016, 2019, 2022, and 2025.

而运行时版本号必须 **≥ 编译时 MSVC 工具集版本**，所以：**用 MSVC 14.51 编译 ⇒ 目标机必须装
14.51 运行库 ⇒ 目标机必须是 Win10+。** 用它编 Qt 给 Win7 用，从根上就不成立。

#### 因此：把 runner 钉到 `windows-2022`

GitHub 的 `windows-latest` 已在 2025 年 9 月迁移到 Windows Server 2025，现在是
`windows-2025-vs2026`（预装 VS 2026 / MSVC 14.51）。**而 `windows-2022` 镜像目前仍然受支持。**

```yaml
runs_on: windows-2022      # 工作流里这一项的默认值已经是它
```

一个改动同时带来三个好处：
1. VC++ 运行库 14.4x **支持 Windows 7 SP1** → 产物真正可部署；
2. Qt 6.8.4 官方验证的就是 MSVC 2022 → 避开 `STL1011` 那类新 STL/编译器的误伤；
3. **不需要自建 runner**，托管 runner 直接可用（且已实测 D: 有 147 GB、全量约 2.8h，资源够）。

> ⚠️ `windows-2022` 终将被弃用（有资料称约 2028 年）。届时改用装了 VS 2022 的**自托管 runner**
> （`runs_on` 填 `self-hosted, windows, x64`），**关键是 MSVC 工具集必须 ≤ 14.4x**。

## Windows 7 兼容性是怎么保证的

> **本项目的目标不是"编出全部模块"，而是"编出的 Qt 能在 Windows 7 上真的跑起来"。**
> 因此某些模块被默认跳过（见[已知模块限制](#已知模块限制)）——它们要么依赖 Win7 上不存在的
> WinRT，要么在该 Qt 版本 + MSVC 下本身就无法编译。**为了凑模块数去死磕它们是偏离目标的。**

### 兼容机制（来自上游）

[crystalidea/qt6windows7](https://github.com/crystalidea/qt6windows7) 把 Qt 6 里那些 Windows 7
上不存在的 API（WinRT、`SetTimerEx`、`DnsQueryEx`、D3D12、HighDPI 等）改成
**运行时 `GetProcAddress` + 回退实现**。这样同一份 Qt 在 Win7 / 8 / 10 / 11 上都能加载运行。

### 我们的三层校验（`scripts/Test-Artifacts.ps1`）

| 层次 | 检查内容 | 意义 |
|---|---|---|
| 烟雾构建 | 用编出来的 Qt 编译链接一个 Widgets 程序 | 证明这套 Qt 能被真正使用 |
| API-Set 扫描 | 导入表里有没有 Win7 上不存在的 `api-ms-win-*` / `ext-ms-win-*` | 通常是延迟加载，命中多为警告 |
| **静态导入函数扫描** | **只扫常规导入表（DataDirectory[1]），查有没有 Win8/10 才有的函数**（`GetDpiForWindow`、`GetAddrInfoEx`、`RoGetActivationFactory` 等） | **最关键的一层**：这里命中的是**硬性加载期依赖**，在 Win7 上会直接导致 DLL 加载失败 |

最后一层为什么准：**延迟加载的导入位于 Delayload 目录（DataDirectory[13]），不在常规导入表里**，
所以延迟加载 / `GetProcAddress` 保护的调用不会被误报——而这正是上游补丁的实现方式。

### ⚠️ 真机验证（必做）

GitHub 托管 runner 是 Windows Server，无法真正运行 Win7。**发布前务必在真实 Windows 7 x64 上做一次**：

```bat
:: 1) 解包
7z x Qt-6.8.4-msvc2022-Windows7x64-shared-Release.7z -oC:\Qt\6.8.4-win7

:: 2) 确认 Qt 核心库能被加载（最关键的一步）
dumpbin /imports C:\Qt\6.8.4-win7\bin\Qt6Core.dll | findstr /I "GetDpiForWindow GetAddrInfoEx RoGetActivationFactory"
::   无输出 = 没有静态依赖 Win8+ 函数

:: 3) 跑一个最小 Widgets 程序（Win7 需先装 VC++ 运行库）
::    Visual C++ Redistributable for Visual Studio 2015-2022 (x64)
cmake -S tests\hello -B build -DCMAKE_PREFIX_PATH=C:\Qt\6.8.4-win7
cmake --build build --config Release
```

要点：
- Win7 必须装 **VC++ 2015–2022 运行库**（Qt 用 MSVC 编的，依赖 `VCRUNTIME140.dll` / `MSVCP140.dll` / `ucrtbase.dll`）。
- 若某 DLL 加载失败，用 `dumpbin /imports` 或 Dependencies 工具看它静态依赖了哪个 Win8+ 函数，
  那就是上游补丁没覆盖到的点。

## 产物内容

产物优先打成 **`.7z`**；若运行环境里没有 7-Zip，会**自动退回 `.tar.gz`**（内容完全相同，只是体积更大），
文件名相应变为 `Qt-<版本>-msvc2022-Windows7x64-shared-Release.tar.gz`，Release 说明里的解压命令也会随之变化。

压缩包根节点就是 Qt 的安装前缀：

```text
bin/        Qt6Core.dll, Qt6Gui.dll, Qt6Widgets.dll, moc/uic/rcc/qmake 等工具
lib/        .lib 导入库与 CMake 包配置
plugins/    platforms/qwindows.dll, styles/, imageformats/, ...
include/    头文件
mkspecs/    qmake 规格
BUILDINFO.txt   本次构建的完整参数清单
```

用法：

```bat
mkdir C:\Qt\6.8.4-win7
7z x Qt-6.8.4-msvc2022-Windows7x64-shared-Release.7z -oC:\Qt\6.8.4-win7

cmake -S . -B build -DCMAKE_PREFIX_PATH=C:\Qt\6.8.4-win7
cmake --build build --config Release
```

发布时记得把用到的 `bin\*.dll` 和 `plugins\platforms\qwindows.dll` 一起带上。

---

## 编译流程

```text
1. 下载 qt-everywhere 源码（download.qt.io + 多个镜像兜底）
2. 用 crystalidea/qt6windows7 的替换文件覆盖 qtbase / qtmultimedia / qtwebengine
   —— 附带 win7-patches.json 记录 commit 与文件清单，便于溯源
3. 静态编译 OpenSSL（结果缓存在 Actions Cache，重复构建可跳过）
4. configure.bat：-opengl desktop -shared -openssl-linked -- -DOPENSSL_USE_STATIC_LIBS=ON ...
5. cmake --build --parallel  →  cmake --install
6. 冒烟编译 tests/hello，确认这套 Qt 能真正编译链接出一个 Widgets 程序
7. 扫描所有产出 .dll/.exe 的 PE 导入表，报告 Windows 7 上不存在的 API-Set
8. 打包成 Qt-<版本>-msvc2022-Windows7x64-shared-Release.7z 并发布到 Releases
```

---

## 耗时与磁盘

默认组合是 **`all` + `release` + 动态库(shared)**，编译全部社区开源模块并产出 Release 动态库：

| 配置 | 大致编译时间 | 峰值磁盘占用 |
|---|---|---|
| `base` / `release` | 40 ~ 70 分钟 | ~10 GB |
| `essential` / `release` | 1.5 ~ 3 小时 | ~25 GB |
| `all` / `release`（默认） | 4 ~ 8 小时 | ~60 GB |
| 再加 `build_webengine` | 20 小时以上 | 200 GB 以上 |

因此：

- **GitHub 托管 runner 跑不完默认配置**（限时 6 小时、磁盘约 30~40 GB 可用、
  4 核 / 16 GB 内存）。默认 `all` + `release` + 动态库 仍需要约 60 GB 峰值磁盘，
  请改用自托管 runner：把 `runs_on` 改成自托管 runner 的标签（`self-hosted, windows, x64`）
  并把 `timeout_minutes` 调大（如 `1440`）。
- 流水线**不会**去清理 runner 上预装的 SDK，磁盘只增不减；
  `clean_build_dir` 默认 `false`，所以构建目录会一直留着（方便排查，但很吃空间）。
  磁盘吃紧时把它打开。
- 想先看磁盘够不够，可以在触发后第一时间看 **Set up paths** 步骤的输出，
  那里会打印各分区剩余空间。

自托管 runner 建议自带：Visual Studio 2022（含 MSVC 与 Windows 10/11 SDK）、
CMake、Ninja、Perl（Strawberry Perl）、Python 3、Node.js、`git`、`tar`、`7z`，
以及 **150 GB 以上可用磁盘**。

> OpenSSL 用 `nmake` 单线程编译，约 10 ~ 20 分钟，结果会被 Actions Cache 缓存，
> 同一版本 + 同一架构第二次构建会直接跳过。

---

## 本地手动跑（不依赖 GitHub Actions）

脚本不依赖 Actions，可以直接在本机 PowerShell 7 里执行：

```powershell
git clone https://github.com/jx996/qt6-win7-builder.git
cd qt6-win7-builder

$work = 'C:\qt-work'
.\scripts\Fetch-QtSource.ps1      -Version 6.8.4 -Destination "$work\src"
.\scripts\Apply-Win7Patches.ps1   -SourceDir "$work\src" -PatchRef master -WorkDir "$work\patches"
.\scripts\Build-OpenSSL.ps1       -Version 3.0.13 -Arch x64 -Prefix "$work\openssl"
.\scripts\Configure-Qt.ps1        -SourceDir "$work\src" -InstallDir "$work\install" -Arch x64 -OpensslMode static -OpensslPrefix "$work\openssl"
.\scripts\Build-Qt.ps1            -SourceDir "$work\src" -InstallDir "$work\install" -Arch x64
.\scripts\Test-Artifacts.ps1      -InstallDir "$work\install" -Arch x64
.\scripts\Package-Qt.ps1          -InstallDir "$work\install" -Version 6.8.4 -Arch x64 -OutDir "$work\dist"
```

`Configure-Qt.ps1` / `Build-Qt.ps1` / `Test-Artifacts.ps1` 内部会在找不到 `cl.exe`
时自动通过 `vswhere` 加载 `vcvarsall.bat`，无需手动开 "Developer PowerShell"。

---

## 重要提醒

- **GitHub 托管的 runner 是 Windows Server，无法真正验证 Windows 7 兼容性。**
  流水线只做"静态检查 + 冒烟编译"，发布前请务必在真实的 Windows 7 x64 机器上跑一遍。
- 上游明确说明：Qt 6 的 **D3D12 后端在 Windows 7 上未被验证**，因此默认
  `-opengl desktop`，运行时走 D3D11。Windows 7 需要安装
  [KB2670838](https://www.microsoft.com/en-us/download/details.aspx?id=36805)（平台更新）
  才能获得可用的 D3D11。
- 上游补丁是以**整文件替换**的方式提供的，目前主要针对 **Qt 6.8.4**。
  编译其它版本时，`Apply-Win7Patches.ps1` 仍会把这些 6.8.4 版本的文件覆盖进去，
  能否编译通过取决于两个版本间的差异，请留意构建日志。
- Qt 本身遵循 LGPLv3 / GPLv2 / 商业授权，使用本仓库产出的二进制即代表你接受 Qt 的授权条款。

---

## 目录结构

```text
.github/workflows/build-qt6-win7.yml   # 主流程：手动触发，输入 Qt 版本号
.github/workflows/lint.yml             # actionlint 静态检查，几秒内发现工作流语法/上下文错误
scripts/Common.ps1                     # 日志、下载、解压、MSVC 环境等公共函数
scripts/Fetch-QtSource.ps1             # 下载并解包 qt-everywhere 源码
scripts/Apply-Win7Patches.ps1          # 覆盖式应用 Win7 补丁，输出溯源清单
scripts/Build-OpenSSL.ps1              # 静态编译 OpenSSL
scripts/Configure-Qt.ps1               # 计算 -skip 列表并执行 configure.bat
scripts/Build-Qt.ps1                   # cmake --build / --install，可选 WebEngine 二遍编译
scripts/Test-Artifacts.ps1             # 冒烟编译 + PE 导入表 Win7 兼容审计
scripts/Package-Qt.ps1                 # 打包 Qt-<版本>-msvc2022-Windows7<x64|x86>-shared-Release.7z + SHA256
tests/hello/                           # 用于冒烟测试的 Qt Widgets 小程序
```

## 排查

推送 `.github/workflows/**` 时会自动跑一遍 [actionlint](https://github.com/rhysd/actionlint)，
几秒内就能发现工作流错误，不用等编译跑到一半才失败。

本地也可以先自检（需要先装 actionlint）：

```bash
actionlint -no-color
```

已经踩过一次的坑：**工作流级 `env:` 只能用 `github` / `inputs` / `vars` 三个上下文**，
`runner.temp` 这类要放到步骤里用 `$GITHUB_ENV` 导出，否则 GitHub 会直接判定工作流文件无效：

```text
Invalid workflow file: Unrecognized named-value: 'runner'
```

另外 `runner` 上下文里也没有 `workspace` 属性（只有 `arch` / `debug` / `environment` /
`name` / `os` / `temp` / `tool_cache`）。

## 许可

MIT（见 [LICENSE](LICENSE)）。Qt 自身的授权以 Qt 官方条款为准。
