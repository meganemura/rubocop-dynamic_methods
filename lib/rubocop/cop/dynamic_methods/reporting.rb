# frozen_string_literal: true

module RuboCop
  module Cop
    module DynamicMethods
      # The offense both rewriting cops add: the names a rewrite defines, or
      # the reason there is none, which tells an agent what to write by hand.
      module Reporting
        def on_new_investigation
          @rewrite = nil
          @corrected_ranges = nil
          super
        end

        private

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
              corrector.replace(plan.range, plan.text)
            end
          end
        end

        def message_for(_node, plan)
          return "Define this method with `def`, so a search for its name finds it." if plan.nil?

          names = plan.names.map { "`#{_1}`" }
          "Define #{names.size > 3 ? "#{names.first(3).join(", ")} and #{names.size - 3} more" : names.join(", ")} with `def`, so a search for `def name` finds #{names.size == 1 ? "it" : "them"}."
        end

        def rewrite
          @rewrite ||= RuboCop::DynamicMethods::Rewrite.new(
            processed_source,
            ruby_version: target_ruby_version,
            frozen_strings: frozen_string_literals_enabled?
          )
        end

        def corrected_ranges
          @corrected_ranges ||= []
        end
      end
    end
  end
end
