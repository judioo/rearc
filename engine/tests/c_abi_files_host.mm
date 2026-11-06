#import <AppKit/AppKit.h>
#include "rearc_engine_abi.h"
#include <assert.h>
#include <stdio.h>
#include <string>
#include <fstream>
static uint64_t tab, profile, pending;
static NSWindow* window;
static ReArcAttachment lease{};
static std::string base, root, first, second, folder, save;
static int step, requests, cancels;
static bool stopped, busy;
static void eval(const std::string& s,ReArcScriptCallback2 cb){assert(ReArcTabEvaluateScript2(tab,s.c_str(),1,nullptr,10000,cb,nullptr)==0);}
static void click(void*,ReArcStatus s,uint64_t,uint64_t,uint8_t* png,size_t){
 assert(s==0);ReArcBufferFree(png);NSPoint point=[(__bridge NSView*)lease.native_view convertPoint:NSMakePoint(30,270) toView:nil];
 for(auto type:{NSEventTypeLeftMouseDown,NSEventTypeLeftMouseUp}){NSEvent* e=[NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];NSView* hit=[window.contentView hitTest:point];if(type==NSEventTypeLeftMouseDown)[hit mouseDown:e];else[hit mouseUp:e];}
}
static void install(){
 const char* attrs=step==1?"multiple":step==2?"webkitdirectory":"";
 std::string source="document.body.innerHTML=`<button style='position:absolute;left:0;top:0;width:400px;height:300px' onclick=\\\"document.querySelector('input').click()\\\">pick</button><input type=file accept='.txt,text/plain' "+std::string(attrs)+" hidden>`;var i=document.querySelector('input');i.onchange=()=>document.title='files:'+i.files.length+':'+Array.from(i.files).map(f=>f.webkitRelativePath||f.name).sort().join(',');i.oncancel=()=>document.title='cancelled';true";
 // Template HTML uses literal quotes, not escaped HTML entities.
 auto pos=source.find("\\\"");while(pos!=std::string::npos){source.replace(pos,2,"\"");pos=source.find("\\\"");}
 eval(source,[](void*,const ReArcScriptResult* r){assert(r->status==0);assert(ReArcTabCaptureSnapshot(tab,0,click,nullptr)==0);});
}
static void shutdown(void*,ReArcStatus s,bool c){assert(s==0&&!c);ReArcViewRelease(lease.native_view);assert(requests==7&&cancels==3);assert(ReArcEngineShutdown(true,[](void*,ReArcStatus s,bool c){assert(s==0&&!c);stopped=true;puts("FILES open/multiple/folder/save + cancel/navigation/close PASS");},nullptr)==0);}
static void chooser(void*,const ReArcFileChooserEvent* e){
 printf("FILES step=%d phase=%u mode=%u id=%llu\n",step,e->phase,e->mode,e->request_id);
 assert(e->tab_id==tab&&e->profile_id==profile&&e->request_id);
 if(e->phase){++cancels;assert(ReArcFileChooserRespond(e->request_id,true,nullptr,0)==REARC_NOT_FOUND);return;}
 ++requests;pending=e->request_id;
 const char* bad="relative";assert(ReArcFileChooserRespond(pending,false,&bad,1)==REARC_INVALID_ARGUMENT);
 if(step<=2){assert(e->mode==unsigned(step)&&e->accept_type_count==2&&((std::string(e->accept_types[0])+","+e->accept_types[1])==".txt,text/plain"||(std::string(e->accept_types[0])+","+e->accept_types[1])=="text/plain,.txt"));
 const char* paths[]={first.c_str(),second.c_str()};if(step==2)paths[0]=folder.c_str();
 assert(ReArcFileChooserRespond(pending,false,paths,step==1?2:1)==0);
 assert(ReArcFileChooserRespond(pending,false,paths,1)==REARC_NOT_FOUND);return;}
 if(step==3){assert(ReArcFileChooserRespond(pending,true,nullptr,0)==0);return;}
 if(step==4){assert(e->mode==4&&std::string(e->default_path).ends_with("rearc-small.bin"));const char* p=save.c_str();assert(ReArcFileChooserRespond(pending,false,&p,1)==0);return;}
 if(step==5){step=6;assert(ReArcTabNavigate(tab,(base+"/visit-b").c_str(),0)==0);return;}
 if(step==7){step=8;assert(ReArcTabClose(tab,true,shutdown,nullptr)==0);return;}
 assert(false);
}
static void download(void*,const ReArcDownloadEvent* e){if(step!=4||e->kind!=2)return;assert(std::string(e->target_path)==save);std::ifstream f(save,std::ios::binary|std::ios::ate);assert(f.tellg()==65536);step=5;busy=false;install();}
static void event(void*,const ReArcTabEvent* e){
 if(e->tab_id!=tab||e->kind!=1||!(e->changes&2))return;
 std::string t=e->title;printf("TITLE step=%d %s\n",step,t.c_str());
 if(step==0&&t=="ReArc visit A"&&!busy){busy=true;install();}
 else if(step<=2&&t.starts_with("files:")){
 if(step==0)assert(t=="files:1:a.txt");if(step==1)assert(t=="files:2:a.txt,b.txt");if(step==2)assert(t=="files:1:folder/sub/c.txt");++step;install();}
 else if(step==3&&t=="cancelled"){step=4;assert(ReArcDownloadSetPolicy(profile,root.c_str(),1)==0);eval("location.href='"+base+"/download/small';true",[](void*,const ReArcScriptResult* r){assert(r->status==0);});}
 else if(step==6&&t=="ReArc visit B"){step=7;install();}
}
static void ready(void*,uint64_t p){profile=p;assert(ReArcEngineABIMinorVersion()>=19&&ReArcEngineHasFeature("file_chooser"));ReArcEngineSetFileChooserCallback(chooser,nullptr);ReArcEngineSetDownloadCallback(download,nullptr);
 assert(ReArcTabCreate(p,1,(base+"/visit-a").c_str(),&tab)==0);window=[[NSWindow alloc]initWithContentRect:NSMakeRect(0,0,400,300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];assert(ReArcWindowRegister(1,(__bridge void*)window)==0);assert(ReArcViewAttach(tab,1,400,300,1,&lease)==0);[window.contentView addSubview:(__bridge NSView*)lease.native_view];[window makeKeyAndOrderFront:nil];assert(ReArcViewSetVisible(tab,lease.attachment_id,true)==0);}
int main(int argc,const char** argv){@autoreleasepool{setbuf(stdout,nullptr);base="http://127.0.0.1:"+std::string(getenv("REARC_TEST_PORT"));root=getenv("REARC_FILES_DIR");first=root+"/a.txt";second=root+"/b.txt";folder=root+"/folder";save=root+"/chosen.bin";ReArcCallbacks c{ready,event,nullptr,nullptr};assert(ReArcEngineConfigure(1,&c,nullptr)==0);int r=ReArcEngineRun(argc,argv);assert(r==0&&stopped);return r;}}
