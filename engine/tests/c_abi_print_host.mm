#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <string>
static uint64_t profile, tab;
static std::string base;
static int step, requests;
static bool stopped, started;
static int pages(const uint8_t* d, size_t n) {
  std::string pdf(reinterpret_cast<const char*>(d), n); int count = 0;
  for (size_t at = pdf.find("/Type /Page"); at != std::string::npos; at = pdf.find("/Type /Page", at + 1))
    if (pdf.compare(at, 12, "/Type /Pages") != 0) ++count;
  return count;
}
static void eval(const std::string& s, ReArcScriptCallback2 cb) { assert(ReArcTabEvaluateScript2(tab, s.c_str(), 1, nullptr, 10000, cb, nullptr) == 0); }
static void next();
static void pdf(void* ctx, ReArcStatus s, uint64_t id, uint64_t gen, uint8_t* d, size_t n) {
  printf("PRINT step=%d status=%d size=%zu pages=%d\n", step, s, n, d ? pages(d, n) : -1);
  assert(id == tab && gen == 1);
  if (step == 0 || step == 1 || step == 3) {
    assert(s == REARC_OK && n > 500 && d && std::string(reinterpret_cast<char*>(d), 5) == "%PDF-");
    assert(pages(d, n) == (step == 1 ? 1 : 3));
  } else if (step == 2) {
    assert(s == REARC_INVALID_ARGUMENT && !d && !n);
  } else {
    assert((step == 5 || step == 6) && s == REARC_CANCELLED && !d && !n);
  }
  ReArcBufferFree(d);
  ++step;
  if (step != 7) next();
}
static void closed(void*, ReArcStatus s, bool c) {
  assert(s == 0 && !c && step == 7 && requests == 1);
  assert(ReArcEngineShutdown(true, [](void*, ReArcStatus s, bool c) { assert(s == 0 && !c); stopped = true;
    puts("PRINT pdf bytes/pages/landscape range/invalid range/busy + window.print request/afterprint + navigation/close cancellation PASS"); }, nullptr) == 0);
}
static void next() {
  if (step == 1) {
    ReArcPrintOptions o{}; o.landscape = true; o.print_background = true; o.page_ranges = "2";
    o.margin_top_in = o.margin_bottom_in = o.margin_left_in = o.margin_right_in = 0.5;
    assert(ReArcTabPrintToPDF(tab, &o, pdf, nullptr) == 0);
    assert(ReArcTabPrintToPDF(tab, nullptr, pdf, nullptr) == REARC_BUSY);
  } else if (step == 2) {
    ReArcPrintOptions o{}; o.page_ranges = "9"; o.margin_top_in = o.margin_bottom_in = o.margin_left_in = o.margin_right_in = -1;
    assert(ReArcTabPrintToPDF(tab, &o, pdf, nullptr) == 0);
  } else if (step == 3) {
    // window.print() completes for the page and asks the host to print.
    eval("window.print();document.title", [](void*, const ReArcScriptResult* r) {
      printf("PRINT window.print title=%s\n", r->json); assert(r->status == 0);
      assert(std::string(r->json) == "\"beforeprint+afterprint\"");
    });
  } else if (step == 4) {
    // Host prints in response to the request; then a navigation cancels.
    step = 5;
    assert(ReArcTabPrintToPDF(tab, nullptr, pdf, nullptr) == 0);
    assert(ReArcTabNavigate(tab, (base + "/print?again").c_str(), 0) == 0);
  } else if (step == 6) {
    assert(ReArcTabPrintToPDF(tab, nullptr, pdf, nullptr) == 0);
    assert(ReArcTabClose(tab, true, closed, nullptr) == 0);
  }
}
static void print(void*, const ReArcPrintRequestEvent* e) {
  printf("PRINT request step=%d source=%u\n", step, e->source);
  assert(step == 3 && e->tab_id == tab && e->profile_id == profile && e->content_generation == 1 && e->source == 0);
  ++requests;
  assert(ReArcTabPrintToPDF(tab, nullptr, pdf, nullptr) == 0);
}
static void event(void*, const ReArcTabEvent* e) {
  static std::string committed;
  if (e->tab_id == tab && e->kind == 3) committed = e->url;
  if (e->tab_id != tab || e->kind != 1 || !(e->changes & 4) || e->is_loading) return;
  if (!started && committed == base + "/print") {
    started = true;
    assert(ReArcTabPrintToPDF(tab, nullptr, pdf, nullptr) == 0);
  } else if (step == 6 && committed == base + "/print?again") next();
}
static void ready(void*, uint64_t p) {
  profile = p;
  assert(ReArcEngineABIMinorVersion() >= 28 && ReArcEngineHasFeature("printing"));
  ReArcEngineSetPrintCallback(print, nullptr);
  assert(ReArcTabPrintToPDF(424242, nullptr, pdf, nullptr) == REARC_TAB_NOT_FOUND);
  assert(ReArcTabCreate(p, 1, (base + "/print").c_str(), &tab) == 0);
  assert(ReArcTabPrintToPDF(tab, nullptr, nullptr, nullptr) == REARC_INVALID_ARGUMENT);
  ReArcPrintOptions o{}; o.scale = 3;
  assert(ReArcTabPrintToPDF(tab, &o, pdf, nullptr) == REARC_INVALID_ARGUMENT);
  o.scale = 1; o.page_ranges = "\xe2\x80\x94";
  assert(ReArcTabPrintToPDF(tab, &o, pdf, nullptr) == REARC_INVALID_ARGUMENT);
}
int main(int argc, const char** argv) { @autoreleasepool {
  setbuf(stdout, nullptr);
  base = "http://127.0.0.1:" + std::string(getenv("REARC_TEST_PORT"));
  ReArcCallbacks c{ready, event, nullptr, nullptr};
  assert(ReArcEngineConfigure(1, &c, nullptr) == 0);
  int r = ReArcEngineRun(argc, argv); assert(r == 0 && stopped); return r;
}}
