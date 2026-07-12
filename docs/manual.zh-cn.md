# Goeteia 开发者手册

## 简介

Goeteia 是一个自举的 Scheme→WebAssembly-GC 编译器，它能编译自身，并运行在任何支持 Wasm GC 的引擎上（Node 22+、现代浏览器、wasmtime）。本手册介绍在 Goeteia *之上* 构建应用所需的知识，假定你已经了解 R6RS Scheme。我们只覆盖 Goeteia 特有的工具链、库与行为；标准 R6RS 原语不在此文档化。

### 如何阅读签名

每个文档化的过程给出：调用形式、一行类型签名、一句说明，以及——在结果值得展示时——一个带 `=>` 的示例。

类型行从左往右读：以 `func`（过程本身）开头，箭头依次穿过它的各个参数，最后一项是结果；`...` 表示变长尾部。无参过程就是 `func -> result`。结果为 `void` 表示该调用只为其**副作用**而执行（副作用在说明里写明）；结果为 `never` 表示它不会正常返回（会抛出）。结果类型后写一个具体值，表示确切返回什么——`func -> *jsObject globalThis` 返回的就是 `globalThis` 对象。宏用同样方式书写，但标头为 `syntax:`。

`*` 前缀的名字是*指向宿主对象的指针*：`*jsObject`（一个持有 JS 值的 Wasm `externref`），同理还有 `*domElement`、`*signal`、`*effect`、`*response`、`*ws`、`*sse`、`*three`。其他类型：`any`、`string`、`number`、`int`、`boolean`、`symbol`、`list`、`pair`、`vector`、`alist`、`procedure`、`port`、`hashtable`、`condition`、`datum`、`sxml`、`raw`（原始 HTML 标记）以及 `template`（`sx`/`s3d` 的字面模板形式）。

## 目录

1. [工具链与工作流](#工具链与工作流)
2. [程序结构](#程序结构)
3. [库系统](#库系统)
4. [值与 Goeteia 特有的表示](#值与-goeteia-特有的表示)
5. [超出常见 R6RS 的运行时设施](#超出常见-r6rs-的运行时设施)
6. [JavaScript FFI](#javascript-ffi)
7. [DOM](#dom)
8. [响应式](#响应式)
9. [模板](#模板)
10. [HTML 与 CSS 即数据](#html-与-css-即数据)
11. [React 互操作](#react-互操作)
12. [3D 与 WebGL](#3d-与-webgl)
13. [网络](#网络)
14. [在浏览器中运行](#在浏览器中运行)
15. [测试](#测试)
16. [从 JavaScript/TypeScript 移植](#从-javascripttypescript-移植)
17. [当前限制与计划中的工作](#当前限制与计划中的工作)

## 工具链与工作流

### 编译与运行

Goeteia 以一个预编译的 `goeteia.wasm` 二进制发布——它就是编译器本身。编译并运行一个 Scheme 程序：

```bash
node rt/compile.mjs goeteia.wasm program.ss program.wasm
node rt/run.mjs program.wasm
```

编译器读入 `program.ss`，解析其库导入，产出 `program.wasm`。运行器实例化该 wasm 模块，调用其导出的 `main()` 函数，并打印结果。

一个程序由顶层定义后跟表达式组成；最后一个表达式的值就是程序结果：

```scheme
(define (fact n)
  (if (zero? n) 1 (* n (fact (- n 1)))))
(fact 20)  ; prints 2432902008176640000
```

### Chez 路径（可选）

装有 [Chez Scheme](https://cisco.github.io/ChezScheme/) 时，可用 `./bin/schwasmc` 编译，本地可能更快：

```bash
./bin/schwasmc program.ss program.wasm
```

Chez 是可选的——它只用于自举以及作为自举编译器的独立校验者，不是运行时依赖。

### 自举与不动点

当你修改编译器（`src/compiler.ss`）后，重建快照：

```bash
./rebuild.sh
```

它执行：
1. **候选**：当前的 `goeteia.wasm` 把源码编译成 `candidate.wasm`
2. **校验**：`candidate.wasm` 再次把源码编译成 `verify.wasm`
3. 若两者逐字节相同，`candidate.wasm` 成为新的 `goeteia.wasm` 快照

不动点检查保证编译器是稳定的——相同输入总是产出相同输出。若出现 "FIXPOINT FAILED"，说明你的改动破坏了自举不变式；检查编译器顶层形式的顺序（见 design.md）。

要用 Chez 作为独立宿主做更强的检查：

```bash
./build-self.sh
```

这会验证 Chez 与自举编译器产出逐字节相同的输出，跨两个独立实现保证正确性。

## 程序结构

一个 Goeteia 程序是一串顶层定义与表达式。表达式按顺序执行；最后一个表达式的值即程序结果：

```scheme
(define x 5)
(define (double y) (+ y y))
(display x)
(double 10)  ; this value is printed by rt/run.mjs
```

### 导出

顶层定义默认对模块私有。要把定义暴露给宿主：

```scheme
(export name1 name2 ...)
```

`export` 形式列出成为 wasm 导出的名字。死代码消除会剪掉所有未使用的定义，所以导出主要是文档性的——用它标记 API 表面。

### 结果解码

宿主按如下方式解码程序结果：
- **定点数**与**字符**：打印为数字或 `#\c`
- **布尔**、`()`、**符号**：打印为 `#t`、`#f`、`()`、`symbol`
- **其他对象**（序对、字符串、向量、记录、闭包）：显示为 `#<object>`，除非显式用 `display` 或 `write` 转成字符串

要查看结果，使用标准的写出过程：

```scheme
(write (list 1 2 3))      ; writes (1 2 3) to stdout
(display "hello")         ; writes hello
(number->string (+ 1 2))  ; "3" — build a string to return/inspect
```

`display`/`write` 无论如何都写到 stdout；只有最终被*解码的返回值*才会回退到 `#<object>`。

## 库系统

库即模块——每个库是单个 `.ss` 文件里的一个 `(library ...)` 形式。

### 库声明

```scheme
(library (name parts...)
  (export item1 item2 ...)
  (import ...)
  ;; definitions and expressions
  )
```

名为 `(math utils)` 的库位于 `math/utils.ss`，按以下顺序查找：
1. 导入方文件所在目录
2. 其 `lib/` 子目录
3. 工具链的 `lib/` 目录（Goeteia 自带库所在处）

使用找到的第一个文件。

### 导入与规格

顶层 `(import ...)` 形式引入库。驱动器递归解析导入（依赖优先、每个库一次）并内联它们：

```scheme
(import (math utils))          ; load math/utils.ss
(import (rnrs lists))          ; builtin rnrs library
(import (only (web js) js-get js-set!))  ; restrict to these exports
(import (except (web dom) alert))        ; import all except alert
(import (rename (web dom) (window w)))   ; alias window to w
(import (prefix (web sx) sx-))           ; prefix all with sx-
```

**内建库**：`(rnrs ...)` 和 `(schwasm ...)` 由 prelude 提供，编译进每个模块，你不能重新定义它们。

### 死代码消除

编译器剪除未使用的定义，所以即便一个库导出很多名字，也只有实际用到的会被编入。这让模块保持精简。

## 值与 Goeteia 特有的表示

Goeteia 的值以一等 GC 对象的形式存活在 Wasm 引擎的垃圾回收堆上。少数方面与可移植 Scheme 不同：

### 定点数范围

定点数是未装箱的 30 位有符号整数：大致 `[-2^29, 2^29)`（具体为 `[-536870912, 536870911]`）。溢出时，算术会自动提升为大整数：

```scheme
(+ 536870911 1)       ; gives bignum 536870912
(* 1000000 1000000)   ; products checked in i64, promote if needed
```

### 数值塔

- **定点数**：`-536870912` 到 `536870911`，未装箱且快
- **大整数**：任意精度整数，溢出时自动提升
- **浮点数**：IEEE-754 64 位浮点（字面量如 `1.5`、`+nan.0`）
- **有理数**：精确分数——`(/ 1 3)` 得 `1/3`，保持精确
- **复数**：`+2i`、`(make-rectangular 1 2)` → `1+2i`

完整数值塔已实现。算术传染按 complex ⊃ flonum ⊃ ratio ⊃ integer 运行：`(+ 1/2 0.5)` → `1.0`、`(* 2 1/3)` → `2/3`、`(sqrt -1)` → `0+1.0i`、`(make-rectangular 1 2)` → `1+2i`。

### 记录

`define-record-type` 编译为带一个标识槽（一个唯一序对）的 GC 结构，所以 `point?` 是一次 `ref.test` 加一次 `ref.eq`。若字段声明为 `(mutable ...)`，记录可通过字段访问器修改。

### 底层原语

以 `%` 为前缀的名字（如 `%js-ref?`、`%make-string`）是供内部使用的底层 Wasm 原语。请改用库封装（`(web js)` 里的 `js-ref?`、`(rnrs strings)` 里的 `make-string`）。

## 超出常见 R6RS 的运行时设施

### 端口与 I/O

**字符串端口**是一等对象：
```scheme
(define out (open-output-string))
(display "hello" out)
(get-output-string out)  ; => "hello"

(define in (open-input-string "5"))
(read in)                ; => 5
```

**文件端口**（仅 Node；浏览器桩返回错误）：
```scheme
(call-with-input-file "data.txt" read)
(call-with-output-file "out.txt" (lambda (p) (display "hello" p)))
```

**控制台**：`display`、`write`、`newline` 默认写到 stdout（`io.write_byte` 导入）。

```
procedure: (open-output-string)

func -> port
```
一个新的内存输出端口，累积写入的字节。

```
procedure: (get-output-string port)

func -> port -> string
```
字符串输出端口中累积的文本。

```
procedure: (open-input-string s)

func -> string -> port
```
一个从字符串 `s` 读取的输入端口。

```
procedure: (call-with-input-file path proc)

func -> string -> procedure -> any
```
（仅 Node。）打开 `path`，调用 `(proc port)`，关闭，返回其值。浏览器桩会抛出。

```
procedure: (call-with-output-file path proc)

func -> string -> procedure -> any
```
（仅 Node。）以写方式打开 `path`，调用 `(proc port)`，关闭，返回其值。

### 哈希表

以 `eq?` 或 `equal?` 为键的哈希表。`make-hashtable` 接受一个哈希过程和一个等价谓词，或使用 `eq`/`equal` 简写；`hashtable-ref` 需要一个默认值：
```scheme
(define ht (make-eq-hashtable))               ; also make-eqv-hashtable
(define eqht (make-hashtable equal-hash equal?)) ; equal? keys
(hashtable-set! ht 'name "Alice")
(hashtable-ref ht 'name #f)                   ; => "Alice"  (#f if absent)
```

```
procedure: (make-eq-hashtable)

func -> hashtable
```
一个以 `eq?` 为键的新哈希表（`make-eqv-hashtable` 用 `eqv?`）。

```
procedure: (make-hashtable hash equiv)

func -> procedure -> procedure -> hashtable
```
一个带自定义哈希过程与等价谓词的新哈希表，如 `(make-hashtable equal-hash equal?)`。

```
procedure: (hashtable-set! ht key value)

func -> hashtable -> any -> any -> void
```
把 `key` 关联到 `value`。

```
procedure: (hashtable-ref ht key default)

func -> hashtable -> any -> any -> any
```
`key` 对应的值，若不存在则返回 `default`。默认值是必需的。

```
procedure: (hashtable-contains? ht key)

func -> hashtable -> any -> boolean
```
`key` 是否存在。

```
procedure: (hashtable-delete! ht key)

func -> hashtable -> any -> void
```
若存在则删除 `key`。

```
procedure: (hashtable-update! ht key proc default)

func -> hashtable -> any -> procedure -> any -> void
```
把 `key` 设为 `(proc current)`；当 `key` 不存在时以 `default` 作为当前值。

```
procedure: (hashtable-size ht)

func -> hashtable -> int
```
条目数量。

```
procedure: (hashtable-keys ht)

func -> hashtable -> vector
```
所有键组成的向量。

### 符号与 Gensym

符号在编译期以及运行期通过 `string->symbol` 被驻留（intern）。它们可用 `eq?` 比较。`gensym` 接受一个必需的前缀并追加一个新的计数：

```scheme
(gensym "var")  ; => a symbol named var0, var1, ... (prefix + counter)
```

```
procedure: (gensym prefix)

func -> string -> symbol
```
一个全新、看似未驻留的符号：`prefix` 加上一个逐次递增的计数。

```
procedure: (string->symbol s)

func -> string -> symbol
```
把 `s` 驻留为符号（与任何同名符号 `eq?`）。

```
procedure: (symbol->string sym)

func -> symbol -> string
```
`sym` 的名字，作为字符串。

### 错误处理

`guard`/`raise` 与 `dynamic-wind`：

`error` 一步构造并抛出一个条件——`(error who message irritant ...)`；`guard` 捕获它，`condition-message` / `error?` 检视它：

```scheme
(guard (e ((error? e)
           (display (condition-message e))))
  (error 'sqrt "negative argument" -1))

(dynamic-wind
  (lambda () (display "enter"))
  (lambda () (display "body"))
  (lambda () (display "exit")))
```

```
procedure: (error who message irritant ...)

func -> symbol -> string -> any -> ... -> never
```
用 `who`/`message`/`irritants` 构造一个条件并抛出。永不正常返回——用 `guard` 捕获。

```
procedure: (raise obj)

func -> any -> never
```
把 `obj` 作为条件抛给最近的外层 `guard`。

```
procedure: (error? c)

func -> any -> boolean
```
`c` 是否为错误条件。

```
procedure: (condition-message c)

func -> condition -> string
```
一个条件所携带的消息。

```
syntax: (guard (var clause ...) body ...)

any
```
求值 `body`；若抛出，把条件绑定到 `var` 并按 `cond` 风格的 `clause` 分派（如上例）。求值为 body 的值，或抛出时所选子句的值。

```
procedure: (dynamic-wind before thunk after)

func -> procedure -> procedure -> procedure -> any
```
依次运行 `(before)`、`(thunk)`、`(after)`——即使 `thunk` 通过续延逃逸，`after` 也会运行。返回 `thunk` 的值。

### 续延

`call/cc` 只捕获**转义续延**——你可以跳出当前上下文，但不能重新进入已捕获的续延。这是因为 Wasm 异常处理（用来实现续延）支持向上跳转，不支持可重入：

```scheme
(call/cc
  (lambda (escape)
    (for-each (lambda (x)
                (when (zero? (remainder x 7))
                  (escape x)))       ; jump out with the first hit
              '(1 2 3 7 14 21))))
; => 7
```

不要多次调用一个已捕获的续延；第二次调用会陷入（trap）。

```
procedure: (call/cc proc)

func -> procedure -> any
```
调用 `(proc k)`，其中 `k` 是一个**转义**续延：调用 `(k v)` 会从 `call/cc` 形式返回 `v`。`call-with-current-continuation` 是同一过程的全名。`k` 是一次性的，且只能向上跳。

## JavaScript FFI

`(web js)` 库提供到 JavaScript 的桥。Scheme 闭包通过 `->js` 过程和内部的 `$jscb` 回调协议自动成为可调用的 JS 函数。

### 导出与用法

```
procedure: (js-ref? v)

func -> any -> boolean
```
判断 `v` 是否为一个 JS 引用（externref）。

```
procedure: (js-global)

func -> *jsObject globalThis
```

```
procedure: (js-undefined)

func -> *jsObject undefined
```

```
procedure: (js-eq? a b)

func -> *jsObject -> *jsObject -> boolean
```
JS 同一性：`a === b`。

```
procedure: (js-truthy? v)

func -> *jsObject -> boolean
```
`v` 的 JS 真值性。

```
procedure: (js-get obj name)

func -> *jsObject -> string -> *jsObject
```
读取属性：`obj[name]`。

```scheme
(js->number (js-get (js-eval "[10,20,30]") "length"))
=> 3
```

```
procedure: (js-set! obj name value)

func -> *jsObject -> string -> any -> void
```
写入属性：`obj[name] = value`。

```
procedure: (js-call f thisval args ...)

func -> *jsObject -> *jsObject -> any -> ... -> *jsObject
```
应用一个函数：`f.apply(thisval, [args ...])`。

```
procedure: (js-method obj name args ...)

func -> *jsObject -> string -> any -> ... -> *jsObject
```
调用一个方法：`obj[name](args ...)`。

```
procedure: (js-new ctor args ...)

func -> *jsObject -> any -> ... -> *jsObject
```
构造：`new ctor(args ...)`。

```
procedure: (js-index obj i)

func -> *jsObject -> int -> *jsObject
```
索引：`obj[String(i)]`。

```
procedure: (string->js s)

func -> string -> *jsObject
```
把一个 Scheme 字符串转成 JS 字符串。

```
procedure: (js->string r)

func -> *jsObject -> string
```
把一个 JS 字符串转成 Scheme 字符串。

```scheme
(js->string (js-eval "'ab'+'c'"))
=> "abc"
```

```
procedure: (number->js x)

func -> number -> *jsObject
```
把一个 Scheme 数转成 JS 数。

```
procedure: (js->number r)

func -> *jsObject -> number
```
把一个 JS 数转成 Scheme 数——在范围内为定点数，否则为浮点数。

```
procedure: (->js v)

func -> any -> *jsObject
```
把任意 Scheme 值转成 JS：闭包变成函数；`#t` / `#f` / `()` 映射到对应的 JS 值。

```
procedure: (js-eval code)

func -> string -> *jsObject
```
在全局作用域求值 JavaScript：`eval(code)`。

```scheme
(js->number (js-eval "40+2"))
=> 42
```

### 闭包作为函数

Scheme 闭包会自动转换成可调用的 JS 函数：

```scheme
(define callback (lambda (x) (+ x 1)))
(js-set! (js-global) "myCallback" (->js callback))
; now JS can call globalThis.myCallback(5), which calls the Scheme closure
```

宿主侧的桥（`rt/jsbridge.mjs`，由 `rt/run.mjs` 和 `rt/web.mjs` 使用）把闭包作为不透明引用持有，并在 JS 调用它时触发导出的 `$jscb`，通过专用导入编解码参数与返回值。错误处理：若闭包抛错，异常被捕获并返回 `undefined`。

### 示例：DOM 操作

```scheme
(import (web js) (web dom))

(define el (query-selector "#myButton"))
(add-event-listener! el "click"
  (lambda (event)
    (console-log "clicked")))
(js-method el "setAttribute" "disabled" "true")
```

## DOM

`(web dom)` 库封装 DOM。一个 DOM 节点是 `*domElement`（底层是 `*jsObject`）；多数修改器返回 `void`，仅为对树的副作用而调用。

```
procedure: (window)

func -> *jsObject
```
返回 `globalThis`。

```
procedure: (document)

func -> *jsObject
```
返回 `globalThis.document`。

```
procedure: (body)

func -> *domElement
```
返回 `document.body`。

```
procedure: (get-element-by-id id)

func -> string -> *domElement
```
`document.getElementById(id)`。

```
procedure: (query-selector sel)

func -> string -> *domElement
```
`document.querySelector(sel)`——CSS 选择器的第一个匹配。

```
procedure: (create-element tag)

func -> string -> *domElement
```
`document.createElement(tag)`——一个新的、未挂载的元素。

```
procedure: (make-text s)

func -> string -> *domElement
```
`document.createTextNode(s)`——一个新的文本节点。

```
procedure: (append-child! parent child)

func -> *domElement -> *domElement -> void
```
把 `child` 作为 `parent` 的最后一个子节点追加。

```
procedure: (replace-child! parent new old)

func -> *domElement -> *domElement -> *domElement -> void
```
在 `parent` 的子节点中用 `new` 替换 `old`。

```
procedure: (insert-before! parent new ref)

func -> *domElement -> *domElement -> *domElement -> void
```
把 `new` 插入 `parent`，恰在现有子节点 `ref` 之前。

```
procedure: (remove-child! parent child)

func -> *domElement -> *domElement -> void
```
从 `parent` 移除 `child`。

```
procedure: (remove-all-children! el)

func -> *domElement -> void
```
移除 `el` 的每个子节点，使其清空。

```
procedure: (set-inner-html! el s)

func -> *domElement -> string -> void
```
设置 `el.innerHTML = s`。

```
procedure: (inner-text el)

func -> *domElement -> string
```
以 Scheme 字符串读取 `el.innerText`。

```
procedure: (set-text! el s)

func -> *domElement -> string -> void
```
设置 `el.textContent = s`。

```
procedure: (set-attribute! el name v)

func -> *domElement -> string -> string -> void
```
把 `el` 上的属性 `name` 设为 `v`。

```
procedure: (set-style! el prop v)

func -> *domElement -> string -> string -> void
```
把 `el.style` 上的 CSS 属性 `prop` 设为 `v`。

```
procedure: (add-event-listener! el event handler)

func -> *domElement -> string -> procedure -> void
```
为 `event`（如 `"click"`）挂载 `handler`。`handler` 是一个 Scheme 过程，被调用时以事件作为 `*jsObject` 传入。

```
procedure: (console-log x)

func -> any -> void
```
`console.log(x)`；非字符串值先用 `write` 渲染。

```
procedure: (alert s)

func -> string -> void
```
弹出一个消息为 `s` 的浏览器 alert 对话框。

## 响应式

`(web reactive)` 库实现细粒度的响应式更新：信号持有值，效果观察它们，依赖追踪自动进行。`*signal` 是一个响应式单元；`*effect` 是一个活动的观察者。

### 过程

```
procedure: (signal init)

func -> any -> *signal
```
创建一个持有 `init` 的信号。

```
procedure: (signal-ref s)

func -> *signal -> any
```
读取当前值。在 `effect` 内部调用时，会把该效果订阅到 `s`。

```
procedure: (signal-set! s v)

func -> *signal -> any -> void
```
把值设为 `v` 并重跑观察它的效果。若写入的值与当前值 `eqv?`，则无操作。

```
procedure: (signal-update! s f)

func -> *signal -> procedure -> void
```
把值设为 `(f current-value)`。

```
procedure: (effect thunk)

func -> procedure -> *effect
```
立即运行 `thunk`，追踪它读取的每个信号，并在其中任一信号变化时重跑。返回效果句柄。

```
procedure: (dispose-effect! e)

func -> *effect -> void
```
停止效果 `e` 并释放它拥有的效果；它不会再重跑。

```
procedure: (root thunk)

func -> procedure -> pair
```
在一个全新的、游离的属主下运行 `thunk`，使其中创建的效果能在任何外层效果重跑时存活。返回 `(result . dispose)`——`car` 是 `thunk` 的值，`cdr` 是释放整棵树的 thunk。

```
procedure: (batch thunk)

func -> procedure -> any
```
运行 `thunk`，把它的所有信号写入合并为末尾的一次效果重跑。返回 `thunk` 的值。

```
procedure: (untracked thunk)

func -> procedure -> any
```
运行 `thunk`，但不把当前效果订阅到它读取的任何信号。返回 `thunk` 的值。

端到端的行为：

```scheme
(define c (signal 0))
(define d (signal 0))
(effect (lambda () (signal-set! d (* 2 (signal-ref c)))))
(signal-ref d)                      ; => 0   (ran once at creation)
(signal-set! c 5)
(signal-ref d)                      ; => 10  (effect reran)
(batch (lambda () (signal-set! c 100) 'done))  ; => done
(untracked (lambda () (signal-ref c)))          ; => 100
```

### 信号

一个信号持有值，并在其变化时通知观察者：

```scheme
(define count (signal 0))
(signal-ref count)              ; read current value
(signal-set! count 5)           ; set value
(signal-update! count (lambda (v) (+ v 1)))  ; update via a function
```

写入相同的值（用 `eqv?` 检测）不会触发观察者。

### 效果

一个效果运行一个 thunk，并自动追踪它读取了哪些信号：

```scheme
(define count (signal 0))
(define doubled (signal 0))

(effect (lambda ()
  (let ((c (signal-ref count)))
    (signal-set! doubled (* c 2)))))

(signal-set! count 5)  ; effect reruns, doubled becomes 10
```

当效果读取的信号变化时，效果重跑。重新订阅是自动的。

### 批处理

`batch` 把多次信号更新合并为一次效果重跑：

```scheme
(batch (lambda ()
  (signal-set! count 1)
  (signal-set! total 10)))
; effects run once, not twice
```

### 效果属主关系

在一个效果内部创建的效果被那个效果*拥有*。当属主重跑时，它的子效果被释放（运行到完成、然后标记为死亡）并重新创建：

```scheme
(effect (lambda ()
  (let ((filter (signal-ref current-filter)))
    (effect (lambda ()
      ;; this inner effect dies when the outer one reruns
      (display (signal-ref data)))))))
```

这防止过期的内层效果在外层切换上下文后仍然触发。

### Untracked 与 Root

`untracked` 读取信号而不订阅：

```scheme
(effect (lambda ()
  (let ((x (signal-ref count)))        ; subscribed
    (let ((y (untracked (lambda ()
      (signal-ref hidden)))))          ; not subscribed
      ...))))
```

`root` 创建一个游离的属主——其中的效果在外层重跑时存活，只能通过显式释放而死亡：

```scheme
(let ((r (root (lambda ()
  (effect (lambda () ...))
  (signal 0)))))
  (car r))  ; the return value
; (cdr r)  ; the dispose thunk
```

这对生命周期长于单个效果的组件很有用。

## 模板

`(web sx)` 宏构建响应式 DOM 模板。静态结构在展开期一次性构建；动态孔洞成为就地更新的效果。

### 过程

`sx` 是宏；`sx-mount` 和 `sx-list` 是过程。

```
syntax: (sx template)

template -> *domElement
```
把一个准引用（quasiquote）标记模板展开成活的 DOM 片段：静态结构一次性构建；每个 `,`-unquote 成为一个就地更新的效果（或在 `on-*` 属性下成为事件监听器）。返回根元素。

```
procedure: (sx-mount container node)

func -> *domElement -> *domElement -> *domElement
```
把 `node`（通常是一个 `sx` 片段）作为 `container` 的子节点追加，并返回 `node`。

```
procedure: (sx-list thunk render [key])

func -> procedure -> procedure -> procedure -> *domElement
```
构建一个宿主元素，其子节点追踪一个动态列表。`(thunk)` 产出当前的项；`(render item)` 为每项产出一个节点。无 `key` 时重建是朴素的（清空 + 重新渲染）；给定 `key` 过程时，键仍在的项保留其节点、效果与 DOM 状态，只做移动。返回宿主元素。

### `sx` 宏

```scheme
(import (web sx) (web reactive) (web dom))

(define count (signal 0))

(sx (div
  (@ (id "counter") (class "app"))
  (span ,(signal-ref count))
  (button (@ (on-click ,(lambda _ (signal-update! count (lambda (v) (+ v 1))))))
    "+")))
```

该宏展开为对 `$sx-build` 的调用，它：
1. **引用模板**：静态结构一次性构建
2. **抽取孔洞**：unquote 成为在效果内重跑的 thunk
3. **区分监听器**：`on-*` 属性孔洞求值一次并作为监听器挂载；其他孔洞都是就地更新的效果

### 孔洞类型

- **监听器孔洞**（`on-click`、`on-change` 等）：unquote 表达式在构建期求值一次并作为事件监听器挂载
- **属性孔洞**（其他属性）：动态表达式成为更新属性值的效果
- **子节点孔洞**：动态表达式成为更新子文本节点或元素的效果

### 挂载

`sx-mount` 把模板追加到容器：

```scheme
(sx-mount (get-element-by-id "app")
  (sx (div (h1 "Hello"))))
```

返回根元素。

### 动态列表

`sx-list` 渲染一个动态项列表。无键时，重建是朴素的（清空并重新渲染）：

```scheme
(define items (signal '("apple" "banana")))

(sx-mount container
  (sx-list (lambda () (signal-ref items))
           (lambda (item)
             (sx (li ,item)))))
```

有了键函数，节点按标识作键，因此移动项会保留其 DOM 状态与效果：

```scheme
(define todos (signal '()))  ; list of (id . title) pairs

(sx-mount container
  (sx-list (lambda () (signal-ref todos))
           (lambda (todo)
             (sx (li (@ (id ,(number->string (car todo))))
                   (span ,(cdr todo)))))
           car))  ; key function: use car (the id) as the key
```

### 只写 DOM 原则

DOM 被当作只写表面——绝不从中读取以获取状态。用信号持有状态；让模板把信号投影到 DOM：

```scheme
;; Good: state in signal, DOM projects from it
(define text (signal ""))
(sx (input (@ (on-input ,(lambda (e)
  (signal-set! text (js->string (js-get (js-get e "target") "value"))))))))

;; Bad: reading from the DOM defeats reactivity
(let ((val (js->string (js-get (query-selector "input") "value"))))
  ...)
```

## HTML 与 CSS 即数据

两个构建期库把 s-表达式渲染成标记与样式——正是用来生成本站点的纯函数对偶（见 `site/*.ss`）。二者都不碰 DOM；都只返回字符串。

### `(web html)`：SXML → HTML

一个 SXML 节点是 `(tag (@ (attr value) ...) child ...)`，其中 child 是字符串（发出时转义）或另一个节点；`(raw s)` 原样插入一个字符串。

```
procedure: (sxml->html node)

func -> sxml -> string
```
把一个 SXML 节点渲染成 HTML 字符串；文本内容会被转义。

```scheme
(sxml->html '(div (@ (class "a")) "hi " (b "x") " <>&"))
=> "<div class=\"a\">hi <b>x</b> &lt;&gt;&amp;</div>"
```

```
procedure: (html->document node)

func -> sxml -> string
```
同 `sxml->html`，但前缀 `<!DOCTYPE html>`——一整页。

```
procedure: (html-escape s)

func -> string -> string
```
转义 `&`、`<`、`>` 以用作文本内容。

```scheme
(html-escape "a <b> & \"c\"")
=> "a &lt;b&gt; &amp; \"c\""
```

```
procedure: (raw s)

func -> string -> raw
```
包裹 `s`，使 `sxml->html` **不转义**地发出它——用于预渲染的 HTML 或像 `&nbsp;` 这样的实体。

```
procedure: (raw? x)

func -> any -> boolean
```
判断 `x` 是否为一个 `raw` 标记。

### `(web css)`：规则列表 → CSS

一张样式表是一个规则列表；一条规则是 `(selector (prop value ...) ...)`。选择器是符号（元素名）或字符串（任何含 `.`/`#`/`:`/空格 的）。值：精确整数原样通过，字符串按字面，单位形式如 `(em 0 92)` → `0.92em`、`(var ink)` → `var(--ink)`；`@media` / `@keyframes` / `@supports` 嵌套规则。

```
procedure: (css->string rules)

func -> list -> string
```
把一个规则列表渲染成 CSS 字符串。

```scheme
(css->string '((body (margin 0) (color (var ink)))
               (".nav a" (font-size (em 0 92)))))
=> "body{margin:0;color:var(--ink);}.nav a{font-size:0.92em;}"
```

```
procedure: (num->css n)

func -> number -> string
```
渲染单个数值 CSS 标量——一个精确整数，或一个原样通过的字符串。供单位形式内部使用。

## React 互操作

`(web react)` 库把 Goeteia 组件嵌入 React 应用。

```
procedure: (react-component name mount)

func -> string -> procedure -> void
```
以 `name` 注册一个组件工厂。`mount` 以 `(mount container props)` 调用——`container` 是 React 为你创建的 DOM 元素，`props` 是一个 JS 对象——并可返回一个释放 thunk。

```
procedure: (props-ref props name)

func -> *jsObject -> string -> any
```
从 `props` 对象读取属性 `name`，不存在则返回 `#f`。

### Scheme 侧：`react-component`

```scheme
(import (web react) (web sx) (web reactive) (web dom))

(react-component "Counter"
  (lambda (container props)
    ;; container: a DOM element React created for you
    ;; props: JS object with prop values
    
    (let ((start (or (props-ref props "start") 0)))
      (define count (signal start))
      (sx-mount container
        (sx (div
          (span ,(signal-ref count))
          (button (@ (on-click ,(lambda _ (signal-update! count 1+))))
            "+"))))
      
      ;; return a dispose thunk (optional)
      (lambda ()
        (display "unmounting")))))
```

`react-component` 在 `globalThis.__goeteia[name]` 上注册一个工厂。工厂接受 `(container, props)` 并返回一个释放 thunk。

### Props

`props-ref` 按名读取一个属性，返回 JS 值或 `#f`（若不存在）：

```scheme
(define value (props-ref props "value"))
(if value (do-something (js->string value)))
```

### JS 侧：`goeteiaComponent`

在你的 React 应用中：

```javascript
import { loadGoeteia } from './rt/web.mjs';
import { goeteiaComponent } from './rt/react.mjs';

loadGoeteia('widgets.wasm');

const Counter = goeteiaComponent(React, 'Counter');

export default function App() {
  return <Counter start={10} />;
}
```

`goeteiaComponent(React, name, opts?)` 把一个 Goeteia 工厂包装成 React 组件。属性流入；任一属性变化时组件重新挂载（通过 `useEffect` 依赖数组里的 `Object.values(props)`）。释放 thunk 在卸载时运行。

## 3D 与 WebGL

三个图形库，从高到低分层。它们都遵循与 `sx` 相同的原则：场景以数据描述，一次性构建，渲染表面只写——桥的流量是 O(变化)，绝不是 O(帧)。

### `(web three)`：响应式场景

`s3d` 模板像 `sx` 构建 DOM 那样构建 Three.js 场景图。静态结构一次性构建；unquote 的属性值成为就地更新的信号驱动孔洞。`three-loop!` 把帧泵入一个 Scheme thunk，由它驱动信号并渲染。

```scheme
(import (web three) (web reactive) (web dom))

(define angle (signal 0.0))

(define world
  (s3d (scene
    (mesh (@ (geometry (box 1 1 1))
             (material (standard (@ (color "#1550c4") (metalness 0.3))))
             (rotation-y ,(signal-ref angle))
             (rotation-x ,(* 0.4 (signal-ref angle)))))
    (ambient-light (@ (intensity 0.6)))
    (directional-light (@ (intensity 1.6) (position 5 10 7))))))

(define camera (s3d (perspective-camera (@ (fov 60) (position 0 0.8 3)))))
(define renderer (three-renderer (get-element-by-id "app") 640 480))

(three-loop!
 (lambda ()
   (signal-update! angle (lambda (a) (+ a 0.02)))
   (three-render! renderer world camera)))
```

- 标签：`scene`、`group`、`mesh`、`perspective-camera`、`ambient-light`、`directional-light`、`point-light`
- 几何规格（`geometry` 属性）：`(box w h d)`、`(sphere r ...)`、`(plane w h)`、`(cylinder ...)`、`(torus ...)`、`(cone ...)`，或一个裸 `js-ref`
- 材质规格（`material` 属性）：`(basic|standard|phong|lambert|normal (@ (k v) ...))`
- 变换属性：`(position x y z)`、`(rotation x y z)`、`(scale x y z)`、单轴 `position-y` / `rotation-x` / …，以及任何普通 JS 属性（`intensity`、`fov`、`visible`、…）

过程（`*three` 是一个 Three.js 对象——场景、相机、网格或渲染器——以 `*jsObject` 持有）：

```
syntax: (s3d template)

template -> *three
```
把一个场景模板展开成 Three.js 对象图：静态结构一次性构建，`,`-unquote 的属性值成为就地更新的信号驱动孔洞。

```
procedure: (three-ref name)

func -> string -> *jsObject
```
查找 `globalThis.THREE[name]`——一个裸构造器或值。

```
procedure: (three-renderer parent width height)

func -> *domElement -> int -> int -> *three
```
创建一个给定尺寸的 WebGL 渲染器，挂载到 `parent` 下。

```
procedure: (three-render! renderer scene camera)

func -> *three -> *three -> *three -> void
```
通过 `camera` 渲染 `scene` 的一帧。

```
procedure: (three-loop! thunk)

func -> procedure -> void
```
每个动画帧调用一次 `thunk`（驱动渲染循环）。

构造属性（`geometry` / `material`、相机的 `fov`、光源的 `intensity`）是静态的；把响应式孔洞放到其他属性上。使用 `globalThis.THREE`，所以页面需单独加载 Three.js。渲染保持在 GPU 上；只有变化的属性穿过桥。

### `(web gl)`：经命令缓冲的裸 WebGL

要在没有 Three.js 的情况下完全掌控，`(web gl)` 通过一个*命令缓冲*来说 WebGL：Scheme 把一帧的 GL 命令编码为共享线性内存中的字（暂存内存原语 `%mem-*`），一次桥调用重放它们全部。顶点数据从同一内存零拷贝上传。资源——程序、缓冲、uniform 位置——是 JS 对象，因此存在一张初始化时建好一次的槽表里；命令引用槽号。

```scheme
(import (web gl) (web glsl))

(gl-attach! (get-element-by-id "c"))
(gl-program! 0 vertex-shader fragment-shader)   ; slot 0
(gl-buffer! 1)                                   ; slot 1
(cmd-region! 0)

(define (frame!)
  (cmd-begin!)
  (cmd-viewport! 0 0 800 600)
  (cmd-clear! 0.07 0.08 0.12 1.0)
  (cmd-use-program! 0)
  (cmd-bind-buffer! 1)
  (cmd-buffer-data! POS (* 8 N))                 ; zero-copy from staging memory
  (cmd-vertex-attrib! 0 2 0 0)
  (cmd-draw-arrays! GL-POINTS 0 N)
  (cmd-flush!))                                   ; ONE bridge call per frame
```

JS 重放器作为字符串内嵌在库里（用 `js-eval` 注入一次），所以没有需要随附的宿主侧文件。见 `examples/gl-particles.html`——一万个粒子，每帧一次桥调用。

#### 初始化（一次）

资源是持在槽表里的真实 JS 对象；你创建它们一次，之后按槽号引用。

```
procedure: (gl-attach! canvas)

func -> *domElement -> *jsObject
```
注入重放器（经 `js-eval`），在 `canvas` 上创建一个 `webgl` 上下文，并返回重放器句柄。副作用：安装 `globalThis.__goeteia_gl` 并绑定模块的暂存内存。

```
procedure: (gl-program! slot vs fs)

func -> int -> string -> string -> void
```
编译顶点着色器源 `vs` 与片段着色器源 `fs`，链接成一个程序，存入 `slot`。副作用：若某着色器编译失败或程序链接失败，（从 JS）抛出。

```
procedure: (gl-buffer! slot)

func -> int -> void
```
创建一个 `ARRAY_BUFFER` 并存入 `slot`。

```
procedure: (gl-uniform! slot pslot name)

func -> int -> int -> string -> void
```
在 `pslot` 处的程序中查找 uniform `name`，把它的位置存入 `slot`。

#### 每帧命令

每个 `cmd-*` 在当前写指针处把一条字对齐的命令编码进暂存内存；在 `cmd-flush!` 之前不碰 WebGL。

```
procedure: (cmd-region! base)

func -> int -> void
```
设置命令流写入所在的暂存内存字节偏移。

```
procedure: (cmd-begin!)

func -> void
```
把写指针重置到区域基址——开始一新帧。

```
procedure: (cmd-clear! r g b a)

func -> number -> number -> number -> number -> void
```
编码 `clearColor(r,g,b,a)` 后跟一次颜色+深度 `clear`。

```
procedure: (cmd-use-program! slot)

func -> int -> void
```
编码对 `slot` 中程序的 `useProgram`。

```
procedure: (cmd-bind-buffer! slot)

func -> int -> void
```
编码对 `slot` 中缓冲的 `bindBuffer(ARRAY_BUFFER, …)`。

```
procedure: (cmd-buffer-data! offset bytes)

func -> int -> int -> void
```
编码 `bufferData`，从暂存内存字节 `offset` 处上传 `bytes` 字节——零拷贝，因为数据已在该内存中。

```
procedure: (cmd-vertex-attrib! loc size stride offset)

func -> int -> int -> int -> int -> void
```
编码 `enableVertexAttribArray(loc)` + `vertexAttribPointer(loc, size, FLOAT, false, stride, offset)`。

```
procedure: (cmd-uniform1f! slot x)

func -> int -> number -> void
```
编码 `uniform1f`，把 `x` 写到 `slot` 中的 uniform 位置。

```
procedure: (cmd-uniform4f! slot x y z w)

func -> int -> number -> number -> number -> number -> void
```
编码 `uniform4f`，把 `(x,y,z,w)` 写到 `slot` 中的 uniform 位置。

```
procedure: (cmd-draw-arrays! mode first count)

func -> int -> int -> int -> void
```
编码 `drawArrays(mode, first, count)`；`mode` 是一个 `GL-*` 常量。

```
procedure: (cmd-viewport! x y w h)

func -> int -> int -> int -> int -> void
```
编码 `viewport(x, y, w, h)`。

```
procedure: (cmd-flush!)

func -> void
```
唯一的桥调用：重放自 `cmd-begin!` 以来编码的每条命令，一次性为整帧发出真实的 `gl.*` 调用。

#### 描画模式常量

`cmd-draw-arrays!` 的 `mode` 参数用的整数枚举：`GL-POINTS`（0）、`GL-LINES`（1）、`GL-TRIANGLES`（4）、`GL-TRIANGLE-STRIP`（5）。

### `(web glsl)`：着色器即 S-表达式

`glsl->string` 把一个形式列表渲染成 GLSL 源码——着色器的 `(web css)`。着色器是列表，因此可用 `append` 组合、用函数抽象。

```
procedure: (glsl->string forms)

func -> list -> string
```
把一个 GLSL 形式列表渲染成 GLSL 源码字符串。

```scheme
(glsl->string
 '((attribute vec2 p)
   (define (main) void
     (set! gl_Position (vec4 p (fl 0) (fl 1)))
     (set! gl_PointSize (fl 2)))))
=> "attribute vec2 p; void main() { gl_Position = vec4(p, 0.0, 1.0); gl_PointSize = 2.0; } "
```

顶层形式：`attribute`/`uniform`/`varying`、`precision`，以及用于函数的 `define`。语句：`local`、`set!`、`return`、`if`/`if-else`、`discard`。表达式：`+ - * /` 中缀，比较 `< > <= >= ==`，其余皆为调用；符号原样通过，所以像 `p.x` 这样的 swizzle 直接可用。浮点字面量用「整数加百分之几」的约定——`(fl 2)` → `2.0`、`(fl 0 50)` → `0.5`、`(fl 1 25)` → `1.25`——所以没有 Scheme 浮点（也没有打印噪声）进入源码。

## 网络

当线的两端都说 Scheme 时，没有编解码器：一端 `write`，另一端 `read`。面向异构后端则有一个安全的 JSON 编解码器。二者都跑在 `(web fetch)` 之上，后者把 HTTP 变成直接风格的调用。

### `(web fetch)`：经 JSPI 的直接风格 HTTP

`(web fetch)` 用 Wasm JSPI（JavaScript Promise Integration）让 HTTP 读起来像阻塞调用：`js-await` 把整个 wasm 栈挂起在一个 promise 上，并以其值恢复。没有回调，没有 async 染色；挂起期间页面保持响应。

```scheme
(import (web fetch))

(let* ((page  (http-get "/manual.md"))
       (resp  (fetch "/api" '((method . "POST") (body . "hello"))))
       (body  (response-text resp)))
  (list (response-status resp) body))
```

`*response` 是 JS 的 `Response` 对象；`opts` 是一个 alist，如 `((method . "POST") (body . "...") (headers . (("Content-Type" . "text/plain"))))`。

```
procedure: (fetch url [opts])

func -> string -> alist -> *response
```
发起一个 HTTP 请求并返回响应。挂起 wasm 栈（JSPI）直到响应头到达。

```
procedure: (http-get url)

func -> string -> string
```
GET `url` 并以字符串返回响应体。

```
procedure: (http-post url body [content-type])

func -> string -> string -> string -> string
```
把 `body` POST 到 `url`（默认内容类型 `text/plain`），并以字符串返回响应体。

```
procedure: (response-status r)

func -> *response -> int
```
HTTP 状态码，如 `200`。

```
procedure: (response-ok? r)

func -> *response -> boolean
```
状态是否在 200–299 范围内。

```
procedure: (response-text r)

func -> *response -> string
```
以字符串读取完整响应体。挂起直到响应体到达。

```
procedure: (response-header r name)

func -> *response -> string -> string
```
按名读取一个响应头。

```
procedure: (fetch-direct?)

func -> boolean
```
特性探测 JSPI：可用直接风格挂起时为 `#t`。

JSPI 需要支持它的引擎（Chrome 稳定版；Node 带 `--experimental-wasm-jspi`）。没有它时底层的 await 导入是恒等——用 `(fetch-direct?)` 探测并回退到下面的回调式 `rpc!`。`js-await` 只在主栈上合法，不能在从 JS 重入的 `$jscb` 回调内使用。

### `(web rpc)`：面向 Scheme 后端的 S-表达式 RPC

对端是 [Igropyr](https://github.com/guenchi/Igropyr)，一个 Scheme 应用服务器。两端都说 Scheme，所以请求与回复都是 s-表达式——精确整数与有理数完好穿过线，中间没有 JSON。下文的 `datum` 是任何线路安全的 s-表达式（列表、符号、字符串、精确整数与有理数、布尔）。

```
procedure: (rpc url datum)

func -> string -> datum -> datum
```
把 `datum` 发到 `url` 并返回回复 datum。直接风格——经 JSPI 挂起直到回复到达。

```
procedure: (rpc-get url)

func -> string -> datum
```
获取一个作为 `application/sexpr` 提供的资源，并作为 datum 返回。

```
procedure: (rpc! url datum on-reply [on-error])

func -> string -> datum -> procedure -> procedure -> void
```
无需 JSPI 的回调式 RPC：发送 `datum`，然后调用 `(on-reply reply)`，或失败时 `(on-error e)`。

```
procedure: (rpc-serialize datum)

func -> datum -> string
```
把一个 datum 序列化为线路文本（`write`，限制在 Igropyr 接受的安全白名单内）。

```
procedure: (rpc-parse text)

func -> string -> datum
```
把线路文本解析回一个 datum（`read`，同一安全白名单）。

```scheme
(import (web rpc))

;; direct style (needs JSPI):
(rpc "/rpc" '(add 1 2 1/2))          ; => (ok 7/2)   -- the ratio survives
(rpc "/rpc" '(get-user 42))          ; => (ok (user (id . 42) (name . "ada")))

;; REST-style resource served as application/sexpr:
(rpc-get "/users/42")                ; => (user (id . 42) (name . "ada"))

;; callback style (works without JSPI):
(rpc! "/rpc" '(get-user 42)
  (lambda (reply) (render! reply))
  (lambda (e) (show-error! e)))       ; optional error thunk
```

Igropyr 侧是对称的——一个标签分派端点，其处理器返回回复 datum，包成 `(ok ...)` / `(error ...)`：

```scheme
;; server (Igropyr): (igropyr express) + (igropyr sexpr)
(define users '((42 . "ada") (7 . "alan")))

(app-rpc app "/rpc"
  `((add      . ,(lambda (args) (apply + args)))
    (get-user . ,(lambda (args)
                   (let ((u (assv (car args) users)))
                     (if u
                         (list 'user (cons 'id (car u)) (cons 'name (cdr u)))
                         'not-found))))))
```

`rpc-serialize` / `rpc-parse` 直接暴露线路编解码（它们是 `write` / `read`，限制在 Igropyr 解析器接受的安全白名单内：列表、符号、字符串、精确整数与有理数、布尔）。

对于推送流，有两个轻量伴生库，对应服务器上 Igropyr 的 `ws-send-sexpr!` / `sse-send-sexpr!`——每条消息就是一个 datum。`*ws` 是一个 WebSocket 句柄，`*sse` 是一个 EventSource 句柄。

```
procedure: (ws-connect! url on-datum [...])

func -> string -> procedure -> *ws
```
打开一个到 `url` 的 WebSocket；`(on-datum d)` 每条消息触发一次，带解码后的 datum。返回套接字句柄。

```
procedure: (ws-send! w datum)

func -> *ws -> datum -> void
```
经套接字 `w` 发送一个 datum。

```
procedure: (ws-close! w)

func -> *ws -> void
```
关闭套接字。

```
procedure: (ws-open? w)

func -> *ws -> boolean
```
套接字是否打开。

```
procedure: (sse-connect! url on-datum [...])

func -> string -> procedure -> *sse
```
打开一个 Server-Sent-Events 流；`(on-datum d)` 每个事件触发一次。返回流句柄。

```
procedure: (sse-close! es)

func -> *sse -> void
```
关闭 SSE 流。

```scheme
(import (web ws) (web sse))

(define w (ws-connect! "wss://host/chat/lobby"
            (lambda (datum) (render! datum))))   ; one datum per message
(ws-send! w '(say "hello everyone"))

(sse-connect! "/progress"
  (lambda (datum)                                ; (progress (percent . 42))
    (update-bar! (cdr (assq 'percent (cdr datum))))))
```

### `(web json)`：面向异构后端的安全 JSON

当对端不是 Scheme 时，`(web json)` 是一个安全的递归下降编解码器（不是 reader——无 `#`-语法、无 eval），与 Igropyr 在服务器上用的是同一个，移植自其 `json.sc`。

```
procedure: (string->json s)

func -> string -> any
```
解析一个 JSON 字符串：对象 → alist（字符串键），数组 → 向量，字符串 → 字符串，数字 → 数字，`true`/`false` → `#t`/`#f`，`null` → `'null`。

```scheme
(string->json "{\"user\":{\"id\":42,\"tags\":[\"a\",\"b\"]}}")
=> (("user" ("id" . 42) ("tags" . #("a" "b"))))
```

```
procedure: (json->string x)

func -> any -> string
```
把一个 Scheme 值（同一数据模型）序列化为 JSON 字符串。

```scheme
(json->string '(("ok" . #t) ("n" . 42)))
=> "{\"ok\":true,\"n\":42}"
```

```
procedure: (json-ref x key ...)

func -> any -> any -> ... -> any
```
按字符串/符号键（对象）或整数索引（数组）沿路径下行，任一步缺失时返回 `#f`。

```scheme
(json-ref (string->json "{\"user\":{\"id\":42}}") "user" "id")
=> 42
```

数据模型：对象 → 字符串键 alist，数组 → 向量，字符串 → 字符串，数字 → 数字，`true`/`false` → `#t`/`#f`，`null` → `'null`。`\uXXXX` 与代理对解码为 UTF-8 字节（Goeteia 字符串是 UTF-8 字节串）；超大整数保持精确大整数。`(json-ref x k ...)` 按字符串/符号键（对象）或整数索引（数组）沿路径下行，缺失时返回 `#f`。与 `(web fetch)` 结合：

```scheme
(let ((data (string->json (http-get "/api/user/42"))))
  (json-ref data "name"))
```

## 在浏览器中运行

`rt/web.mjs` 加载器实例化一个编译好的模块并运行它：

```javascript
import { loadGoeteia } from './rt/web.mjs';

loadGoeteia('app.wasm');
```

模块运行在浏览器主线程，具有完整的 DOM 访问。JS 桥（`rt/jsbridge.mjs`）处理所有编解码。

### 最小 HTML

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>My App</title>
</head>
<body>
  <div id="app"></div>
  <script type="module">
    import { loadGoeteia } from './rt/web.mjs';
    loadGoeteia('app.wasm');
  </script>
</body>
</html>
```

之后 Scheme 程序即可经 `(web dom)` 和 `(web sx)` 操作 DOM。

### 示例

见 `examples/counter.html` 与 `examples/counter.ss`——一个完整的计数器应用。也见 `examples/react-embed.html`，将 Goeteia 小部件嵌入 React 应用。

## 测试

运行测试套件：

```bash
./run-tests.sh
```

### 测试协议

每个测试文件在首行声明其期望输出：

```scheme
;; expect: 42
(+ 21 21)
```

测试运行器：
1. 用 Chez 宿主与自举编译器（若 `goeteia.wasm` 存在）分别编译该测试
2. 各自运行，捕获输出
3. 校验结果是否匹配期望

### 输入文件

对于需要读取输入的测试，在测试旁创建一个 `.input` 文件：

```
test/readnums.ss       <- test file
test/readnums.input    <- input file (byte stream)
```

`run-tests.sh` 把该输入文件作为 stdin 传给 `rt/run.mjs`。

### 无头 DOM 测试

`(web sx)` 与 `(web reactive)` 库针对一个用 JavaScript 定义的模拟 DOM 运行：

```scheme
;; Set up a mock DOM
(js-eval "globalThis.document = {
  createElement: ...
  ...
}")

;; Now run Goeteia DOM code against the mock
(define el (create-element "div"))
(append-child! (body) el)
```

完整示例见 `test/sx.ss` 与 `test/todomvc.ss`。若你调用了未实现的方法，模拟 DOM 会打印错误，便于开发时捕获缺失的 API。

## 从 JavaScript/TypeScript 移植

本项目附带一个定义在 `.claude/agents/web-porter.md` 的子代理，它把单个 UI 文件从 JavaScript/TypeScript 移植到 Goeteia Scheme。它会：

1. **翻译**一个 JS/TS 文件为地道的 Goeteia（React hooks → 信号，JSX → `sx` 模板，DOM API → `(web dom)`）
2. **验证**行为等价性，用差分测试：以相同的输入/事件驱动原件与移植件并比对输出，反复修正移植件直到一致
3. **报告**任何无法做到等价的地方，作为带标记的 TODO

范围是 UI 子集加行为良好的逻辑；它会标记病态的 JS 语义角落（深层 `this`/原型分派、`==` 强制转换）而非模拟它们。它是一个同结果移植器，而非通用的 JS-in-Scheme 运行时。

它像任何 Claude Code 子代理那样运行——在一次会话内，通过请求 Claude 对某文件使用 `web-porter` 代理——而不是作为独立的 shell 命令。

## 当前限制与计划中的工作

- **`call/cc` 仅转义**：续延能跳出但不能重入。这是 Wasm 的限制；可重入需要不同的实现。
- **异步需要 JSPI**：`(web fetch)` 与直接风格的 `(web rpc)` 经 Wasm JSPI 挂起，所以需要有它的引擎（Chrome 稳定版；Node 带 `--experimental-wasm-jspi`）。其他环境用 `(fetch-direct?)` 探测并改用回调式 `rpc!`。
- **无 datum 标签**：reader 不支持 `#0=` / `#0#` 循环结构记法。

这些是设计取舍，不是缺陷；若你有需要它们的用例，请提 issue。
