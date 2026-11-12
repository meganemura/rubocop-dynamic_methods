# rubocop-dynamic_methods

RuboCop cops for methods that Ruby metaprogramming defines.
A reader, a coding agent first and a person second, searches for `def paid?` and finds nothing when `paid?` comes from `define_method` or a string eval.
These cops find those methods and write them as plain `def`s.

```ruby
# frozen_string_literal: true

class Order
  STATES = %i[draft paid].freeze

  STATES.each do |state|
    define_method(:"#{state}?") { @state == state }
  end
end
```

```sh
$ rubocop -A --only DynamicMethods order.rb
order.rb:7:5: C: [Corrected] DynamicMethods/DefineMethod: Define draft?, paid? with def, so a search for def name finds them.
```

```ruby
# frozen_string_literal: true

class Order
  STATES = %i[draft paid].freeze

  def draft?
    @state == :draft
  end

  def paid?
    @state == :paid
  end
end
```

## Quick start

```ruby
# Gemfile
gem "rubocop-dynamic_methods", require: false
```

```yaml
# .rubocop.yml
plugins:
  - rubocop-dynamic_methods
```

The plugin needs RuboCop 1.72 or later and Ruby 3.2 or later.

## The cops

| Cop | Finds | Autocorrects |
| --- | --- | --- |
| `DynamicMethods/DefineMethod` | `define_method` and `define_singleton_method` | to `def name` and `def self.name` |
| `DynamicMethods/StringEval` | `class_eval`, `module_eval`, `instance_eval`, and `eval` with a string | to the defs the string holds |
| `DynamicMethods/MethodMissing` | `def method_missing` | no |
| `DynamicMethods/Delegation` (disabled by default) | `delegate`, `delegate_missing_to`, `def_delegator`, `def_delegators` | no |

`DynamicMethods/Delegation` only reports: delegation is common style, and a def is not the same method, because Forwardable reaches private methods and both take any arguments.
Turn it on with `Enabled: true` under `DynamicMethods/Delegation` in `.rubocop.yml`.

## Exact or not at all

The autocorrection writes defs only when Ruby would define the same methods: the same names, parameters, bodies, and visibility.
When it cannot be sure, the offense says why and the code stays as it is:

```ruby
class Feed
  ELEMENTS = %w[title link]
  include Parsing

  ELEMENTS.each do |name|
    class_eval <<~RUBY, __FILE__, __LINE__ + 1
      def #{name}; @values[:#{name}]; end
    RUBY
  end
end
```

```text
feed.rb:6:5: C: DynamicMethods/StringEval: `class_eval` evaluates a string that defines methods named `#{name}`; write them with `def`, so a search finds them. Not autocorrected: `ELEMENTS` is not frozen, and `include Parsing` runs between its assignment and the loop.
```

The reason is written for whoever writes the defs next, an agent or a person.

RuboCop reads the source and never runs it, so a rewrite is possible only when the source fixes every name:

- The call has no receiver, or `self`, and sits directly in a class or module body, or in an `each` over a literal Array or Hash there.
  A branch of an `if` or `unless` there counts too, and the def stays in the branch.
  A block of `class_eval`, `module_eval`, `class_exec`, `module_exec`, `Class.new`, `Module.new`, `Struct.new`, or `Data.define` counts as a class body: a def there defines on the same module, with the same visibility and constants.
  A block of any other method, such as `included do`, does not, because only the code that runs it knows where it defines.
  A constant counts as a literal list when the same body sets it once, before the loop, to a literal Array or Hash, and `LIST.keys` and `LIST.values` count too.
  If the list is not frozen, only defs, literal constants, and calls such as `attr_reader :a` may run between the assignment and the loop, so nothing can change the list.
  A constant of another module, such as `Base::NAMES`, is refused, because another file can change it.
- A class method that defines methods, such as `def self.delegate_to_metadata(key)`, is written out at each call in the same class body that gives it literal arguments: `delegate_to_metadata :file_path` becomes `def file_path`.
  The class method stays for other callers.
  A call after a bare `private` is refused, because a method that another method defines is public.
- The other calls in such a loop, such as `alias_method`, `attr_reader`, `private`, or `ruby2_keywords`, are copied once per value, after the def they follow.
  A name built from the loop variable becomes a Symbol, as in `alias_method :refute_text, :assert_text`.
  The loop is refused when it assigns a local, calls a bare `private`, or uses `next`, `break`, or `return`, because a block and a class body treat those differently.
- A loop value becomes a literal only when the literal is the same object on every read: a Symbol, a small Integer, nil, true, false, or a String under `# frozen_string_literal: true`.
- A block is refused when it shares a local with the code around it, or uses something a def treats differently: numbered parameters, `it`, `yield`, `binding`, `local_variables`, `block_given?`, `eval`, `super` with no arguments, `break` or `redo` outside a loop.
  A `next` that leaves the method becomes `return`.
- A string eval is refused after a bare `private`, `protected`, or `module_function`, because the defs it makes are public even there.
  It is also refused when the string holds more than defs, or holds a string literal that the file's `# frozen_string_literal:` comment would freeze or unfreeze: that comment does not reach code a string eval compiles.

The autocorrection is unsafe in RuboCop's sense: it trusts that `define_method`, `class_eval`, and `Array#each` are Ruby's own. Run it with `rubocop -A`.

[docs/decisions/0001-exact-or-refused.md](docs/decisions/0001-exact-or-refused.md) has the full rule.

## How the rewrite is checked

`test/hegel/rewrite_test.rb` generates classes with hegeltest, corrects them with the cops, loads the original and the corrected class, and compares what Ruby reports: the method names by visibility, the parameters, the return values, and the instance variables a call sets.

## License

MIT. See [LICENSE](LICENSE).

[Japanese](README.ja.md)
