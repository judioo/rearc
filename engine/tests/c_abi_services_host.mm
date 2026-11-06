#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <string>
static uint64_t tab;
static NSWindow* window;
static ReArcAttachment attachment;
static bool stopped, muted, security, favicon, viewport, fullpage, peek;
static bool captured, closing, removed, plan_done;
static int port;
static void shutdown_done(void*, ReArcStatus status, bool cancelled) {
 assert(status==REARC_OK&&!cancelled);stopped=true;
 assert(muted&&security&&favicon&&viewport&&fullpage&&peek);
 puts("SERVICES runtime PASS");
}
static void close_done(void*, ReArcStatus s,bool c) {
 assert(s==REARC_OK&&!c);ReArcViewRelease(attachment.native_view);
 assert(ReArcEngineShutdown(true,shutdown_done,nullptr)==REARC_OK);
}
static void cancelled_snapshot(void*,ReArcStatus status,uint64_t id,uint64_t gen,uint8_t* data,size_t size) {
 assert(status==REARC_CANCELLED&&id==tab&&gen&&!data&&!size);
 puts("snapshot navigation cancellation PASS");
 assert(ReArcTabClose(tab,true,close_done,nullptr)==REARC_OK);
}
static void removed_ready() {
 if(!removed||!plan_done)return;
 removed=false;
 assert(ReArcTabCaptureSnapshot(tab,0,cancelled_snapshot,nullptr)==REARC_OK);
 assert(ReArcTabNavigate(tab,"about:blank",0)==REARC_OK);
}
static void removed_plan(void*,ReArcStatus status,bool cancelled) {
 assert(status==REARC_OK&&!cancelled);plan_done=true;removed_ready();
}
static void finish() {
 if(peek&&fullpage&&favicon&&!closing){closing=true;assert(ReArcTabSetScripts(tab,nullptr,0,removed_plan,nullptr)==REARC_OK);}
}
static void dump(NSView* v,int depth) {
 fprintf(stderr,"%*s%s frame=%s hidden=%d\n",depth,"",NSStringFromClass(v.class).UTF8String,NSStringFromRect(v.frame).UTF8String,v.hidden);
 for(NSView* child in v.subviews)dump(child,depth+1);
}
static void clicked() {
 NSView* view=(__bridge NSView*)attachment.native_view;
 dump(view,0);
 NSPoint point=[view convertPoint:NSMakePoint(30,570) toView:nil];
 for(NSEventType type : {NSEventTypeLeftMouseDown,NSEventTypeLeftMouseUp}) {
  NSEvent* event=[NSEvent mouseEventWithType:type location:point
   modifierFlags:NSEventModifierFlagShift timestamp:NSProcessInfo.processInfo.systemUptime
   windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
  NSView* hit=[window.contentView hitTest:point];
  fprintf(stderr,"click hit=%s point=%g,%g\n",NSStringFromClass(hit.class).UTF8String,point.x,point.y);
  if(type==NSEventTypeLeftMouseDown)[hit mouseDown:event];else [hit mouseUp:event];
 }
}
static void snapshot(void* context,ReArcStatus status,uint64_t id,uint64_t gen,uint8_t* data,size_t size) {
 fprintf(stderr,"snapshot scope=%ld status=%d bytes=%zu\n",(long)context,status,size);
 assert(status==REARC_OK&&id==tab&&gen&&size>24&&data[0]==0x89);
 uint32_t height=(data[20]<<24)|(data[21]<<16)|(data[22]<<8)|data[23];
 if(context){assert(height>=2200);fullpage=true;ReArcBufferFree(data);clicked();finish();}
 else {assert(height>0&&height<2200);viewport=true;ReArcBufferFree(data);
  assert(ReArcTabCaptureSnapshot(tab,1,snapshot,(void*)1)==REARC_OK);}
}
static void service(void*,const ReArcServiceEvent* e) {
 assert(e->profile_id&&e->content_generation);
 if(e->kind==1){
  assert(e->has_metadata&&e->title&&e->artist&&e->album);
  if(e->muted)muted=true;
 }
 if(e->kind==2)security=true;
 if(e->kind==0&&e->icon_ref&&e->icon_ref[0]){
  uint8_t* data;size_t size;assert(ReArcFaviconGet(tab,e->icon_ref,&data,&size)==REARC_OK);
  assert(size>8&&data[0]==0x89);ReArcBufferFree(data);favicon=true;puts("favicon PASS");
 }
 if(e->kind==3){fprintf(stderr,"peek %s\n",e->href);assert(std::string(e->href)=="https://example.com/peek");peek=true;}
 finish();
}
static void tab_event(void*,const ReArcTabEvent* e) {
 if(e->kind==1&&(e->changes&2)&&std::string(e->title)=="removed:0") {
  removed=true;puts("CSS replacement/pageshow PASS");removed_ready();
 }
 if(e->kind==1&&(e->changes&2)&&std::string(e->title).starts_with("probe:")) {
  fprintf(stderr,"title %s\n",e->title);
  assert(std::string(e->title)=="probe:yes:yes:true:rgb(1, 2, 3)");
  if(!captured){captured=true;assert(ReArcTabCaptureSnapshot(tab,0,snapshot,nullptr)==REARC_OK);}
 }
}
static void enabled(void*,ReArcStatus status,bool c) {
 fprintf(stderr,"peek enabled %d\n",status);assert(status==REARC_OK&&!c);
 std::string url="http://127.0.0.1:"+std::to_string(port)+"/test";
 assert(ReArcTabNavigate(tab,url.c_str(),0)==REARC_OK);
}
static void installed(void*,ReArcStatus status,bool c) {
 fprintf(stderr,"scripts installed %d\n",status);assert(status==REARC_OK&&!c);
 assert(ReArcTabSetLinkPeek(tab,true,enabled,nullptr)==REARC_OK);
}
static void ready(void*,uint64_t profile) {
 assert(ReArcTabCreate(profile,1,nullptr,&tab)==REARC_OK);
 assert(ReArcTabSetMuted(tab,true)==REARC_OK);
 assert(ReArcTabSetPictureInPicture(tab,true)==REARC_UNSUPPORTED);
 assert(ReArcTabMediaAction(tab,3)==REARC_INVALID_STATE);
 assert(ReArcTabMediaAction(tab,5)==REARC_OK);
 window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,800,600)
 styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
 assert(ReArcWindowRegister(1,(__bridge void*)window)==REARC_OK);
 assert(ReArcViewAttach(tab,1,800,600,1,&attachment)==REARC_OK);
 [window.contentView addSubview:(__bridge NSView*)attachment.native_view];[window makeKeyAndOrderFront:nil];
 assert(ReArcViewSetVisible(tab,attachment.attachment_id,true)==REARC_OK);
 ReArcScriptScope scopes[]={{"127.0.0.1","/test",false,1},{"127.0.0.1","/test",false,1}};
 ReArcScript entries[]={
  {"start",scopes,2,0,"globalThis.rearcSecret='isolated';globalThis.rearcRuns=(globalThis.rearcRuns||0)+1;document.addEventListener('DOMContentLoaded',()=>document.documentElement.dataset.start=globalThis.rearcRuns===1?'yes':'duplicate');","body{background:rgb(1,2,3)}"},
  {"end",scopes,1,1,"document.documentElement.dataset.end='yes';",""}
 };
 assert(ReArcTabSetScripts(tab,entries,2,installed,nullptr)==REARC_OK);
 assert(ReArcTabSetScripts(tab,entries,2,installed,nullptr)==REARC_BUSY);
}
int main(int argc,const char** argv){@autoreleasepool{
 setbuf(stdout,nullptr);port=atoi(getenv("REARC_TEST_PORT"));
 ReArcCallbacks callbacks{ready,tab_event,nullptr,nullptr};
 ReArcEngineSetServiceCallback(service,nullptr);
 assert(ReArcEngineConfigure(1,&callbacks,nullptr)==REARC_OK);
 int code=ReArcEngineRun(argc,argv);assert(stopped&&code==0);return code;
}}
