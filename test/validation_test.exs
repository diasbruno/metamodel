defmodule MetaDsl.ValidationTest do
  use ExUnit.Case, async: true

  alias MetaDsl.Validation
  alias MetaDsl.{MetaType, Property}

  defp prop(name, type, opts \\ []) do
    {validate, opts} = Keyword.pop(opts, :validate)

    %Property{
      name: name,
      type: type,
      required: Keyword.get(opts, :required, false),
      default: Keyword.get(opts, :default, nil),
      annotations: if(validate, do: %{validate: validate}, else: %{})
    }
  end

  # ---------------------------------------------------------------------------
  # generate/1 — list input
  # ---------------------------------------------------------------------------

  test "returns empty list for empty meta types" do
    assert [] = Validation.generate([])
  end

  test "returns one quoted expression per meta type" do
    types = [
      %MetaType{name: :val_list_thing_a, properties: []},
      %MetaType{name: :val_list_thing_b, properties: []}
    ]

    assert length(Validation.generate(types)) == 2
  end

  test "generates validator modules for multiple meta types (list)" do
    types = [
      %MetaType{
        name: :val_list_article,
        properties: [prop(:id, :uuid, required: true), prop(:title, :string)]
      }
    ]

    [ast] = Validation.generate(types)
    Code.eval_quoted(ast)

    assert {:ok, _} = ValListArticle.validate(%{id: "some-id", title: "Hello"})
    assert {:error, [{:id, "is required"}]} = ValListArticle.validate(%{id: nil, title: "Hello"})
  end

  test "returns ok when all required fields are present" do
    types = [
      %MetaType{
        name: :val_all_required,
        properties: [
          prop(:id, :uuid, required: true),
          prop(:name, :string, required: true)
        ]
      }
    ]

    [ast] = Validation.generate(types)
    Code.eval_quoted(ast)

    assert {:ok, _} = ValAllRequired.validate(%{id: "1", name: "Alice"})
  end

  test "returns error listing all missing required fields" do
    types = [
      %MetaType{
        name: :val_missing_required,
        properties: [
          prop(:id, :uuid, required: true),
          prop(:name, :string, required: true),
          prop(:notes, :string)
        ]
      }
    ]

    [ast] = Validation.generate(types)
    Code.eval_quoted(ast)

    assert {:error, errors} = ValMissingRequired.validate(%{id: nil, name: nil, notes: "ok"})
    assert {:id, "is required"} in errors
    assert {:name, "is required"} in errors
    assert length(errors) == 2
  end

  test "preserves declaration order in the error list" do
    types = [
      %MetaType{
        name: :val_ordered_errors,
        properties: [
          prop(:first, :string, required: true),
          prop(:second, :string, required: true),
          prop(:third, :string, required: true)
        ]
      }
    ]

    [ast] = Validation.generate(types)
    Code.eval_quoted(ast)

    assert {:error, [{:first, "is required"}, {:second, "is required"}, {:third, "is required"}]} =
             ValOrderedErrors.validate(%{})
  end

  test "optional nil fields do not produce errors" do
    types = [
      %MetaType{
        name: :val_optional_fields,
        properties: [
          prop(:id, :uuid, required: true),
          prop(:notes, :string)
        ]
      }
    ]

    [ast] = Validation.generate(types)
    Code.eval_quoted(ast)

    assert {:ok, _} = ValOptionalFields.validate(%{id: "1"})
    assert {:ok, _} = ValOptionalFields.validate(%{id: "1", notes: nil})
  end

  test "uses PascalCase module names derived from the meta-type atom" do
    types = [%MetaType{name: :snake_case_val, properties: []}]

    [ast] = Validation.generate(types)
    assert Macro.to_string(ast) =~ "SnakeCaseVal"
  end

  test "generates independent validator modules for multiple meta types" do
    types = [
      %MetaType{name: :val_cat, properties: [prop(:name, :string, required: true)]},
      %MetaType{name: :val_dog, properties: [prop(:breed, :string, required: true)]}
    ]

    Validation.generate(types) |> Enum.each(&Code.eval_quoted/1)

    assert {:error, [{:name, "is required"}]} = ValCat.validate(%{})
    assert {:error, [{:breed, "is required"}]} = ValDog.validate(%{})
  end

  test "validate/1 returns the original data in the ok tuple" do
    types = [
      %MetaType{
        name: :val_returns_data,
        properties: [prop(:id, :uuid, required: true)]
      }
    ]

    [ast] = Validation.generate(types)
    Code.eval_quoted(ast)

    data = %{id: "abc-123"}
    assert {:ok, ^data} = ValReturnsData.validate(data)
  end

  defmodule SampleStruct do
    defstruct [:id, :name]
  end

  test "validate/1 accepts a struct as input" do
    types = [
      %MetaType{
        name: :val_struct_input,
        properties: [prop(:id, :uuid, required: true), prop(:name, :string, required: true)]
      }
    ]

    [ast] = Validation.generate(types)
    Code.eval_quoted(ast)

    assert {:ok, _} = ValStructInput.validate(%SampleStruct{id: "1", name: "Alice"})

    assert {:error, [{:id, "is required"}]} =
             ValStructInput.validate(%SampleStruct{id: nil, name: "Alice"})
  end

  # ---------------------------------------------------------------------------
  # generate/1 — single MetaType input
  # ---------------------------------------------------------------------------

  test "accepts a single MetaType and returns a single quoted expression (not a list)" do
    meta_type = %MetaType{
      name: :val_single_item,
      properties: [prop(:value, :integer, required: true)]
    }

    ast = Validation.generate(meta_type)
    refute is_list(ast)
    Code.eval_quoted(ast)

    assert {:ok, _} = ValSingleItem.validate(%{value: 42})
    assert {:error, [{:value, "is required"}]} = ValSingleItem.validate(%{value: nil})
  end

  test "single MetaType with no required fields always returns ok" do
    meta_type = %MetaType{
      name: :val_single_optional,
      properties: [prop(:note, :string)]
    }

    ast = Validation.generate(meta_type)
    Code.eval_quoted(ast)

    assert {:ok, _} = ValSingleOptional.validate(%{})
    assert {:ok, _} = ValSingleOptional.validate(%{note: nil})
  end

  # ---------------------------------------------------------------------------
  # Custom validators via :validate annotation
  # ---------------------------------------------------------------------------

  test "custom validator returning :ok marks the field as valid" do
    types = [
      %MetaType{
        name: :val_custom_ok,
        properties: [prop(:code, :string, validate: fn _v -> :ok end)]
      }
    ]

    [ast] = Validation.generate(types)
    Code.eval_quoted(ast)

    assert {:ok, _} = ValCustomOk.validate(%{code: "anything"})
    assert {:ok, _} = ValCustomOk.validate(%{code: nil})
  end

  test "custom validator returning {:error, reason} includes reason in errors" do
    validator = fn v ->
      if is_binary(v) and String.length(v) == 3,
        do: :ok,
        else: {:error, "must be 3 characters"}
    end

    types = [
      %MetaType{
        name: :val_custom_error,
        properties: [prop(:code, :string, validate: validator)]
      }
    ]

    [ast] = Validation.generate(types)
    Code.eval_quoted(ast)

    assert {:ok, _} = ValCustomError.validate(%{code: "ABC"})
    assert {:error, [{:code, "must be 3 characters"}]} = ValCustomError.validate(%{code: "AB"})
    assert {:error, [{:code, "must be 3 characters"}]} = ValCustomError.validate(%{code: nil})
  end

  test "custom validator returning true/false uses default 'is invalid' message" do
    types = [
      %MetaType{
        name: :val_bool_validator,
        properties: [prop(:score, :integer, validate: fn v -> is_integer(v) and v >= 0 end)]
      }
    ]

    [ast] = Validation.generate(types)
    Code.eval_quoted(ast)

    assert {:ok, _} = ValBoolValidator.validate(%{score: 5})
    assert {:error, [{:score, "is invalid"}]} = ValBoolValidator.validate(%{score: -1})
    assert {:error, [{:score, "is invalid"}]} = ValBoolValidator.validate(%{score: nil})
  end

  test "required field with custom validator: nil yields 'is required', not custom error" do
    validator = fn v ->
      if is_binary(v) and String.length(v) > 0, do: :ok, else: {:error, "must be non-empty"}
    end

    types = [
      %MetaType{
        name: :val_required_with_custom,
        properties: [prop(:name, :string, required: true, validate: validator)]
      }
    ]

    [ast] = Validation.generate(types)
    Code.eval_quoted(ast)

    assert {:ok, _} = ValRequiredWithCustom.validate(%{name: "Alice"})
    assert {:error, [{:name, "is required"}]} = ValRequiredWithCustom.validate(%{name: nil})
    assert {:error, [{:name, "must be non-empty"}]} = ValRequiredWithCustom.validate(%{name: ""})
  end

  test "multiple properties with mixed validators accumulate errors in order" do
    types = [
      %MetaType{
        name: :val_multi_validators,
        properties: [
          prop(:id, :string, required: true),
          prop(:code, :string,
            validate: fn v -> if v == "ok", do: :ok, else: {:error, "bad code"} end
          ),
          prop(:count, :integer, required: true)
        ]
      }
    ]

    [ast] = Validation.generate(types)
    Code.eval_quoted(ast)

    assert {:ok, _} = ValMultiValidators.validate(%{id: "1", code: "ok", count: 3})

    assert {:error, [{:id, "is required"}, {:code, "bad code"}, {:count, "is required"}]} =
             ValMultiValidators.validate(%{id: nil, code: "bad", count: nil})
  end

  # ---------------------------------------------------------------------------
  # use MetaDsl.Validation (compile-time macro)
  # ---------------------------------------------------------------------------

  defmodule CompileTimeSchema do
    use MetaDsl

    meta_type :val_user do
      property(:id, :uuid, required: true)
      property(:name, :string, required: true)
      property(:role, :string, default: "member")
    end

    subtype(:val_public_user, from: :val_user, only: [:id, :name])

    extend_type :val_admin_user, from: :val_user do
      property(:permissions, {:list, :string}, required: true)
    end
  end

  defmodule CompileTimeSchemaWithValidator do
    use MetaDsl

    meta_type :val_item do
      property(:code, :string,
        required: true,
        validate: fn v ->
          if is_binary(v) and String.length(v) == 3, do: :ok, else: {:error, "must be 3 chars"}
        end
      )
      property(:count, :integer)
    end
  end

  # All types — validators are nested in this module's namespace.
  defmodule CompileTimeValidators do
    use MetaDsl.Validation,
      schema: MetaDsl.ValidationTest.CompileTimeSchema
  end

  defmodule CompileTimeValidatorsWithAnnotation do
    use MetaDsl.Validation,
      schema: MetaDsl.ValidationTest.CompileTimeSchemaWithValidator
  end

  # Single type via type: atom
  defmodule SingleTypeValidators do
    use MetaDsl.Validation,
      schema: MetaDsl.ValidationTest.CompileTimeSchema,
      type: :val_user
  end

  # Subset via type: list
  defmodule SubsetValidators do
    use MetaDsl.Validation,
      schema: MetaDsl.ValidationTest.CompileTimeSchema,
      type: [:val_user, :val_public_user]
  end

  test "use macro defines validator modules nested inside the calling module" do
    assert function_exported?(CompileTimeValidators.ValUser, :validate, 1)
    assert function_exported?(CompileTimeValidators.ValPublicUser, :validate, 1)
    assert function_exported?(CompileTimeValidators.ValAdminUser, :validate, 1)
  end

  test "use macro generates working validators for required fields" do
    assert {:ok, _} =
             CompileTimeValidators.ValUser.validate(%{id: "1", name: "Alice", role: "member"})

    assert {:error, errors} =
             CompileTimeValidators.ValUser.validate(%{id: nil, name: "Alice"})

    assert {:id, "is required"} in errors
  end

  test "use macro validates only projected fields in subtypes" do
    assert {:ok, _} = CompileTimeValidators.ValPublicUser.validate(%{id: "1", name: "Alice"})

    assert {:error, [{:id, "is required"}]} =
             CompileTimeValidators.ValPublicUser.validate(%{id: nil, name: "Alice"})

    # :role is not part of val_public_user, so its absence is not an error
    assert {:ok, _} =
             CompileTimeValidators.ValPublicUser.validate(%{id: "1", name: "Alice", role: nil})
  end

  test "use macro validates extended type with extra required fields" do
    assert {:error, errors} =
             CompileTimeValidators.ValAdminUser.validate(%{id: "1", name: "Alice"})

    assert {:permissions, "is required"} in errors
  end

  test "use macro picks up :validate annotation from DSL property declaration" do
    assert {:ok, _} =
             CompileTimeValidatorsWithAnnotation.ValItem.validate(%{code: "ABC", count: 1})

    assert {:error, [{:code, "is required"}]} =
             CompileTimeValidatorsWithAnnotation.ValItem.validate(%{code: nil})

    assert {:error, [{:code, "must be 3 chars"}]} =
             CompileTimeValidatorsWithAnnotation.ValItem.validate(%{code: "AB"})
  end

  test "use macro with type: atom generates only the specified type" do
    assert function_exported?(SingleTypeValidators.ValUser, :validate, 1)
    refute function_exported?(SingleTypeValidators.ValPublicUser, :validate, 1)
    refute function_exported?(SingleTypeValidators.ValAdminUser, :validate, 1)
  end

  test "use macro with type: list generates only the specified types" do
    assert function_exported?(SubsetValidators.ValUser, :validate, 1)
    assert function_exported?(SubsetValidators.ValPublicUser, :validate, 1)
    refute function_exported?(SubsetValidators.ValAdminUser, :validate, 1)
  end

  test "use macro raises at compile time for unknown type: atom" do
    assert_raise ArgumentError, ~r/unknown type :nonexistent/, fn ->
      Code.compile_string("""
      defmodule BadSingleTypeValidators do
        use MetaDsl.Validation,
          schema: MetaDsl.ValidationTest.CompileTimeSchema,
          type: :nonexistent
      end
      """)
    end
  end

  test "use macro raises at compile time for unknown type: list entries" do
    assert_raise ArgumentError, ~r/unknown types \[:missing_a, :missing_b\]/, fn ->
      Code.compile_string("""
      defmodule BadSubsetValidators do
        use MetaDsl.Validation,
          schema: MetaDsl.ValidationTest.CompileTimeSchema,
          type: [:val_user, :missing_a, :missing_b]
      end
      """)
    end
  end
end
