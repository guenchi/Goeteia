;; expect: #t
;; (lng effect): what several independent sources do to one quantity is
;; DATA.  An effect names its kind, its source, when it applies and how
;; strongly; a policy per kind says how the payloads combine; the
;; executor folds them and hands back both the result and where each
;; part of it came from.  Every ordering the answer depends on is in
;; that data -- the phase list, the priority number, the order the
;; effects were collected -- and none of it comes from registration
;; order or from which module loaded first.
;;
;; Dispatch and collection are different jobs, and this file keeps them
;; apart on purpose: a generic picks the ONE rule that applies inside
;; one module, and collect-effects unions what several producers each
;; returned.  There is no implicit method combination anywhere.
;;
;; Policies are named, not passed as procedures, so the whole input to
;; resolve is a datum: it can be written to a file and replayed.  A
;; custom policy is a name the caller binds, exactly as a machine binds
;; its guards.
(import (rnrs) (lng pred) (lng generic) (lng effect))

(define (refused? who thunk)
  (guard (e (#t (and (error? e) (eq? (condition-who e) who))))
    (thunk) #f))
(define (report name ok) (unless ok (display "  FAIL ") (display name) (newline)) ok)

;; ---- an effect is a record, and says what it is ----
(define effect-ok
  (let ((e (make-effect 'damage 'sword 2 'compute '(dice 6))))
    (and (effect? e)
         (not (effect? 'damage))
         (eq? (effect-kind e) 'damage)
         (eq? (effect-source e) 'sword)
         (= (effect-priority e) 2)
         (eq? (effect-phase e) 'compute)
         (equal? (effect-payload e) '(dice 6)))))

;; ---- two phases, two policies, one pass ----
(define hit
  (list (make-effect 'damage 'sword 0 'compute 5)
        (make-effect 'damage 'ring  0 'compute 2)
        (make-effect 'damage 'curse 1 'compute 3)
        (make-effect 'armor  'plate 0 'settle 4)
        (make-effect 'armor  'buff  0 'settle 7)))
(define hit-policies '((damage . sum) (armor . max)))

(define basic-ok
  (let-values (((res prov) (resolve hit '(compute settle) hit-policies)))
    (and (= (cdr (assq 'damage res)) 10)
         (= (cdr (assq 'armor res)) 7)
         (= (length res) 2))))

;; ---- priority first, then the order they were collected ----
;; `last' is the policy that can see the difference: whichever effect is
;; folded last is the answer, so this pins the whole ordering, and it is
;; the cell an unstable sort fails.
(define order-ok
  (let ((es (list (make-effect 'speed 'a 1 'compute 'slow)
                  (make-effect 'speed 'b 0 'compute 'fast)
                  (make-effect 'speed 'c 1 'compute 'final))))
    (let-values (((res prov) (resolve es '(compute) '((speed . last)))))
      (and (eq? (cdr (assq 'speed res)) 'final)
           (equal? (map car (cdr (assq 'speed prov))) '(b a c))))))

;; ---- the phase list decides, not where the effect sits in the input ----
(define phase-ok
  (let ((es (list (make-effect 'hp 'heal 0 'settle 10)
                  (make-effect 'hp 'hit  0 'compute 3))))
    (let-values (((res prov) (resolve es '(compute settle) '((hp . all)))))
      (equal? (cdr (assq 'hp res)) '(3 10)))))

;; ---- a custom policy is a NAME the caller binds ----
(define custom-ok
  (let ((seen 'nothing))
    (let-values (((res prov)
                  (resolve (list (make-effect 'k 'x 0 'p 1) (make-effect 'k 'y 0 'p 2))
                           '(p)
                           '((k . how-many))
                           (list (cons 'how-many
                                       (lambda (payloads)
                                         (set! seen payloads)
                                         (length payloads)))))))
      (and (= (cdr (assq 'k res)) 2)
           (equal? seen '(1 2))))))

;; ---- provenance says who contributed what, in the order it happened ----
(define provenance-ok
  (let-values (((res prov) (resolve hit '(compute settle) hit-policies)))
    (and (equal? (cdr (assq 'damage prov)) '((sword . 5) (ring . 2) (curse . 3)))
         (equal? (cdr (assq 'armor prov)) '((plate . 4) (buff . 7))))))

;; ---- dispatch picks one rule; collection unions several producers ----
;; The generic's three signatures do not overlap ambiguously: on (fire
;; mage) the fire rule dominates the catch-all, so exactly one runs.
;; The union across modules comes from calling each producer, which is
;; the only combining this library does.
(define (skill-of x) (car x))
(define (job-of x) (cdr x))
(define skill-kind (define-classifier 'skill-kind skill-of '(fire ice)))
(define job (define-classifier 'job job-of '(mage warrior)))
(define skill-effects (make-generic 'skill-effects 2 (classifiers skill-kind job)))
(add-handlers! skill-effects
  (list (cons '(fire _) (lambda (s t) (list (make-effect 'damage 'fire 0 'compute 6))))
        (cons '(ice _)  (lambda (s t) (list (make-effect 'damage 'ice 0 'compute 1))))
        (cons '(_ _)    (lambda (s t) '()))))
(define (gear-effects s t) (list (make-effect 'damage 'sword 1 'compute 4)))
(define (aura-effects s t) (list (make-effect 'armor 'robe 0 'settle 1)))

(define modules-ok
  (let ((es (collect-effects (list skill-effects gear-effects aura-effects)
                             '(fire . 3) '(al . mage))))
    (let-values (((res prov) (resolve es '(compute settle) hit-policies)))
      (and (= (cdr (assq 'damage res)) 10)
           (= (cdr (assq 'armor res)) 1)
           (equal? (map car (cdr (assq 'damage prov))) '(fire sword))))))

;; ---- an effect round-trips, so a fight can be replayed ----
(define roundtrip-ok
  (let* ((e (make-effect 'damage 'sword 2 'compute '(dice 6)))
         (d (effect->datum e))
         (back (datum->effect d)))
    (and (equal? d (effect->datum back))
         (eq? (effect-kind back) 'damage)
         (equal? (effect-payload back) '(dice 6))
         (refused? 'effect->datum
                   (lambda () (effect->datum (make-effect 'k 'x 0 'p (lambda () 1)))))  ; a live payload is not a datum
         (refused? 'datum->effect (lambda () (datum->effect '(effect damage))))
         (refused? 'datum->effect (lambda () (datum->effect 'not-an-effect))))))

;; ---- nothing is settled by which entry came first ----
(define refused-ok
  (and (refused? 'resolve (lambda () (resolve (list (make-effect 'k 'x 0 'nope 1)) '(p) '((k . sum)))))   ; a phase no list mentions
       (refused? 'resolve (lambda () (resolve (list (make-effect 'k 'x 0 'p 1)) '(p) '())))               ; a kind with no policy
       (refused? 'resolve (lambda () (resolve (list (make-effect 'k 'x 0 'p 1)) '(p p) '((k . sum)))))    ; a phase given twice
       (refused? 'resolve (lambda () (resolve (list (make-effect 'k 'x 0 'p 1)) '(p) '((k . sum) (k . max)))))
       (refused? 'resolve (lambda () (resolve (list 'not-an-effect) '(p) '((k . sum)))))
       (refused? 'resolve (lambda () (resolve (list (make-effect 'k 'x 0 'p 1)) '(p) '((k . nonesuch)))))  ; not a policy and not bound
       (refused? 'resolve (lambda () (resolve (list (make-effect 'k 'x 0 'p 1)) '(p) '((k . mine))
                                              (list (cons 'mine 42)))))                                   ; bound to something that is not a procedure
       (refused? 'resolve (lambda () (resolve (list (make-effect 'k 'x 0 'p 1)) '(p) '(not-a-pair))))
       (refused? 'make-effect (lambda () (make-effect 'k 'x 'not-a-number 'p 1)))
       (refused? 'make-effect (lambda () (make-effect "not-a-symbol" 'x 0 'p 1)))
       (refused? 'collect-effects (lambda () (collect-effects (list (lambda (a b) 'not-a-list)) 1 2)))
       (refused? 'collect-effects (lambda () (collect-effects (list 'not-a-procedure) 1 2)))
       ;; a built-in policy name means one thing everywhere: rebinding it would
       ;; give one name two readings, which is what this library refuses everywhere else
       (refused? 'resolve (lambda () (resolve (list (make-effect 'k 'x 0 'p 1)) '(p) '((k . sum))
                                              (list (cons 'sum (lambda (ps) 0))))))
       (refused? 'resolve (lambda () (resolve (list (make-effect 'k 'x 0 'p 1)) '(p) '((k . mine))
                                              (list (cons 'mine (lambda (ps) 1))
                                                    (cons 'mine (lambda (ps) 2))))))))

;; ---- a cycle in what the caller hands over is refused, never walked ----
(define cyclic-ok
  (let ((es (list (make-effect 'k 'x 0 'p 1)))
        (phases (list 'p))
        (pol (list (cons 'k 'sum))))
    (set-cdr! es es)
    (set-cdr! phases phases)
    (and (refused? 'resolve (lambda () (resolve es '(p) '((k . sum)))))
         (refused? 'resolve (lambda () (resolve (list (make-effect 'k 'x 0 'p 1)) phases '((k . sum))))))))

(let ((all (list (report "effect" effect-ok) (report "basic" basic-ok)
                 (report "order" order-ok) (report "phase" phase-ok)
                 (report "custom" custom-ok) (report "provenance" provenance-ok)
                 (report "modules" modules-ok) (report "roundtrip" roundtrip-ok)
                 (report "refused" refused-ok) (report "cyclic" cyclic-ok))))
  (display (let loop ((l all)) (cond ((null? l) #t) ((car l) (loop (cdr l))) (else #f))))
  (newline))
