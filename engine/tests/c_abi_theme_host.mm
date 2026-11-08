// ABI 1.51 page_theme_color: theme-colour events per document and only on
// change, ReArcTabGetThemeColor, and snapshot scope 2 (the viewport's top
// edge). The window sits far off screen, behind everything, never key.
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string>
#include <vector>
static uint64_t tab;
static NSWindow* window;
static ReArcAttachment attachment;
static std::string port;
static int stage;
static bool stopped, meta_titled;
static void meta_ready();
struct Seen { uint64_t document; bool has; uint32_t argb; };
static std::vector<Seen> seen;
static void navigate(const char* path){std::string url="http://127.0.0.1:"+port+path;assert(ReArcTabNavigate(tab,url.c_str(),0)==REARC_OK);}
static void shutdown_done(void*,ReArcStatus s,bool c){assert(s==0&&!c);stopped=true;puts("THEME runtime PASS");}
static void finish(){
 // Only changes: no two events in a row for one document say the same.
 for(size_t i=1;i<seen.size();++i)
  assert(!(seen[i].document==seen[i-1].document&&seen[i].has==seen[i-1].has&&seen[i].argb==seen[i-1].argb));
 puts("THEME events only on change PASS");
 assert(ReArcEngineShutdown(true,shutdown_done,nullptr)==0);
}
static void snapshot(void*,ReArcStatus s,uint64_t id,uint64_t,uint8_t* data,size_t size){
 fprintf(stderr,"THEME snapshot status=%d size=%zu\n",s,size);
 assert(s==REARC_OK&&id==tab&&data&&size);
 CFDataRef bytes=CFDataCreate(nullptr,data,size);ReArcBufferFree(data);
 CGImageSourceRef source=CGImageSourceCreateWithData(bytes,nullptr);
 CGImageRef image=CGImageSourceCreateImageAtIndex(source,0,nullptr);assert(image);
 size_t w=CGImageGetWidth(image),h=CGImageGetHeight(image);
 fprintf(stderr,"THEME top edge %zux%zu\n",w,h);
 assert(w>=700&&h>=1&&h<=8);
 std::vector<uint8_t> px(w*h*4);
 CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
 CGContextRef ctx=CGBitmapContextCreate(px.data(),w,h,8,w*4,space,kCGImageAlphaPremultipliedLast);
 CGContextDrawImage(ctx,CGRectMake(0,0,w,h),image);
 size_t i=((h/2)*w+w/2)*4;
 fprintf(stderr,"THEME top edge pixel %02x%02x%02x\n",px[i],px[i+1],px[i+2]);
 assert(abs(px[i]-0x1f)<=3&&abs(px[i+1]-0x20)<=3&&abs(px[i+2]-0x23)<=3);
 CGContextRelease(ctx);CGColorSpaceRelease(space);CGImageRelease(image);CFRelease(source);CFRelease(bytes);
 puts("THEME snapshot scope 2 is the #1f2023 top bar PASS");
 stage=3;navigate("/theme-script");
}
static void meta_ready(){
 // The <title> precedes the <meta>: go on once both have arrived.
 if(stage!=0||!meta_titled||seen.empty()||!seen.back().has)return;
 assert(seen.back().argb==0xFF336699);
 bool has;uint32_t argb;assert(ReArcTabGetThemeColor(tab,&has,&argb)==REARC_OK&&has&&argb==0xFF336699);
 assert(ReArcTabGetThemeColor(tab,nullptr,&argb)==REARC_INVALID_ARGUMENT);
 assert(ReArcTabCaptureSnapshot(tab,3,snapshot,nullptr)==REARC_INVALID_ARGUMENT);
 puts("THEME declared colour PASS");
 stage=1;navigate("/theme-none");
}
static void theme(void*,const ReArcThemeColorEvent* e){
 if(e->document.tab_id!=tab)return;
 fprintf(stderr,"THEME stage=%d doc=%llu has=%d argb=%08x\n",stage,e->document.document_generation,e->has_color,e->argb);
 assert(e->document.content_generation&&e->document.document_generation);
 seen.push_back({e->document.document_generation,e->has_color,e->argb});
 if(stage==3&&e->has_color){
  assert(e->argb==0xFF00FF00);
  bool has;uint32_t argb;assert(ReArcTabGetThemeColor(tab,&has,&argb)==REARC_OK&&has&&argb==0xFF00FF00);
  puts("THEME colour added by script delivered PASS");stage=4;finish();
 }
 meta_ready();
}
static void event(void*,const ReArcTabEvent* e){
 if(e->tab_id!=tab||e->kind!=1||!(e->changes&2)||!e->title)return;
 std::string title=e->title;
 if(stage==0&&title=="probe:meta"){
  meta_titled=true;meta_ready();
 } else if(stage==1&&title=="probe:none"){
  uint64_t meta=0;for(const auto& s:seen)if(s.has&&s.argb==0xFF336699)meta=s.document;
  assert(seen.back().document>meta&&!seen.back().has);
  bool has=true;uint32_t argb=1;assert(ReArcTabGetThemeColor(tab,&has,&argb)==REARC_OK&&!has&&!argb);
  puts("THEME new document without one reports none PASS");
  stage=2;
  // The bar is painted by now; give the compositor a frame.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
   assert(ReArcTabCaptureSnapshot(tab,2,snapshot,nullptr)==REARC_OK);
  });
 }
}
static void ready(void*,uint64_t profile){
 assert(ReArcEngineHasFeature("page_theme_color")&&ReArcEngineABIMinorVersion()>=51);
 assert(ReArcTabCreate(profile,1,nullptr,&tab)==REARC_OK);
 bool has;uint32_t argb;assert(ReArcTabGetThemeColor(0,&has,&argb)!=REARC_OK);
 window=[[NSWindow alloc]initWithContentRect:NSMakeRect(-30000,-30000,800,600)
  styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
 assert(ReArcWindowRegister(1,(__bridge void*)window)==REARC_OK);
 assert(ReArcViewAttach(tab,1,800,600,1,&attachment)==REARC_OK);
 [window.contentView addSubview:(__bridge NSView*)attachment.native_view];
 [window orderBack:nil];
 assert(ReArcViewSetVisible(tab,attachment.attachment_id,true)==REARC_OK);
 navigate("/theme-meta");
}
int main(int argc,const char** argv){@autoreleasepool{
 port=getenv("REARC_TEST_PORT");
 ReArcCallbacks c{ready,event,nullptr,nullptr};
 ReArcEngineSetThemeColorCallback(theme,nullptr);
 assert(ReArcEngineConfigure(1,&c,nullptr)==0);
 int r=ReArcEngineRun(argc,argv);assert(r==0&&stopped);return r;
}}
