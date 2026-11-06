#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <functional>
#include <string>
// Wave 32 (pip_embedded, ABI 1.43): with a video overlay callback, PiP renders
// into an engine NSView the host parents. Steps: 1 recorded WebM plays and the
// media actions offer PiP; host enter -> created (+1 view) and shown; bounds,
// natural size, pixels read back advancing while the tab's view is hidden; 2 pause and
// 3 play through the overlay; 4 back to tab -> hidden + PiP phase 2; 5 enter
// again on the same overlay; 6 tab close -> hidden then closed. No input.
static uint64_t tab, profile, overlay;
static NSWindow* window;
static NSWindow* pip_window;
static NSView* video;
static ReArcAttachment lease{};
static std::string base;
static int step, shown, hidden, focused, entered;
static bool stopped, requested, natural, closed_seen, tab_closed, available;
static uint32_t pixels[4];
static int pixel_reads;
static void after(double s, std::function<void()> f) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(s * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ f(); }); }
// Four reads of the view's composited centre pixel, 0.5 s apart: the video
// (not black) and changing (the fixture's colour changes every 50 ms).
static void read_pixel() {
  assert(ReArcVideoOverlayReadPixel(overlay, [](void*, ReArcStatus s, uint32_t rgba) {
    printf("PIP EMBEDDED pixel %d status=%d rgba=%08X\n", pixel_reads, s, rgba);
    assert(s == REARC_OK);
    pixels[pixel_reads++] = rgba;
    if (pixel_reads < 4) { after(0.5, read_pixel); return; }
    bool changed = false, video = false;
    for (int i = 0; i < 4; ++i) {
      changed |= pixels[i] != pixels[0];
      video |= ((pixels[i] >> 8) & 0xFFFFFF) > 0x101010;
    }
    assert(changed && video);
    puts("PIP EMBEDDED frames advance in the view while the tab is hidden PASS");
    step = 2;
    assert(ReArcVideoOverlayAction(overlay, 11) == REARC_OK);  // pause
  }, nullptr) == REARC_OK);
}
static void finish() {
  assert(closed_seen && tab_closed && shown == 2 && hidden == 2 && focused == 1 && entered == 2 && natural);
  assert(ReArcVideoOverlayAction(overlay, 0) == REARC_NOT_FOUND);
  ReArcViewRelease(lease.native_view);
  assert(ReArcEngineShutdown(true, [](void*, ReArcStatus s, bool c) { assert(s == 0 && !c); stopped = true;
    puts("PIP EMBEDDED media actions + created/shown + bounds + frames while hidden + pause/play + back to tab + reuse + close PASS"); }, nullptr) == 0);
}
static void enter() {
  assert(ReArcTabSetPictureInPicture(tab, true) == REARC_OK);
}
// The recorded file plays (step 1) and PiP is available, in either order.
static void enter_when_ready() {
  if (step != 1 || !available || requested) return;
  requested = true;
  enter();
}
static void overlay_event(void*, const ReArcVideoOverlayEvent* e) {
  if (e->kind != 6) printf("OVERLAY step=%d kind=%u id=%llu playback=%u buttons=0x%x\n", step, e->kind, e->overlay_id, e->playback, e->buttons);
  assert(e->tab_id == tab && e->profile_id == profile && e->content_generation == 1);
  switch (e->kind) {
    case 0:
      assert(step == 1 && !overlay && e->view);
      overlay = e->overlay_id;
      video = (__bridge_transfer NSView*)e->view;
      pip_window = [[NSWindow alloc] initWithContentRect:NSMakeRect(520, 0, 320, 180) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
      video.frame = pip_window.contentView.bounds;
      [pip_window.contentView addSubview:video];
      [pip_window orderFront:nil];
      return;
    case 1:
      assert(e->overlay_id == overlay);
      ++shown;
      if (shown == 1) {
        assert(step == 1);
        assert(ReArcVideoOverlaySetBounds(overlay, 0, 0, 0, 180) == REARC_INVALID_ARGUMENT);
        assert(ReArcVideoOverlaySetBounds(overlay + 1000, 520, 0, 320, 180) == REARC_NOT_FOUND);
        assert(ReArcVideoOverlaySetBounds(overlay, 520, 0, 320, 180) == REARC_OK);
        assert(ReArcVideoOverlayAction(overlay, 99) == REARC_INVALID_ARGUMENT);
        // The tab's own view is hidden: the video still renders, into this view.
        assert(ReArcViewSetVisible(tab, lease.attachment_id, false) == 0);
        assert(ReArcVideoOverlayReadPixel(overlay, nullptr, nullptr) == REARC_INVALID_ARGUMENT);
        assert(ReArcVideoOverlayReadPixel(overlay + 1000, [](void*, ReArcStatus, uint32_t) { assert(false); }, nullptr) == REARC_NOT_FOUND);
        after(1.0, read_pixel);
      } else {
        assert(step == 5);
        step = 6;
        after(1.0, [] { assert(ReArcTabClose(tab, true, [](void*, ReArcStatus s, bool c) {
          assert(s == 0 && !c); tab_closed = true; after(1.0, finish); }, nullptr) == 0); });
      }
      return;
    case 2:
      assert(e->overlay_id == overlay);
      ++hidden;
      if (hidden == 1) {
        assert(step == 4 && ReArcVideoOverlayAction(overlay, 0) == REARC_INVALID_STATE);
      } else {
        // Tab close: the overlay may already be gone with its controller.
        assert(step == 6);
        ReArcStatus late = ReArcVideoOverlayAction(overlay, 0);
        assert(late == REARC_INVALID_STATE || late == REARC_NOT_FOUND);
      }
      return;
    case 3:
      assert(e->overlay_id == overlay && step == 6 && hidden == 2);
      closed_seen = true;
      [video removeFromSuperview];
      video = nil;
      return;
    case 4:
      assert(e->width > 0 && e->height > 0);
      natural = true;
      return;
    case 5:
      assert(e->buttons & REARC_VIDEO_OVERLAY_BUTTON_PLAY_PAUSE);
      if (step == 2 && e->playback == 1) { step = 3; assert(ReArcVideoOverlayAction(overlay, 10) == REARC_OK); }
      else if (step == 3 && e->playback == 0) { step = 4; assert(ReArcVideoOverlayAction(overlay, 7) == REARC_OK); }
      return;
    default:
      return;
  }
}
static void pip(void*, const ReArcPictureInPictureEvent* e) {
  printf("PIP step=%d phase=%u\n", step, e->phase);
  assert(e->tab_id == tab);
  if (e->phase == 0) ++entered;
  if (e->phase == 2) {
    assert(step == 4 && hidden == 1);
    ++focused;
    step = 5;
    after(0.5, enter);
  }
}
static void service(void*, const ReArcServiceEvent* e) {
  if (e->tab_id != tab || e->kind != 1) return;
  uint32_t actions = 0;
  assert(ReArcTabGetMediaActions(tab, &actions) == REARC_OK);
  printf("PIP media step=%d available=%d active=%d playback=%u actions=0x%x\n", step, e->pip_available, e->pip_active, e->playback, actions);
  if (e->pip_available && !available) {
    assert(actions & REARC_MEDIA_ACTION_PICTURE_IN_PICTURE);
    assert(actions & REARC_MEDIA_ACTION_PAUSE);
    assert(!(actions & REARC_MEDIA_ACTION_NEXT_TRACK) && !(actions & REARC_MEDIA_ACTION_PREVIOUS_TRACK));
  }
  available = e->pip_available;
  enter_when_ready();
}
static void event(void*, const ReArcTabEvent* e) {
  if (e->tab_id != tab || e->kind != 1 || !(e->changes & 2)) return;
  std::string t = e->title;
  printf("TITLE step=%d %s\n", step, t.c_str());
  if (t == "pip:ready" && step == 0) {
    assert(ReArcTabEvaluateScript2(tab, "toFile()", 1, nullptr, 20000, [](void*, const ReArcScriptResult* r) {
      assert(r->status == 0); step = 1; enter_when_ready();
    }, nullptr) == 0);
  }
}
static void ready(void*, uint64_t p) {
  profile = p;
  assert(ReArcEngineABIMinorVersion() >= 43 && ReArcEngineHasFeature("pip_embedded"));
  uint32_t actions = 7;
  assert(ReArcTabGetMediaActions(424242, &actions) == REARC_TAB_NOT_FOUND);
  assert(ReArcTabGetMediaActions(424242, nullptr) == REARC_INVALID_ARGUMENT);
  ReArcEngineSetServiceCallback(service, nullptr);
  ReArcEngineSetPictureInPictureCallback(pip, nullptr);
  ReArcEngineSetVideoOverlayCallback(overlay_event, nullptr);
  assert(ReArcTabCreate(p, 1, (base + "/pip").c_str(), &tab) == 0);
  window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  assert(ReArcWindowRegister(1, (__bridge void*)window) == 0);
  assert(ReArcViewAttach(tab, 1, 400, 300, 1, &lease) == 0);
  [window.contentView addSubview:(__bridge NSView*)lease.native_view];
  [window makeKeyAndOrderFront:nil];
  assert(ReArcViewSetVisible(tab, lease.attachment_id, true) == 0);
}
int main(int argc, const char** argv) { @autoreleasepool {
  setbuf(stdout, nullptr);
  base = "http://127.0.0.1:" + std::string(getenv("REARC_TEST_PORT"));
  ReArcCallbacks c{ready, event, nullptr, nullptr};
  assert(ReArcEngineConfigure(1, &c, nullptr) == 0);
  int r = ReArcEngineRun(argc, argv); assert(r == 0 && stopped); return r;
}}
