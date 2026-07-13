;; expect: #t
;; (web fx) against recording mocks: programs wire their own
;; attributes/uniforms from the glsl forms, the allocator hands out
;; aligned staging memory, the loop pumps t/dt and frames commands,
;; input state follows fired events.
(import (rnrs) (web js) (web gl) (web glsl) (web fx))

(js-eval "globalThis.__gllog = []; globalThis.__ls = {}; globalThis.addEventListener = (k,f) => { globalThis.__ls[k] = f }; globalThis.__frames = []; globalThis.requestAnimationFrame = f => { globalThis.__frames.push(f); return globalThis.__frames.length }; globalThis.__el2 = { addEventListener(k,f){ globalThis.__ls['el2-'+k] = f } }; globalThis.__mockcanvas = { width:640, height:480, addEventListener(k,f){ globalThis.__ls[k] = f }, getContext(kind) { const log = globalThis.__gllog; const push = (...a) => log.push(a.join(':')); return { VERTEX_SHADER:'VS', FRAGMENT_SHADER:'FS', COMPILE_STATUS:'CS', LINK_STATUS:'LS', COLOR_BUFFER_BIT:16384, DEPTH_BUFFER_BIT:256, ARRAY_BUFFER:'AB', DYNAMIC_DRAW:'DD', FLOAT:'F', POINTS:'PTS', LINES:'LNS', TRIANGLES:'TRI', TRIANGLE_STRIP:'STRIP', TEXTURE_2D:'T2D', TEXTURE0:33984, TEXTURE_MIN_FILTER:'MIN', TEXTURE_MAG_FILTER:'MAG', TEXTURE_WRAP_S:'WS', TEXTURE_WRAP_T:'WT', LINEAR:'LIN', CLAMP_TO_EDGE:'CL', RGBA:'RGBA', UNSIGNED_BYTE:'UB', BLEND:'BL', SRC_ALPHA:'SA', ONE:'ONE', ONE_MINUS_SRC_ALPHA:'OMSA', createShader(k){ return {kind:k} }, shaderSource(s,src){}, compileShader(s){}, getShaderParameter(){ return true }, createProgram(){ return {id:'P'+(this._p=(this._p||0)+1)} }, attachShader(p,s){}, linkProgram(p){}, getProgramParameter(){ return true }, bindAttribLocation(p,i,n){ push('bindAttrib', i, n) }, createVertexArray(){ return {id:'V'+(this._v=(this._v||0)+1)} }, bindVertexArray(v){ push('bindVAO', v ? v.id : 'null') }, createBuffer(){ return {id:'B'+(this._b=(this._b||0)+1)} }, getUniformLocation(p,n){ return {id:'U:'+n} }, vertexAttribDivisor(l,d){ if (d > 0) push('divisor', l, d) }, drawElementsInstanced(m,c,t,o,n){ push('drawInst', m, c, n) }, createFramebuffer(){ return {id:'F'+(this._fb=(this._fb||0)+1)} }, bindFramebuffer(t,fb){ push('bindFB', fb ? fb.id : 'null') }, framebufferTexture2D(t,a,tt,tex,l){ push('fbTex', a, tex.id) }, createRenderbuffer(){ return {id:'R'+(this._rb=(this._rb||0)+1)} }, bindRenderbuffer(t,rb){ push('bindRB', rb.id) }, renderbufferStorage(t,f,w,h){ push('rbStore', f, w, h) }, framebufferRenderbuffer(t,a,rt,rb){ push('fbRB', a, rb.id) }, drawBuffers(arr){ push('drawBuffers', arr.join(',')) }, DEPTH_COMPONENT24:'D24', DEPTH_COMPONENT:'DC', UNSIGNED_INT:'UI', NEAREST:'NEA', FRAMEBUFFER:'FB', DEPTH_ATTACHMENT:'DA', COLOR_ATTACHMENT0:'CA0', RENDERBUFFER:'RB', DEPTH_COMPONENT16:'D16', NONE:'NONE', createTexture(){ return {id:'T'+(this._t=(this._t||0)+1)} }, bindTexture(t,tex){ push('bindTexture', tex.id) }, texParameteri(t,k,v){ push('texParam', k, v) }, generateMipmap(t){ push('genMip', t) }, texImage2D(...a){ const d = a[a.length-1]; push('texImage', d ? d.id : 'null') }, activeTexture(u){ push('activeTexture', u) }, enable(c){ push('gEnable', c) }, disable(c){ push('gDisable', c) }, blendFunc(a,b){ push('blendFunc', a, b) }, clearColor(...a){ push('clearColor', ...a.map(x=>x.toFixed(2))) }, clear(bits){ push('clear', bits) }, useProgram(p){ push('useProgram', p.id) }, bindBuffer(t,b){ push('bindBuffer', b.id) }, bufferData(t,arr,u){ push('bufferData', Array.from(arr).map(x=>x.toFixed(2)).join(',')) }, enableVertexAttribArray(l){ push('enable', l) }, vertexAttribPointer(...a){ push('attrib', a.join(',')) }, uniform1f(loc,x){ push('uniform1f', loc.id, x.toFixed(2)) }, uniform2f(loc,x,y){ push('uniform2f', loc.id, x.toFixed(2), y.toFixed(2)) }, uniform4f(loc,...a){ push('uniform4f', loc.id, a.map(x=>x.toFixed(1)).join(',')) }, uniform1i(loc,v){ push('uniform1i', loc.id, v) }, uniformMatrix4fv(loc,tr,arr){ push('uniformMat4', loc.id, arr.length, arr[0].toFixed(2), arr[12].toFixed(2)) }, drawArrays(m,f,c){ push('draw', m, f, c) }, viewport(...a){ push('viewport', a.join(',')) } } } }")

(define log (js-get (js-global) "__gllog"))
(define (entry i) (js->string (js-index log i)))
(define (log-len) (js->number (js-get log "length")))
(define (check-from base es)
  (let loop ((i base) (es es))
    (or (null? es)
        (and (or (string=? (entry i) (car es))
                 (begin (display "mismatch at ") (display i)
                        (display ": got ") (display (entry i))
                        (display " want ") (display (car es)) (newline)
                        #f))
             (loop (+ i 1) (cdr es))))))
(define (pump! ms)
  (let* ((fr (js-get (js-global) "__frames"))
         (n (js->number (js-get fr "length"))))
    (js-call (js-index fr (- n 1)) (js-undefined) ms)))
(define (fire! name evt)
  (js-call (js-get (js-get (js-global) "__ls") name) (js-undefined) evt))
(define (near? a b)
  (and (fl<? (fl- a b) 0.0001) (fl<? (fl- b a) 0.0001)))

;; ---- init + allocator ----
(fx-init! (js-get (js-global) "__mockcanvas"))
(define a1 (fx-alloc! 100))              ; first block: after the cmd
(define a2 (fx-alloc! 4))                ; region and the 128-byte m4
(define a3 (fx-alloc! 300000))           ; scratch; re-aligned to 8;
(define alloc-ok                         ; the big one grows memory
  (and (= a1 (+ 65536 128))
       (= a2 (+ 65640 128))
       (= (remainder a3 8) 0)
       (>= (* 65536 (%mem-size)) (+ a3 300000))))

;; ---- a program wired from its own forms ----
(define base-b (log-len))
(define p
  (fx-program!
   '((attribute vec2 a_pos) (attribute vec4 a_tint) (uniform vec2 u_res)
     (define (main) void (set! gl_Position (vec4 a_pos (fl 0) (fl 1)))))
   '((precision mediump float) (uniform float u_glow) (uniform sampler2D u_tex)
     (define (main) void (set! gl_FragColor (vec4 (fl 1) (fl 1) (fl 1) u_glow))))))
(define buf (fx-buffer!))
(define prog-ok
  (and (check-from base-b '("bindAttrib:0:a_pos" "bindAttrib:1:a_tint"))
       (= (fx-program-slot p) 0)
       (= (fx-program-stride p) 24)
       (= buf 4)))                       ; program 0, uniforms 1-3, buffer 4

;; ---- use + typed uniform dispatch (with fixnum coercion) ----
(define base-c (log-len))
(cmd-begin!)
(fx-use! p buf)
(fx-uniform! p 'u_glow 2)                ; fixnum in, 1f out
(fx-uniform! p 'u_res 640 480)
(fx-uniform! p 'u_tex 0)
(cmd-flush!)
(define use-ok
  (check-from base-c
              '("useProgram:P1" "bindVAO:V1" "bindBuffer:B1"
                "enable:0" "attrib:0,2,F,false,24,0"
                "enable:1" "attrib:1,4,F,false,24,8"
                "uniform1f:U:u_glow:2.00"
                "uniform2f:U:u_res:640.00:480.00"
                "uniform1i:U:u_tex:0")))

;; the second use of the same (program, buffer) pair rides the
;; recorded VAO: no pointer re-setup, just the rebind (plus the
;; array buffer, for dynamic uploads)
(define base-c2 (log-len))
(cmd-begin!)
(fx-use! p buf)
(cmd-flush!)
(define reuse-ok
  (check-from base-c2
              '("useProgram:P1" "bindVAO:V1" "bindBuffer:B1")))

;; ---- the uniform cache: a steady value costs one send, ever ----
(define base-u (log-len))
(cmd-begin!)
(fx-uniform! p 'u_glow 2)               ; same value as the last send
(fx-uniform! p 'u_res 640 480)          ; same again
(fx-uniform! p 'u_glow 3)               ; changed: this one encodes
(fx-uniform! p 'u_glow 3)               ; and settles again
(cmd-flush!)
(define ucache-ok
  (check-from base-u '("uniform1f:U:u_glow:3.00")))

;; ---- the timing pump: t/dt in seconds, no GL ----
(define ticks '())
(fx-ticks! (lambda (t dt) (set! ticks (cons (cons t dt) ticks))))
(pump! 1000)                             ; fixnum timestamp
(pump! 1016.5)
(define ticks-ok
  (and (= (length ticks) 2)
       (near? (car (cadr ticks)) 0.0)    ; first frame: t = dt = 0
       (near? (cdr (cadr ticks)) 0.0)
       (near? (car (car ticks)) 0.0165)
       (near? (cdr (car ticks)) 0.0165)))

;; ---- the frame loop: begin, viewport, commands, flush ----
(define base-e (log-len))
(define loop-t -1.0)
(fx-loop! (lambda (t dt)
            (set! loop-t t)
            (cmd-clear! 0.0 0.0 0.0 1.0)))
(pump! 2000)
(define loop-ok
  (and (near? loop-t 0.0)
       (check-from base-e
                   '("viewport:0,0,640,480"
                     "clearColor:0.00:0.00:0.00:1.00"
                     "clear:16640"))))

;; ---- the fullscreen quad ----
(define base-f (log-len))
(define q
  (fx-fullscreen!
   '((precision mediump float)
     (uniform float u_time) (uniform vec2 u_resolution)
     (define (main) void
       (set! gl_FragColor (vec4 (fl 0) (fl 0) (fl 0) (fl 1)))))))
(cmd-begin!)
(fx-fullscreen-use! q 1.5)
(fx-fullscreen-draw! q)
(cmd-flush!)
(define quad-ok
  (check-from base-f
              '("bindAttrib:0:a_pos"
                "useProgram:P2" "bindVAO:V2" "bindBuffer:B2"
                "enable:0" "attrib:0,2,F,false,8,0"
                "bufferData:-1.00,-1.00,1.00,-1.00,-1.00,1.00,1.00,1.00"
                "uniform1f:U:u_time:1.50"
                "uniform2f:U:u_resolution:640.00:480.00"
                "draw:STRIP:0:4")))

;; ---- mat4 uniforms dispatch through the same table ----
(define base-m (log-len))
(define pm
  (fx-program!
   '((attribute vec2 a_pos) (uniform mat4 u_mvp)
     (define (main) void
       (set! gl_Position (* u_mvp (vec4 a_pos (fl 0) (fl 1))))))
   '((precision mediump float)
     (define (main) void
       (set! gl_FragColor (vec4 (fl 1) (fl 1) (fl 1) (fl 1)))))))
(cmd-begin!)
(fx-uniform! pm 'u_mvp
             (vector 1.0 0.0 0.0 0.0  0.0 1.0 0.0 0.0
                     0.0 0.0 1.0 0.0  9.0 0.0 0.0 1.0))
(cmd-flush!)
(define mat-ok
  (check-from base-m '("bindAttrib:0:a_pos"
                       "uniformMat4:U:u_mvp:16:1.00:9.00")))

;; ---- polled input from fired events ----
(fx-init-input!)                         ; default element: the canvas
(define input-ok
  (and (not (key-down? "ArrowLeft"))
       (begin (fire! "keydown" (js-eval "({key:'ArrowLeft'})"))
              (key-down? "ArrowLeft"))
       (begin (fire! "keyup" (js-eval "({key:'ArrowLeft'})"))
              (not (key-down? "ArrowLeft")))
       (begin (fire! "pointermove" (js-eval "({offsetX:12, offsetY:34})"))
              (and (fl=? (pointer-x) 12.0) (fl=? (pointer-y) 34.0)))
       (not (pointer-down?))
       (begin (fire! "pointerdown" (js-eval "({})")) (pointer-down?))
       (begin (fire! "pointerup" (js-eval "({})")) (not (pointer-down?)))))

;; input on an explicit element (the Three.js path: no GL needed)
(fx-init-input! (js-get (js-global) "__el2"))
(define input2-ok
  (begin (fire! "el2-pointermove" (js-eval "({offsetX:7, offsetY:9})"))
         (and (fl=? (pointer-x) 7.0) (fl=? (pointer-y) 9.0))))

;; ---- instancing: i_* attributes split into their own layout ----
(define pi2
  (fx-program!
   '((attribute vec3 a_pos) (attribute vec3 i_offset)
     (attribute vec3 i_tint) (uniform mat4 u_vp)
     (define (main) void
       (set! gl_Position (* u_vp (vec4 (+ a_pos i_offset) (fl 1))))))
   '((precision mediump float)
     (define (main) void
       (set! gl_FragColor (vec4 (fl 1) (fl 1) (fl 1) (fl 1)))))))
(define vb2 (fx-buffer!))
(define ib2 (fx-buffer!))
(define base-i (log-len))
(cmd-begin!)
(fx-use-instanced! pi2 vb2 ib2)
(cmd-draw-elements-instanced! GL-TRIANGLES 36 1000)
(cmd-flush!)
(define inst-ok
  (and (= (fx-program-stride pi2) 12)      ; a_pos only
       (= (fx-program-istride pi2) 24)     ; two instance vec3s
       (check-from base-i
                   '("useProgram:P4" "bindVAO:V3" "bindBuffer:B3"
                     "enable:0" "attrib:0,3,F,false,12,0"
                     "bindBuffer:B4"
                     "enable:1" "attrib:1,3,F,false,24,0"
                     "divisor:1:1"
                     "enable:2" "attrib:2,3,F,false,24,12"
                     "divisor:2:1"
                     "drawInst:TRI:36:1000"))))

;; ---- offscreen targets: binding sets the matching viewport ----
(define base-t (log-len))
(define tgt (fx-target! 320 240))
(cmd-begin!)
(fx-bind-target! tgt)
(fx-bind-canvas!)
(cmd-flush!)
(define target-ok
  (and (fx-target? tgt)
       (= (fx-target-width tgt) 320)
       (= (fx-target-height tgt) 240)
       (check-from (+ base-t 12)          ; skip the creation sequence
                   '("bindFB:F1" "viewport:0,0,320,240"
                     "bindFB:null" "viewport:0,0,640,480"))))

;; ---- pointer lock: capture on click, relative motion, release ----
(js-eval "globalThis.document = { pointerLockElement: null, addEventListener(k,f){ globalThis.__ls['doc-'+k] = f } }; globalThis.__mockcanvas.requestPointerLock = () => { globalThis.__plreq = (globalThis.__plreq || 0) + 1 }")
(pointer-lock!)
(define lock-ok
  (and (not (pointer-locked?))
       ;; a click asks the browser for capture
       (begin (fire! "click" (js-eval "({})"))
              (= (js->number (js-get (js-global) "__plreq")) 1))
       ;; the grant arrives as pointerlockchange
       (begin (js-eval "globalThis.document.pointerLockElement = globalThis.__mockcanvas")
              (fire! "doc-pointerlockchange" (js-eval "({})"))
              (pointer-locked?))
       ;; motion accumulates; consuming it resets
       (begin (fire! "doc-mousemove" (js-eval "({movementX:4, movementY:-2})"))
              (fire! "doc-mousemove" (js-eval "({movementX:4, movementY:-2})"))
              (let ((d (pointer-motion!)))
                (and (fl=? (car d) 8.0) (fl=? (cdr d) -4.0))))
       (let ((d (pointer-motion!)))
         (and (fl=? (car d) 0.0) (fl=? (cdr d) 0.0)))
       ;; Esc releases: state flips, motion is ignored again
       (begin (js-eval "globalThis.document.pointerLockElement = null")
              (fire! "doc-pointerlockchange" (js-eval "({})"))
              (fire! "doc-mousemove" (js-eval "({movementX:9, movementY:9})"))
              (and (not (pointer-locked?))
                   (let ((d (pointer-motion!)))
                     (and (fl=? (car d) 0.0) (fl=? (cdr d) 0.0)))))))

;; ---- the fixed-timestep loop: sim at its own cadence ----
(define sims 0)
(define alphas '())
(fx-loop-fixed! 0.01
                (lambda (step) (set! sims (+ sims 1)))
                (lambda (alpha t dt) (set! alphas (cons alpha alphas))))
(pump! 5000)                            ; first frame: dt 0, no sim
(pump! 5025)                            ; +25ms: two steps, half left
(pump! 15025)                           ; a stall: clamped to 3 more
(define fixed-ok
  (and (= sims 5)
       (near? (car (cdr alphas)) 0.5)
       (near? (car alphas) 1.0)))

(and alloc-ok prog-ok use-ok reuse-ok ucache-ok ticks-ok loop-ok quad-ok mat-ok
     input-ok input2-ok inst-ok target-ok lock-ok fixed-ok)
