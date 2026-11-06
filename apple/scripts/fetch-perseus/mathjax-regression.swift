import AppKit
import WebKit

@main struct MathJaxRegression {
    static func main() {
        setbuf(stdout, nil)
        let app=NSApplication.shared, runner=Runner()
        app.delegate=runner; app.run(); withExtendedLifetime(runner) {}
    }
}
final class Runner:NSObject,NSApplicationDelegate,WKURLSchemeHandler,WKScriptMessageHandler {
    let root=URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL
    var window:NSWindow!
    var web:WKWebView!
    var seen=Set<String>()
    func applicationDidFinishLaunching(_ notification:Notification) {
        DispatchQueue.main.asyncAfter(deadline:.now()+45) { print("FAIL math adapter timeout",self.seen.sorted()); exit(1) }
        let configuration=WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(self,forURLScheme:"nomad-perseus")
        configuration.userContentController.add(self,name:"mathTest")
        web=WKWebView(frame:NSRect(x:0,y:0,width:800,height:700),configuration:configuration)
        window=NSWindow(contentRect:web.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView=web; window.orderFront(nil)
        let rules=#"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier:"nomad-mathjax-regression",encodedContentRuleList:rules) { list,error in
            guard let list else { print("FAIL blocker",error as Any); exit(1) }
            configuration.userContentController.add(list)
            self.web.load(URLRequest(url:URL(string:"nomad-perseus://local/renderer/index.html")!))
        }
    }
    func webView(_ webView:WKWebView,start task:WKURLSchemeTask) {
        guard let url=task.request.url,url.host=="local",url.path.hasPrefix("/renderer/") else { task.didFailWithError(URLError(.badURL)); return }
        let relative=String(url.path.dropFirst("/renderer/".count))
        let file=root.appendingPathComponent(relative).standardizedFileURL
        guard file.path.hasPrefix(root.path+"/") else { task.didFailWithError(URLError(.badURL)); return }
        do {
            let data=try Data(contentsOf:file)
            let mime=["html":"text/html","js":"text/javascript","css":"text/css","json":"application/json","woff":"font/woff"][file.pathExtension] ?? "application/octet-stream"
            seen.insert(relative)
            task.didReceive(HTTPURLResponse(url:url,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":mime,"Access-Control-Allow-Origin":"nomad-perseus://local"])!)
            task.didReceive(data); task.didFinish()
        } catch { print("FAIL missing local resource",relative); task.didFailWithError(error) }
    }
    func webView(_ webView:WKWebView,stop task:WKURLSchemeTask) {}
    func userContentController(_ controller:WKUserContentController,didReceive message:WKScriptMessage) {
        guard let result=message.body as? [String:Any] else { print("FAIL invalid result"); exit(1) }
        if let progress=result["progress"] as? String { print("CHECK",progress); return }
        guard result["error"]==nil,let count=result["passed"] as? Int,count>=20,
              seen.contains("mathjax/fonts/MathJax_Main-Regular.woff"),seen.contains("speech/en.json") else {
            print("FAIL",result,"resources",seen.sorted()); exit(1)
        }
        print("PASS \(count) MathJax adapter checks + local fonts/speech",result["checks"] as Any)
        exit(0)
    }
}
