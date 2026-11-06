#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <string>
#include <vector>
static uint64_t profile,tab;
static size_t url_index;
static bool stopped;
static std::vector<std::string> urls;
static void next();
static void shutdown_done(void*,ReArcStatus s,bool c){assert(s==0&&!c);stopped=true;puts("URL policy runtime PASS");}
static void closed(void*,ReArcStatus s,bool c){assert(s==0&&!c);++url_index;next();}
static void next(){
 if(url_index==urls.size()){assert(ReArcEngineShutdown(true,shutdown_done,nullptr)==0);return;}
 assert(ReArcTabCreate(profile,1,urls[url_index].c_str(),&tab)==0);
}
static void event(void*,const ReArcTabEvent* e){
 if(e->kind==3&&e->tab_id==tab){
  fprintf(stderr,"URL commit %s error=%d\n",e->url,e->is_error_page);
  assert(!e->is_error_page);assert(ReArcTabClose(tab,true,closed,nullptr)==0);
 }
}
static void ready(void*,uint64_t p){
 profile=p;assert(ReArcEngineABIMinorVersion()>=1);assert(ReArcEngineHasFeature("navigation_extended"));
 std::string file="/tmp/rearc-abi-url-fixture.html";
 [@"<title>local-file</title>" writeToFile:[NSString stringWithUTF8String:file.c_str()] atomically:YES encoding:NSUTF8StringEncoding error:nil];
 urls={"data:text/html,<title>data-ok</title>","file://"+file,"chrome://settings/","chrome://version/","view-source:http://127.0.0.1:"+std::string(getenv("REARC_TEST_PORT"))+"/test","about:blank"};
 uint64_t rejected=123;
 for(const char* url:{"javascript:alert(1)","blob:https://example.com/id","chrome-untrusted://test/","view-source:javascript:alert(1)","view-source:view-source:https://example.com","ftp://example.com","chrome://flags/","mailto:a@example.com"}){
  assert(ReArcTabCreate(p,1,url,&rejected)==REARC_INVALID_URL&&rejected==0);
 }
 next();
}
int main(int argc,const char** argv){@autoreleasepool{
 ReArcCallbacks c{ready,event,nullptr,nullptr};assert(ReArcEngineConfigure(1,&c,nullptr)==0);
 int r=ReArcEngineRun(argc,argv);assert(r==0&&stopped);return r;
}}
