#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <cmath>
#include <set>
#include <string>
#include <stdio.h>
static uint64_t tabs[3],profiles[3];
static std::set<uint64_t> loaded, seen;
static int stage;
static bool stopped;
static std::string path;
static double factor(int i){double f;assert(ReArcTabGetZoomFactor(tabs[i],&f)==0);return f;}
static bool equal(double a,double b){return std::abs(a-b)<0.00001;}
static void shutdown_done(void*,ReArcStatus s,bool c){assert(s==0&&!c);stopped=true;puts("ZOOM runtime PASS");}
static void begin(){
 assert(equal(factor(0),getenv("REARC_ZOOM_SECOND")?2:1));assert(equal(factor(1),factor(0))&&equal(factor(2),1));
 assert(ReArcTabSetZoomFactor(tabs[0],NAN)==REARC_INVALID_ARGUMENT);
 assert(ReArcTabSetZoomFactor(tabs[0],INFINITY)==REARC_INVALID_ARGUMENT);
 assert(ReArcTabSetZoomFactor(tabs[0],0)==REARC_INVALID_ARGUMENT);
 assert(ReArcTabSetZoomFactor(tabs[0],5.1)==REARC_INVALID_ARGUMENT);
 stage=1;assert(ReArcTabSetZoomFactor(tabs[0],1.5)==0);assert(seen.empty());
}
static void zoom(void*,const ReArcZoomEvent* e){
 int i=0;while(i<3&&tabs[i]!=e->document.tab_id)++i;assert(i<3);
 assert(e->document.profile_id==profiles[i]&&e->document.content_generation&&e->document.document_generation);
 fprintf(stderr,"ZOOM stage=%d tab=%llu factor=%g\n",stage,e->document.tab_id,e->factor);
 if((stage==1&&equal(e->factor,1.5))||(stage==2&&equal(e->factor,2))){
  assert(i<2);seen.insert(e->document.tab_id);
  if(seen.size()==2){
   assert(equal(factor(2),1));seen.clear();
   if(stage==1){stage=2;assert(ReArcTabSetZoomFactor(tabs[1],2)==0);}
   else{stage=3;std::string url="http://localhost:"+path;assert(ReArcTabNavigate(tabs[0],url.c_str(),0)==0);}
  }
 }
}
static void event(void*,const ReArcTabEvent* e){
 if(e->kind!=1||!(e->changes&2)||!std::string(e->title).starts_with("probe:"))return;
 if(stage==0){loaded.insert(e->tab_id);if(loaded.size()==3)begin();}
 else if(stage==3&&e->tab_id==tabs[0]){assert(equal(factor(0),1));stage=4;assert(ReArcTabGoBack(tabs[0])==0);}
 else if(stage==4&&e->tab_id==tabs[0]){
  assert(equal(factor(0),2));stage=5;
  assert(ReArcTabClose(tabs[0],true,[](void*,ReArcStatus s,bool c){
   assert(s==0&&!c);double f;assert(ReArcTabGetZoomFactor(tabs[0],&f)==REARC_TAB_NOT_FOUND);
   assert(ReArcEngineShutdown(true,shutdown_done,nullptr)==0);
  },nullptr)==0);
 }
}
static void ready(void*,uint64_t p){
 assert(ReArcEngineHasFeature("page_zoom"));profiles[0]=profiles[1]=p;
 assert(ReArcProfileOpen("zoom-other",[](void*,ReArcStatus s,uint64_t p,bool otr){
  assert(s==0&&!otr);profiles[2]=p;
  for(int i=0;i<3;++i){std::string url="http://127.0.0.1:"+path;assert(ReArcTabCreate(profiles[i],i+1,url.c_str(),&tabs[i])==0);}
 },nullptr)==0);
}
int main(int argc,const char** argv){@autoreleasepool{path=std::string(getenv("REARC_TEST_PORT"))+"/test";ReArcCallbacks c{ready,event,nullptr,nullptr};ReArcEngineSetZoomCallback(zoom,nullptr);assert(ReArcEngineConfigure(1,&c,nullptr)==0);int r=ReArcEngineRun(argc,argv);assert(r==0&&stopped);return r;}}
