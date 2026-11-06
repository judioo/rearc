#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <string>
static uint64_t tab;
static NSWindow* window;
static ReArcAttachment lease{};
static std::string base;
static int step, cancels;
static bool image_saved;
static bool stopped, started;
static void eval(const std::string& s,ReArcScriptCallback2 cb){assert(ReArcTabEvaluateScript2(tab,s.c_str(),1,nullptr,10000,cb,nullptr)==0);}
static void click(void*,ReArcStatus s,uint64_t,uint64_t,uint8_t* png,size_t){assert(s==0);ReArcBufferFree(png);NSPoint point=[(__bridge NSView*)lease.native_view convertPoint:NSMakePoint(30,270) toView:nil];for(auto type:{NSEventTypeRightMouseDown,NSEventTypeRightMouseUp}){NSEvent* e=[NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];NSView* hit=[window.contentView hitTest:point];if(type==NSEventTypeRightMouseDown)[hit rightMouseDown:e];else[hit rightMouseUp:e];}}
static void menu(){assert(ReArcTabCaptureSnapshot(tab,0,click,nullptr)==0);}
static void setup(bool input){eval(input?"document.body.innerHTML=`<textarea style='position:absolute;left:0;top:0;width:400px;height:300px'>context text</textarea>`;var i=document.querySelector('textarea');i.focus();i.select();true":"document.body.innerHTML=`<a style='position:absolute;left:0;top:0;width:400px;height:300px' href='/visit-b'>link text</a>`;true",[](void*,const ReArcScriptResult* r){assert(r->status==0);menu();});}
static void image(){eval("document.body.innerHTML=`<img style='position:absolute;left:0;top:0;width:400px;height:300px' src='/favicon.png'>`;new Promise(r=>{var i=document.querySelector('img');if(i.complete)r(true);else i.onload=()=>r(true)})",[](void*,const ReArcScriptResult* r){assert(r->status==0);menu();});}
static void download(void*,const ReArcDownloadEvent* e){if(step==11&&e->kind==2){image_saved=true;menu();}}
static void closed(void*,ReArcStatus s,bool c){assert(s==0&&!c&&cancels==2&&image_saved);ReArcViewRelease(lease.native_view);assert(ReArcEngineShutdown(true,[](void*,ReArcStatus s,bool c){assert(s==0&&!c);stopped=true;puts("CONTEXT payload/copylink/open/edit/back/forward/reload + stale cancellation PASS");},nullptr)==0);}
static void context(void*,const ReArcContextMenuEvent* e){printf("CONTEXT step=%d phase=%u id=%llu editable=%d link=%s selection=%s flags=%u\n",step,e->phase,e->request_id,e->is_editable,e->link_url,e->selection_text,e->edit_flags);assert(e->tab_id==tab&&e->request_id);
 if(e->phase){++cancels;assert(ReArcContextMenuCommand(e->request_id,12)==REARC_NOT_FOUND);return;}
 assert(ReArcContextMenuCommand(e->request_id,99)==REARC_INVALID_ARGUMENT);
 assert(ReArcContextMenuCommand(e->request_id,8)==REARC_UNSUPPORTED);
 uint32_t action=12;
 if(step==0){assert(std::string(e->link_url)==base+"/visit-b"&&!e->is_editable&&e->x>=0&&e->y>=0);action=1;}
 if(step==1)action=0;
 if(step==2)action=9;
 if(step==3)action=10;
 if(step==4)action=11;
 if(step>=5&&step<=8){assert(e->is_editable);action=step==5?2:step==6?4:step==7?3:5;}
 if(step==9||step==10){assert(e->has_image_contents&&e->media_type==1&&std::string(e->src_url)==base+"/favicon.png");action=step==9?7:6;}
 if(step==11){++step;assert(ReArcTabNavigate(tab,(base+"/visit-a").c_str(),0)==0);return;}
 if(step==13){++step;assert(ReArcTabClose(tab,true,closed,nullptr)==0);return;}
 assert(ReArcContextMenuCommand(e->request_id,action)==0);assert(ReArcContextMenuCommand(e->request_id,action)==REARC_NOT_FOUND);
 if(step==0){assert([[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString] != nil);}
 int was=step++;
 if(was==0)menu();
 if(was==9)menu();
 if(was>=5&&was<=8){eval("document.querySelector('textarea').value",[](void*,const ReArcScriptResult* r){assert(r->status==0);if(step==7)assert(std::string(r->json)=="\"\"");else assert(std::string(r->json)=="\"context text\"");if(step==9)image();else menu();});}
}
static void event(void*,const ReArcTabEvent* e){if(e->tab_id!=tab)return;
 if(e->kind==1&&(e->changes&2)&&std::string(e->title)=="ReArc visit A"&&step==0&&!started){started=true;setup(false);}
 if(e->kind==1&&(e->changes&4)&&!e->is_loading){
 if(step>=2&&step<=4)menu();
 else if(step==5)setup(true);
 else if(step==12){step=13;setup(false);}}
}
static void ready(void*,uint64_t p){assert(ReArcEngineABIMinorVersion()>=21&&ReArcEngineHasFeature("context_menu"));ReArcEngineSetContextMenuCallback(context,nullptr);ReArcEngineSetDownloadCallback(download,nullptr);assert(ReArcDownloadSetPolicy(p,getenv("REARC_FILES_DIR"),0)==0);assert(ReArcTabCreate(p,1,(base+"/visit-a").c_str(),&tab)==0);window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,400,300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];assert(ReArcWindowRegister(1,(__bridge void*)window)==0);assert(ReArcViewAttach(tab,1,400,300,1,&lease)==0);[window.contentView addSubview:(__bridge NSView*)lease.native_view];[window makeKeyAndOrderFront:nil];assert(ReArcViewSetVisible(tab,lease.attachment_id,true)==0);}
int main(int argc,const char** argv){@autoreleasepool{setbuf(stdout,nullptr);base="http://127.0.0.1:"+std::string(getenv("REARC_TEST_PORT"));ReArcCallbacks c{ready,event,nullptr,nullptr};assert(ReArcEngineConfigure(1,&c,nullptr)==0);int r=ReArcEngineRun(argc,argv);assert(r==0&&stopped);return r;}}
