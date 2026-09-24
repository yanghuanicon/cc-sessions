import AppKit
import Carbon.HIToolbox
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = SessionStore()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var hotKey: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Claude 会话")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.action = #selector(togglePanel)
            button.target = self
        }
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PanelView(store: store))

        store.onBadgeChange = { [weak self] count in self?.updateBadge(count) }
        store.closePanel = { [weak self] in self?.popover.performClose(nil) }
        store.start()
        registerHotKey()
    }

    @objc func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        store.panelOpen = true
        store.focusToken += 1
    }

    func popoverDidClose(_ notification: Notification) {
        store.panelOpen = false
    }

    /// 菜单栏上只在有会话等你处理时显示橙色数字。
    private func updateBadge(_ count: Int) {
        guard let button = statusItem.button else { return }
        if count > 0 {
            button.attributedTitle = NSAttributedString(string: " \(count)", attributes: [
                .foregroundColor: NSColor.systemOrange,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            ])
        } else {
            button.title = ""
        }
    }

    /// 全局快捷键 ⌥⌘K；用 Carbon 的热键接口，不需要辅助功能权限。
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.togglePanel() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x43435345), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }
}

if CommandLine.arguments.contains("--dump") {
    SessionStore().dump()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
