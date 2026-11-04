import Foundation
import CoreFoundation
import WebKit

/// Native macOS WKWebView has no public UIScrollView. Observe position in an
/// isolated content world; book scripts stay disabled and no network is used.
enum EPUBDesktopPosition {
    static let handlerName = "nomadEPUBPosition"
    static let world = WKContentWorld.world(name: "org.projectnomad.epub-position")
    static let snapshotScript = """
    const element = document.scrollingElement || document.documentElement;
    const maximum = Math.max(1, element.scrollHeight - window.innerHeight);
    return {url: location.href, fraction: Math.min(1, Math.max(0, element.scrollTop / maximum))};
    """
    static let restoreScript = """
    const element = document.scrollingElement || document.documentElement;
    const maximum = Math.max(0, element.scrollHeight - window.innerHeight);
    if (fraction > 0) window.scrollTo(0, maximum * Math.min(1, fraction));
    return Math.min(1, Math.max(0, element.scrollTop / Math.max(1, maximum)));
    """
    static let script = """
    (() => {
      let timer;
      const send = () => {
        const element = document.scrollingElement || document.documentElement;
        const maximum = Math.max(1, element.scrollHeight - window.innerHeight);
        window.webkit.messageHandlers.nomadEPUBPosition.postMessage({url: location.href,
          fraction: Math.min(1, Math.max(0, element.scrollTop / maximum))});
      };
      window.addEventListener('scroll', () => { clearTimeout(timer); timer = setTimeout(send, 100); }, {passive: true});
      window.addEventListener('resize', send, {passive: true});
    })();
    """
    static func fraction(_ value: Any?, expectedURL: URL) -> Double? {
        guard let object = value as? [String: Any], let address = object["url"] as? String,
              let url = URL(string: address), url == expectedURL,
              url.scheme == "nomadepub", url.host == "book",
              let number = object["fraction"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              (0...1).contains(number.doubleValue) else { return nil }
        return number.doubleValue
    }
}
