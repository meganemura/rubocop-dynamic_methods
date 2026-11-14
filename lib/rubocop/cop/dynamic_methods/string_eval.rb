# frozen_string_literal: true
# rbs_inline: enabled

module RuboCop
  module Cop
    module DynamicMethods
      # Finds code evaluated from a string with `class_eval`, `module_eval`,
      # `instance_eval`, or `eval`. A search for `def name` does not find a
      # method a string defines.
      #
      # The autocorrection writes the defs the string holds in place of the
      # call, when the string is a literal or interpolates only the variable
      # of an `each` over a literal list, holds nothing but defs, and is
      # evaluated on the class whose body calls it. A def from a string eval is
      # public even after a bare `private`, so a call after one is refused.
      # Otherwise the offense says what the string defines, or where the code
      # comes from, and why it was not rewritten.
      #
      # The autocorrection is unsafe: it trusts that `class_eval` and
      # `Array#each` are Ruby's own.
      #
      # @example
      #   # bad
      #   %w[width height].each do |name|
      #     class_eval <<~RUBY, __FILE__, __LINE__ + 1
      #       def #{name} = @size.fetch(:#{name})
      #     RUBY
      #   end
      #
      #   # good
      #   def width = @size.fetch(:width)
      #
      #   def height = @size.fetch(:height)
      class StringEval < Base
        extend AutoCorrector
        include FrozenStringLiteral
        include DynamicMethods::Reporting

        RESTRICT_ON_SEND = %i[class_eval module_eval instance_eval eval].freeze #: Array[Symbol]

        #: (AST::Node node) -> void
        def on_send(node)
          # `instance_eval(&block)` runs a block, whose defs a search finds.
          return if node.block_node || !node.arguments? || node.first_argument.block_pass_type?
          return if node.method?(:eval) && !node.receiver.nil?

          report(node, node) do
            raise RuboCop::DynamicMethods::Rewrite::Refusal, refusal(node) unless RuboCop::DynamicMethods::Rewrite.statement?(node)
          end
        end

        private

        # The lead of a refused offense says what is known about the code:
        # what it evaluates, and what it defines when the string says.
        #: (AST::Node node, ::RuboCop::DynamicMethods::Rewrite::Plan? plan) -> String
        def message_for(node, plan)
          return super if plan

          callee = "`#{node.receiver ? "#{node.receiver.source}." : ""}#{node.method_name}`"
          code = node.first_argument
          case code.type
          when :str
            names = defined_names(code.value)
            return "#{callee} evaluates a string that holds no def; run the code without a string, so a reader can search it." if names&.empty?
            return "#{callee} evaluates a string that defines #{names.map { "`#{_1}`" }.join(", ")}; define #{names.size == 1 ? "it" : "them"} with `def`, so a search finds #{names.size == 1 ? "it" : "them"}." if names
          when :dstr
            names = pattern_names(code)
            if names&.any?
              return "#{callee} evaluates a string that defines methods named #{names.map { "`#{_1}`" }.join(", ")}; " \
                     "write them with `def`, so a search finds them."
            end
            part = code.children.find { !_1.str_type? }
            return "#{callee} evaluates a string that interpolates `#{part.source}`, so only running it shows which methods it defines." if part
          end
          "#{callee} evaluates code from `#{code.source.lines.first.strip}`, so only running it shows which methods it defines."
        end

        # The def names of an interpolated string, with each interpolation
        # kept as written, such as `#{name}?`; nil when they cannot be read.
        #: (AST::Node dstr) -> Array[String]?
        def pattern_names(dstr)
          holes = {} #: Hash[String, String]
          flat = lambda do |node|
            node.children.map do |part|
              next part.value if part.str_type?
              next flat.call(part) if part.dstr_type?
              return unless part.begin_type?

              holes["zq#{holes.size}zq"] = part.source
              "zq#{holes.size - 1}zq"
            end.join
          end
          names = defined_names(flat.call(dstr))
          names&.map { |name| name.gsub(/zq\d+zq/) { holes.fetch(_1) } }
        end

        # The names of the defs in the code, or nil when it is not Ruby.
        #: (String code) -> Array[String]?
        def defined_names(code)
          parsed = RuboCop::ProcessedSource.new(code, target_ruby_version, "(eval)")
          return unless parsed.valid_syntax?

          parsed.ast&.each_node(:def, :defs)&.map { _1.defs_type? ? "self.#{_1.method_name}" : _1.method_name.to_s } || []
        end

        #: (AST::Node node) -> String
        def refusal(node)
          return "`#{node.method_name}` runs the string on another receiver" if %i[eval instance_eval].include?(node.method_name)

          "it evaluates the string on `#{node.receiver.source}`"
        end
      end
    end
  end
end
