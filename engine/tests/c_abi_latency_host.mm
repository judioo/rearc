#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <string>
static uint64_t profile,tab;
static NSWindow* window;
static ReArcAttachment lease{};
static int iteration,count=6,stage;
static bool stopped,loaded;
static double start,eval_start;
static double now(){return NSProcessInfo.processInfo.systemUptime;}
static const char* mode(){return iteration%2?"attached":"hidden";}
static void next();
static void done(void*,ReArcStatus s,bool c){assert(s==REARC_OK&&!c);stopped=true;}
static void closed(void*,ReArcStatus s,bool c){assert(s==REARC_OK&&!c);if(lease.native_view)ReArcViewRelease(lease.native_view);lease={};++iteration;next();}
static void evaluate();
static void evaluated(void*,const ReArcScriptResult* r){
  assert(r->status==REARC_OK||(stage>=2&&r->status==REARC_TIMEOUT));
  fprintf(stdout,"LATENCY mode=%s iteration=%d stage=%d elapsed_ms=%.3f status=%d json=%s\n",mode(),iteration/2,stage,(now()-eval_start)*1000,r->status,r->json?r->json:"");
  if(++stage<4)evaluate();else assert(ReArcTabClose(tab,true,closed,nullptr)==REARC_OK);
}
static void evaluate(){
  const char* scripts[]={"({visibility:document.visibilityState,hidden:document.hidden,title:document.title})","42", "(async()=>{let t=performance.now();for(let i=0;i<8;i++)await new Promise(r=>setTimeout(r,5));return performance.now()-t})()", "new Promise(r=>requestAnimationFrame(()=>r('raf')))"};
  eval_start=now();assert(ReArcTabEvaluateScript2(tab,scripts[stage],0,nullptr,stage==3?350:30000,evaluated,nullptr)==REARC_OK);
}
static void event(void*,const ReArcTabEvent* e){
  if(e->tab_id==tab&&!loaded&&e->kind==1&&(e->changes&2)&&std::string(e->title)=="stress-ok"){
    loaded=true;fprintf(stdout,"LATENCY mode=%s iteration=%d stage=load elapsed_ms=%.3f\n",mode(),iteration/2,(now()-start)*1000);stage=0;evaluate();
  }
}
static void next(){
  if(iteration==count*2){assert(ReArcEngineShutdown(true,done,nullptr)==REARC_OK);return;}
  loaded=false;start=now();assert(ReArcTabCreate(profile,1,nullptr,&tab)==REARC_OK);
  if(iteration%2){assert(ReArcViewAttach(tab,1,640,480,1,&lease)==REARC_OK);[window.contentView addSubview:(__bridge NSView*)lease.native_view];assert(ReArcViewSetVisible(tab,lease.attachment_id,true)==REARC_OK);}
  std::string url="http://127.0.0.1:"+std::string(getenv("REARC_TEST_PORT"))+"/latency?i="+std::to_string(iteration);
  assert(ReArcTabNavigate(tab,url.c_str(),0)==REARC_OK);
}
static void ready(void*,uint64_t p){
  profile=p;window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,640,480) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  assert(ReArcWindowRegister(1,(__bridge void*)window)==REARC_OK);[window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];next();
}
int main(int argc,const char** argv){@autoreleasepool{
  setbuf(stdout,nullptr);ReArcCallbacks c{ready,event,nullptr,nullptr};assert(ReArcEngineConfigure(1,&c,nullptr)==REARC_OK);
  int result=ReArcEngineRun(argc,argv);assert(result==0&&stopped);return result;
}}
