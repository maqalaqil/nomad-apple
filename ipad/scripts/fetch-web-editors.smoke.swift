// macOS WebKit smoke checks. Pass Resources/WebTools/ITTools or Resources/WebTools/Excalidraw.
// The runner writes a test drawing to its own macOS WebKit store; it does not access iPad data.
import AppKit
import WebKit
import UniformTypeIdentifiers
final class ToolLocalAssetHandler: NSObject, WKURLSchemeHandler {
    let directory: URL
    init(directory: URL) { self.directory = directory.standardizedFileURL.resolvingSymlinksInPath() }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              requestURL.host == directory.lastPathComponent.lowercased() else {
            urlSchemeTask.didFailWithError(URLError(.badURL)); return
        }
        let path = requestURL.path.isEmpty || requestURL.path == "/" ? "index.html" : String(requestURL.path.dropFirst())
        var file = directory.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(directory.path + "/") else { urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile)); return }
        if !FileManager.default.fileExists(atPath: file.path), file.pathExtension.isEmpty {
            file = directory.appendingPathComponent("index.html")
        }
        do {
            let data = try Data(contentsOf: file)
            let types = ["js": "application/javascript", "mjs": "application/javascript", "html": "text/html", "css": "text/css", "json": "application/json", "wasm": "application/wasm", "svg": "image/svg+xml", "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "webmanifest": "application/manifest+json"]
            let mime = types[file.pathExtension.lowercased()] ?? UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            guard let response = HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*", "Cache-Control": "no-cache"]) else { throw URLError(.badServerResponse) }
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch { urlSchemeTask.didFailWithError(error) }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
setbuf(stdout, nil)
final class EditorRunner: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler, WKDownloadDelegate {
 let root=URL(fileURLWithPath:CommandLine.arguments[1]); var web:WKWebView!; var attempts=0; var phase=0; var exported:URL?
 func applicationDidFinishLaunching(_ notification:Notification) {
  DispatchQueue.main.asyncAfter(deadline: .now() + 90) { print("FAIL test timeout"); exit(1) }
  let c=WKWebViewConfiguration(); c.websiteDataStore = .default()
  c.setURLSchemeHandler(ToolLocalAssetHandler(directory:root),forURLScheme:"nomad-local")
  c.userContentController.add(self,name:"log")
  c.userContentController.addUserScript(WKUserScript(source:"window.addEventListener('error',e=>window.webkit.messageHandlers.log.postMessage(String(e.message)));window.addEventListener('unhandledrejection',e=>window.webkit.messageHandlers.log.postMessage(String(e.reason)));",injectionTime:.atDocumentStart,forMainFrameOnly:false))
  web=WKWebView(frame:NSRect(x:0,y:0,width:1366,height:1024),configuration:c); web.navigationDelegate=self
  let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]"#
  WKContentRuleListStore.default().compileContentRuleList(forIdentifier:"NomadEditorSmoke",encodedContentRuleList:rules){ list,error in
   if let list { c.userContentController.add(list) }
   self.web.load(URLRequest(url:URL(string:"nomad-local://\(self.root.lastPathComponent.lowercased())/")!)); self.poll()
  }
 }
 func userContentController(_ controller:WKUserContentController,didReceive message:WKScriptMessage){print("JS ERROR",message.body)}
 func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!){print("NAV READY")}
 func poll(){
  attempts += 1
  if attempts>45 { print("FAIL timeout"); exit(1) }
  let ready = root.lastPathComponent == "ITTools" ? "document.body.innerText.includes('IT - TOOLS')" : "!!window.nomadExcalidraw"
  web.evaluateJavaScript(ready) { value,error in
   if value as? Bool == true {
    if self.root.lastPathComponent == "ITTools" { self.testIT() }
    else if self.phase==0 { self.testDrawing() } else { self.testReload() }
   } else { DispatchQueue.main.asyncAfter(deadline:.now()+0.5){self.poll()} }
  }
 }
 func testIT(){
  web.evaluateJavaScript("JSON.stringify({links:new Set([...document.querySelectorAll('a[href^=\"/\"]')].map(a=>a.getAttribute('href'))).size,secure:isSecureContext,subtle:!!crypto.subtle})") { print("IT CATALOG",$0 as Any,$1 as Any) }
  web.evaluateJavaScript("document.querySelector('a[href=\"/base64-string-converter\"]').click()") { _,error in
   if let error { print(error); exit(1) }
   DispatchQueue.main.asyncAfter(deadline:.now()+1) {
    self.web.evaluateJavaScript("(()=>{const t=document.querySelector('textarea'); t.value='NOMAD';t.dispatchEvent(new Event('input',{bubbles:true}));return true})()") { _,error in
     if let error { print(error);exit(1) }
     DispatchQueue.main.asyncAfter(deadline:.now()+1) {
      self.web.evaluateJavaScript("JSON.stringify([...document.querySelectorAll('textarea,input')].map(x=>x.value))") { value,error in
       print("IT BASE64",value as Any,error as Any)
       guard let value=value as? String, value.contains("Tk9NQUQ=") else { exit(1) }
       print("PASS IT Tools actual conversion");exit(0)
      }
     }
    }
   }
  }
 }
 func testDrawing(){
  phase=1
  let code="const n=nomadExcalidraw; const elements=n.convertToExcalidrawElements([{type:'rectangle',x:10,y:20,width:160,height:80},{type:'text',x:20,y:40,text:'NOMAD offline',fontSize:24}]); n.api.updateScene({elements}); await new Promise(r=>setTimeout(r,1500)); const saved=await n.readSaved(); return JSON.stringify({count:saved.elements?.length,status:document.querySelector('.nomad-save-status').innerText});"
  web.callAsyncJavaScript(code,arguments:[:],in:nil,in:.page){ result in
   print("DRAW SAVE",result)
   guard case .success(let value)=result, let text=value as? String,text.contains("\"count\":2"),text.contains("Saved on this iPad") else { exit(1) }
   self.web.reload();DispatchQueue.main.asyncAfter(deadline:.now()+1){self.poll()}
  }
 }
 func testReload(){
  web.evaluateJavaScript("nomadExcalidraw.api.getSceneElements().length"){value,error in
   print("DRAW RELOAD",value as Any,error as Any)
   guard value as? Int == 2 else {exit(1)}
   self.web.evaluateJavaScript("[...document.querySelectorAll('.nomad-toolbar button')].find(b=>b.textContent==='PNG').click()") {_,error in if let error {print(error);exit(1)}}
  }
 }
 func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void){decisionHandler(action.shouldPerformDownload ? .download:.allow)}
 func webView(_ webView:WKWebView,navigationAction:WKNavigationAction,didBecome download:WKDownload){download.delegate=self}
 func download(_ download:WKDownload,decideDestinationUsing response:URLResponse,suggestedFilename:String,completionHandler:@escaping(URL?)->Void){let u=FileManager.default.temporaryDirectory.appendingPathComponent("nomad-drawing-test-\(UUID().uuidString).png");exported=u;completionHandler(u)}
 func downloadDidFinish(_ download:WKDownload){
  guard let u=exported,let data=try? Data(contentsOf:u),Array(data.prefix(8)) == [137,80,78,71,13,10,26,10] else {print("FAIL PNG");exit(1)}
  print("PASS persistent drawing and PNG export",data.count);try? FileManager.default.removeItem(at:u);exit(0)
 }
 func download(_ download:WKDownload,didFailWithError error:Error,resumeData:Data?){print(error);exit(1)}

}
let app=NSApplication.shared;app.setActivationPolicy(.prohibited);let runner=EditorRunner();app.delegate=runner;app.run()
