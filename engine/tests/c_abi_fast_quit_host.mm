#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <chrono>
#include <set>
#include <string>
// tab/090: a non-forced shutdown closes pages that cannot ask "Leave site?"
// together. Mode 0: 60 pages with no handler and 3 with a pagehide handler
// close in under a second. Mode 1: a beforeunload page's Stay (the dialog
// manager answers it with no host handler) keeps every other page open.
static constexpr int kPlain = 60, kPageHide = 3;
static std::set<uint64_t> tabs, plain, loaded, closed;
static uint64_t asking;
static NSWindow* window;
static ReArcAttachment lease{};
static bool stopped, requested, clicked, armed;
static int mode;
static std::chrono::steady_clock::time_point started;
static void done(void*,ReArcStatus s,bool c){
 assert(s==REARC_OK&&!c&&closed==tabs);
 if(lease.native_view)ReArcViewRelease(lease.native_view);
 stopped=true;
 if(mode==0){
  auto ms=std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-started).count();
  printf("FAST QUIT %zu tabs closed in %lld ms\n",tabs.size(),(long long)ms);
  assert(ms<1000);puts("FAST QUIT non-forced shutdown under 1 s PASS");
 }else puts("FAST QUIT forced retry after Stay PASS");
}
static void vetoed(void*,ReArcStatus s,bool c){
 assert(s==REARC_OK&&c);
 for(uint64_t id:plain)assert(!closed.contains(id));
 assert(!closed.contains(asking));
 puts("FAST QUIT Stay closed no other page PASS");
 assert(ReArcEngineShutdown(true,done,nullptr)==REARC_OK);
}
static void shutdown(){
 requested=true;started=std::chrono::steady_clock::now();
 assert(ReArcEngineShutdown(false,mode==0?done:vetoed,nullptr)==REARC_OK);
}
static void installed(void*,const ReArcScriptResult* r){
 assert(r->status==REARC_OK&&std::string(r->json)=="true");
 shutdown();
}
static void snapshot(void*,ReArcStatus s,uint64_t,uint64_t,uint8_t* png,size_t){
 assert(s==REARC_OK);ReArcBufferFree(png);
 NSPoint point=[(__bridge NSView*)lease.native_view convertPoint:NSMakePoint(30,270) toView:nil];
 for(NSEventType type:{NSEventTypeLeftMouseDown,NSEventTypeLeftMouseUp}){
  NSEvent* e=[NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
  NSView* hit=[window.contentView hitTest:point];if(type==NSEventTypeLeftMouseDown)[hit mouseDown:e];else[hit mouseUp:e];
 }
}
static void event(void*,const ReArcTabEvent* e){
 if(e->kind==2){assert(closed.insert(e->tab_id).second);return;}
 if(e->kind!=1||!(e->changes&2)||!tabs.contains(e->tab_id))return;
 std::string title=e->title;
 if(title=="ready")loaded.insert(e->tab_id);
 if(e->tab_id==asking&&title=="clicked"&&!armed){
  armed=true;
  assert(ReArcTabEvaluateScript2(asking,"window.onbeforeunload=()=>true;navigator.userActivation.hasBeenActive",1,nullptr,3000,installed,nullptr)==REARC_OK);
  return;
 }
 if(loaded.size()!=tabs.size())return;
 if(mode==0){if(!requested)shutdown();}
 else if(!clicked){clicked=true;assert(ReArcTabCaptureSnapshot(asking,0,snapshot,nullptr)==REARC_OK);}
}
static uint64_t create(uint64_t profile,const char* url){
 uint64_t id;assert(ReArcTabCreate(profile,1,url,&id)==REARC_OK);tabs.insert(id);return id;
}
static void ready(void*,uint64_t p){
 for(int i=0;i<kPlain;++i)plain.insert(create(p,"data:text/html,<title>ready</title>plain"));
 if(mode==0){
  for(int i=0;i<kPageHide;++i)create(p,"data:text/html,<title>ready</title><script>addEventListener('pagehide',()=>{})</script>pagehide");
  return;
 }
 asking=create(p,"data:text/html,<body style='margin:0;height:100vh' onclick=\"document.title='clicked'\"><title>ready</title>click");
 window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,400,300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
 assert(ReArcWindowRegister(1,(__bridge void*)window)==REARC_OK);
 assert(ReArcViewAttach(asking,1,400,300,1,&lease)==REARC_OK);[window.contentView addSubview:(__bridge NSView*)lease.native_view];[window makeKeyAndOrderFront:nil];
 assert(ReArcViewSetVisible(asking,lease.attachment_id,true)==REARC_OK);
}
int main(int argc,const char** argv){@autoreleasepool{
 if(getenv("REARC_FAST_QUIT_MODE"))mode=atoi(getenv("REARC_FAST_QUIT_MODE"));
 ReArcCallbacks callbacks{ready,event,[](void*,const ReArcViewEvent*){},nullptr};assert(ReArcEngineConfigure(1,&callbacks,nullptr)==REARC_OK);
 int result=ReArcEngineRun(argc,argv);assert(result==0&&stopped);return result;
}}
