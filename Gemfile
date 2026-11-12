# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "minitest", "6.0.6"
gem "rubocop", "1.92.2"

# hegeltest needs Ruby 3.4; CI runs the property tests there only.
group :hegel do
  gem "hegeltest", "0.4.1"
end
