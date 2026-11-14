# frozen_string_literal: true
# rbs_inline: enabled

require "lint_roller"
require "pathname"

module RuboCop
  module DynamicMethods
    # Tells RuboCop where the cops' default configuration is.
    class Plugin < LintRoller::Plugin
      def about #: LintRoller::About
        LintRoller::About.new(
          name: "rubocop-dynamic_methods",
          version: VERSION,
          homepage: "https://github.com/meganemura/rubocop-dynamic_methods",
          description: "Rewrites dynamically defined methods as plain defs you can search for."
        )
      end

      # @rbs context: LintRoller::Context
      # @rbs return: bool
      def supported?(context)
        context.engine == :rubocop
      end

      # @rbs _context: LintRoller::Context
      # @rbs return: LintRoller::Rules
      def rules(_context)
        LintRoller::Rules.new(
          type: :path,
          config_format: :rubocop,
          # `__dir__` is nil only in code given to `eval`.
          value: Pathname.new(__dir__).join("../../../config/default.yml").expand_path # steep:ignore ArgumentTypeMismatch
        )
      end
    end
  end
end
