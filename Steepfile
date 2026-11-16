# frozen_string_literal: true

# `sig` holds this gem's own signatures, which the gem ships. `sig-deps`
# holds stubs for the parts of RuboCop and lint_roller that lib/ calls;
# those gems ship no RBS.
target :lib do
  signature "sig", "sig-deps"
  check "lib"
  library "pathname"

  # Steep reports a node it cannot type as UnexpectedError and skips the
  # rest of that node. The default level is hint, so the check would pass.
  configure_code_diagnostics do |hash|
    hash[Steep::Diagnostic::Ruby::UnexpectedError] = :error
  end
end
