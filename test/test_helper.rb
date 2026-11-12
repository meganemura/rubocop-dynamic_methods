# frozen_string_literal: true

require "minitest/autorun"
require "rubocop-dynamic_methods"

# Runs the department's cops on a source the way `rubocop -A` does, and
# returns the offenses of the first pass and the source once nothing changes.
module CopRunner
  COPS = [
    RuboCop::Cop::DynamicMethods::DefineMethod,
    RuboCop::Cop::DynamicMethods::StringEval,
    RuboCop::Cop::DynamicMethods::MethodMissing
  ].freeze

  Result = Data.define(:offenses, :source)

  def self.config
    @config ||= RuboCop::Config.new(
      RuboCop::ConfigLoader.default_configuration.to_h.merge(
        "AllCops" => { "TargetRubyVersion" => 3.4 },
        **COPS.to_h { [_1.cop_name, { "Enabled" => true, "SafeAutoCorrect" => true }] }
      ),
      "(test)"
    )
  end

  # With autocorrect on, a Team skips the cops after one that corrects, so
  # the offenses come from a run with it off.
  def self.offenses(source, autocorrect: false)
    processed = RuboCop::ProcessedSource.new(source, 3.4, "test.rb")
    # `stdin` keeps a correction in memory; without it the Team writes the file.
    team = RuboCop::Cop::Team.mobilize(COPS, config, raise_error: true, autocorrect:, stdin: source)
    team.investigate(processed)
  end

  def self.run(source)
    first = offenses(source).offenses
    10.times do
      report = offenses(source, autocorrect: true)
      corrector = report.correctors.compact.first
      corrected = report.correctors.compact.each_with_object(RuboCop::Cop::Corrector.new(report.processed_source)) do |c, all|
        all.merge!(c)
      rescue RuboCop::Cop::Corrector::ClobberingError
        nil
      end
      return Result.new(offenses: first, source:) if corrector.nil?

      updated = corrected.rewrite
      return Result.new(offenses: first, source:) if updated == source

      source = updated
    end
    raise "the corrections did not settle"
  end
end
