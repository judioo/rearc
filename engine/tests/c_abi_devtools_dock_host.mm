// Dockable DevTools (devtools_docking, ABI 1.54). Windowless: the views are
// attached to a transparent borderless window far off screen, ordered in
// without activation so the renderers paint (device mode lays out on frames).
// Phase 0: a frontend opened before the callback is set is not dockable; with
// it, can_dock=true, the device toolbar and toggle-dock actions exist, every
// side round-trips through setIsDocked, device emulation reaches the page
// docked and undocked (through the adopted toolbox), and the toolbox closes
// with its frontend; undocked, the toolbox loads its page, the device-mode
// action shows and hides the device toolbar there and the page fills the
// toolbox without it. Phase 1 (same profile): the last side persisted.
#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <functional>
#include <map>
#include <set>
#include <string>
#include <vector>
#include "c_abi_test_devtools.h"
static uint64_t target,front,toolbox,replaced;
static NSWindow* window;
static std::map<uint64_t,ReArcAttachment> leases;
static std::set<uint64_t> closed;
static std::vector<ReArcDevToolsDockEvent> docks;
static std::string base,front_url;
static bool stopped,started,second;
static std::set<uint64_t> loaded_toolboxes;
static NSURLSessionWebSocketTask* ws;
static int seq;
static std::function<void(NSDictionary*)> reply;
static void after(int ms,std::function<void()> f){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)ms*NSEC_PER_MSEC),dispatch_get_main_queue(),^{f();});}
static void receive(){[ws receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage* m,NSError* err){assert(!err&&m);NSDictionary* d=[NSJSONSerialization JSONObjectWithData:[m.string dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];dispatch_async(dispatch_get_main_queue(),^{if(!d[@"id"]){receive();return;}assert(!d[@"error"]);auto f=std::move(reply);reply=nullptr;f(d[@"result"]);});}];}
static void evaluate(NSString* expression,std::function<void(id)> f){assert(!reply);reply=[f](NSDictionary* r){if(r[@"exceptionDetails"])NSLog(@"FRONTEND EXCEPTION %@",r);assert(!r[@"exceptionDetails"]);f(r[@"result"][@"value"]);};NSData* data=[NSJSONSerialization dataWithJSONObject:@{@"id":@(++seq),@"method":@"Runtime.evaluate",@"params":@{@"expression":expression,@"awaitPromise":@YES,@"returnByValue":@YES}} options:0 error:nil];[ws sendMessage:[[NSURLSessionWebSocketMessage alloc]initWithString:[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]] completionHandler:^(NSError* e){assert(!e);}];receive();}
static void connect_front(std::function<void()> f){
 NSURL* url=[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%@/json/list",test_cdp::port_lines()[0]]];
 [[test_cdp::session dataTaskWithURL:url completionHandler:^(NSData* data,NSURLResponse*,NSError* e){assert(!e&&data);NSArray* ts=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];dispatch_async(dispatch_get_main_queue(),^{NSString* address=nil;for(NSDictionary* t in ts)if([t[@"url"] hasPrefix:@"devtools://devtools/bundled/devtools_app.html"])address=t[@"webSocketDebuggerUrl"];if(!address){after(150,[f]{connect_front(f);});return;}ws=[test_cdp::session webSocketTaskWithURL:[NSURL URLWithString:address]];[ws resume];f();});}] resume];
}
static void attach(uint64_t id){ReArcAttachment a{};assert(ReArcViewAttach(id,1,1000,500,1,&a)==0);NSView* v=(__bridge NSView*)a.native_view;v.frame=NSMakeRect(0,0,1000,500);[window.contentView addSubview:v];assert(ReArcViewSetVisible(id,a.attachment_id,true)==0);leases[id]=a;}
// Waits (bounded) for the newest dock event of the frontend to satisfy pred.
static void wait_dock(const char* what,std::function<bool(const ReArcDevToolsDockEvent&)> pred,std::function<void()> f,int tries=200){
 for(auto it=docks.rbegin();it!=docks.rend();++it)if(it->frontend_tab_id==front){if(pred(*it)){printf("DOCK %s: side %u in_tab %s bounds %s %d,%d %dx%d PASS\n",what,it->dock_side,it->in_tab_tab_id==front?"frontend":it->in_tab_tab_id&&it->in_tab_tab_id==toolbox?"toolbox":"none",it->has_bounds?"yes":"no",it->x,it->y,it->width,it->height);f();return;}break;}
 if(!tries){for(auto& d:docks)NSLog(@"dock event front %llu side %u in_tab %llu bounds %d %d,%d %dx%d",d.frontend_tab_id,d.dock_side,d.in_tab_tab_id,d.has_bounds,d.x,d.y,d.width,d.height);fprintf(stderr,"DOCK timed out waiting for %s\n",what);abort();}
 after(50,[=]{wait_dock(what,pred,f,tries-1);});
}
static void side(NSString* to,std::function<void()> f){evaluate([NSString stringWithFormat:@"(async()=>{const UI=await import('./ui/legacy/legacy.js');UI.DockController.DockController.instance().setDockSide('%@');return 1})()",to],[f](id){f();});}
// Device emulation as the device toolbar applies it, read back in the page.
// Responsive with a desktop UA: mobile emulation trips a debug-only Blink
// DCHECK on Mac when the page resizes (scrollable_area.cc,
// BlinkControlsOverlayVisibility), unrelated to hosting.
static NSString* const kEmulate=@R"JS((async()=>{
 const E=await import('./models/emulation/emulation.js'),SDK=await import('./core/sdk/sdk.js');
 const m=E.DeviceModeModel.DeviceModeModel.instance();
 m.uaSetting().set('Desktop');
 m.emulate(E.DeviceModeModel.Type.Responsive,null,null);
 m.setWidth(375);m.setHeight(100);
 const t=SDK.TargetManager.TargetManager.instance().primaryPageTarget();
 let w=0;for(const end=Date.now()+15000;w!==375&&Date.now()<end;){await new Promise(r=>setTimeout(r,50));w=(await t.runtimeAgent().invoke_evaluate({expression:'screen.width',returnByValue:true})).result.value;}
 if(w!==375)return JSON.stringify({w,type:m.type(),device:m.device()?.title,applied:m.appliedDeviceSize(),avail:m.availableSize?.(),targets:SDK.TargetManager.TargetManager.instance().targets().map(t=>t.type()+':'+t.hasAllCapabilities?.(4))});
 return w;
})())JS";
static void shutdown(){ReArcEngineSetDevToolsDockCallback(nullptr,nullptr);assert(ReArcEngineShutdown(true,[](void*,ReArcStatus s,bool c){assert(!s&&!c);for(auto [id,a]:leases)ReArcViewRelease(a.native_view);stopped=true;},nullptr)==0);test_cdp::close_browser();}
static void reloaded(int tries=400);
static void closing(){
 assert(ReArcTabClose(front,false,[](void*,ReArcStatus s,bool c){assert(!s&&!c);after(500,[]{assert(closed.contains(front)&&!closed.contains(target));if(toolbox){assert(closed.contains(toolbox));puts("DOCK toolbox closes with its frontend PASS");}shutdown();});},nullptr)==0);
}
static void toggle_device_mode(std::function<void()> f){evaluate(@"(async()=>{const UI=await import('./ui/legacy/legacy.js');await UI.ActionRegistry.ActionRegistry.instance().getAction('emulation.toggle-device-mode').execute();return 1})()",[f](id){f();});}
static void wait_toolbox_loaded(std::function<void()> f,int tries=200){
 if(loaded_toolboxes.contains(toolbox)){puts("DOCK toolbox loads device_mode_emulation_frame.html PASS");f();return;}
 if(!tries){fprintf(stderr,"DOCK toolbox %llu never committed its page\n",toolbox);abort();}
 after(50,[f,tries]{wait_toolbox_loaded(f,tries-1);});
}
static bool fills_toolbox(const ReArcDevToolsDockEvent& d){return d.dock_side==0&&d.in_tab_tab_id==toolbox&&d.has_bounds&&d.x==0&&d.y==0&&d.width==1000&&d.height==500;}
// Device mode on in the toolbox: its toolbar sits above the page.
static bool device_mode_in_toolbox(const ReArcDevToolsDockEvent& d){return d.dock_side==0&&d.in_tab_tab_id==toolbox&&d.has_bounds&&d.y>0&&d.width>0&&d.width<=1000&&d.height>0&&d.height<500;}
static void undocked(){
 // Chrome's toolbox: opened by the frontend, adopted with opener = frontend.
 // Its page must load (the renderer forks it through OpenURLFromTab), or
 // the device toolbar has nowhere to show and the page keeps its docked
 // bounds. Device mode is still on from the bottom dock.
 wait_dock("undocked",[](auto& d){return d.dock_side==0&&toolbox&&d.in_tab_tab_id==toolbox;},[]{
  wait_toolbox_loaded([]{
   wait_dock("undocked device mode shows in the toolbox",device_mode_in_toolbox,[]{
    // The device-mode action is ⌘⇧M and the toolbar's device icon.
    toggle_device_mode([]{wait_dock("undocked device mode off: the page fills the toolbox",fills_toolbox,[]{
     toggle_device_mode([]{wait_dock("undocked device mode back on",device_mode_in_toolbox,[]{
      evaluate(kEmulate,[](id w){NSLog(@"EMULATE %@",w);assert([w isKindOfClass:NSNumber.class]&&[w intValue]==375);puts("DOCK device emulation reaches the page undocked PASS");
       wait_dock("undocked 375px responsive bounds",[](auto& d){return device_mode_in_toolbox(d)&&d.width==375;},[]{
        // A reloaded frontend opens a new toolbox; it replaces the old one, as in DevToolsWindow.
        assert(ReArcTabReload(front,false)==REARC_OK);reloaded();});});});});});});});});});
}
static void reloaded(int tries){
 if(!(replaced&&closed.contains(replaced))){assert(tries);after(50,[tries]{reloaded(tries-1);});return;}
 puts("DOCK reloaded frontend's toolbox replaces the old one PASS");
 wait_dock("undocked after reload",[](auto& d){return d.dock_side==0&&d.in_tab_tab_id==toolbox&&d.has_bounds;},[]{wait_toolbox_loaded([]{
    evaluate(@"(async()=>{const UI=await import('./ui/legacy/legacy.js');const a=UI.ActionRegistry.ActionRegistry.instance();for(let n=0;n<200&&!a.hasAction('main.toggle-dock');++n)await new Promise(r=>setTimeout(r,50));return 1})()",[](id){
    // ⌘⇧D's action: back to the last docked side.
    evaluate(@"(async()=>{const UI=await import('./ui/legacy/legacy.js');await UI.ActionRegistry.ActionRegistry.instance().getAction('main.toggle-dock').execute();return 1})()",[](id){
     wait_dock("toggle-dock back to bottom",[](auto& d){return d.dock_side==2&&d.in_tab_tab_id==front;},[]{side(@"left",[]{wait_dock("left again",[](auto& d){return d.dock_side==3;},closing);});});});});});});
}
static void prove(){
 connect_front([]{evaluate(@R"JS((async()=>{
  const Root=await import('./core/root/root.js'),UI=await import('./ui/legacy/legacy.js');
  const actions=UI.ActionRegistry.ActionRegistry.instance();
  for(let n=0;n<200&&!actions.hasAction('emulation.toggle-device-mode');++n)await new Promise(r=>setTimeout(r,50));
  const keys=UI.ShortcutRegistry.ShortcutRegistry.instance();
  return {canDock:Root.Runtime.conditions.canDock(),device:actions.hasAction('emulation.toggle-device-mode'),dock:actions.hasAction('main.toggle-dock'),
   side:UI.DockController.DockController.instance().dockSide(),
   deviceKey:keys.shortcutsForAction('emulation.toggle-device-mode').map(s=>s.title()).join(),dockKey:keys.shortcutsForAction('main.toggle-dock').map(s=>s.title()).join()};
 })())JS",[](id v){NSLog(@"FRONTEND DOCKING %@",v);
  assert([v[@"canDock"] boolValue]&&[v[@"device"] boolValue]&&[v[@"dock"] boolValue]);
  puts("DOCK frontend can dock; device toolbar and toggle-dock actions registered PASS");
  printf("DOCK shortcuts: device toolbar %s, toggle dock %s\n",[v[@"deviceKey"] UTF8String],[v[@"dockKey"] UTF8String]);
  if(second){assert([v[@"side"] isEqual:@"left"]);puts("DOCK side persisted across frontends PASS");closing();return;}
  assert([v[@"side"] isEqual:@"right"]);
  side(@"left",[]{wait_dock("left",[](auto& d){return d.dock_side==3&&d.in_tab_tab_id==front&&d.has_bounds&&d.x>0;},[]{
   side(@"bottom",[]{wait_dock("bottom",[](auto& d){return d.dock_side==2&&d.has_bounds&&d.y==0&&d.height<500&&d.width>900;},[]{
    evaluate(@"(async()=>{const UI=await import('./ui/legacy/legacy.js');await UI.ActionRegistry.ActionRegistry.instance().getAction('emulation.toggle-device-mode').execute();return 1})()",[](id){
     evaluate(kEmulate,[](id w){NSLog(@"EMULATE %@",w);assert([w isKindOfClass:NSNumber.class]&&[w intValue]==375);puts("DOCK device emulation reaches the page docked PASS");side(@"undocked",undocked);});});});});});});
 });});
}
static void dock(void*,const ReArcDevToolsDockEvent* e){assert(e&&e->target_tab_id==target);assert(e->dock_side<=3);docks.push_back(*e);}
static void event(void*,const ReArcTabEvent* e){
 if(e->is_crashed)fprintf(stderr,"DOCK crashed tab %llu kind %u (target %llu front %llu toolbox %llu replaced %llu)\n",e->tab_id,e->kind,target,front,toolbox,replaced);
 assert(!e->is_crashed);if(e->kind==2){closed.insert(e->tab_id);return;}
 if(e->kind==0&&e->opener_tab_id==front&&front){assert(!replaced);replaced=toolbox;toolbox=e->tab_id;assert(std::string(e->url).rfind("devtools://devtools/bundled/device_mode_emulation_frame.html",0)==0);attach(toolbox);puts("DOCK toolbox adopted as a registry tab PASS");}
 if(e->kind==0&&e->opener_tab_id==target)front_url=e->url?e->url:"";
 if(e->kind==3&&e->tab_id==toolbox&&toolbox&&e->url&&std::string(e->url).rfind("devtools://devtools/bundled/device_mode_emulation_frame.html",0)==0)loaded_toolboxes.insert(e->tab_id);
 if(e->tab_id==target&&e->kind==1&&(e->changes&2)&&std::string(e->title)=="devtools-ready"&&!started){started=true;
  uint64_t plain=0;assert(ReArcTabOpenDevTools(target,&plain)==0&&plain);
  assert(ReArcTabClose(plain,true,[](void*,ReArcStatus s,bool){assert(!s);assert(front_url.rfind("devtools://devtools/bundled/devtools_app.html",0)==0&&front_url.find("can_dock")==std::string::npos);
   puts("DOCK frontend without a dock callback is not dockable PASS");
   ReArcEngineSetDevToolsDockCallback(dock,nullptr);
   assert(ReArcTabOpenDevTools(target,&front)==0);attach(front);
   // DevToolsWindow waits for the first setIsDocked; the side is the profile's.
   wait_dock("first setIsDocked",[](auto& d){return d.in_tab_tab_id==front&&d.dock_side==(second?3u:1u);},[]{
    assert(front_url.find("&can_dock=true")!=std::string::npos);puts("DOCK frontend opened with can_dock=true PASS");
    if(!second)wait_dock("right page bounds",[](auto& d){return d.has_bounds&&d.x==0&&d.y==0&&d.width>0&&d.width<1000&&d.height>=499;},prove);else prove();});
  },nullptr)==0);}
}
static void ready(void*,uint64_t p){assert(ReArcEngineHasFeature("devtools_docking")&&ReArcEngineABIMinorVersion()>=54);
 window=[[NSWindow alloc]initWithContentRect:NSMakeRect(-20000,-20000,1000,500) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];assert(ReArcWindowRegister(1,(__bridge void*)window)==0);
 window.alphaValue=0;window.ignoresMouseEvents=YES;[window orderFrontRegardless];
 assert(ReArcTabCreate(p,1,(base+"/devtools").c_str(),&target)==0);attach(target);}
int main(int argc,const char** argv){@autoreleasepool{setbuf(stdout,nullptr);test_cdp::initialize(argc,argv);base="http://127.0.0.1:"+std::string(getenv("REARC_TEST_PORT"));second=getenv("REARC_DEVTOOLS_DOCK_SECOND")!=nullptr;ReArcCallbacks c{ready,event,nullptr,nullptr};assert(ReArcEngineConfigure(1,&c,nullptr)==0);int r=ReArcEngineRun(argc,argv);assert(!r&&stopped);return r;}}
