;; expect: #t
;; Four rasterizer states travel in the command stream: the depth
;; comparison, the polygon offset, the colour write mask and face
;; culling.
;;
;; Before these, the stream carried only the depth test, the depth
;; write mask and blending, so a caller wanting any of the four set it
;; with a direct call between two flushes.  That puts the state change
;; where the CALL happened, not where the command sits in the stream:
;; a frame encoded in one order and replayed in another -- the shape of
;; defect test/viewport-uniforms-are-resolved-at-replay.ss was written
;; for -- applies it to the wrong draws.  So the rows below read the
;; GL calls in replay order, interleaved with the draws they govern.
;;
;; THE CONTRACT, as these rows state it:
;;   (cmd-depth-func! f), f one of never less equal lequal greater
;;     notequal gequal always -> gl.depthFunc
;;   (cmd-polygon-offset! factor units) -> enables POLYGON_OFFSET_FILL
;;     and sets gl.polygonOffset; factor and units both zero disables
;;     it (an offset of zero changes nothing, so the two agree on every
;;     pixel)
;;   (cmd-color-mask! r g b a) -> gl.colorMask; each argument is a
;;     Scheme truth value, as cmd-depth! reads its argument, so 0 and
;;     '() mean true
;;   (cmd-cull-face! m), m one of off back front front-and-back ->
;;     off disables CULL_FACE, the others enable it and set gl.cullFace
;; A name outside those lists, and a factor or units that is not a
;; finite real number within the range of an f32 (the stream carries
;; f32), is refused when the command is ENCODED, with the
;; procedure's own name as who, and refused BEFORE ANY WORD IS WRITTEN:
;; an opcode left in the stream without its operands would desynchronise
;; everything replayed after it.  The cmd-pos rows pin that, and the
;; draw replayed after each refusal shows the stream still reads.
;;
;; THE MOCK'S ENUMS ARE GL'S NUMBERS, not their own names, and the log
;; turns them back into names: a replayer that passed the string "LESS"
;; where gl.LESS belongs would otherwise log exactly what a correct one
;; logs.  Anything that is not one of those numbers logs as NOT-AN-ENUM.
;;
;; ON THE TREE BEFORE THE CHANGE this cell does not compile: none of the
;; four procedures exists there.
(import (rnrs) (web js) (gfx gl) (gfx fx))

(js-eval "globalThis.__gllog = [];
globalThis.__mkcanvas = (w, h) => {
  const log = globalThis.__gllog; const push = (...a) => log.push(a.join(':'));
  const labels = { 0x0B71:'DEPTH_TEST', 0x0BE2:'BLEND', 0x0B44:'CULL_FACE', 0x8037:'POLYGON_OFFSET_FILL', 0x0405:'BACK', 0x0404:'FRONT', 0x0408:'FRONT_AND_BACK', 0x0200:'NEVER', 0x0201:'LESS', 0x0202:'EQUAL', 0x0203:'LEQUAL', 0x0204:'GREATER', 0x0205:'NOTEQUAL', 0x0206:'GEQUAL', 0x0207:'ALWAYS', 0x0302:'SRC_ALPHA', 1:'ONE', 0x0303:'ONE_MINUS_SRC_ALPHA' };
  const name = v => (typeof v === 'number' && labels[v] !== undefined) ? labels[v] : 'NOT-AN-ENUM(' + String(v) + ')';
  let ctx = null;
  return { width: w, height: h, addEventListener(k, f) {}, getContext(kind) {
    if (ctx) return ctx;
    ctx = { VERTEX_SHADER:'VS', FRAGMENT_SHADER:'FS', COMPILE_STATUS:'CS', LINK_STATUS:'LS', COLOR_BUFFER_BIT:16384, DEPTH_BUFFER_BIT:256, ARRAY_BUFFER:'AB', DYNAMIC_DRAW:'DD', FLOAT:'F', TRIANGLES:'TRI', POINTS:'PTS', LINES:'LIN', TRIANGLE_STRIP:'STRIP', DEPTH_TEST:0x0B71, BLEND:0x0BE2, CULL_FACE:0x0B44, POLYGON_OFFSET_FILL:0x8037, BACK:0x0405, FRONT:0x0404, FRONT_AND_BACK:0x0408, NEVER:0x0200, LESS:0x0201, EQUAL:0x0202, LEQUAL:0x0203, GREATER:0x0204, NOTEQUAL:0x0205, GEQUAL:0x0206, ALWAYS:0x0207, SRC_ALPHA:0x0302, ONE:1, ONE_MINUS_SRC_ALPHA:0x0303, ELEMENT_ARRAY_BUFFER:'EAB', UNSIGNED_SHORT:'US', TEXTURE_2D:'T2D', TEXTURE0:33984, TEXTURE_MIN_FILTER:'MIN', TEXTURE_MAG_FILTER:'MAG', TEXTURE_WRAP_S:'WS', TEXTURE_WRAP_T:'WT', LINEAR:'LIN', LINEAR_MIPMAP_LINEAR:'LML', CLAMP_TO_EDGE:'CL', RGBA:'RGBA', UNSIGNED_BYTE:'UB', NEAREST:'NEA', FRAMEBUFFER:'FB', DEPTH_ATTACHMENT:'DA', COLOR_ATTACHMENT0:'CA0', RENDERBUFFER:'RB', DEPTH_COMPONENT16:'D16', DEPTH_COMPONENT24:'D24', DEPTH_COMPONENT:'DC', UNSIGNED_INT:'UI', NONE:'NONE', VIEWPORT:'VP',
      createShader(k){ return {kind:k} }, shaderSource(){}, compileShader(){}, getShaderParameter(){ return true }, createProgram(){ return {id:'P'} }, attachShader(){}, linkProgram(){}, getProgramParameter(){ return true }, bindAttribLocation(){}, createVertexArray(){ return {id:'V'} }, bindVertexArray(){}, createBuffer(){ return {id:'B'} }, getUniformLocation(p,n){ return {id:'U:'+n} }, createTexture(){ return {id:'T'} }, bindTexture(){}, texParameteri(){}, generateMipmap(){}, texImage2D(){}, activeTexture(){}, createFramebuffer(){ return {id:'F'} }, bindFramebuffer(){}, framebufferTexture2D(){}, createRenderbuffer(){ return {id:'R'} }, bindRenderbuffer(){}, renderbufferStorage(){}, framebufferRenderbuffer(){}, drawBuffers(){}, blendFunc(a, b){ push('blendFunc', name(a), name(b)) }, clearColor(){}, clear(){}, useProgram(){}, bindBuffer(){}, bufferData(){}, enableVertexAttribArray(){}, vertexAttribPointer(){}, vertexAttribDivisor(){}, viewport(x, y, w, h){ push('viewport', x, y, w, h) }, getParameter(){ return null }, uniform1f(){}, uniform2f(){}, uniform3f(){}, uniform1i(){}, uniform4f(){}, uniformMatrix4fv(){},
      enable(c){ push('enable', name(c)) }, disable(c){ push('disable', name(c)) },
      depthMask(b){ push('depthMask', b) },
      depthFunc(f){ push('depthFunc', name(f)) },
      polygonOffset(a, b){ push('polygonOffset', Number(a).toFixed(2), Number(b).toFixed(2)) },
      colorMask(r, g, b, a){ push('colorMask', r, g, b, a) },
      cullFace(m){ push('cullFace', name(m)) },
      drawArrays(m, f, c){ push('draw', c) } };
    return ctx; } }; };")

(define log (js-get (js-global) "__gllog"))
(define (entries)
  (let loop ((i 0) (out '()))
    (if (= i (js->number (js-get log "length")))
        (reverse out)
        (loop (+ i 1) (cons (js->string (js-index log i)) out)))))
(define (clear-log!) (js-set! log "length" 0))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect) (set! fails (cons (list name 'got got 'want expect) fails))))
(define (try thunk) (guard (e (#t (list 'raised (condition-who e)))) (thunk)))

(fx-init! (js-call (js-get (js-global) "__mkcanvas") (js-undefined) 64 64))

;; one frame: the thunk encodes between cmd-begin! and cmd-flush!, and
;; the answer is what GL saw, in order.  A draw of n vertices logs
;; "draw:n", so each draw names itself.
(define (frame thunk)
  (clear-log!) (cmd-begin!) (thunk) (cmd-flush!) (entries))
(define (D n) (cmd-draw-arrays! GL-TRIANGLES 0 n))

;; ---- CONTROLS: the instrument reads the existing state commands ----
(want "CONTROL cmd-depth! and cmd-depth-write! replay between their draws"
      (frame (lambda () (D 3) (cmd-depth! #t) (D 6) (cmd-depth-write! #f) (D 9)))
      '("draw:3" "enable:DEPTH_TEST" "draw:6" "depthMask:false" "draw:9"))
(want "CONTROL cmd-blend! and cmd-viewport! still replay as they did"
      (frame (lambda () (cmd-blend! 'alpha) (D 3) (cmd-viewport! 1 2 30 40) (cmd-blend! 'off) (D 6)))
      '("enable:BLEND" "blendFunc:SRC_ALPHA:ONE_MINUS_SRC_ALPHA" "draw:3"
        "viewport:1:2:30:40" "disable:BLEND" "draw:6"))

;; ---- the depth comparison: every name, and its place in the stream ----
(for-each
 (lambda (pair)
   (want (string-append "depth-func " (symbol->string (car pair)))
         (try (lambda () (frame (lambda () (D 3) (cmd-depth-func! (car pair)) (D 6)))))
         (list "draw:3" (string-append "depthFunc:" (cdr pair)) "draw:6")))
 '((never . "NEVER") (less . "LESS") (equal . "EQUAL") (lequal . "LEQUAL")
   (greater . "GREATER") (notequal . "NOTEQUAL") (gequal . "GEQUAL")
   (always . "ALWAYS")))

;; ---- face culling: on, which face, and off again ----
(want "cull-face back, then off, each between its draws"
      (try (lambda () (frame (lambda () (D 3) (cmd-cull-face! 'back) (D 6)
                                     (cmd-cull-face! 'off) (D 9)))))
      '("draw:3" "enable:CULL_FACE" "cullFace:BACK" "draw:6" "disable:CULL_FACE" "draw:9"))
(want "cull-face front"
      (try (lambda () (frame (lambda () (cmd-cull-face! 'front) (D 3)))))
      '("enable:CULL_FACE" "cullFace:FRONT" "draw:3"))
(want "cull-face front-and-back"
      (try (lambda () (frame (lambda () (cmd-cull-face! 'front-and-back) (D 3)))))
      '("enable:CULL_FACE" "cullFace:FRONT_AND_BACK" "draw:3"))

;; ---- the colour write mask: each channel independently ----
(want "color-mask t f t f"
      (try (lambda () (frame (lambda () (D 3) (cmd-color-mask! #t #f #t #f) (D 6)))))
      '("draw:3" "colorMask:true:false:true:false" "draw:6"))
(want "color-mask f t f t (no channel is read from another's slot)"
      (try (lambda () (frame (lambda () (cmd-color-mask! #f #t #f #t) (D 3)))))
      '("colorMask:false:true:false:true" "draw:3"))
(for-each
 (lambda (row)
   (want (string-append "color-mask one channel " (cadr row))
         (try (lambda () (frame (lambda () (apply cmd-color-mask! (car row)) (D 3)))))
         (list (string-append "colorMask:" (cadr row)) "draw:3")))
 '(((#t #f #f #f) "true:false:false:false")
   ((#f #t #f #f) "false:true:false:false")
   ((#f #f #t #f) "false:false:true:false")
   ((#f #f #f #t) "false:false:false:true")))
(want "color-mask reads Scheme truth: 0 and '() are true"
      (try (lambda () (frame (lambda () (cmd-color-mask! 0 '() #f 1) (D 3)))))
      '("colorMask:true:true:false:true" "draw:3"))

;; ---- the polygon offset: set, negative, and zero-zero disables ----
(want "polygon-offset 1.5 2.0 enables and sets"
      (try (lambda () (frame (lambda () (D 3) (cmd-polygon-offset! 1.5 2.0) (D 6)))))
      '("draw:3" "enable:POLYGON_OFFSET_FILL" "polygonOffset:1.50:2.00" "draw:6"))
(want "polygon-offset takes negative values (pulled toward the eye)"
      (try (lambda () (frame (lambda () (cmd-polygon-offset! -1.0 -4.0) (D 3)))))
      '("enable:POLYGON_OFFSET_FILL" "polygonOffset:-1.00:-4.00" "draw:3"))
(want "polygon-offset takes exact numbers"
      (try (lambda () (frame (lambda () (cmd-polygon-offset! 2 1/2) (D 3)))))
      '("enable:POLYGON_OFFSET_FILL" "polygonOffset:2.00:0.50" "draw:3"))
(want "polygon-offset with a factor and zero units still enables"
      (try (lambda () (frame (lambda () (cmd-polygon-offset! 1.0 0.0) (D 3)))))
      '("enable:POLYGON_OFFSET_FILL" "polygonOffset:1.00:0.00" "draw:3"))
(want "polygon-offset -0.0 0 disables: a zero of either sign is zero"
      (try (lambda () (frame (lambda () (cmd-polygon-offset! -0.0 0) (D 3)))))
      '("disable:POLYGON_OFFSET_FILL" "draw:3"))
(want "polygon-offset 0 0 disables"
      (try (lambda () (frame (lambda () (cmd-polygon-offset! 0.0 0.0) (D 3)))))
      '("disable:POLYGON_OFFSET_FILL" "draw:3"))
(want "polygon-offset with only one of the two zero still enables"
      (try (lambda () (frame (lambda () (cmd-polygon-offset! 0.0 1.0) (D 3)))))
      '("enable:POLYGON_OFFSET_FILL" "polygonOffset:0.00:1.00" "draw:3"))

;; ---- refusals: at encode time, by name, and nothing written ----
(define (refused-cleanly name thunk who)
  ;; the refusal lands in a stream that already holds commands: a draw
  ;; and a state change before it, a draw after it, all replayed
  (clear-log!)
  (cmd-begin!)
  (D 5) (cmd-depth! #t)
  (let* ((before (cmd-pos))
         (draws (cmd-draws))
         (r (try thunk))
         (after (cmd-pos)))
    (want (string-append name ": refused with who") r (list 'raised who))
    (want (string-append name ": no word written") (- after before) 0)
    (want (string-append name ": the draw count kept") (cmd-draws) draws)
    (D 3)
    (cmd-flush!)
    (want (string-append name ": what came before and after it replays")
          (entries) '("draw:5" "enable:DEPTH_TEST" "draw:3"))))

(refused-cleanly "depth-func of an unknown name"
                 (lambda () (cmd-depth-func! 'lesser)) 'cmd-depth-func!)
(refused-cleanly "depth-func of a string"
                 (lambda () (cmd-depth-func! "less")) 'cmd-depth-func!)
(refused-cleanly "cull-face of an unknown name"
                 (lambda () (cmd-cull-face! 'sideways)) 'cmd-cull-face!)
(refused-cleanly "cull-face of #f (off is a name, not a truth value)"
                 (lambda () (cmd-cull-face! #f)) 'cmd-cull-face!)
(refused-cleanly "polygon-offset of a NaN factor"
                 (lambda () (cmd-polygon-offset! +nan.0 1.0)) 'cmd-polygon-offset!)
(refused-cleanly "polygon-offset of infinite units"
                 (lambda () (cmd-polygon-offset! 1.0 +inf.0)) 'cmd-polygon-offset!)
(refused-cleanly "polygon-offset of a symbol"
                 (lambda () (cmd-polygon-offset! 'a 1.0)) 'cmd-polygon-offset!)
(refused-cleanly "polygon-offset of a complex number"
                 (lambda () (cmd-polygon-offset! 1.0 1+2i)) 'cmd-polygon-offset!)
(refused-cleanly "polygon-offset of NaN units"
                 (lambda () (cmd-polygon-offset! 1.0 +nan.0)) 'cmd-polygon-offset!)
(refused-cleanly "polygon-offset of a negative infinite factor"
                 (lambda () (cmd-polygon-offset! -inf.0 1.0)) 'cmd-polygon-offset!)
(refused-cleanly "polygon-offset of symbol units"
                 (lambda () (cmd-polygon-offset! 1.0 'a)) 'cmd-polygon-offset!)
;; finite as a Scheme number is not enough: the stream carries f32, and a
;; value past the largest f32 would reach GL as an infinity
(refused-cleanly "polygon-offset of a factor past the largest f32"
                 (lambda () (cmd-polygon-offset! 1e39 1.0)) 'cmd-polygon-offset!)
(refused-cleanly "polygon-offset of exact units past the largest f32"
                 (lambda () (cmd-polygon-offset! 1.0 10000000000000000000000000000000000000000)) 'cmd-polygon-offset!)
(want "polygon-offset of the largest f32 itself is accepted"
      (try (lambda () (frame (lambda () (cmd-polygon-offset! 3.4028234663852886e38 1.0) (D 3)))))
      '("enable:POLYGON_OFFSET_FILL" "polygonOffset:3.4028234663852886e+38:1.00" "draw:3"))

;; ---- several states in one frame keep their own places ----
(want "all four, interleaved with draws, replay in encoded order"
      (try (lambda ()
             (frame (lambda ()
                      (cmd-cull-face! 'back) (cmd-depth-func! 'lequal) (D 3)
                      (cmd-polygon-offset! 1.0 1.0) (cmd-color-mask! #f #f #f #f) (D 6)
                      (cmd-color-mask! #t #t #t #t) (cmd-polygon-offset! 0 0)
                      (cmd-depth-func! 'less) (cmd-cull-face! 'off) (D 9)))))
      '("enable:CULL_FACE" "cullFace:BACK" "depthFunc:LEQUAL" "draw:3"
        "enable:POLYGON_OFFSET_FILL" "polygonOffset:1.00:1.00"
        "colorMask:false:false:false:false" "draw:6"
        "colorMask:true:true:true:true" "disable:POLYGON_OFFSET_FILL"
        "depthFunc:LESS" "disable:CULL_FACE" "draw:9"))

(display (if (null? fails) #t (reverse fails)))
