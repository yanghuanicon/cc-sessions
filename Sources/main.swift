import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 无边框浮动面板；默认的无边框窗口不能成为 key window，搜索框就没法输入，所以要重写。
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = SessionStore()
    private var statusItem: NSStatusItem!
    private var panel: KeyPanel!
    private var hotKey: EventHotKeyRef?
    /// 点菜单栏图标时，面板会先因失去焦点而收起，紧接着按钮动作又会把它打开；用时间戳挡掉这次误开。
    private var lastHiddenAt = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 记住位置：用户按住 ⌘ 拖到靠右处后，重启也保持，不容易被菜单多的应用挤掉。
        statusItem.autosaveName = "cc-sessions"
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Claude 会话")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.action = #selector(togglePanel)
            button.target = self
        }
        setupPanel()
        store.onBadgeChange = { [weak self] count in self?.updateBadge(count) }
        store.closePanel = { [weak self] in self?.hidePanel() }
        store.start()
        registerHotKey()
    }

    private func setupPanel() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 560),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 11
        effect.layer?.masksToBounds = true
        let hosting = NSHostingView(rootView: PanelView(store: store))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
    }

    @objc func togglePanel() {
        if panel.isVisible { hidePanel() } else if Date().timeIntervalSince(lastHiddenAt) > 0.3 { showPanel() }
    }

    private func showPanel() {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        var origin: NSPoint
        if let button = statusItem.button, let window = button.window,
           window.occlusionState.contains(.visible),
           let buttonScreen = window.screen, buttonScreen.visibleFrame.intersects(window.frame) {
            // 图标可见：面板挂在图标正下方，右边不超出屏幕。
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            let visible = buttonScreen.visibleFrame
            origin = NSPoint(x: min(anchor.midX - size.width / 2, visible.maxX - size.width - 6),
                             y: anchor.minY - size.height - 4)
            origin.x = max(origin.x, visible.minX + 6)
        } else {
            // 图标被菜单栏挤掉了：面板从屏幕顶部正中弹出。
            let visible = screen.visibleFrame
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 6)
        }
        panel.setFrameOrigin(origin)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        store.panelOpen = true
        store.focusToken += 1
    }

    private func hidePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        lastHiddenAt = Date()
        statusItem.button?.highlight(false)
        store.panelOpen = false
    }

    /// 点到别的应用或桌面就收起。截图（⌘⇧4 / ⌘⇧5）也会抢走焦点，但前台应用不变，这时不收，面板才截得进去。
    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() else { return }
            self?.hidePanel()
        }
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
