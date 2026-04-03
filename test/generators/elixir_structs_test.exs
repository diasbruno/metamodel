defmodule MetaDsl.Generators.ElixirStructsTest do
  use ExUnit.Case, async: true

  alias MetaDsl.Generators.ElixirStructs
  alias MetaDsl.{MetaType, Property}

  # Unique namespace so eval'd modules don't collide with anything else.
  @ns MetaDsl.Test.ElixirStructs

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
  # generate/2
  # ---------------------------------------------------------------------------

  test "returns empty list for empty meta types" do
    assert [] = ElixirStructs.generate([])
  end

  test "returns one quoted expression per meta type" do
    types = [
      %MetaType{name: :gen_thing_a, properties: []},
      %MetaType{name: :gen_thing_b, properties: []}
    ]

    assert length(ElixirStructs.generate(types)) == 2
  end

  test "generates a struct module with the correct fields" do
    types = [
      %MetaType{
        name: :gen_article,
        properties: [prop(:id, :uuid), prop(:title, :string)]
      }
    ]

    [ast] = ElixirStructs.generate(types, namespace: @ns)
    Code.eval_quoted(ast)

    mod = Module.concat(@ns, "GenArticle")
    s = struct(mod)
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

    [ast] = ElixirStructs.generate(types, namespace: @ns)
    Code.eval_quoted(ast)

    mod = Module.concat(@ns, "GenScored")
    s = struct(mod)
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

  test "applies namespace option to the generated module name" do
    types = [%MetaType{name: :gen_entity, properties: [prop(:id, :uuid)]}]

    [ast] = ElixirStructs.generate(types, namespace: @ns)
    Code.eval_quoted(ast)

    mod = Module.concat(@ns, "GenEntity")
    assert struct(mod).__struct__ == mod
  end

  test "generates independent struct modules for multiple meta types" do
    types = [
      %MetaType{name: :gen_cat, properties: [prop(:name, :string)]},
      %MetaType{name: :gen_dog, properties: [prop(:breed, :string)]}
    ]

    asts = ElixirStructs.generate(types, namespace: @ns)
    Enum.each(asts, &Code.eval_quoted/1)

    cat = struct(Module.concat(@ns, "GenCat"))
    dog = struct(Module.concat(@ns, "GenDog"))
    assert Map.has_key?(cat, :name)
    assert Map.has_key?(dog, :breed)
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
  end

  defmodule CompileTimeStructs do
    use MetaDsl.Generators.ElixirStructs,
      schema: MetaDsl.Generators.ElixirStructsTest.CompileTimeSchema
  end

  test "use macro defines struct modules under the calling module's namespace" do
    assert function_exported?(CompileTimeStructs.CtUser, :__struct__, 0)
    assert function_exported?(CompileTimeStructs.CtPublicUser, :__struct__, 0)
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
      ElixirStructs.generate(
        CompileTimeSchema.meta_types(),
        namespace: CompileTimeStructs
      )
      |> Enum.map(&Macro.to_string/1)
      |> Enum.join("\n")

    assert code =~ "@enforce_keys"
  end
end
