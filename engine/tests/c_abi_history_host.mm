#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <string>

static uint64_t profile, tab, named;
static int visits, phase, cancelled;
static bool committed, loaded, stopped, in_call;
static int64_t visit_time;
static std::string base_url;
static void query();
static void navigate(const char* path) {
  committed = loaded = false;
  assert(ReArcTabNavigate(tab, (base_url + path).c_str(), 0) == REARC_OK);
}
static void deleted(void*, ReArcStatus s, bool c) {
  assert(!in_call && s == REARC_OK && !c); query();
}
static void isolated(void*, ReArcStatus s, uint64_t id, const ReArcHistoryEntry* rows, size_t count) {
  assert(s == REARC_OK && id == named && count == 0 && !rows);
  assert(ReArcHistoryQuery(named, "", 10, [](void*, ReArcStatus s, uint64_t id, const ReArcHistoryEntry*, size_t n) {
    assert(s == REARC_CANCELLED && id == named && !n); ++cancelled;
  }, nullptr) == REARC_OK);
  assert(ReArcProfileClose(named, true, [](void*, ReArcStatus s, bool c) {
    assert(s == REARC_OK && !c && cancelled == 1);
    assert(ReArcEngineShutdown(true, [](void*, ReArcStatus s, bool c) {
      assert(s == REARC_OK && !c); stopped = true;
      puts("HISTORY recent/text/limit/counts + URL/range removal + isolation/OTR/cancellation PASS");
    }, nullptr) == REARC_OK);
  }, nullptr) == REARC_OK);
}
static void results(void*, ReArcStatus s, uint64_t id, const ReArcHistoryEntry* rows, size_t count) {
  assert(!in_call && s == REARC_OK && id == profile);
  printf("HISTORY phase=%d count=%zu\n", phase, count);
  if (phase == 0) {
    assert(count == 2 && std::string(rows[0].url) == base_url + "/visit-a");
    assert(std::string(rows[0].title) == "ReArc visit A" && rows[0].visit_count >= 2);
    assert(rows[0].visit_time_us >= rows[1].visit_time_us && rows[1].visit_time_us > 0);
    phase = 1; query();
  } else if (phase == 1) {
    assert(count == 1 && std::string(rows[0].url) == base_url + "/visit-b");
    visit_time = rows[0].visit_time_us;
    phase = 2; query();
  } else if (phase == 2) {
    assert(count == 1 && std::string(rows[0].url) == base_url + "/visit-a");
    phase = 3;
    in_call = true;
    assert(ReArcHistoryDeleteURL(profile, (base_url + "/visit-a").c_str(), deleted, nullptr) == REARC_OK);
    in_call = false;
  } else if (phase == 3) {
    assert(count == 1 && std::string(rows[0].url) == base_url + "/visit-b");
    phase = 4;
    // Exclusive upper bound must preserve the visit exactly at that time.
    assert(ReArcHistoryDeleteRange(profile, 0, visit_time, deleted, nullptr) == REARC_OK);
  } else if (phase == 4) {
    assert(count == 1);
    phase = 5;
    assert(ReArcHistoryDeleteRange(profile, visit_time, visit_time+1, deleted, nullptr) == REARC_OK);
  } else if (phase == 5) {
    assert(count == 0 && !rows);
    assert(ReArcProfileCreateOffTheRecord(profile, [](void*, ReArcStatus s, uint64_t id, bool otr) {
      assert(s == REARC_OK && otr);
      assert(ReArcHistoryQuery(id, "", 10, results, nullptr) == REARC_UNSUPPORTED);
      assert(ReArcHistoryDeleteURL(id, (base_url + "/visit-b").c_str(), deleted, nullptr) == REARC_UNSUPPORTED);
      assert(ReArcHistoryDeleteRange(id, 0, 0, deleted, nullptr) == REARC_UNSUPPORTED);
      assert(ReArcProfileClose(id, true, [](void*, ReArcStatus s, bool c) {
        assert(s == REARC_OK && !c);
        assert(ReArcProfileOpen("history-isolated", [](void*, ReArcStatus s, uint64_t id, bool otr) {
          assert(s == REARC_OK && !otr); named = id;
          assert(ReArcHistoryQuery(named, "", 10, isolated, nullptr) == REARC_OK);
        }, nullptr) == REARC_OK);
      }, nullptr) == REARC_OK);
    }, nullptr) == REARC_OK);
  } else assert(false);
}
static void query() {
  in_call = true;
  assert(ReArcHistoryQuery(profile, phase == 1 ? "visit B" : "", phase == 2 ? 1 : 10, results, nullptr) == REARC_OK);
  in_call = false;
}
static void event(void*, const ReArcTabEvent* e) {
  if (e->tab_id != tab) return;
  if (e->kind == 3 && std::string(e->url).starts_with("http")) committed = true;
  if (e->kind != 1 || !(e->changes & 4) || e->is_loading || !committed || loaded) return;
  loaded = true;
  ++visits;
  if (visits == 1) navigate("/visit-b");
  else if (visits == 2) navigate("/visit-a");
  else if (visits == 3) query();
}
static void ready(void*, uint64_t id) {
  profile = id;
  assert(ReArcEngineABIMinorVersion() >= 23 && ReArcEngineHasFeature("history_query"));
  assert(ReArcHistoryQuery(profile, "", 0, results, nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcHistoryQuery(profile, "", 1001, results, nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcHistoryQuery(profile, "\xff", 10, results, nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcHistoryQuery(profile, nullptr, 10, results, nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcHistoryQuery(profile, "", 10, nullptr, nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcHistoryQuery(99999, "", 10, results, nullptr) == REARC_PROFILE_NOT_FOUND);
  assert(ReArcHistoryDeleteURL(profile, "invalid", deleted, nullptr) == REARC_INVALID_URL);
  assert(ReArcHistoryDeleteRange(profile, -1, 0, deleted, nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcHistoryDeleteRange(profile, 2, 1, deleted, nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcHistoryDeleteRange(profile, 0, INT64_MAX, deleted, nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcTabCreate(profile, 1, (base_url + "/visit-a").c_str(), &tab) == REARC_OK);
}
int main(int argc, const char** argv) { @autoreleasepool {
  setbuf(stdout, nullptr);
  base_url = "http://127.0.0.1:" + std::string(getenv("REARC_TEST_PORT"));
  ReArcCallbacks c{ready, event, nullptr, nullptr};
  assert(ReArcEngineConfigure(1, &c, nullptr) == REARC_OK);
  int result = ReArcEngineRun(argc, argv); assert(!result && stopped); return result;
}}
