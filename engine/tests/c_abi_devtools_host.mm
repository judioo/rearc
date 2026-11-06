#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <functional>
#include <map>
#include <set>
#include <string>
#include "c_abi_test_devtools.h"
static uint64_t profile,target,front,extra;
static NSWindow* window;
static std::map<uint64_t,ReArcAttachment> leases;
static std::set<uint64_t> closed;
static std::string base;
static bool stopped,started;
static int mode,stage;
static NSURLSessionWebSocketTask* ws;
static int seq;
static std::function<void(NSDictionary*)> reply;
static void later(std::function<void()> f){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,150*NSEC_PER_MSEC),dispatch_get_main_queue(),^{f();});}
static void receive(){[ws receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage* m,NSError* err){assert(!err&&m);NSDictionary* d=[NSJSONSerialization JSONObjectWithData:[m.string dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];dispatch_async(dispatch_get_main_queue(),^{if(!d[@"id"]){receive();return;}assert(!d[@"error"]);auto f=std::move(reply);reply=nullptr;f(d[@"result"]);});}];}
static void command(NSString* method,NSDictionary* params,std::function<void(NSDictionary*)> f){assert(!reply);reply=std::move(f);NSData* data=[NSJSONSerialization dataWithJSONObject:@{@"id":@(++seq),@"method":method,@"params":params} options:0 error:nil];[ws sendMessage:[[NSURLSessionWebSocketMessage alloc]initWithString:[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]] completionHandler:^(NSError* e){assert(!e);}];receive();}
static void evaluate(NSString* expression,std::function<void(id)> f){command(@"Runtime.evaluate",@{@"expression":expression,@"awaitPromise":@YES,@"returnByValue":@YES},[f](NSDictionary* r){if(r[@"exceptionDetails"])NSLog(@"FRONTEND EXCEPTION %@",r);assert(!r[@"exceptionDetails"]);f(r[@"result"][@"value"]);});}
static void after(int ms,std::function<void()> f){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)ms*NSEC_PER_MSEC),dispatch_get_main_queue(),^{f();});}
// Browser- and frontend-initiated navigations away from the bundled app are
// cancelled by the hosted throttle; the same frontend document stays connected.
static void locked(std::function<void()> f){
 assert(ReArcTabNavigate(front,(base+"/devtools").c_str(),0)==REARC_OK);
 after(700,[f]{evaluate([NSString stringWithFormat:@"location.assign('%s/devtools');location.href",base.c_str()],[f](id){after(700,[f]{evaluate(@"location.href",[f](id href){
  assert([href hasPrefix:@"devtools://devtools/bundled/devtools_app.html"]);puts("DEVTOOLS frontend URL locked to bundled app PASS");f();});});});});
}
static void connect_front(std::function<void()> f){
 NSURL* url=[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%@/json/list",test_cdp::port_lines()[0]]];
 [[test_cdp::session dataTaskWithURL:url completionHandler:^(NSData* data,NSURLResponse*,NSError* e){assert(!e&&data);NSArray* ts=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];dispatch_async(dispatch_get_main_queue(),^{NSString* address=nil;for(NSDictionary* t in ts)if([t[@"url"] hasPrefix:@"devtools://devtools/bundled/"])address=t[@"webSocketDebuggerUrl"];if(!address){later([f]{connect_front(f);});return;}ws=[test_cdp::session webSocketTaskWithURL:[NSURL URLWithString:address]];[ws resume];f();});}] resume];
}
static void attach(uint64_t id,int x){ReArcAttachment a{};assert(ReArcViewAttach(id,1,500,500,1,&a)==0);NSView* v=(__bridge NSView*)a.native_view;v.frame=NSMakeRect(x,0,500,500);[window.contentView addSubview:v];assert(ReArcViewSetVisible(id,a.attachment_id,true)==0);leases[id]=a;}
static void shutdown(bool force){assert(ReArcEngineShutdown(force,[](void*,ReArcStatus s,bool c){assert(!s&&!c);for(auto [id,a]:leases){assert(closed.contains(id));ReArcViewRelease(a.native_view);}stopped=true;puts("DEVTOOLS all registry contents destroyed before shutdown PASS");},nullptr)==0);test_cdp::close_browser();}
static void frontend_first(){
 assert(ReArcTabClose(front,false,[](void*,ReArcStatus s,bool c){assert(!s&&!c&&closed.contains(front)&&!closed.contains(target));puts("DEVTOOLS frontend first detaches without target close PASS");
   assert(ReArcTabEvaluateScript2(target,"document.querySelector('#pick').textContent",1,nullptr,5000,[](void*,const ReArcScriptResult* r){assert(!r->status&&std::string(r->json)=="\"select me\"");
     assert(ReArcTabOpenDevTools(target,&front)==0);attach(front,500);
     if(mode==0){assert(ReArcTabClose(target,true,[](void*,ReArcStatus s,bool c){assert(!s&&!c);later([]{assert(closed.contains(front));puts("DEVTOOLS target first closes frontend PASS");shutdown(true);});},nullptr)==0);}
     else shutdown(false);
   },nullptr)==0);
 },nullptr)==0);
}
static void prove_frontend(){
 connect_front([]{evaluate(@R"JS((async()=>{
  const SDK=await import('./core/sdk/sdk.js');
  for(let n=0;n<200&&!SDK.TargetManager.TargetManager.instance().primaryPageTarget();++n)await new Promise(r=>setTimeout(r,50));
  const t=SDK.TargetManager.TargetManager.instance().primaryPageTarget();
  if(!t)throw Error('no target attached: '+JSON.stringify(SDK.TargetManager.TargetManager.instance().targets().map(t=>({id:t.id(),type:t.type(),parent:t.parentTarget()?.id()}))));
  const r=await t.runtimeAgent().invoke_evaluate({expression:"document.title='console-proof';6*7",returnByValue:true});
  const dom=t.model(SDK.DOMModel.DOMModel),doc=await dom.requestDocument();
  const q=await t.domAgent().invoke_querySelector({nodeId:doc.id,selector:'#pick'});
  const node=dom.nodeForId(q.nodeId);
  const Common=await import('./core/common/common.js');await Common.Revealer.reveal(node);
  const Elements=await import('./panels/elements/elements.js');
  const selected=Elements.ElementsPanel.ElementsPanel.instance().selectedDOMNode();
  const unsupported=await new Promise(r=>DevToolsAPI.sendMessageToEmbedder('connectAutomaticFileSystem',['/tmp/no-workspace','none',true],r));
  const remote=await t.targetAgent().invoke_createTarget({url:'about:blank'});
  return {value:r.result.value,selected:selected?.getAttribute('id'),unsupported:unsupported.error,remote:remote.getError()};
 })())JS",[](id value){NSLog(@"FRONTEND PROOF %@",value);assert([value[@"value"] intValue]==42&&[value[@"selected"] isEqual:@"pick"]&&[value[@"unsupported"] isEqual:@"unsupported"]&&[value[@"remote"] isEqual:@"unsupported"]);
   puts("DEVTOOLS bundled frontend console, Elements selection, workspace/remote denial PASS");
   locked([]{
   [ws cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];ws=nil;
   if(mode<2)frontend_first();
   else if(mode==2){ // Frontend attached when shutdown joins an in-flight veto.
    test_cdp::focus(base,[]{assert(ReArcTabEvaluateScript2(target,"window.onbeforeunload=()=>true;document.body.onclick=()=>document.title='veto-clicked';true",1,nullptr,5000,[](void*,const ReArcScriptResult* r){assert(!r->status);NSPoint pt=[(__bridge NSView*)leases[target].native_view convertPoint:NSMakePoint(30,470) toView:nil];for(auto ty:{NSEventTypeLeftMouseDown,NSEventTypeLeftMouseUp}){NSEvent* e=[NSEvent mouseEventWithType:ty location:pt modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];NSView* hit=[window.contentView hitTest:pt];if(ty==NSEventTypeLeftMouseDown)[hit mouseDown:e];else[hit mouseUp:e];}},nullptr)==0);});
   }else {assert(ReArcProfileClose(profile,false,[](void*,ReArcStatus s,bool c){assert(!s&&!c&&closed.contains(target)&&closed.contains(front));puts("DEVTOOLS profile-close destruction barrier PASS");shutdown(true);},nullptr)==0);}
   });
 });});
}
static void event(void*,const ReArcTabEvent* e){
 assert(!e->is_crashed);if(e->kind==2){closed.insert(e->tab_id);return;}
 if(e->tab_id==front&&e->kind==3)assert(std::string(e->url?e->url:"").rfind("devtools://devtools/bundled/",0)==0);
 if(e->tab_id==target&&e->kind==1&&(e->changes&2)&&std::string(e->title)=="devtools-ready"&&!started){started=true;assert(ReArcTabOpenDevTools(target,&front)==0);attach(front,500);uint64_t no=123;assert(ReArcTabOpenDevTools(front,&no)==REARC_UNSUPPORTED&&!no);assert(ReArcTabNavigate(target,"devtools://devtools/bundled/devtools_app.html",0)==REARC_INVALID_URL);later([]{prove_frontend();});}
 if(mode==2&&e->tab_id==target&&e->kind==1&&(e->changes&2)&&std::string(e->title)=="veto-clicked"&&stage++==0){assert(ReArcTabClose(target,false,[](void*,ReArcStatus s,bool c){assert(!s&&c);},nullptr)==0);assert(ReArcEngineShutdown(false,[](void*,ReArcStatus s,bool c){assert(!s&&c&&!closed.contains(target)&&!closed.contains(front));puts("DEVTOOLS target veto preserved; frontend remains open PASS");shutdown(true);},nullptr)==0);}
}
static void begin(uint64_t p){profile=p;assert(ReArcTabCreate(p,1,(base+"/devtools").c_str(),&target)==0);attach(target,0);}
static void ready(void*,uint64_t p){assert(ReArcEngineHasFeature("devtools"));uint64_t no=123;assert(ReArcTabOpenDevTools(9999,&no)==REARC_TAB_NOT_FOUND&&!no);assert(ReArcTabOpenDevTools(9999,nullptr)==REARC_INVALID_ARGUMENT);assert(ReArcTabCreate(p,1,"devtools://devtools/bundled/devtools_app.html",&no)==REARC_INVALID_URL&&!no);
 window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,1000,500) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];assert(ReArcWindowRegister(1,(__bridge void*)window)==0);[window makeKeyAndOrderFront:nil];
 if(mode==3)assert(ReArcProfileCreateOffTheRecord(p,[](void*,ReArcStatus s,uint64_t p,bool otr){assert(!s&&otr);begin(p);},nullptr)==0);else begin(p);
}
int main(int argc,const char** argv){@autoreleasepool{setbuf(stdout,nullptr);test_cdp::initialize(argc,argv);base="http://127.0.0.1:"+std::string(getenv("REARC_TEST_PORT"));mode=atoi(getenv("REARC_DEVTOOLS_MODE")?:"0");ReArcCallbacks c{ready,event,nullptr,nullptr};assert(ReArcEngineConfigure(1,&c,nullptr)==0);int r=ReArcEngineRun(argc,argv);assert(!r&&stopped);return r;}}
