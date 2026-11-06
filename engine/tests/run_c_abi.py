#!/usr/bin/env python3
"""Native ABI integration tests; run after build.sh, without an active build."""
import os
import hashlib
import json
import sys
from pathlib import Path
import shutil
import struct
import sqlite3
import subprocess
import tempfile
import threading
import time
import socket
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ENGINE = Path(__file__).resolve().parents[1]
SRC = ENGINE / "chromium/src"
OUT = SRC / "out/ReArc-dev-arm64"
BRIDGE = Path(os.environ.get("REARC_TEST_ABI_HEADER_DIR", SRC / "chrome/browser/rearc_bridge"))


def build_gate():
    # The bracket keeps the probe from matching its own command line.
    # Wait (bounded) for real builders and old wrappers with literal text.
    deadline = time.monotonic() + 1800
    while True:
        raw = subprocess.run(["pgrep", "-fl", "siso[ ]ninja"], capture_output=True, text=True)
        if raw.returncode == 1 or time.monotonic() > deadline:
            break
        time.sleep(10)
    assert raw.returncode == 1, raw.stdout
    # Also detect builder processes independent of their command line.
    process = subprocess.run(["pgrep", "-lx", "siso|ninja|autoninja"], capture_output=True)
    assert process.returncode == 1, process.stdout.decode()


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


STORE_CRXS = {
    "jlnmailbicnpnbggmhfebbomaddckncf": SRC / "components/test/data/crx_file/valid_test_publisher.crx3",
    "enfkhcelefdadlmkffamgdlgplcionje": SRC / "chrome/test/data/extensions/api_test/webstore_private/extension.crx",
}


def store_manifest(crx):
    """The manifest inside a CRX3/CRX2 archive (the zip after its header)."""
    import io, zipfile
    data = crx.read_bytes()
    version, = struct.unpack("<I", data[4:8])
    if version == 3:
        offset = 12 + struct.unpack("<I", data[8:12])[0]
    else:
        key, sig = struct.unpack("<II", data[8:16])
        offset = 16 + key + sig
    return zipfile.ZipFile(io.BytesIO(data[offset:])).read("manifest.json").decode()


class Fixture(BaseHTTPRequestHandler):
    suggest_queries = []
    auth_seen = set()
    link_referrers = []

    def do_GET(self):
        if self.path == "/link-result":
            Fixture.link_referrers.append(self.headers.get("Referer", ""))
        if self.path.startswith("/auth/"):
            from urllib.parse import urlsplit, parse_qs
            import base64, hashlib, re
            route = urlsplit(self.path)
            realm = parse_qs(route.query).get("realm", ["rearc"])[0]
            scheme = "Digest" if route.path.endswith("digest") else "Basic"
            auth = self.headers.get("Authorization", "")
            ok = auth == "Basic " + base64.b64encode(b"rearc:local-secret").decode() if scheme == "Basic" else False
            if scheme == "Digest" and auth.startswith("Digest "):
                fields = dict((k, v or token) for k, v, token in re.findall(r'(\w+)=(?:"([^"]*)"|([^, ]+))', auth[7:]))
                md5 = lambda x: hashlib.md5(x.encode()).hexdigest()
                ha1 = md5("rearc:" + realm + ":local-secret")
                ha2 = md5("GET:" + fields.get("uri", ""))
                expected = md5(ha1 + ":rearc-local-nonce:" + fields.get("nc", "") + ":" + fields.get("cnonce", "") + ":auth:" + ha2)
                ok = fields.get("username") == "rearc" and fields.get("realm") == realm and fields.get("response") == expected and fields.get("uri") == self.path
            # A new realm must challenge even if Chromium preemptively sends
            # previously cached Basic credentials for the shared /auth/ path.
            if self.path not in Fixture.auth_seen:
                Fixture.auth_seen.add(self.path)
                ok = False
            body = ("<!doctype html><title>auth-ok-" + realm + "</title>local authenticated").encode() if ok else b"<!doctype html><title>auth-denied</title>local denied"
            self.send_response(200 if ok else 401)
            if not ok:
                challenge = f'{scheme} realm="{realm}"'
                if scheme == "Digest": challenge += ', nonce="rearc-local-nonce", algorithm=MD5, qop="auth"'
                self.send_header("WWW-Authenticate", challenge)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers(); self.wfile.write(body); return
        if self.path.startswith("/download/"):
            return self.download()
        if self.path.startswith(("/suggest?", "/suggest-slow?")):
            from urllib.parse import parse_qs, urlsplit
            query = parse_qs(urlsplit(self.path).query).get("q", [""])[0]
            Fixture.suggest_queries.append(query)
            if self.path.startswith("/suggest-slow?"):
                time.sleep(8)
            body = json.dumps([query, [query + " suggestion one", query + " suggestion two"]]).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            return
        if self.path.startswith("/favicon"):
            body = (b"\x89PNG\r\n\x1a\n" +
                    chunk(b"IHDR", struct.pack(">IIBBBBB", 16, 16, 8, 2, 0, 0, 0)) +
                    chunk(b"IDAT", zlib.compress((b"\0" + b"\x11\x22\x33" * 16) * 16)) +
                    chunk(b"IEND", b""))
            mime = "image/png"
        elif self.path.startswith("/visit-"):
            letter = self.path[-1].upper().encode()
            body = b"<!doctype html><title>ReArc visit " + letter + b"</title><p>visit " + letter
            mime = "text/html"
        elif self.path == "/pip":
            body = (b"<!doctype html><title>pip</title><body style='margin:0'>"
                    b"<video id=v muted playsinline style='position:absolute;left:0;top:0;width:400px;height:300px'></video><script>"
                    b"const c=document.createElement('canvas');c.width=320;c.height=180;const g=c.getContext('2d');let n=0;"
                    b"setInterval(()=>{g.fillStyle='hsl('+(n++*10%360)+',80%,50%)';g.fillRect(0,0,320,180)},50);"
                    b"const s=c.captureStream(20);const ac=new AudioContext();const o=ac.createOscillator();"
                    b"const d=ac.createMediaStreamDestination(),q=ac.createGain();q.gain.value=0;o.connect(q);q.connect(d);o.start();s.addTrack(d.stream.getAudioTracks()[0]);"
                    b"v.srcObject=s;v.onloadedmetadata=()=>v.play().then(()=>document.title='pip:ready');"
                    b"v.onclick=()=>v.requestPictureInPicture().catch(e=>document.title='pip:err:'+e.name);"
                    b"v.addEventListener('enterpictureinpicture',()=>document.title='pip:in');"
                    b"v.addEventListener('leavepictureinpicture',()=>document.title='pip:out');"
                    # A recorded WebM is a persistent player with audio: Chromium's media
                    # session offers browser-initiated PiP for it (not for MediaStreams).
                    b"window.toFile=()=>new Promise(r=>{const m=new MediaRecorder(s,{mimeType:'video/webm;codecs=vp8,opus'});"
                    b"const parts=[];m.ondataavailable=e=>parts.push(e.data);m.onstop=()=>{v.srcObject=null;v.loop=true;v.muted=false;"
                    b"v.src=URL.createObjectURL(new Blob(parts,{type:'video/webm'}));v.onloadedmetadata=null;v.play().then(()=>r(true))};"
                    b"m.start();setTimeout(()=>m.stop(),6500)});</script>")
            mime = "text/html"
        elif self.path == "/drop":
            body = (b"<!doctype html><title>drop</title><body style='margin:0;height:100vh'><script>window.log=[];"
                    b"for(const t of ['dragenter','dragover'])document.addEventListener(t,e=>{e.preventDefault();"
                    b"if(t==='dragenter')log.push('enter:'+[...e.dataTransfer.types].join(','))});"
                    b"document.addEventListener('drop',async e=>{e.preventDefault();const d=e.dataTransfer,f=[...d.files];"
                    b"let c='';if(f[0])c=(await f[0].text()).slice(0,40);"
                    b"log.push('drop|types='+[...d.types].join(',')+'|text='+d.getData('text/plain')+'|uri='+d.getData('text/uri-list')"
                    b"+'|files='+f.map(x=>x.name+':'+x.type+':'+x.size).join(';')+'|content='+c)});</script>")
            mime = "text/html"
        elif self.path.startswith("/print"):
            body = (b"<!doctype html><title>print</title><style>div{height:900px;break-after:page}</style>"
                    b"<div>page one</div><div>page two</div><div>page three</div>"
                    b"<script>addEventListener('beforeprint',()=>document.title='beforeprint');"
                    b"addEventListener('afterprint',()=>document.title+='+afterprint')</script>")
            mime = "text/html"
        elif self.path == "/webstore" or self.path.startswith("/webstore/extension.crx"):
            # Fake Web Store (--apps-gallery-url=http://localhost:PORT/) with
            # Chromium's own test CRXs: components' valid_test_publisher.crx3
            # carries the test publisher proof the gallery override accepts;
            # webstore_private's extension.crx has none (install must fail).
            if self.path == "/webstore":
                manifests = {store_id: store_manifest(path) for store_id, path in STORE_CRXS.items()}
                body = ("<!doctype html><title>store</title><script>const manifests=" + json.dumps(manifests) + ";"
                        "const done=ok=>chrome.runtime.lastError?'error:'+chrome.runtime.lastError.message:ok;"
                        "window.begin=id=>new Promise(r=>chrome.webstorePrivate.beginInstallWithManifest3({id,manifest:manifests[id]},x=>r(done('ok:'+x))));"
                        "window.complete=id=>new Promise(r=>chrome.webstorePrivate.completeInstall(id,()=>r(done('complete'))));"
                        "</script>").encode()
                mime = "text/html"
            else:
                from urllib.parse import parse_qs, urlsplit
                x = parse_qs(urlsplit(self.path).query).get("x", [""])[0]
                store_id = parse_qs(x).get("id", [""])[0]
                body = STORE_CRXS[store_id].read_bytes()
                mime = "application/x-chrome-extension"
        elif self.path == "/perf":
            # perf-0: text and an inline image give FCP, LCP and a load event.
            body = (b"<!doctype html><title>perf</title><body style='margin:0;font:20px -apple-system'>"
                    b"<h1 style='font-size:64px'>ReArc perf page</h1><p>" + b"Loopback text. " * 200 +
                    b"<p><img width=300 height=200 src='data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%22300%22 height=%22200%22%3E%3Crect width=%22300%22 height=%22200%22 fill=%22%232a6%22/%3E%3C/svg%3E'>")
            mime = "text/html"
        elif self.path == "/devtools":
            body = b'<!doctype html><title>devtools-ready</title><body style="margin:0"><p id="pick">select me</p>'
            mime = "text/html"
        elif self.path == "/link-open":
            body = (b'<!doctype html><title>links-ready</title><body style="margin:0">'
                    b'<a href="/link-result" style="position:absolute;left:0;top:10px;width:400px;height:40px">ordinary link</a>'
                    b'<a href="/link-result" rel="noreferrer" style="position:absolute;left:0;top:70px;width:400px;height:40px">no referrer link</a></body>')
            mime = "text/html"
        elif self.path == "/link-result":
            body = b'<!doctype html><title>link-result</title>opened by host'
            mime = "text/html"
        elif self.path.startswith("/save"):
            def field(name, auto):
                return f'<input id="{name}" name="{name}" autocomplete="{auto}">'.encode()
            body = (b'<!doctype html><title>save</title><form id="address" action="/welcome">' +
                    b''.join(field(n,a) for n,a in [('name','name'),('street','street-address'),('city','address-level2'),
                        ('state','address-level1'),('zip','postal-code'),('email','email'),('phone','tel')]) +
                    b'<select id="country" name="country" autocomplete="country"><option value="US" selected>United States</option></select></form>' +
                    b'<form id="card" action="/welcome">' + field('ccname','cc-name') + field('ccnum','cc-number') + field('ccexp','cc-exp') + b'</form>')
            mime = "text/html"
        elif self.path == "/autofill":
            # Fields at fixed CSS positions so the host can check view bounds.
            def field(name, auto, top):
                return (f'<input id="{name}" name="{name}" autocomplete="{auto}" style="position:absolute;'
                        f'left:10px;top:{top}px;width:300px;height:30px;box-sizing:border-box">').encode()
            body = (b'<!doctype html><title>autofill</title><body style="margin:0">'
                    b'<form id="a" action="/welcome" method="get">' + field("name", "name", 10) +
                    field("street", "street-address", 60) + field("city", "address-level2", 110) +
                    field("zip", "postal-code", 160) + field("email", "email", 210) + b'</form>'
                    b'<form id="c" action="/welcome" method="get">' + field("ccname", "cc-name", 300) +
                    field("ccnum", "cc-number", 350) + field("ccexp", "cc-exp", 400) + b'</form>')
            mime = "text/html"
        elif self.path == "/ext":
            body = b"<!doctype html><title>ext</title><p>extension fixture page"
            mime = "text/html"
        elif self.path.startswith("/search?"):
            body = b"<!doctype html><title>ReArc search</title><p>results"
            mime = "text/html"
        elif self.path == "/find":
            body = b"<!doctype html><title>find</title><p>alpha Alpha ALPHA gamma alpha</p>"
            mime = "text/html"
        elif self.path == "/login":
            body = (b'<!doctype html><title>login</title><form action="/welcome" method="get">'
                    b'<input id="u" name="u" autocomplete="username" style="position:absolute;left:0;top:0;width:300px">'
                    b'<input id="p" name="p" type="password" autocomplete="current-password" style="position:absolute;left:0;top:60px;width:300px">'
                    b'<script>window.__c=[];for(const t of ["mousedown","click","submit"])addEventListener(t,e=>__c.push(t),true)</script>'
                    b'<button id="s" type="submit" style="position:absolute;left:0;top:200px;width:300px;height:100px">Sign in</button></form>')
            mime = "text/html"
        elif self.path.startswith("/welcome"):
            body = b"<!doctype html><title>welcome</title><p>signed in"
            mime = "text/html"
        else:
            body = b'''<!doctype html><html><head><link rel="icon" href="/favicon.png"><script>
const pageWorld = typeof rearcSecret === 'undefined';
let hadStyle=false;
new MutationObserver(()=>{
 const count=document.querySelectorAll('style[data-rearc-abi]').length;
 if(count)hadStyle=true;
 else if(hadStyle&&document.documentElement.getAttribute('data-rearc-abi-plan')==='[]'){
  hadStyle=false;window.dispatchEvent(new PageTransitionEvent('pageshow'));
  document.title='removed:'+document.querySelectorAll('style[data-rearc-abi]').length;
 }
}).observe(document.documentElement,{childList:true,subtree:true,attributes:true});
document.addEventListener('DOMContentLoaded',()=>{
 document.title='probe:'+document.documentElement.dataset.start+':'+document.documentElement.dataset.end+':'+pageWorld+':'+getComputedStyle(document.body).backgroundColor;
});
</script></head><body style="margin:0;height:2200px"><a href="https://example.com/peek" style="display:block;width:500px;height:80px">Shift click</a><p>ABI snapshot fixture</p></body></html>'''
            mime = "text/html"
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def download(self):
        # small completes; slow trickles for pause/resume/cancel; broken drops
        # the connection early so Chromium interrupts the item.
        name = self.path.rsplit("/", 1)[1]
        size = 65536 if name == "small" or name.startswith("danger-") else 1048576
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        extension = "sh" if name.startswith("danger-") else "bin"
        self.send_header("Content-Disposition", f'attachment; filename="rearc-{name}.{extension}"')
        self.send_header("Content-Length", str(size))
        self.end_headers()
        try:
            if name == "small" or name.startswith("danger-"):
                self.wfile.write(b"a" * size)
            elif name == "slow":
                for _ in range(size // 16384):
                    self.wfile.write(b"s" * 16384)
                    self.wfile.flush()
                    time.sleep(0.05)
            else:
                self.wfile.write(b"b" * 131072)
                self.wfile.flush()
                self.connection.shutdown(socket.SHUT_RDWR)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        self.close_connection = True

    def log_message(self, *args):
        pass


def write_extensions(root):
    """Local unpacked MV3 fixtures for the extensions host (never the real store)."""
    cs = root / "cs"
    cs.mkdir(parents=True, exist_ok=True)
    (cs / "manifest.json").write_text(json.dumps({
        "name": "ReArc content script fixture", "version": "1.0", "manifest_version": 3,
        "background": {"service_worker": "bg.js"},
        "permissions": ["webNavigation", "scripting"],
        "host_permissions": ["http://127.0.0.1/*"],
        "content_scripts": [{"matches": ["http://127.0.0.1/ext*"], "js": ["cs.js"], "run_at": "document_end"}],
        "options_page": "options.html",
    }))
    (cs / "options.html").write_text("<!doctype html><title>options</title>")
    (cs / "cs.js").write_text(
        "const root=document.documentElement;root.dataset.rearcCs='ran';"
        "chrome.runtime.onMessage.addListener((m,s,send)=>{if(m.ping){root.dataset.rearcPing=m.ping;send({pong:1});}});"
        "window.addEventListener('message',e=>{if(e.source===window&&e.data&&e.data.route)chrome.runtime.sendMessage(e.data,r=>{root.dataset.routing=r});});"
        "chrome.runtime.sendMessage({hello:1},r=>{root.dataset.rearcReply=JSON.stringify(r);});")
    (cs / "bg.js").write_text(
        "const nav={};"
        "chrome.webNavigation.onCommitted.addListener(d=>{if(d.frameId===0)nav[d.tabId]=d.url;});"
        "chrome.runtime.onMessage.addListener((m,sender,send)=>{const tabId=sender.tab?sender.tab.id:-1;"
        "if(m.route){(async()=>{"
        "const q=await chrome.tabs.query({currentWindow:true,active:true});if(q.length!==1)throw Error('active query:'+JSON.stringify(q));"
        "const original=q[0],win=await chrome.windows.getCurrent({populate:true});if(win.tabs.length!==1||win.id!==original.windowId)throw Error('window query');"
        "const created=await chrome.tabs.create({url:m.base+'/visit-a',active:false,openerTabId:original.id});"
        "const got=await chrome.tabs.get(created.id);if(got.active||got.windowId!==win.id)throw Error('get');"
        "const updated=await chrome.tabs.update(created.id,{url:m.base+'/visit-b',active:true});if(!updated.active)throw Error('update');"
        "await chrome.runtime.openOptionsPage();"
        "const nw=await chrome.windows.create({url:'about:blank'});if(nw.id===win.id||nw.tabs.length!==1)throw Error('create window');"
        "const list=await chrome.windows.getAll({populate:true});if(list.length!==2)throw Error('window list');"
        "const single=await chrome.windows.get(nw.id,{populate:true});if(single.tabs[0].id!==nw.tabs[0].id)throw Error('window get');"
        "const focused=await chrome.windows.getLastFocused();if(focused.id!==nw.id)throw Error('last focused');"
        "const filtered=await chrome.tabs.query({windowId:nw.id,active:true});if(filtered.length!==1)throw Error('filter');"
        "await chrome.tabs.remove(created.id);await chrome.tabs.remove(nw.tabs[0].id);"
        "try{await chrome.tabs.get(created.id);throw Error('still present')}catch(e){if(e.message==='still present')throw e}"
        "try{await chrome.tabs.create({url:m.base+'/cancel'});throw Error('not cancelled')}catch(e){if(e.message==='not cancelled')throw e}"
        "return 'routing-pass';})().then(r=>send(r),e=>send('failure:'+e.message));return true;}"

        "const fail=p=>p.then(()=>'opened',e=>'error:'+e.message);"
        "Promise.all([fail(chrome.tabs.create({url:'about:blank'})),fail(chrome.runtime.openOptionsPage())])"
        ".then(([create,options])=>send({tabId,nav:nav[tabId]||null,create,options}));"
        "if(tabId>0)chrome.tabs.sendMessage(tabId,{ping:'from-bg'}).then(r=>chrome.scripting.executeScript("
        "{target:{tabId},func:x=>{document.documentElement.dataset.rearcExec=x;},args:[JSON.stringify(r)]}));return true;});")
    act = root / "act"
    act.mkdir(exist_ok=True)
    (act / "manifest.json").write_text(json.dumps({
        "name": "ReArc popup action fixture", "version": "1.0", "manifest_version": 3,
        "background": {"service_worker": "bg.js"},
        "action": {"default_title": "ReArc popup", "default_popup": "popup.html",
                   "default_icon": {"16": "icon16.png", "32": "icon32.png"}},
    }))
    (act / "icon16.png").write_bytes(png_icon(16, (0xd0, 0x30, 0x30)))
    (act / "icon32.png").write_bytes(png_icon(32, (0xd0, 0x30, 0x30)))
    (act / "bg.js").write_text(
        "const badge=()=>{chrome.action.setBadgeText({text:'7'});chrome.action.setBadgeBackgroundColor({color:'#ff0000'});};"
        "chrome.runtime.onInstalled.addListener(badge);chrome.runtime.onStartup.addListener(badge);")
    # 320x180 of content; the popup reports its view type and closes itself.
    (act / "popup.html").write_text(
        "<!doctype html><title>popup</title><body style='margin:0'><div style='width:320px;height:180px'>popup</div>"
        "<script src='popup.js'></script>")
    (act / "popup.js").write_text(
        "document.title='popup:'+chrome.extension.getViews({type:'popup'}).length;setTimeout(()=>window.close(),2500);")
    click = root / "click"
    click.mkdir(exist_ok=True)
    (click / "manifest.json").write_text(json.dumps({
        "name": "ReArc click action fixture", "version": "1.0", "manifest_version": 3,
        "background": {"service_worker": "bg.js"}, "permissions": ["activeTab", "scripting"],
        "action": {"default_title": "ReArc click"},
    }))
    # Only activeTab (granted by the host's run) lets it script the page.
    (click / "bg.js").write_text(
        "chrome.action.onClicked.addListener(tab=>chrome.scripting.executeScript({target:{tabId:tab.id},"
        "func:()=>{document.documentElement.dataset.rearcClicked='yes';}}));")
    drop = root / "drop"
    drop.mkdir(exist_ok=True)
    (drop / "manifest.json").write_text(json.dumps({
        "name": "ReArc dropped CRX fixture", "version": "1.0", "manifest_version": 3,
        "permissions": ["tabs"], "icons": {"128": "icon.png"},
    }))
    (drop / "icon.png").write_bytes(png_icon(128, (0x20, 0x80, 0xd0)))
    crx = root / "dropped.crx"
    os.environ["REARC_DROP_CRX_ID"] = pack_crx3(drop, crx, root / "dropped.pem")
    os.environ["REARC_DROP_CRX"] = str(crx)
    return [cs, act, click]


def pack_crx3(source, out, key):
    """Packs `source` as a CRX3 signed with a fresh local RSA key (openssl).
    Returns the extension ID. Test-only: no publisher proof, so Chromium
    accepts it only through off-store paths (chrome://extensions drops)."""
    import io, zipfile, hashlib
    subprocess.run(["openssl", "genrsa", "-out", str(key), "2048"], check=True, capture_output=True)
    public = subprocess.run(["openssl", "rsa", "-in", str(key), "-pubout", "-outform", "DER"],
                            check=True, capture_output=True).stdout
    crx_id = hashlib.sha256(public).digest()[:16]
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for item in sorted(source.rglob("*")):
            if item.is_file():
                archive.write(item, item.relative_to(source).as_posix())
    archive = buffer.getvalue()
    def varint(n):
        out = b""
        while True:
            byte = n & 0x7f
            n >>= 7
            out += bytes([byte | (0x80 if n else 0)])
            if not n:
                return out
    def field(number, data):
        return varint(number << 3 | 2) + varint(len(data)) + data
    signed = field(1, crx_id)
    message = b"CRX3 SignedData\x00" + struct.pack("<I", len(signed)) + signed + archive
    signature = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(key)], input=message,
                               check=True, capture_output=True).stdout
    header = field(2, field(1, public) + field(2, signature)) + field(10000, signed)
    out.write_bytes(b"Cr24" + struct.pack("<II", 3, len(header)) + header + archive)
    return "".join(chr(97 + (b >> 4)) + chr(97 + (b & 15)) for b in crx_id)


def png_icon(size, rgb):
    row = b"\0" + bytes(rgb) * size
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(row * size)) + chunk(b"IEND", b""))


def https_fixture(workspace):
    """Loopback HTTPS for secure-context autofill (cards). The self-signed
    certificate is accepted only through --ignore-certificate-errors-spki-list
    for this run; nothing reaches the Keychain."""
    import base64, hashlib, ssl
    key, cert = workspace / "https-key.pem", workspace / "https-cert.pem"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key),
                    "-out", str(cert), "-days", "2", "-subj", "/CN=127.0.0.1"], check=True, capture_output=True)
    public = subprocess.run(["openssl", "x509", "-in", str(cert), "-pubkey", "-noout"], check=True, capture_output=True).stdout
    der = subprocess.run(["openssl", "pkey", "-pubin", "-outform", "DER"], input=public, check=True, capture_output=True).stdout
    spki = base64.b64encode(hashlib.sha256(der).digest()).decode()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(str(cert), str(key))
    server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, spki


CLIENT_CERTS = SRC / "net/data/ssl/certificates"


class MutualTLS(BaseHTTPRequestHandler):
    """Loopback HTTPS that requires a client certificate chaining to
    net/data's C Root CA and echoes the presented leaf's CN."""
    served = []
    handshake_failures = 0

    def handle(self):
        import ssl
        self.request.settimeout(60)
        try:
            self.request.do_handshake()
        except (ssl.SSLError, OSError):
            MutualTLS.handshake_failures += 1  # Aborted selection or closed tab.
            return
        super().handle()

    def do_GET(self):
        subject = dict(item[0] for item in self.request.getpeercert()["subject"])
        cn = subject["commonName"]
        if self.path != "/favicon.ico":
            MutualTLS.served.append((self.headers.get("Host", ""), self.path, cn))
        body = f"<!doctype html><title>mtls:{cn}:{self.path}</title><p>{cn}".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def mtls_fixture(workspace):
    """Two loopback mutual-TLS ports (separate client-auth cache keys). The
    server certificate is accepted only by its per-run SPKI exception."""
    import base64, hashlib, ssl
    key, cert = workspace / "mtls-key.pem", workspace / "mtls-cert.pem"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key),
                    "-out", str(cert), "-days", "2", "-subj", "/CN=127.0.0.1"], check=True, capture_output=True)
    public = subprocess.run(["openssl", "x509", "-in", str(cert), "-pubkey", "-noout"], check=True, capture_output=True).stdout
    der = subprocess.run(["openssl", "pkey", "-pubin", "-outform", "DER"], input=public, check=True, capture_output=True).stdout
    spki = base64.b64encode(hashlib.sha256(der).digest()).decode()
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(str(cert), str(key))
    context.verify_mode = ssl.CERT_REQUIRED
    context.load_verify_locations(str(CLIENT_CERTS / "client_root_ca.pem"))
    servers = []
    for _ in range(2):
        server = ThreadingHTTPServer(("127.0.0.1", 0), MutualTLS)
        server.socket = context.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        servers.append(server)
    fingerprints = {name: hashlib.sha256(subprocess.run(["openssl", "x509", "-in", str(CLIENT_CERTS / f"{name}.pem"), "-outform", "DER"],
                                                        check=True, capture_output=True).stdout).hexdigest().upper()
                    for name in ("client_1", "client_2")}
    return servers, spki, fingerprints


NETWORK_AUDIT = []
LOOPBACK = {"127.0.0.1", "localhost", "[::1]", "::1"}
# Wave 18f: test processes reach no outside service (Google or otherwise).
# Chromium's background services are switched off, and any remaining lookup
# of a non-loopback name fails locally instead of resolving.
NO_OUTSIDE_NETWORK = [
    "--disable-background-networking", "--disable-component-update",
    "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1, EXCLUDE localhost",
]


def quiet_local_state(user_data_dir):
    """Secure DNS (automatic mode) dials its resolver's IP literal (e.g. Google
    Public DNS), which resolver rules cannot map; tests start with it off."""
    state = Path(user_data_dir) / "Local State"
    if not state.exists():
        state.parent.mkdir(parents=True, exist_ok=True)
        state.write_text(json.dumps({"dns_over_https": {"mode": "off"}}))


def merge_disabled_features(args):
    """Chromium reads only the last --disable-features; join them."""
    features = [a.split("=", 1)[1] for a in args if a.startswith("--disable-features=")]
    rest = [a for a in args if not a.startswith("--disable-features=")]
    return rest + ([f"--disable-features={','.join(features)}"] if features else [])


def outside_connects(path):
    """Non-loopback peers a net log shows traffic to (should be none): any TCP
    connect attempt, and UDP sockets that sent bytes. A bare UDP connect()
    sends nothing; HostResolver's IPv6 reachability probe makes one."""
    import re
    text = path.read_text(errors="replace") if path.exists() else ""
    def outside(address):
        return not (address.startswith("127.") or address.startswith("[::1]") or address.startswith("::1"))
    try:
        log = json.loads(text)
    except ValueError:
        return sorted({a for a in re.findall(r'"params":\{"address":"([^"]+)"', text) if outside(a)} or {"<unparsable net log>"})
    names = {v: k for k, v in log["constants"]["logEventTypes"].items()}
    peers, sent, tcp = {}, set(), set()
    for event in log["events"]:
        name, source, params = names.get(event["type"]), event["source"]["id"], event.get("params", {})
        if name in ("TCP_CONNECT_ATTEMPT", "SOCKET_CONNECT", "UDP_CONNECT") and "address" in params:
            peers.setdefault(source, set()).add(params["address"])
            if name == "TCP_CONNECT_ATTEMPT":
                tcp.add(source)
        elif name == "UDP_BYTES_SENT":
            sent.add(source)
            if "address" in params:
                peers.setdefault(source, set()).add(params["address"])
    return sorted({a for source, addresses in peers.items() if source in tcp or source in sent
                   for a in addresses if outside(a)})


def audit_netlog(path, label):
    """Every non-loopback host a process's net log names (URL requests,
    sockets and DNS), so fixtures can prove they reach no outside service."""
    import re
    text = path.read_text(errors="replace") if path.exists() else ""
    hosts = set(re.findall(r'"(?:url|original_url)":"(?:https?|wss?|ftp)://([^/":?]+)', text))
    hosts |= set(re.findall(r'"host":"(?:[a-z]+://)?([^"/:]+)', text))
    hosts = {h for h in hosts if h not in LOOPBACK and not h.startswith("127.")}
    NETWORK_AUDIT.append((label, sorted(hosts)))
    return hosts


def main():
    build_gate()
    workspace = Path(tempfile.mkdtemp(prefix="rearc-c-abi-"))
    app = workspace / "Chromium.app"
    # Keep physical helper bundles/Info.plists. A symlinked Frameworks directory
    # prevents sandboxed NSBundle metadata discovery in this native harness.
    subprocess.run(["cp", "-cR", str(OUT / "Chromium.app"), str(app)], check=True)
    for library in OUT.glob("*.dylib"):
        (workspace / library.name).symlink_to(library)
    executable = app / "Contents/MacOS/Chromium"
    server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        for kind in (sys.argv[1:] or ("launch", "devtools", "client_certificates", "links", "interstitials", "auth", "save", "leak", "autofill", "extensions", "pip", "pip_embedded", "perf", "drops", "print", "fullscreen", "search", "history", "danger", "discard", "passwords", "context", "permissions", "files", "dialogs", "helpers", "find", "downloads", "webui", "migration", "shutdown", "shutdown_veto", "core", "services", "urls", "eval", "scheme_return", "profiles", "identity", "zoom", "messages", "branding")):
            source = ENGINE / f"tests/c_abi_{kind}_host.mm"
            subprocess.run([
                "xcrun", "clang++", "-std=c++20", "-fobjc-arc", f"-I{BRIDGE}",
                str(source), "-framework", "AppKit", "-framework", "QuartzCore", f"-F{OUT}", "-framework",
                "Chromium Framework", f"-Wl,-rpath,{OUT}", "-o", str(executable),
            ], check=True)
            build_gate()
            profile = workspace / f"profile-{kind}"
            env = dict(os.environ, REARC_TEST_PORT=str(server.server_port))
            if kind in ("files", "context", "drops"):
                files = (workspace / f"files-{kind}").resolve()
                (files / "folder/sub").mkdir(parents=True, exist_ok=True)
                for name in ("a.txt", "b.txt", "folder/sub/c.txt"):
                    (files / name).write_text(name)
                (files / "folder/escape").symlink_to(files / "a.txt")
                if kind == "drops":
                    (files / "pixel.png").write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"\0\x11\x22\x33")) + chunk(b"IEND", b""))
                env["REARC_FILES_DIR"] = str(files)
            if kind in ("autofill", "save", "interstitials"):
                https, spki = https_fixture(workspace)
                env["REARC_TEST_HTTPS_PORT"] = str(https.server_port)
                env["REARC_TEST_SPKI"] = spki
            if kind == "client_certificates":
                mtls, spki, fingerprints = mtls_fixture(workspace)
                env["REARC_TEST_MTLS_PORTS"] = ",".join(str(m.server_port) for m in mtls)
                env["REARC_TEST_SPKI"] = spki
                env["REARC_CLIENT_FP_A"], env["REARC_CLIENT_FP_D"] = fingerprints["client_1"], fingerprints["client_2"]
            if kind == "extensions":
                fixtures = write_extensions((workspace / "extensions-fixtures").resolve())
                env["REARC_EXTENSION_DIRS"] = ",".join(str(f) for f in fixtures)
                env["REARC_DROP_CRX"] = os.environ["REARC_DROP_CRX"]
                env["REARC_DROP_CRX_ID"] = os.environ["REARC_DROP_CRX_ID"]
            if kind in ("downloads", "danger", "extensions"):
                downloads = (workspace / f"downloads-{kind}").resolve()
                downloads.mkdir(exist_ok=True)
                env["REARC_DOWNLOAD_DIR"] = str(downloads)
            phases = range(4) if kind == "devtools" else range(3) if kind == "shutdown" else range(2) if kind in ("discard", "profiles", "zoom", "migration", "leak") else range(1)
            for phase in phases:
                if kind == "devtools":
                    env["REARC_DEVTOOLS_MODE"] = str(phase)
                if kind == "discard":
                    if phase: env["REARC_DISCARD_DISABLED"] = "1"
                    else: env.pop("REARC_DISCARD_DISABLED", None)
                if kind == "shutdown":
                    env["REARC_SHUTDOWN_MODE"] = str(phase)
                elif phase and kind != "discard":
                    env["REARC_MIGRATION_SECOND" if kind == "migration" else "REARC_PROFILE_SECOND" if kind == "profiles" else "REARC_LEAK_SECOND" if kind == "leak" else "REARC_ZOOM_SECOND"] = "1"
                if kind == "migration" and phase:
                    (profile / "alias").symlink_to("Default", target_is_directory=True)
                suffix = "-disabled" if kind == "discard" and phase else f"-mode{phase}" if kind in ("shutdown", "devtools") else '-reopen' if phase else ''
                log = ENGINE / f"runtime-abi-{kind}{suffix}.log"
                netlog = workspace / f"netlog-{kind}{suffix}.json"
                quiet_local_state(profile)
                with log.open("wb") as output:
                    result = subprocess.run(merge_disabled_features([
                        "timeout", "-k", "5", "120" if kind in ("devtools", "client_certificates", "links", "interstitials", "auth", "save", "leak", "autofill", "extensions", "pip", "pip_embedded", "perf", "drops", "print", "fullscreen", "search", "helpers", "webui", "urls", "profiles", "migration", "dialogs", "files", "permissions", "context", "passwords") else "45", str(executable),
                        f"--user-data-dir={profile}", "--use-mock-keychain", f"--log-net-log={netlog}",
                        *NO_OUTSIDE_NETWORK,
                        *(["--process-per-site", *(["--disable-features=WebContentsDiscard"] if phase else [])] if kind == "discard" else []),
                        *(["--safebrowsing-manual-download-blacklist=" + hashlib.sha256(b"a" * 65536).hexdigest()] if kind == "danger" else []),
                        *(["--remote-debugging-port=0", "--enable-logging=stderr", "--vmodule=close_controller=1,rearc_keep_alive=1,keep_alive_registry=1,devtools_ui_bindings=1"] if kind in ("devtools", "webui", "helpers", "permissions", "passwords", "fullscreen", "pip", "extensions", "autofill", "leak", "save", "interstitials") else []),
                        *(["--disable-backgrounding-occluded-windows"] if kind in ("devtools", "helpers", "permissions", "passwords", "fullscreen", "pip", "pip_embedded", "perf", "extensions", "autofill", "leak", "save", "interstitials") else []),
                        *(["--use-fake-device-for-media-stream"] if kind == "permissions" else []),
                        *(["--autoplay-policy=no-user-gesture-required"] if kind in ("pip", "pip_embedded") else []),
                        *([f"--mark_as_phishing=http://127.0.0.1:{server.server_port}/phishing-a,http://localhost:{server.server_port}/phishing-b"] if kind == "interstitials" else []),
                        # The locked test session never makes the window key; Chromium
                        # shows suggestions only for a focused view (test switch only).
                        *(["--ignore-certificate-errors-spki-list=" + env["REARC_TEST_SPKI"],
                           "--disable-features=RWHVMacHasFocusReturnsFalseForNonKeyWindow"] if kind in ("autofill", "save") else []),
                        # Test-only memory ClientCertStore (debug builds only, also
                        # requires --use-mock-keychain); no Keychain identity lookup.
                        *(["--ignore-certificate-errors-spki-list=" + env["REARC_TEST_SPKI"],
                           f"--rearc-test-client-cert-dir={CLIENT_CERTS}", "--enable-logging=stderr"] if kind == "client_certificates" else []),
                        *(["--load-extension=" + env["REARC_EXTENSION_DIRS"],
                           f"--apps-gallery-url=http://localhost:{server.server_port}/",
                           f"--apps-gallery-update-url=http://localhost:{server.server_port}/webstore/extension.crx"] if kind == "extensions" else []),
                    ]), stdout=output, stderr=subprocess.STDOUT, env=env)
                assert result.returncode == 0, f"{kind}: rc={result.returncode}; {log}"
                print(f"{kind} phase={phase} PASS ({log})", flush=True)
                outside = audit_netlog(netlog, f"{kind}{suffix}")
                connects = outside_connects(netlog)
                assert netlog.exists() and not connects, (kind, connects, netlog)
                if kind == "leak":
                    leak = "passwordsleakcheck" in (netlog.read_text(errors="replace") if netlog.exists() else "")
                    print(f"leak phase={phase} leak-check request attempted={leak}", flush=True)
                    if phase:
                        assert not leak, "leak check attempted with password_leak_detection off"
                        print("No leak-check request with leak detection off PASS", flush=True)
            if kind == "links":
                print("Link HTTP Referer headers", Fixture.link_referrers, flush=True)
                assert len(Fixture.link_referrers) == 6, Fixture.link_referrers
                expected_referrer = f"http://127.0.0.1:{server.server_port}/link-open"
                assert Fixture.link_referrers[:5] == [expected_referrer] * 5 and Fixture.link_referrers[5] == "", Fixture.link_referrers
                print("Five Chromium referrers and noreferrer suppression verified on HTTP server PASS", flush=True)
            if kind == "client_certificates":
                for mtls_server in mtls:  # Keep the shared fixture `server` intact.
                    mtls_server.shutdown()
                    mtls_server.server_close()
                text = log.read_text(errors="replace")
                print("Mutual TLS requests served", MutualTLS.served, "aborted handshakes", MutualTLS.handshake_failures, flush=True)
                served = [(path, cn) for _, path, cn in MutualTLS.served]
                assert served == [("/select", "Client Cert D"), ("/cached", "Client Cert D"),
                                  ("/after-acquire", "Client Cert A"), ("/after-sign", "Client Cert A")], served
                assert '"net_error":-110' in netlog.read_text(errors="replace"), "no ERR_SSL_CLIENT_AUTH_CERT_NEEDED abort"
                assert "TEST CLIENT CERT memory store (no Keychain)" in text and "TEST CLIENT CERT acquiring private key" in text
                closing = text.index("CLIENTCERT closing during signing")
                started = text.rfind("TEST CLIENT CERT signing started", 0, closing)
                assert started >= 0, "signing not in flight at close"
                assert text.find("TEST CLIENT CERT signing resumed", started) > closing, "signing finished before close"
                print("Server saw only selected identities; memory store, delayed acquisition and close-during-signing ordering PASS", flush=True)
            if kind == "search":
                queries = list(Fixture.suggest_queries)
                print("Suggest requests", queries, flush=True)
                assert any(q.startswith("visit") for q in queries), queries
                assert not any("privateonly" in q for q in queries), queries
                print("Regular remote suggest observed; no OTR suggest request PASS", flush=True)
            if kind == "danger":
                assert [(p.name, p.stat().st_size) for p in downloads.iterdir()] == [("rearc-danger-keep.sh", 65536)]
                print("Kept file present; discarded temporary/final files absent PASS", flush=True)
            if kind == "passwords":
                with sqlite3.connect(f"file:{profile / 'Default/Login Data'}?mode=ro", uri=True) as db:
                    saved = db.execute("SELECT username_value, date_created, date_password_modified, length(password_value), blacklisted_by_user FROM logins").fetchall()
                credentials = [r for r in saved if not r[4]]
                assert len(credentials) == 1 and credentials[0][0] == 'wave18c-saved', saved
                assert credentials[0][2] > credentials[0][1] and credentials[0][3] > 0, saved
                assert sum(bool(r[4]) for r in saved) == 1, saved
                print('Password save/update timestamp + never blocklist, dismissed credentials absent PASS', flush=True)
            if kind == "permissions":
                exceptions = json.loads((profile / 'Default/Preferences').read_text())['profile']['content_settings']['exceptions']
                for name, setting in (('notifications',1),('midi_sysex',2),('media_stream_camera',2),('media_stream_mic',2)):
                    assert any(v.get('setting') == setting for k,v in exceptions.get(name,{}).items() if str(server.server_port) in k), (name,exceptions.get(name))
                assert not any(str(server.server_port) in k for name in ('clipboard','geolocation','geolocation_with_options') for k in exceptions.get(name,{})), exceptions
                print('Durable notification/MIDI/media prefs present; transient clipboard/geolocation prefs absent PASS', flush=True)
            if kind == "helpers":
                base = f"http://127.0.0.1:{server.server_port}"
                with sqlite3.connect(f"file:{profile / 'Default/History'}?mode=ro", uri=True) as db:
                    rows = dict(db.execute("SELECT url, title FROM urls WHERE url LIKE ?", (base + "/visit-%",)).fetchall())
                assert rows == {base + "/visit-a": "ReArc visit A", base + "/visit-b": "ReArc visit B"}, rows
                with sqlite3.connect(f"file:{profile / 'Default/Login Data'}?mode=ro", uri=True) as db:
                    used = db.execute("SELECT times_used, date_last_used FROM logins WHERE username_value='rearc-w18b'").fetchall()
                assert len(used) == 1 and used[0][0] >= 1 and used[0][1] > 0, used
                print(f"History rows {sorted(rows)} and Login Data times_used={used[0][0]} PASS", flush=True)
            if kind == "profiles":
                # Named OTR contexts share their original's GetPath, but storage
                # must remain memory-only. Search all persistent profile files.
                for item in profile.rglob("*"):
                    if item.is_file():
                        assert b"PRIVATE-ONLY-W14" not in item.read_bytes(), item
                        if item.name == "Cookies":
                            with sqlite3.connect(f"file:{item}?mode=ro", uri=True) as db:
                                assert db.execute("SELECT count(*) FROM cookies WHERE name='private'").fetchone()[0] == 0, item
                print("OTR disk marker and persisted private-cookie rows absent PASS", flush=True)
        wave = os.environ.get("REARC_WAVE_LABEL", "w18h")
        audit_name = f"network-audit-{wave}.log" if not sys.argv[1:] else f"network-audit-{wave}-{'-'.join(sys.argv[1:])}.log"
        with (ENGINE / audit_name).open("w") as audit:
            for label, hosts in NETWORK_AUDIT:
                audit.write(f"{label}: {' '.join(hosts) if hosts else 'loopback only'}\n")
            audit.write(f"NO OUTSIDE CONNECT PASS: {len(NETWORK_AUDIT)} processes, every TCP/UDP connect to loopback\n")
        print(f"Network audit: {sum(1 for _, h in NETWORK_AUDIT if h)} of {len(NETWORK_AUDIT)} processes looked up outside names, "
              f"none connected outside (engine/{audit_name})", flush=True)
    finally:
        server.shutdown()
        server.server_close()
    print(f"Native app and profiles retained at {workspace}", flush=True)


if __name__ == "__main__":
    main()
