;; expect: #t
;; Pixel readback through the command buffer: cmd-read-pixels! encodes
;; a rectangle plus a staging address, the replayer hands gl.readPixels
;; a Uint8Array aimed straight at that address, and the bytes are there
;; for %mem-u8-ref the moment cmd-flush! returns.
;;
;; The mock's readPixels fills the view it is GIVEN with a pattern
;; derived from (x y w h), so a wrong length, a wrong address or a
;; swapped rectangle all show up as bytes in the wrong place -- not
;; merely as a wrong log line.
(import (rnrs) (web js) (gfx gl) (gfx fx))

(js-eval "globalThis.__gllog = []; globalThis.__mockcanvas = { width:8, height:4, addEventListener(k,f){}, getContext(kind) { const log = globalThis.__gllog; const push = (...a) => log.push(a.join(':')); return { RGBA:'RGBA', UNSIGNED_BYTE:'UB', RGBA8:'R8', RGBA16F:'R16F', HALF_FLOAT:'HF', TEXTURE_2D:'T2D', FRAMEBUFFER:'FB', READ_FRAMEBUFFER:'RFB', DRAW_FRAMEBUFFER:'DFB', COLOR_ATTACHMENT0:'CA0', DEPTH_ATTACHMENT:'DA', RENDERBUFFER:'RB', DEPTH_COMPONENT16:'D16', DEPTH_COMPONENT24:'D24', DEPTH_COMPONENT:'DC', UNSIGNED_INT:'UI', COLOR_BUFFER_BIT:16384, NONE:'NONE', LINEAR:'LIN', NEAREST:'NEA', CLAMP_TO_EDGE:'CL', TEXTURE_MIN_FILTER:'MIN', TEXTURE_MAG_FILTER:'MAG', TEXTURE_WRAP_S:'WS', TEXTURE_WRAP_T:'WT', POINTS:'PTS', LINES:'LNS', TRIANGLES:'TRI', TRIANGLE_STRIP:'STRIP', getExtension(n){ return {} }, createTexture(){ return {id:'T'+(this._t=(this._t||0)+1)} }, bindTexture(t,tex){ push('bindTexture', tex ? tex.id : 'null') }, texParameteri(t,k,v){ push('texParam', k, v) }, texImage2D(...a){ push('texImage', a.length) }, createFramebuffer(){ return {id:'F'+(this._f=(this._f||0)+1)} }, bindFramebuffer(t,fb){ push('bindFB', fb ? fb.id : 'null') }, framebufferTexture2D(t,a,tt,tex,l){ push('fbTex', a, tex.id) }, createRenderbuffer(){ return {id:'R'+(this._r=(this._r||0)+1)} }, bindRenderbuffer(t,rb){ push('bindRB', rb.id) }, renderbufferStorage(t,f,w,h){ push('rbStore', f, w, h) }, renderbufferStorageMultisample(t,s,f,w,h){ push('rbStoreMS', s, f, w, h) }, framebufferRenderbuffer(t,a,rt,rb){ push('fbRB', a, rb.id) }, drawBuffers(arr){ push('drawBuffers', arr.join(',')) }, blitFramebuffer(...a){ push('blit', a.join(',')) }, drawArrays(m,f,c){ push('draw', m, f, c) }, readPixels(x,y,w,h,fmt,type,view){ push('readPixels', x, y, w, h, view.length, fmt, type); for (let i = 0; i < view.length; i++) view[i] = (x + y + w + h + i) & 255; } } } }")

(define gllog (js-get (js-global) "__gllog"))
(define (entry i) (js->string (js-index gllog i)))
(define (log-len) (js->number (js-get gllog "length")))
(define (prefix? p s)
  (and (<= (string-length p) (string-length s))
       (string=? p (substring s 0 (string-length p)))))

(fx-init! (js-get (js-global) "__mockcanvas"))

;; 238 marks every byte the read must NOT touch
(define (poison! base n)
  (let loop ((i 0))
    (when (< i n) (%mem-u8-set! (+ base i) 238) (loop (+ i 1)))))
;; the mock's pattern: byte i of a read of (x y w h) is (x+y+w+h+i)
(define (byte-ok base s i)
  (= (%mem-u8-ref (+ base i)) (remainder (+ s i) 256)))
(define (clean? base i) (= (%mem-u8-ref (+ base i)) 238))

(define pa (fx-alloc! 64))
(define pb (fx-alloc! 64))

;; ---- (a) the rectangle reaches gl.readPixels unpermuted ----
(poison! pa 64)
(define mark1 (log-len))
(cmd-begin!)
(cmd-read-pixels! 2 3 3 2 pa)             ; 3x2 RGBA8 = 24 bytes
(cmd-flush!)
(define encode-ok
  (and (= (log-len) (+ mark1 1))
       (string=? (entry mark1) "readPixels:2:3:3:2:24:RGBA:UB")))

;; ---- (b) the bytes land AT base, and exactly w*h*4 of them ----
;; first, middle and last texel are checked separately: a length
;; computed as w*h*3 writes 18 bytes and leaves byte 23 poisoned,
;; while an over-long view would spill past byte 23
(define bytes-ok
  (and (byte-ok pa 10 0)
       (byte-ok pa 10 11)
       (byte-ok pa 10 23)
       (clean? pa 24)
       (clean? pa 25)))

;; ---- (c) two reads at two bases do not tread on each other ----
;; the patterns differ from byte 0 (10... vs 6...), so an encoder that
;; dropped `base` and always wrote to one place is visible
(poison! pa 64)
(poison! pb 64)
(cmd-begin!)
(cmd-read-pixels! 2 3 3 2 pa)             ; pattern base 10, 24 bytes
(cmd-read-pixels! 1 1 2 2 pb)             ; pattern base 6, 16 bytes
(cmd-flush!)
(define two-bases-ok
  (and (byte-ok pa 10 0) (byte-ok pa 10 23) (clean? pa 24)
       (byte-ok pb 6 0) (byte-ok pb 6 15) (clean? pb 16)))

;; ---- (d) fx-read-target! binds the target BEFORE reading it ----
(define tgt (fx-target! 4 2))
(define pt (fx-alloc! 64))
(poison! pt 64)
(define mark4 (log-len))
(cmd-begin!)
(fx-read-target! tgt pt)
(cmd-flush!)
(define target-read-ok
  (and (= (log-len) (+ mark4 2))          ; exactly bind, then read
       (prefix? "bindFB:F" (entry mark4)) ; a framebuffer, not the canvas
       (string=? (entry (+ mark4 1)) "readPixels:0:0:4:2:32:RGBA:UB")
       (byte-ok pt 6 0)                   ; 0+0+4+2 = 6
       (byte-ok pt 6 31)
       (clean? pt 32)))

;; ---- (e) a multisampled target reads through its RESOLVE fb ----
;; gl-target-msaa! creates the resolve framebuffer (F2) before the
;; multisampled one (F3); the blit runs F3 -> F2, so a read that
;; bound the multisampled framebuffer would say F3 here -- and in a
;; real context readPixels on it is an error
(define ms (fx-target-msaa! 2 2 4))
(define pm (fx-alloc! 32))
(poison! pm 32)
(define mark5 (log-len))
(cmd-begin!)
(fx-resolve! ms)
(fx-read-target! ms pm)
(cmd-flush!)
(define msaa-read-ok
  (and (= (log-len) (+ mark5 6))
       (string=? (entry mark5) "bindFB:F3")          ; blit source
       (string=? (entry (+ mark5 1)) "bindFB:F2")    ; blit destination
       (string=? (entry (+ mark5 2)) "blit:0,0,2,2,0,0,2,2,16384,NEA")
       (string=? (entry (+ mark5 3)) "bindFB:null")
       (string=? (entry (+ mark5 4)) "bindFB:F2")    ; the READ binds it
       (string=? (entry (+ mark5 5)) "readPixels:0:0:2:2:16:RGBA:UB")
       (byte-ok pm 4 0) (byte-ok pm 4 15) (clean? pm 16)))

;; ---- (f) reads and draws coexist in one flush ----
;; the positive control for the opcode's word count: if the replayer
;; advanced by anything but five words, the draw between the two reads
;; would decode from the wrong offset
(poison! pb 64)
(poison! pt 64)
(define mark6 (log-len))
(cmd-begin!)
(cmd-read-pixels! 0 0 2 1 pb)             ; 8 bytes, pattern base 3
(cmd-draw-arrays! GL-TRIANGLES 0 3)
(cmd-read-pixels! 1 0 1 1 pt)             ; 4 bytes, pattern base 3
(cmd-flush!)
(define coexist-ok
  (and (= (log-len) (+ mark6 3))
       (string=? (entry mark6) "readPixels:0:0:2:1:8:RGBA:UB")
       (string=? (entry (+ mark6 1)) "draw:TRI:0:3")
       (string=? (entry (+ mark6 2)) "readPixels:1:0:1:1:4:RGBA:UB")
       (byte-ok pb 3 0) (byte-ok pb 3 7) (clean? pb 8)
       (byte-ok pt 3 0) (byte-ok pt 3 3) (clean? pt 4)))

(and encode-ok bytes-ok two-bases-ok target-read-ok msaa-read-ok
     coexist-ok)
