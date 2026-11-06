#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <functional>
#include <map>
#include <string>

// Wave 18f extensions. run_c_abi.py writes local unpacked MV3 fixtures and
// passes --load-extension; the "store" is a loopback page on localhost made
// the gallery origin with --apps-gallery-url, installing Chromium's own
// test-publisher-signed webstore_private fixture CRX. Nothing is fetched from
// the real Web Store.
// Content scripts (tab/049): the "cs" fixture's content script, runtime
// messaging with sender.tab, webNavigation, tabs.sendMessage and
// scripting.executeScript by tab ID all reach a registry tab. An OTR tab of
// the same engine gets no content script (not incognito-enabled).
// Prompts (tab/050): webstorePrivate install with no callback aborts without
// UI; with a callback the host cancels, then accepts a CRX without publisher
// proof (install-failed notification). A locally signed CRX3 dropped on
// chrome://extensions (developer mode; real NSDraggingDestination with a
// synthetic NSDraggingInfo, as in the drops host) is accepted through the
// host and installed (notification, no Chromium window). chrome://extensions'
// confirmed uninstall is a host request (cancel, then accept).
// Actions (tab/051): the toolbar list (title, badge, colors, popup flag,
// 2x icon), a click that grants activeTab to an onClicked extension, and a
// popup hosted as an attachable registry tab that auto-sizes and closes
// itself with window.close().
// The DevTools socket is test-only (user gestures), as in the helpers host.
@interface FakeDrag : NSObject <NSDraggingInfo>
@property(strong) NSPasteboard* pasteboard;
@property NSPoint location;
@property(strong) NSWindow* window;
@end
@implementation FakeDrag
@synthesize draggingFormation, animatesToDestination, numberOfValidItemsForDrop, springLoadingHighlight;
- (NSWindow*)draggingDestinationWindow { return _window; }
- (NSDragOperation)draggingSourceOperationMask { return NSDragOperationCopy | NSDragOperationLink | NSDragOperationGeneric; }
- (NSPoint)draggingLocation { return _location; }
- (NSPoint)draggedImageLocation { return _location; }
- (NSImage*)draggedImage { return nil; }
- (NSPasteboard*)draggingPasteboard { return _pasteboard; }
- (id)draggingSource { return nil; }
- (NSInteger)draggingSequenceNumber { return 7; }
- (void)slideDraggedImageTo:(NSPoint)point {}
- (NSArray<NSString*>*)namesOfPromisedFilesDroppedAtDestination:(NSURL*)url { return nil; }
- (void)enumerateDraggingItemsWithOptions:(NSDraggingItemEnumerationOptions)o forView:(NSView*)v classes:(NSArray*)c searchOptions:(NSDictionary*)s usingBlock:(void (^)(NSDraggingItem*, NSInteger, BOOL*))b {}
- (void)resetSpringLoading {}
@end

static uint64_t profile, tab, otr_profile, otr_tab;
static NSWindow* window;
static ReArcAttachment lease{};
static std::string base, store, profile_path;
static int stage, reloads, prompts, uninstall_prompts, cancels, installed, failed;
static bool stopped, settled;
// Chromium's webstore_private fixture CRX has no publisher proof; the
// dropped CRX is signed per run by run_c_abi.py.
static const std::string kUnsignedId = "enfkhcelefdadlmkffamgdlgplcionje";
static std::string kStoreId;

static std::string field(const std::string& json, const std::string& key) {
  auto at = json.find("\"" + key + "\":\"");
  if (at == std::string::npos) return "";
  at += key.size() + 4;
  std::string out;
  for (; at < json.size() && json[at] != '"'; ++at) {
    if (json[at] == '\\') ++at;
    out += json[at];
  }
  return out;
}
static void later(double seconds, std::function<void()> f) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ f(); });
}
static std::function<void(std::string)> eval_done;
static void evaluate(uint64_t id, const char* source, std::function<void(std::string)> done) {
  eval_done = std::move(done);
  assert(ReArcTabEvaluateScript(id, source, 1, nullptr, 20000, [](void*, ReArcStatus s, uint64_t, uint64_t, const char* json, const char* error) {
    if (s) printf("EXT eval status=%d %s\n", s, error ? error : "");
    assert(s == REARC_OK);
    auto done = std::move(eval_done);
    done(json);
  }, nullptr) == REARC_OK);
}

// Test-only loopback CDP: page evaluation with a user gesture.
namespace cdp {
static NSURLSession* session;
static NSURLSessionWebSocketTask* socket_;
static int next_id = 1;
static std::function<void(NSDictionary*)> pending;
static NSArray* port_lines() {
  NSString* file = [NSString stringWithUTF8String:(profile_path + "/DevToolsActivePort").c_str()];
  return [[NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"];
}
static void receive() {
  [socket_ receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage* msg, NSError* error) {
    assert(!error && msg);
    NSDictionary* reply = [NSJSONSerialization JSONObjectWithData:[msg.string dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!reply[@"id"]) { receive(); return; }
      printf("EXT cdp %s\n", msg.string.UTF8String);
      assert(!reply[@"error"] && !reply[@"result"][@"exceptionDetails"]);
      auto done = std::move(pending);
      pending = nullptr;
      done(reply[@"result"]);
    });
  }];
}
static void send(NSString* method, NSDictionary* params, std::function<void(NSDictionary*)> done) {
  pending = std::move(done);
  NSData* payload = [NSJSONSerialization dataWithJSONObject:@{@"id":@(next_id++),@"method":method,@"params":params} options:0 error:nil];
  [socket_ sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:[[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding]] completionHandler:^(NSError* error) { assert(!error); }];
  receive();
}
static void attach(std::string prefix, std::function<void()> done) {
  NSURL* list = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%@/json/list", port_lines()[0]]];
  [[session dataTaskWithURL:list completionHandler:^(NSData* data, NSURLResponse*, NSError* error) {
    assert(!error && data);
    NSArray* targets = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      NSString* ws = nil;
      for (NSDictionary* t in targets)
        if ([t[@"url"] hasPrefix:[NSString stringWithUTF8String:prefix.c_str()]]) ws = t[@"webSocketDebuggerUrl"];
      if (!ws) printf("EXT targets %s\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
      assert(ws);
      if (socket_) [socket_ cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
      socket_ = [session webSocketTaskWithURL:[NSURL URLWithString:ws]];
      [socket_ resume];
      send(@"Emulation.setFocusEmulationEnabled", @{@"enabled":@YES}, [done](NSDictionary*) { done(); });
    });
  }] resume];
}
// Evaluates `expression` (a Promise of a string) with a user gesture.
static void gesture(NSString* expression, std::function<void(std::string)> done) {
  send(@"Runtime.evaluate", @{@"expression":expression,@"awaitPromise":@YES,@"returnByValue":@YES,@"userGesture":@YES,@"timeout":@30000},
       [done](NSDictionary* result) {
         id value = result[@"result"][@"value"];
         done([value isKindOfClass:NSString.class] ? std::string([value UTF8String]) : std::string([[value description] UTF8String]));
       });
}
static void close_browser() {
  NSArray* lines = port_lines();
  socket_ = [session webSocketTaskWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"ws://127.0.0.1:%@%@", lines[0], lines[1]]]];
  [socket_ resume];
  [socket_ sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:@"{\"id\":1,\"method\":\"Browser.close\"}"] completionHandler:^(NSError* error) { assert(!error); }];
}
}  // namespace cdp

static void finish() {
  assert(ReArcEngineShutdown(true, [](void*, ReArcStatus s, bool c) {
    assert(s == REARC_OK && !c);
    ReArcViewRelease(lease.native_view);
    stopped = true;
    puts("EXTENSIONS PASS");
  }, nullptr) == REARC_OK);
  cdp::close_browser();
}
static void navigate(const std::string& url) {
  settled = false;
  assert(ReArcTabNavigate(tab, url.c_str(), 0) == REARC_OK);
}
// Only the test's own window may be on screen: Chromium opened no Browser
// window or dialog for any prompt or install.
static void assert_no_chromium_windows() {
  for (NSWindow* w in NSApp.windows) {
    // Menu-bar status items (NSStatusBarWindow, present before any extension
    // loads) are not Browser windows or dialogs; anything else visible is.
    if (w == window || !w.visible || [w.className isEqualToString:@"NSStatusBarWindow"]) continue;
    printf("EXT unexpected window %s title=%s\n", w.className.UTF8String, w.title.UTF8String);
    assert(false);
  }
}
static void after(std::function<bool()> condition, std::function<void()> then, int tries = 100) {
  if (condition() || tries <= 0) { then(); return; }
  later(0.1, [condition, then, tries] { after(condition, then, tries - 1); });
}

// --- tab/051 toolbar actions ---------------------------------------------
struct Action { std::string id, name, title, badge; uint32_t badge_bg; bool visible, popup; size_t icon; uint32_t icon_width; };
static std::string act_id, click_id;
static uint64_t popup_tab;
static ReArcAttachment popup_lease{};
static int popup_resizes, action_events;
static int32_t popup_width, popup_height;
static bool popup_created, popup_closed, popup_titled;
static void store_stage();
static void action_event(void*, const ReArcExtensionActionEvent* e) {
  printf("EXT action event kind=%u profile=%llu tab=%llu ext=%s popup=%llu size=%dx%d\n", e->kind, e->profile_id, e->tab_id,
         e->extension_id, e->popup_tab_id, e->width, e->height);
  ++action_events;
  if (e->kind == 3) {
    assert(e->tab_id == tab && e->popup_tab_id == popup_tab && std::string(e->extension_id) == act_id);
    popup_width = e->width;
    popup_height = e->height;
    ++popup_resizes;
    assert(ReArcViewResize(popup_tab, popup_lease.attachment_id, e->width, e->height, 1) == REARC_OK);
  }
}
static std::function<void(std::vector<Action>)> actions_done;
static void query_actions(std::function<void(std::vector<Action>)> done) {
  actions_done = std::move(done);
  assert(ReArcTabGetExtensionActions(tab, 2, [](void*, ReArcStatus s, const ReArcExtensionActionList* list) {
    assert(s == REARC_OK && list->tab_id == tab && list->profile_id == profile);
    std::vector<Action> out;
    for (size_t i = 0; i < list->count; ++i) {
      const ReArcExtensionAction& a = list->actions[i];
      uint32_t width = 0;
      if (a.icon_png_size > 24) width = a.icon_png[16] << 24 | a.icon_png[17] << 16 | a.icon_png[18] << 8 | a.icon_png[19];
      out.push_back({a.extension_id, a.name, a.title, a.badge_text, a.badge_background_color, a.visible, a.has_popup, a.icon_png_size, width});
    }
    auto done = std::move(actions_done);
    done(out);
  }, nullptr) == REARC_OK);
}
static void finish_actions() {
  assert(popup_closed && popup_titled && popup_resizes >= 1);
  assert(popup_width >= 318 && popup_width <= 322 && popup_height >= 178 && popup_height <= 182);
  ReArcViewRelease(popup_lease.native_view);
  puts("EXT action popup: attachable registry tab (popup view type), auto-resize event, window.close() closes it PASS");
  store_stage();
}
static void run_popup() {
  uint32_t result = 9;
  assert(ReArcTabRunExtensionAction(tab, act_id.c_str(), &result, &popup_tab) == REARC_OK);
  printf("EXT run popup action result=%u popup_tab=%llu\n", result, popup_tab);
  assert(result == 1 && popup_tab && popup_tab != tab);
}
static void actions_stage(int tries = 0) {
  query_actions([tries](std::vector<Action> list) {
    const Action* act = nullptr;
    const Action* click = nullptr;
    for (const auto& a : list) {
      printf("EXT action id=%s name=%s title=%s badge=%s bg=%08x visible=%d popup=%d icon=%zu/%upx\n", a.id.c_str(), a.name.c_str(),
             a.title.c_str(), a.badge.c_str(), a.badge_bg, a.visible, a.popup, a.icon, a.icon_width);
      if (a.name == "ReArc popup action fixture") act = &a;
      if (a.name == "ReArc click action fixture") click = &a;
    }
    if ((!act || !click || act->badge != "7" || act->icon_width != 32) && tries < 50) {
      later(0.2, [tries] { actions_stage(tries + 1); });
      return;
    }
    assert(act && click);
    assert(act->title == "ReArc popup" && act->visible && act->popup && act->badge == "7" && act->badge_bg == 0xffff0000u);
    assert(act->icon && act->icon_width == 32);
    assert(click->title == "ReArc click" && click->visible && !click->popup && click->icon);
    act_id = act->id;
    click_id = click->id;
    puts("EXT toolbar action list: title, badge text/color, popup flag, 2x icon PASS");
    uint32_t result = 9;
    uint64_t popup = 9;
    assert(ReArcTabRunExtensionAction(tab, "not-an-extension-id", &result, &popup) == REARC_INVALID_ARGUMENT);
    assert(ReArcTabRunExtensionAction(tab, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", &result, &popup) == REARC_NOT_FOUND && !result && !popup);
    assert(ReArcTabRunExtensionAction(tab, click_id.c_str(), &result, &popup) == REARC_OK && result == 0 && popup == 0);
    evaluate(tab, "(async()=>{for(let i=0;i<100&&!document.documentElement.dataset.rearcClicked;++i)"
                  "await new Promise(r=>setTimeout(r,100));return {...document.documentElement.dataset}})()", [](std::string json) {
      printf("EXT after click %s\n", json.c_str());
      assert(field(json, "rearcClicked") == "yes");
      puts("EXT run action: onClicked extension granted activeTab and scripted the tab PASS");
      run_popup();
    });
  });
}

static void prompt_event(void*, const ReArcExtensionPromptEvent* e) {
  printf("EXT prompt phase=%u kind=%u id=%llu tab=%llu ext=%s name=%s title=%s accept=%s cancel=%s perms=%zu icon=%zu error=%s\n",
         e->phase, e->kind, e->request_id, e->tab_id, e->extension_id, e->name, e->title, e->accept_label,
         e->cancel_label, e->permission_count, e->icon_png_size, e->error);
  for (size_t i = 0; i < e->permission_count; ++i) printf("EXT   permission %s\n", e->permissions[i]);
  assert(e->profile_id == profile);
  if (e->phase == 1) { ++cancels; assert(ReArcExtensionPromptRespond(e->request_id, 0) == REARC_NOT_FOUND); return; }
  if (e->phase == 2) {
    assert(e->request_id == 0 && std::string(e->extension_id) == kStoreId && *e->name && e->icon_png_size);
    ++installed;
    return;
  }
  if (e->phase == 3) {
    assert(e->request_id == 0 && std::string(e->error).find("CRX_REQUIRED_PROOF_MISSING") != std::string::npos);
    ++failed;
    return;
  }
  assert(e->phase == 0 && e->request_id);
  assert(ReArcExtensionPromptRespond(e->request_id, 7) == REARC_INVALID_ARGUMENT);
  if (e->kind == 100) {
    assert(std::string(e->extension_id) == kStoreId && *e->title && *e->accept_label);
    ++uninstall_prompts;
    assert(ReArcExtensionPromptRespond(e->request_id, uninstall_prompts == 1 ? 1 : 0) == REARC_OK);
  } else {
    assert(e->kind == 0 && e->tab_id == tab);
    assert(std::string(e->extension_id) == (prompts < 3 ? kUnsignedId : kStoreId));
    assert(*e->title && *e->accept_label && *e->cancel_label && e->permission_count >= 1);
    ++prompts;
    if (prompts == 2) {
      // Replacement withdraws the pending request (Chromium aborts it); the
      // new registration gets no event for it and the old ID is stale.
      ReArcEngineSetExtensionPromptCallback(prompt_event, nullptr);
      assert(ReArcExtensionPromptRespond(e->request_id, 0) == REARC_NOT_FOUND);
      return;
    }
    assert(ReArcExtensionPromptRespond(e->request_id, prompts == 1 ? 1 : 0) == REARC_OK);
  }
  assert(ReArcExtensionPromptRespond(e->request_id, 0) == REARC_NOT_FOUND);
}

static void store_stage() {
  stage = 2;
  navigate(store + "/webstore");
}
// Stage 2: the store page. Attempt 1 has no callback (abort, no event);
// attempt 2 is cancelled by the host; attempt 3 is accepted but its CRX has
// no publisher proof (install-failed notification).
static NSString* call(const char* f, const std::string& id) {
  return [NSString stringWithFormat:@"%s('%s')", f, id.c_str()];
}
static void store_attempts() {
  cdp::attach(store, [] {
    ReArcEngineSetExtensionPromptCallback(nullptr, nullptr);
    cdp::gesture(call("begin", kUnsignedId), [](std::string r) {
      printf("EXT begin without callback -> %s\n", r.c_str());
      assert(r.starts_with("error:") && prompts == 0);
      assert_no_chromium_windows();
      puts("EXT install prompt without host callback aborts, no Chromium dialog PASS");
      ReArcEngineSetExtensionPromptCallback(prompt_event, nullptr);
      cdp::gesture(call("begin", kUnsignedId), [](std::string r) {
        printf("EXT begin cancelled -> %s\n", r.c_str());
        assert(r.starts_with("error:") && prompts == 1);
        cdp::gesture(call("begin", kUnsignedId), [](std::string r) {
        printf("EXT begin during callback replacement -> %s\n", r.c_str());
        assert(r.starts_with("error:") && prompts == 2 && cancels == 0);
        puts("EXT callback replacement withdraws a pending prompt (no event, stale ID) PASS");
        cdp::gesture(call("begin", kUnsignedId), [](std::string r) {
          assert(r == "ok:" && prompts == 3);
          cdp::gesture(call("complete", kUnsignedId), [](std::string r) {
            printf("EXT complete without publisher proof -> %s\n", r.c_str());
            assert(r.starts_with("error:"));
            after([] { return failed > 0; }, [] {
              assert(failed == 1 && installed == 0);
              assert_no_chromium_windows();
              puts("EXT Web Store prompt: host cancel; host accept of a CRX without publisher proof -> install-failed notification PASS");
              stage = 3;
              navigate("chrome://extensions/");
            });
          });
        });
        });
      });
    });
  });
}
static NSView* find_cocoa(NSView* v) {
  if ([NSStringFromClass([v class]) isEqualToString:@"WebContentsViewCocoa"]) return v;
  for (NSView* s in v.subviews) if (NSView* f = find_cocoa(s)) return f;
  return nil;
}
// Stage 3a: drop the locally signed CRX on chrome://extensions.
static void drop_install(std::function<void()> then) {
  cdp::gesture(@"chrome.developerPrivate.updateProfileConfiguration({inDeveloperMode:true}).then(()=>'dev')", [then](std::string r) {
    assert(r == "dev");
    later(1, [then] {
      NSPasteboard* pb = [NSPasteboard pasteboardWithUniqueName];
      [pb clearContents];
      assert([pb writeObjects:@[ [NSURL fileURLWithPath:[NSString stringWithUTF8String:getenv("REARC_DROP_CRX")]] ]]);
      FakeDrag* d = [FakeDrag new];
      d.pasteboard = pb;
      d.window = window;
      d.location = [(__bridge NSView*)lease.native_view convertPoint:NSMakePoint(400, 300) toView:nil];
      NSView* cocoa = find_cocoa((__bridge NSView*)lease.native_view);
      assert(cocoa);
      NSDragOperation op = [(id<NSDraggingDestination>)cocoa draggingEntered:d];
      printf("EXT drag enter op=%lu\n", (unsigned long)op);
      later(0.3, [d, cocoa, then] {
        [(id<NSDraggingDestination>)cocoa draggingUpdated:d];
        later(0.3, [d, cocoa, then] {
          [(id<NSDraggingDestination>)cocoa draggingUpdated:d];
          later(0.3, [d, cocoa, then] {
            printf("EXT drag perform=%d\n", [(id<NSDraggingDestination>)cocoa performDragOperation:d]);
            after([] { return installed > 0; }, [then] {
              assert(installed == 1 && prompts == 4 && cancels == 0);
              assert_no_chromium_windows();
              puts("EXT CRX dropped on chrome://extensions: host install prompt accepted, installed notification, no Chromium window PASS");
              then();
            }, 200);
          });
        });
      });
    });
  });
}
// Stage 3: chrome://extensions' confirmed removal goes through the host.
static void uninstall_attempts() {
  cdp::attach("chrome://extensions", [] { drop_install([] {
    NSString* has = [NSString stringWithFormat:@"chrome.management.getAll().then(a=>String(a.some(e=>e.id==='%s')))", kStoreId.c_str()];
    NSString* remove = [NSString stringWithFormat:@"chrome.management.uninstall('%s',{showConfirmDialog:true}).then(()=>'removed',e=>'error:'+e.message)", kStoreId.c_str()];
    cdp::gesture(has, [remove, has](std::string r) {
      assert(r == "true");
      cdp::gesture(remove, [remove, has](std::string r) {
        printf("EXT uninstall cancelled -> %s\n", r.c_str());
        assert(r.starts_with("error:") && uninstall_prompts == 1);
        cdp::gesture(remove, [has](std::string r) {
          printf("EXT uninstall accepted -> %s\n", r.c_str());
          assert(r == "removed" && uninstall_prompts == 2);
          cdp::gesture(has, [](std::string r) {
            assert(r == "false");
            assert_no_chromium_windows();
            puts("EXT chrome://extensions uninstall confirmation through the host (cancel, accept) PASS");
            finish();
          });
        });
      });
    });
  }); });
}

static int route_requests;
static void route_request(void*, const ReArcExtensionTabRequest* e) {
  if (e->phase) { printf("EXT route withdrawn %llu\n", e->request_id); return; }
  ++route_requests;
  printf("EXT route kind=%u url=%s active=%d opener=%llu\n",e->kind,e->url,e->active,e->opener_tab_id);
  assert(e->profile_id == profile && strlen(e->extension_id) == 32);
  if (std::string(e->url).ends_with("/cancel")) {
    assert(ReArcExtensionTabRequestRespond(e->request_id,0) == REARC_OK); return;
  }
  uint64_t id = e->tab_id;
  int window_id = e->kind == 1 ? 2 : e->window_id ? e->window_id : 1;
  if (e->kind != 3) assert(ReArcTabCreate(e->profile_id,1,"about:blank",&id) == REARC_OK);
  if (e->kind == 0) assert(e->opener_tab_id == tab && !e->active);
  assert(ReArcTabSetExtensionWindow(id,window_id,e->active,true) == REARC_OK);
  assert(ReArcExtensionTabRequestRespond(e->request_id,id) == REARC_OK);
  assert(ReArcExtensionTabRequestRespond(e->request_id,id) == REARC_NOT_FOUND);
}
static void run_routes(std::function<void()> done) {
  assert(ReArcTabSetExtensionWindow(tab,1,true,true) == REARC_OK);
  ReArcExtensionTabState state{};
  assert(ReArcTabGetExtensionState(tab,&state) == REARC_OK && state.tab_id > 0 && state.window_id == 1 && state.active && state.focused);
  assert(ReArcTabSetExtensionWindow(tab,-1,false,false) == REARC_INVALID_ARGUMENT);
  ReArcEngineSetExtensionTabRequestCallback(route_request,nullptr);
  std::string script = "(async()=>{window.postMessage({route:1,base:'"+base+"'},'*');for(let i=0;i<300&&!document.documentElement.dataset.routing;++i)await new Promise(r=>setTimeout(r,100));return document.documentElement.dataset.routing})()";
  cdp::attach(base+"/ext",[script,done] { cdp::gesture([NSString stringWithUTF8String:script.c_str()],[done](std::string r) {
    printf("EXT routing result %s requests=%d\n",r.c_str(),route_requests);
    assert(r == "routing-pass" && route_requests == 5);
    ReArcEngineSetExtensionTabRequestCallback(nullptr,nullptr);
    assert_no_chromium_windows();
    puts("EXT registry query/get/update/remove, host tabs/options/window creation and active/focused window state PASS");
    done();
  }); });
}
static void check_content_scripts(std::string json) {
  printf("EXT markers %s\n", json.c_str());
  if ((field(json, "rearcCs").empty() ||
       field(json, "rearcReply").find("\"nav\":null") != std::string::npos) && reloads < 10) {
    // --load-extension installs asynchronously after startup; a document
    // committed before the extension loaded has no content script, and one
    // committed before the service worker first ran registered its
    // webNavigation listener is not reported to it.
    ++reloads;
    later(1, [] { settled = false; assert(ReArcTabReload(tab, false) == REARC_OK); });
    return;
  }
  assert(field(json, "rearcCs") == "ran");
  std::string reply = field(json, "rearcReply");
  assert(reply.find("\"tabId\":") != std::string::npos && reply.find("\"tabId\":-1") == std::string::npos);
  assert(reply.find("\"nav\":\"" + base + "/ext\"") != std::string::npos);
  assert(field(json, "rearcPing") == "from-bg");
  assert(field(json, "rearcExec") == "{\"pong\":1}");
  // tab/050: extension APIs that would open a Chromium Browser window fail.
  assert(reply.find("\"create\":\"error:No current window\"") != std::string::npos);
  assert(reply.find("\"options\":\"error:") != std::string::npos);
  assert_no_chromium_windows();
  puts("EXT tabs.create and runtime.openOptionsPage fail without opening a Chromium window PASS");
  printf("EXT content script, runtime messaging (sender.tab), webNavigation, tabs.sendMessage, scripting.executeScript by tab ID PASS (reloads=%d)\n", reloads);
  run_routes([] {
  stage = 1;
  assert(ReArcProfileCreateOffTheRecord(profile, [](void*, ReArcStatus s, uint64_t id, bool otr) {
    assert(s == REARC_OK && otr);
    otr_profile = id;
    assert(ReArcTabCreate(otr_profile, 2, (base + "/ext").c_str(), &otr_tab) == REARC_OK);
  }, nullptr) == REARC_OK);
  });
}
static void event(void*, const ReArcTabEvent* e) {
  assert(!e->is_crashed);
  if (popup_tab && e->tab_id == popup_tab) {
    if (e->kind == 0) {
      assert(e->disposition == 3 && e->opener_tab_id == tab && e->profile_id == profile);
      popup_created = true;
      assert(ReArcViewAttach(popup_tab, 1, 100, 100, 1, &popup_lease) == REARC_OK);
      [window.contentView addSubview:(__bridge NSView*)popup_lease.native_view];
      assert(ReArcViewSetVisible(popup_tab, popup_lease.attachment_id, true) == REARC_OK);
      // A popup is not a toolbar tab.
      uint32_t result;
      uint64_t other;
      assert(ReArcTabRunExtensionAction(popup_tab, act_id.c_str(), &result, &other) == REARC_UNSUPPORTED);
      assert(ReArcTabGetExtensionActions(popup_tab, 1, [](void*, ReArcStatus, const ReArcExtensionActionList*) { assert(false); }, nullptr) == REARC_UNSUPPORTED);
    }
    if (e->kind == 1 && (e->changes & 2)) {
      printf("EXT popup title %s\n", e->title);
      if (std::string(e->title) == "popup:1") popup_titled = true;
    }
    if (e->kind == 2) {
      printf("EXT popup closed reason=%u\n", e->closed_reason);
      assert(popup_created && e->closed_reason == 1);
      popup_closed = true;
      later(0.2, finish_actions);
    }
    return;
  }
  static std::map<uint64_t,std::string> committed;
  if (e->tab_id != tab && e->tab_id != otr_tab) return;
  if (e->kind == 3 && e->is_main_frame && !e->is_same_document) {
    settled = false;
    committed[e->tab_id] = e->url;
  }
  if (e->kind != 1 || !(e->changes & 4) || e->is_loading || settled) return;
  const std::string& url = committed[e->tab_id];
  if (stage == 0 && e->tab_id == tab && url == base + "/ext") {
    settled = true;
    evaluate(tab, "(async()=>{for(let i=0;i<100;++i){const d=document.documentElement.dataset;"
                  "if(d.rearcExec)break;await new Promise(r=>setTimeout(r,100));}"
                  "return {...document.documentElement.dataset}})()", check_content_scripts);
  } else if (stage == 1 && e->tab_id == otr_tab && url == base + "/ext") {
    settled = true;
    later(3, [] {
      evaluate(otr_tab, "({...document.documentElement.dataset})", [](std::string json) {
        printf("EXT otr markers %s\n", json.c_str());
        assert(field(json, "rearcCs").empty());
        puts("EXT OTR tab without incognito access gets no content script PASS");
        actions_stage();
      });
    });
  } else if (stage == 2 && e->tab_id == tab && url == store + "/webstore") {
    settled = true;
    store_attempts();
  } else if (stage == 3 && e->tab_id == tab && url.starts_with("chrome://extensions")) {
    settled = true;
    later(1, uninstall_attempts);
  }
}
static void ready(void*, uint64_t p) {
  profile = p;
  assert(ReArcEngineABIMinorVersion() >= 33 && ReArcEngineHasFeature("extension_tab_helpers") &&
         ReArcEngineHasFeature("extension_install_prompts") && ReArcEngineHasFeature("extension_actions"));
  // Webstore downloads land in the profile download directory.
  assert(ReArcDownloadSetPolicy(profile, getenv("REARC_DOWNLOAD_DIR"), 0) == REARC_OK);
  // Files only, so chrome://extensions receives the dropped CRX.
  assert(ReArcEngineSetDropPolicy(REARC_DROP_FILES, nullptr, 0) == REARC_OK);
  ReArcEngineSetExtensionPromptCallback(prompt_event, nullptr);
  ReArcEngineSetExtensionActionCallback(action_event, nullptr);
  window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 600) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  assert(ReArcWindowRegister(1, (__bridge void*)window) == REARC_OK);
  [window makeKeyAndOrderFront:nil];
  assert(ReArcTabCreate(profile, 1, (base + "/ext").c_str(), &tab) == REARC_OK);
  assert(ReArcViewAttach(tab, 1, 800, 600, 1, &lease) == REARC_OK);
  [window.contentView addSubview:(__bridge NSView*)lease.native_view];
  assert(ReArcViewSetVisible(tab, lease.attachment_id, true) == REARC_OK);
}
int main(int argc, const char** argv) { @autoreleasepool {
  setbuf(stdout, nullptr);
  for (int i = 1; i < argc; ++i)
    if (std::string(argv[i]).starts_with("--user-data-dir=")) profile_path = argv[i] + 16;
  std::string port = getenv("REARC_TEST_PORT");
  base = "http://127.0.0.1:" + port;
  store = "http://localhost:" + port;
  kStoreId = getenv("REARC_DROP_CRX_ID");
  cdp::session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
  ReArcCallbacks c{ready, event, nullptr, nullptr};
  assert(ReArcEngineConfigure(1, &c, nullptr) == REARC_OK);
  int r = ReArcEngineRun(argc, argv);
  assert(r == 0 && stopped);
  return r;
}}
