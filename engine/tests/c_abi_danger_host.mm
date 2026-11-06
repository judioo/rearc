#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <string>
static uint64_t profile, tab;
static uint32_t kept, discarded;
static int phase;
static bool stopped;
static std::string base_url, directory;
static void navigate(const char* name) {
  assert(ReArcTabNavigate(tab, (base_url + "/download/" + name).c_str(), 1) == REARC_OK);
}
static void event(void*, const ReArcDownloadEvent* e) {
  printf("DANGER phase=%d kind=%u id=%u state=%u danger=%u bytes=%lld\n",phase,e->kind,e->download_id,e->state,e->danger_type,e->received_bytes);
  ReArcDownloadWarning warning{};
  if (e->kind == 5) {
    assert(phase == 2 && e->download_id == discarded);
    assert(ReArcDownloadGetWarning(profile, discarded, &warning) == REARC_NOT_FOUND);
    assert(ReArcDownloadResolveDanger(profile, discarded, 0) == REARC_NOT_FOUND);
    assert(![[NSFileManager defaultManager] fileExistsAtPath:@(e->target_path)]);
    phase = 3;
    assert(ReArcEngineShutdown(true, [](void*, ReArcStatus s, bool c) {
      assert(s == REARC_OK && !c); stopped = true;
      puts("DANGER real warning / explicit keep / discard / invalid states PASS");
    }, nullptr) == REARC_OK);
    return;
  }
  if (phase == 2 && discarded == e->download_id && e->kind == 4) return;
  assert(ReArcDownloadGetWarning(profile, e->download_id, &warning) == REARC_OK);
  // Queued event snapshots may precede current item state.
  if (phase == 0 && warning.is_dangerous && e->received_bytes == 65536) {
    assert(warning.danger_type != 0);
    kept = e->download_id; phase = 1;
    assert(ReArcDownloadResolveDanger(profile, kept, 2) == REARC_INVALID_ARGUMENT);
    assert(ReArcDownloadResolveDanger(999999, kept, 0) == REARC_PROFILE_NOT_FOUND);
    assert(ReArcDownloadResolveDanger(profile, kept, 0) == REARC_OK);
    assert(ReArcDownloadResolveDanger(profile, kept, 0) == REARC_INVALID_STATE);
  } else if (phase == 1 && e->kind == 2 && e->download_id == kept) {
    assert(e->state == 1 && e->received_bytes == 65536 && !warning.is_dangerous);
    NSDictionary* attrs = [NSFileManager.defaultManager attributesOfItemAtPath:@(e->target_path) error:nil];
    assert([attrs[NSFileSize] longLongValue] == 65536);
    assert(ReArcDownloadResolveDanger(profile, kept, 1) == REARC_INVALID_STATE);
    phase = 2; navigate("danger-discard");
  } else if (phase == 2 && warning.is_dangerous && e->received_bytes == 65536) {
    discarded = e->download_id;
    assert(ReArcDownloadResolveDanger(profile, discarded, 1) == REARC_OK);
    // Removal emits queued events, but the item identity is already retired.
    assert(ReArcDownloadResolveDanger(profile, discarded, 1) == REARC_NOT_FOUND);
  }
}
static void ready(void*, uint64_t id) {
  profile = id;
  assert(ReArcEngineABIMinorVersion() >= 24 && ReArcEngineHasFeature("dangerous_downloads"));
  ReArcEngineSetDownloadCallback(event, nullptr);
  assert(ReArcDownloadGetWarning(profile, 1, nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcDownloadResolveDanger(profile, 999999, 0) == REARC_NOT_FOUND);
  assert(ReArcDownloadSetPolicy(profile, directory.c_str(), 0) == REARC_OK);
  assert(ReArcTabCreate(profile, 1, (base_url + "/visit-a").c_str(), &tab) == REARC_OK);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{navigate("danger-keep");});
}
int main(int argc, const char** argv) { @autoreleasepool {
  setbuf(stdout, nullptr);
  base_url = "http://127.0.0.1:" + std::string(getenv("REARC_TEST_PORT"));
  directory = getenv("REARC_DOWNLOAD_DIR");
  ReArcCallbacks c{ready, nullptr, nullptr, nullptr};
  assert(ReArcEngineConfigure(1, &c, nullptr) == REARC_OK);
  int result = ReArcEngineRun(argc, argv); assert(!result && stopped); return result;
}}
