// Windowless persistent-container isolation. Never registers/attaches a view or creates NSWindow.
#import <Foundation/Foundation.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <functional>
#include <map>
#include <stdio.h>
#include <string>
using Action = std::function<void()>;
static uint64_t profiles[2], tabs[2];
static std::map<uint64_t, Action> loaded;
static std::string url;
static bool stopped, second;
static void evaluate(int index, const char* script, const char* expected, Action done) {
 struct Context { std::string expected; Action done; };
 auto* context = new Context{expected, std::move(done)};
 assert(ReArcTabEvaluateScript(tabs[index], script, 1, nullptr, 10000,
  [](void* raw, ReArcStatus status, uint64_t, uint64_t generation, const char* json, const char* error) {
   auto* context = static_cast<Context*>(raw);
   fprintf(stderr, "CONTAINER EVAL status=%d json=%s expected=%s error=%s\n", status,
           json ? json : "null", context->expected.c_str(), error ? error : "");
   assert(status == REARC_OK && generation && json && json == context->expected);
   auto done = std::move(context->done); delete context; done();
  }, context) == REARC_OK);
}
static void create(int index, Action done) {
 assert(ReArcTabCreate(profiles[index], 1, nullptr, &tabs[index]) == REARC_OK);
 loaded[tabs[index]] = std::move(done);
 assert(ReArcTabNavigate(tabs[index], url.c_str(), 0) == REARC_OK);
}
static void finish() {
 assert(ReArcEngineShutdown(true, [](void*, ReArcStatus status, bool cancelled) {
  assert(status == REARC_OK && !cancelled); stopped = true;
  puts("CONTAINERS persistent cookie/localStorage isolation and session reload PASS (windowless)");
 }, nullptr) == REARC_OK);
}
static void reload_in_b() {
 // Shell reassignment destroys the old tab and creates one in the destination profile.
 assert(ReArcTabClose(tabs[0], true, [](void*, ReArcStatus status, bool cancelled) {
  assert(status == REARC_OK && !cancelled);
  assert(ReArcTabCreate(profiles[1], 1, nullptr, &tabs[0]) == REARC_OK);
  loaded[tabs[0]] = [] {
   evaluate(0, "[document.cookie,localStorage.getItem('account')]", "[\"account=B\",\"B\"]", finish);
  };
  assert(ReArcTabNavigate(tabs[0], url.c_str(), 0) == REARC_OK);
 }, nullptr) == REARC_OK);
}
static void verify() {
 evaluate(0, "[document.cookie,localStorage.getItem('account')]", "[\"account=A\",\"A\"]", [] {
  evaluate(1, "[document.cookie,localStorage.getItem('account')]", "[\"account=B\",\"B\"]", reload_in_b);
 });
}
static void test() {
 if (second) { verify(); return; }
 evaluate(0, "[document.cookie,localStorage.getItem('account')]", "[\"\",null]", [] {
  evaluate(1, "[document.cookie,localStorage.getItem('account')]", "[\"\",null]", [] {
   evaluate(0, "document.cookie='account=A;max-age=86400;path=/';localStorage.setItem('account','A');true", "true", [] {
    evaluate(1, "[document.cookie,localStorage.getItem('account')]", "[\"\",null]", [] {
     evaluate(1, "document.cookie='account=B;max-age=86400;path=/';localStorage.setItem('account','B');true", "true", verify);
    });
   });
  });
 });
}
static void open_b(void*, ReArcStatus status, uint64_t id, bool otr) {
 assert(status == REARC_OK && id && id != profiles[0] && !otr); profiles[1] = id;
 create(0, [] { create(1, test); });
}
static void ready(void*, uint64_t) {
 assert(ReArcEngineHasFeature("profiles") && ReArcEngineHasFeature("script_evaluation"));
 assert(ReArcProfileOpen("11111111-1111-1111-1111-111111111111",
  [](void*, ReArcStatus status, uint64_t id, bool otr) {
   assert(status == REARC_OK && id && !otr); profiles[0] = id;
   assert(ReArcProfileOpen("22222222-2222-2222-2222-222222222222", open_b, nullptr) == REARC_OK);
  }, nullptr) == REARC_OK);
}
static void event(void*, const ReArcTabEvent* event) {
 if (event->kind != 1 || !(event->changes & 2) || !std::string(event->title).starts_with("probe:")) return;
 auto found = loaded.find(event->tab_id);
 if (found == loaded.end()) return;
 auto done = std::move(found->second); loaded.erase(found); done();
}
int main(int argc, const char** argv) { @autoreleasepool {
 setbuf(stdout, nullptr); second = getenv("REARC_CONTAINER_SECOND");
 url = "http://127.0.0.1:" + std::string(getenv("REARC_TEST_PORT")) + "/test";
 ReArcCallbacks callbacks{ready, event, nullptr, nullptr};
 assert(ReArcEngineConfigure(1, &callbacks, nullptr) == REARC_OK);
 int result = ReArcEngineRun(argc, argv); assert(result == 0 && stopped); return result;
}}
