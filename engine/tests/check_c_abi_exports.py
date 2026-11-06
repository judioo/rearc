#!/usr/bin/env python3
import re,pathlib,subprocess,sys
root=pathlib.Path(__file__).resolve().parents[1]/'chromium/src';b=root/'chrome/browser/rearc_bridge'
headers=[b/'rearc_engine_abi.h',b/'rearc_engine_entry_mac.h']
symbols=[]
for h in headers:symbols+=re.findall(r'REARC_ENGINE_EXPORT\s+[\w* ]+\s+(ReArc\w+)\(',h.read_text())
framework=root/'out/ReArc-dev-arm64/Chromium Framework.framework/Chromium Framework'
# In a component build the framework reexports libchrome_dll. nm records the
# reexport LC command, while symbols live in the dylib. Check both and dyld.
with open(sys.argv[1],'w') as log:
 for binary in [framework,root/'out/ReArc-dev-arm64/libchrome_dll.dylib']:
  r=subprocess.run(['nm','-gU',str(binary)],capture_output=True,text=True,check=True)
  log.write(f'nm -gU {binary}\n'+r.stdout+'\n')
  found=set(re.findall(r'\b(_ReArc\w+)\b',r.stdout))
  print(binary, len(found),'defined ABI symbols')
  if 'libchrome' in str(binary):assert all('_'+x in found for x in symbols),set(symbols)-set(x[1:] for x in found)
 # dyld reexports must make every symbol available when opening the framework.
 import ctypes
 lib=ctypes.CDLL(str(framework.resolve()))
 for s in symbols:getattr(lib,s);log.write('DLSYM PASS '+s+'\n')
 print('PASS',len(symbols),'symbols via framework dyld reexport')

 # Query the loaded framework too, to catch a stale/version-mismatched binary.
 lib.ReArcEngineABIVersion.restype=ctypes.c_uint32
 lib.ReArcEngineABIMinorVersion.restype=ctypes.c_uint32
 lib.ReArcEngineBridgeVersion.restype=ctypes.c_char_p
 lib.ReArcEngineVersion.restype=ctypes.c_char_p
 major=lib.ReArcEngineABIVersion();minor=lib.ReArcEngineABIMinorVersion()
 expected=int(re.search(r'REARC_ABI_MINOR_VERSION = (\d+)',headers[0].read_text()).group(1))
 assert major==1 and minor==expected,(major,minor,expected)
 version=f'LOADED ABI {major}.{minor} bridge {lib.ReArcEngineBridgeVersion().decode()} Chromium {lib.ReArcEngineVersion().decode()} PASS'
 print(version);log.write(version+'\n')
