#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <string>
#include "c_abi_test_devtools.h"

// Wave 18f password_leak_detection. Phase 1 (default, leak detection on) and
// phase 2 (REARC_LEAK_SECOND: turned off through the ABI in phase 1's
// profile, read back after reopening) each submit a sign-in like the
// passwords host. run_c_abi.py maps every non-loopback name to NOTFOUND
// (NO_OUTSIDE_NETWORK), so Chromium's leak check can only fail locally, and
// reads the
// per-phase net log: phase 1 shows whether Chromium attempted the check,
// phase 2 must show no attempt. Both phases use --use-mock-keychain.
static uint64_t tab, profile;
static NSWindow* window;
static ReArcAttachment lease{};
static std::string base, committed_url;
static bool stopped, prepared, submitted, second;
static void click(void*, ReArcStatus s, uint64_t, uint64_t, uint8_t* png, size_t) {
  assert(s == 0);
  ReArcBufferFree(png);
  NSPoint point = [(__bridge NSView*)lease.native_view convertPoint:NSMakePoint(30, 50) toView:nil];
  for (auto type : {NSEventTypeLeftMouseDown, NSEventTypeLeftMouseUp}) {
    NSEvent* e = [NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
    NSView* hit = [window.contentView hitTest:point];
    if (type == NSEventTypeLeftMouseDown) [hit mouseDown:e]; else [hit mouseUp:e];
  }
}
static void type_input(const char* selector, std::string text, std::function<void()> done) {
  NSString* expression = [NSString stringWithFormat:@"document.querySelector('%s').focus()", selector];
  test_cdp::command(@"Runtime.evaluate", @{@"expression":expression}, [text, done] {
    test_cdp::command(@"Input.insertText", @{@"text":[NSString stringWithUTF8String:text.c_str()]}, done);
  });
}
static void submit() {
  test_cdp::focus(base + "/login", [] {
    type_input("#u", second ? "leak-off" : "leak-on", [] {
      type_input("#p", "leak-password", [] { assert(ReArcTabCaptureSnapshot(tab, 0, click, nullptr) == 0); });
    });
  });
}
static void finish() {
  if (!second) {
    // Phase 2 reopens this profile with the check off (persisted pref).
    assert(ReArcProfileSetPasswordLeakDetection(profile, false) == REARC_OK);
  }
  assert(ReArcEngineShutdown(true, [](void*, ReArcStatus s, bool c) {
    assert(s == 0 && !c);
    ReArcViewRelease(lease.native_view);
    stopped = true;
    printf("LEAK phase %s PASS\n", second ? "off" : "on");
  }, nullptr) == 0);
  test_cdp::close_browser();
}
static void event(void*, const ReArcTabEvent* e) {
  if (e->tab_id != tab) return;
  if (e->kind == 3 && e->is_main_frame && !e->is_same_document) { committed_url = e->url; prepared = false; }
  if (e->kind != 1 || !(e->changes & 4) || e->is_loading || prepared) return;
  prepared = true;
  if (committed_url == base + "/login") {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ submit(); });
  } else if (committed_url.starts_with(base + "/welcome") && !submitted) {
    submitted = true;
    printf("LEAK signed in %s\n", committed_url.c_str());
    // Chromium starts a leak check on the successful-login commit; give it
    // time to reach the (unresolvable) network before shutting down.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ finish(); });
  }
}
static void ready(void*, uint64_t p) {
  profile = p;
  assert(ReArcEngineABIMinorVersion() >= 35 && ReArcEngineHasFeature("password_leak_detection"));
  bool enabled = false, managed = true;
  assert(ReArcProfileGetPasswordLeakDetection(p, nullptr, &managed) == REARC_INVALID_ARGUMENT);
  assert(ReArcProfileGetPasswordLeakDetection(999, &enabled, &managed) == REARC_PROFILE_NOT_FOUND);
  assert(ReArcProfileSetPasswordLeakDetection(999, false) == REARC_PROFILE_NOT_FOUND);
  assert(ReArcProfileGetPasswordLeakDetection(p, &enabled, &managed) == REARC_OK && !managed);
  printf("LEAK ready enabled=%d managed=%d second=%d\n", enabled, managed, second);
  if (second) {
    assert(!enabled);  // Persisted by phase 1.
    puts("LEAK disabled setting persisted across reopen PASS");
  } else {
    assert(enabled);  // Chrome's default.
    // Round trip, then leave it on for this phase's sign-in.
    assert(ReArcProfileSetPasswordLeakDetection(p, false) == REARC_OK);
    assert(ReArcProfileGetPasswordLeakDetection(p, &enabled, &managed) == REARC_OK && !enabled);
    assert(ReArcProfileSetPasswordLeakDetection(p, true) == REARC_OK);
    assert(ReArcProfileGetPasswordLeakDetection(p, &enabled, &managed) == REARC_OK && enabled);
    puts("LEAK default on, get/set round trip PASS");
  }
  assert(ReArcProfileCreateOffTheRecord(p, [](void*, ReArcStatus s, uint64_t otr, bool) {
    assert(s == 0);
    bool enabled, managed;
    assert(ReArcProfileGetPasswordLeakDetection(otr, &enabled, &managed) == REARC_UNSUPPORTED);
    assert(ReArcProfileSetPasswordLeakDetection(otr, false) == REARC_UNSUPPORTED);
    puts("LEAK off-the-record profile unsupported PASS");
    assert(ReArcTabCreate(profile, 1, (base + "/login").c_str(), &tab) == 0);
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    assert(ReArcWindowRegister(1, (__bridge void*)window) == 0);
    [window makeKeyAndOrderFront:nil];
    assert(ReArcViewAttach(tab, 1, 400, 300, 1, &lease) == 0);
    [window.contentView addSubview:(__bridge NSView*)lease.native_view];
    assert(ReArcViewSetVisible(tab, lease.attachment_id, true) == 0);
  }, nullptr) == REARC_OK);
}
int main(int argc, const char** argv) { @autoreleasepool {
  setbuf(stdout, nullptr);
  test_cdp::initialize(argc, argv);
  second = getenv("REARC_LEAK_SECOND") != nullptr;
  base = "http://127.0.0.1:" + std::string(getenv("REARC_TEST_PORT"));
  ReArcCallbacks c{ready, event, nullptr, nullptr};
  assert(ReArcEngineConfigure(1, &c, nullptr) == 0);
  int r = ReArcEngineRun(argc, argv);
  assert(r == 0 && stopped);
  return r;
}}
