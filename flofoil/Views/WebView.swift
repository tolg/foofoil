//
//  WebView.swift
//  flofoil
//
//  Created by tolg on 2026/7/10.
//

import SwiftUI
import WebKit

// 保留应用状态引用；网页右键菜单使用 WebKit 原生实现。
class NonMenuWebView: WKWebView {
    var appState: AppState?
}

// 网页加载组件
struct WebView: NSViewRepresentable {
    let url: URL
    let zoom: Double
    let appState: AppState

    @Binding var isLoading: Bool
    @Binding var progress: Double
    @Binding var loadError: Error?

    let onTitleChange: (String) -> Void
    let onScreenshotTaken: (NSImage) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(
            context.coordinator,
            name: Coordinator.editableFocusHandlerName
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Coordinator.editableFocusTrackingScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        let webView = NonMenuWebView(frame: .zero, configuration: configuration)
        webView.appState = appState
        webView.setValue(false, forKey: "drawsBackground") // 保持背景处理灵活性
        webView.pageZoom = CGFloat(zoom)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.setupObservers(webView: webView)
        return webView
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.editableFocusHandlerName
        )
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if let nonMenuWebView = nsView as? NonMenuWebView {
            nonMenuWebView.appState = appState
        }
        if nsView.pageZoom != CGFloat(zoom) {
            nsView.pageZoom = CGFloat(zoom)
        }
        if context.coordinator.lastLoadedURL != url {
            context.coordinator.lastLoadedURL = url
            if url.isFileURL {
                nsView.loadFileURL(url, allowingReadAccessTo: url)
            } else {
                let request = URLRequest(url: url)
                nsView.load(request)
            }
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
        static let editableFocusHandlerName = "flofoilEditableFocus"
        static let editableFocusTrackingScript = """
        (() => {
            const handler = window.webkit?.messageHandlers?.flofoilEditableFocus;
            if (!handler) return;

            const isEditable = (element) => {
                if (!element || element.disabled || element.readOnly) return false;
                if (element instanceof HTMLTextAreaElement || element.isContentEditable) return true;
                if (!(element instanceof HTMLInputElement)) return false;
                return !['button', 'checkbox', 'color', 'file', 'hidden', 'image', 'radio', 'range', 'reset', 'submit'].includes(element.type);
            };

            const report = (element) => handler.postMessage(isEditable(element));
            document.addEventListener('focusin', (event) => report(event.target), true);
            document.addEventListener('focusout', () => setTimeout(() => report(document.activeElement), 0), true);
            report(document.activeElement);
        })();
        """
        var parent: WebView
        var lastLoadedURL: URL?
        private var titleObservation: NSKeyValueObservation?
        private var progressObservation: NSKeyValueObservation?
        private var loadingObservation: NSKeyValueObservation?
        private var reloadNotificationToken: Any?
        private var captureNotificationToken: Any?
        private var saveSnapshotNotificationToken: Any?

        init(_ parent: WebView) {
            self.parent = parent
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.editableFocusHandlerName,
                  let isFocused = message.body as? Bool else { return }
            DispatchQueue.main.async {
                self.parent.appState.isWebEditableElementFocused = isFocused
            }
        }

        func setupObservers(webView: WKWebView) {
            titleObservation = webView.observe(\.title, options: [.new]) { [weak self] webView, change in
                guard let self = self else { return }
                if let title = change.newValue as? String, !title.isEmpty {
                    DispatchQueue.main.async {
                        self.parent.onTitleChange(title)
                    }
                }
            }

            progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, change in
                guard let self = self else { return }
                if let progress = change.newValue {
                    DispatchQueue.main.async {
                        self.parent.progress = progress
                    }
                }
            }

            loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] webView, change in
                guard let self = self else { return }
                if let isLoading = change.newValue {
                    DispatchQueue.main.async {
                        self.parent.isLoading = isLoading
                    }
                }
            }

            // 监听特定窗口的重新加载通知
            let notificationName = Notification.Name("reloadWebView_\(parent.appState.id.uuidString)")
            reloadNotificationToken = NotificationCenter.default.addObserver(
                forName: notificationName,
                object: nil,
                queue: .main
            ) { [weak webView] _ in
                webView?.reload()
            }

            // 监听特定窗口的截取图片箔通知
            let captureNotificationName = Notification.Name("captureImageFlofoil_\(parent.appState.id.uuidString)")
            captureNotificationToken = NotificationCenter.default.addObserver(
                forName: captureNotificationName,
                object: nil,
                queue: .main
            ) { [weak webView, weak self] _ in
                guard let webView = webView, let self = self else { return }

                // 触发闪白通知
                NotificationCenter.default.post(
                    name: Notification.Name("flashWindow_\(self.parent.appState.id.uuidString)"),
                    object: nil
                )

                let config = WKSnapshotConfiguration()
                webView.takeSnapshot(with: config) { nsImage, error in
                    if let image = nsImage {
                        let scale = webView.window?.backingScaleFactor ?? 1.0
                        DispatchQueue.main.async {
                            self.parent.appState.createNewFlofoilFromScreenshot(image: image, backingScaleFactor: scale)
                        }
                    } else if let error = error {
                        NSLog("Failed to take manual web snapshot: \(error.localizedDescription)")
                    }
                }
            }

            // 监听特定窗口的“另存为截图并闪白”通知
            let saveSnapshotNotificationName = Notification.Name("triggerSaveSnapshot_\(parent.appState.id.uuidString)")
            saveSnapshotNotificationToken = NotificationCenter.default.addObserver(
                forName: saveSnapshotNotificationName,
                object: nil,
                queue: .main
            ) { [weak webView, weak self] _ in
                guard let webView = webView, let self = self else { return }

                // 立即发送闪光通知
                NotificationCenter.default.post(
                    name: Notification.Name("flashWindow_\(self.parent.appState.id.uuidString)"),
                    object: nil
                )

                let config = WKSnapshotConfiguration()
                webView.takeSnapshot(with: config) { nsImage, error in
                    if let image = nsImage {
                        DispatchQueue.main.async {
                            self.parent.appState.saveWebScreenshot(image, triggerSavePanel: true)
                        }
                    } else if let error = error {
                        NSLog("Failed to take web snapshot for saving: \(error.localizedDescription)")
                    }
                }
            }

        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.loadError = nil
                self.parent.isLoading = true
                self.parent.progress = 0.0
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return // 忽略取消事件，避免在前一请求被覆盖时弹窗报错
            }
            DispatchQueue.main.async {
                self.parent.loadError = error
                self.parent.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return // 忽略取消事件
            }
            DispatchQueue.main.async {
                self.parent.loadError = error
                self.parent.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            if let currentURL = webView.url {
                DispatchQueue.main.async {
                    self.parent.appState.actualWebURL = currentURL
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let currentURL = webView.url {
                DispatchQueue.main.async {
                    self.parent.appState.actualWebURL = currentURL
                }
            }
            // 网页可见正文与截图相互独立；正文失败不会影响现有截图流程。
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] value, _ in
                guard let self, let text = value as? String else { return }
                ContentIndexCoordinator.shared.indexWebContent(historyID: self.parent.appState.id, text: text)
            }
            // 页面加载完成，延迟 1.5 秒截图，避免有些动态内容还未显示
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak webView, weak self] in
                guard let webView = webView, let self = self else { return }
                guard !webView.isLoading else { return }

                let config = WKSnapshotConfiguration()
                webView.takeSnapshot(with: config) { nsImage, error in
                    if let image = nsImage {
                        DispatchQueue.main.async {
                            self.parent.onScreenshotTaken(image)
                        }
                    } else if let error = error {
                        NSLog("Failed to take web snapshot: \(error.localizedDescription)")
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "http" || scheme == "https" || scheme == "file" || scheme == "about" {
                decisionHandler(.allow)
            } else {
                // 拦截非网页协议，防止在 App Sandbox 下因调用 launchservicesd 引起 WebContent 进程崩溃
                decisionHandler(.cancel)

                // 针对需要唤起外部程序的常规协议，使用 NSWorkspace 主进程安全拉起
                if scheme == "mailto" || scheme == "tel" || scheme == "sms" {
                    DispatchQueue.main.async {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // 当 WebContent 进程意外崩溃终止时，捕获事件以避免无限重新载入循环
            DispatchQueue.main.async {
                let error = NSError(
                    domain: "WKErrorDomain",
                    code: WKError.webContentProcessTerminated.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("WebContent process terminated unexpectedly.", comment: "")]
                )
                self.parent.loadError = error
                self.parent.isLoading = false
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url, !url.absoluteString.isEmpty, url.absoluteString != "about:blank" {
                DispatchQueue.main.async {
                    if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                        let state = AppState()
                        state.openWeb(url: url)
                        appDelegate.showNewWindow(with: state)
                    }
                }
            }
            return nil
        }

        deinit {
            titleObservation?.invalidate()
            progressObservation?.invalidate()
            loadingObservation?.invalidate()
            if let token = reloadNotificationToken {
                NotificationCenter.default.removeObserver(token)
            }
            if let token = captureNotificationToken {
                NotificationCenter.default.removeObserver(token)
            }
            if let token = saveSnapshotNotificationToken {
                NotificationCenter.default.removeObserver(token)
            }
        }
    }
}

// 网页容器组件（负责状态提示、进度条与错误处理界面）
struct WebContainerView: View {
    let url: URL
    let zoom: Double
    let appState: AppState
    let onTitleChange: (String) -> Void
    let onScreenshotTaken: (NSImage) -> Void
    let shouldHideBorder: Bool

    @State private var isLoading = false
    @State private var progress: Double = 0.0
    @State private var loadError: Error? = nil

    var body: some View {
        ZStack {
            WebView(
                url: url,
                zoom: zoom,
                appState: appState,
                isLoading: $isLoading,
                progress: $progress,
                loadError: $loadError,
                onTitleChange: onTitleChange,
                onScreenshotTaken: onScreenshotTaken
            )
            .id(url) // 保证 URL 改变时，WebView 实例完全重建以彻底清除旧页面痕迹
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .cornerRadius(shouldHideBorder ? 0 : 8)
            .padding(shouldHideBorder ? 0 : 8)
            .opacity((isLoading && progress < 0.08) ? 0.0 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isLoading || progress < 0.08)

            // 1. 载入页面前的状态提示
            if isLoading && progress < 0.08 && loadError == nil {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(NSLocalizedString("Loading...", comment: ""))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.primary)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
                    .cornerRadius(20)
                    .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 5)
                    .padding(.bottom, 20)
                    Spacer()
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            }

            // 2. 载入失败状态提示
            if let error = loadError {
                VStack(spacing: 16) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 36, weight: .light))
                        .foregroundColor(.secondary)

                    VStack(spacing: 6) {
                        Text(NSLocalizedString("Load Failed", comment: ""))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                        Text(error.localizedDescription)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    Button(action: {
                        loadError = nil
                        isLoading = true
                        NotificationCenter.default.post(
                            name: Notification.Name("reloadWebView_\(appState.id.uuidString)"),
                            object: nil
                        )
                    }) {
                        Text(NSLocalizedString("Retry", comment: ""))
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
                .cornerRadius(shouldHideBorder ? 0 : 8)
                .padding(shouldHideBorder ? 0 : 8)
                .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            }

            // 3. 页面资源载入进度条
            if isLoading && progress < 1.0 && loadError == nil {
                VStack {
                    Spacer()
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        let adjustedWidth = shouldHideBorder ? width : max(0, width - 16)
                        let xOffset = shouldHideBorder ? 0 : CGFloat(8)

                        Path { path in
                            path.move(to: CGPoint(x: xOffset, y: 0))
                            path.addLine(to: CGPoint(x: xOffset + adjustedWidth * CGFloat(progress), y: 0))
                        }
                        .stroke(
                            LinearGradient(
                                colors: [Color.blue, Color.cyan],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            lineWidth: 3
                        )
                    }
                    .frame(height: 3)
                    .padding(.bottom, shouldHideBorder ? 0 : 8)
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }

        }
        .onChange(of: url) { newValue in
            // 当 URL 切换时，立刻重置所有加载状态，实现瞬间遮挡并清除旧网页痕迹
            isLoading = true
            progress = 0.0
            loadError = nil
        }
    }
}
