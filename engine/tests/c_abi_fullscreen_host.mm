#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <string>
#include "c_abi_test_devtools.h"
// step 0 refused without callback; 1 host exit; 2 escape; 3 page exit;
// 4 hidden; 5 close. Each step enters through a trusted click.
static uint64_t tab, profile;
static NSWindow* window;
static ReArcAttachment lease{};
static std::string base;
static int step, entered, exited;
static bool stopped, started, page_ok, event_ok, exit_seen, eval_done;
static void eval(const std::string& s,ReArcScriptCallback2 cb){auto st=ReArcTabEvaluateScript2(tab,s.c_str(),1,nullptr,10000,cb,nullptr);if(st)printf("EVAL status=%d step=%d %s\n",st,step,s.c_str());assert(st==0);}
static NSPoint point(){return [(__bridge NSView*)lease.native_view convertPoint:NSMakePoint(30,270) toView:nil];}
static void click(void*,ReArcStatus s,uint64_t,uint64_t,uint8_t* png,size_t){assert(s==0);ReArcBufferFree(png);for(auto type:{NSEventTypeLeftMouseDown,NSEventTypeLeftMouseUp}){NSEvent* e=[NSEvent mouseEventWithType:type location:point() modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];NSView* hit=[window.contentView hitTest:point()];if(type==NSEventTypeLeftMouseDown)[hit mouseDown:e];else[hit mouseUp:e];}}
static void install(){
 page_ok=event_ok=false;
 std::string n=std::to_string(step);
 eval("document.title='waiting"+n+"';document.body.innerHTML=`<button style='position:absolute;left:0;top:0;width:400px;height:300px'>fullscreen</button>`;document.querySelector('button').onclick=()=>document.documentElement.requestFullscreen().then(()=>document.title='fs:ok:"+n+"',e=>document.title='fs:denied:"+n+"');true",
  [](void*,const ReArcScriptResult* r){assert(r->status==0);assert(ReArcTabCaptureSnapshot(tab,0,click,nullptr)==0);});
}
static void closed(void*,ReArcStatus s,bool c){assert(s==0&&!c&&entered==5&&exited==5);ReArcViewRelease(lease.native_view);assert(ReArcEngineShutdown(true,[](void*,ReArcStatus s,bool c){assert(s==0&&!c);stopped=true;puts("FULLSCREEN refusal + enter + host/escape/page/hidden/close exits PASS");},nullptr)==0);test_cdp::close_browser();}
static void left(){
 // Page-visible state must agree once the exit has been granted.
 eval("new Promise(r=>{const f=()=>r(document.fullscreenElement===null);document.fullscreenElement?document.addEventListener('fullscreenchange',f,{once:true}):f()})",[](void*,const ReArcScriptResult* r){assert(r->status==0&&std::string(r->json)=="true");bool fs=true;assert(ReArcTabGetFullscreenState(tab,&fs)==0&&!fs);assert(ReArcTabExitFullscreen(tab)==REARC_INVALID_STATE);++step;install();});
}
static void act(){
 if(!page_ok||!event_ok)return;
 page_ok=event_ok=false;
 bool fs=false;assert(ReArcTabGetFullscreenState(tab,&fs)==0&&fs);
 eval("document.fullscreenElement===document.documentElement",[](void*,const ReArcScriptResult* r){assert(r->status==0&&std::string(r->json)=="true");
  if(step==1)assert(ReArcTabExitFullscreen(tab)==0);
  else if(step==2){NSEvent* e=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil characters:@"\x1b" charactersIgnoringModifiers:@"\x1b" isARepeat:NO keyCode:53];[[window.contentView hitTest:point()] keyDown:e];}
  else if(step==3){exit_seen=eval_done=false;eval("document.exitFullscreen().then(()=>true)",[](void*,const ReArcScriptResult* r){assert(r->status==0);eval_done=true;if(exit_seen)left();});}
  else if(step==4)assert(ReArcViewSetVisible(tab,lease.attachment_id,false)==0);
  else if(step==5)assert(ReArcTabClose(tab,true,closed,nullptr)==0);
 });
}
static void fullscreen(void*,const ReArcFullscreenEvent* e){
 printf("FULLSCREEN step=%d phase=%u reason=%u display=%lld gen=%llu\n",step,e->phase,e->reason,e->display_id,e->content_generation);
 assert(e->tab_id==tab&&e->profile_id==profile&&e->content_generation==1&&step>0);
 if(e->phase==0){++entered;event_ok=true;act();return;}
 ++exited;
 static const uint32_t reasons[]={0,1,2,0,4,3};
 assert(e->phase==1&&e->reason==reasons[step]);
 if(step==4)assert(ReArcViewSetVisible(tab,lease.attachment_id,true)==0);
 // One evaluation per tab: step 3 exitFullscreen() may still be open.
 if(step==3){exit_seen=true;if(eval_done)left();}
 else if(step<5)left();
}
static void event(void*,const ReArcTabEvent* e){if(e->tab_id!=tab||e->kind!=1||!(e->changes&2))return;std::string t=e->title;printf("TITLE step=%d %s\n",step,t.c_str());
 if(step==0&&t=="ReArc visit A"&&!started){started=true;test_cdp::focus(base,[]{install();});}
 else if(t=="fs:denied:0"){assert(step==0&&!entered);ReArcEngineSetFullscreenCallback(fullscreen,nullptr);step=1;install();}
 else if(t=="fs:ok:"+std::to_string(step)){page_ok=true;act();}
 else assert(!t.starts_with("fs:"));
}
static void ready(void*,uint64_t p){profile=p;assert(ReArcEngineABIMinorVersion()>=27&&ReArcEngineHasFeature("html_fullscreen"));bool fs=true;assert(ReArcTabGetFullscreenState(424242,&fs)==REARC_TAB_NOT_FOUND&&!fs);assert(ReArcTabExitFullscreen(424242)==REARC_TAB_NOT_FOUND);assert(ReArcTabCreate(p,1,(base+"/visit-a").c_str(),&tab)==0);assert(ReArcTabGetFullscreenState(tab,nullptr)==REARC_INVALID_ARGUMENT);assert(ReArcTabExitFullscreen(tab)==REARC_INVALID_STATE);window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,400,300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];assert(ReArcWindowRegister(1,(__bridge void*)window)==0);assert(ReArcViewAttach(tab,1,400,300,1,&lease)==0);[window.contentView addSubview:(__bridge NSView*)lease.native_view];[window makeKeyAndOrderFront:nil];assert(ReArcViewSetVisible(tab,lease.attachment_id,true)==0);}
int main(int argc,const char** argv){@autoreleasepool{setbuf(stdout,nullptr);test_cdp::initialize(argc,argv);base="http://127.0.0.1:"+std::string(getenv("REARC_TEST_PORT"));ReArcCallbacks c{ready,event,nullptr,nullptr};assert(ReArcEngineConfigure(1,&c,nullptr)==0);int r=ReArcEngineRun(argc,argv);assert(r==0&&stopped);return r;}}
