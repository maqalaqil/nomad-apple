// Compile with Sources/NomadCore/InternalDownloadLink.swift,
// App/Collections/LocalManifestFile.swift,
// App/Maps/PMTilesArchive.swift and PMTilesAssetHandler.swift.
// Arguments: bundle Maps directory, a local Protomaps schema PMTiles v3 fixture.
import AppKit
import WebKit

@main struct PMTilesSmoke {
    static func main() throws {
        setbuf(stdout, nil)
        let archive = URL(fileURLWithPath: CommandLine.arguments[2])
        let result = try PMTilesHeader.read(from: archive)
        precondition(result.header.tileType == 1 && result.bytes > 127)
        let head = try PMTilesByteRange.parse("bytes=0-126", fileSize: result.bytes); precondition(head.count == 127)
        let tail = try PMTilesByteRange.parse("bytes=-10", fileSize: result.bytes); precondition(tail.count == 10)
        for invalid in [nil, "bytes=1-0", "bytes=0-1,2-3", "bytes=999999999999-", "bytes=-0"] {
            do { _ = try PMTilesByteRange.parse(invalid, fileSize: result.bytes); fatalError("Accepted bad range") } catch {}
        }
        print("PASS header and range validation")
        let app = NSApplication.shared
        let runner = MapRunner()
        app.delegate = runner
        app.run()
        withExtendedLifetime(runner) {}
    }
}

final class MapRunner: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    var web: WKWebView!
    var window: NSWindow!
    var handler: PMTilesAssetHandler!
    var checked = false
    let identifier = "11111111-1111-1111-1111-111111111111"

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 55) { print("FAIL map timeout"); exit(1) }
        handler = PMTilesAssetHandler(assets: URL(fileURLWithPath: CommandLine.arguments[1]))
        handler.archives[identifier + ".pmtiles"] = URL(fileURLWithPath: CommandLine.arguments[2])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: "nomad-map")
        configuration.userContentController.add(self, name: "nomadMap")
        configuration.userContentController.addUserScript(WKUserScript(source: "window.addEventListener('error',e=>window.webkit.messageHandlers.nomadMap.postMessage({type:'error',message:e.message}));window.addEventListener('unhandledrejection',e=>window.webkit.messageHandlers.nomadMap.postMessage({type:'error',message:String(e.reason)}));", injectionTime: .atDocumentStart, forMainFrameOnly: false))
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800), configuration: configuration)
        window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web; window.orderFront(nil)
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "NomadMapsSmoke", encodedContentRuleList: rules) { list, error in
            guard let list else { print("FAIL offline policy", error as Any); exit(1) }
            configuration.userContentController.add(list)
            self.web.load(URLRequest(url: URL(string: "nomad-map://assets/index.html")!))
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        print("MAP", body)
        if type == "error" { exit(1) }
        if type == "ready" {
            let header = try! PMTilesHeader.read(from: URL(fileURLWithPath: CommandLine.arguments[2])).header
            let config: [String: Any] = ["archives": [["id": identifier, "name": "NOMAD test fixture"]], "places": [["name": "Offline test", "notes": "saved pin", "latitude": header.centerLatitude, "longitude": header.centerLongitude, "color": "#cf632c"]]]
            web.callAsyncJavaScript("await nomadMap.configure(configuration); return true", arguments: ["configuration": config], in: nil, in: .page) { result in
                if case .failure(let error) = result { print("FAIL configure", error); exit(1) }
            }
        }
        if type == "rendered", (body["features"] as? Int ?? 0) > 100, !checked {
            checked = true
            web.callAsyncJavaScript("let blocked=false;try{await fetch('https://example.com/offline-map-probe')}catch(e){blocked=true}return JSON.stringify({blocked,features:nomadMap.map.queryRenderedFeatures().length,pins:document.querySelectorAll('.maplibregl-marker').length})", arguments: [:], in: nil, in: .page) { result in
                print("MAP CHECK", result, "range reads", self.handler.archiveReads, "asset reads", self.handler.assetReads)
                guard case .success(let value) = result, let text = value as? String, text.contains("\"blocked\":true"), text.contains("\"pins\":1"), self.handler.archiveReads > 2 else { exit(1) }
                self.web.takeSnapshot(with: nil) { image, error in
                    guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { print("FAIL snapshot", error as Any); exit(1) }
                    try? png.write(to: URL(fileURLWithPath: "/tmp/nomad-map-smoke.png"))
                    print("PASS local vector rendering, byte ranges, fonts/sprites, pin and blocked remote fetch"); exit(0)
                }
            }
        }
    }
}
