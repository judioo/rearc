#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <functional>
#include <map>
#include <set>
#include <string>
using Action = std::function<void()>;
static uint64_t profiles[4], tabs[4], old_a;
static std::map<uint64_t,uint64_t> identities;
static std::map<uint64_t,Action> loaded;
static std::set<uint64_t> closed, invalidated;
static std::map<uint64_t,std::string> icons;
static Action icons_ready, popup_ready;
static uint64_t popup;
static ReArcAttachment lease;
static NSWindow* window;
static bool stopped, second, eval_cancelled, pending_cancelled, reentrant_close;
static std::string url;
static void open(const char* key, std::function<void(uint64_t)> done) {
 auto* c=new std::function<void(uint64_t)>(std::move(done));
 assert(ReArcProfileOpen(key,[](void* c,ReArcStatus s,uint64_t id,bool otr){
  auto f=std::move(*static_cast<std::function<void(uint64_t)>*>(c));delete static_cast<std::function<void(uint64_t)>*>(c);
  assert(s==0&&id&&!otr);f(id);
 },c)==0);
}
static void otr(std::function<void(uint64_t)> done) {
 auto* c=new std::function<void(uint64_t)>(std::move(done));
 assert(ReArcProfileCreateOffTheRecord(profiles[0],[](void* c,ReArcStatus s,uint64_t id,bool otr){
  auto f=std::move(*static_cast<std::function<void(uint64_t)>*>(c));delete static_cast<std::function<void(uint64_t)>*>(c);
  assert(s==0&&id&&otr);f(id);
 },c)==0);
}
static void evaluate(int i,const char* js,const char* expected,Action done,uint32_t world=1,const char* boost=nullptr) {
 struct Context {std::string expected;Action done;};
 auto* c=new Context{expected,std::move(done)};
 assert(ReArcTabEvaluateScript(tabs[i],js,world,boost,10000,[](void* ptr,ReArcStatus s,uint64_t id,uint64_t gen,const char* json,const char* error){
  auto* c=static_cast<Context*>(ptr);fprintf(stderr,"PROFILE EVAL tab=%llu status=%d json=%s expected=%s error=%s\n",id,s,json?json:"null",c->expected.c_str(),error?error:"");
  assert(s==0&&gen&&json&&json==c->expected);auto f=std::move(c->done);delete c;f();
 },c)==0);
}
static void create(int i,Action done) {
 assert(ReArcTabCreate(profiles[i],i+1,nullptr,&tabs[i])==0);
 identities[tabs[i]]=profiles[i];loaded[tabs[i]]=std::move(done);
 if(i==0) {
  ReArcScriptScope scope{"127.0.0.1","/test",false,1};
  ReArcScript script{"private-plan",&scope,1,0,"globalThis.profileSecret=42;",""};
  assert(ReArcTabSetScripts(tabs[i],&script,1,[](void* ptr,ReArcStatus s,bool c){
   assert(s==0&&!c);assert(ReArcTabNavigate(*static_cast<uint64_t*>(ptr),url.c_str(),0)==0);
  },&tabs[i])==0);
 } else assert(ReArcTabNavigate(tabs[i],url.c_str(),0)==0);
}
static void profile_close(uint64_t id,Action done) {
 auto* c=new Action(std::move(done));
 assert(ReArcProfileClose(id,true,[](void* ptr,ReArcStatus s,bool cancelled){
  assert(s==0&&!cancelled);auto f=std::move(*static_cast<Action*>(ptr));delete static_cast<Action*>(ptr);f();
 },c)==0);
 uint64_t t=42;assert(ReArcTabCreate(id,1,nullptr,&t)==REARC_BUSY&&t==0);
 assert(ReArcEngineShutdown(true,[](void*,ReArcStatus,bool){assert(false);},nullptr)==REARC_BUSY);
}
static void shutdown_done(void*,ReArcStatus s,bool c) {assert(s==0&&!c&&pending_cancelled);stopped=true;puts("PROFILES runtime PASS");}
static void finish() {
 // Accepted async initialization is cancelled once; no callback after shutdown.
 assert(ReArcProfileOpen("pending-shutdown",[](void*,ReArcStatus s,uint64_t id,bool){assert(s==REARC_CANCELLED&&!id&&!pending_cancelled);pending_cancelled=true;},nullptr)==0);
 assert(ReArcEngineShutdown(true,shutdown_done,nullptr)==0);
}
static void reopen() {
 old_a=profiles[0];profile_close(old_a,[]{
  assert(closed.contains(tabs[0]));
  if(!second){assert(popup&&closed.contains(popup)&&invalidated.contains(tabs[0]));ReArcViewRelease(lease.native_view);}
  open("A",[](uint64_t id){
   assert(id!=old_a);profiles[0]=id;create(0,[]{
    evaluate(0,"[document.cookie,localStorage.getItem('space')]","[\"space=A\",\"A\"]",finish);
   });
  });
 });
}
static void veto_and_reopen() {
 if(second){reopen();return;}
 // A genuine AppKit input both adopts a popup and activates beforeunload.
 assert(ReArcViewAttach(tabs[0],1,400,300,1,&lease)==0);
 [window.contentView addSubview:(__bridge NSView*)lease.native_view];
 assert(ReArcViewSetVisible(tabs[0],lease.attachment_id,true)==0);
 popup_ready=[]{
  evaluate(0,"window.onbeforeunload=()=>true;navigator.userActivation.hasBeenActive","true",[]{
   assert(ReArcProfileClose(profiles[0],false,[](void*,ReArcStatus s,bool cancelled){
    assert(s==0&&cancelled&&!closed.contains(tabs[0]));
    assert(ReArcTabRefreshState(tabs[0])==0);puts("profile veto restored availability PASS");
    reopen();
   },nullptr)==0);
  });
 };
 evaluate(0,"document.body.innerHTML='<a href=\"/test\" target=\"_blank\" style=\"display:block;width:300px;height:100px\">open</a>';true","true",[]{
  assert(ReArcTabCaptureSnapshot(tabs[0],0,[](void*,ReArcStatus status,uint64_t,uint64_t,uint8_t* png,size_t){
  assert(status==0);ReArcBufferFree(png);
  NSView* v=(__bridge NSView*)lease.native_view;
  NSPoint point=[v convertPoint:NSMakePoint(30,270) toView:nil];
  for(NSEventType type : {NSEventTypeLeftMouseDown,NSEventTypeLeftMouseUp}) {
   NSEvent* e=[NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
   NSView* hit=[window.contentView hitTest:point];fprintf(stderr,"PROFILE CLICK hit=%s point=%g,%g\n",NSStringFromClass(hit.class).UTF8String,point.x,point.y);if(type==NSEventTypeLeftMouseDown)[hit mouseDown:e];else[hit mouseUp:e];
  }
  },nullptr)==0);
 });
}
static void close_children() {
 profile_close(profiles[2],[]{profile_close(profiles[3],veto_and_reopen);});
}
static void extras(Action done) {
 auto test=[done=std::move(done)]{
  for(int i=0;i<4;++i)for(int j=0;j<4;++j)if(i!=j){
   uint8_t* data;size_t size;assert(ReArcFaviconGet(tabs[j],icons.at(tabs[i]).c_str(),&data,&size)==REARC_NOT_FOUND);
  }
  evaluate(0,"globalThis.profileSecret","42",[done]{
   evaluate(1,"typeof profileSecret","\"undefined\"",done,0,"private-plan");
  },0,"private-plan");
 };
 bool ready=true;for(auto t:tabs)ready &= icons.contains(t);
 if(ready)test();else icons_ready=std::move(test);
}
static void isolation_storage() {
 const char* empty="[\"\",null]";
 if(second) {
  evaluate(0,"[document.cookie,localStorage.getItem('space')]","[\"space=A\",\"A\"]",[]{
   evaluate(1,"[document.cookie,localStorage.getItem('space')]","[\"space=B\",\"B\"]",[]{
    evaluate(2,"[document.cookie,localStorage.getItem('space')]","[\"\",null]",[]{
     evaluate(3,"[document.cookie,localStorage.getItem('space')]","[\"\",null]",close_children);
    });
   });
  });return;
 }
 evaluate(0,"document.cookie='space=A;max-age=86400;path=/';localStorage.setItem('space','A');[document.cookie,localStorage.getItem('space')]","[\"space=A\",\"A\"]",[empty]{
 evaluate(1,"[document.cookie,localStorage.getItem('space')]",empty,[empty]{
 evaluate(2,"[document.cookie,localStorage.getItem('space')]",empty,[empty]{
 evaluate(3,"[document.cookie,localStorage.getItem('space')]",empty,[]{
 evaluate(1,"document.cookie='space=B;max-age=86400;path=/';localStorage.setItem('space','B');true","true",[]{
 evaluate(2,"document.cookie='private=secret;max-age=86400;path=/';localStorage.setItem('space','PRIVATE-ONLY-W14');[document.cookie,localStorage.getItem('space')]","[\"private=secret\",\"PRIVATE-ONLY-W14\"]",[]{
 evaluate(3,"[document.cookie,localStorage.getItem('space')]","[\"\",null]",[]{
  // Favicon refs cannot be retrieved across profile/tab caches.
  uint8_t* bytes;size_t size;assert(ReArcFaviconGet(tabs[1],"not-a-ref",&bytes,&size)==REARC_NOT_FOUND);
  assert(ReArcProfileClose(profiles[0],true,[](void*,ReArcStatus,bool){assert(false);},nullptr)==REARC_BUSY);
  window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,400,300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  assert(ReArcWindowRegister(1,(__bridge void*)window)==0);
  assert(ReArcViewAttach(tabs[2],1,400,300,1,&lease)==0);
  [window.contentView addSubview:(__bridge NSView*)lease.native_view];[window makeKeyAndOrderFront:nil];
  assert(ReArcViewSetVisible(tabs[2],lease.attachment_id,true)==0);
  assert(ReArcTabEvaluateScript(tabs[2],"new Promise(()=>{})",0,nullptr,3000,[](void*,ReArcStatus s,uint64_t,uint64_t,const char*,const char*){assert(s==REARC_CANCELLED);eval_cancelled=true;},nullptr)==0);
  uint64_t old=profiles[2];reentrant_close=true;
  assert(ReArcTabClose(tabs[2],true,[](void*,ReArcStatus s,bool cancelled){
   assert(s==0&&!cancelled&&reentrant_close);reentrant_close=false;
   uint64_t old=profiles[2];profile_close(old,[old]{
   assert(eval_cancelled&&closed.contains(tabs[2])&&invalidated.contains(tabs[2]));
   assert([(__bridge NSView*)lease.native_view subviews].count==0);ReArcViewRelease(lease.native_view);
   otr([old](uint64_t id){assert(id!=old);profiles[2]=id;create(2,[]{
    evaluate(2,"[document.cookie,localStorage.getItem('space')]","[\"\",null]",close_children);
   });});
  });
  },nullptr)==0);
 });});});});});});});
}
static void isolation(){extras(isolation_storage);}
static void event(void*,const ReArcTabEvent* e) {
 if(e->kind==0||e->kind==2||(e->kind==1&&(e->changes&2)))fprintf(stderr,"PROFILE EVENT kind=%u tab=%llu title=%s\n",e->kind,e->tab_id,e->title);
 if(e->kind==0&&e->disposition){
  assert((!e->opener_tab_id||e->opener_tab_id==tabs[0])&&e->profile_id==profiles[0]);popup=e->tab_id;identities[popup]=e->profile_id;
  loaded[popup]=[]{assert(popup_ready);puts("adopted popup profile PASS");auto f=std::move(popup_ready);f();};
 }
 assert(identities.at(e->tab_id)==e->profile_id);
 if(e->kind==2)closed.insert(e->tab_id);
 if(e->kind==1&&(e->changes&2)&&std::string(e->title).starts_with("probe:")) {
  auto it=loaded.find(e->tab_id);if(it!=loaded.end()){auto f=std::move(it->second);loaded.erase(it);f();}
 }
}
static void service(void*,const ReArcServiceEvent* e){
 assert(identities.at(e->tab_id)==e->profile_id);assert(!closed.contains(e->tab_id));
 if(e->kind==0&&e->icon_ref&&*e->icon_ref){
  fprintf(stderr,"PROFILE ICON tab=%llu ref=%s\n",e->tab_id,e->icon_ref);
  icons[e->tab_id]=e->icon_ref;
  bool ready=true;for(auto t:tabs)ready &= icons.contains(t);
  if(ready&&icons_ready){auto f=std::move(icons_ready);icons_ready=nullptr;f();}
 }
}
static void ready(void*,uint64_t def) {
 assert(ReArcEngineHasFeature("profiles")&&ReArcEngineHasFeature("profile_off_the_record"));
 assert(ReArcProfileClose(def,true,[](void*,ReArcStatus,bool){assert(false);},nullptr)==REARC_INVALID_STATE);
 assert(ReArcProfileOpen("../bad",[](void*,ReArcStatus,uint64_t,bool){assert(false);},nullptr)==REARC_INVALID_ARGUMENT);
 open("A",[](uint64_t id){profiles[0]=id;});
 open("A",[](uint64_t id){assert(profiles[0]==id);open("a",[](uint64_t id){profiles[1]=id;assert(id!=profiles[0]);
  otr([](uint64_t id){profiles[2]=id;otr([](uint64_t id){profiles[3]=id;assert(id!=profiles[2]);
   create(0,[]{create(1,[]{create(2,[]{create(3,isolation);});});});
  });});
 });});
}
int main(int argc,const char** argv){@autoreleasepool{
 setbuf(stdout,nullptr);second=getenv("REARC_PROFILE_SECOND");url="http://127.0.0.1:"+std::string(getenv("REARC_TEST_PORT"))+"/test";
 ReArcCallbacks c{ready,event,[](void*,const ReArcViewEvent* e){assert(identities.at(e->tab_id)==e->profile_id);invalidated.insert(e->tab_id);
 if(reentrant_close){assert(ReArcProfileClose(e->profile_id,true,[](void*,ReArcStatus,bool){assert(false);},nullptr)==REARC_BUSY);puts("reentrant profile teardown guard PASS");}
 },nullptr};
 ReArcEngineSetServiceCallback(service,nullptr);assert(ReArcEngineConfigure(1,&c,nullptr)==0);
 int r=ReArcEngineRun(argc,argv);assert(r==0&&stopped);return r;
}}
