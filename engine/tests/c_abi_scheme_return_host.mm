#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <string>
static uint64_t tab;
static int stage;
static bool stopped,evaluating;
static std::string http;
static void done(void*,ReArcStatus s,bool c){assert(s==0&&!c);stopped=true;puts("SCHEME return + script registration PASS");}
static void closed(void*,ReArcStatus s,bool c){assert(s==0&&!c);assert(ReArcEngineShutdown(true,done,nullptr)==0);}
static void result(void*,ReArcStatus s,uint64_t id,uint64_t gen,const char* json,const char* error){
 evaluating=false;assert(s==0&&id==tab&&gen&&json&&!error&&std::string(json)=="42");
 if(stage==0){stage=1;assert(ReArcTabNavigate(tab,"chrome://version/",0)==0);}
 else if(stage==2){stage=3;assert(ReArcTabNavigate(tab,"file:///tmp/rearc-abi-return.html",0)==0);}
 else{assert(stage==4);stage=5;assert(ReArcTabClose(tab,true,closed,nullptr)==0);}
}
static void ignored_snapshot(void*,ReArcStatus,uint64_t,uint64_t,uint8_t*,size_t){assert(false);}
static void event(void*,const ReArcTabEvent* e){
 if(e->tab_id!=tab)return;
 if(e->kind==3&&(std::string(e->url).starts_with("chrome:")||std::string(e->url).starts_with("file:"))){
  assert(stage==1||stage==3);
  assert(ReArcTabEvaluateScript(tab,"1",1,nullptr,1000,result,nullptr)==REARC_UNSUPPORTED);
  assert(ReArcTabCaptureSnapshot(tab,0,ignored_snapshot,nullptr)==REARC_UNSUPPORTED);
  ++stage;assert(ReArcTabNavigate(tab,http.c_str(),0)==0);
 }
 if(e->kind==1&&(e->changes&2)&&std::string(e->title).starts_with("probe:")&&!evaluating&&(stage==0||stage==2||stage==4)){
  evaluating=true;assert(ReArcTabEvaluateScript(tab,"globalThis.returnSecret",0,"return",3000,result,nullptr)==0);
 }
}
static void peek_ready(void*,ReArcStatus s,bool c){assert(s==0&&!c);assert(ReArcTabNavigate(tab,http.c_str(),0)==0);}
static void installed(void*,ReArcStatus s,bool c){assert(s==0&&!c);assert(ReArcTabSetLinkPeek(tab,true,peek_ready,nullptr)==0);}
static void ready(void*,uint64_t p){
 http="http://127.0.0.1:"+std::string(getenv("REARC_TEST_PORT"))+"/test";
 [@"<title>file</title>" writeToFile:@"/tmp/rearc-abi-return.html" atomically:YES encoding:NSUTF8StringEncoding error:nil];
 assert(ReArcTabCreate(p,1,nullptr,&tab)==0);
 ReArcScriptScope scope{"127.0.0.1","/test",false,1};ReArcScript script{"return",&scope,1,0,"globalThis.returnSecret=42;","body{color:rgb(3,2,1)}"};
 assert(ReArcTabSetScripts(tab,&script,1,installed,nullptr)==0);
}
int main(int argc,const char** argv){@autoreleasepool{
 ReArcCallbacks c{ready,event,nullptr,nullptr};assert(ReArcEngineConfigure(1,&c,nullptr)==0);int r=ReArcEngineRun(argc,argv);assert(r==0&&stopped);return r;
}}
