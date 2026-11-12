# 1. A rewrite is exact or refused

## Context

A reader trusts a `def` it finds. A def that looks like the original but returns another object, takes other arguments, or has another visibility is worse than the `define_method` it replaced.

RuboCop reads the source and never runs it. So the cops can only rewrite what the source itself fixes: a literal name, or a loop over a literal list in the same class body.

## Decision

The autocorrection writes defs only when Ruby would define the same methods: the same names, parameters, bodies, and visibility. Otherwise the offense says why, and nothing changes.

- The statement is called with no receiver, or with `self`, directly in a class or module body, or in an `each` over a literal Array or Hash there. A block of `class_eval`, `module_eval`, `class_exec`, `module_exec`, `Class.new`, `Module.new`, `Struct.new`, or `Data.define` counts as a body: measured on Ruby 3.4, a def and a define_method there define on the same module, with the same default visibility (a fresh public scope in a `class_eval` block, even after `private` outside it) and the same constant lookup. The locals such a block can see, up to the nearest def, class, or module, count as shared. A block of any other method (`included do`, `class_methods do`) is refused, because the library that runs it decides where it defines. A constant counts as a literal list when the same body sets it once, before the loop, to a literal Array or Hash; `LIST.keys` and `LIST.values` of such a Hash count too. An unfrozen list counts only when nothing between its assignment and the loop can change it: the statements there are defs, constants set to literals, classes and modules made of those, and `attr_*`, `alias_method`, visibility, and `private_constant` calls with literal names, and the loop itself does not name the list. Reading a constant can run code through autoload, and a parent class through `inherited`, so a class there may only have a core parent. A bare constant set elsewhere, or a constant of another module, is refused: it can come from an outer module or an ancestor, which another file can set or reopen.
- The loop may also make other calls, such as `alias_method`, `attr_reader`, `private name`, or `ruby2_keywords`. Each is copied once per run, in its place among the defs, with the loop variables written as their literals. A name argument of `alias_method`, `attr_*`, the visibility methods, `ruby2_keywords`, `undef_method`, or `remove_method` that comes from the loop variables alone is written as a Symbol, because those methods read a String as its Symbol; for the ones that answer with their argument, only when nothing reads the answer. The loop is refused when it assigns a local (each run of a block starts it afresh; a class body keeps it), calls a bare visibility method, uses `next`, `break`, `redo`, or `return` at its own level, holds a def or a class, or calls `binding` and the like.
- A loop value is written as a literal only when the literal is the same object on every read: a Symbol, an Integer of fixnum size, nil, true, false, or a String under `# frozen_string_literal: true`.
- A block is refused when it shares a local with the code around it, uses numbered parameters or `it`, `yield`, `binding`, `local_variables`, `block_given?`, `eval`, `super` with no arguments, `break` or `redo` outside a loop, or `defined?` of the loop variable, assigns a constant, or opens a class or module. A `next` that leaves the method becomes `return`.
- A string eval is refused after a bare `private`, `protected`, or `module_function`, because its defs are public there. It is refused when the string holds more than defs, or names the eval with `__LINE__`, `__FILE__`, `__dir__`, or `Module.nesting`.
- A string eval is refused when its code holds a string literal and its own `# frozen_string_literal:` setting differs from the file's: the file's comment does not reach eval'd code, so the literal would change from mutable to frozen.
- Code that moves is refused when it reads `__LINE__` or holds a string that spans lines.

The autocorrection is marked unsafe: it trusts that `define_method`, `class_eval`, and `Array#each` are Ruby's own.

## Consequences

- `test/hegel/rewrite_test.rb` checks the rule: for generated classes, the corrected class has the same methods, visibility, parameters, return values, and instance variables as the original.
- A refused offense keeps its reason, so an agent can write the defs by hand.
- Most metaprogramming in published gems sits inside a macro the code calls with arguments. RuboCop sees one file at a time, so those calls are reported with a reason and are not rewritten.
