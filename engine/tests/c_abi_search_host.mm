#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <string>
#include <vector>

static uint64_t profile, tab, otr, named, q1, q2, q3, q4, q5;
static int visits, terminal1, terminal4, terminal5;
static bool committed, loaded, stopped, in_call;
static std::string base, host_port;
static void otr_phase();
static void navigate(const char* path) {
  committed = loaded = false;
  assert(ReArcTabNavigate(tab, (base + path).c_str(), 0) == REARC_OK);
}
static ReArcSearchProvider local(const char* suggest) {
  static std::string search, suggestion;
  search = base + "/search?q=%s";
  suggestion = base + suggest;
  return {"ReArc Test", "rearctest", search.c_str(), suggestion.c_str(), false, false};
}
static bool has(const ReArcAutocompleteResult* r, const std::string& url) {
  for (size_t i = 0; i < r->count; ++i)
    if (url == r->matches[i].destination_url) return true;
  return false;
}
static void dump(const char* label, const ReArcAutocompleteResult* r) {
  printf("SEARCH %s query=%llu status=%d done=%d count=%zu\n", label, r->query_id, r->status, r->done, r->count);
  for (size_t i = 0; i < r->count; ++i) {
    const auto& m = r->matches[i];
    printf("  kind=%u type=%u rel=%d default=%d contents=%s url=%s fill=%s inline=%s\n", m.kind, m.match_type,
           m.relevance, m.allowed_to_be_default, m.contents, m.destination_url, m.fill_into_edit, m.inline_autocompletion);
  }
}
static void close_named() {
  assert(ReArcProfileOpen("search-close", [](void*, ReArcStatus s, uint64_t id, bool o) {
    assert(s == REARC_OK && !o); named = id;
    auto p = local("/suggest-slow?q=%s");
    assert(ReArcSearchSetDefaultProvider(named, &p, [](void*, ReArcStatus s, bool c) {
      assert(s == REARC_OK && !c);
      assert(ReArcAutocompleteStart(named, "slowclose", 0, [](void*, const ReArcAutocompleteResult* r) {
        dump("close", r); assert(r->query_id == q5 && r->profile_id == named);
        if (r->done) { assert(r->status == REARC_CANCELLED); ++terminal5; }
      }, nullptr, &q5) == REARC_OK && q5);
      assert(ReArcProfileClose(named, true, [](void*, ReArcStatus s, bool c) {
        assert(s == REARC_OK && !c && terminal5 == 1 && terminal1 == 1 && terminal4 == 1);
        assert(ReArcEngineShutdown(true, [](void*, ReArcStatus s, bool c) {
          assert(s == REARC_OK && !c); stopped = true;
          puts("SEARCH provider get/set + classify + autocomplete history/suggest + supersede/stop/close cancellation + OTR isolation PASS");
        }, nullptr) == REARC_OK);
      }, nullptr) == REARC_OK);
    }, nullptr) == REARC_OK);
  }, nullptr) == REARC_OK);
}
static void otr_suggest() {
  uint64_t query;
  assert(ReArcAutocompleteStart(otr, "privateonly", 0, [](void*, const ReArcAutocompleteResult* r) {
    dump("otr-suggest", r);
    if (!r->done) return;
    assert(r->status == REARC_OK);
    for (size_t i = 0; i < r->count; ++i) assert(std::string(r->matches[i].contents).find("suggestion") == std::string::npos);
    assert(ReArcProfileClose(otr, true, [](void*, ReArcStatus s, bool c) { assert(s == REARC_OK && !c); close_named(); }, nullptr) == REARC_OK);
  }, nullptr, &query) == REARC_OK);
}
static void otr_phase() {
  assert(ReArcProfileCreateOffTheRecord(profile, [](void*, ReArcStatus s, uint64_t id, bool o) {
    assert(s == REARC_OK && o); otr = id;
    auto p = local("/suggest?q=%s");
    assert(ReArcSearchSetDefaultProvider(otr, &p, [](void*, ReArcStatus, bool) { assert(false); }, nullptr) == REARC_UNSUPPORTED);
    assert(ReArcSearchGetDefaultProvider(otr, [](void*, ReArcStatus s, uint64_t id, const ReArcSearchProvider* p) {
      assert(s == REARC_OK && id == otr && std::string(p->keyword) == "rearctest");
      assert(ReArcSearchClassifyInput(otr, "privateonly words", [](void*, ReArcStatus s, uint64_t, const ReArcInputClassification* c) {
        assert(s == REARC_OK && c->kind == 2 && std::string(c->destination_url) == base + "/search?q=privateonly+words");
        uint64_t query;
        assert(ReArcAutocompleteStart(otr, (host_port + "/visit").c_str(), 1, [](void*, const ReArcAutocompleteResult* r) {
          dump("otr-history", r);
          if (!r->done) return;
          assert(r->status == REARC_OK && r->count >= 1);
          assert(!has(r, base + "/visit-a") && !has(r, base + "/visit-b"));
          otr_suggest();
        }, nullptr, &query) == REARC_OK);
      }, nullptr) == REARC_OK);
    }, nullptr) == REARC_OK);
  }, nullptr) == REARC_OK);
}
static void stop_phase() {
  assert(ReArcAutocompleteStart(profile, "slowstop", 0, [](void*, const ReArcAutocompleteResult* r) {
    dump("stop", r); assert(r->query_id == q4);
    if (r->done) { assert(r->status == REARC_CANCELLED && ++terminal4 == 1); otr_phase(); }
  }, nullptr, &q4) == REARC_OK);
  in_call = true;
  assert(ReArcAutocompleteStop(profile) == REARC_OK);
  in_call = false;
}
static void suggest_phase() {
  assert(ReArcAutocompleteStart(profile, "visit", 1, [](void*, const ReArcAutocompleteResult* r) {
    dump("suggest", r); assert(!in_call && r->query_id == q3);
    if (!r->done) return;
    assert(r->status == REARC_OK);
    bool remote = false;
    for (size_t i = 0; i < r->count; ++i)
      if (r->matches[i].kind == 2 && std::string(r->matches[i].contents) == "visit suggestion one" &&
          std::string(r->matches[i].destination_url) == base + "/search?q=visit+suggestion+one") remote = true;
    assert(remote);
    assert(ReArcAutocompleteStop(profile) == REARC_OK);  // Idle: no callback.
    stop_phase();
  }, nullptr, &q3) == REARC_OK);
}
static void autocomplete_phase() {
  in_call = true;
  assert(ReArcAutocompleteStart(profile, "visit", 0, [](void*, const ReArcAutocompleteResult* r) {
    dump("superseded", r); assert(!in_call && r->query_id == q1 && r->done && r->status == REARC_CANCELLED && !r->count);
    ++terminal1;
  }, nullptr, &q1) == REARC_OK && q1);
  assert(ReArcAutocompleteStart(profile, (host_port + "/visit").c_str(), 0, [](void*, const ReArcAutocompleteResult* r) {
    dump("history", r); assert(!in_call && r->query_id == q2 && r->profile_id == profile);
    if (!r->done) return;
    assert(r->status == REARC_OK && terminal1 == 1 && (has(r, base + "/visit-a") || has(r, base + "/visit-b")));
    suggest_phase();
  }, nullptr, &q2) == REARC_OK && q2 > q1);
  in_call = false;
}
static void provider_phase() {
  assert(ReArcSearchGetDefaultProvider(profile, [](void*, ReArcStatus s, uint64_t id, const ReArcSearchProvider* p) {
    assert(s == REARC_OK && id == profile && p);
    printf("SEARCH initial name=%s keyword=%s search=%s suggest=%s managed=%d prepopulated=%d\n", p->name, p->keyword, p->search_url, p->suggest_url, p->is_managed, p->is_prepopulated);
    assert(*p->name && *p->keyword && std::string(p->search_url).find("%s") != std::string::npos && !p->is_managed);
    auto bad = local("/suggest?q=%s"); bad.search_url = "ftp://x/%s";
    assert(ReArcSearchSetDefaultProvider(profile, &bad, [](void*, ReArcStatus, bool) {}, nullptr) == REARC_INVALID_ARGUMENT);
    bad = local("/suggest");
    assert(ReArcSearchSetDefaultProvider(profile, &bad, [](void*, ReArcStatus, bool) {}, nullptr) == REARC_INVALID_ARGUMENT);
    auto good = local("/suggest?q=%s");
    in_call = true;
    assert(ReArcSearchSetDefaultProvider(profile, &good, [](void*, ReArcStatus s, bool c) {
      assert(!in_call && s == REARC_OK && !c);
      assert(ReArcSearchGetDefaultProvider(profile, [](void*, ReArcStatus s, uint64_t, const ReArcSearchProvider* p) {
        printf("SEARCH local name=%s keyword=%s search=%s suggest=%s\n", p->name, p->keyword, p->search_url, p->suggest_url);
        assert(s == REARC_OK && std::string(p->name) == "ReArc Test" && std::string(p->keyword) == "rearctest");
        assert(std::string(p->search_url) == base + "/search?q=%s" && std::string(p->suggest_url) == base + "/suggest?q=%s" && !p->is_prepopulated);
        assert(ReArcSearchClassifyInput(profile, "example.com", [](void*, ReArcStatus s, uint64_t, const ReArcInputClassification* c) {
          printf("SEARCH classify url kind=%u type=%u url=%s\n", c->kind, c->match_type, c->destination_url);
          assert(s == REARC_OK && c->kind == 1 && std::string(c->destination_url) == "http://example.com/");
          assert(ReArcSearchClassifyInput(profile, "hello world", [](void*, ReArcStatus s, uint64_t, const ReArcInputClassification* c) {
            printf("SEARCH classify search kind=%u type=%u url=%s\n", c->kind, c->match_type, c->destination_url);
            assert(s == REARC_OK && c->kind == 2 && std::string(c->destination_url) == base + "/search?q=hello+world");
            autocomplete_phase();
          }, nullptr) == REARC_OK);
        }, nullptr) == REARC_OK);
      }, nullptr) == REARC_OK);
    }, nullptr) == REARC_OK);
    in_call = false;
  }, nullptr) == REARC_OK);
}
static void event(void*, const ReArcTabEvent* e) {
  if (e->tab_id != tab) return;
  if (e->kind == 3 && std::string(e->url).starts_with("http")) committed = true;
  if (e->kind != 1 || !(e->changes & 4) || e->is_loading || !committed || loaded) return;
  loaded = true;
  if (++visits == 1) navigate("/visit-b");
  else if (visits == 2) navigate("/visit-a");
  else if (visits == 3) provider_phase();
}
static void ready(void*, uint64_t id) {
  profile = id;
  assert(ReArcEngineABIMinorVersion() >= 26 && ReArcEngineHasFeature("search_autocomplete"));
  uint64_t query = 7;
  auto cb = [](void*, const ReArcAutocompleteResult*) { assert(false); };
  assert(ReArcAutocompleteStart(profile, "", 0, cb, nullptr, &query) == REARC_INVALID_ARGUMENT && !query);
  assert(ReArcAutocompleteStart(profile, "\xff", 0, cb, nullptr, &query) == REARC_INVALID_ARGUMENT);
  assert(ReArcAutocompleteStart(profile, "x", 2, cb, nullptr, &query) == REARC_INVALID_ARGUMENT);
  assert(ReArcAutocompleteStart(profile, "x", 0, nullptr, nullptr, &query) == REARC_INVALID_ARGUMENT);
  assert(ReArcAutocompleteStart(profile, "x", 0, cb, nullptr, nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcAutocompleteStart(99999, "x", 0, cb, nullptr, &query) == REARC_PROFILE_NOT_FOUND);
  assert(ReArcAutocompleteStop(99999) == REARC_PROFILE_NOT_FOUND);
  assert(ReArcSearchClassifyInput(profile, "", [](void*, ReArcStatus, uint64_t, const ReArcInputClassification*) {}, nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcSearchGetDefaultProvider(profile, nullptr, nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcSearchSetDefaultProvider(profile, nullptr, [](void*, ReArcStatus, bool) {}, nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcTabCreate(profile, 1, (base + "/visit-a").c_str(), &tab) == REARC_OK);
}
int main(int argc, const char** argv) { @autoreleasepool {
  setbuf(stdout, nullptr);
  host_port = "127.0.0.1:" + std::string(getenv("REARC_TEST_PORT"));
  base = "http://" + host_port;
  ReArcCallbacks c{ready, event, nullptr, nullptr};
  assert(ReArcEngineConfigure(1, &c, nullptr) == REARC_OK);
  int result = ReArcEngineRun(argc, argv); assert(!result && stopped); return result;
}}
