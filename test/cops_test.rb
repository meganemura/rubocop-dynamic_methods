# frozen_string_literal: true

require "test_helper"

class CopsTest < Minitest::Test
  def messages(source)
    CopRunner.offenses(source).offenses.map { "#{_1.line}: #{_1.message}" }
  end

  def test_a_loop_over_a_frozen_constant_becomes_one_def_per_value
    source = <<~'RUBY'
      # frozen_string_literal: true

      class Order
        STATES = %i[draft paid].freeze

        STATES.each do |state|
          # A predicate per state.
          define_method(:"#{state}?") { @state == state }
        end
      end
    RUBY
    assert_equal ["8: Define `draft?`, `paid?` with `def`, so a search for `def name` finds them."], messages(source)
    assert_equal <<~'RUBY', CopRunner.run(source).source
      # frozen_string_literal: true

      class Order
        STATES = %i[draft paid].freeze

        # A predicate per state.
        def draft?
          @state == :draft
        end

        def paid?
          @state == :paid
        end
      end
    RUBY
  end

  def test_a_block_keeps_its_parameters_comments_and_lines
    source = <<~'RUBY'
      class Cart
        define_method(:total) do |tax = 0.1, *rest, discount: 0, &block| # with tax
          next 0 if @items.empty?

          [1].each { next }
          @items.sum * (1 + tax) - discount
        end
      end
    RUBY
    assert_equal <<~'RUBY', CopRunner.run(source).source
      class Cart
        def total(tax = 0.1, *rest, discount: 0, &block) # with tax
          return 0 if @items.empty?

          [1].each { next }
          @items.sum * (1 + tax) - discount
        end
      end
    RUBY
  end

  def test_a_string_eval_in_a_loop_becomes_its_defs
    source = <<~'RUBY'
      class Box
        { width: 0, height: 1 }.each do |name, index|
          class_eval <<~CODE, __FILE__, __LINE__ + 1
            # Reads #{name}.
            def #{name}
              @size[#{index}]
            end
          CODE
        end
      end
    RUBY
    assert_equal ["3: Define `width`, `height` with `def`, so a search for `def name` finds them."], messages(source)
    assert_equal <<~'RUBY', CopRunner.run(source).source
      class Box
        # Reads width.
        def width
          @size[0]
        end

        # Reads height.
        def height
          @size[1]
        end
      end
    RUBY
  end

  def test_a_block_that_opens_a_class_is_a_class_body
    source = <<~'RUBY'
      Point = Struct.new(:x, :y) do
        %i[x y].each do |axis|
          define_method(:"#{axis}?") { !self[axis].nil? }
        end
      end

      Point.class_eval do
        define_method(:origin?) { x.zero? && y.zero? }
      end
    RUBY
    assert_equal <<~'RUBY', CopRunner.run(source).source
      Point = Struct.new(:x, :y) do
        def x?
          !self[:x].nil?
        end

        def y?
          !self[:y].nil?
        end
      end

      Point.class_eval do
        def origin?
          x.zero? && y.zero?
        end
      end
    RUBY
  end

  def test_a_singleton_method_becomes_a_def_on_self
    source = "class Config\n  define_singleton_method(:load) { |path| new(path) }\nend\n"
    assert_equal "class Config\n  def self.load(path)\n    new(path)\n  end\nend\n", CopRunner.run(source).source
  end

  def test_a_loop_that_also_calls_alias_method_and_private_is_unrolled
    source = <<~'RUBY'
      class Matchers
        %i[equal match].each do |kind|
          define_method("assert_#{kind}") { |x| [kind, x] }
          alias_method "refute_#{kind}", "assert_#{kind}"
          private kind
        end
      end
    RUBY
    assert_equal <<~'RUBY', CopRunner.run(source).source
      class Matchers
        def assert_equal(x)
          [:equal, x]
        end

        alias_method :refute_equal, :assert_equal
        private :equal

        def assert_match(x)
          [:match, x]
        end

        alias_method :refute_match, :assert_match
        private :match
      end
    RUBY
  end

  REFUSALS = {
    "class A\n  x = 1\n  define_method(:a) { x }\nend\n" =>
      "the block shares the local `x` with the code around it",
    "class A\n  define_method(:a, instance_method(:b))\nend\n" =>
      "the body is `instance_method(:b)`, not a block",
    "class A\n  klass.define_method(:a) { 1 }\nend\n" =>
      "it defines the method on `klass`",
    "class A\n  define_method(:a) { _1 }\nend\n" =>
      "the block uses numbered parameters",
    "class A\n  define_method(:a) { super }\nend\n" =>
      "the block calls `super` with no arguments, which raises in a block given to define_method",
    "class A\n  define_method(:a) { binding }\nend\n" =>
      "the block calls `binding`, which sees the locals around the block",
    "class A\n  def self.make(name)\n    define_method(name) { 1 }\n  end\nend\n" =>
      "it is not called directly in a class or module body, or a block that opens one",
    "module Ext\n  included do\n    define_method(:x) { 1 }\n  end\nend\n" =>
      "it is inside `included do`, and only the code that runs the block knows which module it defines on",
    "def self.build(name)\n  Class.new do\n    define_method(:label) { name }\n  end\nend\n" =>
      "the block shares the local `name` with the code around it",
    "class A\n  NAMES.each { |n| define_method(n) { 1 } }\nend\n" =>
      "the loop runs over `NAMES`, which this class body does not set once before the loop",
    "class A\n  %w[a b].each { |n| define_method(:x) { n } }\nend\n" =>
      "the block reads the string \"a\", which is one shared object only under `# frozen_string_literal: true`",
    "class A\n  [1.5].each { |n| define_method(:x) { n } }\nend\n" =>
      "the list holds `1.5`, which is not a symbol, string, small integer, nil, true, or false",
    "class A\n  %i[a].each do |n|\n    x = n\n    define_method(n) { 1 }\n  end\nend\n" =>
      "the loop assigns the local `x`, which each run of the loop starts afresh",
    "class A\n  %i[a].each do |n|\n    private\n    define_method(n) { 1 }\n  end\nend\n" =>
      "the loop calls a bare `private`, which a block and a class body scope differently",
    "class A\n  %i[a].each do |n|\n    define_method(n) { 1 }\n    next if n == :a\n  end\nend\n" =>
      "the loop uses `next`",
    "class A\n  define_method(:\"two words\") { 1 }\nend\n" =>
      "`two words` cannot be written after `def`",
    "class A\n  private\n\n  class_eval \"def a; end\"\nend\n" =>
      "it follows a bare `private`, and a def from a string eval stays public",
    "class A\n  class_eval \"attr_reader :a\"\nend\n" =>
      "the string does more than define methods",
    "class A\n  class_eval \"def a = __LINE__\"\nend\n" =>
      "the string reads `__LINE__`, `__FILE__`, `__dir__`, or `Module.nesting`, which name the eval",
    "# frozen_string_literal: true\n\nclass A\n  class_eval \"def a = 'x'\"\nend\n" =>
      "the string's code holds the string literal 'x', which `# frozen_string_literal:` would treat differently in this file",
    "class A\n  class_eval code\nend\n" =>
      "`class_eval` is not given a string literal",
    "class A\n  instance_eval \"def a; end\"\nend\n" =>
      "`instance_eval` runs the string on another receiver",
    "eval \"def a; end\"\n" =>
      "`eval` runs the string on another receiver"
  }.freeze

  def test_a_refused_rewrite_names_its_reason_and_changes_nothing
    REFUSALS.each do |source, reason|
      offense = CopRunner.offenses(source).offenses.reject { _1.cop_name == "DynamicMethods/MethodMissing" }.first
      assert_equal "Define this method with `def`, so a search for its name finds it. Not autocorrected: #{reason}.", offense&.message, source
      assert_equal source, CopRunner.run(source).source
    end
  end

  def test_method_missing_is_reported
    assert_equal ["2: Define the methods `method_missing` answers with `def`, so a search for their names finds them."],
                 messages("class A\n  def method_missing(name, *) = super\nend\n")
  end

  def test_a_class_eval_with_a_block_and_a_plain_def_are_not_offenses
    assert_empty messages("class A\n  class_eval do\n    def a; end\n  end\n\n  def b; end\nend\n")
  end
end
