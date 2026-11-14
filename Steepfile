# frozen_string_literal: true

# `sig` holds this gem's own signatures, which the gem ships. `sig-deps`
# holds stubs for the parts of RuboCop and lint_roller that lib/ calls;
# those gems ship no RBS.
target :lib do
  signature "sig", "sig-deps"
  check "lib"
  library "pathname"
end
