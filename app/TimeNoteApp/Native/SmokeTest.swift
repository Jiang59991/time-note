import AppKit
import WebKit
import Foundation

/// Release smoke testing only. Requires an explicitly isolated data directory.
@MainActor
func runNativeSmokeTest(in webView: WKWebView) {
    guard let directory = ProcessInfo.processInfo.environment["TIME_NOTE_DATA_DIR"], !directory.isEmpty else {
        fputs("Smoke tests require TIME_NOTE_DATA_DIR.\n", stderr)
        exit(2)
    }
    let reopen = CommandLine.arguments.contains("--smoke-reopen")
    Task { @MainActor in
        let resultURL = URL(fileURLWithPath: directory).appendingPathComponent(reopen ? "smoke-reopen-result.json" : "smoke-result.json")
        do {
            let body = #"""
            const assert = (ok, message) => { if (!ok) throw new Error(message); };
            const checks = [];
            if (!reopen) {
                document.querySelector('#tab-record').click();
                document.querySelector('[data-entry-mode="manual"]').click();
                const field = document.querySelector('#new-start'); field.value=''; field.focus();
                for (const key of ['1','0']) field.dispatchEvent(new KeyboardEvent('keydown',{key,bubbles:true,cancelable:true}));
                assert(field.value==='10:00' && field.selectionStart===3 && field.selectionEnd===5, 'hours default minutes and select minute segment');
                for (const key of ['3','5']) field.dispatchEvent(new KeyboardEvent('keydown',{key,bubbles:true,cancelable:true}));
                assert(field.value==='10:35', 'minute typing replaces default');field.value='';field.blur();
                document.querySelector('[data-entry-mode="timer"]').click();document.querySelector('#tab-day').click();
                checks.push('WebKit time segments advance and default minutes');
            }
            const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
            const wait = async (predicate, label, timeout = 15000) => {
              const started = Date.now();
              while (Date.now() - started < timeout) {
                if (await predicate()) return;
                await pause(80);
              }
              throw new Error('Timeout: ' + label);
            };
            const bridge = payload => window.webkit.messageHandlers.timeNote.postMessage(payload);
            const command = fields => bridge({action:'command', command:{operationID:crypto.randomUUID(), ...fields}});
            const load = () => bridge({action:'load'});
            const input = (selector, value, event='input') => {
              const el = document.querySelector(selector);
              assert(el, 'Missing input ' + selector);
              el.value = value; el.dispatchEvent(new Event(event, {bubbles:true}));
            };
            await wait(() => window.timeNote && document.querySelector('#entry-form'), 'frontend ready');
            let state = await load();
            assert(state.schemaVersion === 1 && Array.isArray(state.records), 'real native snapshot shape');
            if (reopen) {
              const a = state.records.find(r => r.title === '冒烟科研 A');
              const p = state.records.find(r => r.title === '冒烟番茄 B');
              assert(a && a.end === null, 'ordinary timer restored after process restart');
              assert(p && p.end === p.deadline, 'pomodoro deadline preserved after restart');
              assert(state.records.some(r => r.title === '冒烟手动记录'), 'manual history restored');
              assert(Object.values(state.todos).flat().some(t => t.title === '冒烟待办' && t.done), 'completed todo restored');
              assert(Object.values(state.todos).flat().filter(t => t.title === '冒烟延续待办' && !t.done).length === 1, 'carried todo restored exactly once');
              checks.push('cold process restart preserves independent timers, manual history and todo');
              window.timeNote.openRecord();
              await wait(() => document.querySelector('.running-card'), 'restored running UI');
              return {status:'passed', phase:'reopen', checks, revision:state.revision, records:state.records.length};
            }
            assert(state.records.length === 0 && Object.values(state.todos).flat().length === 0, 'first launch must have no demo data');
            checks.push('clean empty startup through actual WK reply bridge');
            window.timeNote.openRecord();
            await wait(() => document.querySelector('#tab-record').getAttribute('aria-selected') === 'true', 'record tab');
            await wait(() => !document.querySelector('#entry-submit').disabled, 'ready to submit');
            input('#new-title', '冒烟科研 A');
            input('#new-timer-mode', 'countup', 'change');
            document.querySelector('#entry-form').requestSubmit();
            await wait(async () => (await load()).records.some(r => r.title === '冒烟科研 A'), 'UI timer commit');
            state = await load();
            const a = state.records.find(r => r.title === '冒烟科研 A');
            assert(a.runID && a.end === null && a.category === 'work', 'UI start uses native identity and category');
            checks.push('UI start persists a real independently identified timer');
            document.querySelector('#tab-day').click();
            for (let i=0; i<8; i++) document.querySelector('#prev-date').click();
            window.timeNote.openRecord();
            document.querySelector('[data-entry-mode="manual"]').click();
            const yesterday = new Date(); yesterday.setDate(yesterday.getDate()-1);
            const key = [yesterday.getFullYear(),String(yesterday.getMonth()+1).padStart(2,'0'),String(yesterday.getDate()).padStart(2,'0')].join('-');
            document.querySelector('#new-date-toggle').click();
            input('#new-title','冒烟手动记录'); input('#new-category','dining','change');
            input('#new-start-date',key,'change'); input('#new-end-date',key,'change');
            input('#new-start','01:30'); input('#new-end','10:00');
            document.querySelector('#entry-form').requestSubmit();
            await wait(() => document.querySelector('#tab-day').getAttribute('aria-selected') === 'true', 'saved manual record day');
            state = await load();
            const manual = state.records.find(r => r.title === '冒烟手动记录');
            assert(manual && manual.runID === null, 'manual history is not a timer');
            assert(document.querySelector('#date-label').textContent.includes(key.replaceAll('-','.')), 'manual save navigates from old week to saved date');
            const contains = (selector,id) => Array.from(document.querySelectorAll(selector)).some(el => el.dataset.recordIds.split(',').includes(id));
            assert(contains('#day-track .block',manual.id), 'saved dining is visible in day timeline');
            document.querySelector('#tab-week').click();
            assert(contains('#week-days .block',manual.id), 'saved dining is visible in its week');
            assert(Number(document.querySelector('[data-category="dining"]').dataset.duration) === 510*60000, 'saved dining contributes 8h30m to week');
            checks.push('UI manual dining save navigates to its day and renders the saved record and week totals');
            document.querySelector('#tab-day').click();
            await wait(() => document.querySelector('#tab-day').getAttribute('aria-selected') === 'true', 'day tab');
            document.querySelector('#next-date').click(); // Manual entry above selected yesterday.
            input('#todo-input', '冒烟待办'); document.querySelector('#todo-form').requestSubmit();
            await wait(async () => Object.values((await load()).todos).flat().some(t => t.title === '冒烟待办'), 'UI todo commit');
            await wait(() => document.querySelector('#todo-list input[type=checkbox]'), 'todo checkbox');
            document.querySelector('#todo-list input[type=checkbox]').click();
            await wait(async () => Object.values((await load()).todos).flat().some(t => t.title === '冒烟待办' && t.done), 'UI todo completion');
            checks.push('day todo add and completion persist through native commands');
            state = await command({type:'todoAdd',day:key,title:'冒烟延续待办'});
            const carried = Object.entries(state.todos).flatMap(([day,rows]) => rows.filter(t => t.title === '冒烟延续待办').map(t => ({day,...t})));
            const today = new Date(), todayKey = [today.getFullYear(),String(today.getMonth()+1).padStart(2,'0'),String(today.getDate()).padStart(2,'0')].join('-');
            assert(carried.length === 1 && carried[0].day === todayKey && !carried[0].done, 'overdue todo carries forward through real native bridge');
            checks.push('overdue unfinished todo moves to today without duplication');
            state = await command({type:'start', title:'冒烟番茄 B', category:'work', categoryManual:false, mode:'pomodoro', minutes:1});
            let p = state.records.find(r => r.title === '冒烟番茄 B');
            assert(p.id !== a.id && p.runID !== a.runID, 'concurrent timers have distinct IDs');
            const revisionBefore = state.revision;
            try {
              await command({type:'edit',id:a.id,expectedRevision:a.revision+100,title:'不该保存',category:'other',categoryManual:true,start:a.start,end:null,minutes:25,completionIntent:'preserve'});
              throw new Error('Expected revision conflict was accepted');
            } catch (error) { assert(!String(error).includes('was accepted'), String(error)); }
            state = await load();
            assert(state.records.find(r => r.id === a.id).title === '冒烟科研 A', 'failed edit must not mutate saved record');
            assert(state.revision === revisionBefore, 'failed edit must not change revision');
            checks.push('stale mutation rejects without changing committed state');
            p = state.records.find(r => r.id === p.id);
            state = await command({type:'edit',id:p.id,expectedRevision:p.revision,title:p.title,category:p.category,categoryManual:false,start:Date.now()-55000,end:null,minutes:1,completionIntent:'preserve'});
            p = state.records.find(r => r.id === p.id);
            const deadline = p.deadline;
            window.timeNote.openRecord();
            await wait(() => document.querySelectorAll('.running-card').length === 2, 'both running UI rows');
            // No load call here: require native polling to persist expiry and push into WebKit UI.
            await wait(() => document.querySelectorAll('.running-card').length === 1, 'native expiry push', 14000);
            state = await load();
            p = state.records.find(r => r.id === p.id);
            assert(p.end === deadline && state.records.find(r => r.id === a.id).end === null, 'expiry ends only its own run at exact deadline');
            checks.push('native polling expires only the due pomodoro and pushes updated UI');
            document.querySelector('#tab-week').click();
            await wait(() => document.querySelectorAll('#category-summary .category-cell').length === 8, 'eight category summary');
            assert(document.querySelectorAll('#week-days .week-row').length === 7, 'seven timeline rows');
            checks.push('real committed data renders week timeline and all eight categories');
            return {status:'passed', phase:'initial', checks, revision:state.revision, records:state.records.length, runIDs:state.records.filter(r=>r.runID).map(r=>r.runID)};
            """#
            let result = try await webView.callAsyncJavaScript(body, arguments: ["reopen": reopen], in: nil, contentWorld: .page)
            let data = try JSONSerialization.data(withJSONObject: result ?? ["status":"no result"], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: resultURL, options: .atomic)
            if !reopen {
                let configuration = WKSnapshotConfiguration()
                let image = try await webView.takeSnapshot(configuration: configuration)
                if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("native-week.png"), options: .atomic)
                }
            }
            print(String(data: data, encoding: .utf8) ?? "smoke passed")
            fflush(stdout)
            exit(0)
        } catch {
            let result: [String:Any] = ["status":"failed", "phase":reopen ? "reopen":"initial", "error":error.localizedDescription, "detail":String(describing:error)]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]) {
                try? data.write(to: resultURL, options: .atomic)
                fputs((String(data:data,encoding:.utf8) ?? "smoke failed")+"\n", stderr)
            }
            exit(1)
        }
    }
}
