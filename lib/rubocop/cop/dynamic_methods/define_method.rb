# frozen_string_literal: true
# rbs_inline: enabled

module RuboCop
  module Cop
    module DynamicMethods
      # Finds methods defined with `define_method` or `define_singleton_method`.
      # A search for `def name` does not find them.
      #
      # The autocorrection writes a plain `def` when the result is the same
      # method: the same name, parameters, body, and visibility. That holds
      # for a call directly in a class or module body (or a block Ruby runs as
      # one, such as `Class.new do`), or in an `each` over a
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

        RESTRICT_ON_SEND = %i[define_method define_singleton_method].freeze #: Array[Symbol]

        #: (AST::Node node) -> void
        def on_send(node)
          return unless node.block_node || node.arguments?

          statement = node.block_node || node
          report(node, statement) do
            raise RuboCop::DynamicMethods::Rewrite::Refusal, refusal(node) unless node.block_node && RuboCop::DynamicMethods::Rewrite.statement?(statement)
          end
        end

        private

        #: (AST::Node node) -> String
        def refusal(node)
          return "it defines the method on `#{node.receiver.source}`" unless RuboCop::DynamicMethods::Rewrite.implicit?(node)
          return body_refusal(node.arguments[1]) if node.arguments.size > 1

          "the body is not a block"
        end

        # What a body that is not a literal block is, so the reader knows
        # what a def would have to do instead.
        #: (AST::Node body) -> String
        def body_refusal(body)
          if body.block_pass_type?
            inner = body.children.first
            return "the body is `&#{inner.value.inspect}`, which calls `#{inner.value}` on the method's first argument" if inner&.sym_type?
            return copied(inner) || "the body is the block in `#{inner&.source}`, which the code that runs this passes in"
          end
          return "the body is a lambda, not a block" if body.block_type? && body.send_node.lambda_or_proc?
          copied(body) || "the body is `#{body.source}`, not a block"
        end

        # `Kernel.instance_method(:send)` or `Time.method(:now)`: the method is
        # copied as it is, and a def would be a new method that calls it.
        #: (AST::Node? node) -> String?
        def copied(node)
          return unless node&.send_type? && %i[instance_method method].include?(node.method_name) && node.first_argument
          unless %i[sym str].include?(node.first_argument.type)
            owner = node.receiver ? " of `#{node.receiver.source.delete_prefix("::")}`" : ""
            return "it copies a method#{owner} chosen by `#{node.first_argument.source}`, as it is"
          end

          name = node.first_argument.value.to_s
          name = "#{node.receiver.source.delete_prefix("::")}#{node.method?(:instance_method) ? "#" : "."}#{name}" if node.receiver
          "it copies the method `#{name}` as it is, and a def would be a new method that calls it"
        end
      end
    end
  end
end
