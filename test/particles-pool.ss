;; expect: #t
;; (gfx particles): the pool's bookkeeping, and the shape of its shaders.
;;
;; The GL underneath is a recording mock, and that mock -- like every
;; other one in this tree -- has compileShader() {} and a
;; getShaderParameter that answers true.  So NOTHING here says the
;; shaders are valid GLSL; that question is answered by tools/cdp.mjs
;; against a real compiler, and these cells are about the pool: how much
;; of it is reserved, what it refuses, and what it counts.
;;
;; The one shader property that IS structural, and so belongs here, is
;; that neither shader carries a raw string.  A raw string is opaque to
;; anything that walks the forms -- it can hide a use of a name, or
;; introduce a declaration nothing can see -- so "there are none" is
;; worth pinning rather than re-establishing by reading.
(import (rnrs) (web js) (gfx gl) (gfx fx) (gfx particles))

(js-eval "globalThis.__ls={}; globalThis.addEventListener=(k,f)=>{globalThis.__ls[k]=f};
globalThis.requestAnimationFrame=f=>1;
globalThis.__mockcanvas={ width:640, height:480, addEventListener(k,f){},
 getContext(kind){ let n=0; const o={};
  for (const k of ['VERTEX_SHADER','FRAGMENT_SHADER','COMPILE_STATUS','LINK_STATUS',
   'ARRAY_BUFFER','DYNAMIC_DRAW','FLOAT','POINTS','TRIANGLES','BLEND','SRC_ALPHA','ONE',
   'ONE_MINUS_SRC_ALPHA','DEPTH_TEST','COLOR_BUFFER_BIT','DEPTH_BUFFER_BIT']) o[k]=k;
  o.createShader=()=>({}); o.shaderSource=()=>{}; o.compileShader=()=>{};
  o.getShaderParameter=()=>true; o.getShaderInfoLog=()=>'';
  o.createProgram=()=>({id:'P'+(++n)}); o.attachShader=()=>{}; o.linkProgram=()=>{};
  o.getProgramParameter=()=>true; o.getProgramInfoLog=()=>'';
  o.bindAttribLocation=()=>{}; o.getUniformLocation=(p,nm)=>({id:nm});
  o.createBuffer=()=>({id:'B'+(++n)}); o.bindBuffer=()=>{}; o.bufferData=()=>{};
  o.createVertexArray=()=>({id:'V'+(++n)}); o.bindVertexArray=()=>{};
  o.enableVertexAttribArray=()=>{}; o.vertexAttribPointer=()=>{};
  o.vertexAttribDivisor=()=>{}; o.useProgram=()=>{}; o.drawArrays=()=>{};
  o.enable=()=>{}; o.disable=()=>{}; o.blendFunc=()=>{}; o.depthMask=()=>{};
  o.uniform1f=()=>{}; o.uniformMatrix4fv=()=>{}; o.viewport=()=>{};
  o.clearColor=()=>{}; o.clear=()=>{};
  return o; } };")
(fx-init! (js-get (js-global) "__mockcanvas"))

(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))
(define (refuses? thunk)
  (guard (e ((error? e) #t) (else #f)) (begin (thunk) #f)))
;; a raw string anywhere in the forms, at any depth
(define (has-string? x)
  (cond ((string? x) #t)
        ((pair? x) (or (has-string? (car x)) (has-string? (cdr x))))
        (else #f)))

;; ---- the reserve comes from the ratio, not from a constant ----
(check "a quarter of the pool is reserved by default"
       (let ((p (make-particles 64)))
         (and (= (particles-capacity p) 64) (= (particles-ambient-capacity p) 16))))
(check "the ratio decides the reserve"
       (= (particles-ambient-capacity (make-particles 64 0.5)) 32))
(check "a zero ratio reserves nothing"
       (= (particles-ambient-capacity (make-particles 64 0.0)) 0))

;; ---- refusals at construction ----
(check "a capacity below the floor is refused"  (refuses? (lambda () (make-particles 8))))
(check "a non-integer capacity is refused"      (refuses? (lambda () (make-particles 64.5))))
(check "a ratio above one is refused"           (refuses? (lambda () (make-particles 64 1.5))))
(check "a negative ratio is refused"            (refuses? (lambda () (make-particles 64 -0.1))))
(check "a non-positive maximum size is refused" (refuses? (lambda () (make-particles 64 0.25 0.0))))

;; ---- refusals at emission ----
(check "a particle with no lifetime is refused"
       (refuses? (lambda () (particle-emit! (make-particles 64) 0. 0. 0. 0. 0. 0. 1. 1. 1. 0.0 1.0 0.))))
(check "a particle with no size is refused"
       (refuses? (lambda () (particle-emit! (make-particles 64) 0. 0. 0. 0. 0. 0. 1. 1. 1. 1.0 0.0 0.))))
;; a pool entirely reserved has nowhere to put a one-shot, and says so
;; rather than quietly writing over an ambient particle
(check "emitting into a wholly reserved pool is refused"
       (refuses? (lambda () (particle-emit! (make-particles 64 1.0) 0. 0. 0. 0. 0. 0. 1. 1. 1. 1.0 1.0 0.))))
(check "the ambient reserve refuses the one past its end"
       (let ((p (make-particles 64 0.25)))     ; 16 ambient slots
         (let fill ((i 0)) (when (< i 16) (particle-ambient! p 0. 0. 0. 1. 1. 1. 1.0 0.0) (fill (+ i 1))))
         (refuses? (lambda () (particle-ambient! p 0. 0. 0. 1. 1. 1. 1.0 0.0)))))

;; ---- what it counts ----
(check "emitting counts one"
       (let ((p (make-particles 64)))
         (particle-emit! p 0. 0. 0. 0. 0. 0. 1. 1. 1. 1.0 1.0 0.)
         (= (particles-emitted p) 1)))
(check "a burst counts every particle it made"
       (let ((p (make-particles 64)))
         (particle-burst! p 0. 0. 0. 5 1.0 1. 1. 1. 1.0 1.0 0.)
         (= (particles-emitted p) 5)))
(check "the ring keeps taking emissions past the pool size"
       (let ((p (make-particles 64 0.25)))     ; 48 one-shot slots
         (let fill ((i 0))
           (when (< i 100)
             (particle-emit! p 0. 0. 0. 0. 0. 0. 1. 1. 1. 1.0 1.0 0.)
             (fill (+ i 1))))
         (= (particles-emitted p) 100)))
(check "ambient particles are not counted as emissions"
       (let ((p (make-particles 64)))
         (particle-ambient! p 0. 0. 0. 1. 1. 1. 1.0 0.0)
         (= (particles-emitted p) 0)))

;; ---- the shaders are structure, not text ----
(check "the vertex shader carries no raw string"
       (not (has-string? (particles-vertex-shader))))
(check "the fragment shader carries no raw string"
       (not (has-string? (particles-fragment-shader))))
(check "and the walker would have said so if there were one"
       (has-string? '(define (main) void (set! x "a_life.y < 0.0"))))
(display (= failed 0))
