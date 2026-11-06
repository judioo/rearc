#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <string>
#include <vector>
static uint64_t profile, tab;
static NSWindow* window;
static ReArcAttachment attachment{};
static int iteration, count=30;
static bool stopped, finished, shutdown_mode;
static double start,shutdown_start;
static unsigned token;
static int closed_count,blank_commits,prompt_requests,prompt_cancels;
static bool prompt_mode;
static std::vector<uint64_t> pending_prompts;
static std::vector<ReArcAttachment> shutdown_attachments;
static double now(){return NSProcessInfo.processInfo.systemUptime;}
static void next();
static void shutdown_done(void*,ReArcStatus s,bool c){assert(s==0&&!c);if(shutdown_mode){assert(closed_count==4);for(auto a:shutdown_attachments)ReArcViewRelease(a.native_view);}
 if(prompt_mode){assert(prompt_requests==4&&prompt_cancels==4&&pending_prompts.empty());puts("STRESS four pending dialogs cancelled exactly once PASS");}
 stopped=true;fprintf(stdout,"STRESS shutdown PASS elapsed_ms=%.3f closed=%d\n",shutdown_start?(now()-shutdown_start)*1000:0,closed_count);}
static void closed(void*,ReArcStatus s,bool c){assert(s==0&&!c);if(attachment.native_view)ReArcViewRelease(attachment.native_view);attachment={};next();}
static void finish(bool timeout){
 if(finished)return;finished=true;++token;
 fprintf(stdout,"TIMING mode=%s iteration=%d elapsed_ms=%.3f timeout=%d\n",iteration<count?"hidden":"attached",iteration%count,(now()-start)*1000,timeout);fflush(stdout);
 ++iteration;assert(ReArcTabClose(tab,true,closed,nullptr)==0);
}
static void event(void*,const ReArcTabEvent* e){
 if(e->kind==3&&std::string(e->url)=="about:blank")++blank_commits;
 if(shutdown_mode&&e->kind==2){++closed_count;fprintf(stderr,"CLOSED tab=%llu elapsed_ms=%.3f\n",(unsigned long long)e->tab_id,(now()-shutdown_start)*1000);}
 if(!shutdown_mode&&e->tab_id==tab&&e->kind==1&&(e->changes&2)&&std::string(e->title)=="stress-ok")finish(false);
}
static void next(){
 if(iteration==count*2){fprintf(stdout,"PLACEHOLDER commits=%d\n",blank_commits);if(ReArcEngineABIMinorVersion()>=4)assert(blank_commits==0);assert(ReArcEngineShutdown(true,shutdown_done,nullptr)==0);return;}
 finished=false;start=now();
 assert(ReArcTabCreate(profile,1,nullptr,&tab)==0);
 if(iteration>=count||shutdown_mode){
  assert(ReArcViewAttach(tab,1,640,480,1,&attachment)==0);
  [window.contentView addSubview:(__bridge NSView*)attachment.native_view];
  assert(ReArcViewSetVisible(tab,attachment.attachment_id,true)==0);
 }
 std::string url="http://127.0.0.1:"+std::string(getenv("REARC_TEST_PORT"))+(prompt_mode?"/prompt?i=":shutdown_mode?"/slow?i=":"/stress?i=")+std::to_string(iteration);
 assert(ReArcTabNavigate(tab,url.c_str(),0)==0);
 if(shutdown_mode){
  shutdown_attachments.push_back(attachment);attachment={};
  if(++iteration<4){next();return;}
  if(prompt_mode)return;
  const int delay=getenv("REARC_STRESS_DELAY_MS")?atoi(getenv("REARC_STRESS_DELAY_MS")):0;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,delay*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
   shutdown_start=now();fprintf(stderr,"SHUTDOWN request force=%d closed=%d\n",getenv("REARC_STRESS_FORCE")!=nullptr,closed_count);
   assert(ReArcEngineShutdown(getenv("REARC_STRESS_FORCE")!=nullptr,shutdown_done,nullptr)==0);
  });return;
 }
 unsigned expected=++token;
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(token==expected)finish(true);});
}
static void begin(uint64_t p){
 profile=p;
 prompt_mode=getenv("REARC_STRESS_PROMPTS")!=nullptr;
 if(prompt_mode){
  assert(ReArcEngineABIMinorVersion()>=18);
  ReArcEngineSetJavaScriptDialogCallback([](void*,const ReArcJavaScriptDialogEvent* e){
   if(e->phase){bool found=false;for(auto i=pending_prompts.begin();i!=pending_prompts.end();++i)if(*i==e->request_id){pending_prompts.erase(i);found=true;break;}assert(found);++prompt_cancels;assert(ReArcJavaScriptDialogRespond(e->request_id,true,"")==REARC_NOT_FOUND);return;}
   assert(e->kind==0);pending_prompts.push_back(e->request_id);if(++prompt_requests==4){shutdown_start=now();assert(ReArcEngineShutdown(true,shutdown_done,nullptr)==0);}
  },nullptr);
 }
 if(getenv("REARC_STRESS_COUNT"))count=atoi(getenv("REARC_STRESS_COUNT"));shutdown_mode=getenv("REARC_STRESS_SHUTDOWN")!=nullptr;
 window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,640,480) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
 assert(ReArcWindowRegister(1,(__bridge void*)window)==0);[window orderFront:nil];next();
}
static void opened(void*,ReArcStatus s,uint64_t p,bool otr){
 assert(s==REARC_OK);
 if(getenv("REARC_STRESS_PROFILE")&&std::string(getenv("REARC_STRESS_PROFILE"))=="otr"&&!otr){
  assert(ReArcProfileCreateOffTheRecord(p,opened,nullptr)==REARC_OK);return;
 }
 begin(p);
}
static void ready(void*,uint64_t p){
 if(getenv("REARC_STRESS_PROFILE")&&std::string(getenv("REARC_STRESS_PROFILE"))!="default"){
  assert(ReArcProfileOpen("stress-named",opened,nullptr)==REARC_OK);return;
 }
 begin(p);
}
int main(int argc,const char** argv){@autoreleasepool{
 ReArcCallbacks c{ready,event,nullptr,nullptr};assert(ReArcEngineConfigure(1,&c,nullptr)==0);
 int result=ReArcEngineRun(argc,argv);assert(result==0&&stopped);return result;
}}
