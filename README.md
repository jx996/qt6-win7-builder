# qt6-win7-builder

用 GitHub Actions 自动编译**可在 Windows 7 x64 上运行的 Qt 6**，并把产物打包成
`<Qt版本号>_Windows7.tar.gz` 自动发布到 Releases。

核心的 Windows 7 兼容层来自上游项目 [crystalidea/qt6windows7](https://github.com/crystalidea/qt6windows7)：
它把 Qt 6 里那些在 Windows 7 上不存在的 API（WinRT、`SetTimerEx`、`DnsQueryEx`、D3D12 等）
改成运行时 `GetProcAddress` 加回退实现，从而让同一份 Qt 在 Windows 7 / 8 / 10 / 11 上都能跑。

本仓库不改动 Qt 的授权，只提供**编译脚本 + CI 流水线**。

---

## 快速开始

1. Fork 或直接使用本仓库。
2. 打开 **Actions** → **Build Qt 6 for Windows 7** → **Run workflow**。
3. 在 **`qt_version`** 里填要编译的 Qt 版本号（例如 `6.8.4`）。
4. 其余参数用默认值即可，点 **Run workflow**。
5. 编译结束后：
   - 工作流构件（Artifacts）里有 `6.8.4_Windows7.tar.gz`
   - 同时在 **Releases** 里自动生成 `v6.8.4-win7` 版本并附带同名资产

```text
6.8.4_Windows7.tar.gz          # 打包好的 Qt（bin/lib/plugins/include/mkspecs ...）
6.8.4_Windows7.tar.gz.sha256   # 校验值
```

---

## 触发参数

| 参数 | 默认值 | 说明 |
|---|---|---|
| `qt_version` | `6.8.4` | **必填**。要编译的 Qt 版本，如 `6.8.4`、`6.10.3` |
| `patch_ref` | `master` | 上游补丁仓库的分支 / tag / commit。建议固定成 commit 以保证可复现 |
| `arch` | `x64` | `x64` 或 `x86`（x86 不支持 WebEngine / Pdf） |
| `build_type` | `release` | `release` / `debug` / `debug-and-release` |
| `module_preset` | `essential` | `base`（仅 qtbase）/ `essential`（常用桌面模块）/ `all` |
| `extra_modules` | 空 | 在模块集基础上追加，空格分隔，如 `qtmultimedia qtcharts` |
| `skip_modules` | 空 | 要跳过的模块，空格分隔 |
| `openssl_mode` | `static` | `static`（从源码静态编译 OpenSSL）/ `none` |
| `openssl_version` | `3.0.13` | 静态编译时使用的 OpenSSL 版本 |
| `ffmpeg_url` | 空 | 预编译 FFmpeg 前缀的 zip 地址，编译 `qtmultimedia` 时用 |
| `build_webengine` | `false` | 额外编译 QtWebEngine + QtPdf（**强烈建议自托管 runner**） |
| `publish_release` | `true` | 是否发布/更新 GitHub Release |
| `release_latest` | `false` | 是否把该 Release 标记为 latest |
| `retention_days` | `7` | 工作流构件保留天数 |
| `runs_on` | `windows-latest` | 运行器标签，可填自托管 runner 标签 |
| `clean_build_dir` | `true` | 安装后删除构建目录以释放磁盘 |

模块集说明：

| 预设 | 包含模块 |
|---|---|
| `base` | `qtbase` |
| `essential` | `qtbase` `qtshadertools` `qtdeclarative` `qtsvg` `qttools` `qtimageformats` `qt5compat` |
| `all` | 除 `qtwebengine`（单独二遍编译）与 `qtwayland`（Linux 专用）外的全部模块 |

---

## 产物内容

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
tar -xzf 6.8.4_Windows7.tar.gz -C C:\Qt\6.8.4-win7

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
4. configure.bat：-opengl desktop -openssl-linked -- -DOPENSSL_USE_STATIC_LIBS=ON ...
5. cmake --build --parallel  →  cmake --install
6. 冒烟编译 tests/hello，确认这套 Qt 能真正编译链接出一个 Widgets 程序
7. 扫描所有产出 .dll/.exe 的 PE 导入表，报告 Windows 7 上不存在的 API-Set
8. 打包成 <Qt版本号>_Windows7.tar.gz 并发布到 Releases
```

---

## 耗时与配额

| 模块集 | GitHub 托管 runner 上的大致耗时 |
|---|---|
| `base` | 40 ~ 70 分钟 |
| `essential` | 1.5 ~ 3 小时 |
| `all` | 3 ~ 6 小时 |
| `all` + WebEngine | **会超时 / 磁盘不足，请使用自托管 runner** |

GitHub 托管的 Windows runner 限时 **6 小时**、内存 16 GB。若需要编译完整 Qt 或
QtWebEngine，请把 `runs_on` 改成自托管 runner 的标签（`self-hosted, windows, x64`）。

自托管 runner 建议自带：Visual Studio 2022（含 MSVC 与 Windows 10/11 SDK）、
CMake、Ninja、Perl（Strawberry Perl）、Python 3、Node.js、`git`、`tar`、`7z`。

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
.github/workflows/build-qt6-win7.yml   # 唯一的工作流：手动触发，输入 Qt 版本号
scripts/Common.ps1                     # 日志、下载、解压、MSVC 环境等公共函数
scripts/Fetch-QtSource.ps1             # 下载并解包 qt-everywhere 源码
scripts/Apply-Win7Patches.ps1          # 覆盖式应用 Win7 补丁，输出溯源清单
scripts/Build-OpenSSL.ps1              # 静态编译 OpenSSL
scripts/Configure-Qt.ps1               # 计算 -skip 列表并执行 configure.bat
scripts/Build-Qt.ps1                   # cmake --build / --install，可选 WebEngine 二遍编译
scripts/Test-Artifacts.ps1             # 冒烟编译 + PE 导入表 Win7 兼容审计
scripts/Package-Qt.ps1                 # 打包 <版本号>_Windows7.tar.gz + SHA256
tests/hello/                           # 用于冒烟测试的 Qt Widgets 小程序
```

## 许可

MIT（见 [LICENSE](LICENSE)）。Qt 自身的授权以 Qt 官方条款为准。
