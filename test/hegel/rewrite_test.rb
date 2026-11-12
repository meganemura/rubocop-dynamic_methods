# frozen_string_literal: true

require "test_helper"
require "hegel"
require "tmpdir"

# The autocorrection claims each def it writes is the method the original
# defined. These properties load the original and the corrected class side by
# side and compare what Ruby itself says about their methods.
class RewriteTest < Minitest::Test
  include Hegel::Syntax::Methods

  SETTINGS = { test_cases: 200, seed: 7, suppress_health_check: %i[too_slow filter_too_much] }.freeze

  # The text of a block that reads the loop variable v. "PARAMS" is its
  # parameter list.
  TEMPLATES = [
    ["", "v"], ["", "-v"], ["", "v.to_s"], ["", "\"<\#{v}>\""], ["", "{ v: }"], ["", "defined?(v)"],
    ["", "[v].map { |e| e }"], ["", "v.then { |x| [x, v] }"], ["", "case v\nin Integer then :int\nelse :other\nend"],
    ["", "v if v"], ["", "w = v\nw"], ["", "loop { break v }"], ["", "[1].each { next v }\nv"], ["", "->() { v }.call"],
    ["", "v rescue nil"], ["", "begin\n  v\nensure\n  @x = 1\nend"], ["", "v.frozen?"], ["a = v", "a"],
    ["a = v, b = [v]", "[a, b]"], ["*a", "[v, *a]"], ["k: v", "k"], ["", "!v"], ["", "v.class"], ["", "v.equal?(v)"],
    ["", "x = [v]\nx << v\nx"], ["", "v&.to_s"], ["", "%w[a b].map { v }"], ["", "v..v"], ["", "[v] * 2"],
    ["", "{ v => v }"], ["", "\"\#{v}\".frozen?"], ["", ":\"\#{v}\""], ["", "v; v"], ["", "v ? v : nil"],
    ["", "[v][0]"], ["", "v <=> v"], ["", "__method__"], ["", "next v if v\n:no"], ["", "@seen = v\nnil"],
    ["", "[v, seed]"], ["", "v ** 2"], ["", "binding.local_variable_get(:v)"], ["", "super()"], ["", "yield"], ["&b", "b&.call(v)"]
  ].freeze

  NAMES = %w[alpha beta gamma delta ok? save!].freeze

  @@classes = 0

  def values
    one_of(
      integers(min_value: -(2**64), max_value: 2**64),
      floats(allow_nan: false, allow_infinity: false),
      text(max_size: 4).map(&:to_sym),
      text(max_size: 4),
      sampled_from([nil, true, false])
    )
  end

  # The bodies a define_method can sit in: a class body, and the blocks Ruby
  # runs as one. `seed` is a local a block body can see and a def cannot.
  OPENERS = [
    "class KLASS",
    "class KLASS; end\nseed = 1\nKLASS.class_eval do",
    "seed = 1\nKLASS = Class.new do",
    "KLASS = Struct.new(:z) do"
  ].freeze

  def outcome(&call)
    result = call.call
    # frozen? too: a literal moved between files can change it.
    [:ok, result.class, result.inspect, result.frozen?, result.is_a?(Array) && result.map(&:frozen?)]
  rescue Exception => e # rubocop:disable Lint/RescueException
    [:raise, e.class]
  end

  # Writes the class to a file of its own, so its magic comment applies, and
  # loads it.
  def load_class(source, name, root)
    file = File.join(root, "#{name}.rb")
    File.write(file, source.gsub("KLASS", name))
    # The classes are generated; their warnings are noise.
    verbose, $VERBOSE = $VERBOSE, nil
    load file
    Object.const_get(name)
  ensure
    $VERBOSE = verbose
  end

  def compare(original, written)
    %i[public_instance_methods private_instance_methods protected_instance_methods].each do |list|
      assert_equal original.send(list, false).sort, written.send(list, false).sort, list
    end
    original.instance_methods(false).each do |name|
      assert_equal original.instance_method(name).parameters, written.instance_method(name).parameters, name
      a = original.allocate
      b = written.allocate
      assert_equal outcome { a.send(name) }, outcome { b.send(name) }, name
      assert_equal a.instance_variables.map { a.instance_variable_get(_1) }, b.instance_variables.map { b.instance_variable_get(_1) }
    end
  end

  def check(source)
    result = CopRunner.run(source)
    return :unchanged if result.source == source

    Dir.mktmpdir do |root|
      number = @@classes += 1
      compare(load_class(source, "Original#{number}", root), load_class(result.source, "Written#{number}", root))
    end
    left = CopRunner.offenses(result.source).offenses.reject { _1.cop_name == "DynamicMethods/MethodMissing" }
    assert_empty left.map(&:message)
    :corrected
  end

  def test_a_corrected_block_is_the_method_the_original_defined
    seen = Hash.new(0)
    Hegel.test(**SETTINGS) do |tc|
      opener = tc.draw(sampled_from(OPENERS))
      value = tc.draw(values)
      params, body = TEMPLATES[tc.draw(integers(min_value: 0, max_value: TEMPLATES.size - 1))]
      frozen = tc.draw(booleans)
      section = tc.draw(sampled_from(["", "private\n  ", "protected\n  "]))
      brace = tc.draw(booleans) && !body.include?("\n")
      block = if brace
                "{#{params.empty? ? "" : " |#{params}|"} #{body} }"
              else
                "do#{params.empty? ? "" : " |#{params}|"}\n      #{body.gsub("\n", "\n      ")}\n    end"
              end
      source = <<~RUBY
        # frozen_string_literal: #{frozen}

        #{opener}
          #{section}[#{value.inspect}].each do |v|
            define_method(:m) #{block}
          end
        end
      RUBY
      tc.note(source)
      seen[check(source)] += 1
    end
    assert_operator seen[:corrected], :>, 50, seen.inspect
  end

  def test_a_corrected_loop_defines_every_name_the_original_defined
    seen = Hash.new(0)
    Hegel.test(**SETTINGS) do |tc|
      opener = tc.draw(sampled_from(OPENERS))
      names = tc.draw(arrays(sampled_from(NAMES), min_size: 1, max_size: 3, unique: true))
      symbols = tc.draw(booleans)
      list = symbols ? "[#{names.map { _1.to_sym.inspect }.join(", ")}]" : names.inspect
      frozen = tc.draw(booleans)
      name = tc.draw(sampled_from(['name', ':"#{name}_q"', '"get_#{name}"', ':"#{name}"']))
      body = tc.draw(sampled_from(["[name, x]", "\"\#{name}:\#{x}\"", "name.to_s * x", "__method__", "name.equal?(name)"]))
      spell = tc.draw(sampled_from(%w[define_method define_singleton_method]))
      source = <<~RUBY
        # frozen_string_literal: #{frozen}

        #{opener}
          #{list}.each do |name|
            # One per name.
            #{spell}(#{name}) do |x = 1|
              #{body}
            end
          end
        end
      RUBY
      tc.note(source)
      kind = check(source)
      seen[kind] += 1
      next unless kind == :corrected && spell == "define_singleton_method"

      # The class methods are compared here; check compares instance methods.
      Dir.mktmpdir do |root|
        number = @@classes += 1
        original = load_class(source, "Original#{number}", root)
        written = load_class(CopRunner.run(source).source, "Written#{number}", root)
        assert_equal original.singleton_methods.sort, written.singleton_methods.sort
        # A Struct class answers `inspect` and the like with its own name.
        (original.singleton_methods - Struct.new(:z).singleton_methods).each { |m| assert_equal outcome { original.send(m) }, outcome { written.send(m) } }
      end
    end
    assert_operator seen[:corrected], :>, 50, seen.inspect
  end

  # Calls a loop makes next to define_method, each copied once per run.
  EXTRAS = [
    'alias_method :"#{name}_alias", name',
    'alias_method "old_#{name}", "#{name}"',
    'attr_accessor :"#{name.to_s.delete("?!")}_attr"',
    "private name",
    'protected "#{name}"',
    "public(name)",
    "ruby2_keywords(name) if respond_to?(:ruby2_keywords, true)",
    'module_function name if false'
  ].freeze

  def test_a_corrected_loop_makes_the_calls_the_original_made
    seen = Hash.new(0)
    Hegel.test(**SETTINGS) do |tc|
      opener = tc.draw(sampled_from(OPENERS))
      names = tc.draw(arrays(sampled_from(NAMES), min_size: 1, max_size: 3, unique: true))
      list = tc.draw(booleans) ? "[#{names.map { _1.to_sym.inspect }.join(", ")}]" : names.inspect
      frozen = tc.draw(booleans)
      extras = tc.draw(arrays(sampled_from(EXTRAS), min_size: 1, max_size: 3))
      source = <<~RUBY
        # frozen_string_literal: #{frozen}

        #{opener}
          #{list}.each do |name|
            define_method(name) { |x = 1| [name, x] }
            #{extras.join("\n    ")}
          end
        end
      RUBY
      tc.note(source)
      seen[check(source)] += 1
    end
    assert_operator seen[:corrected], :>, 50, seen.inspect
  end

  def test_a_corrected_string_eval_defines_the_methods_the_original_defined
    seen = Hash.new(0)
    Hegel.test(**SETTINGS) do |tc|
      opener = tc.draw(sampled_from(OPENERS))
      names = tc.draw(arrays(sampled_from(NAMES), min_size: 1, max_size: 3, unique: true))
      list = tc.draw(sampled_from(%w[symbols words constant hash]))
      section = tc.draw(sampled_from(["", "private\n  ", "public\n  "]))
      loop_head = case list
                  when "symbols" then "[#{names.map { _1.to_sym.inspect }.join(", ")}].each do |name|"
                  when "words" then "#{names.inspect}.each do |name|"
                  when "constant" then "NAMES = #{names.map(&:to_sym).inspect}.freeze\n  NAMES.each do |name|"
                  when "hash" then "{ #{names.map { "#{_1.to_sym.inspect} => #{_1.size}" }.join(", ")} }.each do |name, size|"
                  end
      result = list == "hash" ? "\#{size}" : tc.draw(sampled_from([":\#{name}", "'\#{name}'", "%(\#{name})"]))
      frozen = tc.draw(sampled_from(["", "# frozen_string_literal: true\n", "# frozen_string_literal: false\n"]))
      source = <<~RUBY
        #{frozen}#{opener}
          #{section}#{loop_head}
            class_eval <<~CODE, __FILE__, __LINE__ + 1
              def \#{name}(by = 1)
                [#{result}, by]
              end
            CODE
          end
        end
      RUBY
      tc.note(source)
      seen[check(source)] += 1
    end
    assert_operator seen[:corrected], :>, 50, seen.inspect
  end
end
