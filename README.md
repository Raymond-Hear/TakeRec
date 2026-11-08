# 简录 TakeRec

简录是一款原生 macOS 录屏与轻剪辑工具。它分别保存屏幕、摄像头、麦克风和系统声音，方便录完以后调整人像位置、运镜和混音。当前公开测试版为 **0.15.0**，界面为简体中文。

## 下载和试录

从 GitHub 的 **Releases** 打开 `v0.15.0`，下载 `TakeRec-0.15.0-macOS-universal.zip`。解压后打开「简录.app」，也可将它拖到「应用程序」。支持 macOS 15 及以上，安装包包含 Apple 芯片和 Intel 架构。全屏录制时排除简录浮窗需要 macOS 15.2 或以上。

测试包采用临时签名，尚未经过 Apple 公证。若 macOS 拦截首次打开，请确认文件来自本仓库 Release，再到「系统设置 → 隐私与安全性」查看是否有「仍要打开」。也可以用下面的步骤从源码构建。 [Apple 关于在 macOS 上安全打开 App 的说明](https://support.apple.com/zh-cn/102445)

1. 选择单窗口或全屏，在 macOS 选择器中指定要录的内容。
2. 按需开启相机、麦克风和系统声音。相机支持预览和镜像，麦克风可以选设备、看电平。录制外放音频时，耳机或耳麦有助于减少串音。
3. 按 `⌃⇧R` 开始，按 `⌃⇧S` 结束。录制浮条提供计时、音量、暂停和结束。可在「设置 → 快捷键」修改按键。
4. 在时间线拖动、裁切或分割片段，调节各轨显隐、音量与运镜。按空格预览，`⌘K` 分割当前轨，`⌘S` 保存工程。需要续录时可把新素材接到当前工程末尾。

分辨率支持 1080p 和 4K 档位，保留来源比例，并以原始素材像素为上限。成片导出为 MP4。工程保存为 `.desktake`，其中含可继续编辑的分轨素材。提词器可在录制前填写和拖动，录制期间用快捷键翻页。

## 从源码构建

需要 Mac 和完整的 Xcode。已使用 Xcode 26.6 构建。首次使用 Xcode 时，先打开一次并完成组件安装。若 `xcode-select -p` 显示命令行工具目录，在「Xcode → Settings → Locations → Command Line Tools」选择已安装的 Xcode。

在本仓库根目录运行：

```bash
./build.sh 'build/简录.app'
open 'build/简录.app'
```

脚本编译 Swift 源码、打包图标和网页接收器，并生成通用 App。默认使用本地临时签名。指定自有签名身份时可通过 `DESKTAKE_SIGN_IDENTITY` 传入。开发和本地构建不需要付费的 Apple Developer Program 会员资格。

## 调试

先用一个空白窗口做短录制。逐项开启摄像头、麦克风与系统声音，查看录制前预览、浮条电平、各条音轨波形和导出的 MP4。若某项没有输入，先确认选中了正确设备，并到「系统设置 → 隐私与安全性」检查相应的屏幕与系统音频录制、摄像头或麦克风权限。更换签名或 App 版本后，macOS 可能会再次请求授权。

需要断点时，构建当前 Mac 架构的调试版并在终端启动 LLDB：

```bash
TAKEREC_BUILD_CONFIGURATION=debug ./build.sh 'build/简录-调试.app'
xcrun lldb 'build/简录-调试.app/Contents/MacOS/TakeRec'
```

在 LLDB 中载入符号，再设断点：

```text
target symbols add "build/简录-调试.app/Contents/Resources/TakeRec.dSYM"
breakpoint set --file DeskTakeApp.swift --line 44
run
```

用 macOS「控制台」按进程 `TakeRec` 查看日志和崩溃报告。报告问题时请注明简录版本、macOS 版本、Mac 架构、选择的录制来源和复现步骤，并用测试窗口代替个人录屏或工程。

| 要调试的部分 | 入口 |
| --- | --- |
| 屏幕来源、采集配置 | [ScreenTake.swift](Sources/ScreenTake.swift) |
| 相机、麦克风预览 | [DevicePreview.swift](Sources/DevicePreview.swift) |
| 分轨写入 | [MovieWriter.swift](Sources/MovieWriter.swift) |
| 光标与点击事件 | [PointerCapture.swift](Sources/PointerCapture.swift) |
| 时间线与工程 | [ClipTimelineView.swift](Sources/ClipTimelineView.swift)、[TakeProject.swift](Sources/TakeProject.swift) |
| 运镜、混音与导出 | [TakeCompositor.swift](Sources/TakeCompositor.swift)、[MovieExport.swift](Sources/MovieExport.swift) |

## 媒体与隐私

- 使用 Mac 本机输入时，屏幕、摄像头、麦克风、系统声音和点击轨迹在本机处理。工程和导出文件保存在 Mac。
- 手机扫码是可选功能。启用时手机浏览器访问第三方 VDO.Ninja 页面，配对依赖其信令服务。相机和麦克风通过加密 WebRTC 传到 Mac，无法直连时可能经过 TURN 中继。服务可能处理 IP 和连接诊断。 [VDO.Ninja 工作原理](https://docs.vdo.ninja/readme/how-does-it-work) · [VDO.Ninja 隐私说明](https://docs.vdo.ninja/help/privacy-and-security-details/vdo.ninja-privacy-policy)
- 「Agent 剪辑」把工程副本与说明写到用户选择的本机文件夹，并把提示词复制到剪贴板。由用户决定是否把素材交给外部工具，后续处理取决于所选工具。

## 许可

简录代码采用 [MIT](LICENSE)。Lucide 图标按随附的 [ISC 与 MIT 许可](App/Lucide-LICENSE.txt) 分发。网页接收器包含 VDO.Ninja SDK 1.6.2，SDK 源码随包分发并适用 [MPL-2.0](App/PhoneReceiver/VDO-Ninja-MPL-2.0.txt)。 [VDO.Ninja SDK 对应版本](https://github.com/steveseguin/ninjasdk/tree/328965a06fa19cf47c3f01182e9cb1d91f39214e)
