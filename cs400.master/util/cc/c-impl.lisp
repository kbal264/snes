;; TODO you can define a function argument and a function local
;; variable with the same name.

(in-package #:cs400-compiler)

"## Scratch Space"
(defmacro c-funcall (function &rest args)
  (dolist (a args) (assert (or (symbolp a) (numberp a))))
  ;; TODO This is just for testing; it doesn't do anything.
  ;(format *error-output* "~%funcall: ~a(~{~a~^, ~})~%~%" function args)
  `(with-indent ,(format nil "_call_to_~a" function)
     (need-call-space ,(length args))
     ,@(iter (for arg in (reverse args))
             (for i from 1)

             ;; TODO Hack
             (collect `(with-indent ,(format nil "_arg_~a" arg)))
             (when (numberp arg)
               (collect `(lda ,arg)))
             (when (symbolp arg)
               (collect `(->A ,arg)))
             (collect `(asm sta :stack-indexed ,(1- (* 2 i)))))
     (asm jsr :absolute (c-fn-unique-name ',function))))

(defmacro need-call-space (amount)
  (declare (ignore amount))
  (values))

;; - TODO These should access global variables.
;; - TODO The macrolet A-> in a scope should fall through to this
;;   version if it can't be found.
(defmacro A-> (var)
  (declare (ignore var))
  (error "Code outside of a function!"))

(defmacro ->A (var)
  (declare (ignore var))
  (error "Code outside of a function!"))



"## Labels, Gotos, Break, and Continue.  "

"
### Lexically bound macros and functions
These macros and functions will be rebound as needed in other macros
using CL:MACROLET and CL:FLET.
"
(defmacro c-continue () (error "continue statement not within a loop"))
(defmacro c-break () (error "break statement not within a loop or switch"))
(defmacro c-goto (label)
  (error "goto (~a) statement outside of a function body" label))
(defmacro c-label (name)
  (error "label (~a) statement outside of a function body" name))
(always-eval
    (defun lookup-label (name)
  (error "Trying to lookup a label (~a) outside of a function body" name)))

(defmacro labels-block (&body code)
  "Binds the macros c-goto and c-label to generate branches and asm
   labels.  "
  (let ((code (preexpand
               (transform-c-syntax
                (preexpand `(progn ,@code))))))
    (with-gensyms (labels)
      `(with-symbol-alias-alist ,labels ,(find-labels code)
         (flet ((lookup-label (label)
                  (or (lookup label ,labels)
                      (error "Undefined label ~a" label))))
           (declare (ignorable #'lookup-label))
           (macrolet ((c-goto (label)
                        (declare (type symbol label))
                        `(%goto (lookup-label ',label)))
                      (c-label (name)
                        `(%label (lookup-label ',name))))
             ,code))))))

"## Control Strutures"
(defmacro c-goto-<if-zero> (label)
  `(%branch-if-not (lookup-label ',label)))

(defun %switch-jump-entry (value target)
  (declare (symbol target) (number value))
  (asm cmp :immediate-w value)
  (emit (format nil "BEQ {~a}" target)))

(defmacro c-block (&body code)
  "TODO This should introduce a new variable namespace.  "
  `(progn ,@code))

(always-eval
  "## Scopes and their identifiers and tags.  "
  (defstruct scope
    "The point of giving scopes names is to help generate better error
   messages and better names of generated names.  For exapmle an
   struct without a type name needs to have a type name generated."
    identifiers tags name)

  (defun new-scope (name)
    (make-scope :identifiers (make-hash-table)
                :tags (make-hash-table)
                :name name))

  (defparameter *scopes* (list (new-scope 'global)))
  (defparameter *global-scope* (first *scopes*))

  (defstruct c-var name type storage-class address)
  (defun new-var (name type storage-class address)
    (make-c-var :name name
                :type type
                :storage-class storage-class
                :address address))

  (defun identifiers-table () (scope-identifiers (first *scopes*)))
  (defun tags-table () (scope-tags (first *scopes*)))

  (defun bind-identifier (name value &optional (scope (first *scopes*)))
    (setf (gethash name (scope-identifiers scope)) value)))

(defmacro with-scope (name &body body)
  `(let ((*scopes* (cons (new-scope ,name) *scopes*)))
     ,@body))


"## Global Memory Allocation"
(defparameter *next-available-global-space* #x0100
  "This will be ***MODIFIED*** when new global space is requested.  ")

(defun allocate-global (size)
  (prog1
      *next-available-global-space*
      (incf *next-available-global-space* size)))

(defmacro c-var (name type &optional value)
  "This expands into code that declares a global variable.  A separate
   version for stack variables is bound with a MACROLET in
   c-proto.  "
  (when value (error "Setting variables is not implemented.  "))
  `(let ((size 2)) ;; replace 2 with (size-of type)
     (when (in-table? ',name (identifiers-table))
       (error "More than one declaration of global identifier ~a.  "
              ',name))
     (setf (gethash ',name (identifiers-table))
           (new-var ',name ',type :static
                    (allocate-global size)))))



"## Functions and Subrountines"
(defmacro c-subroutine (name &body code)
  "This is like #'C-FN except it doesn't do any stack manipulation so no
   variables, etc.  The only really supported constructs are labels
   and gotos.  'NAME will **not** be mangled, so make sure it's what
   you want.  "

  `(with-indent ,(format nil "_subrountine_~s" (intern (symbol-name name)))
     (labels-block
       (bind-identifier ',name (list ',name :scope *scopes* :code ',code))
       (asm-code ',name)
       ,@code
       (asm rts :implied))))

(always-eval
  (defun c-fn-unique-name (symbol)
    "Returns a unique name for a function or a suggested unique-name.
     Also returns whether the function was already bound and whether
     it was already definied.  "
    (flet ((prototype? (fn) (not (cdr fn))))
      (multiple-value-bind (fn already-bound?)
          (gethash symbol (scope-identifiers *global-scope*))
        (values (if already-bound?
                    (first fn)
                    (nice-gensym symbol))
                already-bound?
                (not (prototype? fn)))))))

(defmacro c-proto (name)
  "Binds a unique name to the function 'NAME in the global scope.
   This allows us to reference functions in asm code that haven't been
   defined yet.  Return the unique name.  "
  (multiple-value-bind (unique bound? defined?)
      (c-fn-unique-name name)
    (if defined? (error "global identifier ~a is already bound" name))
    `(progn
       ,(unless bound?
          `(setf (gethash ',name (scope-identifiers *global-scope*))
                 (list ',unique)))
       (asm-code ',unique :prototype t))))

(defmacro with-grown-stack (stack-size &body code)
  "Return a PROGN that grows the stack by STACK-SIZE, runs CODE, then
   shrinks the stack by STACK-SIZE.  "
  `(progn
     ,(when (plusp stack-size)
            `(with-indent "_growing_the_stack"
               (asm tsc :implied)
               (asm sec :implied)
               (asm sbc :immediate-w ,stack-size)
               (asm tcs :implied)))
     ,@code
     ,(when (plusp stack-size)
             `(with-indent "_shrinking_the_stack"
                (asm tsc :implied)
                (asm clc :implied)
                (asm adc :immediate-w ,stack-size)
                (asm tcs :implied)))))

(defmacro with-stack-lookup-macros (variable-spaces &body code)
  "Binds c-VAR to set the variable if given a value and binds REF and
   SET to read from and write to a variable by name.  "
  (with-gensyms (stack-space)
    `(let ((,stack-space ,variable-spaces))
       (flet ((var-addr-mode (varname)
                (declare (ignore varname))
                :stack-indexed)
              (var-addr (varname)
                (elookup varname ,stack-space)))
         (macrolet ((->A (var)
                      (etypecase var
                        (symbol `(asm lda (var-addr-mode ',var)
                                      (var-addr ',var)))
                        (number `(lda ,var))))
                    (A-> (var)
                      `(asm sta (var-addr-mode ',var)
                            (var-addr ',var)))
                    (c-var (name type &optional value)
                      (declare (ignore type))
                      (when value
                        `(progn
                           (lda ,value)
                           (A-> ,name)))))
           ,@code)))))

(defmacro with-stack-variables (variable-declarations args call-space
                                &body code)
  (let* ((vars variable-declarations)
         (local-stack-size call-space)
         (variable-spaces (iter (for (name . type) in vars)
                                (collect
                                    (cons name
                                          (prog1 (1+ local-stack-size)
                                            (incf local-stack-size 2))))))
         (argument-spaces (iter (for name in (reverse args))
                                (for index from (+ 1 2 local-stack-size) by 2)
                                (collect (cons name index)))))
    `(with-grown-stack ,local-stack-size
       (with-stack-lookup-macros ',(append argument-spaces variable-spaces)
         ,@code))))

(defmacro with-return (label &body code)
  `(with-goto-macrolet c-return ,label ,@code))


(defmacro c-proc ((name return-type) args &body code)
  (declare (ignore return-type))
  (let* ((input-code `(progn ,@code))
         (unique-name (c-fn-unique-name name))
         (code (preexpand (transform-c-syntax (preexpand input-code))))
         (needed-call-space (needed-call-space code))
         (vars (append (find-vars code)
                       (find-temp-variables code))))
    `(with-indent ,(format nil "_function_~s"
                           (intern (symbol-name name)))
       (with-scope ',name
         (asm-code ',unique-name)
         (16-bit-mode)
         (with-stack-variables ,vars ,args ,needed-call-space
           (labels-block
             (bind-identifier ',name
                              (list ',unique-name :code ',code)
                              *global-scope*)
             ,code))
         (asm rts :implied)))))

"## Operators"
(defmacro nice-block (name &body code)
  `(with-indent ,(format nil "_~a" name)
     (c-block ,@code)))

(defmacro def-simple-binary-operator (operator mnemonic &key prelude)
  `(defmacro ,operator (operand-1 operand-2)
     `(nice-block ,',(symbol-name operator)
        ,',prelude
        (->A ,operand-1)
        ,(etypecase operand-2
           (symbol `(asm ,',mnemonic (var-addr-mode ',operand-2)
                         (var-addr ',operand-2)))
           (number `(asm ,',mnemonic :immediate-w ,operand-2))))))

(pluralize-macro def-simple-binary-operator def-simple-binary-operators)

(def-simple-binary-operators
  (c-+ adc :prelude (asm clc :implied))
  (c-- sbc :prelude (asm sec :implied))
  (c-^ eor)
  (c-& and)
  (c-band and)
  (c-\| ora)
  (c-bor ora))

(defmacro c-++ (var)
  (declare (type symbol var))
  `(c-block
    (->A ,var)
    (asm inc :accumulator)
    (A-> ,var)))

(defmacro c--- (var)
  `(c-block
     (->A ,var)
     (asm dec :accumulator)
     (A-> ,var)))

(defmacro c-@ (operand)
  "Address of a variable"
  (declare (type symbol operand))
  `(nice-block ,(format nil "address_of_~a" operand)
    (case (var-addr-mode ',operand)
      (:stack-indexed
       (asm clc :implied)
       (asm tsc :implied)
       (asm adc :immediate-w (var-addr ',operand)))
      (:absolute (var-addr ',operand)))))

(defmacro c-$ (operand)
  "Pointer dereference.  "
  `(nice-block 'dereference
     (->A ,operand)
     (asm sta :immediate-w 00)
     (asm lda :direct-indirect 00)))


"## Interrupt Handling"

(defvar *defined-interrupt-handlers* nil)
(defvar *reset-table-written?* nil)
(define-constant +interrupts+ '(:reset :irq :bk :cop :abort :nmi))
(define-constant +interrupt-handler-positions+
  '("$80 $FE" :empty :cop   :brk   :abort :nmi   :empty :irq
    :empty    :empty :empty :empty :empty :empty :reset :empty))

(deftype interrupt-handler-name () (cons 'member +interrupts+))

(defun get-interrupt-name (name)
  (declare (type interrupt-handler-name name))
  (symbol-name name))

(defun vector-table ()
  (unless (member :reset *defined-interrupt-handlers*)
    (error "You must have a handler for the reset interrupt.  "))
  (emit (format nil
                "#Data $00:FFE0 interrupt_vector {~{~a~^~%~a~}}"
                (iter (for interrupt in +interrupt-handler-positions+)
                      (collect
                          (cond
                            ((stringp interrupt)
                             interrupt)
                            ((member interrupt *defined-interrupt-handlers*)
                             (get-interrupt-name interrupt))
                            (t "$FFE0")))
                      (collect "                                   ")))))

(defmacro interrupt-handler (name &body code)
  (declare (type interrupt-handler-name name))
  (let* ((unique-name (get-interrupt-name name)))
    (if (member name *defined-interrupt-handlers*)
        (error "Multiple definitions of interrupt-handler ~a"
               unique-name)
        (push name *defined-interrupt-handlers*))
    `(labels-block
       (asm-code ',name)
       ,@code
       [RTI])))


"## Testing"
(defun repl ()
  (let ((eof '#.(gensym "EOF-")))
    (loop for x = (read *standard-input* nil eof)
       until (eq x eof) do (eval x)
       do (force-output))))

(defun compiler-reset ()
  "For convience at the lisp repl; Clears out the global scope
   effectively destroying everything the compiler has definied.  "
  (clrhash (scope-identifiers *global-scope*))
  (setf *reset-table-written?* nil)
  (setf *defined-interrupt-handlers* nil)
  (clrhash (scope-tags *global-scope*)))

(defun interactive-compiler-test (file)
  (compiler-reset)
  (with-open-file (*standard-input* file)
    (repl)))

(defun compile-c (file)
  (with-open-file (*standard-input* file)
    (repl)))

(defmacro with-goto-macrolet (macro-name label &body code)
  `(macrolet ((,macro-name () `(c::goto ,',label)))
     ,@code))

#|
(c-proc c-main ()
  (c-var c-x c-int 1)
  (c-var c-y c-int 2)
  c-x
  (A-> c-y)
  (c::while c-x (lda 0) (A-> c-x))
  (c-f c-x)
  (c::while c-y
    (c-switch c-x
      (3 (c-block (lda 1)
           (A-> c-x)))
      (4) (5) (6) (7) (8) (9 (c-block
                                 (lda 0)
                               (A-> c-x)))
      (default (c-block
                   (lda 1) (A-> c-y)
                   (c-break)))
      (10 (c-continue))))
  c-y)
|#
