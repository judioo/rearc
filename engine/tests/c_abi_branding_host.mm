#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
static bool stopped;
static void done(void*,ReArcStatus s,bool c){assert(s==0&&!c);stopped=true;puts("BRANDING runtime PASS");}
static void ready(void*,uint64_t p){assert(p&&ReArcEngineHasFeature("rearc_safe_storage_branding"));assert([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.rearc.browser"]);assert(ReArcEngineShutdown(true,done,nullptr)==0);}
int main(int argc,const char** argv){@autoreleasepool{ReArcCallbacks c{ready,nullptr,nullptr,nullptr};assert(ReArcEngineConfigure(1,&c,nullptr)==0);int r=ReArcEngineRun(argc,argv);assert(r==0&&stopped);return r;}}
