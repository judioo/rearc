// ABI 1.53: no windows, prompts, UI automation, or real Web Store traffic.
#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <set>
#include <string>
#include <vector>

static bool stopped, inside;
static uint64_t profile;
static std::string loaded_id, removed_id;
static uint32_t replies;
static std::set<std::string> seen;
static void unexpected(void*, const char*, int32_t, const char*, uint32_t, uint32_t) { assert(false); }
static void shutdown_done(void*, ReArcStatus status, bool cancelled) {
  assert(status == REARC_OK && !cancelled);
  stopped = true;
  puts("BULK extensions runtime PASS");
}
static void finish() {
  assert(ReArcEngineShutdown(true, shutdown_done, nullptr) == REARC_OK);
}
static void batch_reply(void*, const char* id, int32_t result, const char* reason,
                        uint32_t completed, uint32_t total) {
  assert(!inside && total == 9 && completed == ++replies);
  assert(seen.insert(id).second);
  if (id == loaded_id) assert(result == 1);
  else if (id == removed_id) assert(result == 2);
  else if (*id >= 'a' && *id <= 'e') assert(result == 2);
  else if (*id == 'f') assert(result == 3 && reason && *reason);
  else if (*id == 'g') assert(result == 4 && reason && *reason);
  else assert(false);
  fprintf(stderr, "BULK result id=%s status=%d progress=%u/%u reason=%s\n", id, result, completed, total, reason);
  if (completed == total) finish();
}
static void batch() {
  std::vector<std::string> ids{loaded_id, removed_id};
  for (char c = 'a'; c <= 'g'; ++c) ids.emplace_back(32, c);
  std::vector<const char*> pointers;
  for (auto& id : ids) pointers.push_back(id.c_str());
  inside = true;
  assert(ReArcProfileInstallExtensions(profile, pointers.data(), pointers.size(), batch_reply, nullptr) == REARC_OK);
  assert(ReArcProfileInstallExtensions(profile, pointers.data(), pointers.size(), unexpected, nullptr) == REARC_BUSY);
  assert(ReArcProfileClose(profile, true, [](void*, ReArcStatus, bool) { assert(false); }, nullptr) == REARC_BUSY);
  assert(ReArcEngineShutdown(true, shutdown_done, nullptr) == REARC_BUSY);
  inside = false;
}
static void missing_unpacked(void*, const char*, int32_t result, const char* reason, uint32_t completed, uint32_t total) {
  assert(!inside && result == 3 && reason && *reason && completed == 1 && total == 1);
  batch();
}
static void loaded(void*, const char* id, int32_t result, const char* reason, uint32_t completed, uint32_t total) {
  assert(!inside && result == 0 && id && *id && completed == 1 && total == 1);
  loaded_id = id;
  inside = true;
  assert(ReArcProfileLoadUnpackedExtension(profile, "/nonexistent/rearc-fixture", missing_unpacked, nullptr) == REARC_OK);
  inside = false;
}
static void opened(void*, ReArcStatus status, uint64_t id, bool otr) {
  assert(status == REARC_OK && !otr);
  profile = id;
  const char* invalid[]{"bad"};
  const char* duplicate[]{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"};
  assert(ReArcProfileInstallExtensions(id, invalid, 1, unexpected, nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcProfileInstallExtensions(id, duplicate, 2, unexpected, nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcProfileInstallExtensions(id, nullptr, 0, unexpected, nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcProfileLoadUnpackedExtension(id, "relative", unexpected, nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcProfileInstallExtensions(9999999, duplicate, 1, unexpected, nullptr) == REARC_PROFILE_NOT_FOUND);
  inside = true;
  assert(ReArcProfileLoadUnpackedExtension(id, getenv("REARC_BULK_UNPACKED"), loaded, nullptr) == REARC_OK);
  inside = false;
}
static void ready(void*, uint64_t) {
  assert(ReArcEngineABIMinorVersion() >= 53 && ReArcEngineHasFeature("extension_bulk_install"));
  ReArcEngineSetExtensionPromptCallback([](void*, const ReArcExtensionPromptEvent*) { assert(false); }, nullptr);
  assert(ReArcProfileOpen("BulkFixture", opened, nullptr) == REARC_OK);
}
int main(int argc, const char** argv) { @autoreleasepool {
  setbuf(stdout, nullptr);
  removed_id = getenv("REARC_BULK_REMOVED_ID");
  ReArcCallbacks callbacks{ready, nullptr, nullptr, nullptr};
  assert(ReArcEngineConfigure(1, &callbacks, nullptr) == REARC_OK);
  int result = ReArcEngineRun(argc, argv);
  assert(result == 0 && stopped && replies == 9);
  return result;
}}
