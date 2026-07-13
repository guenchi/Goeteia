;; expect: #t
;; (web sprite) against recording mocks: the atlas rasterizes each
;; distinct code point once and its measurer feeds typeset, the batch
;; writes the exact quad floats, text draws at typeset's line breaks,
;; growth re-uploads with a doubled u_texsize.
(import (rnrs) (web js) (web gl) (web glsl) (web fx) (web typeset) (web sprite))

(js-eval "globalThis.__gllog = []; globalThis.__2dlog = []; globalThis.__cvk = 0; globalThis.__make2d = () => { const log = globalThis.__2dlog; return { font:'', textBaseline:'', fillStyle:'', measureText(s){ return { width: s === 'W' ? 30 : 10 } }, fillText(s,x,y){ log.push(['fillText',s,x,y].join(':')) }, fillRect(...a){ log.push(['fillRect',...a].join(':')) }, drawImage(src,x,y){ log.push('drawImage:'+src.id) } } }; globalThis.document = { createElement(tag){ return { id:'CV'+(++globalThis.__cvk), width:0, height:0, getContext(k){ return globalThis.__make2d() } } } }; globalThis.__mockcanvas = { width:640, height:480, addEventListener(k,f){}, getContext(kind) { const log = globalThis.__gllog; const push = (...a) => log.push(a.join(':')); return { VERTEX_SHADER:'VS', FRAGMENT_SHADER:'FS', COMPILE_STATUS:'CS', LINK_STATUS:'LS', COLOR_BUFFER_BIT:16384, DEPTH_BUFFER_BIT:256, ARRAY_BUFFER:'AB', DYNAMIC_DRAW:'DD', FLOAT:'F', POINTS:'PTS', LINES:'LNS', TRIANGLES:'TRI', TRIANGLE_STRIP:'STRIP', TEXTURE_2D:'T2D', TEXTURE0:33984, TEXTURE_MIN_FILTER:'MIN', TEXTURE_MAG_FILTER:'MAG', TEXTURE_WRAP_S:'WS', TEXTURE_WRAP_T:'WT', LINEAR:'LIN', LINEAR_MIPMAP_LINEAR:'LML', CLAMP_TO_EDGE:'CL', RGBA:'RGBA', UNSIGNED_BYTE:'UB', BLEND:'BL', SRC_ALPHA:'SA', ONE:'ONE', ONE_MINUS_SRC_ALPHA:'OMSA', createShader(k){ return {kind:k} }, shaderSource(s,src){}, compileShader(s){}, getShaderParameter(){ return true }, createProgram(){ return {id:'P'+(this._p=(this._p||0)+1)} }, attachShader(p,s){}, linkProgram(p){}, getProgramParameter(){ return true }, bindAttribLocation(p,i,n){ push('bindAttrib', i, n) }, createBuffer(){ return {id:'B'+(this._b=(this._b||0)+1)} }, getUniformLocation(p,n){ return {id:'U:'+n} }, createTexture(){ return {id:'T'+(this._t=(this._t||0)+1)} }, bindTexture(t,tex){ push('bindTexture', tex.id) }, texParameteri(t,k,v){ push('texParam', k, v) }, UNPACK_PREMULTIPLY_ALPHA_WEBGL:'UPA', pixelStorei(k,v){ push('pixelStore', k, v) }, texImage2D(...a){ push('texImage', a[a.length-1].id) }, generateMipmap(t){ push('genMip', t) }, activeTexture(u){ push('activeTexture', u) }, enable(c){ push('gEnable', c) }, disable(c){ push('gDisable', c) }, blendFunc(a,b){ push('blendFunc', a, b) }, clearColor(...a){ push('clearColor', ...a.map(x=>x.toFixed(2))) }, clear(bits){ push('clear', bits) }, useProgram(p){ push('useProgram', p.id) }, bindBuffer(t,b){ push('bindBuffer', b.id) }, bufferData(t,arr,u){ globalThis.__lastbuf = Array.from(arr) }, enableVertexAttribArray(l){ push('enable', l) }, vertexAttribPointer(...a){ push('attrib', a.join(',')) }, uniform1f(loc,x){ push('uniform1f', loc.id, x.toFixed(2)) }, uniform2f(loc,x,y){ push('uniform2f', loc.id, x.toFixed(2), y.toFixed(2)) }, uniform4f(loc,...a){ push('uniform4f', loc.id, a.map(x=>x.toFixed(1)).join(',')) }, uniform1i(loc,v){ push('uniform1i', loc.id, v) }, drawArrays(m,f,c){ push('draw', m, f, c) }, viewport(...a){ push('viewport', a.join(',')) } } } }")

(define gllog (js-get (js-global) "__gllog"))
(define d2log (js-get (js-global) "__2dlog"))
(define (entry i) (js->string (js-index gllog i)))
(define (log-len) (js->number (js-get gllog "length")))
(define (check-from base es)
  (let loop ((i base) (es es))
    (or (null? es)
        (and (or (string=? (entry i) (car es))
                 (begin (display "mismatch at ") (display i)
                        (display ": got ") (display (entry i))
                        (display " want ") (display (car es)) (newline)
                        #f))
             (loop (+ i 1) (cdr es))))))
(define (prefix? p s)
  (and (<= (string-length p) (string-length s))
       (string=? p (substring s 0 (string-length p)))))
(define (count-log arr p)
  (let ((n (js->number (js-get arr "length"))))
    (let loop ((i 0) (c 0))
      (if (= i n)
          c
          (loop (+ i 1)
                (if (prefix? p (js->string (js-index arr i))) (+ c 1) c))))))
(define (lb i)                           ; the last uploaded buffer
  (js->number (js-index (js-get (js-global) "__lastbuf") i)))
(define (lb-len)
  (js->number (js-get (js-get (js-global) "__lastbuf") "length")))

;; ---- atlas init: white block, texture params, line height ----
(fx-init! (js-get (js-global) "__mockcanvas"))
(define base-a (log-len))
(define at (make-atlas "16px m" 16))     ; cell-h = 16 + 6 + 2 = 24
(define init-ok
  (and (= (atlas-line-height at) 24)
       (= (count-log d2log "fillRect:0:0:2:2") 1)
       (check-from base-a '("bindTexture:T1"
                            "texParam:MIN:LML" "texParam:MAG:LIN"
                            "texParam:WS:CL" "texParam:WT:CL"))))

;; ---- the measurer rasterizes once per distinct code point ----
(define m (atlas-measurer at))
(define meas-ok
  (and (fl=? (m "A") 10.0)
       (fl=? (m "A") 10.0)               ; cache hit: no second fillText
       (= (count-log d2log "fillText") 1)))
(define prep (prepare "Hi Hi" m))        ; distinct: H, i, space
(define prep-ok
  (and (= (count-log d2log "fillText") 4)
       (= (count-log d2log "fillText:H:17:1") 1)
       (= (count-log d2log "fillText:i:29:1") 1)))

;; ---- one rect: exact vertex floats, one draw call ----
(define base-b (log-len))
(define bt (make-batch at))
(define battr-ok
  (check-from base-b
              '("bindAttrib:0:a_pos" "bindAttrib:1:a_uv" "bindAttrib:2:a_tint")))
(define base-c (log-len))
(cmd-begin!)
(batch-begin! bt)
(rect! bt 10 20 30 40 1 0 0 1)           ; fixnums in, floats out
(batch-draw! bt)
(cmd-flush!)
(define rect-ok
  (and (check-from base-c
                   '("bindTexture:T1" "texImage:CV1"   ; dirty -> upload
                     "genMip:T2D"
                     "gEnable:BL" "blendFunc:SA:OMSA"
                     "useProgram:P1" "bindBuffer:B1"
                     "enable:0" "attrib:0,2,F,false,32,0"
                     "enable:1" "attrib:1,2,F,false,32,8"
                     "enable:2" "attrib:2,4,F,false,32,16"
                     "activeTexture:33984" "bindTexture:T1"
                     "uniform1i:U:u_tex:0"
                     "uniform2f:U:u_resolution:640.00:480.00"
                     "uniform2f:U:u_texsize:256.00:256.00"
                     "draw:TRI:0:6"))
       (= (lb-len) 48)
       (= (lb 0) 10) (= (lb 1) 20)       ; v0: pos, white-block uv, tint
       (= (lb 2) 1) (= (lb 3) 1)
       (= (lb 4) 1) (= (lb 5) 0) (= (lb 6) 0) (= (lb 7) 1)
       (= (lb 8) 40)                     ; v1: x + w
       (= (lb 17) 60)))                  ; v2: y + h
;; a clean second frame does not re-upload the texture
(cmd-begin!)
(batch-begin! bt)
(rect! bt 0 0 1 1 1 1 1 1)
(batch-draw! bt)
(cmd-flush!)
(define once-ok (= (count-log gllog "texImage") 1))

;; ---- text: quads at typeset's pen positions and line breaks ----
(define lay (layout prep 640.0 24))
(cmd-begin!)
(batch-begin! bt)
(draw-text! bt lay 0 0 1 1 1 1)
(batch-draw! bt)
(cmd-flush!)
(define text-ok
  (and (string=? (entry (- (log-len) 1)) "draw:TRI:0:24")  ; 4 quads
       (= (lb-len) 192)
       (= (lb 0) 0) (= (lb 2) 17) (= (lb 3) 1)    ; H: pen 0, its cell uv
       (= (lb 8) 10)                              ; glyph width 10
       (= (lb 17) 22)                             ; glyph height 22
       (= (lb 48) 10)                             ; i at pen 10
       (= (lb 96) 30)                             ; space advances the pen
       (= (lb 144) 40)))
(define lay2 (layout (prepare "Hi\nHi" m) 640.0 24))
(cmd-begin!)
(batch-begin! bt)
(draw-text! bt lay2 0 0 1 1 1 1)
(batch-draw! bt)
(cmd-flush!)
(define lines-ok
  (and (= (lb-len) 192)
       (= (lb 1) 0)                      ; line 1 at y 0
       (= (lb 96) 0) (= (lb 97) 24)))    ; line 2 back at x 0, y 24

;; ---- growth: 2x face, old pixels copied, texture re-uploaded ----
(define at2 (make-atlas "16px m" 16 32))
(define m2 (atlas-measurer at2))
(m2 "a") (m2 "b") (m2 "c")               ; the third overflows the face
(define grow-ok (= (count-log d2log "drawImage:CV2") 1))
(define bt2 (make-batch at2))
(cmd-begin!)
(batch-begin! bt2)
(rect! bt2 0 0 1 1 1 1 1 1)
(batch-draw! bt2)
(cmd-flush!)
(define grow-draw-ok
  (and (= (count-log gllog "uniform2f:U:u_texsize:64.00:64.00") 1)
       (= (count-log gllog "texImage:CV3") 1)))

;; ---- image sheets: load, premultiplied upload, their own batch ----
(js-eval "globalThis.Image = function(){ globalThis.__lastimg = this }")
(define got-img #f)
(load-image! "sprites.png" (lambda (img) (set! got-img img)))
(js-eval "globalThis.__lastimg.width = 64; globalThis.__lastimg.height = 32; globalThis.__lastimg.id = 'IMG'; globalThis.__lastimg.onload()")
(define load-ok
  (and (js-ref? got-img)
       (string=? (js->string (js-get got-img "src")) "sprites.png")))
(define base-s (log-len))
(define sh (make-sheet got-img))
(define sheet-ok
  (and (= (sheet-width sh) 64)
       (= (sheet-height sh) 32)
       (check-from (+ base-s 5)              ; texture params, then upload
                   '("pixelStore:UPA:true"
                     "bindTexture:T3" "texImage:IMG"
                     "genMip:T2D"
                     "pixelStore:UPA:false"))))
(define sb (make-sheet-batch sh))
(cmd-begin!)
(sheet! sb 10 20 32 16 0 0 32 16 1 1 1 1)
(sheet-draw! sb)
(cmd-flush!)
(define sheet-draw-ok
  (and (string=? (entry (- (log-len) 1)) "draw:TRI:0:6")
       (= (count-log gllog "blendFunc:ONE:OMSA") 1)
       (= (count-log gllog "uniform2f:U:u_texsize:64.00:32.00") 1)
       (= (lb-len) 48)
       (= (lb 0) 10) (= (lb 1) 20)           ; dest rect
       (= (lb 2) 0) (= (lb 3) 0)             ; source uv origin
       (= (lb 8) 42) (= (lb 10) 32)          ; x+w, u+sw
       (= (lb 17) 36)))                      ; y+h

(and init-ok meas-ok prep-ok battr-ok rect-ok once-ok text-ok lines-ok
     grow-ok grow-draw-ok load-ok sheet-ok sheet-draw-ok)
