import AppKit
import WebKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    private var expandedContent: NSView?
    private var expandedFrame = NSRect.zero
    private var isCollapsed = false
    private var waitForOrbExit = false
    private var hoverTimer: Timer?
    private var pointerSince: Date?
    private var outsideSince: Date?
    private var holdUntil = Date.distantPast
    private var checkingCollapse = false
    private var settingsOpen = false
    private var engine: StoreEngine!
    private var dataDirectory: URL!
    private var window: NSWindow!
    private var webView: WKWebView!
    private var statusItem: NSStatusItem!
    private var opacityLabel: NSTextField?
    private let notifications = NotificationScheduler()
    private var timer: Timer?
    private var pollInProgress = false
    private var lastRevision: Int = -1
    private var pageReady = false
    private var smokeStarted = false
    private var selectedView = "day"
    private var changingView = false
    private var windowReady = false
    private var indexURL: URL!
    private var settingsMenu = NSMenu()
    private var lastSnapshot: [String: Any]?
    private let isTest = !(ProcessInfo.processInfo.environment["TIME_NOTE_DATA_DIR"] ?? "").isEmpty
    private lazy var preferences: UserDefaults = isTest ? UserDefaults(suiteName: "local.zoey.time-note.testing")! : .standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--smoke-") || $0 == "--title-input-test" }) && !isTest {
                throw ShellError.message("冒烟测试必须指定独立的 TIME_NOTE_DATA_DIR。")
            }
            let directory: URL
            if let override = ProcessInfo.processInfo.environment["TIME_NOTE_DATA_DIR"], !override.isEmpty {
                directory = URL(fileURLWithPath: override, isDirectory: true)
            } else {
                directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Time Note", isDirectory: true)
            }
            dataDirectory = directory
            engine = try StoreEngine(url: directory.appendingPathComponent("store.json"))
            guard let resources = Bundle.main.resourceURL else { throw ShellError.message("应用资源缺失，请重新安装。") }
            indexURL = resources.appendingPathComponent("Web/index.html")
            guard FileManager.default.fileExists(atPath: indexURL.path) else { throw ShellError.message("界面资源缺失，请重新安装。") }
            preferences.register(defaults: ["pinned": true, "opacity": 0.85, "currentSpaceOnly": true, "hoverOrb": true])
            // This release enables the user's requested floating behavior once;
            // subsequent explicit toggles remain persistent.
            if !preferences.bool(forKey: "framelessAppearanceV1") {
                preferences.set(true, forKey: "pinned")
                preferences.set(true, forKey: "framelessAppearanceV1")
            }
            buildMenus()
            buildWindow()
            notifications.onOpen = { [weak self] in self?.showWindow() }
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(resume), name: NSWorkspace.didWakeNotification, object: nil)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(resume), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.poll() }
            }
            RunLoop.main.add(timer!, forMode: .common)
            showWindow()
            if !isTest {
                hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                    Task { @MainActor in await self?.checkHover() }
                }
                RunLoop.main.add(hoverTimer!, forMode: .common)
            }
            Task { await poll(force: true) }
        } catch {
            let alert = NSAlert(); alert.messageText = "Time Note 无法打开"; alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "退出"); alert.runModal(); NSApp.terminate(nil)
        }
    }

    private func buildWindow() {
        let configuration = WKWebViewConfiguration()
        if isTest { configuration.websiteDataStore = .nonPersistent() }
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "timeNote")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = NoteWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.autoresizingMask = [.width, .height]
        window = NoteWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 440),
            styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.title = "Time Note"
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.isReleasedWhenClosed = false; window.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 440))
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        content.layer?.cornerRadius = 20
        content.layer?.masksToBounds = true
        webView.frame = content.bounds
        content.addSubview(webView)
        let dragSurface = NoteDragSurface(frame: content.bounds)
        dragSurface.autoresizingMask = [.width, .height]
        content.addSubview(dragSurface)
        window.contentView = content
        window.center()
        applyAppearance()
        switchView("day")
        if let origin = preferences.array(forKey: "windowOrigin") as? [Double], origin.count == 2, origin.allSatisfy({ $0.isFinite }), let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(NSPoint(x: origin[0], y: origin[1])) }) ?? NSScreen.main {
            var frame = window.frame
            frame.origin = NSPoint(x: min(screen.visibleFrame.maxX - frame.width, max(screen.visibleFrame.minX, origin[0])), y: min(screen.visibleFrame.maxY - frame.height, max(screen.visibleFrame.minY, origin[1])))
            window.setFrame(frame, display: true)
        }
        if !isTest && !preferences.bool(forKey: "orbPositionV1"), let screen = window.screen ?? NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - window.frame.width - 16,
                                          y: screen.visibleFrame.maxY - window.frame.height - 16))
            preferences.set(true, forKey: "orbPositionV1")
            preferences.set([Double(window.frame.minX), Double(window.frame.minY)], forKey: "windowOrigin")
        }
        windowReady = true
        webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
    }

    private func buildMenus() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(item("显示 Time Note", #selector(showWindow), "0"))
        appMenu.addItem(item("开始记录", #selector(openRecord), "n"))
        appMenu.addItem(.separator())
        appMenu.addItem(item("设置与数据…", #selector(openSettings), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(item("隐藏 Time Note", #selector(hideWindow), "h"))
        appMenu.addItem(item("退出 Time Note（保留计时）", #selector(quit), "q"))
        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let edit = NSMenu(title: "编辑"); editItem.submenu = edit
        edit.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z"); edit.addItem(redo)
        edit.addItem(.separator())
        for (title, selector, key) in [("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key))
        }
        NSApp.mainMenu = mainMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "clock", accessibilityDescription: "Time Note")
        let menu = NSMenu()
        menu.addItem(item("显示 / 隐藏 Time Note", #selector(toggleWindow)))
        menu.addItem(item("开始记录", #selector(openRecord)))
        menu.addItem(.separator())
        menu.addItem(item("设置与数据…", #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(item("退出 Time Note（保留计时）", #selector(quit)))
        statusItem.menu = menu
        refreshSettingsMenu()
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: key); result.target = self; return result
    }
    private func refreshSettingsMenu() {
        settingsMenu.removeAllItems()
        let orb = item("移开鼠标后收为小圆球", #selector(toggleOrb))
        orb.state = preferences.bool(forKey: "hoverOrb") ? .on : .off
        settingsMenu.addItem(orb)
        let pin = item("窗口置顶", #selector(togglePin)); pin.state = preferences.bool(forKey: "pinned") ? .on : .off; settingsMenu.addItem(pin)
        let space = item("仅在当前桌面显示", #selector(toggleCurrentSpace))
        space.state = preferences.bool(forKey: "currentSpaceOnly") ? .on : .off
        settingsMenu.addItem(space)
        let lock = item("锁定窗口位置", #selector(togglePositionLock)); lock.state = preferences.bool(forKey: "positionLocked") ? .on : .off; settingsMenu.addItem(lock)
        let opacityItem = NSMenuItem(title: "背景不透明度", action: nil, keyEquivalent: "")
        let opacityView = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 66))
        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 16, y: 39, width: 220, height: 19)
        label.font = .systemFont(ofSize: 12)
        opacityView.addSubview(label); opacityLabel = label
        let slider = NSSlider(value: currentOpacity * 100, minValue: 0, maxValue: 100, target: self, action: #selector(setOpacity(_:)))
        slider.frame = NSRect(x: 14, y: 10, width: 222, height: 24)
        slider.isContinuous = true
        slider.setAccessibilityLabel("背景不透明度，0 为透明，100 为不透明")
        opacityView.addSubview(slider); opacityItem.view = opacityView
        updateOpacityLabel()
        settingsMenu.addItem(opacityItem)
        settingsMenu.addItem(item("启用番茄完成通知…", #selector(enableNotifications)))
        settingsMenu.addItem(.separator())
        for (title, format) in [("导出完整 JSON 备份…", "json"), ("导出 CSV…", "csv"), ("导出 Markdown…", "markdown")] {
            let export = item(title, #selector(exportMenu(_:))); export.representedObject = format; settingsMenu.addItem(export)
        }
        settingsMenu.addItem(item("从 JSON 备份恢复…", #selector(importMenu)))
        settingsMenu.addItem(item("打开数据文件夹", #selector(revealData)))
        settingsMenu.addItem(.separator())
        let info = NSMenuItem(title: "关闭窗口后计时继续；退出后到期通知仍保留。", action: nil, keyEquivalent: ""); info.isEnabled = false; settingsMenu.addItem(info)
    }
    private var currentOpacity: Double { max(0, min(1, preferences.double(forKey: "opacity"))) }
    private func updateOpacityLabel() {
        opacityLabel?.stringValue = "背景不透明度  \(Int((currentOpacity * 100).rounded()))%"
    }
    private func applyAppearance() {
        window.level = preferences.bool(forKey: "pinned") ? .floating : .normal
        // Floating windows otherwise default to transient Spaces behavior.
        // Managed explicitly keeps this window in its own Space even when pinned.
        window.collectionBehavior = preferences.bool(forKey: "currentSpaceOnly")
            ? [.managed] : [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.alphaValue = 1
        window.isMovable = !preferences.bool(forKey: "positionLocked")
        if let surface = window.contentView?.subviews.last { window.invalidateCursorRects(for: surface) }
        let opacity = currentOpacity
        if pageReady { webView.evaluateJavaScript("document.documentElement.style.setProperty('--paper-alpha','\(opacity)')", completionHandler: nil) }
    }
    @objc private func togglePositionLock() { preferences.set(!preferences.bool(forKey: "positionLocked"), forKey: "positionLocked"); applyAppearance(); refreshSettingsMenu() }
    @objc private func toggleCurrentSpace() { preferences.set(!preferences.bool(forKey: "currentSpaceOnly"), forKey: "currentSpaceOnly"); applyAppearance(); refreshSettingsMenu() }
    @objc private func togglePin() { preferences.set(!preferences.bool(forKey: "pinned"), forKey: "pinned"); applyAppearance(); refreshSettingsMenu() }
    @objc private func setOpacity(_ sender: NSSlider) { preferences.set(sender.doubleValue / 100, forKey: "opacity"); applyAppearance(); updateOpacityLabel() }
    @objc private func showWindow() { expandOrb(activate: true); holdUntil = Date().addingTimeInterval(2); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func hideWindow() { window?.orderOut(nil) }
    @objc private func toggleWindow() { window.isVisible ? hideWindow() : showWindow() }
    @objc private func openRecord() { showWindow(); webView?.evaluateJavaScript("window.timeNote && window.timeNote.openRecord()", completionHandler: nil) }
    @objc private func openSettings() {
        showWindow(); refreshSettingsMenu(); settingsOpen = true
        defer { settingsOpen = false; holdUntil = Date().addingTimeInterval(1) }
        settingsMenu.popUp(positioning: nil, at: NSPoint(x: max(20, window.contentView!.bounds.width - 240), y: window.contentView!.bounds.height - 20), in: window.contentView)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func resume() { Task { await poll(force: true) } }
    @objc private func enableNotifications() {
        Task {
            do {
                let status = try await notifications.requestPermission()
                await poll(force: true); showMessage("番茄完成通知", status)
            } catch { showError(error) }
        }
    }
    @objc private func exportMenu(_ sender: NSMenuItem) {
        Task { do { _ = try await exportData(sender.representedObject as? String ?? "json") } catch { showError(error) } }
    }
    @objc private func importMenu() { Task { do { _ = try await importData() } catch { showError(error) } } }
    @objc private func revealData() {
        let path = ProcessInfo.processInfo.environment["TIME_NOTE_DATA_DIR"] ?? (NSHomeDirectory() + "/Library/Application Support/Time Note")
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationDidBecomeActive(_ notification: Notification) { resume() }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate(); hoverTimer?.invalidate() }
    func windowDidMove(_ notification: Notification) {
        guard windowReady, !changingView, !isCollapsed, let window else { return }
        preferences.set([Double(window.frame.origin.x), Double(window.frame.origin.y)], forKey: "windowOrigin")
    }
    func windowDidResize(_ notification: Notification) {
        guard windowReady, !changingView, !isCollapsed, let content = window?.contentView else { return }
        preferences.set([Double(content.bounds.width), Double(content.bounds.height)], forKey: selectedView == "week" ? "size.weekCalendar" : (selectedView == "day" ? "size.dayPacked" : "size.\(selectedView)"))
    }
    private func switchView(_ view: String) {
        guard ["day", "week", "record"].contains(view) else { return }
        if isCollapsed { expandOrb(activate: false) }
        changingView = true; defer { changingView = false }
        selectedView = view
        let defaults: [String: [Double]] = ["day": [460,460], "week": [520,740], "record": [456,750]]
        let size = preferences.array(forKey: view == "week" ? "size.weekCalendar" : (view == "day" ? "size.dayPacked" : "size.\(view)")) as? [Double] ?? defaults[view]!
        let minimum = view == "week" ? NSSize(width: 440, height: 620) : (view == "record" ? NSSize(width: 400, height: 620) : NSSize(width: 360, height: 360))
        let topRight = NSPoint(x: window.frame.maxX, y: window.frame.maxY)
        window.contentMinSize = minimum
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 900)
        let width = min(max(size.first ?? 420, minimum.width), screen.width)
        let height = min(max(size.count > 1 ? size[1] : 440, minimum.height), screen.height - 32)
        window.setContentSize(NSSize(width: width, height: height))
        var frame = window.frame
        frame.origin.y = min(screen.maxY - frame.height, max(screen.minY, topRight.y - frame.height))
        frame.origin.x = min(screen.maxX - frame.width, max(screen.minX, topRight.x - frame.width))
        window.setFrame(frame, display: true)
    }

    @objc private func toggleOrb() {
        preferences.set(!preferences.bool(forKey: "hoverOrb"), forKey: "hoverOrb")
        if !preferences.bool(forKey: "hoverOrb") { expandOrb(activate: true) }
        outsideSince = nil; refreshSettingsMenu()
    }
    private func collapseToOrb() {
        guard !isCollapsed, let window, let content = window.contentView else { return }
        changingView = true; defer { changingView = false }
        expandedFrame = window.frame; expandedContent = content
        // Let AppKit clear its key-window bookkeeping before the non-key orb
        // replaces the editor. Calling resignKey directly leaves a stale key
        // window identity that can prevent later text insertion in WebKit.
        window.orderOut(nil)
        let orb = NoteOrbView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        orb.setAccessibilityElement(true)
        orb.onOpen = { [weak self] in self?.showWindow() }
        orb.onDragEnd = { [weak self] in self?.orbDragEnded() }
        isCollapsed = true
        (window as? NoteWindow)?.compactMode = true
        window.contentMinSize = NSSize(width: 40, height: 40)
        window.styleMask.remove(.resizable)
        window.contentView = orb
        window.setFrame(NSRect(x: expandedFrame.maxX - 40, y: expandedFrame.maxY - 40, width: 40, height: 40), display: true)
        window.orderFront(nil)
        pointerSince = nil; outsideSince = nil
    }
    private func orbDragEnded() {
        guard isCollapsed else { return }
        expandedFrame.origin = NSPoint(x: window.frame.maxX - expandedFrame.width,
                                       y: window.frame.maxY - expandedFrame.height)
        preferences.set([Double(expandedFrame.minX), Double(expandedFrame.minY)], forKey: "windowOrigin")
        waitForOrbExit = true; pointerSince = nil
    }
    private func expandOrb(activate: Bool) {
        guard isCollapsed, let window, let content = expandedContent else { return }
        changingView = true; defer { changingView = false }
        isCollapsed = false; waitForOrbExit = false
        (window as? NoteWindow)?.compactMode = false
        window.styleMask.insert(.resizable)
        window.contentView = content
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? expandedFrame
        var frame = expandedFrame
        frame.origin.x = min(screen.maxX-frame.width, max(screen.minX,frame.minX))
        frame.origin.y = min(screen.maxY-frame.height, max(screen.minY,frame.minY))
        window.setFrame(frame, display: true)
        window.contentMinSize = selectedView == "week" ? NSSize(width: 440, height: 620) : (selectedView == "record" ? NSSize(width: 400, height: 620) : NSSize(width: 360, height: 360))
        expandedContent = nil; outsideSince = nil; pointerSince = nil
        holdUntil = Date().addingTimeInterval(1)
        if activate { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        else { window.orderFront(nil) }
    }
    private func interactionNeedsWindow() async -> Bool {
        guard pageReady, !settingsOpen, window.attachedSheet == nil, NSApp.modalWindow == nil else { return true }
        let script = "Boolean(document.querySelector('dialog[open]') || document.activeElement?.matches('input,textarea,select,[contenteditable=true]') || document.querySelector('[aria-expanded=true]'))"
        do { return (try await webView.evaluateJavaScript(script) as? Bool) ?? true }
        catch { return true }
    }
    private func checkHover(at testPoint: NSPoint? = nil) async {
        let pointer = testPoint ?? NSEvent.mouseLocation
        guard preferences.bool(forKey: "hoverOrb"), window.isVisible, pageReady else { return }
        let inside = window.frame.insetBy(dx: isCollapsed ? 0 : -8, dy: isCollapsed ? 0 : -8).contains(pointer)
        if isCollapsed {
            outsideSince = nil
            if NSEvent.pressedMouseButtons != 0 || (window.contentView as? NoteOrbView)?.holdingPointer == true {
                pointerSince = nil; return
            }
            if waitForOrbExit { if !inside { waitForOrbExit = false }; pointerSince = nil; return }
            if inside {
                if pointerSince == nil { pointerSince = Date() }
                if Date().timeIntervalSince(pointerSince!) >= 0.18 { expandOrb(activate: false) }
            } else { pointerSince = nil }
            return
        }
        if inside || NSEvent.pressedMouseButtons != 0 || Date() < holdUntil || settingsOpen || window.inLiveResize {
            outsideSince = nil; return
        }
        if outsideSince == nil { outsideSince = Date(); return }
        guard Date().timeIntervalSince(outsideSince!) >= 0.9, !checkingCollapse else { return }
        checkingCollapse = true; defer { checkingCollapse = false }
        if await interactionNeedsWindow() { outsideSince = nil; return }
        guard !isCollapsed, window.isVisible, !settingsOpen, window.attachedSheet == nil,
              !window.frame.insetBy(dx: -8, dy: -8).contains(pointer), NSEvent.pressedMouseButtons == 0 else { return }
        collapseToOrb()
    }

    private func runOrbTest() {
        Task { @MainActor in
            var checks: [String] = []
            func require(_ ok: Bool, _ message: String) throws {
                if !ok { throw ShellError.message(message) }; checks.append(message)
            }
            do {
                preferences.set(true, forKey: "hoverOrb")
                let original = window.frame
                _ = try await webView.evaluateJavaScript("document.querySelector('#new-title').value='保留草稿'; document.activeElement?.blur(); true")
                collapseToOrb()
                try require(isCollapsed && window.frame.size == NSSize(width: 40, height: 40), "collapsed window is 40x40")
                try require(window.frame.maxX == original.maxX && window.frame.maxY == original.maxY, "top right anchor preserved")
                let oldOrigin = window.frame.origin
                window.setFrameOrigin(NSPoint(x: oldOrigin.x - 25, y: oldOrigin.y - 25))
                orbDragEnded()
                try require(waitForOrbExit && expandedFrame.maxX == window.frame.maxX && expandedFrame.maxY == window.frame.maxY, "drag updates expanded anchor")
                await checkHover(at: NSPoint(x: window.frame.midX, y: window.frame.midY))
                try require(isCollapsed, "release after drag stays collapsed")
                await checkHover(at: NSPoint(x: -99999, y: -99999))
                pointerSince = Date().addingTimeInterval(-1)
                await checkHover(at: NSPoint(x: window.frame.midX, y: window.frame.midY))
                try require(!isCollapsed && window.frame.size == original.size, "hover restores full window")
                let draft = try await webView.evaluateJavaScript("document.querySelector('#new-title').value") as? String
                try require(draft == "保留草稿", "WebKit draft survives collapse and expand")
                let outside = NSPoint(x: -99999, y: -99999)
                holdUntil = .distantPast; outsideSince = Date()
                await checkHover(at: outside)
                try require(!isCollapsed, "exit delay prevents immediate collapse")
                _ = try await webView.evaluateJavaScript("document.querySelector('#tab-record').click(); document.querySelector('#new-title').focus(); true")
                try require(await interactionNeedsWindow(), "focused input holds window open")
                _ = try await webView.evaluateJavaScript("document.activeElement.blur(); document.querySelector('#confirm-dialog').showModal(); true")
                try require(await interactionNeedsWindow(), "editing dialog holds window open")
                _ = try await webView.evaluateJavaScript("document.querySelector('#confirm-dialog').close(); document.activeElement?.blur(); true")
                settingsOpen = true
                try require(await interactionNeedsWindow(), "native settings hold window open")
                settingsOpen = false; outsideSince = Date().addingTimeInterval(-2); holdUntil = .distantPast
                await checkHover(at: outside)
                try require(isCollapsed, "leaving idle window collapses after delay")
                showWindow()
                try require(!isCollapsed, "explicit open always expands")
                let data = try JSONSerialization.data(withJSONObject: ["status":"passed", "checks":checks], options:.prettyPrinted)
                try data.write(to: dataDirectory.appendingPathComponent("orb-result.json"))
                print(String(data:data,encoding:.utf8)!); fflush(stdout); exit(0)
            } catch { fputs("orb test failed: \(error)\n",stderr); exit(1) }
        }
    }

    private func poll(force: Bool = false) async {
        guard engine != nil, !pollInProgress else { return }
        pollInProgress = true; defer { pollInProgress = false }
        do { let data = try await engine.snapshot(); try await accept(data, force: force) }
        catch { NSLog("Time Note store: %@", error.localizedDescription) }
    }
    private func accept(_ data: Data, force: Bool = false) async throws {
        guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ShellError.message("记录格式无效。") }
        let revision = snapshot["revision"] as? Int ?? 0
        guard revision >= lastRevision else { return }
        let changed = revision != lastRevision
        lastRevision = revision; lastSnapshot = snapshot
        if pageReady && (changed || force), let json = String(data: data, encoding: .utf8) {
            webView.evaluateJavaScript("window.timeNote && window.timeNote.receiveSnapshot(\(json))", completionHandler: nil)
        }
        await notifications.sync(snapshot, force: force)
    }
    private func response(_ data: Data) throws -> Any { try JSONSerialization.jsonObject(with: data) }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.webView === webView, message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.standardizedFileURL.path == indexURL.standardizedFileURL.path,
              message.frameInfo.request.url?.isFileURL == true,
              let payload = message.body as? [String: Any], let action = payload["action"] as? String else {
            replyHandler(nil, "此页面不能访问 Time Note 数据。"); return
        }
        Task { @MainActor in
            do {
                switch action {
                case "load":
                    let data = try await engine.snapshot(); try await accept(data, force: true); replyHandler(try response(data), nil)
                case "command":
                    guard let command = payload["command"] as? [String: Any] else { throw ShellError.message("操作内容无效。") }
                    let data = try await engine.execute(JSONSerialization.data(withJSONObject: command))
                    try await accept(data); replyHandler(try response(data), nil)
                case "view":
                    guard let view = payload["view"] as? String, ["day", "week", "record"].contains(view) else { throw ShellError.message("未知页面。") }
                    switchView(view); replyHandler(["ok": true], nil)
                case "settings":
                    replyHandler(["ok": true], nil)
                    DispatchQueue.main.async { self.openSettings() }
                case "export":
                    replyHandler(try await exportData(payload["format"] as? String ?? "json"), nil)
                case "import": replyHandler(try await importData(), nil)
                case "notifications":
                    let status = try await notifications.requestPermission(); await poll(force: true); replyHandler(["status": status], nil)
                default: throw ShellError.message("不支持的操作。")
                }
            } catch {
                // A stale command can reconcile expiry before being rejected. Refresh that committed truth.
                await poll(force: true)
                replyHandler(nil, error.localizedDescription)
            }
        }
    }

    private func exportData(_ format: String) async throws -> [String: Any] {
        guard ["json", "csv", "markdown"].contains(format) else { throw ShellError.message("不支持的导出格式。") }
        let panel = NSSavePanel()
        let ext = format == "markdown" ? "md" : format
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        panel.nameFieldStringValue = "Time-Note-\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none).replacingOccurrences(of: "/", with: "-" )).\(ext)"
        panel.canCreateDirectories = true
        guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return ["ok": true, "cancelled": true] }
        guard ExportDestination.isAllowed(url, dataDirectory: dataDirectory) else {
            throw ShellError.message("请选择数据文件夹以外的位置保存导出，避免覆盖当前记录或自动备份。")
        }
        let data: Data
        if format == "json" { data = try await engine.exportBackup() }
        else {
            let snapshotData = try await engine.snapshot(); try await accept(snapshotData)
            let snapshot = try response(snapshotData) as! [String: Any]
            data = format == "csv" ? ExportFormatter.csv(snapshot) : ExportFormatter.markdown(snapshot)
        }
        try data.write(to: url, options: .atomic)
        return ["ok": true]
    }
    private func importData() async throws -> Any {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return ["cancelled": true] }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attrs[.size] as? NSNumber)?.intValue ?? 0 <= 64 * 1024 * 1024 else { throw ShellError.message("备份超过 64 MB，无法导入。") }
        let data = try Data(contentsOf: url)
        let summary = try await validateImport(data)
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "用此备份替换当前数据？"
        alert.informativeText = "备份包含 \(summary.records) 条时间记录与 \(summary.todos) 条 Todo。当前数据会先备份到数据文件夹，然后完整替换。运行中的番茄按原定截止时间恢复。"
        alert.addButton(withTitle: "替换并恢复"); alert.addButton(withTitle: "取消")
        guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return ["cancelled": true] }
        let result = try await engine.importBackup(data); try await accept(result, force: true); return try response(result)
    }
    private func validateImport(_ data: Data) async throws -> (records: Int, todos: Int) {
        try StoreEngine.validateBackup(data)
    }
    private func showMessage(_ title: String, _ body: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = body; alert.addButton(withTitle: "好")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
    private func showError(_ error: Error) { showMessage("操作未完成", error.localizedDescription) }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        applyAppearance()
        Task { await poll(force: true) }
        if isTest && CommandLine.arguments.contains("--orb-test") { runOrbTest(); return }
        if isTest && CommandLine.arguments.contains("--title-input-test") {
            runTitleInputTest(in: webView, window: window, directory: dataDirectory,
                hover: { [weak self] in self?.collapseToOrb(); self?.expandOrb(activate: false) })
            return
        }
        if !isTest && preferences.bool(forKey: "hoverOrb") { collapseToOrb() }
        if ProcessInfo.processInfo.arguments.contains("--smoke-test"), !smokeStarted {
            smokeStarted = true
            guard isTest else { NSLog("--smoke-test requires TIME_NOTE_DATA_DIR"); NSApp.terminate(nil); return }
            runNativeSmokeTest(in: webView)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame == true && url.isFileURL && url.standardizedFileURL.path == indexURL.standardizedFileURL.path {
            decisionHandler(.allow)
        } else {
            if navigationAction.navigationType == .linkActivated && ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = message; alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { response in completionHandler(response == .alertFirstButtonReturn) }
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert(); alert.messageText = message; alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }
}

enum ShellError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

@main
struct TimeNoteMain {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
