# frozen_string_literal: true

require "lint_roller"
require "pathname"

module RuboCop
  module DynamicMethods
    # Tells RuboCop where the cops' default configuration is.
    class Plugin < LintRoller::Plugin
      def about
        LintRoller::About.new(
          name: "rubocop-dynamic_methods",
          version: VERSION,
          homepage: "https://github.com/meganemura/rubocop-dynamic_methods",
          description: "Rewrites dynamically defined methods as plain defs you can search for."
        )
      end

      def supported?(context)
        context.engine == :rubocop
      end

      def rules(_context)
        LintRoller::Rules.new(
          type: :path,
          config_format: :rubocop,
          value: Pathname.new(__dir__).join("../../../config/default.yml").expand_path
        )
      end
    end
  end
end
