#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <functional>
#include <string>
#include <vector>

// Wave 18f autofill_suggestions. An address and a card are saved through
// Chromium's own autofillPrivate (chrome://settings) and a credential through
// passwordsPrivate (chrome://password-manager); the form page is loopback
// HTTPS (cards need a secure context; the run's self-signed certificate is
// accepted only by --ignore-certificate-errors-spki-list). Real (DevTools-
// injected) clicks open the suggestions; the host sees rows and field bounds,
// arrow keys move Chromium's selection, early accepts are busy, accepting
// fills, dismiss hides, and "Manage..." (footer row or ReArcAutofillManage)
// asks the host to open Chromium's settings page. No form is submitted.
// The DevTools socket is test-only, as in the helpers host.
static uint64_t profile, tab;
static NSWindow* window;
static ReArcAttachment lease{};
static std::string secure, profile_path, committed;
static int stage;
static bool stopped, settled;

struct Row { std::string value, minor, label, icon; uint32_t kind, type; bool acceptable; };
struct Shown { uint64_t id; uint32_t product; double x, y, w, h; std::vector<Row> rows; };
static std::vector<Shown> shown;
static std::vector<std::pair<uint64_t, int32_t>> selections;
static std::vector<uint64_t> hidden;
static std::vector<std::string> settings;

static void later(double seconds, std::function<void()> f) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ f(); });
}
static void after(std::function<bool()> condition, std::function<void()> then, int tries = 100) {
  if (condition()) { then(); return; }
  assert(tries > 0);
  later(0.1, [condition, then, tries] { after(condition, then, tries - 1); });
}

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
      if (reply[@"error"] || reply[@"result"][@"exceptionDetails"]) printf("AUTOFILL cdp %s\n", msg.string.UTF8String);
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
      assert(ws);
      if (socket_) [socket_ cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
      socket_ = [session webSocketTaskWithURL:[NSURL URLWithString:ws]];
      [socket_ resume];
      send(@"Emulation.setFocusEmulationEnabled", @{@"enabled":@YES}, [done](NSDictionary*) { done(); });
    });
  }] resume];
}
static void eval(NSString* expression, std::function<void(std::string)> done) {
  NSString* wrapped = [NSString stringWithFormat:@"(async()=>{const wait=async(f,what)=>{for(let i=0;i<150;++i){const v=await f();if(v)return v;await new Promise(r=>setTimeout(r,100));}throw Error('timeout: '+what);};%@})()", expression];
  send(@"Runtime.evaluate", @{@"expression":wrapped,@"awaitPromise":@YES,@"returnByValue":@YES,@"userGesture":@YES,@"timeout":@20000},
       [done](NSDictionary* result) {
         id value = result[@"result"][@"value"];
         done([value isKindOfClass:NSString.class] ? std::string([value UTF8String]) : std::string([[value description] UTF8String]));
       });
}
static void click(double x, double y, std::function<void()> done) {
  send(@"Input.dispatchMouseEvent", @{@"type":@"mouseMoved",@"x":@(x),@"y":@(y),@"button":@"none",@"buttons":@0}, [x, y, done](NSDictionary*) {
    send(@"Input.dispatchMouseEvent", @{@"type":@"mousePressed",@"x":@(x),@"y":@(y),@"button":@"left",@"buttons":@1,@"clickCount":@1}, [x, y, done](NSDictionary*) {
      send(@"Input.dispatchMouseEvent", @{@"type":@"mouseReleased",@"x":@(x),@"y":@(y),@"button":@"left",@"buttons":@0,@"clickCount":@1}, [done](NSDictionary*) { done(); });
    });
  });
}
static void close_browser() {
  NSArray* lines = port_lines();
  socket_ = [session webSocketTaskWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"ws://127.0.0.1:%@%@", lines[0], lines[1]]]];
  [socket_ resume];
  [socket_ sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:@"{\"id\":1,\"method\":\"Browser.close\"}"] completionHandler:^(NSError* error) { assert(!error); }];
}
}  // namespace cdp

static void autofill(void*, const ReArcAutofillEvent* e) {
  printf("AUTOFILL event phase=%u id=%llu tab=%llu product=%u bounds=%.1f,%.1f %.1fx%.1f selected=%d rows=%zu url=%s\n",
         e->phase, e->request_id, e->tab_id, e->product, e->x, e->y, e->width, e->height, e->selected,
         e->suggestion_count, e->settings_url);
  assert(e->tab_id == tab && e->profile_id == profile);
  if (e->phase == 0) {
    Shown s{e->request_id, e->product, e->x, e->y, e->width, e->height, {}};
    for (size_t i = 0; i < e->suggestion_count; ++i) {
      const ReArcAutofillSuggestion& r = e->suggestions[i];
      printf("AUTOFILL   row %zu kind=%u type=%u acceptable=%d icon=%s value=%s minor=%s label=%s\n", i, r.kind, r.type,
             r.acceptable, r.icon, r.value, r.minor, r.label);
      s.rows.push_back({r.value, r.minor, r.label, r.icon, r.kind, r.type, r.acceptable});
    }
    shown.push_back(s);
  } else if (e->phase == 1) {
    hidden.push_back(e->request_id);
  } else if (e->phase == 2) {
    selections.push_back({e->request_id, e->selected});
  } else {
    assert(e->phase == 3 && e->suggestion_count == 0);
    settings.push_back(e->settings_url);
  }
}
static int find_row(const Shown& s, uint32_t kind, const std::string& needle = "") {
  for (size_t i = 0; i < s.rows.size(); ++i)
    if (s.rows[i].kind == kind && s.rows[i].acceptable && s.rows[i].value.find(needle) != std::string::npos) return (int)i;
  return -1;
}
static void near(double a, double b) { assert(fabs(a - b) <= 1.5); }
static void navigate(const std::string& url) { settled = false; assert(ReArcTabNavigate(tab, url.c_str(), 0) == REARC_OK); }

static void finish() {
  assert(ReArcEngineShutdown(true, [](void*, ReArcStatus s, bool c) {
    assert(s == REARC_OK && !c);
    ReArcViewRelease(lease.native_view);
    stopped = true;
    puts("AUTOFILL PASS");
  }, nullptr) == REARC_OK);
  cdp::close_browser();
}
static NSView* find_rwhv(NSView* v) {
  if ([NSStringFromClass([v class]) isEqualToString:@"RenderWidgetHostViewCocoa"]) return v;
  for (NSView* s in v.subviews) if (NSView* f = find_rwhv(s)) return f;
  return nil;
}
// Opens suggestions on the field at CSS (x, y) and waits for its phase 0.
// Chromium shows suggestions only while the tab's view is first responder
// (as after a real click in the shell), so the test makes it so.
static void open(double x, double y, std::function<void(const Shown&)> then) {
  NSView* rwhv = find_rwhv((__bridge NSView*)lease.native_view);
  assert(rwhv && [window makeFirstResponder:rwhv]);
  printf("AUTOFILL focus key=%d first_responder=%d\n", window.keyWindow, window.firstResponder == rwhv);
  size_t before = shown.size();
  cdp::click(x, y, [before, then] {
    after([before] { return shown.size() > before; }, [then] { then(shown.back()); });
  });
}

static void passwords_stage() {
  stage = 3;
  navigate(secure + "/login");
}
static void card_stage() {
  // Card form (secure context): a saved local card is offered with its network icon.
  open(160, 365, [](const Shown& s) {
    assert(s.product == 2);
    near(s.x, 10); near(s.y, 350); near(s.w, 300); near(s.h, 30);
    int card = -1;
    for (size_t i = 0; i < s.rows.size(); ++i) if (s.rows[i].icon == "card_visa" && s.rows[i].kind == 0) card = (int)i;
    assert(card >= 0 && find_row(s, 1) >= 0);
    puts("AUTOFILL card suggestions (secure context): visa row, manage footer PASS");
    uint64_t id = s.id;
    later(0.7, [id, card] {
      assert(ReArcAutofillAccept(id, card) == REARC_OK);
      after([id] { return !hidden.empty() && hidden.back() == id; }, [] {
        cdp::eval(@"return await wait(()=>document.querySelector('#ccname').value&&[...document.querySelectorAll('#c input')].map(i=>i.value).join('|'),'card fill');", [](std::string r) {
          printf("AUTOFILL card fill %s\n", r.c_str());
          assert(r.starts_with("Rearc Tester|") && r.find("1111") != std::string::npos);
          puts("AUTOFILL host accept filled the card form PASS");
          passwords_stage();
        });
      });
    });
  });
}
static void address_stage() {
  cdp::attach(secure + "/autofill", [] {
    // Click the name field: Chromium's controller shows suggestions.
    open(160, 25, [](const Shown& s) {
      assert(s.product == 1);
      near(s.x, 10); near(s.y, 10); near(s.w, 300); near(s.h, 30);
      int row = find_row(s, 0, "Rearc Tester");
      assert(row >= 0 && find_row(s, 1) >= 0);
      assert(s.rows[row].label.find("1 Test Way") != std::string::npos || s.rows[row].label.find("Testville") != std::string::npos);
      puts("AUTOFILL address suggestions: field bounds in view coordinates, value/label rows, manage footer PASS");
      // Chromium ignores accepts in the first 500 ms; the ABI reports busy.
      assert(ReArcAutofillAccept(s.id, row) == REARC_BUSY);
      assert(ReArcAutofillAccept(s.id, 999) == REARC_INVALID_ARGUMENT);
      assert(ReArcAutofillAccept(s.id + 1000, row) == REARC_NOT_FOUND);
      uint64_t id = s.id;
      // A native keyDown to the focused RenderWidgetHostViewCocoa (DevTools
      // key events skip browser key listeners without a native key code).
      unichar down = NSDownArrowFunctionKey;
      NSString* chars = [NSString stringWithCharacters:&down length:1];
      NSEvent* e = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagFunction | NSEventModifierFlagNumericPad
                                   timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil
                                  characters:chars charactersIgnoringModifiers:chars isARepeat:NO keyCode:125];
      [find_rwhv((__bridge NSView*)lease.native_view) keyDown:e];
      later(0, [id, row] {
        after([] { return !selections.empty(); }, [id, row] {
          assert(selections.back().first == id && selections.back().second == row);
          puts("AUTOFILL arrow key moves Chromium's selection (phase 2) PASS");
          later(0.6, [id, row] {
            assert(ReArcAutofillAccept(id, row) == REARC_OK);
            after([id] { return !hidden.empty() && hidden.back() == id; }, [] {
              cdp::eval(@"return await wait(()=>document.querySelector('#city').value&&[...document.querySelectorAll('#a input')].map(i=>i.value).join('|'),'fill');", [](std::string r) {
                printf("AUTOFILL address fill %s\n", r.c_str());
                assert(r == "Rearc Tester|1 Test Way|Testville|94043|tester@example.com");
                puts("AUTOFILL host accept filled the address form PASS");
                cdp::eval(@"document.querySelector('#a').reset();return 'reset';", [](std::string) {
                  open(160, 75, [](const Shown& s) {
                    assert(ReArcAutofillDismiss(s.id) == REARC_OK);
                    uint64_t id = s.id;
                    after([id] { return !hidden.empty() && hidden.back() == id; }, [id] {
                      assert(ReArcAutofillDismiss(id) == REARC_NOT_FOUND);
                      puts("AUTOFILL dismiss hides; stale ID not_found PASS");
                      open(160, 75, [](const Shown& s) {
                        int footer = find_row(s, 1);
                        uint64_t id = s.id;
                        later(0.7, [id, footer] {
                          // The "Manage addresses..." row goes through ChromeAutofillClient.
                          assert(ReArcAutofillAccept(id, footer) == REARC_OK);
                          after([] { return settings.size() == 1; }, [] {
                            assert(settings[0] == "chrome://settings/contactInfo");
                            open(160, 75, [](const Shown& s) {
                              assert(ReArcAutofillManage(s.id) == REARC_OK);
                              after([] { return settings.size() == 2; }, [] {
                                assert(settings[1] == "chrome://settings/contactInfo");
                                puts("AUTOFILL manage: footer row and ReArcAutofillManage both request chrome://settings/contactInfo PASS");
                                card_stage();
                              });
                            });
                          });
                        });
                      });
                    });
                  });
                });
              });
            });
          });
        });
      });
    });
  });
}
static void login_stage() {
  cdp::attach(secure + "/login", [] {
    cdp::eval(@"return await wait(()=>document.querySelector('#u').matches(':-webkit-autofill'),'fill on load');", [](std::string) {
      // Password suggestions use the same host path (PasswordAutofillManager).
      open(150, 10, [](const Shown& s) {
        assert(s.product == 6);
        // The login field is content-box: 300px plus padding and border.
        near(s.x, 0); near(s.y, 0); assert(s.w >= 300 && s.w <= 310 && s.h > 0);
        int credential = find_row(s, 0, "rearc-w18f");
        int footer = find_row(s, 1);
        assert(credential >= 0 && footer >= 0);
        assert(s.rows[credential].icon == "key" || s.rows[credential].icon == "globe" || !s.rows[credential].icon.empty());
        puts("AUTOFILL password suggestions from ChromePasswordManagerClient reach the host PASS");
        uint64_t id = s.id;
        later(0.7, [id, footer] {
          assert(ReArcAutofillAccept(id, footer) == REARC_OK);
          after([] { return settings.size() == 3; }, [] {
            assert(settings[2] == "chrome://password-manager/passwords");
            puts("AUTOFILL manage passwords footer requests chrome://password-manager/passwords PASS");
            // Replacement hides open suggestions without delivering them.
            open(150, 10, [](const Shown& s) {
              size_t hides = hidden.size();
              ReArcEngineSetAutofillCallback(autofill, nullptr);
              uint64_t id = s.id;
              later(0.5, [id, hides] {
                assert(hidden.size() == hides && ReArcAutofillAccept(id, 0) == REARC_NOT_FOUND);
                puts("AUTOFILL callback replacement hides suggestions, events withdrawn PASS");
                finish();
              });
            });
          });
        });
      });
    });
  });
}
static void seed_stage() {
  cdp::attach("chrome://settings", [] {
    cdp::eval(@"await chrome.autofillPrivate.saveAddress({fields:["
               "{type:'NAME_FULL',value:'Rearc Tester'},{type:'ADDRESS_HOME_STREET_ADDRESS',value:'1 Test Way'},"
               "{type:'ADDRESS_HOME_CITY',value:'Testville'},{type:'ADDRESS_HOME_STATE',value:'CA'},"
               "{type:'ADDRESS_HOME_ZIP',value:'94043'},{type:'ADDRESS_HOME_COUNTRY',value:'US'},"
               "{type:'EMAIL_ADDRESS',value:'tester@example.com'}]});"
               "await chrome.autofillPrivate.saveCreditCard({name:'Rearc Tester',cardNumber:'4111111111111111',expirationMonth:'12',expirationYear:'2031'});"
               "await wait(async()=>(await chrome.autofillPrivate.getAddressList()).length===1&&(await chrome.autofillPrivate.getCreditCardList()).length===1,'saved');"
               "return 'seeded';", [](std::string r) {
      assert(r == "seeded");
      puts("AUTOFILL address and card saved through autofillPrivate PASS");
      stage = 1;
      navigate("chrome://password-manager/");
    });
  });
}
static void event(void*, const ReArcTabEvent* e) {
  if (e->tab_id != tab) return;
  assert(!e->is_crashed);
  if (e->kind == 3 && e->is_main_frame && !e->is_same_document) { committed = e->url; settled = false; }
  if (e->kind != 1 || !(e->changes & 4) || e->is_loading || settled) return;
  if (stage == 0 && committed.starts_with("chrome://settings")) { settled = true; later(1, seed_stage); }
  else if (stage == 1 && committed.starts_with("chrome://password-manager")) {
    settled = true;
    later(1, [] {
      cdp::attach("chrome://password-manager", [] {
        cdp::eval([NSString stringWithFormat:@"await chrome.passwordsPrivate.addPassword({url:'%s/login',username:'rearc-w18f',password:'w18f-secret',note:'',useAccountStore:false});"
                    "return String(await wait(async()=>(await chrome.passwordsPrivate.getSavedPasswordList()).some(p=>p.username==='rearc-w18f'),'saved'));", secure.c_str()],
                  [](std::string r) {
          assert(r == "true");
          stage = 2;
          navigate(secure + "/autofill");
        });
      });
    });
  }
  else if (stage == 2 && committed == secure + "/autofill") { settled = true; later(0.5, address_stage); }
  else if (stage == 3 && committed == secure + "/login") { settled = true; later(0.5, login_stage); }
}
static void ready(void*, uint64_t p) {
  profile = p;
  assert(ReArcEngineABIMinorVersion() >= 34 && ReArcEngineHasFeature("autofill_suggestions"));
  ReArcEngineSetAutofillCallback(autofill, nullptr);
  window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 700) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  assert(ReArcWindowRegister(1, (__bridge void*)window) == REARC_OK);
  [window makeKeyAndOrderFront:nil];
  assert(ReArcTabCreate(profile, 1, "chrome://settings/", &tab) == REARC_OK);
  assert(ReArcViewAttach(tab, 1, 900, 700, 1, &lease) == REARC_OK);
  [window.contentView addSubview:(__bridge NSView*)lease.native_view];
  assert(ReArcViewSetVisible(tab, lease.attachment_id, true) == REARC_OK);
}
int main(int argc, const char** argv) { @autoreleasepool {
  setbuf(stdout, nullptr);
  for (int i = 1; i < argc; ++i)
    if (std::string(argv[i]).starts_with("--user-data-dir=")) profile_path = argv[i] + 16;
  secure = "https://127.0.0.1:" + std::string(getenv("REARC_TEST_HTTPS_PORT"));
  cdp::session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
  ReArcCallbacks c{ready, event, nullptr, nullptr};
  assert(ReArcEngineConfigure(1, &c, nullptr) == REARC_OK);
  int r = ReArcEngineRun(argc, argv);
  assert(r == 0 && stopped);
  return r;
}}
