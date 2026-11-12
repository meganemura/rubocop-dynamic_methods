# 2. Delegation is a separate cop, off by default, that only reports

## Context

`delegate :a, :b, to: :x` and Forwardable's `def_delegators :@x, :a, :b` define methods that a search for `def name` does not find. In a survey of 51 popular gems they were the most common shape of dynamic definition, at about 240 sites in 23 gems.

A def is not the same method. Forwardable calls the target through `__send__`, so it reaches private methods, and both libraries define methods that take any arguments, where a def would name its parameters. So no rewrite is exact (decision 1).

Delegation is also accepted style, above all in Rails code. A cop that reports it by default would bury the offenses the other cops raise.

## Decision

`DynamicMethods/Delegation` is a cop of its own. It is disabled by default and has no autocorrection. When a project turns it on, each offense names the methods the call defines and what they forward to, so an agent or a person can write the defs where a search should find them.

## Consequences

A project that wants every method to have a `def` turns the cop on. A project that accepts delegation never sees it. The other cops keep their defaults.
