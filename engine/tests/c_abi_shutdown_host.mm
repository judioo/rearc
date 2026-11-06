#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <set>
static uint64_t tabs[3];
static NSWindow* window;
static ReArcAttachment lease{};
static std::set<uint64_t> closed;
static unsigned replies, invalidations;
static bool stopped, requested;
static int mode;
static void done(void*,ReArcStatus status,bool cancelled) {
  assert(status==REARC_OK&&!cancelled&&closed.size()==3&&replies==2);
  assert(invalidations==1&&requested);
  ReArcViewRelease(lease.native_view);
  stopped=true;puts("SHUTDOWN pending-close ordering and exactly-once PASS");
}
static void shutdown() {
  assert(!requested);requested=true;
  assert(ReArcEngineShutdown(mode!=0,done,nullptr)==REARC_OK);
  assert(ReArcEngineShutdown(true,done,nullptr)==REARC_BUSY);
  uint64_t unused;
  assert(ReArcTabCreate(ReArcEngineDefaultProfile(),1,nullptr,&unused)==REARC_ENGINE_NOT_READY);
}
static void reply(void* context,ReArcStatus status,bool cancelled) {
  assert(status==REARC_OK&&!cancelled);
  auto index=reinterpret_cast<uintptr_t>(context);
  assert(closed.contains(tabs[index]));++replies;
}
static void event(void*,const ReArcTabEvent* e) {
  assert(!stopped);
  if(e->kind==2){assert(closed.insert(e->tab_id).second);}
}
static void invalidated(void*,const ReArcViewEvent*) {
  assert(!stopped);++invalidations;
  if(mode==2)shutdown();
}
static void ready(void*,uint64_t p) {
  assert(ReArcEngineHasFeature("shutdown_pending_closes"));
  for(auto& tab:tabs)assert(ReArcTabCreate(p,1,nullptr,&tab)==REARC_OK);
  window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,300,200) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  assert(ReArcWindowRegister(1,(__bridge void*)window)==REARC_OK);
  assert(ReArcViewAttach(tabs[0],1,300,200,1,&lease)==REARC_OK);
  [window.contentView addSubview:(__bridge NSView*)lease.native_view];
  assert(ReArcTabClose(tabs[0],true,reply,nullptr)==REARC_OK);
  assert(ReArcTabClose(tabs[1],false,reply,reinterpret_cast<void*>(1))==REARC_OK);
  if(mode!=2)shutdown();
}
int main(int argc,const char** argv){@autoreleasepool{
  if(getenv("REARC_SHUTDOWN_MODE"))mode=atoi(getenv("REARC_SHUTDOWN_MODE"));
  ReArcCallbacks c{ready,event,invalidated,nullptr};
  assert(ReArcEngineConfigure(1,&c,nullptr)==REARC_OK);
  int result=ReArcEngineRun(argc,argv);assert(result==0&&stopped);return result;
}}
