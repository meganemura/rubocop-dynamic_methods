# AGENTS.md

Context for agents that work in this repository.

## What this is

rubocop-dynamic_methods is a RuboCop plugin. Its cops find methods that Ruby metaprogramming defines (`define_method`, string evals, `method_missing`), which a search for `def name` cannot find.
The autocorrection writes a plain `def` only when the def is the same method. Otherwise the offense names the reason, so an agent or a person can write the def.
The design records are in `docs/decisions/`. Read them before you change the shape.

## Layout

- `lib/rubocop-dynamic_methods.rb` is the entry RuboCop requires. `lib/rubocop/dynamic_methods/plugin.rb` is the lint_roller plugin, and `config/default.yml` is the cops' default configuration.
- `lib/rubocop/dynamic_methods/rewrite.rb` decides whether a statement, or the `each` loop around it, can be written as defs, and writes them. It raises `Rewrite::Refusal` with the reason.
- `lib/rubocop/cop/dynamic_methods/` holds the cops. `reporting.rb` is the offense the two rewriting cops share.
- `test/cops_test.rb` covers the exact output and each refusal. `test/hegel/rewrite_test.rb` loads the original and the corrected class and compares their methods.

## Visibility

This repository is intended for public release.
Write all committed text in English: code, comments, docs, commit messages.
`README.ja.md` is the one Japanese file. It follows `README.md` in the same commit, in natural Japanese, one sentence per line, with no em dash.
Do not reference private tools, private repositories, or internal working documents in committed content.

## Rules

- The runtime dependencies are `rubocop` and `lint_roller`. The Gemfile pins the development versions exactly. Add a dependency only with the owner's approval, pinned exactly, at least 7 days past its release.
- A rewrite is exact or refused. Never write a def that is close (`docs/decisions/0001-exact-or-refused.md`).
- Each refusal reason says what the code does, so the reader knows what to write by hand.
- Write property tests with hegeltest wherever a property exists. A new rewrite rule needs a case in `test/hegel/rewrite_test.rb` that loads both versions.
- Comments say why: the constraint, or the alternative that was refused. Each file starts with its responsibility.
- A release or a change of the repository's visibility is the owner's to run. A commit that changes `lib/rubocop/dynamic_methods/version.rb` and lands on `main` starts `.github/workflows/release.yml`; `docs/releasing.md` has the steps. Every change that a gem user can notice adds a line under `## [Unreleased]` in `CHANGELOG.md`.

## Commands

- `bundle exec bin/test` runs every test. `bundle exec bin/test test/cops_test.rb` runs one file.
- `BUNDLE_WITHOUT=hegel bundle exec bin/test test/cops_test.rb` runs on Ruby older than 3.4, which hegeltest needs.
- To try the cops on real code, write a `.rubocop.yml` with `plugins: [rubocop-dynamic_methods]` in a scratch directory and run `BUNDLE_GEMFILE=<this checkout>/Gemfile bundle exec rubocop --only DynamicMethods` there.
