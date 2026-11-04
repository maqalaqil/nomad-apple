import SwiftUI
#if os(macOS)
import AppKit
typealias PlatformViewRepresentable = NSViewRepresentable
typealias NomadPlatformImage = NSImage
#else
import UIKit
typealias PlatformViewRepresentable = UIViewRepresentable
typealias NomadPlatformImage = UIImage
#endif

@MainActor enum NomadClipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

@MainActor enum NomadDeviceDescription {
    static var model: String {
        #if os(macOS)
        "Mac"
        #else
        UIDevice.current.model
        #endif
    }
}

@MainActor enum NomadImageEncoding {
    static func pngData(_ image: NomadPlatformImage) -> Data? {
        #if os(macOS)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
        #else
        return image.pngData()
        #endif
    }
}

// Hardware keyboards and Mac window titles have no software-keyboard/navigation-bar
// configuration. Keep shared forms readable without introducing UIKit on macOS.
#if os(macOS)
enum NomadNavigationBarDisplayMode { case automatic, inline, large }
enum NomadKeyboardType { case `default`, URL, numberPad, decimalPad, numbersAndPunctuation, emailAddress }
enum NomadTextAutocapitalization { case never, words, sentences, characters }
extension View {
    func navigationBarTitleDisplayMode(_ mode: NomadNavigationBarDisplayMode) -> some View { self }
    func keyboardType(_ type: NomadKeyboardType) -> some View { self }
    func textInputAutocapitalization(_ mode: NomadTextAutocapitalization?) -> some View { self }
}
#endif
