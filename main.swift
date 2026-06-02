import Cocoa
import SwiftUI
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?
    private let core = LookoutCore()
    private let sparkleUserDriverDelegate = LookoutUserDriverDelegate()
    private lazy var sparkleUpdater = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: sparkleUserDriverDelegate
    )
    private var isPulsing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        setupStatusItem()
        setupPopover()

        core.onStateChange = { [weak self] in
            self?.refreshIcon()
        }
        core.start()
        refreshIcon()

        if LookoutKeychain.loadToken() == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showSetup()
            }
        }

        // Redraw the status icon when the display configuration changes — the
        // menu bar's effective thickness can shrink (e.g. moving from a notched
        // display to an external one) and leave the pre-rendered pill cropped.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshIcon()
        }

        _ = sparkleUpdater  // forces lazy init so Sparkle starts at launch
    }

    func applicationWillTerminate(_ notification: Notification) {
        core.stop()
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
    }

    // LSUIElement apps get no default main menu, which means Cmd+X/C/V/A
    // don't reach the first responder in any window we open. Install a
    // hidden Edit menu so SecureField paste works in the setup sheet.
    private func installEditMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Lookout",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo",       action: Selector(("undo:")),       keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo",       action: Selector(("redo:")),       keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut",        action: #selector(NSText.cut(_:)),         keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy",       action: #selector(NSText.copy(_:)),        keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste",      action: #selector(NSText.paste(_:)),       keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)),   keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    // MARK: Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "LookoutStatus"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func refreshIcon() {
        guard let button = statusItem.button else { return }

        let symbol: String
        let tint: NSColor?
        let shouldPulse: Bool
        switch core.state {
        case .unconfigured:
            symbol = "binoculars"
            tint = nil
            shouldPulse = false
        case .error:
            symbol = "binoculars.fill"
            tint = .systemOrange
            shouldPulse = false
        default:
            if core.unreadCount > 0 {
                symbol = "binoculars.fill"
                tint = .systemRed
                shouldPulse = true
            } else {
                symbol = "binoculars"
                tint = nil
                shouldPulse = false
            }
        }

        button.image = JorvikMenuBarPill.icon(
            symbolName: symbol,
            tint: tint,
            accessibilityDescription: "Lookout"
        )
        button.title = ""
        button.imagePosition = .imageOnly

        if shouldPulse {
            startPulse(color: tint ?? .systemRed)
        } else {
            stopPulse()
        }
    }

    // MARK: - Pulse / glow animation
    // Same shape as CalendarUpcoming's startPulse/stopPulse — opacity fade
    // 1.0 → 0.35 plus a coloured shadow halo, 1.2s easeInEaseOut, infinite,
    // autoreversing. Whole status-bar image (pill + glyph) fades together,
    // which is the accepted trade-off for the composed-NSImage pill design.

    private func startPulse(color: NSColor) {
        if isPulsing { stopPulse() }
        guard let layer = statusItem.button?.layer else { return }
        isPulsing = true

        layer.shadowColor = color.cgColor
        layer.shadowOpacity = 0.0
        layer.shadowRadius = 8.0
        layer.shadowOffset = .zero

        let opAnim = CABasicAnimation(keyPath: "opacity")
        opAnim.fromValue = 1.0; opAnim.toValue = 0.35
        opAnim.duration = 1.2; opAnim.autoreverses = true
        opAnim.repeatCount = .infinity
        opAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(opAnim, forKey: "lookoutPulse")

        let glowAnim = CABasicAnimation(keyPath: "shadowOpacity")
        glowAnim.fromValue = 0.9; glowAnim.toValue = 0.1
        glowAnim.duration = 1.2; glowAnim.autoreverses = true
        glowAnim.repeatCount = .infinity
        glowAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(glowAnim, forKey: "lookoutGlow")
    }

    private func stopPulse() {
        guard isPulsing, let layer = statusItem.button?.layer else { return }
        isPulsing = false
        layer.removeAnimation(forKey: "lookoutPulse")
        layer.removeAnimation(forKey: "lookoutGlow")
        layer.opacity = 1.0
        layer.shadowOpacity = 0.0
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showRightClickMenu()
        } else {
            togglePopover()
        }
    }

    // MARK: Popover

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let panel = LookoutPanel(
            core: core,
            onSetup: { [weak self] in self?.showSetup() },
            onQuit:  { NSApp.terminate(nil) },
            onAbout: { [weak self] in self?.openAbout() },
            onSettings: { [weak self] in self?.openSettings() }
        )
        popover.contentViewController = NSHostingController(rootView: panel)
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        installClickAwayMonitor()
    }

    private func installClickAwayMonitor() {
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    private func showRightClickMenu() {
        let setupTitle = LookoutKeychain.loadToken() == nil ? "Set up GitHub Token\u{2026}" : "Re-enter GitHub Token\u{2026}"

        let menu = JorvikMenuBuilder.buildMenu(
            appName: "Lookout",
            aboutAction: #selector(openAboutAction),
            settingsAction: #selector(openSettingsAction),
            target: self,
            actions: [
                JorvikMenuBuilder.ActionItem(title: "Refresh",     action: #selector(refreshNow),       target: self, keyEquivalent: "r"),
                JorvikMenuBuilder.ActionItem(title: setupTitle,    action: #selector(showSetupAction),  target: self),
                JorvikMenuBuilder.ActionItem(title: "-",           action: #selector(refreshNow),       target: self),
                JorvikMenuBuilder.ActionItem(title: "Check for Updates\u{2026}", action: #selector(checkForUpdates(_:)), target: self),
            ]
        )

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        DispatchQueue.main.async { [weak self] in self?.statusItem.menu = nil }
    }

    @objc private func refreshNow() { core.refreshNow() }
    @objc private func showSetupAction() { showSetup() }
    @objc private func openAboutAction() { openAbout() }
    @objc private func openSettingsAction() { openSettings() }
    @objc func checkForUpdates(_ sender: Any?) {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        sparkleUpdater.checkForUpdates(sender)
    }

    private func showSetup() {
        if popover.isShown { popover.performClose(nil) }
        LookoutSetupWindow.show { [weak self] _ in
            self?.core.tokenWasUpdated()
        }
    }

    private func openAbout() {
        if popover.isShown { popover.performClose(nil) }
        JorvikAboutView.showWindow(
            appName: "Lookout",
            repoName: "Lookout",
            productPage: "utilities/lookout"
        )
    }

    private func openSettings() {
        if popover.isShown { popover.performClose(nil) }
        JorvikSettingsView.showWindow(appName: "Lookout") { [weak self] in
            MenuBarPillSettings { self?.refreshIcon() }
        }
    }
}

/// Keeps Sparkle's update UI visible across the whole session, including
/// when the user switches to another app mid-download. See KB:
/// `conventions/sparkle-integration.md` §6 for the rationale.
final class LookoutUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    private var sessionObserver: NSObjectProtocol?
    private var elevatedWindows: [(window: NSWindow, originalLevel: NSWindow.Level)] = []

    func standardUserDriverWillShowModalAlert() {
        bringForward()
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        startFocusGuard()
        bringForward()
    }

    func standardUserDriverWillFinishUpdateSession() {
        stopFocusGuard()
    }

    private func bringForward() {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        elevateAllWindows()
    }

    private func startFocusGuard() {
        guard sessionObserver == nil else { return }
        sessionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.bringForward()
        }
    }

    private func stopFocusGuard() {
        if let obs = sessionObserver {
            NotificationCenter.default.removeObserver(obs)
            sessionObserver = nil
        }
        for entry in elevatedWindows {
            entry.window.level = entry.originalLevel
        }
        elevatedWindows.removeAll()
    }

    private func elevateAllWindows() {
        for window in NSApp.windows where window.isVisible && window.level == .normal {
            elevatedWindows.append((window, window.level))
            window.level = .floating
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
