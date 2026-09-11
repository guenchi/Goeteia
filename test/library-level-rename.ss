;; expect: 5
;; A library imports (rename (rnrs) (car hd)) and defines a procedure
;; that uses hd; an importing program gets the library's answer.  Under
;; the driver this worked by accident of where the generated alias sat;
;; when the clause moved to where the program wrote it, the alias moved
;; with it, and the compiler now emits a library's rename aliases from
;; its header under the %library-body tag -- not the driver.  The tree
;; had no cell for a library-level rename, so a regression here would
;; have been silent.  Program-level rename of the same shape answers 7
;; (car of (7 8)); this answers 5 (car of (5 6)) through the library.
(import (rnrs))
(begin
  (library (u) (export g) (import (rename (rnrs) (car hd))) (define (g l) (hd l)))
  (import (u)))
(display (g (list 5 6)))
