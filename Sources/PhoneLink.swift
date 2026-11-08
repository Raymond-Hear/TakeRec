import AppKit
@preconcurrency import AVFoundation
import Combine
import WebKit

@MainActor
final class PhoneLink: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let deviceID = "local.takerec.phone-web"
    static let deviceName = "手机网页"
    static let waitingToPair = "扫描二维码连接手机"
    private static let bridge = "takeRecPhone"

    private struct Pairing {
        let streamID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
        let password = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        var url: URL? {
            var options = URLComponents()
            options.queryItems = [URLQueryItem(name: "push", value: streamID), URLQueryItem(name: "p", value: password),
                                  URLQueryItem(name: "webcam", value: nil), URLQueryItem(name: "autostart", value: nil),
                                  URLQueryItem(name: "easyexit", value: nil), URLQueryItem(name: "quality", value: "0"),
                                  URLQueryItem(name: "maxframerate", value: "30"), URLQueryItem(name: "qos", value: "0")]
            var url = URLComponents()
            url.scheme = "https"
            url.host = "vdo.ninja"
            url.path = "/"
            url.percentEncodedFragment = options.percentEncodedQuery
            return url.url
        }
    }

    @Published private(set) var url: URL?
    @Published private(set) var hasVideo = false
    @Published private(set) var hasAudio = false
    @Published private(set) var status = PhoneLink.waitingToPair

    private let receiver: URL?
    private let decoderQueue = DispatchQueue(label: "local.takerec.phone-decode", qos: .userInitiated)
    private var decoder = PhoneMedia()
    private var web: WKWebView?
    private var receiverWindow: NSPanel?
    private var pairing: Pairing?
    private var watch: Task<Void, Never>?
    private var lastVideo: ContinuousClock.Instant?
    private var lastAudio: ContinuousClock.Instant?
    private var videoBusy = false
    private var route = 0
    private var videoOutput: ((CVPixelBuffer) -> Void)?
    private var audioOutput: ((CMSampleBuffer) -> Void)?

    init(receiver: URL? = Bundle.main.url(forResource: "receiver", withExtension: "html", subdirectory: "PhoneReceiver")) {
        self.receiver = receiver
    }

    var active: Bool { web != nil }

    func start() {
        stop()
        guard let receiver else { status = "缺少网页接收组件。"; return }
        let next = Pairing()
        guard let url = next.url else { return }
        pairing = next
        self.url = url
        status = "正在连接网页配对服务…"
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.inactiveSchedulingPolicy = .none
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(self, name: Self.bridge)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 160, height: 120), configuration: config)
        view.navigationDelegate = self
        web = view
        // WebKit suspends audio and video in a detached view. This transparent, noninteractive panel
        // stays attached when the recording window hides for full-screen capture.
        let panel = NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.canHide = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.contentView = view
        receiverWindow = panel
        panel.orderFrontRegardless()
        view.loadFileURL(receiver, allowingReadAccessTo: receiver.deletingLastPathComponent())
        startWatch()
    }

    func setOutputs(video: ((CVPixelBuffer) -> Void)?, audio: ((CMSampleBuffer) -> Void)?) {
        route += 1
        videoOutput = video
        audioOutput = audio
    }

    func stop() {
        watch?.cancel()
        watch = nil
        if let web {
            web.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridge)
            web.navigationDelegate = nil
            web.evaluateJavaScript("stopTakeRec()", completionHandler: nil)
            web.stopLoading()
        }
        receiverWindow?.orderOut(nil)
        receiverWindow?.contentView = nil
        receiverWindow = nil
        web = nil
        pairing = nil
        url = nil
        setOutputs(video: nil, audio: nil)
        decoder = PhoneMedia()
        videoBusy = false
        lastVideo = nil
        lastAudio = nil
        hasVideo = false
        hasAudio = false
        status = Self.waitingToPair
    }

    private func startWatch() {
        let deadline = ContinuousClock.now + .seconds(300)
        watch = Task { [weak self] in
            var received = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                let now = ContinuousClock.now
                if !received && now >= deadline {
                    self.stop()
                    self.status = "二维码已过期。可以重新生成。"
                    return
                }
                received = received || self.hasVideo || self.hasAudio
                let lostVideo = self.hasVideo && self.lastVideo.map { $0.duration(to: now) > .seconds(2) } == true
                let lostAudio = self.hasAudio && self.lastAudio.map { $0.duration(to: now) > .seconds(2) } == true
                if lostVideo { self.hasVideo = false }
                if lostAudio { self.hasAudio = false }
                if lostVideo || lostAudio {
                    if self.hasVideo || self.hasAudio { self.updateStatus() }
                    else { self.status = "手机连接已中断。请回到手机网页。" }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard web === webView, let pairing else { return }
        webView.callAsyncJavaScript("void startTakeRec(streamID, password);",
                    arguments: ["streamID": pairing.streamID, "password": pairing.password], in: nil, in: .page) { [weak self, weak webView] result in
            guard let self, self.web === webView else { return }
            if case .failure = result { self.status = "网页接收器无法启动。请重新生成二维码。" }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url == receiver ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard web === webView else { return }
        status = "无法载入网页接收器。请重新生成二维码。"
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard web === webView else { return }
        stop()
        status = "网页接收器已结束。可以重新生成二维码。"
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view = web, message.webView === view, message.frameInfo.isMainFrame,
              let value = message.body as? [String: Any], let kind = value["kind"] as? String else { return }
        switch kind {
        case "video":
            guard let data = value["data"] as? String, data.utf8.count <= 2_400_000 else { return }
            lastVideo = .now
            if !hasVideo { hasVideo = true; updateStatus() }
            guard videoOutput != nil, !videoBusy else { return }
            videoBusy = true
            let generation = route
            let decoder = decoder
            decoderQueue.async {
                let buffer = decoder.video(data)
                Task { @MainActor [weak self, weak view] in
                    guard let self, let view, self.web === view else { return }
                    self.videoBusy = false
                    if let buffer, generation == self.route { self.videoOutput?(buffer) }
                }
            }
        case "audio":
            guard let data = value["data"] as? String, data.utf8.count <= 24_000,
                  let rate = value["rate"] as? Int, let rate = Int32(exactly: rate), (16_000...96_000).contains(rate) else { return }
            lastAudio = .now
            if !hasAudio { hasAudio = true; updateStatus() }
            guard audioOutput != nil else { return }
            let generation = route
            let decoder = decoder
            let receivedAt = CMClockGetTime(CMClockGetHostTimeClock())
            decoderQueue.async {
                guard let sample = decoder.audio(data, rate: rate, receivedAt: receivedAt) else { return }
                Task { @MainActor [weak self, weak view] in
                    guard let self, let view, self.web === view, generation == self.route else { return }
                    self.audioOutput?(sample)
                }
            }
        case "waiting": status = "等待手机扫码授权"
        case "videoError": status = "手机画面接收失败。请重新打开手机网页。"
        case "audioError": status = "手机声音接收失败。可检查浏览器的麦克风权限。"
        case "error": status = "网页连接失败。请检查网络后重试。"
        default: break
        }
    }

    private func updateStatus() {
        if hasVideo && hasAudio { status = "已收到手机画面和声音" }
        else if hasVideo { status = "已收到手机画面，等待声音" }
        else if hasAudio { status = "已收到手机声音，等待画面" }
    }
}
