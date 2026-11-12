# Changelog

## [Unreleased]

First release. rubocop-dynamic_methods finds methods that Ruby metaprogramming defines and writes them as plain `def`s, so a search for `def name` finds them.

- `DynamicMethods/DefineMethod` reports `define_method` and `define_singleton_method`, and autocorrects them to `def name` and `def self.name`.
- `DynamicMethods/StringEval` reports `class_eval`, `module_eval`, `instance_eval`, and `eval` with a string, and autocorrects a `class_eval` or `module_eval` string that holds only defs to those defs.
- `DynamicMethods/MethodMissing` reports `def method_missing`.
- The autocorrection runs only when the defs are the same methods: a call directly in a class or module body, or in an `each` over a literal Array, a literal Hash, a constant set once to one of those before the loop, or the `keys` or `values` of such a Hash. An unfrozen constant counts only when no code between its assignment and the loop can change it. Otherwise the offense ends with `Not autocorrected:` and the reason.
- The autocorrection is unsafe: it trusts that `define_method`, `class_eval`, and `Array#each` are Ruby's own.
- A block of `class_eval`, `module_eval`, `class_exec`, `module_exec`, `Class.new`, `Module.new`, `Struct.new`, or `Data.define` counts as a class body. A block of any other method, such as `included do`, is refused with that reason.
- A string eval whose code holds a string literal is not autocorrected when the file's `# frozen_string_literal:` setting differs from the code's own, because the literal would change between mutable and frozen.
- A loop that also calls `alias_method`, `attr_*`, `private name`, `ruby2_keywords`, or other methods with the loop variable is unrolled: each call is copied once per value, and a name built from the loop variable becomes a Symbol. A loop that assigns a local, calls a bare `private`, or uses `next`, `break`, or `return` is refused with that reason.
- A class method that defines methods (`def self.record(name)` with `define_method(name)` in it) is written out at each call in the same class body that gives it literal arguments, so `record :and_return` becomes `def and_return`. The class method stays. A define_method inside any other method now says that only the method's callers know which names it defines.
- A string eval that is not rewritten says what it evaluates: the defs a literal string holds, the def names an interpolated string makes (such as `#{name}?`), or the code it comes from. `instance_eval(&block)` is not reported, since it runs a block.
- A `define_method` whose body is not a literal block says what the body is: a copy of a named method such as `Kernel#send`, a block passed in from the caller, `&:name`, or a lambda.
- `bin/check-corpus ROOT` checks the autocorrection on a folder of unpacked gems without loading them.
- A lint_roller plugin, for RuboCop 1.72 or later, on Ruby 3.2 or later.
