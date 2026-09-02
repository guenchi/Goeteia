;; Express GLSL in Scheme: render a shader form list to GLSL source.
;;
;; The (web css) of shaders -- a pure function from s-expressions to a
;; GLSL string, so shaders compose with Scheme's own abstraction
;; (append, map, helper functions) and verify headlessly.
;;
;;   (glsl->string
;;     '((attribute vec2 p)
;;       (uniform float u_time)
;;       (define (main) void
;;         (local float w (+ (* p.x (fl 0 50)) u_time))
;;         (set! gl_Position (vec4 p (fl 0) (fl 1)))
;;         (set! gl_PointSize (fl 2)))))
;;
;; Top-level forms:
;;   (attribute T name) (uniform T name) (varying T name)
;;   (precision P T)
;;   (out loc T name)      -- a fragment output at an explicit
;;                            location; ESSL 3.00 only (MRT), and it
;;                            replaces gl_FragColor in that shader
;;   (define (name (T arg) ...) RET stmt ...)
;; Statements:
;;   (local T name expr)   -> "T name = expr;"
;;   (set! lhs expr)       -> "lhs = expr;"
;;   (return expr) (return)
;;   (if c stmt ...)       / (if-else c (stmt ...) (stmt ...))
;;   (for (T name init cond step) stmt ...)
;;                         -> "for (T name = init; cond; name += k)"
;;                            (step (+ name k) / (- name k) becomes
;;                            += / -= as ESSL 1.00 loops require)
;;   (discard)
;; Expressions:
;;   symbols pass through verbatim (p, gl_Position, v.xy);
;;   exact integers as themselves; (fl W F [width]) is a float literal
;;   -- (fl 2)="2.0", (fl 0 5)="0.5", (fl 1 2345)="1.2345".  `width` is
;;   a MINIMUM, left-padded with zeros, and defaults to F's own digit
;;   count; give it when you want a leading zero Scheme would drop:
;;   (fl 0 5 2)="0.05", (fl 0 2037 5)="0.02037".  No Scheme flonums, so
;;   no printer noise;
;;   (+ - * /) are infix, (- x) negates; (< > <= >= ==) compare;
;;   anything else (vec4 sin dot mix ...) is a call.
;;
;; Every position that introduces a name is checked against the GLSL
;; ES reserved words (glsl-check runs it alone), so an identifier the
;; driver would reject is an error here instead of a shader that
;; silently fails to compile and draws nothing.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (gfx glsl)
  (export glsl->string glsl-attributes glsl-uniforms glsl-varyings
          glsl-uniform-blocks glsl-check
          glsl300-vs->string glsl300-fs->string
          fl-literal->string)          ; (gfx wgsl) renders (fl ...) with it
  (import (rnrs))

  (define (join parts sep)
    (cond
     ((null? parts) "")
     ((null? (cdr parts)) (car parts))
     (else (string-append (car parts) sep (join (cdr parts) sep)))))

  (define (strip-trailing-zeros s)
    (let loop ((i (string-length s)))
      (if (and (> i 1) (char=? (string-ref s (- i 1)) #\0))
          (loop (- i 1))
          (substring s 0 i))))
  ;; a fraction's digits, leading-zero-padded to `width' then
  ;; trailing-zeros stripped.  Scheme drops a literal's leading zeros,
  ;; so a third (fl) argument states the intended width: 2037 with
  ;; width 5 is the fraction 02037, i.e. .02037
  (define (frac->glsl f width)
    (let loop ((s (number->string f)))
      (if (< (string-length s) width)
          (loop (string-append "0" s))
          (strip-trailing-zeros s))))

  ;; ONE renderer for (fl W F [width]), and both backends call it.
  ;; There used to be a second copy in (gfx wgsl), which ignored the
  ;; width argument entirely: `(fl 0 2037 5)` rendered 0.02037 through
  ;; GLSL and 0.2037 through WGSL -- the same shader source, a factor
  ;; of ten apart, on two devices.  Two implementations of one notation
  ;; is the thing that made that possible, so there is now one.
  ;;
  ;; The width is a MINIMUM, padded on the left with zeros, and it
  ;; defaults to however many digits F itself has.  So (fl 0 5) is 0.5
  ;; and (fl 0 05) cannot be written -- Scheme has already dropped that
  ;; leading zero before this code sees it -- which is what the third
  ;; argument is for: (fl 0 5 2) is 0.05.
  ;;
  ;; It used to default to 2, and that rule was wrong in exactly one
  ;; shape: a single-digit fraction.  (fl 0 5) meaning 0.05 reads
  ;; backwards to everyone who has not memorised the rule, and the
  ;; evidence that it read backwards is that three documents carried a
  ;; warning about it.  A notation that needs to be warned about in
  ;; three places is arguing with itself.
  (define (fl-literal->string e)
    (string-append
     (number->string (cadr e)) "."
     (if (null? (cddr e)) "0"
         (frac->glsl (caddr e)
                     (if (pair? (cdddr e))
                         (cadddr e)
                         (string-length (number->string (caddr e))))))))

  (define (expr->glsl e)
    (cond
     ((symbol? e) (symbol->string e))
     ((and (integer? e) (exact? e)) (number->string e))
     ((string? e) e)
     ((pair? e)
      (let ((h (car e)))
        (cond
         ;; float literal -- see fl-literal->string
         ((eq? h 'fl) (fl-literal->string e))
         ;; unary minus
         ((and (eq? h '-) (null? (cddr e)))
          (string-append "(-" (expr->glsl (cadr e)) ")"))
         ;; array indexing: (at u_joints i) -> u_joints[i]
         ((eq? h 'at)
          (string-append (expr->glsl (cadr e)) "["
                         (expr->glsl (caddr e)) "]"))
         ;; infix operators, left-folded, parenthesized
         ((memq h '(+ - * /))
          (string-append "(" (join (map expr->glsl (cdr e))
                                   (string-append " " (symbol->string h) " "))
                         ")"))
         ((memq h '(< > <= >= ==))
          (string-append "(" (expr->glsl (cadr e)) " " (symbol->string h)
                         " " (expr->glsl (caddr e)) ")"))
         ;; a call: vec4(...), sin(...), dot(...), user functions
         (else
          (string-append (symbol->string h) "("
                         (join (map expr->glsl (cdr e)) ", ") ")")))))
     (else (error 'glsl "bad expression" e))))

  (define (stmt->glsl s)
    (let ((h (car s)))
      (case h
        ((local)
         (string-append (symbol->string (cadr s)) " "
                        (symbol->string (caddr s)) " = "
                        (expr->glsl (cadddr s)) "; "))
        ((set!)
         (string-append (expr->glsl (cadr s)) " = "
                        (expr->glsl (caddr s)) "; "))
        ((return)
         (if (null? (cdr s)) "return; "
             (string-append "return " (expr->glsl (cadr s)) "; ")))
        ((discard) "discard; ")
        ((if)
         (string-append "if (" (expr->glsl (cadr s)) ") { "
                        (apply string-append (map stmt->glsl (cddr s)))
                        "} "))
        ((if-else)
         (string-append "if (" (expr->glsl (cadr s)) ") { "
                        (apply string-append (map stmt->glsl (caddr s)))
                        "} else { "
                        (apply string-append (map stmt->glsl (cadddr s)))
                        "} "))
        ((for)
         ;; (for (T name init cond step) stmt ...) -- step is an
         ;; expression assigned back to name each iteration.  ESSL
         ;; 1.00 (Appendix A) only allows the loop index to advance
         ;; by ++/--/+=/-=, so (+ name e) and (- name e) render as
         ;; compound assignment; anything else is on the caller.
         (let* ((h (cadr s))
                (ty (car h)) (name (cadr h)) (init (caddr h))
                (c (cadddr h)) (step (list-ref h 4)))
           (string-append "for (" (symbol->string ty) " "
                          (symbol->string name) " = " (expr->glsl init)
                          "; " (expr->glsl c) "; "
                          (if (and (pair? step) (pair? (cdr step))
                                   (pair? (cddr step)) (null? (cdddr step))
                                   (memq (car step) '(+ -))
                                   (eq? (cadr step) name))
                              (string-append (symbol->string name)
                                             (if (eq? (car step) '+) " += " " -= ")
                                             (expr->glsl (caddr step)))
                              (string-append (symbol->string name) " = "
                                             (expr->glsl step)))
                          ") { "
                          (apply string-append (map stmt->glsl (cddr s)))
                          "} ")))
        (else (error 'glsl "bad statement" s)))))

  (define (param->glsl p)                 ; (T name)
    (string-append (symbol->string (car p)) " " (symbol->string (cadr p))))

  (define (form->glsl f)
    (case (car f)
      ((attribute uniform varying)
       (if (pair? (cadr f))              ; (array T N) declarations
           (string-append (symbol->string (car f)) " "
                          (symbol->string (cadr (cadr f))) " "
                          (symbol->string (caddr f))
                          "[" (number->string (caddr (cadr f))) "]; ")
           (string-append (symbol->string (car f)) " "
                          (symbol->string (cadr f)) " "
                          (symbol->string (caddr f)) "; ")))
      ((precision)
       (string-append "precision " (symbol->string (cadr f)) " "
                      (symbol->string (caddr f)) "; "))
      ((out)
       (error 'glsl "out needs the ESSL 3.00 dialect (fx-program3!)" f))
      ((define)
       ;; (define (name (T a) ...) RET stmt ...)
       (let* ((head (cadr f))
              (name (car head))
              (params (cdr head))
              (ret (caddr f))
              (body (cdddr f)))
         (string-append (symbol->string ret) " " (symbol->string name) "("
                        (join (map param->glsl params) ", ") ") { "
                        (apply string-append (map stmt->glsl body))
                        "} ")))
      (else (error 'glsl "bad top-level form" f))))

  ;; ---- reserved words, rejected where a name is introduced ----
  ;;
  ;; Identifiers pass through verbatim, so a local named `out' used
  ;; to reach the driver as syntactically invalid GLSL: the shader
  ;; failed to compile at runtime, the draw produced nothing, and
  ;; nothing on the Scheme side said a word.  The check below turns
  ;; that into a generation-time error, raised at the *declaration*
  ;; -- the place the user wrote the name -- rather than at one of
  ;; its uses.
  ;;
  ;; The tables are data, one row per spec clause:
  ;;   (dialect kind word ...)
  ;; Sources: "The OpenGL ES Shading Language" 1.00.17 sections 3.6
  ;; (Keywords) and 3.7 (Reserved Keywords), and 3.00.6 sections 3.6
  ;; and 3.7.  A word is listed in the first row that reserves it and
  ;; not repeated, so the row it is found in names the clause the
  ;; error can cite.
  ;;
  ;; Both dialects reject the *union* of the two sets, whichever one
  ;; is being emitted.  A word that 3.00 reserves and 1.00 does not
  ;; (`sample', `filter', `layout', `smooth') would otherwise compile
  ;; today and break the day the same forms are handed to
  ;; glsl300-vs->string -- which is the point of a dialect-neutral
  ;; form language, and one call away.  The dialect tag stays so the
  ;; message can say which spec reserves the name.
  (define $glsl-reserved
    '((es100 keyword
             attribute const bool float int break continue do else for
             if discard return bvec2 bvec3 bvec4 ivec2 ivec3 ivec4
             vec2 vec3 vec4 mat2 mat3 mat4 in out inout uniform
             varying sampler2D samplerCube struct void while lowp
             mediump highp precision invariant)
      (es100 future
             asm class union enum typedef template this packed goto
             switch default inline noinline volatile public static
             extern external interface flat long short double half
             fixed unsigned superp input output hvec2 hvec3 hvec4
             dvec2 dvec3 dvec4 fvec2 fvec3 fvec4 sampler1D sampler3D
             sampler1DShadow sampler2DShadow sampler2DRect
             sampler3DRect sampler2DRectShadow sizeof cast namespace
             using)
      ;; 3.00 keywords the 1.00 rows above do not already cover
      (es300 keyword
             layout centroid smooth case true false uint uvec2 uvec3
             uvec4 mat2x2 mat2x3 mat2x4 mat3x2 mat3x3 mat3x4 mat4x2
             mat4x3 mat4x4 samplerCubeShadow sampler2DArray
             sampler2DArrayShadow isampler2D isampler3D isamplerCube
             isampler2DArray usampler2D usampler3D usamplerCube
             usampler2DArray)
      (es300 future
             coherent restrict readonly writeonly resource atomic_uint
             noperspective patch sample subroutine common partition
             active filter image1D image2D image3D imageCube iimage1D
             iimage2D iimage3D iimageCube uimage1D uimage2D uimage3D
             uimageCube image1DArray image2DArray iimage1DArray
             iimage2DArray uimage1DArray uimage2DArray image1DShadow
             image2DShadow image1DArrayShadow image2DArrayShadow
             imageBuffer iimageBuffer uimageBuffer sampler1DArray
             sampler1DArrayShadow isampler1D isampler1DArray usampler1D
             usampler1DArray samplerBuffer isamplerBuffer
             usamplerBuffer sampler2DMS isampler2DMS usampler2DMS
             sampler2DMSArray isampler2DMSArray usampler2DMSArray)))

  (define ($glsl-reserved-by w)         ; (dialect kind), or #f
    (let loop ((rows $glsl-reserved))
      (cond
       ((null? rows) #f)
       ((memq w (cddr (car rows))) (list (caar rows) (cadar rows)))
       (else (loop (cdr rows))))))

  (define ($glsl-prefix? s p)
    (and (>= (string-length s) (string-length p))
         (string=? (substring s 0 (string-length p)) p)))

  ;; both specs reserve identifiers containing two consecutive
  ;; underscores anywhere, not only at the front
  (define ($glsl-dunder? s)
    (let loop ((i 1))
      (and (< i (string-length s))
           (or (and (char=? (string-ref s (- i 1)) #\_)
                    (char=? (string-ref s i) #\_))
               (loop (+ i 1))))))

  ;; why this name may not be declared, or #f if it may be
  (define ($glsl-name-fault name)
    (let ((s (symbol->string name)))
      (cond
       ;; "gl_" is reserved for built-ins; a *reference* to
       ;; gl_Position or gl_FragColor is fine, this is about
       ;; introducing the name
       (($glsl-prefix? s "gl_") "names beginning gl_ are reserved")
       (($glsl-dunder? s) "names containing __ are reserved")
       (else
        (let ((row ($glsl-reserved-by name)))
          (and row
               (string-append "reserved in GLSL ES "
                              (if (eq? (car row) 'es100) "1.00" "3.00")
                              " ("
                              (symbol->string (cadr row))
                              ")")))))))

  ;; kind names the binding form, so the message points at the
  ;; declaration and not at some use of it far downstream
  (define ($glsl-check-name kind name)
    (if (symbol? name)
        (let ((fault ($glsl-name-fault name)))
          (if fault
              (error 'glsl
                     (string-append "illegal " kind " name: "
                                    (symbol->string name) " -- " fault)
                     name)
              #t))
        #t))

  ;; tolerant accessors: a malformed form is the renderer's error to
  ;; report, so the check skips what it cannot read rather than
  ;; failing first with a worse message
  (define ($glsl-nth x n)
    (cond ((not (pair? x)) #f)
          ((= n 0) (car x))
          (else ($glsl-nth (cdr x) (- n 1)))))

  (define ($glsl-drop x n)
    (if (or (= n 0) (not (pair? x))) x ($glsl-drop (cdr x) (- n 1))))

  (define ($glsl-check-each kind xs field)
    (let loop ((xs xs))
      (if (pair? xs)
          (begin ($glsl-check-name kind ($glsl-nth (car xs) field))
                 (loop (cdr xs)))
          #t)))

  (define ($glsl-check-stmt s)
    (if (pair? s)
        (case (car s)
          ((local) ($glsl-check-name "local variable" ($glsl-nth s 2)))
          ((if) ($glsl-check-stmts ($glsl-drop s 2)))
          ((if-else)
           (begin ($glsl-check-stmts ($glsl-nth s 2))
                  ($glsl-check-stmts ($glsl-nth s 3))))
          ((for)
           (begin ($glsl-check-name "loop index"
                                    ($glsl-nth ($glsl-nth s 1) 1))
                  ($glsl-check-stmts ($glsl-drop s 2))))
          (else #t))
        #t))

  (define ($glsl-check-stmts ss)
    (let loop ((ss ss))
      (if (pair? ss)
          (begin ($glsl-check-stmt (car ss)) (loop (cdr ss)))
          #t)))

  ;; Only names the *user* introduces are checked.  The DSL's own
  ;; structure words sit in head position -- attribute, varying, out
  ;; in (out 0 vec4 name), uniform-block -- and type names sit in
  ;; type position; neither is a declared identifier, so neither is
  ;; matched against the tables.
  (define ($glsl-check-form f)
    (if (pair? f)
        (case (car f)
          ((attribute uniform varying)
           ($glsl-check-name (symbol->string (car f)) ($glsl-nth f 2)))
          ((out)                        ; (out loc T name)
           ($glsl-check-name "fragment output" ($glsl-nth f 3)))
          ((uniform-block)              ; (uniform-block Name (T m) ...)
           (begin ($glsl-check-name "uniform block" ($glsl-nth f 1))
                  ($glsl-check-each "uniform block member"
                                    ($glsl-drop f 2) 1)))
          ((define)                     ; (define (name (T a) ...) RET stmt ...)
           (let ((head ($glsl-nth f 1)))
             (begin ($glsl-check-name "function" ($glsl-nth head 0))
                    ($glsl-check-each "function parameter"
                                      ($glsl-drop head 1) 1)
                    ($glsl-check-stmts ($glsl-drop f 3)))))
          (else #t))
        #t))

  ;; every emission path runs this first: the error belongs to the
  ;; forms, not to the dialect that happens to render them
  (define (glsl-check forms)
    (let loop ((fs forms))
      (if (pair? fs)
          (begin ($glsl-check-form (car fs)) (loop (cdr fs)))
          #t)))

  (define (glsl->string forms)
    (glsl-check forms)
    (apply string-append (map form->glsl forms)))

  ;; ---- the ES 3.00 dialect: the same forms, respelled ----
  ;; The form language is dialect-neutral; these render it as
  ;; "#version 300 es" source: attribute -> in, varying -> out (VS)
  ;; / in (FS), gl_FragColor -> a declared output, texture2D and
  ;; textureCube -> the unified texture().  (uniform-block Name
  ;; (T field) ...) becomes a std140 uniform block -- the syntax
  ;; UBOs need, which 1.00 does not have.
  (define ($glsl-subst x alist)
    (cond
     ((symbol? x) (let ((hit (assq x alist))) (if hit (cdr hit) x)))
     ((pair? x) (cons ($glsl-subst (car x) alist)
                      ($glsl-subst (cdr x) alist)))
     (else x)))

  (define $glsl300-renames
    '((texture2D . texture) (textureCube . texture)
      (gl_FragColor . goe_FragColor)))

  (define ($form300->glsl f stage)
    (case (car f)
      ((attribute varying)
       (let ((kw (if (eq? (car f) 'attribute)
                     "in"
                     (if (eq? stage 'vertex) "out" "in"))))
         (if (pair? (cadr f))
             (string-append kw " " (symbol->string (cadr (cadr f))) " "
                            (symbol->string (caddr f))
                            "[" (number->string (caddr (cadr f))) "]; ")
             (string-append kw " " (symbol->string (cadr f)) " "
                            (symbol->string (caddr f)) "; "))))
      ((out)
       ;; (out loc T name): one of several fragment outputs -- MRT.
       ;; The location is explicit because with more than one output
       ;; ESSL 3.00 wants them all pinned anyway
       (string-append "layout(location = " (number->string (cadr f))
                      ") out highp " (symbol->string (caddr f)) " "
                      (symbol->string (cadddr f)) "; "))
      ((uniform-block)
       ;; members carry explicit highp: the vertex default is highp,
       ;; a mediump fragment default would otherwise disagree, and
       ;; block layouts must match exactly across stages.  A member
       ;; may be an array -- ((array T N) name) -- which is how a
       ;; block carries a palette; std140 gives a mat4 array the
       ;; tight 64-byte stride, so such a block maps one to one onto
       ;; a run of matrices in staging memory
       (string-append
        "layout(std140) uniform " (symbol->string (cadr f)) " { "
        (apply string-append
               (map (lambda (m)
                      (if (pair? (car m))
                          (string-append
                           "highp " (symbol->string (cadr (car m))) " "
                           (symbol->string (cadr m))
                           "[" (number->string (caddr (car m))) "]; ")
                          (string-append "highp "
                                         (symbol->string (car m)) " "
                                         (symbol->string (cadr m)) "; ")))
                    (cddr f)))
        "}; "))
      (else (form->glsl f))))

  (define ($glsl300 forms stage head)
    ;; the names checked are the ones the caller wrote, before the
    ;; 3.00 renames rewrite references
    (glsl-check forms)
    (string-append
     "#version 300 es\n" head
     (apply string-append
            (map (lambda (f) ($form300->glsl f stage))
                 ($glsl-subst forms $glsl300-renames)))))

  (define (glsl300-vs->string forms)
    ($glsl300 forms 'vertex ""))
  ;; a shader that declares its own (out ...) forms replaces the
  ;; default output entirely -- an implicit goe_FragColor would
  ;; collide with an explicit location 0
  (define ($glsl-has-out? forms)
    (let loop ((fs forms))
      (cond ((null? fs) #f)
            ((eq? (caar fs) 'out) #t)
            (else (loop (cdr fs))))))

  (define (glsl300-fs->string forms)
    ($glsl300 forms 'fragment
              (if ($glsl-has-out? forms)
                  ""
                  "out highp vec4 goe_FragColor; ")))

  ;; the interface, extracted: shader forms are data, so the
  ;; attribute/uniform declarations that (gfx fx) wires up come from
  ;; the same list that rendered the source -- one source of truth
  (define ($glsl-components t)          ; f32 components per attribute
    (case t
      ((float) 1) ((vec2) 2) ((vec3) 3) ((vec4) 4)
      (else (error 'glsl "no component count for attribute type" t))))

  (define (glsl-attributes forms)       ; ((name type count) ...) in order
    (let loop ((fs forms))
      (cond
       ((null? fs) '())
       ((eq? (caar fs) 'attribute)
        (let ((ty (cadar fs)) (name (caddr (car fs))))
          (cons (list name ty ($glsl-components ty)) (loop (cdr fs)))))
       (else (loop (cdr fs))))))

  (define (glsl-uniforms forms)         ; ((name type) ...) in order
    (let loop ((fs forms))
      (cond
       ((null? fs) '())
       ((eq? (caar fs) 'uniform)
        (cons (list (caddr (car fs)) (cadar fs)) (loop (cdr fs))))
       (else (loop (cdr fs))))))

  (define (glsl-varyings forms)         ; names in order -- what a
    (let loop ((fs forms))              ; transform feedback captures
      (cond
       ((null? fs) '())
       ((eq? (caar fs) 'varying)
        (cons (caddr (car fs)) (loop (cdr fs))))
       (else (loop (cdr fs))))))

  ;; ((Name member ...) ...) in order -- the blocks a program must
  ;; wire to binding points (gl-uniform-block!).  Members come along
  ;; unchanged, so a caller can read a block's shape as well as its
  ;; name
  (define (glsl-uniform-blocks forms)
    (let loop ((fs forms))
      (cond
       ((null? fs) '())
       ((eq? (caar fs) 'uniform-block)
        (cons (cdr (car fs)) (loop (cdr fs))))
       (else (loop (cdr fs)))))))
