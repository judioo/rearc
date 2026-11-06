#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <functional>
#include <map>
#include <set>
#include <string>
// Loopback mutual TLS. Identities come from the test-only memory store
// (--rearc-test-client-cert-dir, net/data); no Keychain identity exists.
static uint64_t profile,tab,last;
static NSWindow* window;
static std::map<uint64_t,ReArcAttachment> leases;
static std::string base,p1,p2,fp_a,fp_d;
static int stage,requests;
static std::map<uint64_t,int> withdrawn;
static std::set<uint64_t> replaced_ids;
static bool stopped,cached_after_sign=true;
static const int64_t kExpiry=2240611199LL*1000000;  // 2040-12-31T23:59:59Z
static void later(int ms,std::function<void()> f){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)ms*NSEC_PER_MSEC),dispatch_get_main_queue(),^{f();});}
static std::string mtls(bool localhost,const std::string& port,const char* path){return std::string("https://")+(localhost?"localhost:":"127.0.0.1:")+port+path;}
static void navigate(std::string url){assert(ReArcTabNavigate(tab,url.c_str(),0)==REARC_OK);}
static void attach(uint64_t id){ReArcAttachment a{};assert(ReArcViewAttach(id,1,800,600,1,&a)==REARC_OK);[window.contentView addSubview:(__bridge NSView*)a.native_view];assert(ReArcViewSetVisible(id,a.attachment_id,true)==REARC_OK);leases[id]=a;}
static void create(std::string url){assert(ReArcTabCreate(profile,1,url.c_str(),&tab)==REARC_OK);attach(tab);}
static void close_tab(std::function<void()> f){
 assert(ReArcTabClose(tab,true,[](void* c,ReArcStatus s,bool cancelled){assert(!s&&!cancelled);auto* f=static_cast<std::function<void()>*>(c);(*f)();delete f;},new std::function<void()>(std::move(f)))==REARC_OK);
}
static void replaced(void*,const ReArcClientCertificateEvent* e){
 // Neither the superseded request's withdrawal nor any re-prompt arrives here.
 printf("CLIENTCERT replacement phase=%u id=%llu\n",e->phase,e->request_id);assert(false);
}
static void check_identities(const ReArcClientCertificateEvent* e,bool localhost,const std::string& port){
 assert(e->profile_id==profile&&e->tab_id==tab&&e->content_generation);
 assert(std::string(e->origin)==mtls(localhost,port,""));
 assert(e->identity_count==2&&e->identities);
 std::map<std::string,const ReArcClientCertificateIdentity*> by;
 for(size_t i=0;i<e->identity_count;++i){auto& id=e->identities[i];printf("CLIENTCERT identity subject=%s issuer=%s expiry_us=%lld fp=%s\n",id.subject,id.issuer,id.expiry_us,id.fingerprint);by[id.subject]=&id;}
 assert(by.contains("Client Cert A")&&by.contains("Client Cert D"));
 assert(std::string(by["Client Cert A"]->issuer)=="B CA"&&std::string(by["Client Cert D"]->issuer)=="E CA");
 assert(by["Client Cert A"]->expiry_us==kExpiry&&by["Client Cert D"]->expiry_us==kExpiry);
 assert(by["Client Cert A"]->fingerprint==fp_a&&by["Client Cert D"]->fingerprint==fp_d);
}
static void shutdown_pending(){
 assert(ReArcEngineShutdown(false,[](void*,ReArcStatus s,bool cancelled){
   assert(!s&&!cancelled);assert(withdrawn[last]==1);assert(ReArcClientCertificateRespond(last,nullptr)==REARC_NOT_FOUND);
   for(auto [id,a]:leases)ReArcViewRelease(a.native_view);
   puts("CLIENTCERT shutdown withdraws pending request before completion PASS");
   stopped=true;puts("CLIENTCERT PASS");
 },nullptr)==REARC_OK);
}
static void cert(void*,const ReArcClientCertificateEvent* e){
 printf("CLIENTCERT phase=%u id=%llu origin=%s count=%zu stage=%d\n",e->phase,e->request_id,e->origin,e->identity_count,stage);
 if(e->phase){assert(e->phase==1);++withdrawn[e->request_id];return;}
 ++requests;last=e->request_id;
 if(stage==1){
   check_identities(e,false,p1);puts("CLIENTCERT identity list subject/issuer/expiry/fingerprint PASS");
   assert(ReArcClientCertificateRespond(last,std::string(64,'0').c_str())==REARC_INVALID_ARGUMENT);
   assert(ReArcClientCertificateRespond(last,"ABC")==REARC_INVALID_ARGUMENT);
   assert(ReArcClientCertificateRespond(last,nullptr)==REARC_OK);
   assert(ReArcClientCertificateRespond(last,nullptr)==REARC_NOT_FOUND);
 }else if(stage==2){
   check_identities(e,false,p1);
   assert(ReArcClientCertificateRespond(last,fp_d.c_str())==REARC_OK);
   assert(ReArcClientCertificateRespond(last,fp_d.c_str())==REARC_NOT_FOUND);
 }else if(stage==3){assert(false);  // Selection is cached for the host and port.
 }else if(stage==4){
   check_identities(e,true,p1);
   later(100,[]{navigate(base+"/devtools");});
 }else if(stage==5){
   check_identities(e,true,p1);
   assert(ReArcClientCertificateRespond(last,fp_a.c_str())==REARC_OK);
   // Key acquisition is delayed 500 ms by the test identity; close inside it.
   later(150,[]{const uint64_t id=last;close_tab([id]{
     assert(withdrawn[id]==1&&ReArcClientCertificateRespond(id,fp_a.c_str())==REARC_NOT_FOUND);
     puts("CLIENTCERT close during private-key acquisition withdraws PASS");
     stage=6;create(mtls(true,p1,"/after-acquire"));});});
 }else if(stage==6){
   // The aborted acquisition cached nothing, so the host is asked again.
   check_identities(e,true,p1);assert(ReArcClientCertificateRespond(last,fp_a.c_str())==REARC_OK);
 }else if(stage==7){
   check_identities(e,false,p2);assert(ReArcClientCertificateRespond(last,fp_a.c_str())==REARC_OK);
   // Acquisition 500 ms, then signing is held for 1000 ms: close in between.
   later(1000,[]{puts("CLIENTCERT closing during signing");close_tab([]{
     puts("CLIENTCERT close during signing PASS");stage=8;later(1500,[]{create(mtls(false,p2,"/after-sign"));});});});
 }else if(stage==8){
   cached_after_sign=false;check_identities(e,false,p2);assert(ReArcClientCertificateRespond(last,fp_a.c_str())==REARC_OK);
 }else if(stage==9){
   check_identities(e,true,p2);replaced_ids.insert(last);
   ReArcEngineSetClientCertificateCallback(replaced,nullptr);
   assert(ReArcClientCertificateRespond(last,fp_a.c_str())==REARC_NOT_FOUND);
 }else if(stage==10){
   check_identities(e,true,p2);
   later(100,[]{shutdown_pending();});
 }else assert(false);
}
static void event(void*,const ReArcTabEvent* e){
 if(e->tab_id!=tab)return;assert(!e->is_crashed);
 // An aborted selection commits Chromium's ERR_SSL_CLIENT_AUTH_CERT_NEEDED page.
 if(e->kind==4||(e->kind==3&&e->is_error_page)){
   printf("CLIENTCERT failed kind=%u error=%d url=%s stage=%d\n",e->kind,e->error_code,e->url,stage);
   if(e->kind==4)return;  // Superseded navigations (stages 4/5/7) abort.
   // Commit events carry no net error; the harness checks -110 in the net log.
   if(stage==0){stage=1;puts("CLIENTCERT no callback aborts PASS");ReArcEngineSetClientCertificateCallback(cert,nullptr);later(100,[]{navigate(mtls(false,p1,"/cancel"));});}
   else if(stage==1){
     // No cached null choice and no error-page auto-reload: nobody asks again.
     stage=101;const int seen=requests;
     later(1500,[seen]{assert(requests==seen&&!withdrawn.contains(last));stage=2;
       puts("CLIENTCERT invalid fingerprints rejected; host cancel aborts once, no re-prompt PASS");navigate(mtls(false,p1,"/select"));});}
   else if(stage==9&&replaced_ids.contains(last)){
     stage=109;later(1500,[]{stage=10;assert(!withdrawn.contains(last));puts("CLIENTCERT callback replacement aborts; stale reply rejected; no queued old events PASS");
       ReArcEngineSetClientCertificateCallback(cert,nullptr);navigate(mtls(true,p2,"/shutdown"));});
   }
   return;
 }
 if(e->kind!=1||!(e->changes&2))return;
 std::string title=e->title;printf("CLIENTCERT title=%s stage=%d\n",title.c_str(),stage);
 if(stage==2&&title=="mtls:Client Cert D:/select"){
   stage=3;puts("CLIENTCERT selected identity reaches server after delayed key acquisition/signing PASS");later(100,[]{navigate(mtls(false,p1,"/cached"));});
 }else if(stage==3&&title=="mtls:Client Cert D:/cached"){
   stage=4;puts("CLIENTCERT Chromium caches selection for host/port PASS");later(100,[]{navigate(mtls(true,p1,"/navigate"));});
 }else if(stage==4&&title=="devtools-ready"){
   assert(withdrawn[last]==1&&ReArcClientCertificateRespond(last,fp_a.c_str())==REARC_NOT_FOUND);
   puts("CLIENTCERT navigation withdraws pending request PASS");stage=5;later(100,[]{navigate(mtls(true,p1,"/acquire"));});
 }else if(stage==6&&title=="mtls:Client Cert A:/after-acquire"){
   stage=7;puts("CLIENTCERT aborted acquisition caches nothing; reselect PASS");later(100,[]{navigate(mtls(false,p2,"/sign"));});
 }else if(stage==8&&title=="mtls:Client Cert A:/after-sign"){
   printf("CLIENTCERT after signing close cached=%d PASS\n",cached_after_sign);
   stage=9;later(100,[]{navigate(mtls(true,p2,"/replace"));});
 }
}
static void ready(void*,uint64_t p){
 profile=p;assert(ReArcEngineHasFeature("client_certificates")&&ReArcEngineABIMinorVersion()>=41);
 assert(ReArcClientCertificateRespond(12345,nullptr)==REARC_NOT_FOUND);
 assert(ReArcClientCertificateRespond(12345,"short")==REARC_INVALID_ARGUMENT);
 window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,800,600) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
 assert(ReArcWindowRegister(1,(__bridge void*)window)==REARC_OK);[window makeKeyAndOrderFront:nil];
 create(mtls(false,p1,"/none"));
}
int main(int argc,const char** argv){@autoreleasepool{
 setbuf(stdout,nullptr);base="http://127.0.0.1:"+std::string(getenv("REARC_TEST_PORT"));
 std::string ports=getenv("REARC_TEST_MTLS_PORTS");p1=ports.substr(0,ports.find(','));p2=ports.substr(ports.find(',')+1);
 fp_a=getenv("REARC_CLIENT_FP_A");fp_d=getenv("REARC_CLIENT_FP_D");
 ReArcCallbacks c{ready,event,nullptr,nullptr};assert(ReArcEngineConfigure(1,&c,nullptr)==REARC_OK);
 int r=ReArcEngineRun(argc,argv);assert(!r&&stopped);return r;
}}
