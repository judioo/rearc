#!/usr/bin/env python3
"""Preserve every ABI 1.17 struct layout and typecheck the exact Swift entry."""
from pathlib import Path
import re,subprocess,tempfile
from run_c_abi import SRC,BRIDGE,build_gate
build_gate()
root=Path(tempfile.mkdtemp(prefix='rearc-w18f-import-'))
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
swift=root/'adoption.swift';swift.write_text('''import Foundation
import ReArcEngine
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
print('Swift gated wave 18f extension prompt/action/popup, autofill and leak-detection, wave 18e search/fullscreen/print/drop/PiP, history/download/discard and prompt adoption PASS')
print('Legacy headers retained at',old)
