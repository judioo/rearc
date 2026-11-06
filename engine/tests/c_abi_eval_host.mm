#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <string>
static uint64_t tab;
static int step;
static bool started,stopped,cancelled_close;
static void eval(const char* source,uint32_t world=0,const char* boost=nullptr,unsigned timeout=3000);
static void shutdown_done(void*,ReArcStatus s,bool c){assert(s==0&&!c&&cancelled_close);stopped=true;puts("EVALUATION runtime PASS");}
static void closed(void*,ReArcStatus s,bool c){assert(s==0&&!c&&cancelled_close);assert(ReArcEngineShutdown(true,shutdown_done,nullptr)==0);}
static void result(void*,ReArcStatus s,uint64_t id,uint64_t gen,const char* json,const char* error){
 assert(id==tab&&gen);fprintf(stderr,"EVAL step=%d status=%d json=%s error=%s\n",step,s,json?json:"(null)",error?error:"(null)");
 if(step<6){assert(s==0&&json&&!error);}
 else assert(!json&&error);
 switch(step++){
 case 0:assert(std::string(json)=="42");eval("typeof boostSecret",1);break;
 case 1:assert(std::string(json)=="\"undefined\"");eval("Promise.resolve({nested:[1,true,null]})");break;
 case 2:assert(std::string(json)=="{\"nested\":[1,true,null]}");eval("globalThis.editorSecret=7");break;
 case 3:assert(std::string(json)=="7");eval("globalThis.editorSecret");break;
 case 4:assert(std::string(json)=="7");eval("undefined");break;
 case 5:assert(std::string(json)=="null");eval("(()=>{throw new Error('expected')})()");break;
 case 6:assert(s==REARC_SCRIPT_ERROR&&std::string(error).find("exception")!=std::string::npos);eval("1n");break;
 case 7:assert(s==REARC_SCRIPT_ERROR&&std::string(error).find("serialization")!=std::string::npos);eval("new Promise(()=>{})",0,nullptr,40);break;
 case 8:assert(s==REARC_TIMEOUT);eval("new Promise(()=>{})");assert(ReArcTabNavigate(tab,"about:blank",0)==0);break;
 case 9:assert(s==REARC_CANCELLED);break;
 case 10:assert(s==REARC_CANCELLED);cancelled_close=true;break;
 default:assert(false);
 }
}
static void eval(const char* source,uint32_t world,const char* boost,unsigned timeout){
 assert(ReArcTabEvaluateScript(tab,source,world,boost,timeout,result,nullptr)==0);
 assert(ReArcTabEvaluateScript(tab,"1",0,nullptr,100,result,nullptr)==REARC_BUSY);
}
static void event(void*,const ReArcTabEvent* e){
 if(e->tab_id!=tab)return;
 if(e->kind==1&&(e->changes&2)&&std::string(e->title).starts_with("probe:")&&!started){
  started=true;eval("globalThis.boostSecret",0,"installed");
 }
 if(e->kind==3&&std::string(e->url)=="about:blank"&&step==10){
  eval("new Promise(()=>{})");assert(ReArcTabClose(tab,true,closed,nullptr)==0);
 }
}
static void installed(void*,ReArcStatus s,bool c){
 assert(s==0&&!c);std::string url="http://127.0.0.1:"+std::string(getenv("REARC_TEST_PORT"))+"/test";
 assert(ReArcTabNavigate(tab,url.c_str(),0)==0);
}
static void ready(void*,uint64_t p){
 assert(ReArcEngineHasFeature("script_evaluation"));assert(ReArcTabCreate(p,1,nullptr,&tab)==0);
 assert(ReArcTabEvaluateScript(tab,"1",2,nullptr,1,result,nullptr)==REARC_INVALID_ARGUMENT);
 assert(ReArcTabEvaluateScript(tab,"1",0,"bad.id",1,result,nullptr)==REARC_INVALID_ARGUMENT);
 assert(ReArcTabEvaluateScript(tab,"1",0,nullptr,0,result,nullptr)==REARC_INVALID_ARGUMENT);
 ReArcScriptScope scope{"127.0.0.1","/test",false,1};ReArcScript script{"installed",&scope,1,0,"globalThis.boostSecret=42;",""};
 assert(ReArcTabSetScripts(tab,&script,1,installed,nullptr)==0);
}
int main(int argc,const char** argv){@autoreleasepool{
 ReArcCallbacks c{ready,event,nullptr,nullptr};assert(ReArcEngineConfigure(1,&c,nullptr)==0);int r=ReArcEngineRun(argc,argv);assert(r==0&&stopped);return r;
}}
