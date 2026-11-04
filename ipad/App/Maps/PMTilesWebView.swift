import SwiftUI
import WebKit

@MainActor final class PMTilesMapController: ObservableObject {
    @Published var status = "Opening offline map…"
    @Published var error: String?
    @Published var selectedLatitude: Double?
    @Published var selectedLongitude: Double?
    weak var webView: WKWebView?

    func fly(latitude: Double, longitude: Double) {
        webView?.callAsyncJavaScript("window.nomadMap.fly(latitude, longitude)", arguments: ["latitude": latitude, "longitude": longitude], in: nil, in: .page, completionHandler: nil)
    }
}

struct PMTilesWebView: UIViewRepresentable {
    let assets: URL
    @ObservedObject var store: PMTilesStore
    @ObservedObject var controller: PMTilesMapController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(context.coordinator.handler, forURLScheme: "nomad-map")
        configuration.userContentController.add(context.coordinator, name: "nomadMap")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isInspectable = true
        controller.webView = view
        context.coordinator.view = view
        context.coordinator.update(self)
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "NOMADOfflineMaps", encodedContentRuleList: rules) { list, error in
            DispatchQueue.main.async {
                guard let list else { controller.error = error?.localizedDescription ?? "Could not activate offline map protection."; return }
                view.configuration.userContentController.add(list)
                view.load(URLRequest(url: URL(string: "nomad-map://assets/index.html")!))
            }
        }
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) { context.coordinator.update(self) }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: PMTilesWebView
        let handler: PMTilesAssetHandler
        weak var view: WKWebView?
        var ready = false
        var previous: Data?

        init(_ parent: PMTilesWebView) { self.parent = parent; handler = PMTilesAssetHandler(assets: parent.assets) }

        func update(_ parent: PMTilesWebView) {
            self.parent = parent
            handler.archives = Dictionary(uniqueKeysWithValues: parent.store.archives.map { ($0.filename, parent.store.fileURL(for: $0)) })
            guard ready else { return }
            struct Configuration: Encodable { let archives: [PMTilesArchive]; let places: [PMTilesSavedPlace] }
            guard let data = try? JSONEncoder().encode(Configuration(archives: parent.store.archives.filter(\.enabled), places: parent.store.places)), data != previous,
                  let object = try? JSONSerialization.jsonObject(with: data) else { return }
            previous = data
            view?.callAsyncJavaScript("await window.nomadMap.configure(configuration)", arguments: ["configuration": object], in: nil, in: .page) { result in
                if case .failure(let error) = result { parent.controller.error = error.localizedDescription }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready": ready = true; update(parent)
            case "status": parent.controller.status = body["message"] as? String ?? "Offline map"
            case "error": parent.controller.error = body["message"] as? String ?? "Map rendering failed."
            case "coordinate":
                parent.controller.selectedLatitude = body["latitude"] as? Double
                parent.controller.selectedLongitude = body["longitude"] as? Double
            default: break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.scheme == "nomad-map" ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { parent.controller.error = error.localizedDescription }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { ready = false; previous = nil; webView.reload() }
    }
}
