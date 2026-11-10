<div align="center">
  <p><strong>简体中文</strong> · <a href="README.en.md">English</a></p>
  <img src="docs/images/takerec-icon.png" alt="简录应用图标" width="92">
  <h1>简录 TakeRec</h1>
  <p><strong>给想把一个操作讲清楚的人做的开源 Mac 录屏工具。</strong></p>
  <p>
    <a href="https://github.com/Raymond-Hear/TakeRec/releases/tag/v0.29.0"><img src="https://img.shields.io/badge/Release-v0.29.0-6E56AE?style=flat-square" alt="测试版 v0.29.0"></a>
    <img src="https://img.shields.io/badge/macOS-15%2B-3D776B?style=flat-square" alt="macOS 15 及以上">
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-675F7B?style=flat-square" alt="MIT 许可"></a>
  </p>
  <p><a href="https://github.com/Raymond-Hear/TakeRec/releases/download/v0.29.0/TakeRec-0.29.0-macOS-universal.zip"><strong>下载 Mac 测试版</strong></a> · <a href="#新手教程"><strong>新手教程</strong></a> · <a href="#本次更新">本次更新</a> · <a href="https://github.com/Raymond-Hear/TakeRec/issues">提交反馈</a></p>
</div>

## 本次更新

- **多机位录制**。Mac、外接和扫码连接的手机摄像头可以同时录制，最多三路。剪辑时可单独显示、隐藏或切换机位。
- **横屏与竖屏**。同一工程支持原比例、16:9 和 9:16。竖屏可换背景，也可调整录屏和人像的大小与位置。
- **字幕与转写**。导入 SRT 或 TXT，调整字幕时间、文字和样式。右侧「字幕 → 临时导出」提供 M4A、低清 MP4、通义听悟入口和上传步骤。
- **独立按键轨**。录制时可实时显示键帽，剪辑时可开关按键轨。按键采集断开后会尝试恢复，输入监控未就绪时也能开始录屏。
- **录制控制条与提词器**。可拖动控制条，查看计时、音量和快捷键。提词器支持快捷键翻页和自动滚动调速。
- **全屏选项**。可选择是否录入顶部菜单栏。授权后，录制控制条和提词器可显示在桌面上，同时从全屏成片中排除。
- **剪辑工作台**。可调整预览高度、收起右栏。时间线支持 Ctrl 滚轮缩放、Option 滚轮横移，屏幕和人像片段都可预览缩略图。
- **分轨收音**。改善麦克风与系统声音同时录制时的收音，剪辑时仍可单独调整解说与原声。
- **录制与剪辑入口**。录制页集中设置权限，菜单栏显示彩色图标。「Agent 剪辑」集中提供素材包导出与剪辑方案导入。

## 新手教程

我们先录一个约 10 秒的小视频。在「文本编辑」里打一行字，最后把视频保存到桌面。每一步做完再往下走就好。

### 1. 打开简录

1. [下载简录 Mac 测试版](https://github.com/Raymond-Hear/TakeRec/releases/download/v0.29.0/TakeRec-0.29.0-macOS-universal.zip)。它支持 macOS 15 或更新版本，以及 Apple 芯片和 Intel Mac。
2. 在 Finder 的「下载」里双击 ZIP 解压，再双击解压出来的「简录.app」。

如果 macOS 拦截了首次打开，请先确认下载来自这个仓库，再到「系统设置 → 隐私与安全性」查看「仍要打开」。[Apple 打开 App 的说明](https://support.apple.com/zh-cn/102445)

### 2. 看一眼权限

看到「设置录制权限」时，**这次练习可以先点右下角的「完成」或「暂不设置」**。等到选窗口时，macOS 会请你确认共享哪个窗口。以后想加什么功能，就开对应的权限。

| 简录里的权限 | 什么时候需要 |
| --- | --- |
| 屏幕与系统音频录制 | 这次在 macOS 选择器里共享单个窗口即可。以后全屏录制时，想显示录制控制条和提词器并把它们排除在成片外，再给简录屏幕录制权限。 |
| 摄像头 | 想把人像一起录进去时开启。 |
| 麦克风 | 想把自己的解说录进去时开启。 |
| 输入监控 | 想在成片里展示按了哪些键，并开启「保留按键轨」时使用。 |

以后需要授权时，点简录右上角的盾牌图标「权限设置」，再点对应权限旁的设置按钮。按 macOS 提示操作，回到简录点「重新检查」，等那一项显示「已就绪」。如果系统提示重开简录，重开后会回到权限引导。[Apple 屏幕录制权限说明](https://support.apple.com/zh-cn/guide/mac-help/mchld6aa7d23/mac)

### 3. 选中要录的窗口

1. 打开 Mac 自带的「文本编辑」，点「新建文稿」，或按 <kbd>⌘N</kbd> 新建一份空白文稿。先留着这个窗口。
2. 回到简录，在左上角选「单窗口」，点旁边的「选择录制内容…」。在 macOS 弹出的选择器里选中文本编辑的文稿，按提示确认共享。
3. 看到简录左侧出现空白文稿的预览，就选对了。右侧把「摄像头」「麦克风」「系统声音」「保留按键轨」保持关闭，把「显示录制控制条」保持勾选。

<p align="center">
  <a href="docs/images/recording-preview.png"><img src="docs/images/recording-preview.png" alt="简录录制准备页。左上角选择窗口，左侧看预览，右下角开始录制。" width="760"></a><br>
  <sub>录制准备页的演示图。你的预览会显示空白文稿，右下角就是「开始录制」。</sub>
</p>

如果「开始录制」是灰色的，先确认左侧已经出现文稿预览，再看看右侧的摄像头和麦克风是否都已关闭。

### 4. 录十秒，再结束

1. 点简录右下角的「开始录制」。看到录制控制条开始计时，再点一下文本编辑的文稿。
2. 慢慢打下「这是我的第一个简录视频」，停两秒。
3. 点录制控制条上的「结束」。如果找不到控制条，按住 <kbd>Control</kbd> 和 <kbd>Shift</kbd>，再按 <kbd>S</kbd>。简录会打开「剪辑工作台」。

### 5. 回看刚录的画面

点「成片预览」下方的 ▶ 播放。看到那行字出现在画面里，就可以导出了。

<p align="center">
  <a href="docs/images/timeline-editor.png"><img src="docs/images/timeline-editor.png" alt="简录剪辑工作台。播放按钮在成片预览下方，导出 MP4 按钮在右上角。" width="760"></a><br>
  <sub>剪辑工作台的演示图。先点播放，再点右上角的「导出 MP4…」。</sub>
</p>

### 6. 把第一个视频存到桌面

1. 点右上角的「导出 MP4…」。在弹出的窗口里给文件取名「第一次简录」，把位置选为「桌面」。
2. 「成片分辨率」选 1080p 上限，点「导出 MP4」。
3. 等底部出现「MP4 已导出」，点顶部的「播放成片」。桌面上的「第一次简录.mp4」就是可以发给别人的视频。

下次想把自己的声音也录进去，可以在开录前开启「麦克风」、按提示允许，然后说一句话。看到右侧电平跟着动了，再点「开始录制」。

用过之后欢迎点个 **Star**，也欢迎告诉我哪里顺手、哪里还可以改。[提交 Issue](https://github.com/Raymond-Hear/TakeRec/issues)

<details>
<summary><strong>从源码构建与调试</strong></summary>

安装并打开一次完整的 Xcode 后，在终端运行。

```bash
git clone https://github.com/Raymond-Hear/TakeRec.git
cd TakeRec
./build.sh 'build/简录.app'
open 'build/简录.app'
```

如需断点调试，先构建当前 Mac 架构的调试版。

```bash
TAKEREC_BUILD_CONFIGURATION=debug ./build.sh 'build/简录-调试.app'
xcrun lldb 'build/简录-调试.app/Contents/MacOS/TakeRec'
```

```text
target symbols add "build/简录-调试.app/Contents/Resources/TakeRec.dSYM"
breakpoint set --file RecorderModel.swift --source-pattern-regexp "func startRecording"
run
```

</details>

<details>
<summary><strong>素材隐私与第三方许可</strong></summary>

使用本机输入录制时，素材在 Mac 上处理和保存。按键轨由你开启，只在录制期间采集。手机扫码通过 VDO.Ninja 配对，并通过加密 WebRTC 传输。无法直连时可能经 TURN 中继。[VDO.Ninja 隐私说明](https://docs.vdo.ninja/help/privacy-and-security-details/vdo.ninja-privacy-policy)

Agent 素材包和临时转写文件导出到你选择的本机位置。使用通义听悟时，由你在网页上选择要上传的文件。

简录代码采用 MIT。Lucide 图标按随附的 ISC 与 MIT 许可分发，VDO.Ninja SDK 1.6.2 按 MPL-2.0 分发。[简录许可](LICENSE) · [Lucide 许可](App/Lucide-LICENSE.txt) · [VDO.Ninja SDK 许可](App/PhoneReceiver/VDO-Ninja-MPL-2.0.txt) · [SDK 对应源码](https://github.com/steveseguin/ninjasdk/tree/328965a06fa19cf47c3f01182e9cb1d91f39214e)

</details>

## 关于作者

我是 **聆风Raymond**，简录的作者。

- **公众号**　聆风Raymond
- **邮箱**　[heylingfeng@111.com](mailto:heylingfeng@111.com)
- **GitHub**　[@Raymond-Hear](https://github.com/Raymond-Hear)

<p>
  <img src="App/Assets.xcassets/WeChatFollowQRCode.imageset/follow.png" alt="聆风Raymond 公众号关注二维码" width="144"><br>
  <sub>微信扫码关注</sub>
</p>
