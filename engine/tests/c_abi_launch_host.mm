#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
// launch (early_window, ABI 1.45): the callback runs once inside Run, once
// NSApplication, its delegate and menu exist and before ready; nothing else
// is available there. A window ordered front and flushed in it stays up and
// hosts a tab after ready. The callback is settable only between Configure
// and Run. No input.
static NSWindow* window;
static int early_calls;
static double main_at, early_at, ready_at;
static bool stopped;
static void early(void* context) {
  assert(context == &early_calls);
  ++early_calls;
  early_at = CACurrentMediaTime();
  assert([NSThread isMainThread] && NSApp && NSApp.delegate && NSApp.mainMenu);
  assert(ReArcEngineSetEarlyWindowCallback(early, &early_calls) == REARC_INVALID_STATE);
  assert(ReArcEngineDefaultProfile() == 0);
  uint64_t tab = 1;
  assert(ReArcTabCreate(1, 1, "about:blank", &tab) == REARC_ENGINE_NOT_READY && tab == 0);
  assert(ReArcEngineHasFeature("early_window") && ReArcEngineABIMinorVersion() >= 45);
  window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  window.contentView.wantsLayer = YES;
  window.contentView.layer.backgroundColor = NSColor.systemBlueColor.CGColor;
  [window makeKeyAndOrderFront:nil];
  [window displayIfNeeded];
  [CATransaction flush];
  assert(window.isVisible);
  printf("LAUNCH early_window %.1f ms after main: application exists, engine not ready, window ordered front PASS\n",
         (early_at - main_at) * 1000);
}
static void ready(void*, uint64_t p) {
  ready_at = CACurrentMediaTime();
  assert(early_calls == 1 && early_at < ready_at && window.isVisible);
  printf("LAUNCH ready %.1f ms after the early window, which is still up PASS\n", (ready_at - early_at) * 1000);
  assert(ReArcWindowRegister(1, (__bridge void*)window) == 0);
  uint64_t tab = 0;
  assert(ReArcTabCreate(p, 1, "about:blank", &tab) == 0);
  ReArcAttachment lease{};
  assert(ReArcViewAttach(tab, 1, 400, 300, window.backingScaleFactor, &lease) == 0);
  [window.contentView addSubview:(__bridge NSView*)lease.native_view];
  ReArcViewRelease(lease.native_view);
  puts("LAUNCH the early window hosts a tab after ready PASS");
  assert(ReArcEngineShutdown(true, [](void*, ReArcStatus s, bool c) { assert(s == 0 && !c); stopped = true; }, nullptr) == 0);
}
int main(int argc, const char** argv) { @autoreleasepool {
  setbuf(stdout, nullptr);
  main_at = CACurrentMediaTime();
  assert(ReArcEngineSetEarlyWindowCallback(early, &early_calls) == REARC_INVALID_STATE);
  ReArcCallbacks c{ready, [](void*, const ReArcTabEvent*) {}, nullptr, nullptr};
  assert(ReArcEngineConfigure(1, &c, nullptr) == 0);
  assert(ReArcEngineSetEarlyWindowCallback(nullptr, nullptr) == REARC_OK);
  assert(ReArcEngineSetEarlyWindowCallback(early, &early_calls) == REARC_OK);
  int r = ReArcEngineRun(argc, argv);
  assert(r == 0 && stopped && early_calls == 1);
  puts("LAUNCH early_window ran exactly once and Run returned cleanly PASS");
  return r;
}}
