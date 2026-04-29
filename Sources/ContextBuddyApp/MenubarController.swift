import AppKit
import SwiftUI
import ContextBuddyCore

@MainActor
final class MenubarController: NSObject, NSMenuDelegate {
    private let core: BuddyCore
    private let inspectorRoot: URL
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var snapshot = BuddyCore.Snapshot(
        state: .sleep, projectHash: nil, lastGrade: nil, pinnedHash: nil
    )
    private var animationsEnabled = true
    private var tokenRowPct = 70
    private var subscriptionTask: Task<Void, Never>?

    // Async factory replaces the previous semaphore-blocking init. AppDelegate
    // awaits this from `applicationDidFinishLaunching` so the main thread
    // never blocks on Storage open.
    static func create(inspectorRoot: URL? = nil) async throws -> MenubarController {
        let core = try await BuddyCore(inspectorRoot: inspectorRoot)
        let resolvedRoot = inspectorRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/inspector", isDirectory: true)
        return await MainActor.run {
            MenubarController(core: core, inspectorRoot: resolvedRoot)
        }
    }

    private init(core: BuddyCore, inspectorRoot: URL) {
        self.core = core
        self.inspectorRoot = inspectorRoot
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()

        super.init()

        configureStatusItem()
        configurePopover()
        startObserving()
    }

    deinit {
        subscriptionTask?.cancel()
    }

    private func configureStatusItem() {
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        renderIcon()
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 320, height: 200)
        popover.contentViewController = NSHostingController(rootView: makePopoverView())
    }

    private func startObserving() {
        subscriptionTask = Task { [weak self] in
            guard let self else { return }
            await self.core.start()
            for await snap in await self.core.subscribe() {
                await MainActor.run {
                    self.snapshot = snap
                    self.renderIcon()
                    self.updatePopover()
                }
            }
        }
    }

    private func renderIcon() {
        guard let button = statusItem.button else { return }
        let style = IconStyle.style(for: snapshot.state, animationsEnabled: animationsEnabled)
        let image = NSImage(systemSymbolName: style.symbol, accessibilityDescription: snapshot.state.rawValue)
        image?.isTemplate = false
        button.image = image
        button.contentTintColor = style.tint
        button.toolTip = "ContextBuddy: \(snapshot.state.rawValue)"
    }

    private func updatePopover() {
        popover.contentViewController = NSHostingController(rootView: makePopoverView())
    }

    private func makePopoverView() -> some View {
        PopoverView(
            snapshot: snapshot,
            tokenRowPct: tokenRowPct,
            onAck: { [weak self] in self?.handleAck() },
            onMute: { [weak self] in self?.handleMute() },
            onOpenInspector: { [weak self] in self?.openInspectorFolder() }
        )
    }

    @objc private func handleClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        switch event.type {
        case .rightMouseUp:
            showRightClickMenu()
        default:
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func showRightClickMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let ack = NSMenuItem(title: "Ack current state", action: #selector(menuAck), keyEquivalent: "")
        ack.target = self
        ack.isEnabled = canAck
        menu.addItem(ack)

        let mute = NSMenuItem(
            title: "Mute current signal — this session",
            action: #selector(menuMute),
            keyEquivalent: ""
        )
        mute.target = self
        mute.isEnabled = canMute
        menu.addItem(mute)

        menu.addItem(buildRecentSessionsMenu())
        menu.addItem(NSMenuItem.separator())

        let openFolder = NSMenuItem(
            title: "Open inspector folder",
            action: #selector(menuOpenInspector),
            keyEquivalent: ""
        )
        openFolder.target = self
        menu.addItem(openFolder)

        menu.addItem(NSMenuItem.separator())

        let prefs = NSMenuItem(
            title: "Preferences (edit config.toml)",
            action: #selector(menuOpenConfig),
            keyEquivalent: ""
        )
        prefs.target = self
        menu.addItem(prefs)

        let about = NSMenuItem(title: "About ContextBuddy", action: #selector(menuAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func buildRecentSessionsMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: "Recent sessions", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let sessionsRoot = inspectorRoot.appendingPathComponent("sessions", isDirectory: true)
        let discovery = SessionDiscovery(sessionsRoot: sessionsRoot)
        let sessions = Array(discovery.listSessions().prefix(5))
        if sessions.isEmpty {
            let empty = NSMenuItem(title: "(no sessions)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for session in sessions {
                let item = NSMenuItem(
                    title: session.projectHash,
                    action: #selector(menuPinSession(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = session.projectHash
                if snapshot.pinnedHash == session.projectHash {
                    item.state = .on
                }
                submenu.addItem(item)
            }
        }
        parent.submenu = submenu
        return parent
    }

    private var canAck: Bool {
        switch snapshot.state {
        case .attention, .dizzy, .celebrate: return true
        default: return false
        }
    }
    private var canMute: Bool {
        switch snapshot.state {
        case .attention, .dizzy: return true
        default: return false
        }
    }

    @objc private func menuAck() { handleAck() }
    @objc private func menuMute() { handleMute() }
    @objc private func menuOpenInspector() { openInspectorFolder() }
    @objc private func menuOpenConfig() {
        let url = inspectorRoot.appendingPathComponent("config.toml")
        NSWorkspace.shared.open(url)
    }
    @objc private func menuAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }
    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }
    @objc private func menuPinSession(_ sender: NSMenuItem) {
        guard let hash = sender.representedObject as? String else { return }
        Task { await self.core.pinSession(hash) }
    }

    private func handleAck() {
        guard let signal = snapshot.lastGrade?.dominantSignal else { return }
        Task { await self.core.recordFeedback(action: .ack, signal: signal) }
        popover.performClose(nil)
    }

    private func handleMute() {
        guard let signal = snapshot.lastGrade?.dominantSignal else { return }
        Task { await self.core.recordFeedback(action: .mute, signal: signal, scope: .session) }
        popover.performClose(nil)
    }

    private func openInspectorFolder() {
        let sessionsRoot = inspectorRoot.appendingPathComponent("sessions", isDirectory: true)
        let url: URL
        if let hash = snapshot.projectHash {
            url = sessionsRoot.appendingPathComponent(hash)
        } else {
            url = sessionsRoot
        }
        NSWorkspace.shared.open(url)
    }
}
