#!/usr/bin/env python3
"""Preserve every ABI 1.17 struct layout and typecheck the exact Swift entry."""
from pathlib import Path
import re,subprocess,tempfile
from run_c_abi import SRC,BRIDGE,build_gate
build_gate()
root=Path(tempfile.mkdtemp(prefix='rearc-w18-import-'))
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
print('Swift gated wave 18e search/fullscreen/print/drop/PiP, history/download/discard and prompt adoption PASS')
print('Legacy headers retained at',old)
