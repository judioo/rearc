#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
static uint64_t tab;
static NSWindow* window;
static ReArcAttachment attachment;
static bool saw_created, saw_closed, saw_invalidated, stopped;
static void shutdown_done(void*, ReArcStatus status, bool cancelled) {
  assert(status == REARC_OK && !cancelled && saw_closed && saw_invalidated);
  stopped = true; puts("ABI shutdown completion PASS");
}
static void close_done(void*, ReArcStatus status, bool cancelled) {
  assert(status == REARC_OK && !cancelled && saw_closed && saw_invalidated);
  assert(ReArcViewDetach(tab,attachment.attachment_id)==REARC_STALE_ATTACHMENT);
  ReArcViewRelease(attachment.native_view);
  assert(ReArcEngineShutdown(true, shutdown_done, nullptr)==REARC_OK);
}
static void tab_event(void*, const ReArcTabEvent* e) {
  assert([NSThread isMainThread]); assert(e->profile_id && e->content_generation);
  if (e->kind == 0) { assert(!saw_created); saw_created=true; }
  else assert(saw_created);
  if (e->kind == 3) {
    assert(ReArcTabClose(tab,true,close_done,nullptr)==REARC_OK);
    assert(ReArcTabClose(tab,true,close_done,nullptr)==REARC_BUSY);
  }
  if(e->kind == 2) {assert(saw_invalidated);saw_closed=true;}
}
static void invalidated(void*, const ReArcViewEvent* e) {
  assert(e->profile_id && e->content_generation);
  assert([(__bridge NSView*)attachment.native_view subviews].count==0);
  saw_invalidated = true;
}
static void ready(void*, uint64_t profile) {
  assert(profile && profile == ReArcEngineDefaultProfile());
  assert(ReArcTabCreate(profile,1,"about:blank",&tab)==REARC_OK);
  assert(!saw_created); // No callback reenters create.
  assert(ReArcTabNavigate(tab,"javascript:alert(1)",0)==REARC_INVALID_URL);
  window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,640,480)
      styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  assert(ReArcWindowRegister(1,(__bridge void*)window)==REARC_OK);
  assert(ReArcViewAttach(tab,1,640,480,1,&attachment)==REARC_OK);
  ReArcAttachment second;
  assert(ReArcViewAttach(tab,1,640,480,1,&second)==REARC_ALREADY_ATTACHED);
  [window.contentView addSubview:(__bridge NSView*)attachment.native_view];
  [window orderFront:nil];
  assert(ReArcViewSetVisible(tab,attachment.attachment_id,true)==REARC_OK);
  assert(ReArcViewResize(tab,attachment.attachment_id,800,600,2)==REARC_OK);
  puts("ABI ready/create/attach/visibility PASS");
}
int main(int argc,const char** argv) {
 @autoreleasepool {
  ReArcCallbacks callbacks{ready,tab_event,invalidated,nullptr};
  assert(ReArcEngineABIVersion()==1);
  assert(ReArcEngineConfigure(999,&callbacks,nullptr)==REARC_VERSION_MISMATCH);
  assert(ReArcEngineConfigure(1,&callbacks,nullptr)==REARC_OK);
  int code=ReArcEngineRun(argc,argv);
  assert(stopped && code==0);
  puts("ABI runtime PASS");return code;
 }
}
