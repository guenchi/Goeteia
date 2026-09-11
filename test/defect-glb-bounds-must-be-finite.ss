;; expect: #t
;; REGRESSION GUARD.  Written as a red witness against lib/gfx/glb.ss at
;; 10c2f44.  A bound has to be a
;; number the file can carry.  glTF's min and max are arrays of numbers
;; and JSON has no spelling for an infinity, so the writer emits null --
;; and a null there is not an inaccurate file, it is an INVALID one.
;;
;; Measured on this fixture: a morph delta of 1e40 puts "null" in the
;; written JSON.
;;
;; 1e40 is FINITE as an f64 and overflows f32, which is what makes this
;; one this batch's to answer rather than a pre-existing hole.  Before
;; 10c2f44 the bound kept the f64 and a finite wrong number went into
;; the file; narrowing at the read is correct and turns the same input
;; into an infinity.  The value was always stored as +inf -- only the
;; bound changed -- so the repair is not to stop narrowing but to refuse
;; what cannot be written.
;;
;; +nan.0 is the same check's other half and is pre-existing, but NOT
;; for the reason it is tempting to write down.  Measured: with TWO
;; keyframes a nan is already refused -- the strict-ordering guard
;; compares it and every comparison against nan is false, so it reads as
;; "not increasing".  It slips through only where there is no ordering
;; comparison to catch it, which is a SINGLE keyframe: the t0 seed is
;; the bound, and both bounds serialise as null.  The two-key row below
;; is kept green on purpose to record which guard catches which case,
;; because a finiteness check that made it red would have replaced a
;; working guard rather than added the missing one.
;;
;; Refusing is right rather than clamping: glTF cannot spell these, and
;; a clamp would invent data the caller never gave.
;;
;; FIXED by testing $finite? after the narrowing at all four read sites.
;; Verified to discriminate rather than merely to pass: run against the
;; tree at ddb6c23, the three raises? rows go red AND the sweep names
;; the three inputs that put a null in the file.
(import (rnrs) (web js) (gfx gl) (gfx fx) (gfx gltf) (gfx glb) (web json))
(js-eval "globalThis.__mockcanvas = { width:64, height:64, addEventListener(k,f){}, getContext(kind) { return { createShader(){return {}}, shaderSource(){}, compileShader(){}, getShaderParameter(){return true}, createProgram(){return {}}, attachShader(){}, linkProgram(){}, getProgramParameter(){return true}, bindAttribLocation(){}, getUniformLocation(){return {}}, createBuffer(){return {}}, createVertexArray(){return {}}, createTexture(){return {}}, viewport(){}, enable(){}, clearColor(){}, clear(){} } } }")
(fx-init! (js-get (js-global) "__mockcanvas"))

(define fails '())
(define (want name got expect)
  (unless (equal? got expect)
    (set! fails (cons (list name 'got got 'want expect) fails))))
(define (raises? thunk) (guard (e (#t #t)) (thunk) #f))

(define layout '(position normal uv))
(define stride (glb-stride layout))
(define vcount 3)
(define vbase (fx-alloc! (* vcount stride)))
(define ibase (fx-alloc! 8))
(define nodes (list (list "root" -1 (vector 0.0 0.0 0.0) (vector 0.0 0.0 0.0 1.0) (vector 1.0 1.0 1.0))))
(define (rd-u32 at)
  (+ (%mem-u8-ref at) (* 256 (%mem-u8-ref (+ at 1)))
     (* 65536 (%mem-u8-ref (+ at 2))) (* 16777216 (%mem-u8-ref (+ at 3)))))
(define (jtext loc)
  (let* ((base (car loc)) (jlen (rd-u32 (+ base 12))) (bv (make-bytevector jlen)))
    (let l ((i 0)) (when (< i jlen) (bytevector-u8-set! bv i (%mem-u8-ref (+ base 20 i))) (l (+ i 1))))
    (utf8->string bv)))
(define (has? t needle)
  (let ((m (string-length needle)) (n (string-length t)))
    (let f ((k 0)) (cond ((> (+ k m) n) #f)
                         ((string=? (substring t k (+ k m)) needle) #t)
                         (else (f (+ k 1)))))))
(define (morph d)
  (glb-write! (list (list layout vbase vcount ibase 3
                          'targets (list (list (vector d 0.0 0.0 d 0.0 0.0 d 0.0 0.0) #f #f))
                          'weights '(1.0)))))
(define (times1 v)
  (glb-write! (list (list layout vbase vcount ibase 3)) 'nodes nodes
              'anims (list (list "a" (list (list 0 'translation v
                                                 (vector (vector 0.0 0.0 0.0))
                                                 1 'linear))))))
(define (times v)
  (glb-write! (list (list layout vbase vcount ibase 3)) 'nodes nodes
              'anims (list (list "a" (list (list 0 'translation v
                                                 (vector (vector 0.0 0.0 0.0) (vector 2.0 0.0 0.0))
                                                 2 'linear))))))

;; a finite f64 that overflows f32 must be refused, not written as null
(want 'morph-delta-overflowing-f32 (raises? (lambda () (morph 1e40))) #t)
(want 'keyframe-time-overflowing-f32 (raises? (lambda () (times (vector 0.0 1e40)))) #t)
;; a nan with ONE keyframe, where no ordering comparison exists to
;; catch it: the seed becomes both bounds and both serialise as null
(want 'keyframe-time-nan-single-key (raises? (lambda () (times1 (vector +nan.0)))) #t)

;; THE INVARIANT THE WHOLE CELL IS ABOUT, swept rather than asserted at
;; one point: no export that is ACCEPTED may write a null.  Each entry
;; answers 'refused or the presence of a null, and refused is a fine
;; answer -- what may not happen is a file going out with a null in it.
;;
;; This row must run its calls INSIDE the guard.  An earlier version
;; asked the same question with a bare (jtext (times1 (vector +nan.0)))
;; beside a raises? row that wrapped the identical call.  Once the call
;; raises, that is not a red: the cell TRAPS, the run reports
;; "unhandled exception ... (trap: unreachable)" instead of a verdict,
;; and every row after it never executes.  A cell that checks for a
;; raise has to catch it everywhere it provokes it, not only where it
;; is looking.
(define (null-or-refused thunk)
  (guard (e (#t 'refused)) (if (has? (jtext (thunk)) "null") 'WROTE-NULL 'clean)))
(for-each
 (lambda (entry)
   (let ((got (null-or-refused (cdr entry))))
     (want (car entry) (if (eq? got 'WROTE-NULL) 'WROTE-NULL 'ok) 'ok)))
 (list (cons 'sweep-finite-morph (lambda () (morph 0.5)))
       (cons 'sweep-overflowing-morph (lambda () (morph 1e40)))
       (cons 'sweep-finite-times (lambda () (times (vector 0.0 1.0))))
       (cons 'sweep-overflowing-times (lambda () (times (vector 0.0 1e40))))
       (cons 'sweep-nan-single-key (lambda () (times1 (vector +nan.0))))
       (cons 'sweep-finite-single-key (lambda () (times1 (vector 0.25))))))

;; CONTROL, and it names which guard owns which case: a nan with TWO
;; keyframes is ALREADY refused, by strict ordering rather than by any
;; finiteness test.  Green now and must stay green -- if a finiteness
;; check turned this red it would have displaced a working guard instead
;; of adding the missing one.
(want 'CONTROL-nan-with-two-keys-already-refused
      (raises? (lambda () (times (vector 0.0 +nan.0)))) #t)

;; THE CONTROL.  Ordinary finite values keep working and put no null in
;; the file -- a repair that refused too widely would satisfy every row
;; above and break every real export.  This half must stay green.
(want 'CONTROL-finite-morph-still-writes
      (has? (jtext (morph 0.5)) "null") #f)
(want 'CONTROL-finite-times-still-write
      (has? (jtext (times (vector 0.0 1.0))) "null") #f)

(display (if (null? fails) #t fails))
