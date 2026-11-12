# frozen_string_literal: true

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

        RESTRICT_ON_SEND = %i[class_eval module_eval instance_eval eval].freeze

        def on_send(node)
          return if node.block_node || !node.arguments?
          return if node.method?(:eval) && !node.receiver.nil?

          report(node, node) do
            raise RuboCop::DynamicMethods::Rewrite::Refusal, refusal(node) unless RuboCop::DynamicMethods::Rewrite.statement?(node)
          end
        end

        private

        def refusal(node)
          return "`#{node.method_name}` runs the string on another receiver" if %i[eval instance_eval].include?(node.method_name)

          "it evaluates the string on `#{node.receiver.source}`"
        end
      end
    end
  end
end
