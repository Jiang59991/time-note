import AppKit
import WebKit

/// Real WebKit keyboard regression, only called with an isolated TIME_NOTE_DATA_DIR.
@MainActor
func runTitleInputTest(in webView: WKWebView, window: NSWindow, directory: URL, hover: @escaping () -> Void) {
    Task { @MainActor in
        var checks: [String] = []
        func require(_ condition: Bool, _ label: String) throws {
            guard condition else { throw ShellError.message(label) }
            checks.append(label)
        }
        func js(_ script: String) async throws -> Any? { try await webView.evaluateJavaScript(script) }
        func pause() async { try? await Task.sleep(nanoseconds: 200_000_000) }
        @MainActor func key(_ characters: String, _ code: UInt16, modifiers: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code) { window.sendEvent(event) }
            }
        }
        do {
            _ = try await webView.callAsyncJavaScript("""
                const bridge = p => window.webkit.messageHandlers.timeNote.postMessage(p);
                const stamp = Date.now();
                const state = await bridge({action:'command',command:{operationID:crypto.randomUUID(),type:'manual',
                  title:'标题输入测试',category:'work',categoryManual:true,start:stamp-3600000,end:stamp-1800000}});
                window.timeNote.receiveSnapshot(state);
                window.titleInputRecordID = state.records.find(r=>r.title==='标题输入测试').id;
                document.activeElement?.blur();
                """, arguments: [:], in: nil, contentWorld: .page)
            hover()
            NSApp.deactivate()
            await pause()
            _ = try await js("window.timeNote.openRecord(window.titleInputRecordID); true")
            await pause()
            let rect = try await js("JSON.stringify((()=>{const r=document.querySelector('#edit-title').getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})())") as! String
            let point = try JSONSerialization.jsonObject(with: Data(rect.utf8)) as! [String: Double]
            let localY = webView.isFlipped ? point["y"]! : webView.bounds.height - point["y"]!
            let clickPoint = webView.convert(NSPoint(x: point["x"]!, y: localY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: clickPoint, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                window.sendEvent(event)
            }
            await pause()
            try require(window.isKeyWindow && NSApp.isActive, "click after inactive hover activates the window and application")
            try require(try await js("document.activeElement.id") as? String == "edit-title", "mouse click focuses the actual WebKit title input")
            _ = try await js("document.querySelector('#edit-title').setSelectionRange(0,document.querySelector('#edit-title').value.length); true")
            key("\u{7f}", 51)
            await pause()
            try require(try await js("document.querySelector('#edit-title').value") as? String == "", "native Delete clears the selected title")
            for (text, code) in [("a", UInt16(0)), ("b", 11), ("c", 8)] { key(text, code) }
            await pause()
            try require(try await js("document.querySelector('#edit-title').value") as? String == "abc", "native printable keys insert after deletion")
            guard let client = window.firstResponder as? NSTextInputClient else {
                throw ShellError.message("WebKit responder must support macOS text input")
            }
            client.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            await pause()
            client.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
            await pause()
            try require(try await js("document.querySelector('#edit-title').value") as? String == "abc中文", "marked text can commit Chinese after native typing")
            _ = try await js("document.querySelector('#edit-form').requestSubmit(); true")
            await pause()
            let result = try await webView.callAsyncJavaScript("""
                const state = await window.webkit.messageHandlers.timeNote.postMessage({action:'load'});
                return state.records.find(r=>r.id===window.titleInputRecordID).title;
                """, arguments: [:], in: nil, contentWorld: .page)
            try require(result as? String == "abc中文", "edited title saves through the real native bridge")
            let resultData = try JSONSerialization.data(withJSONObject: ["status":"passed", "checks":checks], options: [.prettyPrinted])
            try resultData.write(to: directory.appendingPathComponent("title-input-result.json"))
            print(String(data: resultData, encoding: .utf8)!); fflush(stdout); exit(0)
        } catch {
            let result: [String: Any] = ["status":"failed", "checks":checks, "error":error.localizedDescription,
                "active":NSApp.isActive, "key":window.isKeyWindow]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]) {
                try? data.write(to: directory.appendingPathComponent("title-input-result.json"))
                fputs(String(data: data, encoding: .utf8)! + "\n", stderr)
            }
            exit(1)
        }
    }
}
