#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <functional>
#include <string>
#include <map>
static uint64_t profile,source_tab,target,last_target,private_tab;
static NSWindow* window;
static ReArcAttachment lease{};
static std::string base;
static int step,requests,withdrawn;
static bool ready_page,stopped,checking;
static std::map<uint64_t,std::string> committed;
static void later(double seconds,std::function<void()> f) {
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(seconds*NSEC_PER_SEC)),dispatch_get_main_queue(),^{f();});
}
static void click_next();
static void finish() {
 assert(requests==8&&withdrawn==1);
 assert(ReArcEngineShutdown(true,[](void*,ReArcStatus status,bool cancelled){
   assert(status==REARC_OK&&!cancelled);ReArcViewRelease(lease.native_view);stopped=true;puts("LINKS PASS");
 },nullptr)==REARC_OK);
}
static void open_request(void*,const ReArcLinkOpenEvent* e) {
 printf("LINKS request step=%d phase=%u disposition=%u url=%s referrer=%s policy=%u\n",step,e->phase,e->disposition,e->url,e->referrer,e->referrer_policy);
 assert(e->profile_id==profile&&e->opener_tab_id==source_tab&&e->content_generation==lease.content_generation);
 if(e->phase){++withdrawn;assert(ReArcLinkOpenRespond(e->request_id,0)==REARC_NOT_FOUND);return;}
 ++requests;assert(e->user_gesture&&std::string(e->url)==base+"/link-result");
 assert(std::string(e->referrer)==(step==6?"":base+"/link-open"));
 const uint32_t expected[]={0,2,1,2,4,5,2,2,2};
 assert(e->disposition==expected[step]);
 assert(ReArcExtensionTabRequestRespond(e->request_id,0)==REARC_NOT_FOUND);
 if(step==7){
   ReArcEngineSetLinkOpenCallback(nullptr,nullptr);
   assert(ReArcLinkOpenRespond(e->request_id,0)==REARC_NOT_FOUND);
   ReArcEngineSetLinkOpenCallback(open_request,nullptr);
   puts("LINKS callback replacement withdraws without delivery PASS");++step;later(.3,click_next);return;
 }
 if(step==8){
   uint64_t id=e->request_id;
   assert(ReArcTabClose(source_tab,true,[](void* ctx,ReArcStatus status,bool cancelled){
     assert(status==REARC_OK&&!cancelled);
     assert(ReArcLinkOpenRespond((uint64_t)(uintptr_t)ctx,0)==REARC_NOT_FOUND);
     puts("LINKS pending source close cancels; stale response rejected PASS");finish();
   },(void*)(uintptr_t)id)==REARC_OK);return;
 }
 assert(ReArcLinkOpenRespond(e->request_id,source_tab)==REARC_INVALID_STATE);
 assert(ReArcLinkOpenRespond(e->request_id,private_tab)==REARC_INVALID_ARGUMENT);
 if(last_target) assert(ReArcLinkOpenRespond(e->request_id,last_target)==REARC_INVALID_STATE);
 assert(ReArcTabCreate(profile,1,"about:blank",&target)==REARC_OK);
 bool active=e->disposition!=2;
 assert(ReArcTabSetExtensionWindow(target,e->disposition==4?3:1,active,true)==REARC_OK);
 assert(ReArcLinkOpenRespond(e->request_id,target)==REARC_OK);
 assert(ReArcLinkOpenRespond(e->request_id,target)==REARC_NOT_FOUND);
}
static void snapshot(void*,ReArcStatus status,uint64_t,uint64_t,uint8_t* png,size_t) {
 assert(status==REARC_OK);ReArcBufferFree(png);
 bool middle=step==3;
 NSEventModifierFlags modifiers=step==2?(NSEventModifierFlagCommand|NSEventModifierFlagShift):
   step==4?NSEventModifierFlagShift:step==5?(NSEventModifierFlagCommand|NSEventModifierFlagOption):
   middle?0:NSEventModifierFlagCommand;
 NSPoint point=[(__bridge NSView*)lease.native_view convertPoint:NSMakePoint(80,step==6?510:570) toView:nil];
 NSView* hit=[window.contentView hitTest:point];assert(hit);
 for(int up=0;up<2;++up){
   NSEventType type=middle?(up?NSEventTypeOtherMouseUp:NSEventTypeOtherMouseDown):(up?NSEventTypeLeftMouseUp:NSEventTypeLeftMouseDown);
   NSEvent* event=[NSEvent mouseEventWithType:type location:point modifierFlags:modifiers timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil eventNumber:step*2+up clickCount:1 pressure:up?0:1];
   if(middle){
     // As in Chromium's cocoa_test_event_utils: NSEvent's mouse factory
     // cannot set buttonNumber, so synthesize a center-button CGEvent.
     NSPoint screen=[window convertPointToScreen:point];
     CGPoint location=CGPointMake(screen.x-NSMinX(window.frame),NSHeight(NSScreen.screens.firstObject.frame)-screen.y+NSMinY(window.frame));
     CGEventRef cg=CGEventCreateMouseEvent(nullptr,up?kCGEventOtherMouseUp:kCGEventOtherMouseDown,location,kCGMouseButtonCenter);
     CGEventSetFlags(cg,0);
     CGEventSetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointer,window.windowNumber);
     CGEventSetIntegerValueField(cg,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent,window.windowNumber);
     event=[NSEvent eventWithCGEvent:cg];[event setValue:window forKey:@"_window"];CFRelease(cg);
     assert(event.buttonNumber==2&&fabs(event.locationInWindow.x-point.x)<1&&fabs(event.locationInWindow.y-point.y)<1);
     if(up)[hit otherMouseUp:event];else[hit otherMouseDown:event];
   }
   else if(up)[hit mouseUp:event];else[hit mouseDown:event];
 }
 if(step==0)later(.6,[]{
   assert(requests==0);puts("LINKS no callback refuses modifier open PASS");
   ReArcEngineSetLinkOpenCallback(open_request,nullptr);++step;click_next();
 });
}
static void click_next(){
 checking=false;
 assert(ReArcTabSetExtensionWindow(source_tab,1,true,true)==REARC_OK);
 assert(ReArcTabCaptureSnapshot(source_tab,0,snapshot,nullptr)==REARC_OK);
}
static void event(void*,const ReArcTabEvent* e){
 printf("LINKS event tab=%llu kind=%u loading=%d changes=%u url=%s title=%s\n",e->tab_id,e->kind,e->is_loading,e->changes,e->url,e->title);
 assert(!e->is_crashed);
 if(e->kind==3&&e->is_main_frame&&!e->is_same_document)committed[e->tab_id]=e->url;
 if(e->tab_id==source_tab&&e->kind==1&&(e->changes&2)&&std::string(e->title)=="links-ready"&&!ready_page){
   ready_page=true;later(.3,click_next);
 }
 if(e->tab_id!=target||e->kind!=1||!(e->changes&4)||e->is_loading||checking||committed[target]!=base+"/link-result")return;
 checking=true;
 assert(ReArcTabEvaluateScript(target,"document.referrer+'|'+(window.opener===null)",1,nullptr,10000,[](void*,ReArcStatus status,uint64_t,uint64_t,const char* json,const char* error){
   if(status)printf("LINKS eval error=%s\n",error?error:"");assert(status==REARC_OK);
   std::string expected="\""+(step==6?std::string():base+"/link-open")+"|true\"";
   printf("LINKS target result step=%d %s\n",step,json);assert(std::string(json)==expected);
   assert(ReArcTabEvaluateScript(source_tab,"location.href",1,nullptr,10000,[](void*,ReArcStatus s,uint64_t,uint64_t,const char* value,const char*){
     assert(s==REARC_OK&&std::string(value)=="\""+base+"/link-open\"");
     printf("LINKS native modifier case %d navigation/referrer/source-unchanged PASS\n",step);
     last_target=target;target=0;++step;later(.3,click_next);
   },nullptr)==REARC_OK);
 },nullptr)==REARC_OK);
}
static void ready(void*,uint64_t p){
 profile=p;assert(ReArcEngineABIMinorVersion()>=39&&ReArcEngineHasFeature("link_open_requests"));
 window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,800,600) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
 assert(ReArcWindowRegister(1,(__bridge void*)window)==REARC_OK);[window makeKeyAndOrderFront:nil];
 assert(ReArcProfileCreateOffTheRecord(profile,[](void*,ReArcStatus status,uint64_t private_profile,bool otr){
   assert(status==REARC_OK&&otr);
   assert(ReArcTabCreate(private_profile,2,"about:blank",&private_tab)==REARC_OK);
   assert(ReArcTabSetExtensionWindow(private_tab,2,false,false)==REARC_OK);
   assert(ReArcTabCreate(profile,1,(base+"/link-open").c_str(),&source_tab)==REARC_OK);
   assert(ReArcViewAttach(source_tab,1,800,600,1,&lease)==REARC_OK);[window.contentView addSubview:(__bridge NSView*)lease.native_view];
   assert(ReArcViewSetVisible(source_tab,lease.attachment_id,true)==REARC_OK);
 },nullptr)==REARC_OK);
}
int main(int argc,const char** argv){@autoreleasepool{
 setbuf(stdout,nullptr);base="http://127.0.0.1:"+std::string(getenv("REARC_TEST_PORT"));
 ReArcCallbacks c{ready,event,nullptr,nullptr};assert(ReArcEngineConfigure(1,&c,nullptr)==REARC_OK);
 int result=ReArcEngineRun(argc,argv);assert(result==0&&stopped);return result;
}}
