// ABI 1.53/1.61/1.63: no windows, UI automation, or real Web Store traffic.
#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <string>
#include <vector>

static bool stopped, inside, prompted;
static uint64_t profile;
static std::string loaded_id, removed_id;
static uint32_t replies, cancelled;
static std::set<std::string> seen;
static void unexpected(void*, const char*, int32_t, const char*, uint32_t, uint32_t) { assert(false); }
static void shutdown_done(void*, ReArcStatus status, bool cancelled_shutdown) {
  assert(status == REARC_OK && !cancelled_shutdown);
  // 1.61 follow-up: a running batch no longer blocks shutdown; every ID was
  // answered before this, the last callback.
  assert(cancelled == 3);
  stopped = true;
  puts("BULK extensions runtime PASS");
}
static void cancel_reply(void*, const char* id, int32_t result, const char* reason,
                         uint32_t completed, uint32_t total) {
  assert(!stopped && total == 3 && completed == ++cancelled);
  assert(result == 3 && reason && strstr(reason, "shutting down"));
  fprintf(stderr, "BULK cancelled id=%s progress=%u/%u reason=%s\n", id, completed, total, reason);
}
static void cancel_on_shutdown() {
  std::vector<std::string> ids{std::string(32, 'h'), std::string(32, 'i'), std::string(32, 'j')};
  std::vector<const char*> pointers;
  for (auto& id : ids) pointers.push_back(id.c_str());
  assert(ReArcProfileInstallExtensions(profile, pointers.data(), pointers.size(), cancel_reply, nullptr) == REARC_OK);
  assert(ReArcEngineShutdown(true, shutdown_done, nullptr) == REARC_OK);
}
static const char* kSourceManifest =
    R"({"name":"Fixture","version":"0.9","manifest_version":3})";
static const char* kSameManifest =
    R"({"name":"Fixture","version":"0.9","manifest_version":3,"permissions":["tabs"],"host_permissions":["<all_urls>"]})";
static void same_reply(void*, const char* id, int32_t result, const char*, uint32_t completed, uint32_t total) {
  // No increase: no prompt, then the store download's 204 (removed listing).
  assert(id == removed_id && result == 2 && completed == 1 && total == 1);
  puts("BULK source permissions equal: no prompt PASS");
  cancel_on_shutdown();
}
static void more_reply(void*, const char* id, int32_t result, const char* reason, uint32_t completed, uint32_t total) {
  assert(prompted && id == removed_id && result == 3 && reason && completed == 1 && total == 1);
  puts("BULK store asks for more than the source: install prompt, cancelled PASS");
  prompted = false;
  ReArcExtensionInstallSource same{removed_id.c_str(), kSameManifest};
  assert(ReArcProfileInstallExtensionSources(profile, &same, 1, same_reply, nullptr) == REARC_OK);
}
static void prompt(void*, const ReArcExtensionPromptEvent* e) {
  if (e->phase != 0) return;
  // Only the 1.61 permission increase may prompt; never the ID-only import.
  assert(!prompted && e->kind == 0 && e->tab_id == 0 && e->extension_id == removed_id);
  assert(e->permission_count > 0);
  for (size_t i = 0; i < e->permission_count; ++i) fprintf(stderr, "BULK prompt permission: %s\n", e->permissions[i]);
  prompted = true;
  assert(ReArcExtensionPromptRespond(e->request_id, 1) == REARC_OK);
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
  if (completed == total) {
    ReArcExtensionInstallSource more{removed_id.c_str(), kSourceManifest};
    assert(ReArcProfileInstallExtensionSources(profile, &more, 1, more_reply, nullptr) == REARC_OK);
  }
}
static void batch() {
  std::vector<std::string> ids{loaded_id, removed_id};
  for (char c = 'a'; c <= 'g'; ++c) ids.emplace_back(32, c);
  std::vector<const char*> pointers;
  for (auto& id : ids) pointers.push_back(id.c_str());
  inside = true;
  assert(ReArcProfileInstallExtensions(profile, pointers.data(), pointers.size(), batch_reply, nullptr) == REARC_OK);
  assert(ReArcProfileInstallExtensions(profile, pointers.data(), pointers.size(), unexpected, nullptr) == REARC_BUSY);
  // The startup profile (where --load-extension applies) can never be closed.
  assert(ReArcProfileClose(profile, true, [](void*, ReArcStatus, bool) { assert(false); }, nullptr) != REARC_OK);
  inside = false;
}
// The --load-extension fixture loads asynchronously at startup: ask until the
// installer reports it already installed (else its ID is just not in store).
static int attempts;
static void probe();
static void probe_reply(void*, const char* id, int32_t result, const char*, uint32_t completed, uint32_t total) {
  assert(id == loaded_id && completed == 1 && total == 1 && (result == 1 || result == 2));
  if (result == 1) {
    batch();
    return;
  }
  assert(++attempts < 40);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ probe(); });
}
static void probe() {
  const char* ids[]{loaded_id.c_str()};
  assert(ReArcProfileInstallExtensions(profile, ids, 1, probe_reply, nullptr) == REARC_OK);
}
static void ready(void*, uint64_t default_profile) {
  assert(ReArcEngineABIMinorVersion() >= 63 && ReArcEngineHasFeature("extension_bulk_install") &&
         ReArcEngineHasFeature("extension_install_sources"));
  ReArcEngineSetExtensionPromptCallback(prompt, nullptr);
  profile = default_profile;
  const char* invalid[]{"bad"};
  const char* duplicate[]{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"};
  assert(ReArcProfileInstallExtensions(profile, invalid, 1, unexpected, nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcProfileInstallExtensions(profile, duplicate, 2, unexpected, nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcProfileInstallExtensions(profile, nullptr, 0, unexpected, nullptr) == REARC_INVALID_ARGUMENT);
  assert(ReArcProfileInstallExtensions(9999999, duplicate, 1, unexpected, nullptr) == REARC_PROFILE_NOT_FOUND);
  ReArcExtensionInstallSource no_manifest{duplicate[0], nullptr};
  assert(ReArcProfileInstallExtensionSources(profile, &no_manifest, 1, unexpected, nullptr) == REARC_INVALID_ARGUMENT);
  ReArcExtensionInstallSource bad_id{"bad", kSourceManifest};
  assert(ReArcProfileInstallExtensionSources(profile, &bad_id, 1, unexpected, nullptr) == REARC_INVALID_ARGUMENT);
  probe();
}
int main(int argc, const char** argv) { @autoreleasepool {
  setbuf(stdout, nullptr);
  removed_id = getenv("REARC_BULK_REMOVED_ID");
  loaded_id = getenv("REARC_BULK_LOADED_ID");
  ReArcCallbacks callbacks{ready, nullptr, nullptr, nullptr};
  assert(ReArcEngineConfigure(1, &callbacks, nullptr) == REARC_OK);
  int result = ReArcEngineRun(argc, argv);
  assert(result == 0 && stopped && replies == 9 && cancelled == 3);
  return result;
}}
