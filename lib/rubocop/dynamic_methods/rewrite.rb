# frozen_string_literal: true

module RuboCop
  module DynamicMethods
    # Writes one defining statement, or the loop it sits in, as plain defs.
    # A rewrite is exact or it raises Refusal with the reason: a def that only
    # looks the same would teach a reader the wrong method. The rewrite only
    # moves code inside one class or module body, so each def keeps the class,
    # the constant scope, and the default visibility the original had.
    class Rewrite
      Refusal = Class.new(StandardError)

      # The text that replaces a range of the file, and the names it defines.
      Plan = Data.define(:range, :text, :names)

      # One literal that a loop variable holds during one run of the loop.
      Value = Data.define(:object, :code)

      SCOPES = %i[class module sclass].freeze
      BLOCKS = %i[block numblock itblock].freeze
      # Nodes that start their own `next` target or their own method body.
      JUMP_TARGETS = %i[block numblock itblock while until while_post until_post for def defs].freeze
      SPELLS = %i[define_method define_singleton_method].freeze
      EVALS = %i[class_eval module_eval].freeze
      # Calls that see the locals of a block but not of a def.
      LOCAL_READERS = %i[binding local_variables block_given? iterator? eval].freeze
      VISIBILITY = %i[private protected public module_function].freeze
      # Blocks read as a loop over values; a block of any other method is not.
      ITERATORS = %i[each each_pair each_with_index each_with_object each_key each_value map flat_map times].freeze
      # Methods that take method names and read a String as its Symbol.
      NAME_TAKERS = %i[alias_method attr_reader attr_writer attr_accessor private public protected module_function
                       private_class_method public_class_method ruby2_keywords undef_method remove_method].freeze
      # Of those, the ones that answer the same for a String and its Symbol:
      # attr_* answer Symbols, and alias_method the new name's Symbol.
      SAME_RESULT = %i[alias_method attr_reader attr_writer attr_accessor].freeze
      LITERALS = %i[array hash pair sym str int float nil true false].freeze
      CORE_PARENTS = %i[Object StandardError RuntimeError ArgumentError TypeError].freeze
      NOT_IN_BODY = "it is not called directly in a class or module body, or a block that opens one"
      # A fixnum is the same object on every read; a larger Integer is not.
      FIXNUM = (-(2**62))...(2**62)

      def initialize(processed_source, ruby_version:, frozen_strings:)
        @source = processed_source
        @ruby_version = ruby_version
        @frozen_strings = frozen_strings
      end

      # The statement that defines: a block node for define_method, a send
      # node for class_eval.
      def self.statement?(node)
        if BLOCKS.include?(node.type)
          SPELLS.include?(node.method_name) && implicit?(node.send_node)
        else
          node.send_type? && EVALS.include?(node.method_name) && implicit?(node)
        end
      end

      def self.implicit?(send)
        send.receiver.nil? || send.receiver.self_type?
      end

      def plan(statement)
        container, body = enclosing(statement)
        if scope?(container)
          scope_body = scope_body(container)
          outer = assigned_locals(scope_body, except: statement) | visible_locals(container)
          run = {}
          text, names = write(statement, run, outer, moved: 0, scope_body:)
          Plan.new(range: full_range(statement), text:, names:)
        elsif BLOCKS.include?(container.type) && container.body.equal?(body) && ITERATORS.include?(container.method_name)
          plan_loop(container)
        elsif BLOCKS.include?(container.type)
          raise Refusal, "it is inside `#{container.method_name} do`, and only the code that runs the block knows " \
                         "which module it defines on"
        else
          raise Refusal, NOT_IN_BODY
        end
      end

      private

      def enclosing(node)
        parent = node.parent
        raise Refusal, NOT_IN_BODY if parent.nil?
        return [parent.parent, parent] if parent.begin_type? && parent.parent

        [parent, node]
      end

      def scope_body(scope)
        scope.body
      end

      # A class or module body, or a block that Ruby runs as one: a def and a
      # define_method there define on the same module, with the same default
      # visibility and the same constant lookup. `included do` and
      # `class_methods do` are not here: what runs them is the library's.
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

      def core_constant?(node, names)
        node&.const_type? && (node.namespace.nil? || node.namespace.cbase_type?) && names.include?(node.short_name)
      end

      # Locals a block can read from the code around it, up to the nearest
      # def, class, or module, which starts a scope of its own.
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

      def plan_loop(loop)
        scope, = enclosing(loop)
        raise Refusal, "the loop is not called directly in a class or module body, or a block that opens one" unless scope?(scope)

        scope_body = scope.body
        runs = runs_of(loop, scope_body)
        statements = loop.body.begin_type? ? loop.body.children : [loop.body]

        outer = assigned_locals(scope_body, except: loop) | loop.arguments.children.map(&:name) | visible_locals(scope)
        indent = " " * loop.loc.column
        names = []
        # [text, whether it defines] for each statement of each run.
        pieces = runs.flat_map do |run|
          statements.map do |statement|
            if statement.first_line == loop.first_line && statement.multiline?
              raise Refusal, "the loop starts a definition on its own line"
            end

            moved = statement.loc.column - loop.loc.column
            next [copy(statement, run, moved:, loop:), false] unless self.class.statement?(statement)

            text, defined = write(statement, run, outer, moved:, scope_body:, loop:)
            names.concat(defined)
            [text, true]
          end
        end
        # A blank line sets each def apart; calls such as `alias_method` that
        # follow one another stay together.
        text = pieces.each_cons(2).map { |(_, a), (b_text, b)| (a || b ? "\n\n" : "\n") + indent + b_text }
        text = pieces.first.first + text.join
        notes = loose_comments(loop, statements).map { "#{_1}\n#{indent}" }.join
        Plan.new(range: full_range(loop), text: notes + text, names:)
      end

      # A statement of the loop that defines nothing, such as `alias_method` or
      # `private`, copied once per run with the loop variables written as
      # their literals. It moves from the block into the class body, so
      # anything that tells the two apart is refused.
      def copy(statement, run, moved:, loop:)
        edits = []
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
      def copy_edits(node, statement, run, loop, edits)
        case node.type
        when :lvar
          edits << loop_read(node, run.fetch(node.children.first)) if run.key?(node.children.first)
        when :lvasgn
          raise Refusal, "the loop assigns the local `#{node.children.first}`, which each run of the loop starts afresh"
        when :arg, :optarg, :restarg, :kwarg, :kwoptarg, :kwrestarg, :blockarg, :shadowarg
          raise Refusal, "a block in the loop reuses the loop's name `#{node.name}`" if run.key?(node.name)
        when :def, :defs
          raise Refusal, "the loop holds a def, which cannot see the loop variable"
        when :class, :module, :sclass
          raise Refusal, "the loop opens a class or module, which cannot see the loop variable"
        when :casgn
          raise Refusal, "the loop assigns a constant"
        when :next, :break, :redo, :return
          raise Refusal, "the loop uses `#{node.type}`" if own_level?(node, loop)
        when :send
          return copy_send(node, statement, run, edits)
        end
        []
      end

      def copy_send(send, statement, run, edits)
        return [] unless self.class.implicit?(send)

        name = send.method_name
        raise Refusal, "the loop calls `#{name}`, which sees the loop's locals" if LOCAL_READERS.include?(name)
        if VISIBILITY.include?(name) && !send.arguments?
          raise Refusal, "the loop calls a bare `#{name}`, which a block and a class body scope differently"
        end
        if (SPELLS + EVALS).include?(name)
          raise Refusal, "the loop calls `#{name}` inside `#{statement.source.lines.first.strip}`"
        end
        return [] unless NAME_TAKERS.include?(name) && (SAME_RESULT.include?(name) || discarded?(send, statement))

        # `alias_method "#{name}?", name` reads better as `alias_method :alpha?, :alpha`.
        send.arguments.select do |argument|
          symbol = folded_name(argument, run)
          edits << [argument.source_range, symbol.inspect] if symbol
        end
      end

      # A call whose value nothing reads: the statement, or a branch of an
      # `if` that is the statement.
      def discarded?(send, statement)
        return true if send.equal?(statement)

        parent = send.parent
        parent.equal?(statement) && parent.if_type? && !send.equal?(parent.condition)
      end

      # The Symbol a name argument comes to, when it is built from the loop
      # variables alone; nil otherwise.
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
      def runs_of(loop, scope_body)
        send = loop.send_node
        raise Refusal, "the loop is `#{send.method_name}`, not `each`" unless %i[each each_pair].include?(send.method_name)
        raise Refusal, "the loop passes arguments to `#{send.method_name}`" if send.arguments?
        raise Refusal, "the loop uses numbered parameters" unless loop.block_type?

        params = loop.arguments.children
        unless params.all?(&:arg_type?) && !loop.arguments.source.to_s.match?(/,\s*\|\z/)
          raise Refusal, "the loop takes parameters other than plain names"
        end

        list = list_of(send.receiver, scope_body, loop)
        raise Refusal, "the list is empty" if list.empty?

        if list.first.is_a?(Array)
          raise Refusal, "the loop over a hash does not take a key and a value" unless params.size == 2

          list.map { |key, value| { params[0].name => key, params[1].name => value } }
        else
          raise Refusal, "the loop does not take one value" unless params.size == 1 && send.method_name == :each

          list.map { { params[0].name => _1 } }
        end
      end

      # The literals a loop runs over: Values, or [Value, Value] pairs.
      def list_of(node, scope_body, loop)
        return hash_part(node, scope_body, loop) if node&.send_type? && %i[keys values].include?(node.method_name) && !node.arguments?

        node = constant_value(node, scope_body, loop) if node&.const_type?
        case node&.type
        when :array
          node.children.map { value_of(_1) }
        when :hash
          node.children.map do |pair|
            raise Refusal, "the hash holds more than literal pairs" unless pair.pair_type?

            [value_of(pair.key), value_of(pair.value)]
          end
        else
          raise Refusal, "the loop runs over `#{node&.source || "nothing"}`, which is not a literal list"
        end
      end

      # `LIST.keys` or `LIST.values` of a literal Hash, as the Values of one side.
      def hash_part(node, scope_body, loop)
        pairs = list_of(node.receiver, scope_body, loop)
        raise Refusal, "the loop runs over `#{node.source}`, which is not the keys or values of a literal Hash" unless pairs.first.is_a?(Array)

        pairs.map { node.method?(:keys) ? _1.first : _1.last }
      end

      # A constant set once in this body, before the loop, to a literal list.
      # A bare constant could also come from an outer module or an ancestor,
      # which another file can set or reopen, so only this body counts.
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
      def names_now?(node, name)
        return false if %i[def defs].include?(node.type)
        return true if node.const_type? && node.short_name == name

        node.each_child_node.any? { names_now?(_1, name) }
      end

      # Code that defines and runs nothing else, so it cannot reach a list.
      # Reading a constant can run code too, through autoload, and a parent
      # class can run code through `inherited`, so only core parents count.
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
      def literal_tree?(node)
        node = node.receiver if node.send_type? && node.method?(:freeze) && !node.arguments? && node.receiver
        node.each_node.all? { LITERALS.include?(_1.type) }
      end

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

      def statements_of(body)
        return [] if body.nil?

        body.begin_type? ? body.children : [body]
      end

      # Locals the code around a statement assigns, which a block shares and a
      # def does not.
      def assigned_locals(body, except:)
        names = []
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

      def write(statement, run, outer, moved:, scope_body:, loop: nil)
        if BLOCKS.include?(statement.type)
          write_block(statement, run, outer, moved:, loop:, column: (loop || statement).loc.column)
        else
          write_string(statement, run, scope_body:, anchor: loop || statement)
        end
      end

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
      def block_edits(block, run, outer, moving:)
        edits = []
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

      def check_moved_node(node)
        raise Refusal, "the block reads `__LINE__`, which the rewrite moves" if node.int_type? && node.source == "__LINE__"
        if %i[str dstr xstr dsym].include?(node.type) && (node.respond_to?(:heredoc?) && node.heredoc? || node.multiline?)
          raise Refusal, "the block holds a string that spans lines, which moving the code would change"
        end
      end

      def own_level?(node, block)
        node.each_ancestor.each do |ancestor|
          return true if ancestor.equal?(block)
          return false if JUMP_TARGETS.include?(ancestor.type)
        end
        false
      end

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
        margin = lines.reject { _1.strip.empty? }.map { _1[/\A */].size }.min || 0
        indent = " " * anchor.loc.column
        text = lines.map.with_index do |line, index|
          stripped = line.strip.empty? ? "" : line[margin..]
          index.zero? || stripped.empty? ? stripped : indent + stripped
        end.join("\n")
        [text, names]
      end

      # A def a string eval writes is public even after a bare `private`.
      def check_visibility(scope_body, anchor)
        last = statements_of(scope_body)
               .take_while { _1.source_range.begin_pos < anchor.source_range.begin_pos }
               .select { _1.send_type? && _1.receiver.nil? && !_1.arguments? && VISIBILITY.include?(_1.method_name) }
               .last
        return if last.nil? || last.method?(:public)

        raise Refusal, "it follows a bare `#{last.method_name}`, and a def from a string eval stays public"
      end

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
      def self.frozen_setting(processed_source)
        first_code = processed_source.tokens.find { !_1.comment? }&.line || Float::INFINITY
        processed_source.comments.take_while { _1.loc.line < first_code }.each do |comment|
          magic = RuboCop::MagicComment.parse(comment.text)
          return magic.frozen_string_literal if magic.frozen_string_literal_specified?
        end
        nil
      end

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

      def check_name(name, prefix)
        parsed = RuboCop::ProcessedSource.new("def #{prefix}#{name}; end", @ruby_version, "(name)")
        ast = parsed.ast
        return if parsed.valid_syntax? && ast && %i[def defs].include?(ast.type) && ast.method_name.to_s == name

        raise Refusal, "`#{name}` cannot be written after `def`"
      end

      def slice(from, to, edits)
        text = +""
        position = from
        edits.select { _1[0].begin_pos >= from && _1[0].end_pos <= to }.sort_by { _1[0].begin_pos }.each do |range, replacement|
          text << buffer_source[position...range.begin_pos] << replacement
          position = range.end_pos
        end
        text << buffer_source[position...to]
      end

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
      def loose_comments(loop, statements)
        loop_range = full_range(loop)
        @source.comments.select do |comment|
          position = comment.source_range.begin_pos
          position.between?(loop_range.begin_pos, loop_range.end_pos) &&
            statements.none? { full_range(_1).begin_pos <= position && position < full_range(_1).end_pos }
        end.map(&:text)
      end

      # A node's range, widened to the end of any heredoc it starts.
      def full_range(node)
        finish = node.source_range.end_pos
        node.each_node(:str, :dstr, :xstr) do |string|
          next unless string.respond_to?(:heredoc?) && string.heredoc?

          finish = [finish, string.loc.heredoc_end.end_pos].max
        end
        if finish > node.source_range.end_pos
          gap = buffer_source[node.source_range.end_pos...node.each_node(:str, :dstr, :xstr).select { _1.respond_to?(:heredoc?) && _1.heredoc? }.map { _1.loc.heredoc_body.begin_pos }.min]
          raise Refusal, "code follows the heredoc's opening line" unless gap.match?(/\A[ \t]*\n\z/)
        end
        node.source_range.with(end_pos: finish)
      end

      def buffer_source
        @source.buffer.source
      end
    end
  end
end
