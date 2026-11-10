<div align="center">
  <p><a href="README.md">简体中文</a> · <strong>English</strong></p>
  <img src="docs/images/takerec-icon.png" alt="TakeRec app icon" width="92">
  <h1>TakeRec 简录</h1>
  <p><strong>An open-source Mac screen recorder for showing someone how it’s done.</strong></p>
  <p>
    <a href="https://github.com/Raymond-Hear/TakeRec/releases/tag/v0.29.0"><img src="https://img.shields.io/badge/Release-v0.29.0-6E56AE?style=flat-square" alt="Preview release v0.29.0"></a>
    <img src="https://img.shields.io/badge/macOS-15%2B-3D776B?style=flat-square" alt="macOS 15 or later">
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-675F7B?style=flat-square" alt="MIT license"></a>
  </p>
  <p><a href="https://github.com/Raymond-Hear/TakeRec/releases/download/v0.29.0/TakeRec-0.29.0-macOS-universal.zip"><strong>Download the Mac preview</strong></a> · <a href="#beginner-tutorial"><strong>Beginner tutorial</strong></a> · <a href="#whats-new">What’s new</a> · <a href="https://github.com/Raymond-Hear/TakeRec/issues">Share feedback</a></p>
</div>

## What’s new

- **Multiple camera angles.** Record up to three cameras at once, including the Mac camera, an external camera, and a phone paired by QR code. Show, hide, or switch angles in the editor.
- **Landscape and portrait canvases.** Switch between the source aspect ratio, 16:9, and 9:16. Customize the portrait background, then resize and reposition the screen and camera footage.
- **Captions and transcription.** Import SRT or TXT and edit the timing, text, and styling. The Captions sidebar groups M4A and low-resolution MP4 exports with the Tingwu link and upload steps.
- **A separate keystroke track.** Preview keycaps while recording and show or hide them in the editor. Keystroke capture can resume after a brief interruption. You can start a screen recording while Input Monitoring is unavailable.
- **Recording controls and teleprompter.** Drag the control bar to a convenient spot and check the timer, audio levels, and shortcuts. Page through the script with shortcuts or set an auto-scroll speed.
- **Full-screen options.** Choose whether to include the top menu bar. With permission, the recording controls and teleprompter can stay visible on your desktop and be excluded from the video.
- **Editing workspace.** Resize the preview or collapse the sidebar. Hold Ctrl and scroll to zoom the timeline, or hold Option and scroll to pan it. Screen and camera clips show thumbnails.
- **Separate audio tracks.** Improved microphone capture when recording system audio at the same time. Adjust narration and system audio separately in the editor.
- **Recording and editing controls.** Set up permissions in one place and find TakeRec by its color menu bar icon. Open Agent Editing to export a media bundle or import an edit plan.

## Beginner tutorial

Let’s make a short video, about ten seconds long. You’ll type a line in TextEdit, then save the video to your desktop. The app is in Simplified Chinese, so the steps include the button labels you’ll see.

### 1. Open TakeRec

1. [Download the Mac preview](https://github.com/Raymond-Hear/TakeRec/releases/download/v0.29.0/TakeRec-0.29.0-macOS-universal.zip). It runs on Apple silicon and Intel Macs with macOS 15 or later.
2. In Finder, open Downloads and double-click the ZIP to unpack it. Then double-click `简录.app`.

If macOS blocks the first launch, confirm that you downloaded the app from this repository, then look for **Open Anyway** in System Settings → Privacy & Security. [Apple’s guide to opening apps](https://support.apple.com/en-us/102445)

### 2. Check the permissions

On the permissions screen 「设置录制权限」, **click 「完成」 (Done) or 「暂不设置」 (Skip for now)** for this exercise. macOS will ask you which window to share in the next step. You can grant the other permissions when you want to use those features.

| Permission in TakeRec | When you need it |
| --- | --- |
| 屏幕与系统音频录制 · Screen & System Audio Recording | For this exercise, share one window in the macOS picker. Grant screen recording permission later if you want to use the controls and teleprompter during a full-screen recording and keep them out of the video. |
| 摄像头 · Camera | When you want to record yourself on camera. |
| 麦克风 · Microphone | When you want to record your narration. |
| 输入监控 · Input Monitoring | When you want to enable 「保留按键轨」 and show the keys you press. |

When you need a permission later, click the shield icon 「权限设置」 in the upper right of TakeRec and click the settings button next to that permission. Follow the macOS prompts, then click 「重新检查」 (Check again) and look for 「已就绪」 (Ready). If macOS asks you to reopen TakeRec, the permission guide will reopen too. [Apple’s screen recording permission guide](https://support.apple.com/guide/mac-help/mchld6aa7d23/mac)

### 3. Choose the window to record

1. Open TextEdit and click New Document, or press <kbd>⌘N</kbd> to create a blank document. Leave that window open.
2. In TakeRec, choose 「单窗口」 (Single window) in the upper left. Click 「选择录制内容…」 next to it, choose your TextEdit document in the macOS picker, and confirm the share.
3. Check that the blank document appears in the preview on the left. On the right, leave 「摄像头」 (Camera), 「麦克风」 (Microphone), 「系统声音」 (System audio), and 「保留按键轨」 (Keep keystroke track) off. Keep 「显示录制控制条」 (Show recording controls) on.

<p align="center">
  <a href="docs/images/recording-preview.png"><img src="docs/images/recording-preview.png" alt="TakeRec recording setup. Choose a window in the upper left, check the preview on the left, and start recording in the lower right." width="760"></a><br>
  <sub>Recording setup with sample footage. You’ll see your blank document in the preview on the left and Start Recording in the lower right.</sub>
</p>

If the start button is gray, check that your document is visible in the preview and that the camera and microphone are both off.

### 4. Record ten seconds, then stop

1. Click 「开始录制」 (Start Recording) in the lower right. When the timer on the recording controls starts counting, click in the TextEdit document.
2. Slowly type “This is my first TakeRec video.” Wait two seconds.
3. Click 「结束」 (Stop) on the recording controls. If you can’t see the controls, hold <kbd>Control</kbd> and <kbd>Shift</kbd>, then press <kbd>S</kbd>. TakeRec opens 「剪辑工作台」 (the editor).

### 5. Play back your recording

Click ▶ below 「成片预览」 (Video preview). Once you see the line you typed, you’re ready to export.

<p align="center">
  <a href="docs/images/timeline-editor.png"><img src="docs/images/timeline-editor.png" alt="TakeRec’s editor. Play is below the preview and Export MP4 is in the upper right." width="760"></a><br>
  <sub>The editor with sample footage. Play your take, then click Export MP4 in the upper right.</sub>
</p>

### 6. Save your first video to the desktop

1. Click 「导出 MP4…」 (Export MP4) in the upper right. In the save dialog, name the file “My first TakeRec video” and choose Desktop.
2. Under 「成片分辨率」 (Video resolution), choose the 1080p option and click 「导出 MP4」 (Export MP4).
3. When you see 「MP4 已导出」 (MP4 exported), click 「播放成片」 (Play video) at the top. You can share the MP4 file on your desktop.

To record your voice next time, turn on 「麦克风」 before starting, grant microphone access, and say a few words. Once the level meter on the right moves as you speak, click Start Recording.

If you found TakeRec useful, a **Star** is welcome. Tell me what worked for you and where it could improve. [Open an issue](https://github.com/Raymond-Hear/TakeRec/issues)

<details>
<summary><strong>Build from source and debug</strong></summary>

Install and open the full Xcode app once, then run these commands.

```bash
git clone https://github.com/Raymond-Hear/TakeRec.git
cd TakeRec
./build.sh 'build/简录.app'
open 'build/简录.app'
```

To set breakpoints, build for your Mac’s architecture.

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
<summary><strong>Privacy and third-party licenses</strong></summary>

TakeRec processes and saves footage from local inputs on your Mac. Keystroke capture is optional and runs during recording. Phone pairing uses VDO.Ninja for signaling and encrypted WebRTC for media. If a direct connection fails, the media may travel through a TURN relay. [VDO.Ninja privacy policy](https://docs.vdo.ninja/help/privacy-and-security-details/vdo.ninja-privacy-policy)

Agent bundles and transcription files are saved to a folder you choose. When using Tingwu, you select the file to upload on its website.

TakeRec’s code is MIT licensed. Lucide icons use the included ISC and MIT terms. The bundled VDO.Ninja SDK 1.6.2 uses MPL-2.0. [TakeRec license](LICENSE) · [Lucide licenses](App/Lucide-LICENSE.txt) · [VDO.Ninja SDK license](App/PhoneReceiver/VDO-Ninja-MPL-2.0.txt) · [SDK source](https://github.com/steveseguin/ninjasdk/tree/328965a06fa19cf47c3f01182e9cb1d91f39214e)

</details>

## About the author

I’m **聆风Raymond**, the creator of TakeRec.

- **WeChat Official Account**　聆风Raymond
- **Email**　[heylingfeng@111.com](mailto:heylingfeng@111.com)
- **GitHub**　[@Raymond-Hear](https://github.com/Raymond-Hear)

<p>
  <img src="App/Assets.xcassets/WeChatFollowQRCode.imageset/follow.png" alt="QR code for Raymond’s WeChat Official Account" width="144"><br>
  <sub>Scan with WeChat to follow</sub>
</p>
