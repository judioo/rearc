#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <functional>
#include <string>
#include <vector>
static uint64_t profile,tab;
static NSWindow* window;
static ReArcAttachment lease{};
static std::string secure,profile_path,committed;
static int stage,offers,withdrawn;
static uint64_t last_request;
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


static void navigate(std::string url) { settled=false; assert(ReArcTabNavigate(tab,url.c_str(),0)==REARC_OK); }
static void finish() {
  assert(ReArcEngineShutdown(true,[](void*,ReArcStatus s,bool c){assert(!s&&!c);ReArcViewRelease(lease.native_view);stopped=true;puts("SAVE PASS");},nullptr)==REARC_OK);
  cdp::close_browser();
}
static void offer(void*,const ReArcAutofillSaveEvent* e) {
  printf("SAVE phase=%u kind=%u summary=%s\n",e->phase,e->kind,e->summary);
  if(e->phase) {
    ++withdrawn;
    assert(ReArcAutofillSaveRespond(e->request_id,0)==REARC_NOT_FOUND);
    if(stage==5) { puts("SAVE navigation withdrawal and stale reply PASS");later(.2,[]{navigate(secure+"/save");}); }
    return;
  }
  ++offers;last_request=e->request_id;
  assert(e->tab_id==tab&&e->profile_id==profile&&e->request_id);
  assert(std::string(e->origin).starts_with(secure));
  if(e->kind==0) {
    assert(std::string(e->summary).find("4111111111111111")==std::string::npos);
    assert(std::string(e->summary).find(stage==1?"1111":stage==2?"0002":stage==4?"4444":stage==5?"1881":"5100")!=std::string::npos);
  } else {assert(e->kind==1&&std::string(e->summary).find("18G Test Way")!=std::string::npos);}
  if(stage==4) {stage=5;later(.3,[]{navigate(secure+"/visit-a");});return;}
  if(stage==5) {
    ReArcEngineSetAutofillSaveCallback(nullptr,nullptr);
    assert(ReArcAutofillSaveRespond(e->request_id,0)==REARC_NOT_FOUND);
    ReArcEngineSetAutofillSaveCallback(offer,nullptr);
    puts("SAVE callback replacement withdraws pending offer PASS");stage=6;later(.2,[]{navigate(secure+"/save");});return;
  }
  if(stage==6) {
    stage=7;
    assert(ReArcTabClose(tab,true,[](void*,ReArcStatus s,bool cancelled){
      assert(!s&&!cancelled&&withdrawn>=2&&offers==6);
      assert(ReArcAutofillSaveRespond(last_request,0)==REARC_NOT_FOUND);
      puts("SAVE pending close withdrawal PASS");finish();
    },nullptr)==REARC_OK);return;
  }
  assert(ReArcAutofillSaveRespond(e->request_id,99)==REARC_INVALID_ARGUMENT);
  assert(ReArcAutofillSaveRespond(e->request_id,stage==1?1:0)==REARC_OK);
  assert(ReArcAutofillSaveRespond(e->request_id,0)==REARC_NOT_FOUND);
  ++stage;
  later(1,[]{navigate(stage<3?secure+"/save":"chrome://settings/");});
}
using Fields=std::vector<std::pair<std::string,std::string>>;
static void type(Fields fields,size_t index,std::function<void()> done) {
  if(index==fields.size()){done();return;}
  auto [id,value]=fields[index];
  NSString* focus=[NSString stringWithFormat:@"document.getElementById('%s').focus();return 'focused';",id.c_str()];
  cdp::eval(focus,[fields,index,value,done](std::string){
    cdp::send(@"Input.insertText",@{@"text":[NSString stringWithUTF8String:value.c_str()]},[fields,index,done](NSDictionary*){type(fields,index+1,done);});
  });
}
static void form() {
  cdp::attach(secure+"/save",[]{
    Fields fields=stage==0?Fields{{"name","Rearc Save Tester"},{"street","18G Test Way"},{"city","Mountain View"},{"state","CA"},{"zip","94043"},{"email","save@example.test"},{"phone","6505551234"}}:
      Fields{{"ccname","Rearc Save Tester"},{"ccnum",stage==1?"4111111111111111":stage==2?"4000000000000002":stage==4?"5555555555554444":stage==5?"4012888888881881":"5105105105105100"},{"ccexp","12/2031"}};
    type(fields,0,[]{
      later(.5,[]{cdp::eval(stage==0?@"document.querySelector('#address').requestSubmit();return 'submitted';":@"document.querySelector('#card').requestSubmit();return 'submitted';",[](std::string r){assert(r=="submitted");});});
    });
  });
}
static void verify() {
  cdp::attach("chrome://settings",[]{
    cdp::eval(@"const a=await wait(async()=>{const a=await chrome.autofillPrivate.getAddressList();return a.length===1&&a},'address');"
               "const c=await wait(async()=>{const c=await chrome.autofillPrivate.getCreditCardList();return c.length===1&&c},'card');"
               "return JSON.stringify({address:a[0],card:c[0]});",[](std::string r){
      printf("SAVE persisted %s\n",r.c_str());assert(offers==3);assert(r.find("0002")!=std::string::npos&&r.find("1111")==std::string::npos);
      puts("SAVE address accepted, local card declined then different card accepted; Chromium store persistence PASS");stage=4;navigate(secure+"/save");
    });
  });
}
static void event(void*,const ReArcTabEvent* e) {
  if(e->tab_id!=tab)return;assert(!e->is_crashed);
  if(e->kind==3&&e->is_main_frame&&!e->is_same_document){committed=e->url;settled=false;}
  if(e->kind!=1||!(e->changes&4)||e->is_loading||settled)return;
  if(committed==secure+"/save"){settled=true;int expected=stage;later(1,[expected]{if(stage==expected&&committed==secure+"/save")form();});}
  else if(committed.starts_with("chrome://settings")&&stage==3){settled=true;later(1,verify);}
}
static void ready(void*,uint64_t p) {
  profile=p;assert(ReArcEngineHasFeature("autofill_save_prompts"));
  assert(ReArcProfileSetPasswordLeakDetection(profile,false)==REARC_OK);
  ReArcEngineSetAutofillSaveCallback(offer,nullptr);
  window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,900,700) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  assert(ReArcWindowRegister(1,(__bridge void*)window)==REARC_OK);[window makeKeyAndOrderFront:nil];
  assert(ReArcTabCreate(profile,1,(secure+"/save").c_str(),&tab)==REARC_OK);
  assert(ReArcViewAttach(tab,1,900,700,1,&lease)==REARC_OK);[window.contentView addSubview:(__bridge NSView*)lease.native_view];
  assert(ReArcViewSetVisible(tab,lease.attachment_id,true)==REARC_OK);
}
int main(int argc,const char** argv){@autoreleasepool{
  setbuf(stdout,nullptr);for(int i=1;i<argc;++i)if(std::string(argv[i]).starts_with("--user-data-dir="))profile_path=argv[i]+16;
  secure="https://127.0.0.1:"+std::string(getenv("REARC_TEST_HTTPS_PORT"));
  cdp::session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
  ReArcCallbacks c{ready,event,nullptr,nullptr};assert(ReArcEngineConfigure(1,&c,nullptr)==REARC_OK);
  int result=ReArcEngineRun(argc,argv);assert(result==0&&stopped);return result;
}}
