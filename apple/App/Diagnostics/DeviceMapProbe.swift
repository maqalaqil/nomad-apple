#if DEBUG
import Foundation
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Uses the production map assets and byte-range handler with an isolated fixture.
@MainActor final class DeviceMapProbe: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private var ready = false
    private var failure: String?
    private var view: WKWebView?
    private var configured = false
    private var renderedAfterConfiguration = false
    private var cancelled = false
    private var cancelWait: (() -> Void)?
    private var deadline: TimeInterval = 0

    func run(archive: URL, screenshot: URL) async throws -> [String: Double] {
        deadline = ProcessInfo.processInfo.systemUptime + 40
        guard let assets = Bundle.main.url(forResource: "WebTools", withExtension: nil)?.appendingPathComponent("Maps"),
              FileManager.default.fileExists(atPath: assets.appendingPathComponent("index.html").path)
        else { throw PMTilesFailure.message("Map assets or the foreground test window are unavailable.") }
        #if os(macOS)
        guard let host = NSApplication.shared.keyWindow?.contentView else {
            throw PMTilesFailure.message("The foreground test window is unavailable.")
        }
        #else
        guard let host = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else {
            throw PMTilesFailure.message("The foreground test window is unavailable.")
        }
        #endif
        _ = try PMTilesHeader.read(from: archive)
        let id = UUID().uuidString.lowercased()
        let handler = PMTilesAssetHandler(assets: assets)
        handler.archives = [id + ".pmtiles": archive]
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: "nomad-map")
        configuration.userContentController.add(self, name: "nomadMap")
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]"#
        let protection = DeviceProbeDeadline<DeviceProbePayload<WKContentRuleList>>()
        let list = try await protection.wait(seconds: remaining(10)) { completion in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "NOMADDeviceMapProbe", encodedContentRuleList: rules) { result, error in
                if let result { completion(.success(DeviceProbePayload(result))) }
                else { completion(.failure(error ?? PMTilesFailure.message("Map network protection could not be enabled."))) }
            }
        }
        configuration.userContentController.add(list.value)
        let web = WKWebView(frame: host.bounds, configuration: configuration)
        web.navigationDelegate = self; view = web
        host.addSubview(web)
        #if os(macOS)
        let cancelButton = NSButton(title: "Cancel map check", target: self, action: #selector(cancelMapCheck))
        cancelButton.setAccessibilityIdentifier("Cancel local map check")
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        #else
        let cancelButton = UIButton(type: .system)
        var buttonConfiguration = UIButton.Configuration.filled()
        buttonConfiguration.title = "Cancel map check"
        buttonConfiguration.baseBackgroundColor = .darkGray
        buttonConfiguration.baseForegroundColor = .white
        cancelButton.configuration = buttonConfiguration
        cancelButton.accessibilityIdentifier = "Cancel local map check"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.addAction(UIAction { [weak self] _ in
            self?.cancelled = true; self?.cancelWait?()
        }, for: .primaryActionTriggered)
        #endif
        host.addSubview(cancelButton)
        NSLayoutConstraint.activate([
            cancelButton.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: 12),
            cancelButton.trailingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.trailingAnchor, constant: -20)
        ])
        defer {
            cancelWait = nil; cancelButton.removeFromSuperview()
            web.stopLoading(); web.removeFromSuperview(); web.navigationDelegate = nil
            configuration.userContentController.removeScriptMessageHandler(forName: "nomadMap"); view = nil
        }
        web.load(URLRequest(url: URL(string: "nomad-map://assets/index.html")!))
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if cancelled { throw CancellationError() }
            if let failure { throw PMTilesFailure.message(failure) }
            if ready, !configured {
                configured = true
                _ = try await evaluate("await window.nomadMap.configure(config)", arguments: ["config": ["archives": [["id": id, "name": "Validation fixture"]], "places": []]], web: web)
            }
            if configured, renderedAfterConfiguration, handler.archiveReads > 0 {
                let result = try await evaluate("const features = window.nomadMap.map.queryRenderedFeatures(); return {loaded: window.nomadMap.map.areTilesLoaded(), features: features.length, textSymbols: features.filter(f => f.layer.type === 'symbol' && f.layer.layout && f.layer.layout['text-field']).length, zoom: window.nomadMap.map.getZoom()}", arguments: [:], web: web) as? [String: Any]
                if result?["loaded"] as? Bool == true, let features = result?["features"] as? Int, features > 0,
                   let textSymbols = result?["textSymbols"] as? Int, textSymbols > 0 {
                    let snapshotWait = DeviceProbeDeadline<DeviceProbePayload<NomadPlatformImage>>()
                    cancelWait = { snapshotWait.cancel() }
                    let snapshot = try await snapshotWait.wait(seconds: remaining(10)) { completion in
                        web.takeSnapshot(with: nil) { image, error in
                            if let image { completion(.success(DeviceProbePayload(image))) }
                            else { completion(.failure(error ?? PMTilesFailure.message("Map snapshot failed."))) }
                        }
                    }
                    cancelWait = nil
                    try Task.checkCancellation()
                    if cancelled { throw CancellationError() }
                    guard let data = NomadImageEncoding.pngData(snapshot.value) else { throw PMTilesFailure.message("Map snapshot could not be encoded.") }
                    try data.write(to: screenshot, options: .atomic)
                    return ["renderedFeatures": Double(features), "renderedTextSymbols": Double(textSymbols), "archiveRangeReads": Double(handler.archiveReads),
                            "bundledAssetReads": Double(handler.assetReads), "zoom": result?["zoom"] as? Double ?? 0,
                            "screenshotBytes": Double(data.count)]
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PMTilesFailure.message("The local map fixture did not finish rendering geometry and text labels within 40 seconds.")
    }

    #if os(macOS)
    @objc private func cancelMapCheck() { cancelled = true; cancelWait?() }
    #endif

    private func evaluate(_ script: String, arguments: [String: Any], web: WKWebView) async throws -> Any {
        let gate = DeviceProbeDeadline<DeviceProbePayload<Any>>()
        cancelWait = { gate.cancel() }
        defer { cancelWait = nil }
        return try await gate.wait(seconds: remaining(12)) { completion in
            web.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
                completion(result.map { DeviceProbePayload($0) })
            }
        }.value
    }

    private func remaining(_ maximum: TimeInterval) -> TimeInterval {
        min(maximum, deadline - ProcessInfo.processInfo.systemUptime)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "ready" { ready = true }
        if type == "rendered", configured, (body["features"] as? Int ?? 0) > 0 { renderedAfterConfiguration = true }
        if type == "error" { failure = body["message"] as? String ?? "Map rendering failed." }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.scheme == "nomad-map" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure = error.localizedDescription }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failure = "The map content process terminated." }
}
#endif
