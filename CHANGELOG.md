# Changelog

## [Unreleased]

First release. rubocop-dynamic_methods finds methods that Ruby metaprogramming defines and writes them as plain `def`s, so a search for `def name` finds them.

- `DynamicMethods/DefineMethod` reports `define_method` and `define_singleton_method`, and autocorrects them to `def name` and `def self.name`.
- `DynamicMethods/StringEval` reports `class_eval`, `module_eval`, `instance_eval`, and `eval` with a string, and autocorrects a `class_eval` or `module_eval` string that holds only defs to those defs.
- `DynamicMethods/MethodMissing` reports `def method_missing`.
- The autocorrection runs only when the defs are the same methods: a call directly in a class or module body, or in an `each` over a literal Array, a literal Hash, or a frozen literal constant set once before the loop. Otherwise the offense ends with `Not autocorrected:` and the reason.
- The autocorrection is unsafe: it trusts that `define_method`, `class_eval`, and `Array#each` are Ruby's own.
- A lint_roller plugin, for RuboCop 1.72 or later, on Ruby 3.2 or later.
