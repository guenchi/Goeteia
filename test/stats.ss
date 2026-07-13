;; expect: #t
;; (web stats): the encoder counts draws as they encode, the HUD
;; reads them (and the write cursor) before adding its own panel --
;; one batch draw of backdrop, frame-time slivers and text.
(import (rnrs) (web js) (web gl) (web fx) (web sprite) (web stats))

(js-eval "globalThis.__gllog = []; globalThis.__2dlog = []; globalThis.__cvk = 0; globalThis.__make2d = () => { const log = globalThis.__2dlog; return { font:'', textBaseline:'', fillStyle:'', measureText(s){ return { width: s === 'W' ? 30 : 10 } }, fillText(s,x,y){ log.push(['fillText',s,x,y].join(':')) }, fillRect(...a){ log.push(['fillRect',...a].join(':')) }, drawImage(src,x,y){ log.push('drawImage:'+src.id) } } }; globalThis.document = { createElement(tag){ return { id:'CV'+(++globalThis.__cvk), width:0, height:0, getContext(k){ return globalThis.__make2d() } } } }; globalThis.__mockcanvas = { width:640, height:480, addEventListener(k,f){}, getContext(kind) { const log = globalThis.__gllog; const push = (...a) => log.push(a.join(':')); return { VERTEX_SHADER:'VS', FRAGMENT_SHADER:'FS', COMPILE_STATUS:'CS', LINK_STATUS:'LS', COLOR_BUFFER_BIT:16384, DEPTH_BUFFER_BIT:256, ARRAY_BUFFER:'AB', DYNAMIC_DRAW:'DD', FLOAT:'F', POINTS:'PTS', LINES:'LNS', TRIANGLES:'TRI', TRIANGLE_STRIP:'STRIP', TEXTURE_2D:'T2D', TEXTURE0:33984, TEXTURE_MIN_FILTER:'MIN', TEXTURE_MAG_FILTER:'MAG', TEXTURE_WRAP_S:'WS', TEXTURE_WRAP_T:'WT', LINEAR:'LIN', LINEAR_MIPMAP_LINEAR:'LML', CLAMP_TO_EDGE:'CL', RGBA:'RGBA', UNSIGNED_BYTE:'UB', BLEND:'BL', SRC_ALPHA:'SA', ONE:'ONE', ONE_MINUS_SRC_ALPHA:'OMSA', createShader(k){ return {kind:k} }, shaderSource(s,src){}, compileShader(s){}, getShaderParameter(){ return true }, createProgram(){ return {id:'P'+(this._p=(this._p||0)+1)} }, attachShader(p,s){}, linkProgram(p){}, getProgramParameter(){ return true }, bindAttribLocation(p,i,n){ push('bindAttrib', i, n) }, createVertexArray(){ return {id:'V'+(this._v=(this._v||0)+1)} }, bindVertexArray(){}, createBuffer(){ return {id:'B'+(this._b=(this._b||0)+1)} }, getUniformLocation(p,n){ return {id:'U:'+n} }, createTexture(){ return {id:'T'+(this._t=(this._t||0)+1)} }, bindTexture(t,tex){ push('bindTexture', tex.id) }, texParameteri(t,k,v){ push('texParam', k, v) }, UNPACK_PREMULTIPLY_ALPHA_WEBGL:'UPA', pixelStorei(k,v){ push('pixelStore', k, v) }, texImage2D(...a){ push('texImage', a[a.length-1].id) }, generateMipmap(t){ push('genMip', t) }, activeTexture(u){ push('activeTexture', u) }, enable(c){ push('gEnable', c) }, disable(c){ push('gDisable', c) }, blendFunc(a,b){ push('blendFunc', a, b) }, clearColor(...a){ push('clearColor', ...a.map(x=>x.toFixed(2))) }, clear(bits){ push('clear', bits) }, useProgram(p){ push('useProgram', p.id) }, bindBuffer(t,b){ push('bindBuffer', b.id) }, bufferData(t,arr,u){ globalThis.__lastbuf = Array.from(arr) }, enableVertexAttribArray(l){ push('enable', l) }, vertexAttribPointer(...a){ push('attrib', a.join(',')) }, uniform1f(loc,x){ push('uniform1f', loc.id, x.toFixed(2)) }, uniform2f(loc,x,y){ push('uniform2f', loc.id, x.toFixed(2), y.toFixed(2)) }, uniform4f(loc,...a){ push('uniform4f', loc.id, a.map(x=>x.toFixed(1)).join(',')) }, uniform1i(loc,v){ push('uniform1i', loc.id, v) }, drawElements(m,c,t,o){ push('draw', m, c, t) }, drawElementsInstanced(m,c,t,o,n){ push('draw', m, c, n) }, vertexAttribDivisor(){}, ELEMENT_ARRAY_BUFFER:'EAB', UNSIGNED_SHORT:'US', UNSIGNED_INT:'UI', drawArrays(m,f,c){ push('draw', m, f, c) }, viewport(...a){ push('viewport', a.join(',')) } } } }")

(define gllog (js-get (js-global) "__gllog"))
(define (log-len) (js->number (js-get gllog "length")))
(define (entry i) (js->string (js-index gllog i)))
(define (count-log p)
  (let ((n (log-len)))
    (let loop ((i 0) (c 0))
      (if (= i n)
          c
          (loop (+ i 1)
                (if (and (<= (string-length p) (string-length (entry i)))
                         (string=? p (substring (entry i) 0
                                                (string-length p))))
                    (+ c 1)
                    c))))))

(fx-init! (js-get (js-global) "__mockcanvas"))

;; ---- the encoder's draw counter ----
(cmd-begin!)
(define d0 (cmd-draws))                  ; a fresh frame counts zero
(cmd-draw-arrays! GL-TRIANGLES 0 3)
(cmd-draw-elements! GL-TRIANGLES 36)
(cmd-draw-elements-instanced! GL-TRIANGLES 36 100)
(cmd-draw-elements32! GL-TRIANGLES 9)
(define d4 (cmd-draws))
(cmd-flush!)
(cmd-begin!)
(define dz (cmd-draws))                  ; begin resets
(cmd-flush!)
(define count-ok (and (= d0 0) (= d4 4) (= dz 0)))

;; ---- the HUD: one extra batch draw, after the numbers ----
(define hud (make-stats))
(cmd-begin!)
(cmd-draw-arrays! GL-TRIANGLES 0 3)
(define before (count-log "draw:TRI"))
(stats-draw! hud 0.016)
(cmd-flush!)
(define hud-ok
  ;; the scene's own draw replays, plus ONE for the whole panel
  (= (count-log "draw:TRI") (+ before 2)))

;; a second frame exercises the ring without re-typesetting
(cmd-begin!)
(stats-draw! hud 0.03)
(cmd-flush!)
(define frame2-ok (> (count-log "draw:TRI") before))

(and count-ok hud-ok frame2-ok)
