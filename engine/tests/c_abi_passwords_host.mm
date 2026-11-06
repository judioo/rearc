#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <string>
#include "c_abi_test_devtools.h"
static uint64_t tab, profile;
static NSWindow* window;
static ReArcAttachment lease{};
static std::string base;
static int step, offers, cancels;
static bool stopped, loaded, prepared;
static std::string committed_url;
static void navigate_login(){loaded=false;assert(ReArcTabNavigate(tab,(base+"/login").c_str(),0)==0);}
static void later(){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{navigate_login();});}
static void click(void*,ReArcStatus s,uint64_t,uint64_t,uint8_t* png,size_t){assert(s==0);ReArcBufferFree(png);NSPoint point=[(__bridge NSView*)lease.native_view convertPoint:NSMakePoint(30,50) toView:nil];for(auto type:{NSEventTypeLeftMouseDown,NSEventTypeLeftMouseUp}){NSEvent* e=[NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];NSView* hit=[window.contentView hitTest:point];if(type==NSEventTypeLeftMouseDown)[hit mouseDown:e];else[hit mouseUp:e];}}
static void type_input(const char* selector,std::string text,std::function<void()> done){
 NSString* expression=[NSString stringWithFormat:@"document.querySelector('%s').focus()",selector];
 test_cdp::command(@"Runtime.evaluate",@{@"expression":expression},[text,done]{
  test_cdp::command(@"Input.dispatchKeyEvent",@{@"type":@"keyDown",@"key":@"a",@"code":@"KeyA",@"modifiers":@4,@"commands":@[@"selectAll"]},[text,done]{
   test_cdp::command(@"Input.dispatchKeyEvent",@{@"type":@"keyUp",@"key":@"a",@"code":@"KeyA",@"modifiers":@0},[text,done]{
    test_cdp::command(@"Input.insertText",@{@"text":[NSString stringWithUTF8String:text.c_str()]},done);
   });
  });
 });
}
static void submit(){
 test_cdp::focus(base+"/login",[]{
  std::string u=step<2?"wave18c-saved":"wave18c-other-"+std::to_string(step);
  type_input("#u",u,[]{type_input("#p","password-"+std::to_string(step),[]{assert(ReArcTabCaptureSnapshot(tab,0,click,nullptr)==0);});});
 });
}
static void attach(){assert(ReArcViewAttach(tab,1,400,300,1,&lease)==0);[window.contentView addSubview:(__bridge NSView*)lease.native_view];assert(ReArcViewSetVisible(tab,lease.attachment_id,true)==0);}
static void password(void*,const ReArcPasswordPromptEvent* e){printf("PASSWORD step=%d phase=%u update=%d username=%s origin=%s\n",step,e->phase,e->update,e->username,e->origin);assert(e->tab_id==tab&&std::string(e->origin)==base);
 if(e->phase){++cancels;assert(ReArcPasswordPromptRespond(e->request_id,0)==REARC_NOT_FOUND);return;}
 ++offers;assert(e->update==(step==1));assert(std::string(e->username)==(step<2?"wave18c-saved":"wave18c-other-"+std::to_string(step)));
 assert(ReArcPasswordPromptRespond(e->request_id,9)==REARC_INVALID_ARGUMENT);
 if(step==3){step=4;loaded=false;assert(ReArcTabNavigate(tab,(base+"/visit-a").c_str(),0)==0);return;}
 if(step==4){assert(ReArcTabClose(tab,true,[](void*,ReArcStatus s,bool c){assert(s==0&&!c);ReArcViewRelease(lease.native_view);step=5;loaded=false;assert(ReArcTabCreate(profile,1,(base+"/login").c_str(),&tab)==0);attach();},nullptr)==0);return;}
 assert(ReArcPasswordPromptRespond(e->request_id,step<2?0:step==2?2:1)==0);assert(ReArcPasswordPromptRespond(e->request_id,0)==REARC_NOT_FOUND);
 if(step==5){assert(offers==6&&cancels==2);assert(ReArcEngineShutdown(true,[](void*,ReArcStatus s,bool c){assert(s==0&&!c);ReArcViewRelease(lease.native_view);stopped=true;puts("PASSWORD save/update/dismiss/never + navigation/close cancellation PASS");},nullptr)==0);test_cdp::close_browser();return;}
 ++step;later();
}
static void event(void*,const ReArcTabEvent* e){
 if(e->tab_id!=tab)return;
 if(e->kind==3&&e->is_main_frame&&!e->is_same_document){committed_url=e->url;prepared=false;}
 if(e->kind==1&&(e->changes&2))printf("TITLE step=%d %s\n",step,e->title);
 if(e->kind==1&&(e->changes&4)&&!e->is_loading&&!prepared){
  prepared=true;
  if(committed_url==base+"/login")dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),dispatch_get_main_queue(),^{submit();});
  else if(step==4&&committed_url==base+"/visit-a")later();
 }
}
static void ready(void*,uint64_t p){profile=p;if(ReArcEngineABIMinorVersion()>=35)assert(ReArcProfileSetPasswordLeakDetection(p,false)==0);// no leak-check request to Google
assert(ReArcEngineABIMinorVersion()>=22&&ReArcEngineHasFeature("password_prompts"));ReArcEngineSetPasswordPromptCallback(password,nullptr);assert(ReArcTabCreate(p,1,(base+"/login").c_str(),&tab)==0);window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,400,300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];assert(ReArcWindowRegister(1,(__bridge void*)window)==0);[window makeKeyAndOrderFront:nil];attach();}
int main(int argc,const char** argv){@autoreleasepool{setbuf(stdout,nullptr);test_cdp::initialize(argc,argv);base="http://127.0.0.1:"+std::string(getenv("REARC_TEST_PORT"));ReArcCallbacks c{ready,event,nullptr,nullptr};assert(ReArcEngineConfigure(1,&c,nullptr)==0);int r=ReArcEngineRun(argc,argv);assert(r==0&&stopped);return r;}}
