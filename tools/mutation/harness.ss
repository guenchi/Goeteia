;; The shared half of every mutation driver (tools/mutate.mjs appends it to
;; a driver of this directory before compiling).  The driver defines
;; MEM-NEED (bytes of linear memory it needs), BASE (where a fixture is
;; loaded), fixtures (a list of (name . bytes)) and (decode! name n), which
;; decodes the n bytes at BASE as the named fixture.
;;
;; The mutations of a fixture, in this order: for each byte, the values
;; 0x00, 0xFF, 0xF0 and its own value plus one (mod 256), each skipped
;; when it is the byte's value or one already tried there; then for each
;; offset with eight bytes after it, a run of eight 0x00 and a run of
;; eight 0xFF, each skipped when the eight bytes already hold it.  A
;; mutation is (len pos val).  The fixtures' mutations are numbered in
;; one sequence, in the order of the list.
;;
;; MUTANT_FROM and MUTANT_TO (environment, decimal) select the numbers
;; [from, to) to decode; MUTANT_FROM -1 prints the counts and every
;; mutation, (m k name len pos val), instead, and -2
;; decodes each fixture unchanged, printing (control name decoded) or
;; (control name refused who "message") -- the tool's check that the
;; fixture and the call are right before any mutation is counted.
;; MUTANT_FROM -3 decodes the one mutation MUTANT_SPEC names as "fixture
;; len pos val", numbered 0 -- the tool's --sample mode, whose list must
;; not depend on the numbering.  Each
;; mutation prints (try k name len pos val) before its decode and
;; (out k decoded) or (out k refused who "message") after; a trap ends the
;; program between the two, which is how the tool tells it.

(define (env-number name)
  (string->number
   (js->string (js-get (js-get (js-get (js-global) "process") "env") name))))

(let ((need (- MEM-NEED (* 65536 (%mem-size)))))
  (when (> need 0) (%mem-grow (quotient (+ need 65535) 65536))))

(define (mutations-of bytes)
  (let* ((v (list->vector bytes)) (n (vector-length v)))
    (define (singles pos acc)
      (if (= pos n)
          acc
          (let ((b (vector-ref v pos)))
            (let each ((vals (list 0 255 240 (remainder (+ b 1) 256)))
                       (tried '()) (acc acc))
              (cond ((null? vals) (singles (+ pos 1) acc))
                    ((or (= (car vals) b) (memv (car vals) tried))
                     (each (cdr vals) tried acc))
                    (else
                     (each (cdr vals) (cons (car vals) tried)
                           (cons (list 1 pos (car vals)) acc))))))))
    (define (holds? pos val)
      (let check ((i 0))
        (or (= i 8)
            (and (= (vector-ref v (+ pos i)) val) (check (+ i 1))))))
    (define (runs pos acc)
      (if (> (+ pos 8) n)
          acc
          (runs (+ pos 1)
                (let* ((acc (if (holds? pos 0) acc (cons (list 8 pos 0) acc)))
                       (acc (if (holds? pos 255) acc (cons (list 8 pos 255) acc))))
                  acc))))
    (reverse (runs 0 (singles 0 '())))))

(define (load! bytes len pos val)
  (let put ((b bytes) (i 0))
    (if (pair? b)
        (begin
          (%mem-u8-set! (+ BASE i)
                        (if (and (>= i pos) (< i (+ pos len))) val (car b)))
          (put (cdr b) (+ i 1)))
        i)))

(define (decode-once k name bytes m)
  (display (list 'try k name (car m) (cadr m) (caddr m)))
  (newline)
  (let ((n (load! bytes (car m) (cadr m) (caddr m))))
    (write
     (guard (e ((condition? e)
                (list 'out k 'refused
                      (if (who-condition? e) (condition-who e) #f)
                      (if (message-condition? e) (condition-message e) "")))
               (#t (list 'out k 'refused #f "a raise of a non-condition")))
       (decode! name n)
       (list 'out k 'decoded))))
  (newline))

(define (control name bytes)
  (let ((n (load! bytes 0 0 0)))
    (write
     (guard (e ((condition? e)
                (list 'control name 'refused
                      (if (who-condition? e) (condition-who e) #f)
                      (if (message-condition? e) (condition-message e) "")))
               (#t (list 'control name 'refused #f "a raise of a non-condition")))
       (decode! name n)
       (list 'control name 'decoded))))
  (newline))

(define (words s)
  (let loop ((cs (string->list s)) (cur '()) (out '()))
    (define (flush) (if (null? cur) out (cons (list->string (reverse cur)) out)))
    (cond ((null? cs) (reverse (flush)))
          ((char=? (car cs) #\space) (loop (cdr cs) '() (flush)))
          (else (loop (cdr cs) (cons (car cs) cur) out)))))

(let ((from (env-number "MUTANT_FROM")) (to (env-number "MUTANT_TO")))
  (when (= from -3)
    (let* ((spec (words (js->string (js-get (js-get (js-get (js-global) "process")
                                                    "env")
                                            "MUTANT_SPEC"))))
           (f (assoc (car spec) fixtures)))
      (if f
          (decode-once 0 (car f) (cdr f) (map string->number (cdr spec)))
          (begin (display (list 'no-fixture (car spec))) (newline)))))
  (when (= from -2)
    (for-each (lambda (f) (control (car f) (cdr f))) fixtures))
  (let walk ((fs fixtures) (k 0))
    (if (null? fs)
        (when (< from 0) (display (list 'total k)) (newline))
        (let* ((name (car (car fs))) (bytes (cdr (car fs)))
               (ms (mutations-of bytes)))
          (when (< from 0)
            (display (list 'count name (length bytes) (length ms))) (newline))
          (let each ((ms ms) (k k))
            (cond ((null? ms) (walk (cdr fs) k))
                  ((= from -1)
                   (display (list 'm k name (car (car ms)) (cadr (car ms))
                                  (caddr (car ms))))
                   (newline)
                   (each (cdr ms) (+ k 1)))
                  ((and (>= k from) (< k to) (>= from 0))
                   (decode-once k name bytes (car ms))
                   (each (cdr ms) (+ k 1)))
                  (else (each (cdr ms) (+ k 1)))))))))
