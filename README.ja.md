# rubocop-dynamic_methods

Ruby のメタプログラミングで定義されたメソッドを見つける RuboCop の cop です。
`paid?` が `define_method` や文字列 eval で作られていると、`def paid?` を検索しても何も見つかりません。
読み手はまずコーディングエージェント、次に人です。
この cop はそうしたメソッドを見つけ、ふつうの `def` に書き直します。

```ruby
# frozen_string_literal: true

class Order
  STATES = %i[draft paid].freeze

  STATES.each do |state|
    define_method(:"#{state}?") { @state == state }
  end
end
```

```sh
$ rubocop -A --only DynamicMethods order.rb
order.rb:7:5: C: [Corrected] DynamicMethods/DefineMethod: Define draft?, paid? with def, so a search for def name finds them.
```

```ruby
# frozen_string_literal: true

class Order
  STATES = %i[draft paid].freeze

  def draft?
    @state == :draft
  end

  def paid?
    @state == :paid
  end
end
```

## はじめかた

```ruby
# Gemfile
gem "rubocop-dynamic_methods", require: false
```

```yaml
# .rubocop.yml
plugins:
  - rubocop-dynamic_methods
```

RuboCop 1.72 以降と Ruby 3.2 以降で動きます。

## cop の一覧

| cop | 見つけるもの | 自動修正 |
| --- | --- | --- |
| `DynamicMethods/DefineMethod` | `define_method` と `define_singleton_method` | `def name` と `def self.name` に書き直す |
| `DynamicMethods/StringEval` | 文字列を渡した `class_eval`、`module_eval`、`instance_eval`、`eval` | 文字列の中の def に書き直す |
| `DynamicMethods/MethodMissing` | `def method_missing` | しない |

## 同じになるときだけ直す

自動修正は、Ruby が同じメソッドを定義するときだけ def を書きます。
同じとは、名前、引数、本体、公開範囲が同じことです。
確かめられないときは、理由を書いた警告だけを出し、コードはそのままにします。

```ruby
class Feed
  ELEMENTS = %w[title link]
  include Parsing

  ELEMENTS.each do |name|
    class_eval <<~RUBY, __FILE__, __LINE__ + 1
      def #{name} = @values[:#{name}]
    RUBY
  end
end
```

```text
feed.rb:6:5: C: DynamicMethods/StringEval: Define this method with `def`, so a search for its name finds it. Not autocorrected: `ELEMENTS` is not frozen, and `include Parsing` runs between its assignment and the loop.
```

理由は、次に def を書く人やエージェントに向けて書いています。

RuboCop はソースを読むだけで実行しません。
そのため、ソースだけで名前がすべて決まるときにだけ書き直せます。

- 呼び出しがレシーバーなしか `self` で、クラスやモジュールの本体に直接あること。
  `class_eval`、`module_eval`、`class_exec`、`module_exec`、`Class.new`、`Module.new`、`Struct.new`、`Data.define` のブロックも、クラスの本体として扱います。
  そこでの def は、同じモジュールに、同じ公開範囲と定数の探し方で定義されるからです。
  `included do` のような他のメソッドのブロックは扱いません。
  どこに定義されるかは、そのブロックを実行するコードにしか分からないからです。
  または、そこにあるリテラルの Array か Hash に対する `each` の中にあること。
  定数は、同じ本体の中でループより前に一度だけ、リテラルの Array か Hash を入れていればリテラルとして扱います。
  `LIST.keys` と `LIST.values` も同じです。
  freeze していないリストでは、代入からループまでの間に、def、リテラルの定数、`attr_reader :a` のような呼び出ししか置けません。
  そうすれば、間でリストが変わることはないからです。
  `Base::NAMES` のような他のモジュールの定数は書き直しません。
  別のファイルで変えられるからです。
- そのループの中の他の呼び出し(`alias_method`、`attr_reader`、`private`、`ruby2_keywords` など)は、値ごとに、前の def のあとへ写します。
  ループ変数から作った名前は、`alias_method :refute_text, :assert_text` のように Symbol にします。
  ループがローカル変数に代入するとき、引数なしの `private` を呼ぶとき、`next`、`break`、`return` を使うときは書き直しません。
  ブロックとクラスの本体では、これらの意味が違うからです。
- ループの値をリテラルに置き換えるのは、読むたびに同じオブジェクトになるときだけです。
  Symbol、小さい Integer、nil、true、false、そして `# frozen_string_literal: true` のもとでの String です。
- ブロックが外側のローカル変数を共有しているときは書き直しません。
  def では意味が変わるものを使っているときも書き直しません。
  番号付きパラメーター、`it`、`yield`、`binding`、`local_variables`、`block_given?`、`eval`、引数なしの `super`、ループの外の `break` と `redo` です。
  メソッドを抜ける `next` は `return` に書き直します。
- 引数なしの `private`、`protected`、`module_function` のあとにある文字列 eval は書き直しません。
  文字列 eval で作った def は、そこでも public になるからです。
  文字列に def 以外のものがあるときも書き直しません。
  文字列の中のコードに文字列リテラルがあり、ファイルの `# frozen_string_literal:` で freeze するかどうかが変わるときも書き直しません。
  このマジックコメントは、文字列 eval でコンパイルするコードには効かないからです。

自動修正は RuboCop でいう unsafe です。
`define_method`、`class_eval`、`Array#each` が Ruby 本来のものだと仮定しているからです。
`rubocop -A` で実行してください。

決まりの全体は [docs/decisions/0001-exact-or-refused.md](docs/decisions/0001-exact-or-refused.md) にあります。

## 書き直しの確かめ方

`test/hegel/rewrite_test.rb` は hegeltest でクラスを作り、cop で直し、元のクラスと直したクラスを両方読み込みます。
そして Ruby が答える内容を比べます。
公開範囲ごとのメソッド名、引数、戻り値、呼び出しで設定されるインスタンス変数です。

## ライセンス

MIT です。
[LICENSE](LICENSE) を見てください。
