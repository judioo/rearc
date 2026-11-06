#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <string>

// Wave 18b downloads over Chromium's DownloadManager: policy directory, a
// completed download, pause/resume/cancel/remove on a slow one, and an
// interrupted one. Reveal is invoked once on the completed file (Finder);
// open is checked for state validation only, to avoid launching an app.
static uint64_t tab, profile_id, otr_id, otr_tab;
static std::string base_url, directory;
static int step;
static bool stopped, paused_seen, resumed_seen;
static uint32_t small_id, slow_id, broken_id;
static int64_t resumed_at;
static void navigate(const char* path) {
  assert(ReArcTabNavigate(tab, (base_url + path).c_str(), 0) == REARC_OK);
}
static void finish() {
  assert(ReArcTabClose(tab, true, [](void*, ReArcStatus s, bool c) {
    assert(s == REARC_OK && !c);
    assert(ReArcEngineShutdown(true, [](void*, ReArcStatus s, bool c) {
      assert(s == REARC_OK && !c); stopped = true;
      puts("DOWNLOADS events/actions/policy PASS");
    }, nullptr) == REARC_OK);
  }, nullptr) == REARC_OK);
}
static void download_event(void*, const ReArcDownloadEvent* e) {
  assert([NSThread isMainThread] && (e->profile_id == profile_id || (otr_id && e->profile_id == otr_id)) && e->guid && e->url && e->target_path && e->mime_type);
  printf("DOWNLOADS step=%d kind=%u id=%u tab=%llu state=%u %lld/%lld paused=%d resume=%d danger=%u reason=%u path=%s url=%s\n",
         step, e->kind, e->download_id, e->tab_id, e->state, e->received_bytes, e->total_bytes, e->paused, e->can_resume, e->danger_type, e->interrupt_reason, e->target_path, e->url);
  std::string url(e->url), path(e->target_path);
  if (step == 0) {
    if (e->kind == 0) {
      assert(url == base_url + "/download/small" && e->tab_id == tab && e->state == 0 && !small_id);
      small_id = e->download_id;
      assert(ReArcDownloadAction(profile_id, small_id, 3) == REARC_INVALID_STATE);  // not complete
      return;
    }
    assert(e->download_id == small_id);
    if (e->kind != 2) { assert(e->kind == 1 && e->state == 0); return; }
    assert(e->state == 1 && e->received_bytes == 65536 && e->total_bytes == 65536 && e->danger_type == 0);
    assert(path == directory + "/rearc-small.bin");
    NSDictionary* attributes = [NSFileManager.defaultManager attributesOfItemAtPath:@(path.c_str()) error:nil];
    assert([attributes[NSFileSize] longLongValue] == 65536);
    assert(ReArcDownloadAction(profile_id, small_id, 0) == REARC_INVALID_STATE);  // pause complete
    assert(ReArcDownloadAction(profile_id, small_id, 2) == REARC_INVALID_STATE);  // cancel complete
    assert(ReArcDownloadAction(profile_id, small_id, 4) == REARC_OK);             // reveal
    puts("DOWNLOADS completed into policy directory + reveal PASS");
    step = 1; navigate("/download/slow");
    return;
  }
  if (step == 1) {
    if (e->kind == 0) {
      assert(url == base_url + "/download/slow" && e->tab_id == tab && !slow_id);
      slow_id = e->download_id; return;
    }
    assert(e->download_id == slow_id);
    if (!paused_seen && e->kind == 1 && e->received_bytes > 0 && !e->paused) {
      assert(e->total_bytes == 1048576);
      assert(ReArcDownloadAction(profile_id, slow_id, 0) == REARC_OK);
      paused_seen = true; return;
    }
    if (paused_seen && !resumed_seen && e->paused) {
      assert(e->state == 0 && e->can_resume);
      assert(ReArcDownloadAction(profile_id, slow_id, 0) == REARC_INVALID_STATE);  // already paused
      assert(ReArcDownloadAction(profile_id, slow_id, 1) == REARC_OK);
      resumed_seen = true; resumed_at = e->received_bytes; return;
    }
    if (resumed_seen && e->kind == 1 && !e->paused && e->received_bytes > resumed_at && resumed_at >= 0) {
      puts("DOWNLOADS pause/resume PASS");
      resumed_at = -1;
      assert(ReArcDownloadAction(profile_id, slow_id, 2) == REARC_OK);
      return;
    }
    if (e->kind == 4) {
      assert(e->state == 2);
      assert(ReArcDownloadAction(profile_id, slow_id, 1) == REARC_INVALID_STATE);
      assert(ReArcDownloadAction(profile_id, slow_id, 5) == REARC_OK);
      return;
    }
    if (e->kind == 5) {
      assert(ReArcDownloadAction(profile_id, slow_id, 4) == REARC_NOT_FOUND);
      puts("DOWNLOADS cancel/remove PASS");
      step = 2; navigate("/download/broken");
    }
    return;
  }
  if (step == 2) {
    if (e->kind == 0) {
      assert(url == base_url + "/download/broken" && !broken_id);
      broken_id = e->download_id; return;
    }
    assert(e->download_id == broken_id);
    if (e->kind == 3) {
      assert(e->state == 3 && e->interrupt_reason != 0);
      puts("DOWNLOADS interrupted PASS");
      step = 3;
      assert(ReArcDownloadAction(profile_id, broken_id, 2) == REARC_OK);
      return;
    }
    return;
  }
  if (step == 3 && e->kind == 4 && e->download_id == broken_id) {
    puts("DOWNLOADS cancel interrupted PASS");
    // Chromium forces "ask where to save" for OTR profiles; embedded mode must
    // save at the suggested path instead of opening a picker.
    step = 4;
    assert(ReArcProfileCreateOffTheRecord(profile_id, [](void*, ReArcStatus s, uint64_t id, bool otr) {
      assert(s == REARC_OK && otr && id);
      otr_id = id;
      assert(ReArcTabCreate(otr_id, 2, (base_url + "/download/small").c_str(), &otr_tab) == REARC_OK);
    }, nullptr) == REARC_OK);
    return;
  }
  if (step == 4 && e->profile_id == otr_id) {
    if (e->kind == 0) assert(e->tab_id == otr_tab);
    if (e->kind == 2) {
      assert(e->state == 1 && e->received_bytes == 65536);
      assert(std::string(e->target_path).starts_with(directory + "/rearc-small") && std::string(e->target_path) != directory + "/rearc-small.bin");
      puts("DOWNLOADS OTR completes without a picker (uniquified) PASS");
      step = 5;
      assert(ReArcTabClose(otr_tab, true, [](void*, ReArcStatus s, bool c) { assert(s == REARC_OK && !c); finish(); }, nullptr) == REARC_OK);
    }
    assert(e->kind != 3 && e->kind != 4);
  }
}
static void ready(void*, uint64_t profile) {
  assert(ReArcEngineABIMinorVersion() >= 17 && ReArcEngineHasFeature("downloads"));
  profile_id = profile;
  ReArcEngineSetDownloadCallback(download_event, nullptr);
  assert(ReArcDownloadSetPolicy(profile, "relative/dir", 0) == REARC_INVALID_ARGUMENT);
  assert(ReArcDownloadSetPolicy(profile, "/tmp/../etc", 0) == REARC_INVALID_ARGUMENT);
  assert(ReArcDownloadSetPolicy(profile, directory.c_str(), 2) == REARC_INVALID_ARGUMENT);
  assert(ReArcDownloadSetPolicy(profile, directory.c_str(), 1) == REARC_UNSUPPORTED);
  assert(ReArcDownloadSetPolicy(987654, directory.c_str(), 0) == REARC_PROFILE_NOT_FOUND);
  assert(ReArcDownloadSetPolicy(profile, directory.c_str(), 0) == REARC_OK);
  assert(ReArcDownloadAction(profile, 424242, 0) == REARC_NOT_FOUND);
  assert(ReArcDownloadAction(profile, 1, 6) == REARC_INVALID_ARGUMENT);
  assert(ReArcDownloadAction(987654, 1, 0) == REARC_PROFILE_NOT_FOUND);
  assert(ReArcTabCreate(profile, 1, (base_url + "/visit-a").c_str(), &tab) == REARC_OK);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    navigate("/download/small");
  });
}
int main(int argc, const char** argv) { @autoreleasepool {
  setbuf(stdout, nullptr);
  base_url = "http://127.0.0.1:" + std::string(getenv("REARC_TEST_PORT"));
  assert(getenv("REARC_DOWNLOAD_DIR"));
  directory = getenv("REARC_DOWNLOAD_DIR");
  ReArcCallbacks c{ready, [](void*, const ReArcTabEvent* e) { assert(!e->is_crashed); }, nullptr, nullptr};
  assert(ReArcEngineConfigure(1, &c, nullptr) == REARC_OK);
  int result = ReArcEngineRun(argc, argv); assert(result == 0 && stopped);
  return result;
}}
