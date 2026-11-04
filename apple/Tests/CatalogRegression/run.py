"""Compile the production catalog parser/accounting against disposable catalog copies.

The filesystem probe is injected as true/false to cover both capacity branches;
actual hardlink behavior is covered separately by NomadCore's storage tests.
No network, downloads, or user stores are used.
"""
from pathlib import Path
import tempfile, shutil, plistlib, subprocess
repo=Path(__file__).resolve().parents[3]
source=(repo/'apple/App/Downloads/CatalogDownloadsView.swift').read_text()
code='import Foundation\nimport CoreFoundation\n'+source[source.index('struct CatalogResource:'):source.index('    @MainActor private static func preflight')]+ '\n}\n'+source[source.index('enum CatalogError:'):]
assert code.count('@MainActor private static func importCopyBytes') == 1
# Change only visibility in the extracted production code so the decision can be exercised.
code=code.replace('@MainActor private static func importCopyBytes', '@MainActor static func importCopyBytes')
with tempfile.TemporaryDirectory(prefix='nomad-catalog-review-') as t:
 p=Path(t); bundle=p/'CatalogTest.bundle'; resources=bundle/'Contents/Resources'; resources.mkdir(parents=True)
 (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'org.nomad.test.catalog','CFBundlePackageType':'BNDL'}))
 shutil.copytree(repo/'apple/Resources/Catalogs',resources/'Catalogs')
 (p/'Parser.swift').write_text(code)
 (p/'Tests.swift').write_text(r'''
import Foundation
@MainActor final class DownloadStore {
 let root: URL
 init(root: URL) { self.root=root }
}
@MainActor enum InternalDownloadLink {
 static var supported = true
 static func probe(in folder: URL) throws -> Bool { supported }
}
@main enum Tests {
 static var count=0
 static func check(_ test: Bool, _ message: String) throws { guard test else { throw CatalogError.message(message) }; count += 1 }
 static func rejects(_ operation: () throws -> Void) throws { do { try operation() } catch { count += 1; return }; throw CatalogError.message("Expected invalid catalog to fail") }
 @MainActor static func main() throws {
  let bundle=Bundle(path:CommandLine.arguments[1])!
  let catalog=bundle.resourceURL!.appendingPathComponent("Catalogs/models.json")
  let original=try Data(contentsOf:catalog)
  let sections=try OfflineContentCatalog.sections(bundle:bundle)
  let all=sections.flatMap(\.resources)
  try check(all.count > 50,"Original catalogs must all parse")
  let full=all.filter { ["wikipedia-ar-all-maxi","wikipedia-en-all-maxi","world-maps-world-streets-v4"].contains($0.id) }
  try check(full.count == 3 && full.reduce(Int64(0)) { $0+$1.bytes } == 281326218886,"Verified full collection exact byte total")
  try check(full.filter { $0.sha256 != nil }.count == 2,"Preserve two published SHA-256 requirements without inventing a world-map hash")
  let expected = try OfflineContentCatalog.requiredBytes(newFiles: full.map(\.bytes),pendingBytes:[],importCopy:134812420554)
  try check(expected == 416675510352,"Account for one largest import copy plus512MiB")
  let store = DownloadStore(root: bundle.bundleURL)
  InternalDownloadLink.supported = true
  let shared = try OfflineContentCatalog.importCopyBytes(full, store: store)
  try check(shared == 0,"Supported linking omits the full ZIM/PMTiles duplicate")
  try check(try OfflineContentCatalog.requiredBytes(newFiles:full.map(\.bytes),pendingBytes:[],importCopy:shared) == 281863089798,"Shared full collection still reserves512MiB")
  InternalDownloadLink.supported = false
  let copied = try OfflineContentCatalog.importCopyBytes(full, store: store)
  try check(copied == 134812420554,"Unsupported linking includes the largest archive copy")
  InternalDownloadLink.supported = true
  let models = all.filter { $0.id.hasPrefix("models-") }
  try check(try OfflineContentCatalog.importCopyBytes(full + models, store:store) == models.map(\.bytes).max(),"Models retain a copy budget even when reader archives can link")
  try check(try OfflineContentCatalog.requiredBytes(newFiles:[100],pendingBytes:[20,30],importCopy:10) == 536871072,"Existing queued bytes remain included")
  try rejects { _ = try OfflineContentCatalog.requiredBytes(newFiles:[Int64.max],pendingBytes:[],importCopy:1) }
  try rejects { _ = try OfflineContentCatalog.requiredBytes(newFiles:[-1],pendingBytes:[],importCopy:0) }
  let changes: [[String:Any]] = [["size_bytes":true],["size_bytes":1.5],["size_bytes":"491400032"],["size_bytes":0],["size_bytes":-1],["sha256":42],["sha256":"not-a-hash"],["size_mb":true],["size_mb":-1],["url":"https://user:secret@example.invalid/file"],["url":"https://example.invalid/file#fragment"],["url":"http://example.invalid/file"]]
  for change in changes {
   var json=try JSONSerialization.jsonObject(with:original) as! [String:Any]
   var rows=json["options"] as! [[String:Any]]; rows[0].merge(change) { _,new in new }; json["options"]=rows
   try JSONSerialization.data(withJSONObject:json).write(to:catalog)
   try rejects { _ = try OfflineContentCatalog.sections(bundle:bundle) }
  }
  var json=try JSONSerialization.jsonObject(with:original) as! [String:Any]
  let rows=json["options"] as! [[String:Any]]; json["options"]=rows+rows
  try JSONSerialization.data(withJSONObject:json).write(to:catalog)
  try rejects { _ = try OfflineContentCatalog.sections(bundle:bundle) }
  try original.write(to:catalog)
  print("PASS: \(count) catalog parser/capacity checks; actual bundled catalogs plus temporary malformed copies only.")
 }
}
''')
 subprocess.run(['xcrun','swiftc','-swift-version','5','-module-cache-path',str(p/'ModuleCache'),str(p/'Parser.swift'),str(p/'Tests.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),str(bundle)],check=True)
