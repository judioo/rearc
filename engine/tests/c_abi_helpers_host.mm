#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <functional>
#include <string>
#include <vector>

// Wave 18b browser-less tab helpers. Visits go through Chromium's
// HistoryTabHelper; the saved credential is created through Chromium's
// passwordsPrivate API, filled by ChromePasswordManagerClient and submitted by
// a real (DevTools-injected) mouse click. run_c_abi.py then checks the History
// and Login Data databases. The DevTools socket is test-only, as in the WebUI
// host; it is never part of the shipping ABI.
static uint64_t tab;
static NSWindow* window;
static ReArcAttachment lease{};
static NSURLSession* session;
static NSURLSessionWebSocketTask* socket_;
static std::string profile_path, base_url, expected_url;
static int stage, next_id = 1;
static bool committed, busy, stopped;
static std::function<void(NSDictionary*)> pending;

static NSString* devtools_port() {
  NSString* file = [NSString stringWithUTF8String:(profile_path + "/DevToolsActivePort").c_str()];
  return [[NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"].firstObject;
}
static void receive() {
  [socket_ receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage* msg, NSError* error) {
    assert(!error && msg);
    NSDictionary* reply = [NSJSONSerialization JSONObjectWithData:[msg.string dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!reply[@"id"]) { receive(); return; }
      printf("HELPERS stage=%d %s\n", stage, msg.string.UTF8String);
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
// Connect to the page target for `prefix` and evaluate an async expression.
static void evaluate(std::string prefix, NSString* body, std::function<void(NSDictionary*)> done) {
  NSURL* list = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%@/json/list", devtools_port()]];
  [[session dataTaskWithURL:list completionHandler:^(NSData* data, NSURLResponse*, NSError* error) {
    assert(!error && data);
    NSArray* targets = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      NSString* ws = nil;
      for (NSDictionary* target in targets)
        if ([target[@"url"] hasPrefix:[NSString stringWithUTF8String:prefix.c_str()]]) ws = target[@"webSocketDebuggerUrl"];
      if (!ws) printf("HELPERS targets %s\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
      assert(ws);
      if (socket_) [socket_ cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
      socket_ = [session webSocketTaskWithURL:[NSURL URLWithString:ws]];
      [socket_ resume];
      NSString* expression = [NSString stringWithFormat:@"(async()=>{const wait=async(f,what)=>{for(let i=0;i<150;++i){const v=await f();if(v)return v;await new Promise(r=>setTimeout(r,100));}throw Error('timeout: '+what);};%@})()", body];
      send(@"Runtime.evaluate", @{@"expression":expression,@"awaitPromise":@YES,@"returnByValue":@YES,@"timeout":@20000}, done);
    });
  }] resume];
}
static void navigate(const std::string& url) {
  committed = false;
  expected_url = url;
  assert(ReArcTabNavigate(tab, url.c_str(), 0) == REARC_OK);
}
static void shutdown_done(void*, ReArcStatus s, bool c) {
  assert(s == REARC_OK && !c); stopped = true;
  puts("HELPERS history + password fill/usage plumbing PASS");
}
static void closed(void*, ReArcStatus s, bool c) {
  assert(s == REARC_OK && !c);
  ReArcViewRelease(lease.native_view);
  assert(ReArcEngineShutdown(true, shutdown_done, nullptr) == REARC_OK);
  // Release the test-only remote-debugging keepalive (see c_abi_webui_host).
  NSString* file = [NSString stringWithUTF8String:(profile_path + "/DevToolsActivePort").c_str()];
  NSArray* lines = [[NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"];
  socket_ = [session webSocketTaskWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"ws://127.0.0.1:%@%@", lines[0], lines[1]]]];
  [socket_ resume];
  [socket_ sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:@"{\"id\":1,\"method\":\"Browser.close\"}"] completionHandler:^(NSError* error) { assert(!error); }];
}
static void advance() {
  busy = true;
  switch (stage) {
    case 0: stage = 1; busy = false; navigate(base_url + "/visit-b"); return;
    case 1: stage = 2; busy = false; navigate("chrome://history/"); return;
    case 2:
      // HistoryService query through Chromium's own page handler, then the
      // rendered chrome://history list itself.
      evaluate("chrome://history", [NSString stringWithFormat:@"const {BrowserProxyImpl}=await import('/browser_proxy.js');"
          "const urls=await wait(async()=>{const r=await BrowserProxyImpl.getInstance().handler.queryHistory('',100,null,true,false);"
          "const u=r.results.value.map(e=>e.url+'|'+e.title);return u.includes('%s/visit-a|ReArc visit A')&&u.includes('%s/visit-b|ReArc visit B')&&u;},'history service');"
          "const app=document.querySelector('history-app');await app.updateComplete;"
          "const titles=await wait(()=>{const list=app.shadowRoot.querySelector('history-list');const items=list?.shadowRoot?.querySelectorAll('history-item')||[];"
          "const t=[...items].map(i=>i.item?.title);return t.includes('ReArc visit A')&&t.includes('ReArc visit B')&&t;},'history list');"
          "return {urls,titles};", base_url.c_str(), base_url.c_str()],
          [](NSDictionary*) {
            puts("HELPERS visits in HistoryService and chrome://history PASS");
            stage = 3; busy = false; navigate("chrome://password-manager/");
          });
      return;
    case 3:
      evaluate("chrome://password-manager", [NSString stringWithFormat:@"await chrome.passwordsPrivate.addPassword({url:'%s/login',username:'rearc-w18b',password:'w18b-secret',note:'',useAccountStore:false});"
          "return await wait(async()=>(await chrome.passwordsPrivate.getSavedPasswordList()).some(p=>p.username==='rearc-w18b'),'saved');", base_url.c_str()],
          [](NSDictionary*) {
            puts("HELPERS credential saved through Chromium password store PASS");
            stage = 4; busy = false; navigate(base_url + "/login");
          });
      return;
    case 4:
      printf("HELPERS window visible=%d occlusion=%lu key=%d active=%d\n", window.visible, (unsigned long)window.occlusionState, window.keyWindow, NSApp.active);
      // Chromium fills on load (values stay JS-hidden until a user gesture).
      evaluate(base_url + "/login", @"await wait(()=>document.querySelector('#u').matches(':-webkit-autofill')&&document.querySelector('#p').matches(':-webkit-autofill'),'autofill');"
          "const r=document.querySelector('#s').getBoundingClientRect();return {x:r.left+r.width/2,y:r.top+r.height/2};",
          [](NSDictionary* result) {
            puts("HELPERS ChromePasswordManagerClient filled saved credential PASS");
            NSDictionary* point = result[@"result"][@"value"];
            stage = 5; busy = false; committed = false;
            expected_url = base_url + "/welcome?u=rearc-w18b&p=w18b-secret";
            send(@"Input.dispatchMouseEvent", @{@"type":@"mouseMoved",@"x":point[@"x"],@"y":point[@"y"],@"button":@"none",@"buttons":@0}, [point](NSDictionary*) {
              send(@"Input.dispatchMouseEvent", @{@"type":@"mousePressed",@"x":point[@"x"],@"y":point[@"y"],@"button":@"left",@"buttons":@1,@"clickCount":@1}, [point](NSDictionary*) {
                send(@"Input.dispatchMouseEvent", @{@"type":@"mouseReleased",@"x":point[@"x"],@"y":point[@"y"],@"button":@"left",@"buttons":@0,@"clickCount":@1}, [](NSDictionary*) {
                  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    if (stage == 5 && !committed)
                      send(@"Runtime.evaluate", @{@"expression":@"JSON.stringify({v:document.visibilityState,f:document.hasFocus(),c:window.__c,u:document.querySelector('#u')?.value,url:location.href})",@"returnByValue":@YES}, [](NSDictionary*) {});
                  });
                });
              });
            });
          });
      return;
    case 5:
      puts("HELPERS user-gesture submission carried the filled credential PASS");
      stage = 6;
      // Allow the password store's usage update to land before closing.
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        assert(ReArcTabClose(tab, true, closed, nullptr) == REARC_OK);
      });
      return;
  }
}
static void event(void*, const ReArcTabEvent* e) {
  if (e->tab_id != tab) return;
  assert(!e->is_crashed);
  if (e->kind == 3 && e->is_main_frame && !e->is_same_document) {
    printf("HELPERS commit stage=%d %s\n", stage, e->url);
    assert(!e->is_error_page);
    if (std::string(e->url).starts_with(expected_url)) committed = true;
  }
  if (!busy && stage < 6 && committed && e->kind == 1 && (e->changes & 4) && !e->is_loading) advance();
}
static void ready(void*, uint64_t profile) {
  // Wave 18f: this host submits a sign-in; no leak-check request to Google.
  if (ReArcEngineABIMinorVersion() >= 35) assert(ReArcProfileSetPasswordLeakDetection(profile, false) == REARC_OK);
  assert(ReArcEngineABIMinorVersion() >= 15 && ReArcEngineHasFeature("history_recording") &&
         ReArcEngineHasFeature("password_autofill") && ReArcEngineHasFeature("webui_daily_pages"));
  session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
  window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,900,700) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  assert(ReArcWindowRegister(1,(__bridge void*)window) == REARC_OK);
  // A locked/occluded test session hides the page and drops input; the runner
  // passes Chromium's --disable-backgrounding-occluded-windows test switch.
  [window makeKeyAndOrderFront:nil];
  assert(ReArcTabCreate(profile,1,nullptr,&tab) == REARC_OK);
  assert(ReArcViewAttach(tab,1,900,700,1,&lease) == REARC_OK);
  [window.contentView addSubview:(__bridge NSView*)lease.native_view];
  assert(ReArcViewSetVisible(tab,lease.attachment_id,true) == REARC_OK);
  navigate(base_url + "/visit-a");
}
int main(int argc, const char** argv) { @autoreleasepool {
  setbuf(stdout,nullptr);
  for (int i=1;i<argc;++i) if(std::string(argv[i]).starts_with("--user-data-dir=")) profile_path=argv[i]+16;
  assert(!profile_path.empty() && getenv("REARC_TEST_PORT"));
  base_url = "http://127.0.0.1:" + std::string(getenv("REARC_TEST_PORT"));
  ReArcCallbacks c{ready,event,nullptr,nullptr};
  assert(ReArcEngineConfigure(1,&c,nullptr) == REARC_OK);
  int result=ReArcEngineRun(argc,argv); assert(result==0 && stopped);
  [session invalidateAndCancel]; return result;
}}
