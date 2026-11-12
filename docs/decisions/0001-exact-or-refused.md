# 1. A rewrite is exact or refused

## Context

A reader trusts a `def` it finds. A def that looks like the original but returns another object, takes other arguments, or has another visibility is worse than the `define_method` it replaced.

RuboCop reads the source and never runs it. So the cops can only rewrite what the source itself fixes: a literal name, or a loop over a literal list in the same class body.

## Decision

The autocorrection writes defs only when Ruby would define the same methods: the same names, parameters, bodies, and visibility. Otherwise the offense says why, and nothing changes.

- The statement is called with no receiver, or with `self`, directly in a class or module body, or in an `each` over a literal Array or Hash there. A constant counts as a literal list when the same body sets it once, before the loop, to a frozen literal.
- A loop value is written as a literal only when the literal is the same object on every read: a Symbol, an Integer of fixnum size, nil, true, false, or a String under `# frozen_string_literal: true`.
- A block is refused when it shares a local with the code around it, uses numbered parameters or `it`, `yield`, `binding`, `local_variables`, `block_given?`, `eval`, `super` with no arguments, `break` or `redo` outside a loop, or `defined?` of the loop variable, assigns a constant, or opens a class or module. A `next` that leaves the method becomes `return`.
- A string eval is refused after a bare `private`, `protected`, or `module_function`, because its defs are public there. It is refused when the string holds more than defs, or names the eval with `__LINE__`, `__FILE__`, `__dir__`, or `Module.nesting`.
- Code that moves is refused when it reads `__LINE__` or holds a string that spans lines.

The autocorrection is marked unsafe: it trusts that `define_method`, `class_eval`, and `Array#each` are Ruby's own.

## Consequences

- `test/hegel/rewrite_test.rb` checks the rule: for generated classes, the corrected class has the same methods, visibility, parameters, return values, and instance variables as the original.
- A refused offense keeps its reason, so an agent can write the defs by hand.
- Most metaprogramming in published gems sits inside a macro the code calls with arguments. RuboCop sees one file at a time, so those calls are reported with a reason and are not rewritten.
