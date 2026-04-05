defmodule MetaDsl.EctoTest do
  use ExUnit.Case, async: true

  alias MetaDsl.Ecto, as: EctoGen
  alias MetaDsl.{MetaType, Property}

  defp prop(name, type, opts \\ []) do
    {ecto_type, opts} = Keyword.pop(opts, :ecto_type)

    annotations =
      if ecto_type,
        do: %{ecto_type: ecto_type},
        else: %{}

    %Property{
      name: name,
      type: type,
      required: Keyword.get(opts, :required, false),
      default: Keyword.get(opts, :default, nil),
      annotations: annotations
    }
  end

  # ---------------------------------------------------------------------------
  # generate/1 — list input
  # ---------------------------------------------------------------------------

  test "returns empty list for empty meta types" do
    assert [] = EctoGen.generate([])
  end

  test "returns one quoted expression per meta type" do
    types = [
      %MetaType{name: :ecto_thing_a, properties: []},
      %MetaType{name: :ecto_thing_b, properties: []}
    ]

    assert length(EctoGen.generate(types)) == 2
  end

  test "generates defmodule with use Ecto.Schema" do
    types = [%MetaType{name: :ecto_article, properties: [prop(:title, :string)]}]

    [ast] = EctoGen.generate(types)
    code = Macro.to_string(ast)

    assert code =~ "defmodule"
    assert code =~ "Ecto.Schema"
  end

  test "uses CamelCase module name derived from the meta-type atom" do
    types = [%MetaType{name: :blog_post, properties: []}]

    [ast] = EctoGen.generate(types)
    assert Macro.to_string(ast) =~ "BlogPost"
  end

  test "derives default table name by appending 's' to the type atom" do
    types = [%MetaType{name: :product, properties: []}]

    [ast] = EctoGen.generate(types)
    assert Macro.to_string(ast) =~ ~s("products")
  end

  test "uses custom table name from :table annotation" do
    types = [
      %MetaType{name: :order_item, properties: [], annotations: %{table: "line_items"}}
    ]

    [ast] = EctoGen.generate(types)
    assert Macro.to_string(ast) =~ ~s("line_items")
  end

  test "generates field declarations for all properties" do
    types = [
      %MetaType{
        name: :ecto_user,
        properties: [prop(:name, :string), prop(:age, :integer)]
      }
    ]

    [ast] = EctoGen.generate(types)
    code = Macro.to_string(ast)

    assert code =~ ":name"
    assert code =~ ":age"
  end

  test "maps {:list, :string} to {:array, :string}" do
    types = [
      %MetaType{name: :ecto_list_type, properties: [prop(:tags, {:list, :string})]}
    ]

    [ast] = EctoGen.generate(types)
    code = Macro.to_string(ast)

    assert code =~ "array"
    assert code =~ ":string"
  end

  test "respects :ecto_type annotation to override type mapping" do
    types = [
      %MetaType{
        name: :ecto_override_type,
        properties: [prop(:data, :string, ecto_type: :map)]
      }
    ]

    [ast] = EctoGen.generate(types)
    code = Macro.to_string(ast)

    assert code =~ ":map"
    refute code =~ ":string"
  end

  test "includes timestamps() when :timestamps annotation is true" do
    types = [
      %MetaType{
        name: :ecto_timestamps_type,
        properties: [prop(:title, :string)],
        annotations: %{timestamps: true}
      }
    ]

    [ast] = EctoGen.generate(types)
    code = Macro.to_string(ast)

    assert code =~ "timestamps()"
  end

  test "omits timestamps() when :timestamps annotation is false or absent" do
    types = [%MetaType{name: :ecto_no_timestamps, properties: [prop(:title, :string)]}]

    [ast] = EctoGen.generate(types)
    refute Macro.to_string(ast) =~ "timestamps()"
  end

  test "generates independent schema modules for multiple meta types" do
    types = [
      %MetaType{name: :ecto_cat, properties: [prop(:name, :string)]},
      %MetaType{name: :ecto_dog, properties: [prop(:breed, :string)]}
    ]

    asts = EctoGen.generate(types)
    codes = Enum.map(asts, &Macro.to_string/1)

    assert Enum.any?(codes, &(&1 =~ "EctoCat"))
    assert Enum.any?(codes, &(&1 =~ "EctoDog"))
  end

  # ---------------------------------------------------------------------------
  # generate/1 — single MetaType input
  # ---------------------------------------------------------------------------

  test "accepts a single MetaType and returns a single quoted expression (not a list)" do
    meta_type = %MetaType{name: :ecto_single, properties: [prop(:value, :integer)]}
    ast = EctoGen.generate(meta_type)
    refute is_list(ast)
    assert Macro.to_string(ast) =~ "EctoSingle"
  end

  # ---------------------------------------------------------------------------
  # type mapping coverage
  # ---------------------------------------------------------------------------

  for {meta_type, ecto_type} <- [
        {:string, ":string"},
        {:integer, ":integer"},
        {:float, ":float"},
        {:boolean, ":boolean"},
        {:uuid, ":binary_id"},
        {:decimal, ":decimal"},
        {:date, ":date"},
        {:time, ":time"},
        {:datetime, ":utc_datetime"},
        {:naive_datetime, ":naive_datetime"},
        {:map, ":map"}
      ] do
    test "maps :#{meta_type} to #{ecto_type}" do
      types = [
        %MetaType{
          name: :"ecto_type_#{unquote(meta_type)}",
          properties: [prop(:field, unquote(meta_type))]
        }
      ]

      [ast] = EctoGen.generate(types)
      assert Macro.to_string(ast) =~ unquote(ecto_type)
    end
  end

  test "passes through unknown types unchanged" do
    types = [
      %MetaType{name: :ecto_custom_type, properties: [prop(:thing, :my_custom_type)]}
    ]

    [ast] = EctoGen.generate(types)
    assert Macro.to_string(ast) =~ ":my_custom_type"
  end

  # ---------------------------------------------------------------------------
  # use MetaDsl.Ecto (compile-time macro)
  # ---------------------------------------------------------------------------

  defmodule CompileTimeSchema do
    use MetaDsl

    meta_type :ecto_ct_user do
      property(:id, :uuid, required: true)
      property(:name, :string, required: true)
      property(:role, :string, default: "member")
    end

    subtype(:ecto_ct_public_user, from: :ecto_ct_user, only: [:id, :name])

    extend_type :ecto_ct_admin_user, from: :ecto_ct_user do
      property(:permissions, {:list, :string}, required: true)
    end
  end

  test "use macro generates code containing Ecto.Schema for all types" do
    code =
      CompileTimeSchema.meta_types()
      |> EctoGen.generate()
      |> Enum.map(&Macro.to_string/1)
      |> Enum.join("\n")

    assert code =~ "Ecto.Schema"
  end

  test "use macro with type: atom generates only the specified type" do
    all_code =
      CompileTimeSchema.meta_types()
      |> EctoGen.generate()
      |> Enum.map(&Macro.to_string/1)
      |> Enum.join("\n")

    single_code =
      CompileTimeSchema.meta_type(:ecto_ct_user)
      |> EctoGen.generate()
      |> Macro.to_string()

    assert single_code =~ "EctoCtUser"
    refute single_code =~ "EctoCtPublicUser"
    assert all_code =~ "EctoCtPublicUser"
  end

  test "use macro raises at compile time for unknown type: atom" do
    assert_raise ArgumentError, ~r/unknown type :nonexistent/, fn ->
      Code.compile_string("""
      defmodule BadSingleEctoSchemas do
        use MetaDsl.Ecto,
          schema: MetaDsl.EctoTest.CompileTimeSchema,
          type: :nonexistent
      end
      """)
    end
  end

  test "use macro raises at compile time for unknown type: list entries" do
    assert_raise ArgumentError, ~r/unknown types \[:missing_a, :missing_b\]/, fn ->
      Code.compile_string("""
      defmodule BadSubsetEctoSchemas do
        use MetaDsl.Ecto,
          schema: MetaDsl.EctoTest.CompileTimeSchema,
          type: [:ecto_ct_user, :missing_a, :missing_b]
      end
      """)
    end
  end
end
