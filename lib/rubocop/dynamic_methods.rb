# frozen_string_literal: true

# The entry RuboCop loads through the lint_roller plugin: the cops and the
# plugin that hands RuboCop their default configuration.
require "lint_roller"
require_relative "dynamic_methods/version"
require_relative "dynamic_methods/plugin"
require_relative "dynamic_methods/rewrite"
require_relative "cop/dynamic_methods/reporting"
require_relative "cop/dynamic_methods/define_method"
require_relative "cop/dynamic_methods/string_eval"
require_relative "cop/dynamic_methods/method_missing"
require_relative "cop/dynamic_methods/delegation"
