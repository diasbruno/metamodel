defmodule MetaDsl.Generators.ElixirStructsTest do
  use ExUnit.Case, async: true

  alias MetaDsl.Generators.ElixirStructs
  alias MetaDsl.{MetaType, Property}

  defp prop(name, type, opts \\ []) do
    %Property{
      name: name,
      type: type,
      required: Keyword.get(opts, :required, false),
      default: Keyword.get(opts, :default, nil),
      annotations: %{}
    }
  end

  # ---------------------------------------------------------------------------
  # generate/1 — list input
  # ---------------------------------------------------------------------------

  test "returns empty list for empty meta types" do
    assert [] = ElixirStructs.generate([])
  end

  test "returns one quoted expression per meta type" do
    types = [
      %MetaType{name: :gen_list_thing_a, properties: []},
      %MetaType{name: :gen_list_thing_b, properties: []}
    ]

    assert length(ElixirStructs.generate(types)) == 2
  end

  test "generates struct modules with the correct fields (list)" do
    types = [
      %MetaType{
        name: :gen_list_article,
        properties: [prop(:id, :uuid), prop(:title, :string)]
      }
    ]

    [ast] = ElixirStructs.generate(types)
    Code.eval_quoted(ast)

    s = struct(GenListArticle)
    assert Map.has_key?(s, :id)
    assert Map.has_key?(s, :title)
    assert s.id == nil
    assert s.title == nil
  end

  test "applies default values to optional fields" do
    types = [
      %MetaType{
        name: :gen_scored,
        properties: [prop(:score, :float, default: 0.0), prop(:label, :string, default: "n/a")]
      }
    ]

    [ast] = ElixirStructs.generate(types)
    Code.eval_quoted(ast)

    s = struct(GenScored)
    assert s.score == 0.0
    assert s.label == "n/a"
  end

  test "includes @enforce_keys in the AST for required properties" do
    types = [
      %MetaType{
        name: :gen_required,
        properties: [
          prop(:id, :uuid, required: true),
          prop(:name, :string, required: true),
          prop(:notes, :string)
        ]
      }
    ]

    [ast] = ElixirStructs.generate(types)
    code = Macro.to_string(ast)
    assert code =~ "@enforce_keys"
    assert code =~ ":id"
    assert code =~ ":name"
  end

  test "omits @enforce_keys when no properties are required" do
    types = [
      %MetaType{
        name: :gen_optional,
        properties: [prop(:id, :uuid), prop(:name, :string)]
      }
    ]

    [ast] = ElixirStructs.generate(types)
    refute Macro.to_string(ast) =~ "@enforce_keys"
  end

  test "uses PascalCase module names derived from the meta-type atom" do
    types = [%MetaType{name: :snake_case_name, properties: []}]

    [ast] = ElixirStructs.generate(types)
    assert Macro.to_string(ast) =~ "SnakeCaseName"
  end

  test "generates independent struct modules for multiple meta types" do
    types = [
      %MetaType{name: :gen_cat, properties: [prop(:name, :string)]},
      %MetaType{name: :gen_dog, properties: [prop(:breed, :string)]}
    ]

    ElixirStructs.generate(types) |> Enum.each(&Code.eval_quoted/1)

    assert Map.has_key?(struct(GenCat), :name)
    assert Map.has_key?(struct(GenDog), :breed)
  end

  # ---------------------------------------------------------------------------
  # generate/1 — single MetaType input
  # ---------------------------------------------------------------------------

  test "accepts a single MetaType and returns a single quoted expression (not a list)" do
    meta_type = %MetaType{name: :gen_single_item, properties: [prop(:value, :integer)]}
    ast = ElixirStructs.generate(meta_type)
    refute is_list(ast)
    Code.eval_quoted(ast)
    assert Map.has_key?(struct(GenSingleItem), :value)
  end

  test "single MetaType with required field includes @enforce_keys" do
    meta_type = %MetaType{
      name: :gen_single_required,
      properties: [prop(:id, :uuid, required: true), prop(:note, :string)]
    }

    ast = ElixirStructs.generate(meta_type)
    assert Macro.to_string(ast) =~ "@enforce_keys"
  end

  # ---------------------------------------------------------------------------
  # use MetaDsl.Generators.ElixirStructs (compile-time macro)
  # ---------------------------------------------------------------------------

  defmodule CompileTimeSchema do
    use MetaDsl

    meta_type :ct_user do
      property(:id, :uuid, required: true)
      property(:name, :string, required: true)
      property(:role, :string, default: "member")
    end

    subtype(:ct_public_user, from: :ct_user, only: [:id, :name])

    extend_type :ct_admin_user, from: :ct_user do
      property(:permissions, {:list, :string}, required: true)
    end
  end

  # All types — structs are nested in this module's namespace.
  defmodule CompileTimeStructs do
    use MetaDsl.Generators.ElixirStructs,
      schema: MetaDsl.Generators.ElixirStructsTest.CompileTimeSchema
  end

  # Single type via type: atom
  defmodule SingleTypeStructs do
    use MetaDsl.Generators.ElixirStructs,
      schema: MetaDsl.Generators.ElixirStructsTest.CompileTimeSchema,
      type: :ct_user
  end

  # Subset via type: list
  defmodule SubsetStructs do
    use MetaDsl.Generators.ElixirStructs,
      schema: MetaDsl.Generators.ElixirStructsTest.CompileTimeSchema,
      type: [:ct_user, :ct_public_user]
  end

  test "use macro defines struct modules nested inside the calling module" do
    assert function_exported?(CompileTimeStructs.CtUser, :__struct__, 0)
    assert function_exported?(CompileTimeStructs.CtPublicUser, :__struct__, 0)
    assert function_exported?(CompileTimeStructs.CtAdminUser, :__struct__, 0)
  end

  test "use macro preserves all fields" do
    s = struct(CompileTimeStructs.CtUser)
    assert Map.has_key?(s, :id)
    assert Map.has_key?(s, :name)
    assert Map.has_key?(s, :role)
    assert s.role == "member"
  end

  test "use macro preserves projected fields for subtypes" do
    s = struct(CompileTimeStructs.CtPublicUser)
    assert Map.has_key?(s, :id)
    assert Map.has_key?(s, :name)
    refute Map.has_key?(s, :role)
  end

  test "use macro embeds @enforce_keys for required fields" do
    code =
      ElixirStructs.generate(CompileTimeSchema.meta_types())
      |> Enum.map(&Macro.to_string/1)
      |> Enum.join("\n")

    assert code =~ "@enforce_keys"
  end

  test "use macro with type: atom generates only the specified type" do
    assert function_exported?(SingleTypeStructs.CtUser, :__struct__, 0)
    refute function_exported?(SingleTypeStructs.CtPublicUser, :__struct__, 0)
    refute function_exported?(SingleTypeStructs.CtAdminUser, :__struct__, 0)
  end

  test "use macro with type: list generates only the specified types" do
    assert function_exported?(SubsetStructs.CtUser, :__struct__, 0)
    assert function_exported?(SubsetStructs.CtPublicUser, :__struct__, 0)
    refute function_exported?(SubsetStructs.CtAdminUser, :__struct__, 0)
  end

  test "use macro raises at compile time for unknown type: atom" do
    assert_raise ArgumentError, ~r/unknown type :nonexistent/, fn ->
      Code.compile_string("""
      defmodule BadSingleTypeStructs do
        use MetaDsl.Generators.ElixirStructs,
          schema: MetaDsl.Generators.ElixirStructsTest.CompileTimeSchema,
          type: :nonexistent
      end
      """)
    end
  end

  test "use macro raises at compile time for unknown type: list entries" do
    assert_raise ArgumentError, ~r/unknown types \[:missing_a, :missing_b\]/, fn ->
      Code.compile_string("""
      defmodule BadSubsetStructs do
        use MetaDsl.Generators.ElixirStructs,
          schema: MetaDsl.Generators.ElixirStructsTest.CompileTimeSchema,
          type: [:ct_user, :missing_a, :missing_b]
      end
      """)
    end
  end
end
