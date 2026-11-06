#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <unistd.h>
#include <functional>
#include <set>
#include <string>
// perf-0 (perf_metrics, ABI 1.44): page timing from page_load_metrics, view
// presentation feedback (shown, resized), histogram snapshots and the process
// list. Steps: 0 load /perf -> response, FCP, DCL, load, LCP events; 1 hide,
// show -> shown event (TotalSwitchDuration3); 2 resize -> resized event;
// 3 histograms; 4 processes; then shutdown. No input.
static uint64_t tab, profile;
static NSWindow* window;
static ReArcAttachment lease{};
static std::string base;
static int step;
static bool stopped, shown_seen, resized_seen;
static std::set<uint32_t> kinds;
static int64_t navigation_start;
static int histograms_pending = 3;
static void after(double s, std::function<void()> f) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(s * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ f(); }); }
// The engine's clock: base::TimeTicks in microseconds of mach_absolute_time.
static int64_t now_us() {
  mach_timebase_info_data_t tb; mach_timebase_info(&tb);
  return (int64_t)(mach_absolute_time() * tb.numer / tb.denom / 1000);
}
static void finish() {
  assert(shown_seen && resized_seen && !histograms_pending);
  ReArcViewRelease(lease.native_view);
  assert(ReArcEngineShutdown(true, [](void*, ReArcStatus s, bool c) { assert(s == 0 && !c); stopped = true;
    puts("PERF page timing + shown/resized presentation + histograms + processes PASS"); }, nullptr) == 0);
}
static void processes() {
  step = 4;
  assert(ReArcEngineGetProcesses(nullptr, nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcEngineGetProcesses([](void*, ReArcStatus s, const ReArcProcessInfo* p, size_t n) {
    assert(s == REARC_OK && n >= 2 && p[0].type == 0 && p[0].pid == getpid() && p[0].phys_footprint > 0);
    bool renderer = false;
    for (size_t i = 0; i < n; ++i) {
      printf("PERF process pid=%d type=%u name=%s profile=%llu ext=%d tabs=%zu footprint=%llu resident=%llu cpu_us=%lld\n",
             p[i].pid, p[i].type, p[i].name, p[i].profile_id, p[i].is_extension, p[i].tab_count,
             p[i].phys_footprint, p[i].resident_size, p[i].cpu_time_us);
      for (size_t t = 0; t < p[i].tab_count; ++t) {
        if (p[i].tab_ids[t] == tab) {
          assert(p[i].type == 1 && p[i].profile_id == profile && p[i].phys_footprint > 0 && p[i].cpu_time_us > 0);
          renderer = true;
        }
      }
    }
    assert(renderer);
    puts("PERF process list: browser first, the tab's renderer with footprint and CPU PASS");
    after(0.2, finish);
  }, nullptr) == REARC_OK);
}
static void histogram(const char* name, ReArcStatus expected) {
  assert(ReArcMetricsGetHistogram(name, [](void* context, ReArcStatus s, const ReArcHistogramSnapshot* h) {
    const ReArcStatus want = (ReArcStatus)(intptr_t)context;
    printf("PERF histogram status=%d count=%lld sum=%lld buckets=%zu %s\n", s, h ? h->count : 0, h ? h->sum : 0,
           h ? h->bucket_count : 0, h ? h->name : "-");
    assert(s == want);
    if (s == REARC_OK) {
      int64_t total = 0;
      for (size_t i = 0; i < h->bucket_count; ++i) { assert(h->buckets[i].max > h->buckets[i].min); total += h->buckets[i].count; }
      assert(h->count >= 1 && total == h->count);
    } else {
      assert(!h);
    }
    if (!--histograms_pending) { puts("PERF histograms: FCP and tab switch found, unknown not_found PASS"); processes(); }
  }, (void*)(intptr_t)expected) == REARC_OK);
}
static void presentation(void*, const ReArcViewPresentationEvent* e) {
  printf("PERF presentation step=%d kind=%u status=%u start=%lld activated=%lld presented=%lld size=%dx%d req=%llu\n", step, e->kind,
         e->status, e->start_us, e->activated_us, e->presented_us, e->width, e->height, e->request_id);
  assert(e->tab_id == tab && e->profile_id == profile && e->attachment_id == lease.attachment_id && e->request_id);
  if (e->kind == 0 && step == 1) {
    assert(e->status == 0 && e->presented_us >= e->start_us && e->start_us <= now_us() && e->width > 0);
    shown_seen = true;
    printf("PERF shown presented after %.1f ms (Browser.Tabs.TotalSwitchDuration3) PASS\n", (e->presented_us - e->start_us) / 1000.0);
    step = 2;
    after(0.3, [] { assert(ReArcViewResize(tab, lease.attachment_id, 500, 350, 1) == 0); });
  } else if (e->kind == 1 && step == 2) {
    assert(e->status == 0 && e->activated_us >= e->start_us && e->width == 500 * (int)window.backingScaleFactor);
    assert(!e->presented_us || e->presented_us >= e->activated_us);
    resized_seen = true;
    printf("PERF resized frame activated after %.1f ms, presented after %.1f ms PASS\n", (e->activated_us - e->start_us) / 1000.0,
           e->presented_us ? (e->presented_us - e->start_us) / 1000.0 : -1.0);
    step = 3;
    assert(ReArcMetricsGetHistogram(nullptr, [](void*, ReArcStatus, const ReArcHistogramSnapshot*) {}, nullptr) == REARC_INVALID_ARGUMENT);
    assert(ReArcMetricsGetHistogram("", [](void*, ReArcStatus, const ReArcHistogramSnapshot*) {}, nullptr) == REARC_INVALID_ARGUMENT);
    histogram("PageLoad.PaintTiming.NavigationToFirstContentfulPaint", REARC_OK);
    histogram("Browser.Tabs.TotalSwitchDuration3", REARC_OK);
    histogram("ReArc.Perf.NoSuchHistogram", REARC_NOT_FOUND);
  }
}
static void page_timing(void*, const ReArcPageTimingEvent* e) {
  printf("PERF page step=%d kind=%u nav=%llu start=%lld value=%lld (+%.1f ms) size=%llu url=%s\n", step, e->kind, e->navigation_id,
         e->navigation_start_us, e->value_us, (e->value_us - e->navigation_start_us) / 1000.0, e->size, e->url);
  assert(e->tab_id == tab && e->profile_id == profile && e->content_generation == 1 && e->navigation_id);
  assert(std::string(e->url) == base + "/perf" && e->value_us >= e->navigation_start_us && e->value_us <= now_us());
  if (navigation_start) assert(e->navigation_start_us == navigation_start);
  navigation_start = e->navigation_start_us;
  if (e->kind == 5) assert(e->size > 0);
  kinds.insert(e->kind);
  if (step == 0 && kinds.count(0) && kinds.count(2) && kinds.count(3) && kinds.count(4) && kinds.count(5)) {
    puts("PERF page timing: response start, FCP, DCL, load and LCP for one navigation PASS");
    step = 1;
    // Hidden, then shown: Chromium measures the switch from the lease's show.
    assert(ReArcViewSetVisible(tab, lease.attachment_id, false) == 0);
    after(0.5, [] { assert(ReArcViewSetVisible(tab, lease.attachment_id, true) == 0); });
  }
}
static void ready(void*, uint64_t p) {
  profile = p;
  assert(ReArcEngineABIMinorVersion() >= 44 && ReArcEngineHasFeature("perf_metrics"));
  ReArcEngineSetPageTimingCallback(page_timing, nullptr);
  ReArcEngineSetViewPresentationCallback(presentation, nullptr);
  window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  assert(ReArcWindowRegister(1, (__bridge void*)window) == 0);
  assert(ReArcTabCreate(p, 1, (base + "/perf").c_str(), &tab) == 0);
  assert(ReArcViewAttach(tab, 1, 400, 300, window.backingScaleFactor, &lease) == 0);
  [window.contentView addSubview:(__bridge NSView*)lease.native_view];
  [window makeKeyAndOrderFront:nil];
  assert(ReArcViewSetVisible(tab, lease.attachment_id, true) == 0);
  after(30, [] { printf("PERF timeout at step %d\n", step); assert(false); });
}
int main(int argc, const char** argv) { @autoreleasepool {
  setbuf(stdout, nullptr);
  base = "http://127.0.0.1:" + std::string(getenv("REARC_TEST_PORT"));
  ReArcCallbacks c{ready, [](void*, const ReArcTabEvent*) {}, nullptr, nullptr};
  assert(ReArcEngineConfigure(1, &c, nullptr) == 0);
  int r = ReArcEngineRun(argc, argv); assert(r == 0 && stopped); return r;
}}
