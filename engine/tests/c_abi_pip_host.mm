#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <functional>
#include <string>
#include "c_abi_test_devtools.h"
// step 0 page request refused without callback; 1 page enter, host exit;
// 2 host enter via media session; 3 back to tab; 4 host enter, close.
static uint64_t tab, profile;
static NSWindow* window;
static ReArcAttachment lease{};
static std::string base;
static int step, entered, exited, focused;
static bool stopped, started, available, active_seen;
static void after(double s, std::function<void()> f) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(s * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ f(); }); }
static NSPoint point() { return [(__bridge NSView*)lease.native_view convertPoint:NSMakePoint(30, 270) toView:nil]; }
static void click() {
  for (auto type : {NSEventTypeLeftMouseDown, NSEventTypeLeftMouseUp}) {
    NSEvent* e = [NSEvent mouseEventWithType:type location:point() modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
    NSView* hit = [window.contentView hitTest:point()];
    if (type == NSEventTypeLeftMouseDown) [hit mouseDown:e]; else [hit mouseUp:e];
  }
}
static NSWindow* pip_window() {
  for (NSWindow* w in NSApp.windows)
    if (w.visible && [NSStringFromClass([w class]) hasPrefix:@"NativeWidgetMac"]) return w;
  return nil;
}
static void back_to_tab() {
  NSWindow* w = pip_window();
  printf("PIP overlay window=%s\n", w ? NSStringFromClass([w class]).UTF8String : "missing");
  assert(w);
  // Controls are hidden (and absent from AX) until the pointer is over them.
  NSPoint center = NSMakePoint(NSWidth(w.contentView.bounds) / 2, NSHeight(w.contentView.bounds) / 2);
  for (auto type : {NSEventTypeMouseEntered, NSEventTypeMouseMoved}) {
    NSEvent* e = type == NSEventTypeMouseMoved
        ? [NSEvent mouseEventWithType:type location:center modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:0 pressure:0]
        : [NSEvent enterExitEventWithType:type location:center modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:w.windowNumber context:nil eventNumber:0 trackingNumber:0 userData:nullptr];
    if (type == NSEventTypeMouseMoved) [w.contentView mouseMoved:e]; else [w.contentView mouseEntered:e];
  }
  // OverlayWindowBackToTabButton: 24px, 28px from the right, 5px from top.
  after(0.7, [w] {
    NSPoint button = NSMakePoint(NSWidth(w.contentView.bounds) - 40, NSHeight(w.contentView.bounds) - 17);
    printf("PIP back-to-tab click at %.0f,%.0f in %.0fx%.0f\n", button.x, button.y, NSWidth(w.contentView.bounds), NSHeight(w.contentView.bounds));
    for (auto type : {NSEventTypeMouseMoved, NSEventTypeLeftMouseDown, NSEventTypeLeftMouseUp}) {
      NSEvent* e = [NSEvent mouseEventWithType:type location:button modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:w.windowNumber context:nil eventNumber:1 clickCount:type == NSEventTypeMouseMoved ? 0 : 1 pressure:type == NSEventTypeLeftMouseDown ? 1 : 0];
      if (type == NSEventTypeMouseMoved) [w.contentView mouseMoved:e];
      else if (type == NSEventTypeLeftMouseDown) [w.contentView mouseDown:e];
      else [w.contentView mouseUp:e];
    }
  });
}
static void closed(void*, ReArcStatus s, bool c) {
  assert(s == 0 && !c && entered == 3 && exited == 3 && focused == 1 && active_seen);
  ReArcViewRelease(lease.native_view);
  assert(ReArcEngineShutdown(true, [](void*, ReArcStatus s, bool c) { assert(s == 0 && !c); stopped = true;
    puts("PIP refusal + page/host enter + host exit + back-to-tab + close while active PASS"); }, nullptr) == 0);
  test_cdp::close_browser();
}
static void host_enter() {
  assert(ReArcTabSetPictureInPicture(tab, true) == REARC_OK);
}
static void pip(void*, const ReArcPictureInPictureEvent* e) {
  printf("PIP step=%d phase=%u gen=%llu\n", step, e->phase, e->content_generation);
  assert(e->tab_id == tab && e->profile_id == profile && e->content_generation == 1 && step > 0);
  if (e->phase == 0) {
    ++entered;
    assert(ReArcTabSetPictureInPicture(tab, true) == REARC_OK);  // Already active.
    if (step == 1) assert(ReArcTabSetPictureInPicture(tab, false) == REARC_OK);
    else if (step == 2) { step = 3; after(0.5, back_to_tab); }
    else if (step == 3) assert(false);
    else if (step == 4) assert(ReArcTabClose(tab, true, closed, nullptr) == 0);
    return;
  }
  if (e->phase == 2) { assert(step == 3); ++focused; step = 4; after(0.5, host_enter); return; }
  ++exited;
  if (step == 1) {
    after(0.3, [] {
      assert(ReArcTabSetPictureInPicture(tab, false) == REARC_INVALID_STATE);
      // Not offered for the MediaStream player (Chromium one-shot player).
      assert(!available && ReArcTabSetPictureInPicture(tab, true) == REARC_INVALID_STATE);
      assert(ReArcTabEvaluateScript2(tab, "toFile()", 1, nullptr, 20000, [](void*, const ReArcScriptResult* r) {
        assert(r->status == 0); step = 2; if (available) host_enter();
        after(3, [] { assert(ReArcTabEvaluateScript2(tab, "JSON.stringify({p:v.paused,e:v.ended,err:v.error&&v.error.code,t:v.currentTime,d:v.duration,rs:v.readyState,a:v.audioTracks?v.audioTracks.length:-1,src:!!v.src})", 1, nullptr, 5000, [](void*, const ReArcScriptResult* r) { printf("PIP file state %d %s\n", r->status, r->json); }, nullptr) == 0); });
      }, nullptr) == 0);
    });
  }
}
static void service(void*, const ReArcServiceEvent* e) {
  if (e->tab_id != tab || e->kind != 1) return;
  printf("PIP media step=%d available=%d active=%d playback=%u\n", step, e->pip_available, e->pip_active, e->playback);
  if (e->pip_active) active_seen = true;
  if (e->pip_available && !available) { available = true; if (step == 2) host_enter(); }
  if (!e->pip_available) available = false;
}
static void event(void*, const ReArcTabEvent* e) {
  if (e->tab_id != tab || e->kind != 1 || !(e->changes & 2)) return;
  std::string t = e->title;
  printf("TITLE step=%d %s\n", step, t.c_str());
  if (t == "pip:ready" && !started) { started = true; test_cdp::focus(base, [] { after(0.3, click); }); }
  else if (t == "pip:err:NotSupportedError") {
    assert(step == 0 && !entered);
    ReArcEngineSetPictureInPictureCallback(pip, nullptr);
    step = 1;
    assert(ReArcTabEvaluateScript2(tab, "document.title='pip:ready1';true", 1, nullptr, 5000, [](void*, const ReArcScriptResult* r) { assert(r->status == 0); after(0.3, click); }, nullptr) == 0);
  }
}
static void ready(void*, uint64_t p) {
  profile = p;
  assert(ReArcEngineABIMinorVersion() >= 30 && ReArcEngineHasFeature("picture_in_picture"));
  ReArcEngineSetServiceCallback(service, nullptr);
  assert(ReArcTabCreate(p, 1, (base + "/pip").c_str(), &tab) == 0);
  assert(ReArcTabSetPictureInPicture(tab, true) == REARC_UNSUPPORTED);
  window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  assert(ReArcWindowRegister(1, (__bridge void*)window) == 0);
  assert(ReArcViewAttach(tab, 1, 400, 300, 1, &lease) == 0);
  [window.contentView addSubview:(__bridge NSView*)lease.native_view];
  [window makeKeyAndOrderFront:nil];
  assert(ReArcViewSetVisible(tab, lease.attachment_id, true) == 0);
}
int main(int argc, const char** argv) { @autoreleasepool {
  setbuf(stdout, nullptr);
  test_cdp::initialize(argc, argv);
  base = "http://127.0.0.1:" + std::string(getenv("REARC_TEST_PORT"));
  ReArcCallbacks c{ready, event, nullptr, nullptr};
  assert(ReArcEngineConfigure(1, &c, nullptr) == 0);
  int r = ReArcEngineRun(argc, argv); assert(r == 0 && stopped); return r;
}}
