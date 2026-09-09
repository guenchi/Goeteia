;; expect: #t
;; (gam save): four situations that a single #f would flatten into one.
;;
;; "Nothing is stored", "what is stored is from an older version",
;; "what is stored does not pass your validator" and "this browser will
;; not let me store anything" are not the same fact.  The first three are
;; about the save: there is nothing usable, start fresh.  The last is
;; about the machine, and answering #f for it would mean a player whose
;; storage is blocked starts a new game every time AND never saves, with
;; nothing said.  So it is an error, and there is a predicate to ask
;; first.
;;
;; The store is read through a JS bridge that answers a status rather
;; than throwing, because a JS exception cannot be caught on this side:
;; guard sees Scheme conditions, and a throw from a host call ends the
;; program.  That was measured, not assumed.
(import (rnrs) (web js) (gam save))

(define failed 0)
(define (check name ok)
  (unless ok (set! failed (+ failed 1)) (display "  FAIL ") (display name) (newline)))
(define (refuses? thunk)
  (guard (e ((error? e) #t) (else #f)) (begin (thunk) #f)))
(define (no-store!)
  (js-eval "globalThis.localStorage = undefined;"))
(define (working-store!)
  (js-eval "globalThis.__mem = {};
globalThis.localStorage = { getItem(k){ return (k in globalThis.__mem) ? globalThis.__mem[k] : null },
                            setItem(k,v){ globalThis.__mem[k] = String(v) },
                            removeItem(k){ delete globalThis.__mem[k] } };"))
(define (blocked-store!)                ; present, readable, refuses to write
  (js-eval "globalThis.localStorage = { getItem(k){ return null },
                                        setItem(k,v){ throw new Error('QuotaExceeded') },
                                        removeItem(k){} };"))
(define (raw-put! k v)
  (js-method (js-get (js-global) "localStorage") "setItem" k v))
(define (any? d) #t)
(define (store . v)
  (make-save-store "slot1" (if (null? v) 1 (car v)) any?))

;; ---- no storage at all ----
(no-store!)
(check "with no storage the store is not available" (not (save-available? (store))))
(check "loading without storage is refused, not answered #f"
       (refuses? (lambda () (save-load (store)))))
(check "writing without storage is refused"
       (refuses? (lambda () (save-write! (store) '(hero)))))

;; ---- a storage that works ----
(working-store!)
(check "an available store says so" (save-available? (store)))
(check "nothing stored answers #f" (not (save-load (store))))
(check "writing answers #t" (eq? #t (save-write! (store) '(hero (hp . 7)))))
(check "and it reads back equal" (equal? (save-load (store)) '(hero (hp . 7))))

;; the reason the text is an s-expression and not JSON: a save is made
;; of exactly the numbers a decimal round trip quietly damages
(check "a flonum survives, sign of zero and all"
       (begin (save-write! (store) (list 1.5 -0.0 7))
              (let ((got (save-load (store))))
                (and (equal? (car got) 1.5)
                     (equal? (caddr got) 7)             ; still exact
                     (fl<? (fl/ 1.0 (cadr got)) 0.0)))))  ; -0.0, not 0.0

;; ---- the value handed in is not touched ----
(check "writing does not modify the caller's value"
       (let ((v (list 'hero (cons 'hp 7))))
         (save-write! (store) v)
         (equal? v '(hero (hp . 7)))))

;; ---- three ways there is nothing usable, all answering #f ----
(check "a save from another version is not usable"
       (begin (save-write! (make-save-store "slot1" 1 any?) '(hero))
              (not (save-load (make-save-store "slot1" 2 any?)))))
(check "a save the validator rejects is not usable"
       (begin (save-write! (make-save-store "slot1" 1 any?) '(hero))
              (not (save-load (make-save-store "slot1" 1 (lambda (d) #f))))))
(check "text that is not a save at all is not usable"
       (begin (raw-put! "slot1" "not an s-expression (((")
              (not (save-load (store)))))

;; ---- but a bad value going IN is the caller's bug, and says so ----
(check "writing a value the validator rejects is refused, not answered #f"
       (refuses? (lambda () (save-write! (make-save-store "slot1" 1 (lambda (d) #f)) '(hero)))))

;; ---- present, readable, but will not write ----
(blocked-store!)
(check "a store that refuses to write is not available" (not (save-available? (store))))
(check "writing to it is refused" (refuses? (lambda () (save-write! (store) '(hero)))))
(check "reading from it still answers #f -- it reads, there is just nothing there"
       (not (save-load (store))))
(display (= failed 0))
