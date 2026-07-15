;; WGSL from the same shader forms (gfx glsl) renders -- one source
;; of truth, three dialects.  wgsl->string takes the VERTEX and
;; FRAGMENT form lists together, because WebGPU wants one module:
;; the uniforms of both merge into a single struct bound at
;; @group(0) @binding(0), the varyings become the VOut struct the
;; vs returns and the fs receives, and gl_Position / gl_FragColor /
;; gl_FragCoord respell themselves.
;;
;;   (wgsl->string vs-forms fs-forms)   -> "struct U {...} ... fn vs..."
;;   (wgsl-layout vs-forms)             -> (stride . "float32x3,...")
;;                                         -- feed gpu-pipeline!
;;
;; The subset that travels: attribute/uniform/varying declarations,
;; define'd helper functions, main, local/set!/if/if-else/for/
;; return/discard, the infix arithmetic and the common intrinsics.
;; A sampler2D uniform becomes a sampler + texture binding pair
;; after the struct (declaration order; gpu-texgroup! matches), and
;; (texture2D u_tex uv) respells as textureSample.  What does not
;; travel (yet): cube textures, arrays, uniform blocks.
;; Two spelling rules WGSL forces on the forms:
;; constructors do not truncate (no (vec3 some-vec4) -- go through a
;; local and swizzle), and varyings are main's business only.
;; Mind the uniform struct's std140-like alignment: order members
;; mat4 / vec4 / vec3+pad / f32, as WGSL will read them.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (gfx wgsl)
  (export wgsl->string wgsl-compute->string wgsl-layout)
  (import (rnrs) (gfx glsl))

  (define ($wgsl-join parts sep)
    (cond
     ((null? parts) "")
     ((null? (cdr parts)) (car parts))
     (else (string-append (car parts) sep
                          ($wgsl-join (cdr parts) sep)))))

  ;; ---- type and intrinsic spellings ----
  (define ($wgsl-type t)
    (case t
      ((float) "f32") ((int) "i32") ((uint) "u32") ((bool) "bool")
      ((vec2) "vec2f") ((vec3) "vec3f") ((vec4) "vec4f")
      ((mat3) "mat3x3f") ((mat4) "mat4x4f")
      ;; any other symbol is a (struct ...)-declared name
      (else (if (symbol? t)
                (symbol->string t)
                (error 'wgsl "no WGSL spelling for type" t)))))

  (define $wgsl-calls                   ; renamed constructors/casts
    '((vec2 . "vec2f") (vec3 . "vec3f") (vec4 . "vec4f")
      (mat3 . "mat3x3f") (mat4 . "mat4x4f")
      (float . "f32") (int . "i32") (uint . "u32")))

  (define ($wgsl-vertex-format t)
    (case t
      ((float) "float32") ((vec2) "float32x2")
      ((vec3) "float32x3") ((vec4) "float32x4")
      (else (error 'wgsl "no vertex format for attribute type" t))))

  ;; ---- symbol substitution, dot-aware: v_n.xy -> vin.v_n.xy ----
  (define ($wgsl-split-head s)          ; "a.b.c" -> ("a" . ".b.c")
    (let ((n (string-length s)))
      (let loop ((i 0))
        (cond ((= i n) (cons s ""))
              ((char=? (string-ref s i) #\.)
               (cons (substring s 0 i) (substring s i n)))
              (else (loop (+ i 1)))))))

  (define ($wgsl-rename sym alist)
    (let* ((s (symbol->string sym))
           (ht ($wgsl-split-head s))
           (hit (assoc (car ht) alist)))
      (if hit
          (string->symbol (string-append (cdr hit) (cdr ht)))
          sym)))

  (define ($wgsl-subst x alist)
    (cond
     ((symbol? x) ($wgsl-rename x alist))
     ((pair? x) (cons ($wgsl-subst (car x) alist)
                      ($wgsl-subst (cdr x) alist)))
     (else x)))

  ;; ---- expressions: the glsl grammar, WGSL spellings ----
  (define ($wgsl-fl whole frac)         ; (fl 2) / (fl 0 50) literals
    (string-append (number->string whole) "."
                   (if (= frac 0)
                       "0"
                       (let ((s (number->string frac)))
                         (if (< frac 10) (string-append "0" s) s)))))

  (define ($wgsl-expr e)
    (cond
     ((symbol? e) (symbol->string e))
     ((string? e) e)                    ; verbatim, like glsl
     ((and (integer? e) (exact? e)) (number->string e))
     ((pair? e)
      (let ((op (car e)))
        (cond
         ((eq? op 'fl)
          ($wgsl-fl (cadr e) (if (null? (cddr e)) 0 (caddr e))))
         ((and (eq? op '-) (null? (cddr e)))
          (string-append "(-" ($wgsl-expr (cadr e)) ")"))
         ((memq op '(+ - * /))
          (string-append
           "(" ($wgsl-join (map $wgsl-expr (cdr e))
                           (string-append " " (symbol->string op) " "))
           ")"))
         ((eq? op 'at)                  ; (at arr i) -> arr[i]
          (string-append ($wgsl-expr (cadr e)) "["
                         ($wgsl-expr (caddr e)) "]"))
         ((eq? op 'array-length)        ; runtime-sized storage arrays
          (string-append "arrayLength(&" ($wgsl-expr (cadr e)) ")"))
         ((memq op '(< > <= >= == %))
          (string-append "(" ($wgsl-expr (cadr e)) " "
                         (symbol->string op) " "
                         ($wgsl-expr (caddr e)) ")"))
         ((eq? op 'texture2D)
          ;; (texture2D u_tex uv): the sampler2D uniform splits into
          ;; a texture + sampler pair at declaration time
          (let ((n (symbol->string (cadr e))))
            (string-append "textureSample(" n "_t, " n "_s, "
                           ($wgsl-expr (caddr e)) ")")))
         ((eq? op 'textureCube)
          (error 'wgsl "cube textures are not in the WGSL subset yet" e))
         (else
          (let ((hit (assq op $wgsl-calls)))
            (string-append (if hit (cdr hit) (symbol->string op)) "("
                           ($wgsl-join (map $wgsl-expr (cdr e)) ", ")
                           ")"))))))
     (else (error 'wgsl "bad expression" e))))

  ;; ---- statements ----
  (define ($wgsl-stmt s)
    (case (car s)
      ((local)
       (string-append "var " (symbol->string (caddr s)) " : "
                      ($wgsl-type (cadr s)) " = "
                      ($wgsl-expr (cadddr s)) "; "))
      ((set!)
       (string-append ($wgsl-expr (cadr s)) " = "
                      ($wgsl-expr (caddr s)) "; "))
      ((return)
       (if (null? (cdr s))
           "return; "
           (string-append "return " ($wgsl-expr (cadr s)) "; ")))
      ((discard) "discard; ")
      ((if)
       (string-append "if (" ($wgsl-expr (cadr s)) ") { "
                      (apply string-append (map $wgsl-stmt (cddr s)))
                      "} "))
      ((if-else)
       (string-append "if (" ($wgsl-expr (cadr s)) ") { "
                      (apply string-append (map $wgsl-stmt (caddr s)))
                      "} else { "
                      (apply string-append (map $wgsl-stmt (cadddr s)))
                      "} "))
      ((for)
       (let* ((h (cadr s))
              (ty (car h)) (name (cadr h)) (init (caddr h))
              (c (cadddr h)) (step (list-ref h 4)))
         (string-append "for (var " (symbol->string name) " : "
                        ($wgsl-type ty) " = " ($wgsl-expr init)
                        "; " ($wgsl-expr c) "; "
                        (symbol->string name) " = " ($wgsl-expr step)
                        ") { "
                        (apply string-append (map $wgsl-stmt (cddr s)))
                        "} ")))
      (else (error 'wgsl "bad statement" s))))

  ;; ---- helper functions (every define that is not main) ----
  (define ($wgsl-helper f)
    (let* ((head (cadr f))
           (name (car head))
           (params (cdr head))
           (ret (caddr f))
           (body (cdddr f)))
      (string-append
       "fn " (symbol->string name) "("
       ($wgsl-join (map (lambda (p)
                          (string-append (symbol->string (cadr p))
                                         " : " ($wgsl-type (car p))))
                        params)
                   ", ")
       ")"
       (if (eq? ret 'void) "" (string-append " -> " ($wgsl-type ret)))
       " { " (apply string-append (map $wgsl-stmt body)) "} ")))

  (define ($wgsl-defines forms main?)   ; the defines, split by name
    (let loop ((fs forms) (acc '()))
      (cond
       ((null? fs) (reverse acc))
       ((and (eq? (caar fs) 'define)
             (eq? main? (eq? (car (cadr (car fs))) 'main)))
        (loop (cdr fs) (cons (car fs) acc)))
       (else (loop (cdr fs) acc)))))

  ;; ---- the module: struct U + struct VOut + helpers + vs + fs ----
  (define (wgsl->string vs-forms fs-forms)
    (let* ((attrs (glsl-attributes vs-forms))
           (varys (glsl-varyings vs-forms))
           (vary-types (let loop ((fs vs-forms) (acc '()))
                         (cond ((null? fs) (reverse acc))
                               ((eq? (caar fs) 'varying)
                                (loop (cdr fs) (cons (cadar fs) acc)))
                               (else (loop (cdr fs) acc)))))
           (all-unis (let dedup ((us (append (glsl-uniforms vs-forms)
                                             (glsl-uniforms fs-forms)))
                                 (acc '()))
                       (cond ((null? us) (reverse acc))
                             ((assq (caar us) acc) (dedup (cdr us) acc))
                             (else (dedup (cdr us)
                                          (cons (car us) acc))))))
           ;; sampler2D uniforms become texture + sampler binding
           ;; pairs after the struct; the rest pack into it
           (unis (let split ((us all-unis) (acc '()))
                   (cond ((null? us) (reverse acc))
                         ((eq? (cadr (car us)) 'sampler2D)
                          (split (cdr us) acc))
                         (else (split (cdr us) (cons (car us) acc))))))
           (texs (let split ((us all-unis) (acc '()))
                   (cond ((null? us) (reverse acc))
                         ((eq? (cadr (car us)) 'sampler2D)
                          (split (cdr us) (cons (caar us) acc)))
                         (else (split (cdr us) acc)))))
           (uni-sub (map (lambda (u)
                           (cons (symbol->string (car u))
                                 (string-append
                                  "u." (symbol->string (car u)))))
                         unis))
           (vs-sub (append
                    '(("gl_Position" . "o.goe_pos"))
                    (map (lambda (v)
                           (cons (symbol->string v)
                                 (string-append "o." (symbol->string v))))
                         varys)
                    uni-sub))
           (fs-sub (append
                    '(("gl_FragColor" . "goe_out")
                      ("gl_FragCoord" . "vin.goe_pos"))
                    (map (lambda (v)
                           (cons (symbol->string v)
                                 (string-append "vin."
                                                (symbol->string v))))
                         varys)
                    uni-sub))
           (vs-main (car ($wgsl-defines ($wgsl-subst vs-forms vs-sub) #t)))
           (fs-main (car ($wgsl-defines ($wgsl-subst fs-forms fs-sub) #t))))
      (string-append
       ;; the uniform struct, one binding for the whole frame state
       (if (null? unis)
           ""
           (string-append
            "struct U { "
            ($wgsl-join (map (lambda (u)
                               (string-append (symbol->string (car u))
                                              " : "
                                              ($wgsl-type (cadr u))))
                             unis)
                        ", ")
            " } "
            "@group(0) @binding(0) var<uniform> u : U; "))
       ;; each sampler2D: a sampler + texture pair, bindings in
       ;; declaration order after the struct (gpu-texgroup! matches)
       (apply string-append
              (let bindings ((ts texs)
                             (b (if (null? unis) 0 1)))
                (if (null? ts)
                    '()
                    (let ((n (symbol->string (car ts))))
                      (cons (string-append
                             "@group(0) @binding(" (number->string b)
                             ") var " n "_s : sampler; "
                             "@group(0) @binding("
                             (number->string (+ b 1))
                             ") var " n "_t : texture_2d<f32>; ")
                            (bindings (cdr ts) (+ b 2)))))))
       ;; the varying struct both entry points share
       "struct VOut { @builtin(position) goe_pos : vec4f"
       (apply string-append
              (let number ((vs varys) (ts vary-types) (i 0))
                (if (null? vs)
                    '()
                    (cons (string-append
                           ", @location(" (number->string i) ") "
                           (symbol->string (car vs)) " : "
                           ($wgsl-type (car ts)))
                          (number (cdr vs) (cdr ts) (+ i 1))))))
       " } "
       ;; helpers (uniform references still work: u is module scope)
       (apply string-append
              (map $wgsl-helper
                   (append ($wgsl-defines ($wgsl-subst vs-forms uni-sub) #f)
                           ($wgsl-defines ($wgsl-subst fs-forms uni-sub) #f))))
       ;; the vertex entry: attributes in, VOut back
       "@vertex fn vs("
       ($wgsl-join (let number ((as attrs) (i 0))
                     (if (null? as)
                         '()
                         (cons (string-append
                                "@location(" (number->string i) ") "
                                (symbol->string (car (car as))) " : "
                                ($wgsl-type (cadr (car as))))
                               (number (cdr as) (+ i 1)))))
                   ", ")
       ") -> VOut { var o : VOut; "
       (apply string-append (map $wgsl-stmt (cdddr vs-main)))
       "return o; } "
       ;; the fragment entry
       "@fragment fn fs(vin : VOut) -> @location(0) vec4f { "
       "var goe_out : vec4f; "
       (apply string-append (map $wgsl-stmt (cdddr fs-main)))
       "return goe_out; } ")))

  ;; ---- a compute module ----
  ;; (wgsl-compute->string forms): struct declarations, ONE
  ;; read_write storage array at binding 0, the uniform struct at
  ;; binding 1 -- the order (gfx gpu)'s gpu-compute-group! wires --
  ;; helper defines, and main as the cs entry point with the global
  ;; invocation id in scope as gid (a vec3u).
  ;;
  ;;   (struct P ((vec2 pos) (float age)))
  ;;   (storage ps (array P))
  ;;   (uniform float dt) ...
  ;;   (workgroup 64)
  ;;   (define (main) void
  ;;     (local uint i gid.x)
  ;;     (if (>= i (array-length ps)) (return))
  ;;     (local P p (at ps i)) ... (set! (at ps i) p))
  (define (wgsl-compute->string forms)
    (let* ((structs (filter (lambda (f) (eq? (car f) 'struct)) forms))
           (stores (filter (lambda (f) (eq? (car f) 'storage)) forms))
           (unis (glsl-uniforms forms))
           (wg (let find ((fs forms))
                 (cond ((null? fs) 64)
                       ((eq? (caar fs) 'workgroup) (cadr (car fs)))
                       (else (find (cdr fs))))))
           (uni-sub (map (lambda (u)
                           (cons (symbol->string (car u))
                                 (string-append
                                  "u." (symbol->string (car u)))))
                         unis))
           (subbed ($wgsl-subst forms uni-sub))
           (cmain (car ($wgsl-defines subbed #t)))
           (helpers ($wgsl-defines subbed #f)))
      (string-append
       (apply string-append
              (map (lambda (s)
                     (string-append
                      "struct " (symbol->string (cadr s)) " { "
                      ($wgsl-join
                       (map (lambda (fld)
                              (string-append (symbol->string (cadr fld))
                                             " : "
                                             ($wgsl-type (car fld))))
                            (caddr s))
                       ", ")
                      " } "))
                   structs))
       (apply string-append
              (let number ((ss stores) (b 0))
                (if (null? ss)
                    '()
                    (cons (string-append
                           "@group(0) @binding(" (number->string b)
                           ") var<storage, read_write> "
                           (symbol->string (cadr (car ss)))
                           " : array<"
                           ($wgsl-type (cadr (caddr (car ss)))) ">; ")
                          (number (cdr ss) (+ b 1))))))
       (if (null? unis)
           ""
           (string-append
            "struct U { "
            ($wgsl-join (map (lambda (u)
                               (string-append (symbol->string (car u))
                                              " : "
                                              ($wgsl-type (cadr u))))
                             unis)
                        ", ")
            " } @group(0) @binding(" (number->string (length stores))
            ") var<uniform> u : U; "))
       (apply string-append (map $wgsl-helper helpers))
       "@compute @workgroup_size(" (number->string wg) ") "
       "fn cs(@builtin(global_invocation_id) gid : vec3u) { "
       (apply string-append (map $wgsl-stmt (cdddr cmain)))
       "} ")))

  ;; the pipeline's vertex layout, from the same attribute forms
  (define (wgsl-layout vs-forms)
    (let ((attrs (glsl-attributes vs-forms)))
      (cons (fold-left (lambda (acc a) (+ acc (* 4 (caddr a)))) 0 attrs)
            ($wgsl-join (map (lambda (a)
                               ($wgsl-vertex-format (cadr a)))
                             attrs)
                        ",")))))
