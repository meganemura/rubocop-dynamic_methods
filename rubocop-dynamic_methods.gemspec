# frozen_string_literal: true

require_relative "lib/rubocop/dynamic_methods/version"

Gem::Specification.new do |spec|
  spec.name = "rubocop-dynamic_methods"
  spec.version = RuboCop::DynamicMethods::VERSION
  spec.authors = ["meganemura"]
  spec.summary = "RuboCop cops that rewrite dynamically defined methods as plain defs you can search for."
  spec.homepage = "https://github.com/meganemura/rubocop-dynamic_methods"
  spec.license = "MIT"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true",
    "default_lint_roller_plugin" => "RuboCop::DynamicMethods::Plugin"
  }
  spec.required_ruby_version = ">= 3.2.0"
  spec.files = Dir["lib/**/*.rb", "sig/**/*.rbs", "config/*.yml", "README.md", "README.ja.md", "LICENSE", "CHANGELOG.md"]
  spec.add_dependency "lint_roller", "~> 1.1"
  spec.add_dependency "rubocop", ">= 1.72.0", "< 2"
end
