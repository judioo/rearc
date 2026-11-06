#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <string>
static uint64_t startup,profile,tab;
static bool second,stopped,loaded;
static int opens,errors,race_replies,cancellations;
static uint64_t race_named,race_directory;
static void start();
static std::string url;
static void reject(void*,ReArcStatus,uint64_t,bool){assert(false);}
static void done(void*,ReArcStatus status,bool cancelled){assert(status==REARC_OK&&!cancelled&&(!second||cancellations==2));stopped=true;}
static void checked(void*,const ReArcScriptResult* result){
  assert(result->status==REARC_OK);
  fprintf(stdout,"MIGRATION state=%s\n",result->json);
  assert(std::string(result->json)=="[\"legacy=kept\",\"DEFAULT-DATA-W16\"]");
  if(second)for(int i=0;i<2;++i)
    assert(ReArcProfileOpenDirectory("Default",[](void*,ReArcStatus s,uint64_t id,bool otr){assert(s==REARC_CANCELLED&&id==0&&!otr);++cancellations;},nullptr)==REARC_OK);
  assert(ReArcEngineShutdown(true,done,nullptr)==REARC_OK);
}
static void event(void*,const ReArcTabEvent* e){
  if(e->tab_id!=tab||loaded||e->kind!=1||!(e->changes&2)||!std::string(e->title).starts_with("probe:"))return;
  loaded=true;
  const char* source=second?"[document.cookie,localStorage.getItem('legacy')]":
    "document.cookie='legacy=kept;max-age=86400;path=/';localStorage.setItem('legacy','DEFAULT-DATA-W16');[document.cookie,localStorage.getItem('legacy')]";
  assert(ReArcTabEvaluateScript2(tab,source,1,nullptr,3000,checked,nullptr)==REARC_OK);
}
static void opened(void*,ReArcStatus status,uint64_t p,bool otr){
  assert(status==REARC_OK&&!otr&&p==startup);profile=p;
  ++opens;start();
}
static void start(){
  if(opens!=2||errors!=3||race_replies!=2)return;
  assert(race_named&&(!race_directory||race_named==race_directory));
  assert(ReArcProfileClose(profile,true,done,nullptr)==REARC_INVALID_STATE);
  assert(ReArcTabCreate(profile,1,url.c_str(),&tab)==REARC_OK);
}
static void ready(void*,uint64_t p){
  startup=p;
  if(second){
    assert(ReArcEngineHasFeature("profile_directory"));
    assert(ReArcProfileOpenDirectory("ReArcProfile-726163652D773136",[](void*,ReArcStatus s,uint64_t id,bool otr){assert(!otr&&(s==REARC_OK||s==REARC_NOT_FOUND));race_directory=id;++race_replies;start();},nullptr)==REARC_OK);
    assert(ReArcProfileOpen("race-w16",[](void*,ReArcStatus s,uint64_t id,bool otr){assert(s==REARC_OK&&!otr);race_named=id;++race_replies;start();},nullptr)==REARC_OK);
    for(const char* invalid:{"", "..", "../Default", "/tmp", "Default/child"})
      assert(ReArcProfileOpenDirectory(invalid,reject,nullptr)==REARC_INVALID_ARGUMENT);
    for(const char* missing:{"missing-w16","default"})
      assert(ReArcProfileOpenDirectory(missing,[](void*,ReArcStatus s,uint64_t id,bool otr){assert(s==REARC_NOT_FOUND&&id==0&&!otr);++errors;start();},nullptr)==REARC_OK);
    assert(ReArcProfileOpenDirectory("alias",[](void*,ReArcStatus s,uint64_t id,bool otr){assert(s==REARC_INVALID_ARGUMENT&&id==0&&!otr);++errors;start();},nullptr)==REARC_OK);
    assert(ReArcProfileOpenDirectory("Default",nullptr,nullptr)==REARC_INVALID_ARGUMENT);
    assert(ReArcProfileOpenDirectory("Default",opened,nullptr)==REARC_OK);
    assert(ReArcProfileOpenDirectory("Default",opened,nullptr)==REARC_OK);
    assert(opens==0);
  }else{profile=p;assert(ReArcTabCreate(profile,1,url.c_str(),&tab)==REARC_OK);}
}
int main(int argc,const char** argv){@autoreleasepool{
  second=getenv("REARC_MIGRATION_SECOND");
  url="http://127.0.0.1:"+std::string(getenv("REARC_TEST_PORT"))+"/test";
  ReArcCallbacks callbacks{ready,event,nullptr,nullptr};
  assert(ReArcEngineConfigure(1,&callbacks,nullptr)==REARC_OK);
  int result=ReArcEngineRun(argc,argv);assert(result==0&&stopped);return result;
}}
