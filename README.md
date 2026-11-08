# 简录 TakeRec

有时候我想录一段很短的演示，像坐在对方旁边那样，指着画面说「这里点一下，接下来这样做」。

录屏软件已经很多了。我用起来，还是常在几个小地方卡住。回看时，窗口里本来读得清的字变糊了。网页里的声音一响，我刚说的那句就听不清了。偏偏被盖过去的，可能就是「为什么要点这里」。

后来我想，干脆做一个自己用着顺手的。第一版能录下来，也能导出去。再一段段试，才知道还差什么。慢慢地，屏幕、摄像头、麦克风和电脑声音各自留了一份。录完还能把解说单独拉响，把鼠标点到的地方放大。讲漏了一步，就接着录进去。

我把简录开源了，想看看换一种录法，它还会在哪里卡住。你可以拿它录教程、演示一个刚做好的功能，也可以只录十几秒，给朋友看一下刚才那个按钮在哪儿。

## 先录一小段

下载公开测试版 **0.15.0**，解压后打开「简录.app」。支持 macOS 15 及以上，安装包同时适用于 Apple 芯片和 Intel Mac。[下载简录](https://github.com/Raymond-Hear/TakeRec/releases/download/v0.15.0/TakeRec-0.15.0-macOS-universal.zip)

可以先选一个窗口，按 `⌃⇧R` 开始，讲两句，再按 `⌃⇧S` 结束。如果想试试录完再调声音，开录前同时开启麦克风和系统声音，录完到「声音」里把原声调低一点。满意了就导出 MP4，想留着下次接着改，就保存为 `.desktake` 工程。

测试包使用临时签名，尚未经过 Apple 公证。首次打开若被拦截，请核对下载来源，再到「系统设置 → 隐私与安全性」查看「仍要打开」。[Apple 打开 App 的说明](https://support.apple.com/zh-cn/102445)

## 录完，欢迎回来聊两句

如果简录刚好帮上了忙，欢迎在仓库右上角点个 **Star**。用过之后，哪一步省了事，哪一步又让你重录了一次，都欢迎回来告诉我。遇到问题时，写下简录和 macOS 的版本，再说说是怎么碰到的。用一个空白窗口复现就够了。[提交 Issues](https://github.com/Raymond-Hear/TakeRec/issues)

<details>
<summary>想从源码构建或调试</summary>

需要安装完整的 Xcode。本版用 Xcode 26.6 验证过。首次使用 Xcode 时，先打开一次并完成组件安装。如果 `xcode-select -p` 指向单独的命令行工具目录，可在「Xcode → Settings → Locations → Command Line Tools」选择 Xcode。

在终端下载源码、构建并打开简录。

```bash
git clone https://github.com/Raymond-Hear/TakeRec.git
cd TakeRec
./build.sh 'build/简录.app'
open 'build/简录.app'
```

脚本默认使用本地临时签名。也可通过 `DESKTAKE_SIGN_IDENTITY` 指定自己的签名身份。

需要下断点时，构建当前 Mac 架构的调试版。

```bash
TAKEREC_BUILD_CONFIGURATION=debug ./build.sh 'build/简录-调试.app'
xcrun lldb 'build/简录-调试.app/Contents/MacOS/TakeRec'
```

在 LLDB 中载入符号，让程序在主窗口打开时停下来。

```text
target symbols add "build/简录-调试.app/Contents/Resources/TakeRec.dSYM"
breakpoint set --file DeskTakeApp.swift --line 44
run
```

排查采集时，建议用空白窗口短录，逐项开启相机、麦克风和系统声音。没有输入时，先看选中的设备，再检查 macOS「隐私与安全性」里的授权。全屏录制时排除简录浮窗需要 macOS 15.2 或以上。在「控制台」里按进程名 `TakeRec` 可以查日志和崩溃报告。

</details>

## 素材和许可

用 Mac 本机输入录制时，素材在本机处理和保存。手机扫码是可选功能，通过 VDO.Ninja 配对，再通过加密 WebRTC 把手机画面和声音传给 Mac。无法直连时可能经过 TURN 中继，服务也可能处理 IP 与连接诊断。[VDO.Ninja 隐私说明](https://docs.vdo.ninja/help/privacy-and-security-details/vdo.ninja-privacy-policy)

「Agent 剪辑」会把素材包写到你选的本机文件夹，并把提示词复制到剪贴板。是否交给其他工具，由你决定。

简录代码采用 MIT。Lucide 图标按随附的 ISC 与 MIT 许可分发，VDO.Ninja SDK 1.6.2 按 MPL-2.0 分发。[简录许可](LICENSE) · [Lucide 许可](App/Lucide-LICENSE.txt) · [VDO.Ninja SDK 许可](App/PhoneReceiver/VDO-Ninja-MPL-2.0.txt) · [SDK 对应源码](https://github.com/steveseguin/ninjasdk/tree/328965a06fa19cf47c3f01182e9cb1d91f39214e)
