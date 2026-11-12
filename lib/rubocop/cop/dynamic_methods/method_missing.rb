# frozen_string_literal: true

module RuboCop
  module Cop
    module DynamicMethods
      # Finds `method_missing`. The methods it answers have no `def` at all,
      # so no search finds them, and no rewrite can list them. Define each
      # method it answers with `def`, or with a call this department can
      # rewrite.
      #
      # @example
      #   # bad
      #   def method_missing(name, *args)
      #     name.end_with?("?") ? @state == name.to_s.chomp("?").to_sym : super
      #   end
      #
      #   # good
      #   def draft? = @state == :draft
      class MethodMissing < Base
        MSG = "Define the methods `method_missing` answers with `def`, so a search for their names finds them."

        def on_def(node)
          add_offense(node.loc.name) if node.method?(:method_missing)
        end
        alias on_defs on_def
      end
    end
  end
end
