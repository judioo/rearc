import Foundation

enum BoostPickerScript {
    static let messageHandler = "rearcBoostEditor"
    static let editorWorldName = "rearc.editor"

    static let bridgeSource = """
    (function(){
      var HANDLER = '\(messageHandler)';
      var overlay = null;
      var pickMode = false;
      var ATTR_ALLOW = ['role','aria-label','aria-labelledby','name','type','href','placeholder','alt','title','for','data-testid','data-test','data-cy','data-qa','data-id'];

      function post(obj){ 
        if(window.webkit && window.webkit.messageHandlers[HANDLER])
          window.webkit.messageHandlers[HANDLER].postMessage(obj);
      }

      function ensureOverlay(){
        if(overlay) return overlay;
        overlay = document.createElement('div');
        overlay.id = 'rearc-boost-picker-overlay';
        overlay.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483646;border:2px solid #6366f1;background:rgba(99,102,241,0.12);box-sizing:border-box;display:none;';
        (document.documentElement || document.body).appendChild(overlay);
        return overlay;
      }

      function implicitRole(el){
        var t = (el.tagName||'').toLowerCase();
        var map = {button:'button',a:'link',input:'textbox',textarea:'textbox',select:'combobox',nav:'navigation',main:'main',header:'banner',footer:'contentinfo'};
        if(map[t]) return map[t];
        if(/^h[1-6]$/.test(t)) return 'heading';
        return null;
      }

      function directText(el){
        var s = '';
        for(var i=0;i<el.childNodes.length;i++){
          var n = el.childNodes[i];
          if(n.nodeType === 3) s += n.textContent;
        }
        return s.replace(/\\s+/g,' ').trim().slice(0,80) || null;
      }

      function collectAttrs(el){
        var out = {};
        for(var i=0;i<ATTR_ALLOW.length;i++){
          var n = ATTR_ALLOW[i];
          if(el.hasAttribute(n)) out[n] = (el.getAttribute(n)||'').slice(0,80);
        }
        return out;
      }

      function indexAmongType(el){
        var tag = el.tagName, idx = 0, sib = el.parentNode ? el.parentNode.children : [];
        for(var i=0;i<sib.length;i++){
          if(sib[i].tagName === tag){
            idx++;
            if(sib[i] === el) return idx;
          }
        }
        return 1;
      }

      function structuralPath(el){
        var path = [], cur = el, depth = 0;
        while(cur && cur.nodeType === 1 && depth < 8){
          path.unshift((cur.tagName||'div').toLowerCase());
          if(cur.tagName === 'BODY') break;
          cur = cur.parentElement;
          depth++;
        }
        return path;
      }

      function computedSnapshot(el){
        var cs = window.getComputedStyle(el);
        var keys = ['color','background-color','font-size','font-weight','padding','margin','border','display','width','height'];
        var out = {};
        for(var i=0;i<keys.length;i++){
          var k = keys[i];
          out[k] = cs.getPropertyValue(k);
        }
        return out;
      }

      function countClassMatches(token){
        try { return document.querySelectorAll('.' + CSS.escape(token)).length; } catch(e){ return 1; }
      }

      function buildDescriptor(el){
        var rect = el.getBoundingClientRect();
        var tagName = (el.tagName||'div').toLowerCase();
        var classCounts = {};
        var classList = Array.prototype.slice.call(el.classList || []).slice(0,12);
        for(var ci=0; ci<classList.length; ci++){
          classCounts[classList[ci]] = countClassMatches(classList[ci]);
        }
        var idCount = 0;
        if(el.id){
          try { idCount = document.querySelectorAll('#' + CSS.escape(el.id)).length; } catch(e){ idCount = 1; }
        }
        return {
          type: 'pick',
          descriptor: {
            tag: tagName,
            id: el.id || null,
            classes: classList,
            attrs: collectAttrs(el),
            role: el.getAttribute('role') || implicitRole(el),
            accessibleName: el.getAttribute('aria-label') || null,
            structuralPath: structuralPath(el),
            indexAmongType: indexAmongType(el),
            tagMatchCount: document.getElementsByTagName(el.tagName).length,
            idMatchCount: idCount,
            classMatchCounts: classCounts
          },
          bounds: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
          viewportWidth: window.innerWidth,
          viewportHeight: window.innerHeight,
          computedStyles: computedSnapshot(el)
        };
      }

      function snapshotAt(x, y){
        var el = document.elementFromPoint(x, y);
        if(!el || el === overlay) return null;
        if(el.id === 'rearc-boost-picker-overlay') return null;
        var rect = el.getBoundingClientRect();
        ensureOverlay().style.display = 'block';
        overlay.style.left = rect.x + 'px';
        overlay.style.top = rect.y + 'px';
        overlay.style.width = rect.width + 'px';
        overlay.style.height = rect.height + 'px';
        return buildDescriptor(el);
      }

      window.__rearcBoostPicker = {
        setPickMode: function(on){
          pickMode = !!on;
          if(!pickMode){
            if(overlay) overlay.style.display = 'none';
          }
        },
        snapshotAt: snapshotAt,
        highlightSelector: function(css){
          try {
            var el = document.querySelector(css);
            if(!el) return;
            var rect = el.getBoundingClientRect();
            var ov = ensureOverlay();
            ov.style.display = 'block';
            ov.style.left = rect.x + 'px';
            ov.style.top = rect.y + 'px';
            ov.style.width = rect.width + 'px';
            ov.style.height = rect.height + 'px';
          } catch(e){}
        },
        hideOverlay: function(){
          if(overlay) overlay.style.display = 'none';
        },
        scanRepairCandidates: function(limit){
          limit = limit || 24;
          var sel = 'button, a, input, textarea, [role="button"], [role="link"]';
          var nodes = Array.prototype.slice.call(document.querySelectorAll(sel)).slice(0, limit);
          var out = [];
          for(var i=0;i<nodes.length;i++){
            var el = nodes[i];
            if(!el || el.id === 'rearc-boost-picker-overlay') continue;
            var rect = el.getBoundingClientRect();
            if(rect.width < 2 || rect.height < 2) continue;
            out.push(buildDescriptor(el));
          }
          return out;
        }
      };

      document.addEventListener('keydown', function(e){
        if(!pickMode) return;
        if(e.key === 'Escape'){
          e.preventDefault();
          post({ type: 'cancel' });
        }
      }, true);

      document.addEventListener('mousemove', function(e){
        if(!pickMode) return;
        snapshotAt(e.clientX, e.clientY);
      }, true);

      document.addEventListener('click', function(e){
        if(!pickMode) return;
        e.preventDefault();
        e.stopImmediatePropagation();
        var payload = snapshotAt(e.clientX, e.clientY);
        if(payload) post(payload);
      }, true);
    })();
    """
}
