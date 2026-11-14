# frozen_string_literal: true
# rbs_inline: enabled

module RuboCop
  module DynamicMethods
    # Writes one defining statement, or the loop it sits in, as plain defs.
    # A rewrite is exact or it raises Refusal with the reason: a def that only
    # looks the same would teach a reader the wrong method. The rewrite only
    # moves code inside one class or module body, so each def keeps the class,
    # the constant scope, and the default visibility the original had.
    class Rewrite
      # @rbs!
      #   # A text that replaces a range of the file.
      #   type edit = [Parser::Source::Range, String]
      #
      #   # What each loop variable holds during one run of a loop.
      #   type run = Hash[Symbol, Value]

      # sig/rewrite.rbs declares it as a class, which rbs-inline cannot write.
      # @rbs skip
      Refusal = Class.new(StandardError)

      # The texts that replace ranges of the file, as [range, text] pairs, and
      # the names they define.
      Plan = Data.define(
        :edits, #: Array[edit]
        :names #: Array[String]
      ) do
        # Steep checks a def in this block as a method of Rewrite, so it
        # skips the line; sig/rewrite.rbs declares the method on Plan.
        def range = edits.first.first # steep:ignore
      end

      # One literal that a loop variable holds during one run of the loop.
      Value = Data.define(
        :object, #: Symbol | String | Integer | bool | nil
        :code #: String
      )

      SCOPES = %i[class module sclass].freeze #: Array[Symbol]
      BLOCKS = %i[block numblock itblock].freeze #: Array[Symbol]
      # Nodes that start their own `next` target or their own method body.
      JUMP_TARGETS = %i[block numblock itblock while until while_post until_post for def defs].freeze #: Array[Symbol]
      SPELLS = %i[define_method define_singleton_method].freeze #: Array[Symbol]
      EVALS = %i[class_eval module_eval].freeze #: Array[Symbol]
      # Calls that see the locals of a block but not of a def.
      LOCAL_READERS = %i[binding local_variables block_given? iterator? eval].freeze #: Array[Symbol]
      VISIBILITY = %i[private protected public module_function].freeze #: Array[Symbol]
      # Blocks read as a loop over values; a block of any other method is not.
      ITERATORS = %i[each each_pair each_with_index each_with_object each_key each_value map flat_map times].freeze #: Array[Symbol]
      # Methods that take method names and read a String as its Symbol.
      NAME_TAKERS = %i[alias_method attr_reader attr_writer attr_accessor private public protected module_function
                       private_class_method public_class_method ruby2_keywords undef_method remove_method].freeze #: Array[Symbol]
      # Of those, the ones that answer the same for a String and its Symbol:
      # attr_* answer Symbols, and alias_method the new name's Symbol.
      SAME_RESULT = %i[alias_method attr_reader attr_writer attr_accessor].freeze #: Array[Symbol]
      LITERALS = %i[array hash pair sym str int float nil true false].freeze #: Array[Symbol]
      CORE_PARENTS = %i[Object StandardError RuntimeError ArgumentError TypeError].freeze #: Array[Symbol]
      NOT_IN_BODY = "it is not called directly in a class or module body, or a block that opens one" #: String
      # A fixnum is the same object on every read; a larger Integer is not.
      FIXNUM = (-(2**62))...(2**62) #: Range[Integer]

      # @rbs @source: AST::ProcessedSource
      # @rbs @ruby_version: Float
      # @rbs @frozen_strings: bool

      #: (AST::ProcessedSource processed_source, ruby_version: Float, frozen_strings: bool) -> void
      def initialize(processed_source, ruby_version:, frozen_strings:)
        @source = processed_source
        @ruby_version = ruby_version
        @frozen_strings = frozen_strings
      end

      # The statement that defines: a block node for define_method, a send
      # node for class_eval.
      #: (AST::Node node) -> bool
      def self.statement?(node)
        if BLOCKS.include?(node.type)
          SPELLS.include?(node.method_name) && implicit?(node.send_node)
        else
          node.send_type? && EVALS.include?(node.method_name) && implicit?(node)
        end
      end

      #: (AST::Node send) -> bool
      def self.implicit?(send)
        send.receiver.nil? || send.receiver.self_type?
      end

      #: (AST::Node statement) -> Plan
      def plan(statement)
        # Steep cannot spread a tuple into positional arguments.
        container, body = lift(*enclosing(statement)) # steep:ignore ArgumentTypeMismatch
        if scope?(container)
          scope_body = scope_body(container)
          outer = assigned_locals(scope_body, except: statement) | visible_locals(container)
          run = {} #: run
          text, names = write(statement, run, outer, moved: 0, scope_body:)
          Plan.new(edits: [[full_range(statement), text]], names:)
        elsif BLOCKS.include?(container.type) && container.body.equal?(body) && ITERATORS.include?(container.method_name)
          plan_loop(container)
        elsif BLOCKS.include?(container.type)
          raise Refusal, "it is inside `#{container.method_name} do`, and only the code that runs the block knows " \
                         "which module it defines on"
        elsif %i[def defs].include?(container.type)
          plan_macro(container)
        else
          raise Refusal, NOT_IN_BODY
        end
      end

      private

      #: (AST::Node node) -> [AST::Node, AST::Node]
      def enclosing(node)
        parent = node.parent
        raise Refusal, NOT_IN_BODY if parent.nil?
        return [parent.parent, parent] if parent.begin_type? && parent.parent

        [parent, node]
      end

      # A branch of an `if` runs in the frame around it, so a def there defines
      # what the define_method did. The condition itself is not a branch.
      #: (AST::Node container, AST::Node body) -> [AST::Node, AST::Node]
      def lift(container, body)
        while container&.if_type? && !container.condition.equal?(body)
          if container.each_node(:send).any? { _1.receiver.nil? && !_1.arguments? && VISIBILITY.include?(_1.method_name) }
            raise Refusal, "the `if` around it calls a bare visibility method"
          end

          container, body = enclosing(container)
        end
        [container, body]
      end

      #: (AST::Node scope) -> AST::Node?
      def scope_body(scope)
        scope.body
      end

      # A class or module body, or a block that Ruby runs as one: a def and a
      # define_method there define on the same module, with the same default
      # visibility and the same constant lookup. `included do` and
      # `class_methods do` are not here: what runs them is the library's.
      #: (AST::Node node) -> bool?
      def scope?(node)
        return true if SCOPES.include?(node.type)
        return false unless BLOCKS.include?(node.type)

        send = node.send_node
        case send.method_name
        when :class_eval, :module_eval, :class_exec, :module_exec then true
        when :new then core_constant?(send.receiver, %i[Class Module Struct])
        when :define then core_constant?(send.receiver, %i[Data])
        else false
        end
      end

      #: (AST::Node? node, Array[Symbol] names) -> bool?
      def core_constant?(node, names)
        node&.const_type? && (node.namespace.nil? || node.namespace.cbase_type?) && names.include?(node.short_name)
      end

      # Locals a block can read from the code around it, up to the nearest
      # def, class, or module, which starts a scope of its own.
      #: (AST::Node scope) -> Array[Symbol]
      def visible_locals(scope)
        return [] if SCOPES.include?(scope.type)

        names = scope.arguments.each_descendant(:arg, :optarg, :restarg, :kwarg, :kwoptarg, :kwrestarg, :blockarg).map(&:name)
        scope.each_ancestor do |ancestor|
          if BLOCKS.include?(ancestor.type) && ancestor.respond_to?(:arguments)
            names.concat(ancestor.arguments.each_descendant(:arg, :optarg, :restarg, :kwarg, :kwoptarg, :kwrestarg, :blockarg).map(&:name))
            names.concat(assigned_locals(ancestor.body, except: scope))
          elsif %i[def defs].include?(ancestor.type)
            names.concat(ancestor.arguments.each_descendant(:arg, :optarg, :restarg, :kwarg, :kwoptarg, :kwrestarg, :blockarg).map(&:name))
            names.concat(assigned_locals(ancestor.body, except: scope))
            return names.uniq
          elsif SCOPES.include?(ancestor.type)
            return (names + assigned_locals(ancestor.body, except: scope)).uniq
          elsif ancestor.parent.nil?
            names.concat(assigned_locals(ancestor, except: scope))
          end
        end
        names.uniq
      end

      #: (AST::Node loop) -> Plan
      def plan_loop(loop)
        scope, = lift(*enclosing(loop)) # steep:ignore ArgumentTypeMismatch
        raise Refusal, "the loop is not called directly in a class or module body, or a block that opens one" unless scope?(scope)

        scope_body = scope.body
        runs = runs_of(loop, scope_body)
        statements = loop.body.begin_type? ? loop.body.children : [loop.body]

        outer = assigned_locals(scope_body, except: loop) | loop.arguments.children.map(&:name) | visible_locals(scope)
        indent = " " * loop.loc.column
        names = [] #: Array[String]
        # [text, whether it defines] for each statement of each run.
        pieces = runs.flat_map do |run|
          statements.map do |statement|
            if statement.first_line == loop.first_line && statement.multiline?
              raise Refusal, "the loop starts a definition on its own line"
            end

            moved = statement.loc.column - loop.loc.column
            next [copy(statement, run, moved:, loop:), false] unless self.class.statement?(statement) #: [String, bool]

            text, defined = write(statement, run, outer, moved:, scope_body:, loop:)
            names.concat(defined)
            [text, true] #: [String, bool]
          end
        end
        notes = loose_comments(loop, statements).map { "#{_1}\n#{indent}" }.join
        Plan.new(edits: [[full_range(loop), notes + join_pieces(pieces, indent)]], names:)
      end

      # A class method that defines methods, written out at each call in the
      # same class body that gives it literal arguments. Such a call runs the
      # macro's own method: `def self.name` (or `def name` in `class << self`)
      # sits on the class's singleton class, which comes first in the lookup
      # unless a module is prepended to it. The macro stays for other callers.
      #: (AST::Node macro) -> Plan
      def plan_macro(macro)
        name = macro.method_name
        reason = "it runs inside the method `#{name}`, and only its callers know which module and names it defines"
        holder = macro.parent&.begin_type? ? macro.parent.parent : macro.parent
        singleton = holder&.sclass_type? && holder.children.first.self_type?
        scope = singleton ? enclosing(holder).first : holder
        raise Refusal, reason unless (macro.defs_type? ? macro.receiver.self_type? : singleton) && %i[class module].include?(scope&.type)

        scope_body = scope.body
        calls = macro_calls(macro, scope_body)
        raise Refusal, "#{reason}; no call in this class body gives it literal arguments" if calls.empty?

        check_macro(macro, scope_body, singleton)
        names = [] #: Array[String]
        edits = calls.map do |call, run|
          check_visibility(scope_body, call, "a method such as `#{name}`")
          pieces = statements_of(macro.body).map do |statement|
            moved = statement.loc.column - call.loc.column
            raise Refusal, "the method `#{name}` is not indented under its callers" unless moved.positive?
            next [copy(statement, run, moved:, loop: macro), false] unless self.class.statement?(statement) #: [String, bool]

            text, defined = write(statement, run, run.keys, moved:, scope_body:, loop: macro, anchor: call)
            names.concat(defined)
            [text, true] #: [String, bool]
          end
          [full_range(call), join_pieces(pieces, " " * call.loc.column)] #: edit
        end
        Plan.new(edits:, names:)
      end

      # The calls of the macro after its def, each a statement of the class
      # body with one literal for each parameter, as [call, run] pairs.
      #: (AST::Node macro, AST::Node? scope_body) -> Array[[AST::Node, run]]
      def macro_calls(macro, scope_body)
        params = macro.arguments.children
        raise Refusal, "the method `#{macro.method_name}` takes parameters other than plain names" unless params.all?(&:arg_type?)

        statements_of(scope_body).filter_map do |call|
          next unless call.send_type? && call.receiver.nil? && call.method_name == macro.method_name
          next unless call.source_range.begin_pos > macro.source_range.end_pos && call.arguments.size == params.size

          values = call.arguments.map { value_of(_1) }
          [call, params.map(&:name).zip(values).to_h]
        rescue Refusal
          nil
        end
      end

      #: (AST::Node macro, AST::Node scope_body, bool? singleton) -> void
      def check_macro(macro, scope_body, singleton)
        defs = scope_body.each_node(:def, :defs).count do |node|
          node.method_name == macro.method_name && (node.defs_type? || node.parent&.sclass_type? || node.parent&.parent&.sclass_type?)
        end
        raise Refusal, "the class defines `#{macro.method_name}` more than once" unless defs == 1
        # Code in a def runs later, when it is called; the class body runs now.
        if runs_in_body(scope_body).any? { _1.send_type? && (_1.method?(:prepend) || _1.method?(:singleton_class)) }
          raise Refusal, "the class prepends a module or opens its singleton class, which could take the call"
        end
        # A block in `class << self` looks constants up there first; a def in
        # the class body does not.
        return unless singleton && macro.body&.each_node(:const)&.any? { _1.namespace.nil? }

        raise Refusal, "the method `#{macro.method_name}` sits in `class << self` and names a constant, " \
                       "which a def in the class body would look up elsewhere"
      end

      # The nodes of a body that run with it, leaving out the bodies of defs.
      # NODE is any child of a node: a node, a Symbol, a literal, or nil.
      #: (untyped node, ?Array[AST::Node] found) -> Array[AST::Node]
      def runs_in_body(node, found = [])
        return found unless node.is_a?(RuboCop::AST::Node) && !%i[def defs].include?(node.type)

        found << node
        node.children.each { runs_in_body(_1, found) }
        found
      end

      # A blank line sets each def apart; calls such as `alias_method` that
      # follow one another stay together. Pieces are [text, whether it defines].
      #: (Array[[String, bool]] pieces, String indent) -> String
      def join_pieces(pieces, indent)
        # Steep reads a destructured element of `each_cons` as possibly nil.
        rest = pieces.each_cons(2).map { |(_, a), (b_text, b)| (a || b ? "\n\n" : "\n") + indent + b_text } # steep:ignore ArgumentTypeMismatch
        pieces.first.first + rest.join
      end

      # A statement of the loop that defines nothing, such as `alias_method` or
      # `private`, copied once per run with the loop variables written as
      # their literals. It moves from the block into the class body, so
      # anything that tells the two apart is refused.
      #: (AST::Node statement, run run, moved: Integer, loop: AST::Node) -> String
      def copy(statement, run, moved:, loop:)
        edits = [] #: Array[edit]
        walk = lambda do |node|
          next unless node.is_a?(RuboCop::AST::Node)

          done = copy_edits(node, statement, run, loop, edits)
          check_moved_node(node)
          node.children.each { walk.call(_1) unless done.include?(_1) }
        end
        walk.call(statement)
        range = full_range(statement)
        reindent(slice(range.begin_pos, range.end_pos, edits), moved)
      end

      # Adds the edits for one node, and returns the children it wrote whole.
      #: (AST::Node node, AST::Node statement, run run, AST::Node loop, Array[edit] edits) -> Array[AST::Node]
      def copy_edits(node, statement, run, loop, edits)
        case node.type
        when :lvar
          edits << loop_read(node, run.fetch(node.children.first)) if run.key?(node.children.first)
        when :lvasgn
          raise Refusal, "#{where(loop)} assigns the local `#{node.children.first}`, which each run starts afresh"
        when :arg, :optarg, :restarg, :kwarg, :kwoptarg, :kwrestarg, :blockarg, :shadowarg
          raise Refusal, "a block in #{where(loop)} reuses the name `#{node.name}`" if run.key?(node.name)
        when :def, :defs
          raise Refusal, "#{where(loop)} holds a def, which cannot see its locals"
        when :class, :module, :sclass
          raise Refusal, "#{where(loop)} opens a class or module, which cannot see its locals"
        when :casgn
          raise Refusal, "#{where(loop)} assigns a constant"
        when :next, :break, :redo, :return
          raise Refusal, "#{where(loop)} uses `#{node.type}`" if own_level?(node, loop)
        when :yield, :super, :zsuper
          # A method has a block and a super method of its own; a class body has neither.
          raise Refusal, "the method uses `#{node.type == :yield ? "yield" : "super"}`" if %i[def defs].include?(loop.type)
        when :send
          return copy_send(node, statement, run, edits, loop)
        end
        []
      end

      #: (AST::Node send, AST::Node statement, run run, Array[edit] edits, AST::Node loop) -> Array[AST::Node]
      def copy_send(send, statement, run, edits, loop)
        return [] unless self.class.implicit?(send)

        name = send.method_name
        raise Refusal, "#{where(loop)} calls `#{name}`, which sees its locals" if LOCAL_READERS.include?(name)
        if VISIBILITY.include?(name) && !send.arguments?
          raise Refusal, "#{where(loop)} calls a bare `#{name}`, which a class body scopes differently"
        end
        if name == :__method__ && %i[def defs].include?(loop.type)
          raise Refusal, "#{where(loop)} reads `__method__`, which is nil in a class body"
        end
        if (SPELLS + EVALS).include?(name)
          raise Refusal, "#{where(loop)} calls `#{name}` inside `#{statement.source.lines.first.strip}`"
        end
        return [] unless NAME_TAKERS.include?(name) && (SAME_RESULT.include?(name) || discarded?(send, statement))

        # `alias_method "#{name}?", name` reads better as `alias_method :alpha?, :alpha`.
        send.arguments.select do |argument|
          symbol = folded_name(argument, run)
          edits << [argument.source_range, symbol.inspect] if symbol
        end
      end

      #: (AST::Node loop) -> String
      def where(loop)
        %i[def defs].include?(loop.type) ? "the method `#{loop.method_name}`" : "the loop"
      end

      # A call whose value nothing reads: the statement, or a branch of an
      # `if` that is the statement.
      #: (AST::Node send, AST::Node statement) -> bool
      def discarded?(send, statement)
        return true if send.equal?(statement)

        parent = send.parent
        parent.equal?(statement) && parent.if_type? && !send.equal?(parent.condition)
      end

      # The Symbol a name argument comes to, when it is built from the loop
      # variables alone; nil otherwise.
      #: (AST::Node node, run run) -> Symbol?
      def folded_name(node, run)
        case node.type
        when :lvar
          value = run[node.children.first]&.object
          value.to_sym if value.is_a?(String) || value.is_a?(Symbol)
        when :dsym, :dstr
          return if node.respond_to?(:heredoc?) && node.heredoc?
          return unless node.each_descendant(:lvar).any? { run.key?(_1.children.first) }

          name_of(node, run).to_sym
        end
      rescue Refusal
        nil
      end

      # Each run of the loop as variable name => Value.
      #: (AST::Node loop, AST::Node? scope_body) -> Array[run]
      def runs_of(loop, scope_body)
        send = loop.send_node
        raise Refusal, "the loop is `#{send.method_name}`, not `each`" unless %i[each each_pair].include?(send.method_name)
        raise Refusal, "the loop passes arguments to `#{send.method_name}`" if send.arguments?
        raise Refusal, "the loop uses numbered parameters" unless loop.block_type?

        params = loop.arguments.children #: Array[AST::Node]
        unless params.all?(&:arg_type?) && !loop.arguments.source.to_s.match?(/,\s*\|\z/)
          raise Refusal, "the loop takes parameters other than plain names"
        end

        list = list_of(send.receiver, scope_body, loop)
        raise Refusal, "the list is empty" if list.empty?

        if list.first.is_a?(Array)
          raise Refusal, "the loop over a hash does not take a key and a value" unless params.size == 2

          list.map { |key, value| { params[0].name => key, params[1].name => value } } #: Array[run]
        else
          raise Refusal, "the loop does not take one value" unless params.size == 1 && send.method_name == :each

          list.map { { params[0].name => _1 } } #: Array[run]
        end
      end

      # The literals a loop runs over: Values, or [Value, Value] pairs.
      # The caller reads the first element to tell the two shapes apart, which
      # a union of the two Array types would not let it do.
      #: (AST::Node? node, AST::Node? scope_body, AST::Node loop) -> Array[untyped]
      def list_of(node, scope_body, loop)
        return hash_part(node, scope_body, loop) if node&.send_type? && %i[keys values].include?(node.method_name) && !node.arguments?

        node = constant_value(node, scope_body, loop) if node&.const_type?
        # Steep does not narrow NODE by `case node&.type`; a branch below runs
        # only when NODE is an array or a hash node.
        case node&.type
        when :array
          node.children.map { value_of(_1) } # steep:ignore NoMethod
        when :hash
          node.children.map do |pair| # steep:ignore NoMethod
            raise Refusal, "the hash holds more than literal pairs" unless pair.pair_type?

            [value_of(pair.key), value_of(pair.value)]
          end
        else
          raise Refusal, "the loop runs over `#{node&.source || "nothing"}`, which is not a literal list"
        end
      end

      # `LIST.keys` or `LIST.values` of a literal Hash, as the Values of one side.
      #: (AST::Node node, AST::Node? scope_body, AST::Node loop) -> Array[Value]
      def hash_part(node, scope_body, loop)
        pairs = list_of(node.receiver, scope_body, loop)
        raise Refusal, "the loop runs over `#{node.source}`, which is not the keys or values of a literal Hash" unless pairs.first.is_a?(Array)

        pairs.map { node.method?(:keys) ? _1.first : _1.last }
      end

      # A constant set once in this body, before the loop, to a literal list.
      # A bare constant could also come from an outer module or an ancestor,
      # which another file can set or reopen, so only this body counts.
      #: (AST::Node node, AST::Node? scope_body, AST::Node loop) -> AST::Node
      def constant_value(node, scope_body, loop)
        unless node.namespace.nil?
          raise Refusal, "the loop runs over `#{node.source}`, a constant of another module, which another file can change"
        end

        sets = statements_of(scope_body).select { _1.casgn_type? && _1.namespace.nil? && _1.name == node.short_name }
        unless sets.size == 1 && sets.first.source_range.end_pos <= loop.source_range.begin_pos
          raise Refusal, "the loop runs over `#{node.source}`, which this class body does not set once before the loop"
        end

        value = sets.first.expression
        if value&.send_type? && value.method?(:freeze) && !value.arguments? && %i[array hash].include?(value.receiver&.type)
          return value.receiver
        end
        raise Refusal, "`#{node.source}` is set to `#{value&.source}`, which is not a literal list" unless %i[array hash].include?(value&.type)

        check_untouched(node.short_name, sets.first, loop, scope_body)
        value
      end

      # An unfrozen list stays as written only when no code between its
      # assignment and the loop could change it: the statements there may
      # only define, or call a method of NAME_TAKERS with literal names.
      #: (Symbol name, AST::Node set, AST::Node loop, AST::Node? scope_body) -> void
      def check_untouched(name, set, loop, scope_body)
        between = statements_of(scope_body).select do
          _1.source_range.begin_pos >= set.source_range.end_pos && _1.source_range.end_pos <= loop.source_range.begin_pos
        end
        busy = between.find { !inert?(_1) || names_now?(_1, name) }
        if busy
          raise Refusal, "`#{name}` is not frozen, and `#{busy.source.lines.first.strip}` runs between its assignment and the loop"
        end
        return unless loop.body&.each_node(:const)&.any? { _1.short_name == name }

        raise Refusal, "`#{name}` is not frozen, and the loop names it, so it could grow while the loop runs"
      end

      # Whether the code reads the constant as it runs; a def's body reads it
      # only when the method is called, after the loop.
      #: (AST::Node node, Symbol name) -> bool
      def names_now?(node, name)
        return false if %i[def defs].include?(node.type)
        return true if node.const_type? && node.short_name == name

        node.each_child_node.any? { names_now?(_1, name) }
      end

      # Code that defines and runs nothing else, so it cannot reach a list.
      # Reading a constant can run code too, through autoload, and a parent
      # class can run code through `inherited`, so only core parents count.
      #: (AST::Node node) -> bool?
      def inert?(node)
        case node.type
        when :def, :defs, :str, :sym, :int, :nil, :true, :false then true
        when :class, :module
          node.identifier.namespace.nil? &&
            (node.type == :module || node.parent_class.nil? || core_constant?(node.parent_class, CORE_PARENTS)) &&
            statements_of(node.body).all? { inert?(_1) }
        when :casgn
          node.namespace.nil? && node.expression && literal_tree?(node.expression)
        when :send
          self.class.implicit?(node) && (NAME_TAKERS + %i[private_constant public_constant]).include?(node.method_name) &&
            node.arguments.all? { %i[sym str].include?(_1.type) }
        else false
        end
      end

      # A literal made of literals, frozen or not.
      #: (AST::Node node) -> bool
      def literal_tree?(node)
        node = node.receiver if node.send_type? && node.method?(:freeze) && !node.arguments? && node.receiver
        node.each_node.all? { LITERALS.include?(_1.type) }
      end

      #: (AST::Node node) -> Value
      def value_of(node)
        case node.type
        when :sym
          Value.new(object: node.value, code: node.value.inspect)
        when :str
          Value.new(object: node.value, code: node.value.inspect)
        when :int
          raise Refusal, "`#{node.source}` is too large to be the same object on every read" unless FIXNUM.cover?(node.value)

          Value.new(object: node.value, code: node.value.negative? ? "(#{node.value})" : node.value.to_s)
        when :nil, :true, :false
          Value.new(object: { nil: nil, true: true, false: false }.fetch(node.type), code: node.type.to_s)
        else
          raise Refusal, "the list holds `#{node.source}`, which is not a symbol, string, small integer, nil, true, or false"
        end
      end

      #: (AST::Node? body) -> Array[AST::Node]
      def statements_of(body)
        return [] if body.nil?

        body.begin_type? ? body.children : [body]
      end

      # Locals the code around a statement assigns, which a block shares and a
      # def does not.
      #: (AST::Node? body, except: AST::Node) -> Array[Symbol]
      def assigned_locals(body, except:)
        names = [] #: Array[Symbol]
        walk = lambda do |node|
          next unless node.is_a?(RuboCop::AST::Node)
          next if node.equal?(except)

          names << node.children.first if node.lvasgn_type?
          next if BLOCKS.include?(node.type) || %i[def defs class module sclass].include?(node.type)

          node.children.each(&walk)
        end
        walk.call(body)
        names.uniq
      end

      #: (AST::Node statement, run run, Array[Symbol] outer, moved: Integer, scope_body: AST::Node?, ?loop: AST::Node?, ?anchor: AST::Node) -> [String, Array[String]]
      def write(statement, run, outer, moved:, scope_body:, loop: nil, anchor: loop || statement)
        if BLOCKS.include?(statement.type)
          write_block(statement, run, outer, moved:, loop:, column: anchor.loc.column)
        else
          write_string(statement, run, scope_body:, anchor:)
        end
      end

      #: (AST::Node block, run run, Array[Symbol] outer, moved: Integer, loop: AST::Node?, column: Integer) -> [String, Array[String]]
      def write_block(block, run, outer, moved:, loop:, column:)
        send = block.send_node
        raise Refusal, "the block uses numbered parameters" if block.numblock_type?
        raise Refusal, "the block uses `it`" if block.type == :itblock
        raise Refusal, "`#{send.method_name}` takes more than a name and a block" unless send.arguments.size == 1

        name = name_of(send.first_argument, run)
        prefix = send.method?(:define_singleton_method) ? "self." : ""
        check_name(name, prefix)
        params = block.arguments
        raise Refusal, "the block declares block-local variables" if params.each_descendant(:shadowarg).any?
        raise Refusal, "the block's parameters end with a comma" if params.source.to_s.match?(/,\s*\|\z/)

        edits = block_edits(block, run, outer, moving: loop || block.single_line?)
        header = "def #{prefix}#{name}"
        unless params.children.empty?
          inner = slice(params.children.first.source_range.begin_pos, params.children.last.source_range.end_pos, edits)
          header += "(#{inner})"
        end
        opener = params.children.empty? ? block.loc.begin : params.loc.end
        body = slice(opener.end_pos, block.loc.end.begin_pos, edits)
        indent = " " * column
        # A one-line block becomes a def of three lines, the shape a reader
        # expects; the body moves to its own line.
        return ["#{header}\n#{indent}#{body.strip.empty? ? "" : "  #{body.strip}\n#{indent}"}end", ["#{prefix}#{name}"]] if block.single_line?

        body = ";#{body}" unless body.match?(/\A[ \t]*(#|\n|\z)/)
        [reindent("#{header}#{body}end", moved), ["#{prefix}#{name}"]]
      end

      # Edits inside a block: loop variables become their literal, and a `next`
      # that leaves the method becomes `return`.
      #: (AST::Node block, run run, Array[Symbol] outer, moving: boolish) -> Array[edit]
      def block_edits(block, run, outer, moving:)
        edits = [] #: Array[edit]
        block.each_descendant do |node|
          case node.type
          when :lvar, :lvasgn
            local = node.children.first
            next unless outer.include?(local)
            raise Refusal, "the block shares the local `#{local}` with the code around it" unless node.lvar_type? && run.key?(local)

            edits << loop_read(node, run.fetch(local))
          when :arg, :optarg, :restarg, :kwarg, :kwoptarg, :kwrestarg, :blockarg, :shadowarg
            raise Refusal, "the block reuses the loop's name `#{node.name}`" if run.key?(node.name)
          when :zsuper
            raise Refusal, "the block calls `super` with no arguments, which raises in a block given to define_method"
          when :yield
            raise Refusal, "the block uses `yield`"
          when :send
            if node.receiver.nil? && LOCAL_READERS.include?(node.method_name)
              raise Refusal, "the block calls `#{node.method_name}`, which sees the locals around the block"
            end
          when :casgn
            raise Refusal, "the block assigns a constant, which a def cannot"
          when :class, :module, :sclass
            raise Refusal, "the block opens a class or module, which a def cannot"
          when :def, :defs
            raise Refusal, "the block holds a def"
          when :next
            edits << [node.loc.keyword, "return"] if own_level?(node, block)
          when :break, :redo
            raise Refusal, "the block uses `#{node.type}` outside a loop" if own_level?(node, block)
          end
          check_moved_node(node) if moving
        end
        edits
      end

      # A read inside a symbol's `#{}` writes the text in place. A string keeps
      # `#{}`, because a string with no interpolation left would be a literal,
      # which `# frozen_string_literal: true` freezes. A string read elsewhere
      # is one shared object, and only a frozen literal is the same object on
      # every call.
      #: (AST::Node node, Value value) -> edit
      def loop_read(node, value)
        holder = node.parent
        raise Refusal, "the block asks `defined?` of the loop variable" if holder&.defined_type?
        if holder&.begin_type? && holder.children.size == 1 && holder.parent&.dsym_type? &&
           holder.parent.source.start_with?(':"') && value.object.to_s.match?(/\A[\w?!= .-]*\z/)
          return [holder.source_range, value.object.to_s]
        end
        return [node.source_range, value.code] if holder&.begin_type? && holder.parent&.dstr_type?
        # `{ v: }` names the local and the key at once.
        return [holder.source_range, "#{holder.key.value}: #{value.code}"] if holder&.pair_type? && holder.value_omission?
        if value.object.is_a?(String) && !@frozen_strings
          raise Refusal, "the block reads the string #{value.code}, which is one shared object only under `# frozen_string_literal: true`"
        end

        [node.source_range, value.code]
      end

      #: (AST::Node node) -> void
      def check_moved_node(node)
        raise Refusal, "the block reads `__LINE__`, which the rewrite moves" if node.int_type? && node.source == "__LINE__"
        if %i[str dstr xstr dsym].include?(node.type) && (node.respond_to?(:heredoc?) && node.heredoc? || node.multiline?)
          raise Refusal, "the block holds a string that spans lines, which moving the code would change"
        end
      end

      #: (AST::Node node, AST::Node block) -> bool
      def own_level?(node, block)
        node.each_ancestor.each do |ancestor|
          return true if ancestor.equal?(block)
          return false if JUMP_TARGETS.include?(ancestor.type)
        end
        false
      end

      #: (AST::Node send, run run, scope_body: AST::Node?, anchor: AST::Node) -> [String, Array[String]]
      def write_string(send, run, scope_body:, anchor:)
        unless (1..3).cover?(send.arguments.size) && %i[str dstr].include?(send.first_argument.type) && !send.block_node
          raise Refusal, "`#{send.method_name}` is not given a string literal"
        end
        check_visibility(scope_body, anchor)
        code = string_value(send.first_argument, run)
        if code.match?(/\b__(LINE|FILE|dir)__\b|\bModule\.nesting\b/)
          raise Refusal, "the string reads `__LINE__`, `__FILE__`, `__dir__`, or `Module.nesting`, which name the eval"
        end

        names = defs_in(code)
        lines = code.chomp.lines(chomp: true)
        # `/\A */` matches every line, so the match is never nil.
        margin = lines.reject { _1.strip.empty? }.map { _1[/\A */].size }.min || 0 # steep:ignore NoMethod
        indent = " " * anchor.loc.column
        text = lines.map.with_index do |line, index|
          stripped = line.strip.empty? ? "" : line[margin..] #: String
          index.zero? || stripped.empty? ? stripped : indent + stripped
        end.join("\n")
        [text, names]
      end

      # A def a string eval writes is public even after a bare `private`.
      #: (AST::Node? scope_body, AST::Node anchor, ?String maker) -> void
      def check_visibility(scope_body, anchor, maker = "a string eval")
        last = statements_of(scope_body)
               .take_while { _1.source_range.begin_pos < anchor.source_range.begin_pos }
               .select { _1.send_type? && _1.receiver.nil? && !_1.arguments? && VISIBILITY.include?(_1.method_name) }
               .last
        return if last.nil? || last.method?(:public)

        raise Refusal, "it follows a bare `#{last.method_name}`, and a def from #{maker} stays public"
      end

      #: (AST::Node node, run run) -> String
      def string_value(node, run)
        case node.type
        when :str
          node.value
        when :dstr
          node.children.map { string_value(_1, run) }.join
        when :begin
          inner = node.children
          if inner.size == 1 && inner.first.lvar_type? && run.key?(inner.first.children.first)
            run.fetch(inner.first.children.first).object.to_s
          elsif inner.size == 1 && %i[sym str int].include?(inner.first.type)
            inner.first.value.to_s
          else
            raise Refusal, "the string interpolates `#{node.source}`, which is not a loop variable over literals"
          end
        else
          raise Refusal, "the string holds `#{node.source}`"
        end
      end

      #: (String code) -> Array[String]
      def defs_in(code)
        parsed = RuboCop::ProcessedSource.new(code, @ruby_version, "(eval)")
        raise Refusal, "the string is not valid Ruby on its own" unless parsed.valid_syntax? && parsed.ast

        top = parsed.ast.begin_type? ? parsed.ast.children : [parsed.ast]
        raise Refusal, "the string does more than define methods" unless top.all? { %i[def defs].include?(_1.type) }

        check_string_literals(parsed)
        top.map { _1.defs_type? ? "self.#{_1.method_name}" : _1.method_name.to_s }
      end

      # The file's `# frozen_string_literal:` comment does not reach code a
      # string eval compiles, so a string literal there is frozen or not by
      # its own comment. Moved into the file, it would take the file's.
      #: (AST::ProcessedSource parsed) -> void
      def check_string_literals(parsed)
        return if self.class.frozen_setting(parsed) == self.class.frozen_setting(@source)

        literal = parsed.ast.each_node(:str, :dstr).find do |node|
          next false if %i[dstr dsym xstr regexp].include?(node.parent&.type)

          node.str_type? || node.children.all?(&:str_type?)
        end
        return unless literal

        raise Refusal, "the string's code holds the string literal #{literal.source}, " \
                       "which `# frozen_string_literal:` would treat differently in this file"
      end

      # true, false, or nil when the source has no magic comment.
      #: (AST::ProcessedSource processed_source) -> bool?
      def self.frozen_setting(processed_source)
        first_code = processed_source.tokens.find { !_1.comment? }&.line || Float::INFINITY
        processed_source.comments.take_while { _1.loc.line < first_code }.each do |comment|
          magic = RuboCop::MagicComment.parse(comment.text)
          return magic.frozen_string_literal if magic.frozen_string_literal_specified?
        end
        nil
      end

      #: (AST::Node node, run run) -> String
      def name_of(node, run)
        case node&.type
        when :sym, :str
          node.value.to_s
        when :dsym, :dstr
          node.children.map do |part|
            if part.str_type?
              part.value
            elsif part.begin_type? && part.children.size == 1 && part.children.first.lvar_type? && run.key?(part.children.first.children.first)
              run.fetch(part.children.first.children.first).object.to_s
            else
              raise Refusal, "its name interpolates `#{part.source}`, which is not a loop variable over literals"
            end
          end.join
        when :lvar
          local = node.children.first
          raise Refusal, "its name comes from `#{node.source}`" unless run.key?(local)

          run.fetch(local).object.to_s
        else
          raise Refusal, "its name comes from `#{node&.source}`"
        end
      end

      #: (String name, String prefix) -> void
      def check_name(name, prefix)
        parsed = RuboCop::ProcessedSource.new("def #{prefix}#{name}; end", @ruby_version, "(name)")
        ast = parsed.ast
        return if parsed.valid_syntax? && ast && %i[def defs].include?(ast.type) && ast.method_name.to_s == name

        raise Refusal, "`#{name}` cannot be written after `def`"
      end

      #: (Integer from, Integer to, Array[edit] edits) -> String
      def slice(from, to, edits)
        text = +""
        position = from
        edits.select { _1[0].begin_pos >= from && _1[0].end_pos <= to }.sort_by { _1[0].begin_pos }.each do |range, replacement|
          # Each range lies inside the buffer, so the slice is a String.
          text << buffer_source[position...range.begin_pos] << replacement # steep:ignore ArgumentTypeMismatch
          position = range.end_pos
        end
        text << buffer_source[position...to] # steep:ignore ArgumentTypeMismatch
      end

      #: (String text, Integer moved) -> String
      def reindent(text, moved)
        return text if moved.zero?

        first, *rest = text.split("\n", -1)
        rest = rest.map do |line|
          next line if line.strip.empty?
          raise Refusal, "the definition is not indented under the loop" unless line.start_with?(" " * moved)

          line[moved..]
        end
        [first, *rest].join("\n")
      end

      # Comments in a loop that no definition holds, kept above the defs.
      #: (AST::Node loop, Array[AST::Node] statements) -> Array[String]
      def loose_comments(loop, statements)
        loop_range = full_range(loop)
        @source.comments.select do |comment|
          position = comment.source_range.begin_pos
          position.between?(loop_range.begin_pos, loop_range.end_pos) &&
            statements.none? { full_range(_1).begin_pos <= position && position < full_range(_1).end_pos }
        end.map(&:text)
      end

      # A node's range, widened to the end of any heredoc it starts.
      #: (AST::Node node) -> Parser::Source::Range
      def full_range(node)
        finish = node.source_range.end_pos
        node.each_node(:str, :dstr, :xstr) do |string|
          next unless string.respond_to?(:heredoc?) && string.heredoc?

          finish = [finish, string.loc.heredoc_end.end_pos].max
        end
        if finish > node.source_range.end_pos
          gap = buffer_source[node.source_range.end_pos...node.each_node(:str, :dstr, :xstr).select { _1.respond_to?(:heredoc?) && _1.heredoc? }.map { _1.loc.heredoc_body.begin_pos }.min] #: String
          raise Refusal, "code follows the heredoc's opening line" unless gap.match?(/\A[ \t]*\n\z/)
        end
        node.source_range.with(end_pos: finish)
      end

      #: () -> String
      def buffer_source
        @source.buffer.source
      end
    end
  end
end
