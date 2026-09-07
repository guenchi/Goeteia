;; expect: 1
;; A primitive used as a value needs a closure type for its own arity
;; even when nothing else in the program is called with that many
;; arguments.  This file has no one-argument call at all -- the list is
;; quoted, the result is left for the runner to print -- so the arity
;; of car's wrapper has to come from the reference itself.  (The arity
;; scan used to find one by accident, mistaking a form sequence of the
;; right length for an application.)
(import (rnrs))
(apply car '((1)))
