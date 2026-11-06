#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <string>
static uint64_t profile, tab, sibling;
static NSWindow* window;
static ReArcAttachment lease{};
static ReArcDocumentIdentity before{};
static int phase, discards, cancelled, find_cancelled, invalidated, closed;
static bool loaded, committed, stopped, disabled, can_forward;
static std::string base_url;
static void evaluated(void*, ReArcStatus s, uint64_t, uint64_t, const char*, const char*) {
  assert(s == REARC_OK);
}
static void eval(uint64_t id, const char* source, ReArcScriptCallback callback = evaluated) {
  assert(ReArcTabEvaluateScript(id, source, 1, nullptr, 30000, callback, nullptr) == REARC_OK);
}
static void shutdown() {
  assert(ReArcEngineShutdown(true, [](void*, ReArcStatus s, bool c) {
    assert(s == REARC_OK && !c && closed == 2);
    if (!disabled) assert(discards == 5 && cancelled == 1 && find_cancelled == 1 && invalidated == 1);
    ReArcViewRelease(lease.native_view);
    stopped = true;
    puts("DISCARD preservation/reload/boosts/history/sibling/cancellation/close PASS");
  }, nullptr) == REARC_OK);
}
static void discard() {
  bool discarded = true;
  assert(ReArcTabGetDiscardState(tab, &discarded) == REARC_OK && !discarded);
  assert(ReArcTabDiscard(tab) == REARC_OK);
  assert(ReArcTabGetDiscardState(tab, &discarded) == REARC_OK && discarded);
  assert(ReArcTabDiscard(tab) == REARC_INVALID_STATE);
  assert(ReArcTabEvaluateScript(tab, "42", 1, nullptr, 1000, evaluated, nullptr) == REARC_INVALID_STATE);
  uint64_t find;
  assert(ReArcTabFindStart(tab, "visit", 0, &find) == REARC_INVALID_STATE);
  assert(invalidated == 0);
  ++discards;
}
static void verify_sibling() {
  eval(sibling, "window.siblingMarker", [](void*, ReArcStatus s, uint64_t, uint64_t, const char* json, const char*) {
    assert(s == REARC_OK && std::string(json) == "42");
    if (phase == 5) {
      // The old A navigation entry survived; BFCache was flushed on discard.
      phase = 6; loaded = committed = false;
      assert(ReArcTabGoBack(tab) == REARC_OK);
    } else {
      assert(phase == 7);
      assert(ReArcViewSetVisible(tab, lease.attachment_id, false) == REARC_OK);
      if (discards == 4) phase = 8;
      loaded = committed = false;
      discard();
      if (phase == 8) shutdown();
    }
  });
}
static void verify_restored() {
  bool discarded = true;
  assert(ReArcTabGetDiscardState(tab, &discarded) == REARC_OK && !discarded);
  ReArcDocumentIdentity after{};
  assert(ReArcTabGetDocumentIdentity(tab, &after) == REARC_OK);
  assert(after.content_generation == before.content_generation && after.document_generation > before.document_generation);
  eval(tab, "[document.wasDiscarded,document.documentElement.getAttribute('data-discard-boost'),history.length,location.pathname]",
       [](void*, ReArcStatus s, uint64_t, uint64_t, const char* json, const char*) {
    assert(s == REARC_OK);
    printf("DISCARD restored phase=%d json=%s\n", phase, json);
    std::string expected = phase == 5 ? "[true,\"alive\",2,\"/visit-b\"]" : "[true,\"alive\",2,\"/visit-a\"]";
    assert(std::string(json) == expected);
    verify_sibling();
  });
}
static void event(void*, const ReArcTabEvent* e) {
  if (e->kind == 2) { ++closed; return; }
  if (e->tab_id != tab) return;
  assert(!e->is_crashed);
  if (e->changes & 64) can_forward = e->can_go_forward;
  if (e->kind == 5 && (phase == 3 || phase == 7)) {
    assert(e->content_generation == lease.content_generation && invalidated == 0);
    if (phase == 3) {
      assert(cancelled == 1 && find_cancelled == 1);
      phase = 4;
      assert(ReArcTabRefreshState(tab) == REARC_OK);
      return;
    }
    assert(ReArcViewSetVisible(tab, lease.attachment_id, true) == REARC_OK);
    return;
  }
  if (e->kind == 5 && phase == 4) {
    phase = 5; loaded = committed = false;
    assert(std::string(e->url) == base_url + "/visit-b" && std::string(e->title) == "ReArc visit B");
    assert(ReArcViewSetVisible(tab, lease.attachment_id, true) == REARC_OK);
    // On a locked desktop the key-window check may reject focus. Visibility
    // restores independently, as required for presented split panes.
    ReArcStatus s = ReArcTabActivate(tab); assert(s == REARC_OK || s == REARC_INVALID_STATE);
    return;
  }
  if (e->kind == 3 && std::string(e->url).starts_with("http")) committed = true;
  if (e->kind != 1 || !(e->changes & 4) || e->is_loading || !committed || loaded) return;
  loaded = true;
  if (phase == 0) {
    phase = 1; loaded = committed = false;
    assert(ReArcTabNavigate(tab, (base_url + "/visit-b").c_str(), 0) == REARC_OK);
  } else if (phase == 1) {
    if (disabled) { assert(ReArcTabDiscard(tab) == REARC_UNSUPPORTED); shutdown(); return; }
    assert(ReArcViewSetVisible(tab, lease.attachment_id, true) == REARC_OK);
    assert(ReArcTabDiscard(tab) == REARC_INVALID_STATE);
    assert(ReArcViewSetVisible(tab, lease.attachment_id, false) == REARC_OK);
    eval(sibling, "window.siblingMarker=42;window.onbeforeunload=()=>true", [](void*, ReArcStatus s, uint64_t, uint64_t, const char*, const char*) {
      assert(s == REARC_OK && ReArcTabDiscard(sibling) == REARC_INVALID_STATE);
      eval(sibling, "window.onbeforeunload=null", [](void*, ReArcStatus s, uint64_t, uint64_t, const char*, const char*) {
        assert(s == REARC_OK);
        ReArcScriptScope scope{"127.0.0.1", "", false, 1};
        ReArcScript script{"discard-boost", &scope, 1, 0,
          "function apply(){document.documentElement.setAttribute('data-discard-boost','alive')}if(document.documentElement)apply();else addEventListener('DOMContentLoaded',apply,{once:true})", ""};
        phase = 2;
        assert(ReArcTabSetScripts(tab, &script, 1, [](void*, ReArcStatus s, bool c) {
          assert(s == REARC_OK && !c);
          assert(ReArcTabGetDocumentIdentity(tab, &before) == REARC_OK);
          eval(tab, "new Promise(()=>{})", [](void*, ReArcStatus s, uint64_t, uint64_t, const char*, const char*) {
            assert(s == REARC_CANCELLED); ++cancelled;
          });
          uint64_t find;
          assert(ReArcTabFindStart(tab, "visit", 0, &find) == REARC_OK);
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            phase = 3; discard();
          });
        }, nullptr) == REARC_OK);
      });
    });
  } else if (phase == 5 || phase == 7) verify_restored();
  else if (phase == 6) {
    assert(can_forward);
    phase = 7;
    assert(ReArcViewSetVisible(tab, lease.attachment_id, false) == REARC_OK);
    loaded = committed = false; discard();
  }
}
static void ready(void*, uint64_t id) {
  profile = id;
  assert(ReArcEngineABIMinorVersion() >= 25 && ReArcEngineHasFeature("tab_discard"));
  bool state = true;
  assert(ReArcTabGetDiscardState(999999, &state) == REARC_TAB_NOT_FOUND && !state);
  assert(ReArcTabGetDiscardState(999999, nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcTabDiscard(999999) == REARC_TAB_NOT_FOUND);
  assert(ReArcTabCreate(id, 1, nullptr, &tab) == REARC_OK);
  if (!disabled) assert(ReArcTabDiscard(tab) == REARC_INVALID_STATE);
  assert(ReArcTabCreate(id, 1, (base_url + "/visit-sibling").c_str(), &sibling) == REARC_OK);
  window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,800,600) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  assert(ReArcWindowRegister(1, (__bridge void*)window) == REARC_OK);
  [window makeKeyAndOrderFront:nil];
  assert(ReArcViewAttach(tab, 1, 800, 600, 1, &lease) == REARC_OK);
  [window.contentView addSubview:(__bridge NSView*)lease.native_view];
  ReArcEngineSetFindCallback([](void*, const ReArcFindEvent* e) {if(e->reason==5)++find_cancelled;}, nullptr);
  assert(ReArcTabNavigate(tab, (base_url + "/visit-a").c_str(), 0) == REARC_OK);
  if (!disabled) assert(ReArcTabDiscard(tab) == REARC_INVALID_STATE);
}
int main(int argc, const char** argv) { @autoreleasepool {
  setbuf(stdout, nullptr);
  base_url = "http://127.0.0.1:" + std::string(getenv("REARC_TEST_PORT"));
  disabled = getenv("REARC_DISCARD_DISABLED");
  ReArcCallbacks c{ready, event, [](void*, const ReArcViewEvent* e) {assert(e->reason == 0); ++invalidated;}, nullptr};
  assert(ReArcEngineConfigure(1, &c, nullptr) == REARC_OK);
  int result = ReArcEngineRun(argc, argv); assert(!result && stopped); return result;
}}
