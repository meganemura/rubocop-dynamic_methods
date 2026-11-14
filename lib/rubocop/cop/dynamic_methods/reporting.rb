# frozen_string_literal: true
# rbs_inline: enabled

module RuboCop
  module Cop
    module DynamicMethods
      # The offense both rewriting cops add: the names a rewrite defines, or
      # the reason there is none, which tells an agent what to write by hand.
      #
      # @rbs module-self Base, FrozenStringLiteral
      module Reporting
        # @rbs @rewrite: ::RuboCop::DynamicMethods::Rewrite?
        # @rbs @corrected_ranges: Array[Parser::Source::Range]?

        #: () -> void
        def on_new_investigation
          @rewrite = nil
          @corrected_ranges = nil
          super
        end

        private

        #: (AST::Node node, AST::Node statement) { () -> void } -> void
        def report(node, statement)
          plan = begin
            yield
            rewrite.plan(statement)
          rescue RuboCop::DynamicMethods::Rewrite::Refusal => e
            e
          end
          if plan.is_a?(Exception)
            add_offense(node.loc.selector, message: "#{message_for(node, nil)} Not autocorrected: #{plan.message}.")
          elsif corrected_ranges.include?(plan.range)
            add_offense(node.loc.selector, message: message_for(node, plan))
          else
            corrected_ranges << plan.range
            add_offense(node.loc.selector, message: message_for(node, plan)) do |corrector|
              plan.edits.each { |range, text| corrector.replace(range, text) }
            end
          end
        end

        #: (AST::Node _node, ::RuboCop::DynamicMethods::Rewrite::Plan? plan) -> String
        def message_for(_node, plan)
          return "Define this method with `def`, so a search for its name finds it." if plan.nil?

          names = plan.names.map { "`#{_1}`" }
          "Define #{names.size > 3 ? "#{names.first(3).join(", ")} and #{names.size - 3} more" : names.join(", ")} with `def`, so a search for `def name` finds #{names.size == 1 ? "it" : "them"}."
        end

        #: () -> ::RuboCop::DynamicMethods::Rewrite
        def rewrite
          @rewrite ||= RuboCop::DynamicMethods::Rewrite.new(
            processed_source,
            ruby_version: target_ruby_version,
            frozen_strings: frozen_string_literals_enabled?
          )
        end

        #: () -> Array[Parser::Source::Range]
        def corrected_ranges
          @corrected_ranges ||= []
        end
      end
    end
  end
end
