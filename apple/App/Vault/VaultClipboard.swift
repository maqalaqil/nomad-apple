import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor enum VaultClipboard {
    #if os(macOS)
    private static var expiration: Task<Void, Never>?
    static let explanation = "On Mac, other apps and Universal Clipboard may read copied passwords. This app clears its unchanged copy after 45 seconds while it remains running."
    static func copy(_ secret: String, to board: NSPasteboard = .general, expiresAfter: Duration = .seconds(45)) {
        expiration?.cancel()
        board.clearContents()
        board.setString(secret, forType: .string)
        let revision = board.changeCount
        expiration = Task { @MainActor in
            do { try await Task.sleep(for: expiresAfter); try Task.checkCancellation() } catch { return }
            // Never clear something the user copied subsequently in this or another app.
            if board.changeCount == revision { board.clearContents() }
            expiration = nil
        }
    }
    #else
    static let explanation = "Copied passwords stay on this device and expire from the clipboard after 45 seconds."
    static func copy(_ secret: String) {
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: secret]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(45)])
    }
    #endif
}
