# frozen_string_literal: true
# rbs_inline: enabled

module RuboCop
  module Cop
    module DynamicMethods
      # Finds methods that delegation defines: ActiveSupport's `delegate` and
      # `delegate_missing_to`, and Forwardable's `def_delegator` and
      # `def_delegators`. A search for `def name` does not find them.
      #
      # It only reports, and it is disabled by default: delegation is common,
      # accepted style, and a def is not the same method. Forwardable calls
      # through `__send__`, so it reaches private methods, and both take any
      # arguments where a def would name them.
      #
      # @example
      #   # bad
      #   delegate :name, :email, to: :user
      #
      #   # good
      #   def name = user.name
      #
      #   def email = user.email
      class Delegation < Base
        RESTRICT_ON_SEND = %i[delegate delegate_missing_to def_delegator def_delegators
                              def_instance_delegator def_instance_delegators].freeze #: Array[Symbol]

        #: (AST::Node node) -> void
        def on_send(node)
          return unless node.receiver.nil? || node.receiver.self_type?
          return unless node.arguments?

          message = case node.method_name
                    when :delegate then delegate(node)
                    when :delegate_missing_to then missing(node)
                    when :def_delegator, :def_instance_delegator then delegator(node)
                    else delegators(node)
                    end
          add_offense(node.loc.selector, message:) if message
        end

        private

        # `delegate :a, :b, to: :x, prefix: true` defines `x_a` and `x_b`.
        #: (AST::Node node) -> String?
        def delegate(node)
          options = node.last_argument if node.last_argument.hash_type?
          target = option(options, :to)
          return unless target

          prefix = option(options, :prefix)
          prefix = if prefix&.true_type? then literal(target)
                   elsif prefix && %i[sym str].include?(prefix.type) then prefix.value.to_s
                   elsif prefix && !prefix.false_type? then prefix.source
                   end
          methods = node.arguments.reject(&:hash_type?)
          names = methods.map { |method| [prefix, literal(method)].compact.join("_") }
          report(node.method_name, names, literal(target))
        end

        #: (AST::Node node) -> String
        def missing(node)
          "`delegate_missing_to` answers every method that `#{node.first_argument.source.delete_prefix(":")}` answers, " \
            "through `method_missing`, so no search finds them. Define the ones callers use with `def`."
        end

        # `def_delegator :@x, :a, :b` defines `b`, or `a` when no alias is given.
        #: (AST::Node node) -> String?
        def delegator(node)
          accessor, method, name = node.arguments
          return unless method

          report(node.method_name, [literal(name || method)], literal(accessor))
        end

        #: (AST::Node node) -> String?
        def delegators(node)
          accessor, *methods = node.arguments
          return if methods.empty?

          report(node.method_name, methods.map { literal(_1) }, literal(accessor))
        end

        #: (Symbol spell, Array[String] names, String target) -> String
        def report(spell, names, target)
          listed = names.map { _1.start_with?("the names in ") ? _1 : "`#{_1}`" }
          listed = names.size > 3 ? "#{listed.first(3).join(", ")} and #{names.size - 3} more" : listed.join(", ")
          one = names.size == 1 && !names.first.start_with?("the names in ")
          "`#{spell}` defines #{listed}, which #{one ? "forwards" : "forward"} to `#{target}`; " \
            "a search for `def name` does not find #{one ? "it" : "them"}."
        end

        #: (AST::Node? hash, Symbol key) -> AST::Node?
        def option(hash, key)
          hash&.pairs&.find { _1.key.sym_type? && _1.key.value == key }&.value
        end

        # A name as written, or the code that makes it.
        #: (AST::Node node) -> String
        def literal(node)
          return "the names in `#{node.children.first.source}`" if node.splat_type?

          %i[sym str].include?(node.type) ? node.value.to_s : node.source
        end
      end
    end
  end
end
