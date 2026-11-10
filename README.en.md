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
  <p><a href="https://github.com/Raymond-Hear/TakeRec/releases/download/v0.29.0/TakeRec-0.29.0-macOS-universal.zip"><strong>Download the Mac preview</strong></a> · <a href="#whats-new">What’s new</a> · <a href="https://github.com/Raymond-Hear/TakeRec/issues">Share feedback</a></p>
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

<p align="center">
  <a href="docs/images/timeline-editor.png"><img src="docs/images/timeline-editor.png" alt="TakeRec’s editor with a video preview, timeline, and editing sidebar." width="880"></a><br>
  <sub>Editing workspace · sample footage</sub>
</p>

## Try a short take

<p align="center">
  <a href="docs/images/recording-preview.png"><img src="docs/images/recording-preview.png" alt="TakeRec’s recording setup with screen and camera previews and a microphone level meter." width="880"></a><br>
  <sub>Recording setup · sample footage</sub>
</p>

1. Unzip the download and open `简录.app`. The preview runs on Apple silicon and Intel Macs. In the Simplified Chinese app, choose 「单窗口」 for one window or 「全屏」 for the whole screen.
2. Press <kbd>⌃⇧R</kbd> to start and <kbd>⌃⇧S</kbd> to stop. Enable the microphone and system audio before recording to mix them separately later.
3. Edit your take, save it as a `.desktake` project, or export an MP4.

> If macOS blocks the first launch, confirm where you downloaded the app, then look for “Open Anyway” in System Settings → Privacy & Security. [Apple’s guide to opening apps](https://support.apple.com/en-us/102445)

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
