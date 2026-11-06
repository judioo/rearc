#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <string>
static uint64_t tab;
static NSWindow* window;
static ReArcAttachment lease{};
static bool stopped,clicked,installed,close_cancelled,closed,invalidated;
static void done(void*,ReArcStatus s,bool c){assert(s==REARC_OK&&!c&&closed&&invalidated&&close_cancelled);ReArcViewRelease(lease.native_view);stopped=true;puts("SHUTDOWN joined veto, resumed service, force retry PASS");}
static void cancelled(void*,ReArcStatus s,bool c){
 assert(s==REARC_OK&&c&&close_cancelled&&!closed&&!invalidated);
 assert(ReArcTabRefreshState(tab)==REARC_OK);
 assert(ReArcEngineShutdown(true,done,nullptr)==REARC_OK);
}
static void installed_handler(void*,const ReArcScriptResult* r){
 assert(r->status==REARC_OK&&std::string(r->json)=="true");
 assert(ReArcTabClose(tab,false,[](void*,ReArcStatus s,bool c){assert(s==REARC_OK&&c);close_cancelled=true;},nullptr)==REARC_OK);
 assert(ReArcEngineShutdown(false,cancelled,nullptr)==REARC_OK);
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
 if(e->kind==2){assert(!closed);closed=true;return;}
 if(e->tab_id!=tab||e->kind!=1||!(e->changes&2))return;
 if(std::string(e->title)=="ready"&&!clicked){clicked=true;assert(ReArcTabCaptureSnapshot(tab,0,snapshot,nullptr)==REARC_OK);}
 if(std::string(e->title)=="clicked"&&!installed){installed=true;assert(ReArcTabEvaluateScript2(tab,"window.onbeforeunload=()=>true;navigator.userActivation.hasBeenActive",1,nullptr,3000,installed_handler,nullptr)==REARC_OK);}
}
static void ready(void*,uint64_t p){
 assert(ReArcTabCreate(p,1,"data:text/html,<body style='margin:0;height:100vh' onclick=\"document.title='clicked'\"><title>ready</title>click",&tab)==REARC_OK);
 window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,400,300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
 assert(ReArcWindowRegister(1,(__bridge void*)window)==REARC_OK);
 assert(ReArcViewAttach(tab,1,400,300,1,&lease)==REARC_OK);[window.contentView addSubview:(__bridge NSView*)lease.native_view];[window makeKeyAndOrderFront:nil];
 assert(ReArcViewSetVisible(tab,lease.attachment_id,true)==REARC_OK);
}
int main(int argc,const char** argv){@autoreleasepool{
 ReArcCallbacks callbacks{ready,event,[](void*,const ReArcViewEvent*){invalidated=true;},nullptr};assert(ReArcEngineConfigure(1,&callbacks,nullptr)==REARC_OK);
 int result=ReArcEngineRun(argc,argv);assert(result==0&&stopped);return result;
}}
