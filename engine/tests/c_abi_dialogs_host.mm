#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <string>
static uint64_t tab, pending;
static NSWindow* window;
static ReArcAttachment lease{};
static int step, requests, cancels;
static bool stopped, clicked, installed, cancelled_eval;
static void eval(const char* source, ReArcScriptCallback2 cb) {
 assert(ReArcTabEvaluateScript2(tab,source,1,nullptr,10000,cb,nullptr)==REARC_OK);
}
static void finish(void*,ReArcStatus s,bool c){
 assert(s==REARC_OK&&!c&&requests==7&&cancels==2&&cancelled_eval);
 ReArcViewRelease(lease.native_view);
 assert(ReArcEngineShutdown(true,[](void*,ReArcStatus s,bool c){assert(s==0&&!c);stopped=true;puts("DIALOG alert/confirm/prompt/beforeunload + navigation/close cancellation PASS");},nullptr)==0);
}
static void dialog(void*,const ReArcJavaScriptDialogEvent* e){
 assert(e->tab_id==tab&&e->request_id&&e->content_generation&&std::string(e->origin)=="null");
 printf("DIALOG step=%d phase=%u kind=%u id=%llu\n",step,e->phase,e->kind,e->request_id);
 if(e->phase){++cancels;assert(e->request_id==pending);assert(ReArcJavaScriptDialogRespond(pending,true,"")==REARC_NOT_FOUND);return;}
 ++requests;
 switch(step){
 case 0: assert(e->kind==0&&std::string(e->message)=="hello");break;
 case 1: assert(e->kind==1);break;
 case 2: assert(e->kind==2&&std::string(e->default_text)=="seed");break;
 case 3: assert(e->kind==0);pending=e->request_id;step=4;
   assert(ReArcTabNavigate(tab,"data:text/html,<title>ready</title><body style='margin:0;height:100vh' onclick=\"document.title='clicked'\">click",0)==0);return;
 case 5: assert(e->kind==3);break;
 case 6: assert(e->kind==3);break;
 case 7: assert(e->kind==0);pending=e->request_id;step=8;assert(ReArcTabClose(tab,true,finish,nullptr)==0);return;
 default: assert(false);
 }
 assert(ReArcJavaScriptDialogRespond(e->request_id,true,"\xff")==REARC_INVALID_ARGUMENT);
 assert(ReArcJavaScriptDialogRespond(e->request_id,step!=1&&step!=5,step==2?"answer":nullptr)==0);
 assert(ReArcJavaScriptDialogRespond(e->request_id,true,"")==REARC_NOT_FOUND);
}
static void next(void*,const ReArcScriptResult* r){
 assert(r->status==0);
 if(step==0){assert(std::string(r->json)=="1");step=1;eval("confirm('confirm')",next);}
 else if(step==1){assert(std::string(r->json)=="false");step=2;eval("prompt('prompt','seed')",next);}
 else if(step==2){assert(std::string(r->json)=="\"answer\"");step=3;eval("alert('navigate')",[](void*,const ReArcScriptResult* r){assert(r->status==REARC_CANCELLED);cancelled_eval=true;});}
}
static void click(void*,ReArcStatus s,uint64_t,uint64_t,uint8_t* png,size_t){
 assert(s==0);ReArcBufferFree(png);
 NSPoint point=[(__bridge NSView*)lease.native_view convertPoint:NSMakePoint(30,270) toView:nil];
 for(auto type:{NSEventTypeLeftMouseDown,NSEventTypeLeftMouseUp}){
 NSEvent* e=[NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
 NSView* hit=[window.contentView hitTest:point];if(type==NSEventTypeLeftMouseDown)[hit mouseDown:e];else[hit mouseUp:e];}
}
static void event(void*,const ReArcTabEvent* e){
 printf("TAB step=%d kind=%u title=%s url=%s loading=%d\n",step,e->kind,e->title?e->title:"",e->url?e->url:"",e->is_loading);
 if(e->tab_id!=tab||e->kind!=1||!(e->changes&2))return;
 std::string title=e->title;
 if(step==0&&title=="start")eval("alert('hello');1",next);
 if(step==4&&title=="ready"&&!clicked){clicked=true;assert(ReArcTabCaptureSnapshot(tab,0,click,nullptr)==0);}
 if(step==4&&title=="clicked"&&!installed){installed=true;eval("window.onbeforeunload=()=>true;navigator.userActivation.hasBeenActive",[](void*,const ReArcScriptResult* r){
 assert(r->status==0&&std::string(r->json)=="true");step=5;
 assert(ReArcTabClose(tab,false,[](void*,ReArcStatus s,bool c){assert(s==0&&c);step=6;
 assert(ReArcTabNavigate(tab,"data:text/html,<title>after-unload</title>",0)==0);},nullptr)==0);});}
 if(step==6&&title=="after-unload"){step=7;eval("alert('close')",[](void*,const ReArcScriptResult* r){assert(r->status==REARC_CANCELLED);});}
}
static void ready(void*,uint64_t p){
 assert(ReArcEngineABIMinorVersion()>=18&&ReArcEngineHasFeature("javascript_dialogs"));
 ReArcEngineSetJavaScriptDialogCallback(dialog,nullptr);
 assert(ReArcJavaScriptDialogRespond(999,true,"")==REARC_NOT_FOUND);
 assert(ReArcTabCreate(p,1,"data:text/html,<title>start</title>",&tab)==0);
 window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,400,300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
 assert(ReArcWindowRegister(1,(__bridge void*)window)==0);
 assert(ReArcViewAttach(tab,1,400,300,1,&lease)==0);[window.contentView addSubview:(__bridge NSView*)lease.native_view];[window makeKeyAndOrderFront:nil];
 assert(ReArcViewSetVisible(tab,lease.attachment_id,true)==0);
}
int main(int argc,const char** argv){@autoreleasepool{setbuf(stdout,nullptr);ReArcCallbacks c{ready,event,nullptr,nullptr};assert(ReArcEngineConfigure(1,&c,nullptr)==0);int r=ReArcEngineRun(argc,argv);assert(r==0&&stopped);return r;}}
