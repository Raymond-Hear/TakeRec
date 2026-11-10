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
  <p><a href="https://github.com/Raymond-Hear/TakeRec/releases/download/v0.29.0/TakeRec-0.29.0-macOS-universal.zip"><strong>下载 Mac 测试版</strong></a> · <a href="FIRST-RECORDING.md#简体中文"><strong>新手教程</strong></a> · <a href="#本次更新">本次更新</a> · <a href="https://github.com/Raymond-Hear/TakeRec/issues">提交反馈</a></p>
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

<p align="center">
  <a href="docs/images/timeline-editor.png"><img src="docs/images/timeline-editor.png" alt="简录剪辑工作台" width="880"></a><br>
  <sub>剪辑工作台 · 演示素材</sub>
</p>

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
