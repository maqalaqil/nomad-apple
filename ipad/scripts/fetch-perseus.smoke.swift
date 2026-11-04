// macOS WebKit bundle smoke test. Uses synthetic local assessment fixtures.
import AppKit
import WebKit
import UniformTypeIdentifiers

@main struct PerseusSmoke {
    static func main() { setbuf(stdout, nil); let app = NSApplication.shared; let runner = PerseusRunner(); app.delegate = runner; app.run(); withExtendedLifetime(runner) {} }
}
final class PerseusRunner: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKURLSchemeHandler {
    var web: WKWebView!
    var window: NSWindow!
    var phase = 0
    var expectsError = false
    var errors = [String]()
    var seen = Set<String>()
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let fixtures = URL(fileURLWithPath: CommandLine.arguments[2])
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 55) { print("FAIL timeout"); exit(1) }
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(self, forURLScheme: "nomad-perseus")
        configuration.userContentController.add(self, name: "perseus")
        configuration.userContentController.addUserScript(WKUserScript(source: "window.addEventListener('error',e=>window.webkit.messageHandlers.perseus.postMessage({type:'error',message:e.message+' '+e.error?.stack}));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 850), configuration: configuration)
        window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false); window.contentView = web; window.orderFront(nil)
        let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "nomad-perseus-smoke", encodedContentRuleList: rules) { list, error in
            guard let list else { print("FAIL blocker", error as Any); exit(1) }; configuration.userContentController.add(list)
            self.web.load(URLRequest(url: URL(string: "nomad-perseus://local/renderer/index.html")!))
        }
    }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let url = task.request.url!, components = url.path.split(separator: "/").map(String.init)
        guard components.count >= 2, url.host == "local", ["renderer", "package"].contains(components[0]) else { task.didFailWithError(URLError(.badURL)); return }
        let directory = components[0] == "renderer" ? root : fixtures
        let relative = components.dropFirst().joined(separator: "/")
        let file = directory.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(directory.path + "/") else { task.didFailWithError(URLError(.badURL)); return }
        do {
            let data = try Data(contentsOf: file)
            let mime = ["js":"text/javascript", "css":"text/css", "html":"text/html", "json":"application/json", "svg":"image/svg+xml", "woff":"font/woff", "woff2":"font/woff2"][file.pathExtension] ?? "application/octet-stream"
            seen.insert(relative)
            task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":mime, "Access-Control-Allow-Origin":"*"])!); task.didReceive(data); task.didFinish()
        } catch { print("MISSING", relative); task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "error" {
            if expectsError { errors.append(body["message"] as? String ?? "Unknown"); return }
            print("FAIL JS", body); exit(1)
        }
        if type == "ready" { print("READY"); testSorter() }
        if type == "result" { print("SCORE", body["score"] as Any) }
    }
    func evaluate(_ code: String, args: [String: Any] = [:], done: @escaping (Any) -> Void) {
        web.callAsyncJavaScript(code, arguments: args, in: nil, in: .page) { result in
            switch result { case .success(let value): done(value); case .failure(let error): print("FAIL JS evaluate", error); exit(1) }
        }
    }
    func testSorter() {
        let item = try! JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("sorter.json")))
        let configuration: [String: Any] = ["item": item, "itemId":"sorter", "locale":"en", "assetBaseURL":"nomad-perseus://local/package/", "answerState":["userInput":["sorter 1":["options":["1","2","3","4","5"], "changed":true]]]]
        evaluate("await NomadPerseus.loadItem(configuration);const correct=NomadPerseus.checkAnswer().score.earned;const saved=NomadPerseus.getState();configuration.answerState={userInput:{'sorter 1':{options:['5','4','3','2','1'],changed:true}}};await NomadPerseus.loadItem(configuration);const wrong=NomadPerseus.checkAnswer().score.earned;configuration.answerState=saved;await NomadPerseus.loadItem(configuration);return JSON.stringify({correct,wrong,restored:NomadPerseus.checkAnswer().score.earned})", args: ["configuration":configuration]) { value in
            print("SORTER", value)
            guard let string = value as? String, string.contains("\"correct\":1"), string.contains("\"wrong\":0"), string.contains("\"restored\":1") else { exit(1) }
            self.testNumeric()
        }
    }
    func testNumeric() {
        let item = try! JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("numeric.json")))
        let configuration: [String: Any] = ["item": item, "itemId":"numeric", "locale":"en", "assetBaseURL":"nomad-perseus://local/package/", "answerState":["userInput":["numeric-input 1":["currentValue":"42"]]]]
        evaluate("""
            await NomadPerseus.loadItem(configuration);NomadPerseus.showHint();
            await new Promise(r=>setTimeout(r,1000));
            document.querySelector('.keypad-input').click();
            await new Promise(r=>setTimeout(r,350));
            const button=label=>[...document.querySelectorAll('button')].find(b=>b.getAttribute('aria-label')===label);
            // Upstream dismiss logic checks event coordinates against keypad bounds.
            // HTMLElement.click() uses (0,0), so send clicks at actual key centers.
            const press=label=>{const element=button(label),r=element.getBoundingClientRect();element.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,clientX:r.left+r.width/2,clientY:r.top+r.height/2}))};
            press('Right arrow');press('Right arrow');
            await new Promise(r=>setTimeout(r,100));
            press('Delete');await new Promise(r=>setTimeout(r,150));
            const afterDelete=NomadPerseus.checkAnswer().score.earned;
            press('2');await new Promise(r=>setTimeout(r,150));
            let blocked=false;try{await fetch('https://example.com/perseus-test')}catch(e){blocked=true}
            return JSON.stringify({result:NomadPerseus.checkAnswer(),afterDelete,blocked,
              math:document.querySelectorAll('mjx-container').length,
              keypadGrid:Math.abs(button('1').getBoundingClientRect().top-button('2').getBoundingClientRect().top)<2 && button('2').getBoundingClientRect().left>button('1').getBoundingClientRect().left,
              graphWidth:document.querySelector('img[src$="graph.svg"]').getBoundingClientRect().width});
            """, args:["configuration":configuration]) { value in
            print("NUMERIC",value,"LOCAL ASSETS",self.seen.sorted())
            guard let string = value as? String, string.contains("\"earned\":1"), string.contains("\"afterDelete\":0"), string.contains("\"blocked\":true"), string.contains("\"hintsVisible\":1"), string.contains("\"keypadGrid\":true"), string.contains("\"graphWidth\":240"), self.seen.contains("graph.svg"), self.seen.contains("graph-data.json"), self.seen.contains("mathjax/fonts/MathJax_Main-Regular.woff") else { exit(1) }
            self.web.takeSnapshot(with: nil) { image,error in
                if let tiff=image?.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) { try? png.write(to:URL(fileURLWithPath:"/tmp/nomad-perseus-smoke.png")) }
                self.testUnsupported()
            }
        }
    }
    func testUnsupported() {
        expectsError = true
        let item = try! JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("sorter.json")))
        evaluate("""
            item.question.widgets['sorter 1'].type='iframe';
            let rejected=false;try{await NomadPerseus.loadItem({item,itemId:'unsupported',assetBaseURL:'nomad-perseus://local/package/'})}catch(e){rejected=true}
            let gradeRejected=false;try{NomadPerseus.checkAnswer()}catch(e){gradeRejected=true}
            return JSON.stringify({rejected,gradeRejected,stateCleared:NomadPerseus.getState()===null});
            """,args:["item":item]) { value in
            print("UNSUPPORTED",value)
            guard let string=value as? String,string.contains("\"rejected\":true"),string.contains("\"gradeRejected\":true"),string.contains("\"stateCleared\":true"),!self.errors.isEmpty else { exit(1) }
            print("PASS official correct/wrong/restored scoring, keypad edits, hints, local math/Graphie, blocked network and rejected unsupported item")
            exit(0)
        }
    }
}
