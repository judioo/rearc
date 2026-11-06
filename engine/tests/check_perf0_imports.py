#!/usr/bin/env python3
"""perf-0: preserve the ABI 1.17, 1.40, 1.42 and 1.43 struct layouts and typecheck gated Swift adoption of ABI 1.44 (and every earlier wave's examples)."""
from pathlib import Path
import re,subprocess,tempfile
from run_c_abi import SRC,BRIDGE,build_gate
build_gate()
root=Path(tempfile.mkdtemp(prefix='rearc-perf0-import-'))
old=root/'abi-1.17';old.mkdir()
for name in ('rearc_engine_abi.h','rearc_engine_entry_mac.h','module.modulemap'):
 (old/name).write_bytes(subprocess.check_output(['git','-C',str(SRC),'show','1708e96dbe:chrome/browser/rearc_bridge/'+name]))
types=re.findall(r'typedef struct (\w+)\s*\{',(old/'rearc_engine_abi.h').read_text())
c=root/'layout.c';c.write_text('#include "rearc_engine_abi.h"\n#include <stdio.h>\nint main(void){\n'+''.join(f'printf("{t} %zu %zu\\n",sizeof({t}),_Alignof({t}));\n' for t in types)+'}\n')
layouts=[]
for name,include in (('old',old),('new',BRIDGE)):
 exe=root/name;subprocess.run(['xcrun','clang','-std=c11',f'-I{include}',str(c),'-o',str(exe)],check=True);layouts.append(subprocess.check_output([str(exe)]))
assert layouts[0]==layouts[1],layouts
print(layouts[1].decode(),end='');print('ABI 1.17 layouts preserved PASS')
recent=root/'abi-1.40';recent.mkdir()
for name in ('rearc_engine_abi.h','rearc_engine_entry_mac.h','module.modulemap'):
 (recent/name).write_bytes(subprocess.check_output(['git','-C',str(SRC),'show','a95beb7f31:chrome/browser/rearc_bridge/'+name]))
recent_types=re.findall(r'typedef struct (\w+)\s*\{',(recent/'rearc_engine_abi.h').read_text())
c.write_text('#include "rearc_engine_abi.h"\n#include <stdio.h>\nint main(void){\n'+''.join(f'printf("{name} %zu %zu\\n",sizeof({name}),_Alignof({name}));\n' for name in recent_types)+'}\n')
recent_layouts=[]
for name,include in (('recent',recent),('current',BRIDGE)):
 exe=root/name;subprocess.run(['xcrun','clang','-std=c11',f'-I{include}',str(c),'-o',str(exe)],check=True);recent_layouts.append(subprocess.check_output([str(exe)]))
assert recent_layouts[0]==recent_layouts[1],recent_layouts
print(f'ABI 1.40 layouts preserved PASS: {len(recent_types)} structs including extension request/state')

wave30=root/'abi-1.42';wave30.mkdir()
for name in ('rearc_engine_abi.h','rearc_engine_entry_mac.h','module.modulemap'):
 (wave30/name).write_bytes(subprocess.check_output(['git','-C',str(SRC),'show','768b683832:chrome/browser/rearc_bridge/'+name]))
wave30_types=re.findall(r'typedef struct (\w+)\s*\{',(wave30/'rearc_engine_abi.h').read_text())
c.write_text('#include "rearc_engine_abi.h"\n#include <stdio.h>\nint main(void){\n'+''.join(f'printf("{name} %zu %zu\\n",sizeof({name}),_Alignof({name}));\n' for name in wave30_types)+'}\n')
wave30_layouts=[]
for name,include in (('wave30',wave30),('current42',BRIDGE)):
 exe=root/name;subprocess.run(['xcrun','clang','-std=c11',f'-I{include}',str(c),'-o',str(exe)],check=True);wave30_layouts.append(subprocess.check_output([str(exe)]))
assert wave30_layouts[0]==wave30_layouts[1],wave30_layouts
print(f'ABI 1.42 layouts preserved PASS: {len(wave30_types)} structs including ReArcServiceEvent and ReArcKeyEquivalentEvent')

wave32=root/'abi-1.43';wave32.mkdir()
for name in ('rearc_engine_abi.h','rearc_engine_entry_mac.h','module.modulemap'):
 (wave32/name).write_bytes(subprocess.check_output(['git','-C',str(SRC),'show','106077933f:chrome/browser/rearc_bridge/'+name]))
wave32_types=re.findall(r'typedef struct (\w+)\s*\{',(wave32/'rearc_engine_abi.h').read_text())
c.write_text('#include "rearc_engine_abi.h"\n#include <stdio.h>\nint main(void){\n'+''.join(f'printf("{name} %zu %zu\\n",sizeof({name}),_Alignof({name}));\n' for name in wave32_types)+'}\n')
wave32_layouts=[]
for name,include in (('wave32',wave32),('current43',BRIDGE)):
 exe=root/name;subprocess.run(['xcrun','clang','-std=c11',f'-I{include}',str(c),'-o',str(exe)],check=True);wave32_layouts.append(subprocess.check_output([str(exe)]))
assert wave32_layouts[0]==wave32_layouts[1],wave32_layouts
print(f'ABI 1.43 layouts preserved PASS: {len(wave32_types)} structs including ReArcVideoOverlayEvent')

swift=root/'adoption.swift';swift.write_text('''import Foundation
import ReArcEngine
import AppKit
func configurePerf0() {
    guard ReArcEngineABIMinorVersion() >= 44 && ReArcEngineHasFeature("perf_metrics") else { return }
    ReArcEngineSetPageTimingCallback({ _, event in
        guard let e = event?.pointee else { return }
        _ = (e.profile_id, e.tab_id, e.content_generation, e.navigation_id, e.kind,
             Double(e.value_us - e.navigation_start_us) / 1000, e.size, e.url.map { String(cString: $0) })
    }, nil)
    ReArcEngineSetViewPresentationCallback({ _, event in
        guard let e = event?.pointee else { return }
        _ = (e.profile_id, e.tab_id, e.attachment_id, e.request_id, e.kind, e.status,
             e.start_us, e.activated_us, e.presented_us, e.width, e.height)
    }, nil)
    _ = ReArcMetricsGetHistogram("Browser.Tabs.TotalSwitchDuration3", { _, status, histogram in
        guard status == ReArcStatus(REARC_OK), let h = histogram?.pointee else { return }
        let buckets = UnsafeBufferPointer(start: h.buckets, count: h.bucket_count)
        _ = (String(cString: h.name), h.count, h.sum, buckets.map { ($0.min, $0.max, $0.count) })
    }, nil)
    _ = ReArcEngineGetProcesses({ _, status, processes, count in
        guard status == ReArcStatus(REARC_OK) else { return }
        for p in UnsafeBufferPointer(start: processes, count: count) {
            _ = (p.pid, p.type, p.name.map { String(cString: $0) }, p.profile_id, p.is_extension,
                 Array(UnsafeBufferPointer(start: p.tab_ids, count: p.tab_count)), p.phys_footprint, p.resident_size, p.cpu_time_us)
        }
    }, nil)
}
func configureWave32() {
    guard ReArcEngineABIMinorVersion() >= 43 && ReArcEngineHasFeature("pip_embedded") else { return }
    var actions: UInt32 = 0
    if ReArcTabGetMediaActions(1, &actions) == ReArcStatus(REARC_OK) {
        _ = (actions & UInt32(REARC_MEDIA_ACTION_PREVIOUS_TRACK) != 0, actions & UInt32(REARC_MEDIA_ACTION_NEXT_TRACK) != 0)
    }
    ReArcEngineSetVideoOverlayCallback({ _, event in
        guard let e = event?.pointee else { return }
        let view = e.view.map { Unmanaged<NSView>.fromOpaque($0).takeRetainedValue() }
        _ = (view, e.profile_id, e.tab_id, e.content_generation, e.kind, e.width, e.height, e.playback,
             e.buttons & UInt32(REARC_VIDEO_OVERLAY_BUTTON_PLAY_PAUSE), e.muted, e.microphone_muted, e.camera_on,
             e.duration, e.position, e.rate, e.title.map { String(cString: $0) })
        _ = ReArcVideoOverlayReadPixel(e.overlay_id, { _, status, rgba in _ = (status, rgba >> 8) }, nil)
        _ = ReArcVideoOverlaySetBounds(e.overlay_id, 0, 0, 320, 180)
        _ = ReArcVideoOverlaySeek(e.overlay_id, 1.5)
        _ = ReArcVideoOverlayAction(e.overlay_id, 7)
    }, nil)
}
func configureWave18h() {
    if ReArcEngineABIMinorVersion() >= 41 && ReArcEngineHasFeature("client_certificates") {
        ReArcEngineSetClientCertificateCallback({ _, event in
            guard let event, event.pointee.phase == 0 else { return }
            let e = event.pointee
            let identities = UnsafeBufferPointer(start: e.identities, count: e.identity_count)
            _ = (String(cString: e.origin), e.profile_id, e.tab_id, e.content_generation)
            for identity in identities {
                _ = (String(cString: identity.subject), String(cString: identity.issuer), identity.expiry_us)
            }
            if let first = identities.first {
                _ = ReArcClientCertificateRespond(e.request_id, first.fingerprint)
            } else {
                _ = ReArcClientCertificateRespond(e.request_id, nil)
            }
        }, nil)
    }
    if ReArcEngineABIMinorVersion() >= 40 && ReArcEngineHasFeature("devtools") {
        var frontend: UInt64 = 0
        _ = ReArcTabOpenDevTools(1, &frontend)
    }

    if ReArcEngineABIMinorVersion() >= 39 && ReArcEngineHasFeature("link_open_requests") {
        ReArcEngineSetLinkOpenCallback({ _, event in
            guard let event, event.pointee.phase == 0 else { return }
            let e = event.pointee
            _ = (String(cString: e.url), String(cString: e.referrer), e.referrer_policy, e.disposition, e.opener_tab_id)
            _ = ReArcLinkOpenRespond(e.request_id, 0)
        }, nil)
    }
    if ReArcEngineABIMinorVersion() >= 36 && ReArcEngineHasFeature("extension_windows") {
        var state = ReArcExtensionTabState()
        _ = ReArcTabSetExtensionWindow(1, 1, true, true)
        _ = ReArcTabGetExtensionState(1, &state)
        ReArcEngineSetExtensionTabRequestCallback({ _, event in
            guard let event, event.pointee.phase == 0 else { return }
            let e = event.pointee
            _ = (String(cString: e.url), String(cString: e.extension_id), e.kind, e.active, e.opener_tab_id, e.window_id)
            var tab: UInt64 = e.tab_id
            if e.kind != 3 { _ = ReArcTabCreate(e.profile_id, 1, "about:blank", &tab) }
            _ = ReArcTabSetExtensionWindow(tab, 1, e.active, true)
            _ = ReArcExtensionTabRequestRespond(e.request_id, tab)
        }, nil)
    }
    if ReArcEngineABIMinorVersion() >= 37 && ReArcEngineHasFeature("autofill_save_prompts") {
        ReArcEngineSetAutofillSaveCallback({ _, event in
            guard let event, event.pointee.phase == 0 else { return }
            let e = event.pointee
            _ = (String(cString: e.origin), String(cString: e.summary), e.kind, e.update)
            _ = ReArcAutofillSaveRespond(e.request_id, 0)
        }, nil)
    }
    if ReArcEngineABIMinorVersion() >= 38 && ReArcEngineHasFeature("http_auth") {
        ReArcEngineSetHttpAuthCallback({ _, event in
            guard let event, event.pointee.phase == 0 else { return }
            let e = event.pointee
            _ = (String(cString: e.challenger), String(cString: e.scheme), String(cString: e.realm), e.is_proxy)
            _ = ReArcHttpAuthRespond(e.request_id, false, "username", "password")
        }, nil)
    }
}
func configureWave18f() {
    if ReArcEngineABIMinorVersion() >= 31 && ReArcEngineHasFeature("extension_tab_helpers") {
        // No new symbols: registry tabs carry Chromium's extension tab helpers.
    }
    if ReArcEngineABIMinorVersion() >= 32 && ReArcEngineHasFeature("extension_install_prompts") {
        ReArcEngineSetExtensionPromptCallback({ _, event in
            guard let event else { return }
            let e = event.pointee
            if e.phase == 0 {
                _ = (String(cString: e.extension_id), String(cString: e.title), e.kind == 100)
                let permissions = UnsafeBufferPointer(start: e.permissions, count: e.permission_count)
                for p in permissions { if let p { _ = String(cString: p) } }
                if let icon = e.icon_png { _ = Data(bytes: icon, count: e.icon_png_size) }
                _ = ReArcExtensionPromptRespond(e.request_id, 1)
            } else if e.phase == 3 {
                _ = String(cString: e.error)
            }
        }, nil)
    }
    if ReArcEngineABIMinorVersion() >= 33 && ReArcEngineHasFeature("extension_actions") {
        ReArcEngineSetExtensionActionCallback({ _, event in
            guard let event else { return }
            if event.pointee.kind == 3 { _ = (event.pointee.popup_tab_id, event.pointee.width, event.pointee.height) }
        }, nil)
        _ = ReArcTabGetExtensionActions(1, 2, { _, status, list in
            guard status == REARC_OK, let list else { return }
            let actions = UnsafeBufferPointer(start: list.pointee.actions, count: list.pointee.count)
            for a in actions {
                _ = (String(cString: a.title), String(cString: a.badge_text), a.badge_background_color, a.visible, a.has_popup, a.wants_to_run)
                if let icon = a.icon_png { _ = Data(bytes: icon, count: a.icon_png_size) }
            }
        }, nil)
        var result: UInt32 = 0
        var popup: UInt64 = 0
        _ = ReArcTabRunExtensionAction(1, "abcdefghijklmnopabcdefghijklmnop", &result, &popup)
    }
    if ReArcEngineABIMinorVersion() >= 34 && ReArcEngineHasFeature("autofill_suggestions") {
        ReArcEngineSetAutofillCallback({ _, event in
            guard let event else { return }
            let e = event.pointee
            switch e.phase {
            case 0:
                let rows = UnsafeBufferPointer(start: e.suggestions, count: e.suggestion_count)
                for r in rows { _ = (String(cString: r.value), String(cString: r.label), String(cString: r.icon), r.kind, r.acceptable) }
                _ = (e.x, e.y, e.width, e.height, e.product, e.selected)
                _ = ReArcAutofillSelect(e.request_id, -1)
                _ = ReArcAutofillAccept(e.request_id, 0)
            case 3:
                _ = String(cString: e.settings_url)
            default:
                break
            }
        }, nil)
        _ = ReArcAutofillDismiss(1)
        _ = ReArcAutofillManage(1)
    }
    if ReArcEngineABIMinorVersion() >= 35 && ReArcEngineHasFeature("password_leak_detection") {
        var enabled = false
        var managed = false
        if ReArcProfileGetPasswordLeakDetection(1, &enabled, &managed) == REARC_OK && !managed {
            _ = ReArcProfileSetPasswordLeakDetection(1, false)
        }
    }
}
func configureWave18e() {
    if ReArcEngineABIMinorVersion() >= 26 && ReArcEngineHasFeature("search_autocomplete") {
        _ = ReArcSearchGetDefaultProvider(1, { _, status, _, provider in
            if status == REARC_OK, let provider {
                _ = String(cString: provider.pointee.search_url)
                _ = provider.pointee.is_managed
            }
        }, nil)
        "ReArc".withCString { name in "rearc".withCString { keyword in
            "https://search.example/?q=%s".withCString { search in
                var provider = ReArcSearchProvider(name: name, keyword: keyword, search_url: search,
                                                   suggest_url: nil, is_managed: false, is_prepopulated: false)
                _ = ReArcSearchSetDefaultProvider(1, &provider, { _, _, _ in }, nil)
            }
        }}
        _ = ReArcSearchClassifyInput(1, "example.com", { _, status, _, result in
            if status == REARC_OK, let result, result.pointee.kind == 1 {
                _ = String(cString: result.pointee.destination_url)
            }
        }, nil)
        var query: UInt64 = 0
        _ = ReArcAutocompleteStart(1, "rearc", 0, { _, result in
            guard let result else { return }
            let matches = UnsafeBufferPointer(start: result.pointee.matches, count: result.pointee.count)
            for match in matches { _ = (match.kind, match.relevance, String(cString: match.destination_url)) }
            _ = (result.pointee.query_id, result.pointee.done, result.pointee.status == REARC_CANCELLED)
        }, nil, &query)
        _ = ReArcAutocompleteStop(1)
    }
    if ReArcEngineABIMinorVersion() >= 27 && ReArcEngineHasFeature("html_fullscreen") {
        ReArcEngineSetFullscreenCallback({ _, event in
            guard let event else { return }
            _ = (event.pointee.phase, event.pointee.reason, event.pointee.display_id)
        }, nil)
        var fullscreen = false
        _ = ReArcTabGetFullscreenState(1, &fullscreen)
        _ = ReArcTabExitFullscreen(1)
    }
    if ReArcEngineABIMinorVersion() >= 28 && ReArcEngineHasFeature("printing") {
        ReArcEngineSetPrintCallback({ _, event in
            guard let event else { return }
            var options = ReArcPrintOptions()
            options.margin_top_in = -1; options.margin_bottom_in = -1
            options.margin_left_in = -1; options.margin_right_in = -1
            _ = ReArcTabPrintToPDF(event.pointee.tab_id, &options, { _, status, _, _, data, size in
                if status == REARC_OK, let data { _ = Data(bytes: data, count: size) }
                ReArcBufferFree(data)
            }, nil)
        }, nil)
    }
    if ReArcEngineABIMinorVersion() >= 29 && ReArcEngineHasFeature("page_drops") {
        "com.rearc.sidebar-item".withCString { type in
            var blocked: [UnsafePointer<CChar>?] = [type]
            _ = ReArcEngineSetDropPolicy(UInt32(REARC_DROP_FILES | REARC_DROP_TEXT | REARC_DROP_URLS | REARC_DROP_IMAGES), &blocked, 1)
        }
    }
    if ReArcEngineABIMinorVersion() >= 30 && ReArcEngineHasFeature("picture_in_picture") {
        ReArcEngineSetPictureInPictureCallback({ _, event in
            guard let event else { return }
            if event.pointee.phase == 2 { _ = ReArcTabActivate(event.pointee.tab_id) }
        }, nil)
        _ = ReArcTabSetPictureInPicture(1, true)
    }
}
func configurePrompts() {
    if ReArcEngineABIMinorVersion() >= 23 && ReArcEngineHasFeature("history_query") {
        _ = ReArcHistoryQuery(1, "", 25, { _, status, profile, entries, count in
            if status == REARC_OK, count > 0, let entries {
                _ = String(cString: entries.pointee.url)
                _ = entries.pointee.visit_time_us
                _ = profile
            }
        }, nil)
        _ = ReArcHistoryDeleteURL(1, "https://example.test/", { _, _, _ in }, nil)
        _ = ReArcHistoryDeleteRange(1, 0, 0, { _, _, _ in }, nil)
    }
    if ReArcEngineABIMinorVersion() >= 24 && ReArcEngineHasFeature("dangerous_downloads") {
        var warning = ReArcDownloadWarning()
        _ = ReArcDownloadGetWarning(1, 1, &warning)
        _ = ReArcDownloadResolveDanger(1, 1, 0)
    }
    if ReArcEngineABIMinorVersion() >= 25 && ReArcEngineHasFeature("tab_discard") {
        var discarded = false
        _ = ReArcTabGetDiscardState(1, &discarded)
        _ = ReArcTabDiscard(1)
    }
    if ReArcEngineABIMinorVersion() >= 18 && ReArcEngineHasFeature("javascript_dialogs") {
        ReArcEngineSetJavaScriptDialogCallback({ _, event in
            guard let event, event.pointee.phase == 0 else { return }
            _ = ReArcJavaScriptDialogRespond(event.pointee.request_id, false, nil)
        }, nil)
    }
    if ReArcEngineABIMinorVersion() >= 19 && ReArcEngineHasFeature("file_chooser") {
        ReArcEngineSetFileChooserCallback({ _, event in
            guard let event, event.pointee.phase == 0 else { return }
            _ = ReArcFileChooserRespond(event.pointee.request_id, true, nil, 0)
        }, nil)
    }
    if ReArcEngineABIMinorVersion() >= 20 && ReArcEngineHasFeature("permission_prompts") {
        ReArcEngineSetPermissionCallback({ _, event in
            guard let event, event.pointee.phase == 0 else { return }
            _ = ReArcPermissionRespond(event.pointee.request_id, 2, false)
        }, nil)
    }
    if ReArcEngineABIMinorVersion() >= 21 && ReArcEngineHasFeature("context_menu") {
        ReArcEngineSetContextMenuCallback({ _, event in
            guard let event, event.pointee.phase == 0 else { return }
            _ = ReArcContextMenuCommand(event.pointee.request_id, 12)
        }, nil)
    }
    if ReArcEngineABIMinorVersion() >= 22 && ReArcEngineHasFeature("password_prompts") {
        ReArcEngineSetPasswordPromptCallback({ _, event in
            guard let event, event.pointee.phase == 0 else { return }
            _ = ReArcPasswordPromptRespond(event.pointee.request_id, 2)
        }, nil)
    }
}
''')
subprocess.run(['xcrun','swiftc','-typecheck',f'-I{BRIDGE}',str(swift)],check=True)
print('Swift gated perf-0 page timing/presentation/histograms/processes, wave 32 media actions/embedded video overlay, wave 18h DevTools/client certificates, wave 18g windows/save/auth/links and wave 18f extension prompt/action/popup, autofill and leak-detection, wave 18e search/fullscreen/print/drop/PiP, history/download/discard and prompt adoption PASS')
print('Legacy headers retained at',old)
