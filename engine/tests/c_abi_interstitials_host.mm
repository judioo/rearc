#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <functional>
#include <string>
static uint64_t profile,tab;
static NSWindow* window;
static ReArcAttachment lease{};
static std::string base,blocked_other,secure,other,profile_path,committed;
static int stage;
static bool stopped,settled;
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


static void navigate(std::string url){settled=false;assert(ReArcTabNavigate(tab,url.c_str(),0)==REARC_OK);}
static void finish(){
 assert(ReArcEngineShutdown(true,[](void*,ReArcStatus s,bool c){assert(!s&&!c);ReArcViewRelease(lease.native_view);stopped=true;puts("INTERSTITIALS PASS");},nullptr)==REARC_OK);cdp::close_browser();
}
static void inspect(std::string prefix,bool certificate,bool proceed,int next){
 cdp::attach(prefix,[certificate,proceed,next]{
   cdp::eval(@"return await wait(()=>document.querySelector('#main-content')&&document.body.textContent,'interstitial DOM');",[certificate,proceed,next](std::string text){
     printf("INTERSTITIAL stage=%d DOM=%s\n",stage,text.substr(0,280).c_str());
     if(certificate)assert(text.find("ERR_CERT_")!=std::string::npos);
     else assert(text.find("Dangerous")!=std::string::npos||text.find("dangerous")!=std::string::npos||text.find("Deceptive")!=std::string::npos);
     auto* action = new std::function<void()>([proceed,next] {
       stage=next;settled=false;
       cdp::eval(proceed?@"document.querySelector('#details-button').click();document.querySelector('#proceed-link').click();return 'proceed';":@"document.querySelector('#primary-button').click();return 'back';",[](std::string){});
     });
     assert(ReArcTabCaptureSnapshot(tab,0,[](void* ctx,ReArcStatus status,uint64_t,uint64_t,uint8_t* bytes,size_t size){
       assert(status==REARC_OK&&bytes&&size>2000);
       std::string path=profile_path+"/interstitial-"+std::to_string(stage)+".png";
       FILE* file=fopen(path.c_str(),"wb");assert(file);assert(fwrite(bytes,1,size,file)==size);fclose(file);ReArcBufferFree(bytes);
       printf("INTERSTITIAL native PNG %s bytes=%zu\n",path.c_str(),size);
       auto* action=static_cast<std::function<void()>*>(ctx);(*action)();delete action;
     },action)==REARC_OK);
   });
 });
}
static void loaded(){
 printf("INTERSTITIAL loaded stage=%d url=%s\n",stage,committed.c_str());
 if(stage==0&&committed==base+"/visit-a"){stage=1;navigate(secure+"/visit-b");}
 else if(stage==1&&committed==secure+"/visit-b")inspect(secure,true,true,2);
 else if(stage==2&&committed==secure+"/visit-b"){
   cdp::attach(secure,[]{cdp::eval(@"return document.title;",[](std::string r){assert(r=="ReArc visit B");puts("INTERSTITIAL self-signed cert rendered, proceed reaches target PASS");stage=3;navigate(other+"/visit-c");});});
 }else if(stage==3&&committed==other+"/visit-c")inspect(other,true,false,4);
 else if(stage==4&&committed==secure+"/visit-b"){
   puts("INTERSTITIAL second-origin certificate back returns to previous entry PASS");stage=5;navigate(base+"/phishing-a");
 }else if(stage==5&&committed==base+"/phishing-a")inspect(base+"/phishing-a",false,true,6);
 else if(stage==6&&committed==base+"/phishing-a"){
   cdp::attach(base+"/phishing-a",[]{cdp::eval(@"return String(!document.querySelector('#main-content'));",[](std::string r){assert(r=="true");puts("INTERSTITIAL Safe Browsing test blocklist rendered, proceed reaches target PASS");stage=7;navigate(blocked_other+"/phishing-b");});});
 }else if(stage==7&&committed==blocked_other+"/phishing-b")inspect(blocked_other+"/phishing-b",false,false,8);
 else if(stage==8&&committed==base+"/phishing-a"){
   puts("INTERSTITIAL Safe Browsing back returns to previous entry PASS");finish();
 }
}
static void event(void*,const ReArcTabEvent* e){
 if(e->tab_id!=tab)return;assert(!e->is_crashed);
 if(e->kind==3&&e->is_main_frame&&!e->is_same_document){committed=e->url;settled=false;}
 if(e->kind==1&&(e->changes&4)&&!e->is_loading&&!settled){settled=true;later(.6,loaded);}
}
static void ready(void*,uint64_t p){
 profile=p;
 window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,900,700) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
 assert(ReArcWindowRegister(1,(__bridge void*)window)==REARC_OK);[window makeKeyAndOrderFront:nil];
 assert(ReArcTabCreate(profile,1,(base+"/visit-a").c_str(),&tab)==REARC_OK);
 assert(ReArcViewAttach(tab,1,900,700,1,&lease)==REARC_OK);[window.contentView addSubview:(__bridge NSView*)lease.native_view];
 assert(ReArcViewSetVisible(tab,lease.attachment_id,true)==REARC_OK);
}
int main(int argc,const char** argv){@autoreleasepool{
 setbuf(stdout,nullptr);for(int i=1;i<argc;++i)if(std::string(argv[i]).starts_with("--user-data-dir="))profile_path=argv[i]+16;
 base="http://127.0.0.1:"+std::string(getenv("REARC_TEST_PORT"));blocked_other="http://localhost:"+std::string(getenv("REARC_TEST_PORT"));
 std::string port=getenv("REARC_TEST_HTTPS_PORT");secure="https://127.0.0.1:"+port;other="https://localhost:"+port;
 cdp::session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
 ReArcCallbacks c{ready,event,nullptr,nullptr};assert(ReArcEngineConfigure(1,&c,nullptr)==REARC_OK);
 int r=ReArcEngineRun(argc,argv);assert(!r&&stopped);return r;
}}
