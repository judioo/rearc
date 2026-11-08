#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <string>
#include <vector>

// Test-only external DevTools connection. The shipping ABI still rejects
// evaluation and capture in privileged documents.
static uint64_t tab;
static NSWindow* window;
static ReArcAttachment lease{};
static NSURLSession* session;
static NSURLSessionWebSocketTask* devtools_socket;
static std::string profile_path;
static size_t index_;
static bool checking, stopped, committed;
static std::vector<std::string> pages = {
    "chrome://history/", "chrome://history/grouped", "chrome://history/syncedTabs",
    "chrome://downloads/", "chrome://password-manager/",
    "chrome://password-manager/settings", "chrome://password-manager/checkup",
    "chrome://extensions/", "chrome://extensions/shortcuts",
    "chrome://settings/content", "chrome://version/", "chrome://credits/"};
static void navigate();
static void shutdown_done(void*, ReArcStatus s, bool c) {
  assert(s == REARC_OK && !c); stopped = true;
  puts("WEBUI admission + live handlers + privilege boundaries PASS");
}
static void closed(void*, ReArcStatus s, bool c) {
  assert(s == REARC_OK && !c);
  puts("WEBUI closed callback");
  ReArcViewRelease(lease.native_view);
  assert(ReArcEngineShutdown(true, shutdown_done, nullptr) == REARC_OK);
  puts("WEBUI shutdown accepted");
  // --no-startup-window + --remote-debugging-port adds Chromium's automation
  // keepalive. Explicitly release it after the ABI has closed its last tab.
  NSString* port_file = [NSString stringWithUTF8String:(profile_path + "/DevToolsActivePort").c_str()];
  NSArray* lines = [[NSString stringWithContentsOfFile:port_file encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"];
  NSURL* endpoint = [NSURL URLWithString:[NSString stringWithFormat:@"ws://127.0.0.1:%@%@", lines[0], lines[1]]];
  devtools_socket = [session webSocketTaskWithURL:endpoint];
  [devtools_socket resume];
  [devtools_socket sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:@"{\"id\":1,\"method\":\"Browser.close\"}"] completionHandler:^(NSError* error) { assert(!error); }];
}
static void returned(void*, ReArcStatus s, uint64_t id, uint64_t,
                     const char* json, const char* error) {
  assert(s == REARC_OK && id == tab && !error && std::string(json) == "42");
  puts("WEBUI -> HTTP preserves installed isolated script PASS");
  assert(ReArcTabClose(tab, true, closed, nullptr) == REARC_OK);
}
static void impossible(void*, ReArcStatus, uint64_t, uint64_t, uint8_t*, size_t) {
  assert(false);
}
static void receive() {
  [devtools_socket receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage* msg, NSError* error) {
    assert(!error && msg);
    NSDictionary* reply = [NSJSONSerialization JSONObjectWithData:[msg.string dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!reply[@"id"]) { receive(); return; }
      fprintf(stdout, "WEBUI %s %s\n", pages[index_].c_str(), msg.string.UTF8String);
      assert(!reply[@"error"] && !reply[@"result"][@"exceptionDetails"]);
      assert([reply[@"result"][@"result"][@"value"][@"ok"] boolValue]);
      [devtools_socket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
      devtools_socket = nil;
      ++index_; checking = false; navigate();
    });
  }];
}
static void check_page() {
  NSString* port_file = [NSString stringWithUTF8String:(profile_path + "/DevToolsActivePort").c_str()];
  NSString* port = [[NSString stringWithContentsOfFile:port_file encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"].firstObject;
  assert(port.length);
  NSURL* list = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%@/json/list", port]];
  [[session dataTaskWithURL:list completionHandler:^(NSData* data, NSURLResponse*, NSError* error) {
    assert(!error && data);
    NSArray* targets = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      NSString* ws = nil;
      for (NSDictionary* target in targets) {
        if ([target[@"url"] hasPrefix:[NSString stringWithUTF8String:pages[index_].c_str()]]) ws = target[@"webSocketDebuggerUrl"];
      }
      assert(ws);
      devtools_socket = [session webSocketTaskWithURL:[NSURL URLWithString:ws]];
      [devtools_socket resume];
      NSString* body = @"";
      NSString* tag = @"";
      if (pages[index_].starts_with("chrome://history")) {
        tag = @"history-app";
        body = @"const {loadTimeData}=await import('chrome://resources/js/load_time_data.js'); if(loadTimeData.getBoolean('isHistoryClustersEnabled'))throw Error('browser-less Journeys'); const {BrowserProxyImpl}=await import('/browser_proxy.js'); const r=await BrowserProxyImpl.getInstance().handler.queryHistory('',100,null,true,false); if(!r.results)throw Error('history query');";
      } else if (pages[index_].starts_with("chrome://downloads")) {
        tag = @"downloads-manager";
        body = @"await node.loaded_.promise; if(!Array.isArray(node.items_))throw Error('download list');";
      } else if (pages[index_].starts_with("chrome://password-manager")) {
        tag = @"password-manager-app";
        body = @"const {PasswordManagerImpl}=await import('/password_manager_proxy.js'); const p=PasswordManagerImpl.getInstance(); const passwords=await chrome.passwordsPrivate.getSavedPasswordList(); if(!Array.isArray(passwords))throw Error('password list'); p.showAddShortcutDialog(); chrome.send('OpenBatchUpload',[0]); chrome.send('restartBrowser'); const {sendWithPromise}=await import('chrome://resources/js/cr.js'); await sendWithPromise('GetSyncInfo');";
      } else if (pages[index_].starts_with("chrome://extensions")) {
        tag = @"extensions-manager";
        body = @"await chrome.developerPrivate.getExtensionsInfo({includeDisabled:true,includeTerminated:true}); await chrome.developerPrivate.getProfileConfiguration();";
      } else if (pages[index_].starts_with("chrome://credits")) {
        body = @"if(document.title!=='Credits'||document.querySelectorAll('.product').length<10)throw Error('missing licences'); const print=document.querySelector('#print-link'); if(print.hidden||typeof print.onclick!=='function')throw Error('credits JS'); const label=document.querySelector('.product label'); const input=label.querySelector('input'); const before=input.checked; label.click(); if(input.checked===before)throw Error('licence toggle'); const link=document.querySelector('.homepage a'); if(!/^https?:/.test(link.href))throw Error('homepage link'); const sheet=Array.from(document.styleSheets).find(s=>s.href==='chrome://credits/credits.css'); if(!sheet?.cssRules.length)throw Error('credits CSS'); let printed=false; window.print=()=>{printed=true}; print.click(); if(!printed)throw Error('print link');";
      } else if (pages[index_].starts_with("chrome://settings")) {
        tag = @"settings-ui";
      }
      NSString* expression = [NSString stringWithFormat:@"(async()=>{const tag='%@';let node=document.body;if(tag){await customElements.whenDefined(tag);node=document.querySelector(tag);if(!node)throw Error('missing root');await node.updateComplete;if(!node.shadowRoot?.childElementCount)throw Error('empty shadow');}%@return {ok:true,title:document.title,tag};})()", tag, body];
      NSData* payload = [NSJSONSerialization dataWithJSONObject:@{@"id":@1,@"method":@"Runtime.evaluate",@"params":@{@"expression":expression,@"awaitPromise":@YES,@"returnByValue":@YES,@"timeout":@15000}} options:0 error:nil];
      NSString* text = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding];
      [devtools_socket sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:text] completionHandler:^(NSError* error) { assert(!error); }];
      receive();
    });
  }] resume];
}
static void event(void*, const ReArcTabEvent* e) {
  if (e->tab_id != tab) return;
  assert(!e->is_crashed);
  if (e->kind == 3) { assert(!e->is_error_page); if (index_ < pages.size() && std::string(e->url).starts_with(pages[index_])) committed = true; }
  if (index_ == pages.size()) {
    if (!checking && e->kind == 1 && (e->changes & 2) && std::string(e->title).starts_with("probe:")) {
      checking = true;
      assert(ReArcTabEvaluateScript(tab,"globalThis.webuiReturn",0,"webui",3000,returned,nullptr) == REARC_OK);
    }
  } else if (!checking && e->kind == 1 && (e->changes & 4) && !e->is_loading && committed) {
    checking = true;
    ReArcStatus status = ReArcTabEvaluateScript(tab,"1",1,nullptr,1000,returned,nullptr);
    fprintf(stdout,"PRIVILEGE index=%zu url=%s status=%d\n",index_,e->url,status);
    assert(status == REARC_UNSUPPORTED);
    assert(ReArcTabCaptureSnapshot(tab,0,impossible,nullptr) == REARC_UNSUPPORTED);
    check_page();
  }
}
static void navigate() {
  committed = false;
  std::string url = index_ < pages.size() ? pages[index_] : "http://127.0.0.1:" + std::string(getenv("REARC_TEST_PORT")) + "/test";
  assert(ReArcTabNavigate(tab,url.c_str(),0) == REARC_OK);
}
static void installed(void*, ReArcStatus s, bool c) { assert(s == REARC_OK && !c); navigate(); }
static void ready(void*, uint64_t profile) {
  assert(ReArcEngineABIMinorVersion() >= 52 && ReArcEngineHasFeature("webui_daily_pages") && ReArcEngineHasFeature("webui_credits"));
  for (const char* rejected : {"chrome://flags/", "chrome://crash/", "chrome://quit/", "chrome://restart/", "chrome://bookmarks/", "chrome-untrusted://history/", "chrome://history.evil/", "chrome://credits.evil/", "chrome-untrusted://credits/", "view-source:chrome://credits/", "view-source:chrome://history/"}) {
    uint64_t bad = 123;
    assert(ReArcTabCreate(profile,1,rejected,&bad) == REARC_INVALID_URL && !bad);
  }
  session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
  window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,900,700) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  assert(ReArcWindowRegister(1,(__bridge void*)window) == REARC_OK);
  [window makeKeyAndOrderFront:nil];
  assert(ReArcTabCreate(profile,1,nullptr,&tab) == REARC_OK);
  assert(ReArcViewAttach(tab,1,900,700,1,&lease) == REARC_OK);
  [window.contentView addSubview:(__bridge NSView*)lease.native_view];
  assert(ReArcViewSetVisible(tab,lease.attachment_id,true) == REARC_OK);
  ReArcScriptScope scope{"127.0.0.1","/test",false,1};
  ReArcScript script{"webui",&scope,1,0,"globalThis.webuiReturn=42;",""};
  assert(ReArcTabSetScripts(tab,&script,1,installed,nullptr) == REARC_OK);
}
int main(int argc, const char** argv) { @autoreleasepool {
  setbuf(stdout,nullptr);
  for (int i=1;i<argc;++i) if(std::string(argv[i]).starts_with("--user-data-dir=")) profile_path=argv[i]+16;
  assert(!profile_path.empty());
  ReArcCallbacks c{ready,event,nullptr,nullptr};
  assert(ReArcEngineConfigure(1,&c,nullptr) == REARC_OK);
  int result=ReArcEngineRun(argc,argv); assert(result==0 && stopped);
  [session invalidateAndCancel]; return result;
}}
