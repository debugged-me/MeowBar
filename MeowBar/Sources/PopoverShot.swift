import Cocoa
import SwiftUI

// `MEOWBAR_POPOVER_SHOT=1 MeowBar` — floats the real popover just under the
// menu bar, mid-screen, so `screencapture` can shoot it for docs/screenshots.
// Pair with MEOWBAR_DEMO=normal|alerts for canned data, or none for live data.
// The app keeps running normally underneath; kill it when done shooting.
enum PopoverShot {
    static func show() {
        let store = UsageStore()
        store.popoverShown = true
        store.start()

        // Invisible 2px anchor just below the menu bar, horizontally centered.
        let popover = NSPopover()
        popover.behavior = .semitransient
        let host = NSHostingController(rootView: PopoverView(store: store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        guard let screen = NSScreen.main else { return }
        let anchor = NSPanel(contentRect: NSRect(x: screen.frame.midX - 60,
                                                 y: screen.frame.maxY - 40,
                                                 width: 120, height: 2),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        anchor.isOpaque = false
        anchor.backgroundColor = .clear
        anchor.hasShadow = false
        anchor.level = .statusBar
        anchor.collectionBehavior = [.canJoinAllSpaces, .stationary]
        anchor.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let v = anchor.contentView else { return }
            popover.show(relativeTo: v.bounds, of: v, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }

        // MEOWBAR_EXPAND=1 expands the nth provider (history + sparkline).
        if let which = ProcessInfo.processInfo.environment["MEOWBAR_EXPAND"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                NotificationCenter.default.post(name: .init("meowbar.toggleProvider"), object: which)
            }
        }
    }
}
