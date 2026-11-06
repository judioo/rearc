#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <string>
#include <stdio.h>
static uint64_t tab, closing_tab, profile;
static std::string url;
static int stage, boosts, floods;
static bool loaded, editor, evaluated, stopped, navigation_cancelled, close_cancelled, closed;
static void maybe_editor();
static void result(void*,const ReArcScriptResult*);
static void eval(const char* js,uint32_t world=0){assert(ReArcTabEvaluateScript2(tab,js,world,nullptr,10000,result,nullptr)==0);}
static void shutdown_done(void*,ReArcStatus s,bool c){assert(s==0&&!c&&navigation_cancelled&&close_cancelled&&closed);stopped=true;printf("MESSAGES runtime PASS boost=%d flood_delivered=%d/500\n",boosts,floods);}
static void close_done(void*,ReArcStatus s,bool c){assert(s==0&&!c&&closed&&close_cancelled);assert(ReArcEngineShutdown(true,shutdown_done,nullptr)==0);}
static void message(void*,const ReArcPageMessage* m){
 assert(m->document.profile_id==profile&&m->document.content_generation&&m->document.document_generation);
 assert(m->json&&m->boost_id&&!closed);
 std::string json=m->json;fprintf(stderr,"MESSAGE stage=%d tab=%llu boost=%s json=%s\n",stage,m->document.tab_id,m->boost_id,m->json);
 if(json=="{\"kind\":\"boost\",\"value\":42}"){
  assert(m->document.tab_id==tab&&std::string(m->boost_id)=="installed");++boosts;
  if(stage==0)maybe_editor();
  else if(stage==4&&loaded){stage=5;eval("rearcPostMessage('{\"kind\":\"navigate\"}');new Promise(()=>{})");}
 }else if(json=="{\"kind\":\"editor\",\"value\":[1,true]}"){
  assert(stage==2&&std::string(m->boost_id)=="editor");editor=true;maybe_editor();
 }else if(json.starts_with("{\"kind\":\"flood\"")){assert(stage==3);++floods;}
 else if(json=="{\"kind\":\"navigate\"}"){
  assert(stage==5);stage=9;
  std::string abort_url=url+"?abort";assert(ReArcTabNavigate(tab,abort_url.c_str(),0)==0);assert(ReArcTabStop(tab)==0);
 }else if(json=="{\"kind\":\"recovered\"}"){
  assert(stage==11);stage=12;assert(ReArcTabNavigate(tab,"about:blank",0)==0);
 }else if(json=="{\"kind\":\"close\"}"){
  assert(stage==7&&m->document.tab_id==closing_tab);
  assert(ReArcTabClose(closing_tab,true,close_done,nullptr)==0);
 }else assert(false); // malformed/oversize/disabled/stale/after-close forbidden.
}
static void maybe_editor(){
 if(stage==0&&loaded&&boosts){stage=1;eval("typeof rearcPostMessage",1);}
 else if(stage==2&&editor&&evaluated){stage=3;eval("for(let i=0;i<500;i++)rearcPostMessage(JSON.stringify({kind:'flood',i}));true");}
}
static void result(void*,const ReArcScriptResult* r){
 if(stage==9){assert(r->status==REARC_CANCELLED);stage=10;return;}
 if(stage==12){assert(r->status==REARC_CANCELLED);navigation_cancelled=true;stage=6;return;}
 assert(r->status==0&&r->json&&!r->error_json);
 if(stage==1){assert(std::string(r->json)=="\"undefined\"");stage=2;eval("rearcPostMessage('{\"kind\":\"editor\",\"value\":[1,true]}');rearcPostMessage('not json');rearcPostMessage(JSON.stringify('x'.repeat(65536)));true");}
 else if(stage==2){evaluated=true;maybe_editor();}
 else if(stage==3){
  assert(floods>0&&floods<500);printf("rate-bound delivered=%d/500 PASS\n",floods);
  stage=8;ReArcEngineSetPageMessageCallback(nullptr,nullptr);eval("new Promise(resolve=>setTimeout(()=>{rearcPostMessage('{\"kind\":\"disabled\"}');resolve(true)},1100))");
 }else if(stage==8){stage=4;loaded=false;ReArcEngineSetPageMessageCallback(message,nullptr);assert(ReArcTabReload(tab,false)==0);}
 else assert(false);
}
static void event(void*,const ReArcTabEvent* e){
 if(e->tab_id==tab&&e->kind==4&&stage==10){
  stage=11;eval("rearcPostMessage('{\"kind\":\"recovered\"}');for(let i=0;i<10;i++)rearcPostMessage('{\"kind\":\"stale\"}');new Promise(()=>{})");
 }
 if(e->kind==2&&e->tab_id==closing_tab){closed=true;return;}
 if(e->tab_id==tab&&e->kind==1&&(e->changes&2)&&std::string(e->title).starts_with("probe:")){
  loaded=true;maybe_editor();
  if(stage==4&&boosts==2){stage=5;eval("rearcPostMessage('{\"kind\":\"navigate\"}');new Promise(()=>{})");}
 }
 if(e->kind==3&&e->tab_id==tab&&stage==6&&std::string(e->url)=="about:blank"){
  assert(navigation_cancelled);stage=7;assert(ReArcTabCreate(profile,2,url.c_str(),&closing_tab)==0);
 }
 if(e->tab_id==closing_tab&&e->kind==1&&(e->changes&2)&&std::string(e->title).starts_with("probe:")){
  assert(ReArcTabEvaluateScript2(closing_tab,"rearcPostMessage('{\"kind\":\"close\"}');for(let i=0;i<10;i++)rearcPostMessage('{\"kind\":\"after-close\"}');new Promise(()=>{})",0,nullptr,10000,[](void*,const ReArcScriptResult* r){assert(r->status==REARC_CANCELLED);close_cancelled=true;},nullptr)==0);
 }
}
static void ready(void*,uint64_t p){
 profile=p;assert(ReArcEngineHasFeature("isolated_page_messages"));assert(ReArcTabCreate(p,1,nullptr,&tab)==0);
 ReArcScriptScope scope{"127.0.0.1","/test",false,1};ReArcScript script{"installed",&scope,1,0,"rearcPostMessage(JSON.stringify({kind:'boost',value:42}));",""};
 assert(ReArcTabSetScripts(tab,&script,1,[](void*,ReArcStatus s,bool c){assert(s==0&&!c);assert(ReArcTabNavigate(tab,url.c_str(),0)==0);},nullptr)==0);
}
int main(int argc,const char** argv){@autoreleasepool{setbuf(stdout,nullptr);url="http://127.0.0.1:"+std::string(getenv("REARC_TEST_PORT"))+"/test";ReArcCallbacks c{ready,event,nullptr,nullptr};ReArcEngineSetPageMessageCallback(message,nullptr);assert(ReArcEngineConfigure(1,&c,nullptr)==0);int r=ReArcEngineRun(argc,argv);assert(r==0&&stopped);return r;}}
