#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <string>
#include <stdio.h>
static uint64_t tab, profile;
static ReArcDocumentIdentity original, same;
static int stage;
static bool started, stopped, cancelled, same_result, same_commit;
static void reload_when_ready(){if(same_result&&same_commit&&stage==5){stage=6;assert(ReArcTabReload(tab,false)==0);}}
static void evaluate(const char* js);
static void shutdown_done(void*,ReArcStatus s,bool c){assert(s==0&&!c&&cancelled);stopped=true;puts("IDENTITY runtime PASS");}
static void closed(void*,ReArcStatus s,bool c){assert(s==0&&!c&&cancelled);assert(ReArcEngineShutdown(true,shutdown_done,nullptr)==0);}
static void result(void*,const ReArcScriptResult* r){
 assert(r->document.tab_id==tab&&r->document.profile_id==profile&&r->document.content_generation);
 fprintf(stderr,"IDENTITY stage=%d status=%d document=%llu nav=%llu\n",stage,r->status,r->document.document_generation,r->document.navigation_id);
 if(stage==1){
  assert(r->status==0&&std::string(r->json)=="42");original=r->document;
  ReArcDocumentIdentity now;assert(ReArcTabGetDocumentIdentity(tab,&now)==0);
  assert(now.document_generation==original.document_generation&&now.navigation_id==original.navigation_id);
  stage=2;evaluate("new Promise(()=>{})");std::string next="http://127.0.0.1:"+std::string(getenv("REARC_TEST_PORT"))+"/test?next";assert(ReArcTabNavigate(tab,next.c_str(),0)==0);
 }else if(stage==2){
  assert(r->status==REARC_CANCELLED&&r->document.document_generation==original.document_generation&&r->document.navigation_id==original.navigation_id);stage=3;
 }else if(stage==4){
  assert(r->status==0&&std::string(r->json)=="true");
  assert(r->document.document_generation>original.document_generation&&r->document.navigation_id!=original.navigation_id);
  same=r->document;stage=5;evaluate("location.hash='same';true");
 }else if(stage==5){assert(r->status==0&&r->document.document_generation==same.document_generation);same_result=true;reload_when_ready();
 }else if(stage==7){
  assert(r->status==REARC_CANCELLED&&r->document.document_generation>same.document_generation);cancelled=true;
 }else assert(false);
}
static void evaluate(const char* js){
 assert(ReArcTabEvaluateScript2(tab,js,0,nullptr,10000,result,nullptr)==0);
 assert(ReArcTabEvaluateScript(tab,"1",0,nullptr,100,[](void*,ReArcStatus,uint64_t,uint64_t,const char*,const char*){assert(false);},nullptr)==REARC_BUSY);
}
static void event(void*,const ReArcTabEvent* e){
 if(e->tab_id!=tab)return;
 if(!started&&e->kind==1&&(e->changes&2)&&std::string(e->title).starts_with("probe:")){
  started=true;stage=1;evaluate("Promise.resolve(42)");
 }
 if(e->kind!=3)return;
 if(stage==3){stage=4;evaluate("true");}
 else if(stage==5){
  assert(e->is_same_document);ReArcDocumentIdentity now;assert(ReArcTabGetDocumentIdentity(tab,&now)==0);
  assert(now.document_generation==same.document_generation&&now.navigation_id==e->navigation_id&&now.navigation_id!=same.navigation_id);
  same_commit=true;reload_when_ready();
 }else if(stage==6){
  ReArcDocumentIdentity now;assert(ReArcTabGetDocumentIdentity(tab,&now)==0);
  assert(now.document_generation>same.document_generation&&now.navigation_id==e->navigation_id);
  stage=7;evaluate("new Promise(()=>{})");assert(ReArcTabClose(tab,true,closed,nullptr)==0);
 }
}
static void ready(void*,uint64_t p){
 profile=p;assert(ReArcEngineHasFeature("script_evaluation_identity"));
 assert(ReArcTabCreate(p,1,nullptr,&tab)==0);ReArcDocumentIdentity id;
 assert(ReArcTabGetDocumentIdentity(tab,&id)==0&&id.document_generation==1&&!id.navigation_id);
 assert(ReArcTabEvaluateScript2(tab,"1",0,nullptr,1,nullptr,nullptr)==REARC_INVALID_ARGUMENT);
 std::string url="http://127.0.0.1:"+std::string(getenv("REARC_TEST_PORT"))+"/test";assert(ReArcTabNavigate(tab,url.c_str(),0)==0);
}
int main(int argc,const char** argv){@autoreleasepool{ReArcCallbacks c{ready,event,nullptr,nullptr};assert(ReArcEngineConfigure(1,&c,nullptr)==0);int r=ReArcEngineRun(argc,argv);assert(r==0&&stopped);return r;}}
