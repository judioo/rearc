#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <string>
#include <vector>

// Wave 18b find in page over Chromium's FindTabHelper: counts, ordinals,
// direction, match case, and one terminal event per session (replace, stop,
// navigation, close).
static uint64_t tab, profile_id, current, previous;
static std::string base_url;
static NSWindow* window;
static ReArcAttachment lease{};
static int step;
static bool loaded, committed, saw_closed, stopped;
static std::vector<uint64_t> terminated;
static void start(const char* text, uint32_t options) {
  previous = current;
  assert(ReArcTabFindStart(tab, text, options, &current) == REARC_OK && current > previous);
}
static void close_done(void*, ReArcStatus s, bool c) {
  assert(s == REARC_OK && !c && saw_closed);
  ReArcViewRelease(lease.native_view);
  assert(ReArcEngineShutdown(true, [](void*, ReArcStatus s, bool c) {
    assert(s == REARC_OK && !c); stopped = true;
    puts("FIND counts/ordinals/case/direction + terminal events PASS");
  }, nullptr) == REARC_OK);
}
static void terminal(const ReArcFindEvent* e) {
  // Exactly one final terminal event per session, carrying no counts.
  assert(e->final_update && e->match_count == -1 && e->active_ordinal == -1);
  for (auto id : terminated) assert(id != e->session_id);
  terminated.push_back(e->session_id);
  switch (e->reason) {
    case 4: assert(step == 4 && e->session_id == previous); puts("FIND replacement terminal PASS"); return;
    case 3: assert(step == 5 && e->session_id == current);
      puts("FIND stop terminal PASS"); step = 6; start("gamma", REARC_FIND_FORWARD); return;
    case 1: assert(step == 7 && e->session_id == current);
      puts("FIND navigation cancels session PASS"); step = 8; return;
    case 2: assert(step == 10 && e->session_id == current && !saw_closed);
      puts("FIND close cancels session before tab.closed PASS"); return;
  }
  assert(false);
}
static void find_event(void*, const ReArcFindEvent* e) {
  assert([NSThread isMainThread] && e->tab_id == tab && e->profile_id == profile_id && e->content_generation && e->session_id);
  printf("FIND step=%d session=%llu reason=%u matches=%d active=%d final=%d\n", step, e->session_id, e->reason, e->match_count, e->active_ordinal, e->final_update);
  if (e->reason) { terminal(e); return; }
  if (!e->final_update || e->session_id != current) return;  // stale/partial
  switch (step) {
    case 0: assert(e->match_count == 4 && e->active_ordinal == 1);
      step = 1; assert(ReArcTabFindNext(tab, true) == REARC_OK); return;
    case 1: assert(e->match_count == 4 && e->active_ordinal == 2);
      step = 2; assert(ReArcTabFindNext(tab, false) == REARC_OK); return;
    case 2: assert(e->match_count == 4 && e->active_ordinal == 1);
      step = 3; assert(ReArcTabFindNext(tab, false) == REARC_OK); return;
    case 3: assert(e->match_count == 4 && e->active_ordinal == 4);  // wraps backward
      puts("FIND next/previous ordinals PASS");
      step = 4; start("alpha", REARC_FIND_FORWARD | REARC_FIND_MATCH_CASE); return;
    case 4: assert(e->match_count == 2 && e->active_ordinal == 1);
      puts("FIND match case PASS");
      step = 5; assert(ReArcTabFindStop(tab, 1) == REARC_OK);
      assert(ReArcTabFindStop(tab, 1) == REARC_INVALID_STATE);
      assert(ReArcTabFindNext(tab, true) == REARC_INVALID_STATE);
      return;
    case 6: assert(e->match_count == 1 && e->active_ordinal == 1);
      step = 7; loaded = committed = false;
      assert(ReArcTabNavigate(tab, (base_url + "/visit-a").c_str(), 0) == REARC_OK); return;
    case 9: assert(e->match_count == 1);
      step = 10; assert(ReArcTabClose(tab, true, close_done, nullptr) == REARC_OK); return;
  }
  assert(false);
}
static void event(void*, const ReArcTabEvent* e) {
  if (e->tab_id != tab) return;
  if (e->kind == 2) { assert(step == 10 && terminated.size() == 4); saw_closed = true; return; }
  if (e->kind == 3 && std::string(e->url).starts_with("http")) committed = true;
  if (e->kind != 1 || !(e->changes & 4) || e->is_loading || loaded || !committed) return;
  loaded = true;
  if (step == 0) {
    uint64_t id = 7;
    assert(ReArcTabFindStart(tab, "", REARC_FIND_FORWARD, &id) == REARC_INVALID_ARGUMENT && !id);
    assert(ReArcTabFindStart(tab, "alpha", 4, &id) == REARC_INVALID_ARGUMENT);
    assert(ReArcTabFindStart(tab, nullptr, 0, &id) == REARC_INVALID_ARGUMENT);
    assert(ReArcTabFindStart(tab, "\xff", 0, &id) == REARC_INVALID_ARGUMENT);
    assert(ReArcTabFindStart(tab, "alpha", 0, nullptr) == REARC_INVALID_ARGUMENT);
    assert(ReArcTabFindStart(99999, "alpha", 0, &id) == REARC_TAB_NOT_FOUND);
    assert(ReArcTabFindNext(tab, true) == REARC_INVALID_STATE);
    assert(ReArcTabFindStop(tab, 9) == REARC_INVALID_ARGUMENT);
    assert(ReArcTabFindStop(tab, 0) == REARC_INVALID_STATE);
    start("alpha", REARC_FIND_FORWARD);
  } else if (step == 8) {
    step = 9; start("visit", REARC_FIND_FORWARD);
  }
}
static void ready(void*, uint64_t profile) {
  assert(ReArcEngineABIMinorVersion() >= 16 && ReArcEngineHasFeature("find_in_page"));
  profile_id = profile;
  ReArcEngineSetFindCallback(find_event, nullptr);
  assert(ReArcTabCreate(profile, 1, (base_url + "/find").c_str(), &tab) == REARC_OK);
  // Find needs laid-out content: present the tab at a real size.
  window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,800,600) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  assert(ReArcWindowRegister(1, (__bridge void*)window) == REARC_OK);
  [window makeKeyAndOrderFront:nil];
  assert(ReArcViewAttach(tab, 1, 800, 600, 1, &lease) == REARC_OK);
  [window.contentView addSubview:(__bridge NSView*)lease.native_view];
  assert(ReArcViewSetVisible(tab, lease.attachment_id, true) == REARC_OK);
}
int main(int argc, const char** argv) { @autoreleasepool {
  setbuf(stdout, nullptr);
  base_url = "http://127.0.0.1:" + std::string(getenv("REARC_TEST_PORT"));
  ReArcCallbacks c{ready, event, nullptr, nullptr};
  assert(ReArcEngineConfigure(1, &c, nullptr) == REARC_OK);
  int result = ReArcEngineRun(argc, argv); assert(result == 0 && stopped);
  return result;
}}
