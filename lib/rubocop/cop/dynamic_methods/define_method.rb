# frozen_string_literal: true

module RuboCop
  module Cop
    module DynamicMethods
      # Finds methods defined with `define_method` or `define_singleton_method`.
      # A search for `def name` does not find them.
      #
      # The autocorrection writes a plain `def` when the result is the same
      # method: the same name, parameters, body, and visibility. That holds
      # for a call directly in a class or module body, or in an `each` over a
      # literal list there. Otherwise the offense names the reason, and the
      # method is left for a person or an agent to write.
      #
      # The autocorrection is unsafe: it trusts that `define_method` and
      # `Array#each` are Ruby's own.
      #
      # @example
      #   # bad
      #   %i[draft paid].each do |state|
      #     define_method(:"#{state}?") { @state == state }
      #   end
      #
      #   # good
      #   def draft?
      #     @state == :draft
      #   end
      #
      #   def paid?
      #     @state == :paid
      #   end
      class DefineMethod < Base
        extend AutoCorrector
        include FrozenStringLiteral
        include DynamicMethods::Reporting

        RESTRICT_ON_SEND = %i[define_method define_singleton_method].freeze

        def on_send(node)
          return unless node.block_node || node.arguments?

          statement = node.block_node || node
          report(node, statement) do
            raise RuboCop::DynamicMethods::Rewrite::Refusal, refusal(node) unless node.block_node && RuboCop::DynamicMethods::Rewrite.statement?(statement)
          end
        end

        private

        def refusal(node)
          return "it defines the method on `#{node.receiver.source}`" unless RuboCop::DynamicMethods::Rewrite.implicit?(node)
          return "the body is `#{node.arguments[1].source}`, not a block" if node.arguments.size > 1

          "the body is not a block"
        end
      end
    end
  end
end
