#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <functional>
#include <string>
static uint64_t profile,tab,last;
static NSWindow* window;
static ReArcAttachment lease{};
static std::string base;
static int stage,requests,retries,withdrawn;
static bool stopped;
static void later(std::function<void()> f){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{f();});}
static void navigate(std::string path){assert(ReArcTabNavigate(tab,(base+path).c_str(),0)==REARC_OK);}
static void finish(){
 assert(requests>=6&&retries==2);
 assert(ReArcEngineShutdown(true,[](void*,ReArcStatus s,bool cancelled){assert(!s&&!cancelled);ReArcViewRelease(lease.native_view);stopped=true;puts("AUTH PASS");},nullptr)==REARC_OK);
}
static void auth(void*,const ReArcHttpAuthEvent* e){
 printf("AUTH phase=%u realm=%s scheme=%s challenger=%s stage=%d\n",e->phase,e->realm,e->scheme,e->challenger,stage);
 assert(e->profile_id==profile&&e->tab_id==tab&&!e->is_proxy);
 if(e->phase){++withdrawn;return;}
 ++requests;last=e->request_id;
 if(stage==1){
   assert(std::string(e->scheme)=="basic");++retries;
   assert(ReArcHttpAuthRespond(last,false,nullptr,"x")==REARC_INVALID_ARGUMENT);
   assert(ReArcHttpAuthRespond(last,false,"rearc",retries==1?"wrong":"local-secret")==REARC_OK);
 }else if(stage==2){
   assert(std::string(e->scheme)=="digest");assert(ReArcHttpAuthRespond(last,false,"rearc","local-secret")==REARC_OK);
 }else if(stage==3){assert(ReArcHttpAuthRespond(last,true,nullptr,nullptr)==REARC_OK);
 }else if(stage==4){
   ReArcEngineSetHttpAuthCallback(nullptr,nullptr);
   assert(ReArcHttpAuthRespond(last,false,"rearc","local-secret")==REARC_NOT_FOUND);
 }else if(stage==5){
   stage=6;
   assert(ReArcTabClose(tab,true,[](void*,ReArcStatus s,bool cancelled){
     assert(!s&&!cancelled);assert(ReArcHttpAuthRespond(last,true,nullptr,nullptr)==REARC_NOT_FOUND);
     puts("AUTH pending close withdrawn, stale reply rejected PASS");finish();
   },nullptr)==REARC_OK);
 }else assert(false);
}
static void event(void*,const ReArcTabEvent* e){
 if(e->tab_id!=tab)return;assert(!e->is_crashed);
 if(e->kind!=1||!(e->changes&2))return;
 std::string title=e->title;printf("AUTH title=%s stage=%d\n",title.c_str(),stage);
 if(stage==0&&title=="auth-denied"){
   stage=1;ReArcEngineSetHttpAuthCallback(auth,nullptr);later([]{navigate("/auth/basic?realm=retry");});
 }else if(stage==1&&title=="auth-ok-retry"){
   stage=2;puts("AUTH Basic wrong credentials then retry accepted PASS");later([]{navigate("/auth/digest?realm=digest");});
 }else if(stage==2&&title=="auth-ok-digest"){
   stage=3;puts("AUTH Digest local server validates credentials PASS");later([]{navigate("/auth/basic?realm=cancel");});
 }else if(stage==3&&title=="auth-denied"){
   stage=4;later([]{navigate("/auth/basic?realm=replace");});
 }else if(stage==4&&title=="auth-denied"){
   stage=5;ReArcEngineSetHttpAuthCallback(auth,nullptr);later([]{navigate("/auth/basic?realm=close");});
 }
}
static void ready(void*,uint64_t p){
 profile=p;assert(ReArcEngineHasFeature("http_auth"));assert(ReArcProfileSetPasswordLeakDetection(profile,false)==REARC_OK);
 window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,800,600) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
 assert(ReArcWindowRegister(1,(__bridge void*)window)==REARC_OK);[window makeKeyAndOrderFront:nil];
 assert(ReArcTabCreate(profile,1,(base+"/auth/basic?realm=none").c_str(),&tab)==REARC_OK);
 assert(ReArcViewAttach(tab,1,800,600,1,&lease)==REARC_OK);[window.contentView addSubview:(__bridge NSView*)lease.native_view];
 assert(ReArcViewSetVisible(tab,lease.attachment_id,true)==REARC_OK);
}
int main(int argc,const char** argv){@autoreleasepool{
 setbuf(stdout,nullptr);base="http://127.0.0.1:"+std::string(getenv("REARC_TEST_PORT"));
 ReArcCallbacks c{ready,event,nullptr,nullptr};assert(ReArcEngineConfigure(1,&c,nullptr)==REARC_OK);
 int r=ReArcEngineRun(argc,argv);assert(!r&&stopped);return r;
}}
