#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <string>
#include "c_abi_test_devtools.h"
static uint64_t tab;
static NSWindow* window;
static ReArcAttachment lease{};
static std::string base;
static int step, requests, cancels;
static bool stopped, started;
static void eval(const std::string& s,ReArcScriptCallback2 cb){assert(ReArcTabEvaluateScript2(tab,s.c_str(),1,nullptr,10000,cb,nullptr)==0);}
static void click(void*,ReArcStatus s,uint64_t,uint64_t,uint8_t* png,size_t){assert(s==0);ReArcBufferFree(png);NSPoint point=[(__bridge NSView*)lease.native_view convertPoint:NSMakePoint(30,270) toView:nil];for(auto type:{NSEventTypeLeftMouseDown,NSEventTypeLeftMouseUp}){NSEvent* e=[NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];NSView* hit=[window.contentView hitTest:point];if(type==NSEventTypeLeftMouseDown)[hit mouseDown:e];else[hit mouseUp:e];}}
static void install(){
 std::string action;
 if(step<2)action="Notification.requestPermission().then(x=>document.title='done:'+x)";
 else if(step==2||step==6||step==8)action="navigator.clipboard.readText().then(x=>document.title='done:clipboard',e=>document.title='done:denied')";
 else if(step==3)action="navigator.requestMIDIAccess({sysex:true}).then(x=>document.title='done:midi',e=>document.title='done:denied')";
 else if(step==4)action="navigator.mediaDevices.getUserMedia({audio:true,video:true}).then(s=>{s.getTracks().forEach(t=>t.stop());document.title='done:media'},e=>document.title='done:denied')";
 else if(step==5)action="navigator.geolocation.getCurrentPosition(x=>document.title='done:geo',e=>document.title='done:denied')";
 std::string source="document.title='waiting';document.body.innerHTML=`<button style='position:absolute;left:0;top:0;width:400px;height:300px'>permission</button>`;document.querySelector('button').onclick=()=>{"+action+"};true";
 eval(source,[](void*,const ReArcScriptResult* r){assert(r->status==0);assert(ReArcTabCaptureSnapshot(tab,0,click,nullptr)==0);});
}
static void closed(void*,ReArcStatus s,bool c){assert(s==0&&!c&&requests==8&&cancels==2);ReArcViewRelease(lease.native_view);assert(ReArcEngineShutdown(true,[](void*,ReArcStatus s,bool c){assert(s==0&&!c);stopped=true;puts("PERMISSIONS notifications/clipboard/MIDI/media/geolocation + persistence + cancellation PASS");},nullptr)==0);test_cdp::close_browser();}
static void permission(void*,const ReArcPermissionEvent* e){
 printf("PERMISSION step=%d phase=%u id=%llu types=",step,e->phase,e->request_id);for(size_t i=0;i<e->type_count;++i)printf("%s,",e->types[i]);puts("");
 assert(e->tab_id==tab&&std::string(e->origin)==base+"/"&&std::string(e->embedding_origin)==base+"/");
 if(e->phase){++cancels;assert(ReArcPermissionRespond(e->request_id,0,true)==REARC_NOT_FOUND);return;}
 ++requests;assert(e->type_count==(step==4?2:1));
 if(step==6){step=7;assert(ReArcTabNavigate(tab,(base+"/visit-b").c_str(),0)==0);return;}
 if(step==8){step=9;assert(ReArcTabClose(tab,true,closed,nullptr)==0);return;}
 assert(ReArcPermissionRespond(e->request_id,3,false)==REARC_INVALID_ARGUMENT);
 assert(ReArcPermissionRespond(e->request_id,step<2?0:1,step==1||step==3||step==4)==0);
 assert(ReArcPermissionRespond(e->request_id,0,true)==REARC_NOT_FOUND);
}
static void verify(void*,const ReArcScriptResult* r){assert(r->status==0);printf("PERMISSION query step=%d %s\n",step,r->json);assert(std::string(r->json)==(step==0||step==2||step==5?"\"prompt\"":step==1?"\"granted\"":"\"denied\""));++step;install();}
static void event(void*,const ReArcTabEvent* e){if(e->tab_id!=tab||e->kind!=1||!(e->changes&2))return;std::string t=e->title;printf("TITLE step=%d %s\n",step,t.c_str());
 if(step==0&&t=="ReArc visit A"&&!started){started=true;test_cdp::focus(base,[]{install();});}
 else if(step<6&&t.starts_with("done:")){
 assert(t==(step<2?"done:granted":"done:denied"));
 const char* descriptor=step<2?"{name:'notifications'}":step==2?"{name:'clipboard-read'}":step==3?"{name:'midi',sysex:true}":step==4?"{name:'camera'}":"{name:'geolocation'}";
 eval("navigator.permissions.query("+std::string(descriptor)+").then(x=>x.state)",verify);
 }else if(step==7&&t=="ReArc visit B"){step=8;test_cdp::focus(base,[]{install();});}}
static void ready(void*,uint64_t p){assert(ReArcEngineABIMinorVersion()>=20&&ReArcEngineHasFeature("permission_prompts"));ReArcEngineSetPermissionCallback(permission,nullptr);assert(ReArcTabCreate(p,1,(base+"/visit-a").c_str(),&tab)==0);window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,400,300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];assert(ReArcWindowRegister(1,(__bridge void*)window)==0);assert(ReArcViewAttach(tab,1,400,300,1,&lease)==0);[window.contentView addSubview:(__bridge NSView*)lease.native_view];[window makeKeyAndOrderFront:nil];assert(ReArcViewSetVisible(tab,lease.attachment_id,true)==0);}
int main(int argc,const char** argv){@autoreleasepool{setbuf(stdout,nullptr);test_cdp::initialize(argc,argv);base="http://127.0.0.1:"+std::string(getenv("REARC_TEST_PORT"));ReArcCallbacks c{ready,event,nullptr,nullptr};assert(ReArcEngineConfigure(1,&c,nullptr)==0);int r=ReArcEngineRun(argc,argv);assert(r==0&&stopped);return r;}}
