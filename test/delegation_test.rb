# frozen_string_literal: true

require "test_helper"

# Delegation only reports, so each case is the exact message.
class DelegationTest < Minitest::Test
  def messages(source)
    config = RuboCop::Config.new(
      RuboCop::ConfigLoader.default_configuration.to_h.merge(
        "AllCops" => { "TargetRubyVersion" => 3.4 },
        "DynamicMethods/Delegation" => { "Enabled" => true }
      ),
      "(test)"
    )
    team = RuboCop::Cop::Team.mobilize([RuboCop::Cop::DynamicMethods::Delegation], config, raise_error: true, stdin: source)
    team.investigate(RuboCop::ProcessedSource.new(source, 3.4, "test.rb")).offenses.map { "#{_1.line}: #{_1.message}" }
  end

  CASES = {
    "delegate :name, :email, to: :user" =>
      "`delegate` defines `name`, `email`, which forward to `user`; a search for `def name` does not find them.",
    "delegate :name, to: :user, prefix: true" =>
      "`delegate` defines `user_name`, which forwards to `user`; a search for `def name` does not find it.",
    "delegate :a, :b, :c, :d, to: :x, prefix: :y" =>
      "`delegate` defines `y_a`, `y_b`, `y_c` and 1 more, which forward to `x`; a search for `def name` does not find them.",
    "def_delegators :@items, :size, :each" =>
      "`def_delegators` defines `size`, `each`, which forward to `@items`; a search for `def name` does not find them.",
    "def_delegators :context, *QUERY_METHODS" =>
      "`def_delegators` defines the names in `QUERY_METHODS`, which forward to `context`; a search for `def name` does not find them.",
    "def_delegator :@items, :first, :head" =>
      "`def_delegator` defines `head`, which forwards to `@items`; a search for `def name` does not find it.",
    "delegate_missing_to :@record" =>
      "`delegate_missing_to` answers every method that `@record` answers, through `method_missing`, " \
      "so no search finds them. Define the ones callers use with `def`."
  }.freeze

  def test_each_delegation_names_the_methods_it_defines
    CASES.each do |line, message|
      assert_equal ["2: #{message}"], messages("class A\n  #{line}\nend\n"), line
    end
  end

  def test_a_call_on_another_receiver_or_without_to_is_not_reported
    assert_empty messages("class A\n  user.delegate :name\n  delegate :name\nend\n")
  end

  def test_it_is_disabled_by_default
    defaults = YAML.load_file(File.expand_path("../config/default.yml", __dir__))
    assert_equal false, defaults.dig("DynamicMethods/Delegation", "Enabled")
  end
end
