defmodule MetaDslSingleFileTest do
  use ExUnit.Case, async: true

  defmodule BasicSchema do
    use MetaDsl

    meta_type :user do
      property :id, :uuid, required: true
      property :name, :string, required: true
      property :email, :string
    end

    subtype :public_user, from: :user, only: [:id, :name]

    extend_type :admin_user, from: :user do
      property :permissions, {:list, :string}, required: true
    end
  end
  
  test "declares and queries base meta types" do
    assert [%MetaDsl.MetaType{name: :admin_user},
            %MetaDsl.MetaType{name: :public_user},
            %MetaDsl.MetaType{name: :user}] =
             BasicSchema.meta_types()

    assert %MetaDsl.MetaType{name: :user, derived_from: nil} = BasicSchema.meta_type(:user)

    assert [
             %MetaDsl.Property{name: :id, type: :uuid, required: true},
             %MetaDsl.Property{name: :name, type: :string, required: true},
             %MetaDsl.Property{name: :email, type: :string, required: false}
           ] = BasicSchema.properties(:user)
  end

  test "builds a subtype using only selected properties" do
    assert %MetaDsl.MetaType{name: :public_user, derived_from: derivation} =
             BasicSchema.meta_type(:public_user)

    assert %MetaDsl.Derivation{kind: :project, from: :user} = derivation

    assert [:id, :name] =
             BasicSchema.properties(:public_user)
             |> Enum.map(& &1.name)
  end

  test "builds an extended type with inherited and extra properties" do
    admin_user = BasicSchema.meta_type(:admin_user)

    assert %MetaDsl.Derivation{kind: :extend, from: :user} = admin_user.derived_from

    assert [:id, :name, :email, :permissions] =
             admin_user.properties
             |> Enum.map(& &1.name)

    assert %MetaDsl.Property{name: :permissions, type: {:list, :string}, required: true} =
             List.last(admin_user.properties)
  end

  test "returns nil when querying an unknown meta type" do
    assert BasicSchema.meta_type(:missing) == nil
    assert BasicSchema.properties(:missing) == nil
  end

  test "exposes resolved representation through to_meta/0" do
    assert BasicSchema.to_meta() == BasicSchema.meta_types()
  end

  test "example debug generator consumes resolved meta types" do
    assert {:ok, output} = MetaDsl.Generators.Debug.generate(BasicSchema.meta_types())

    assert output =~ "type user"
    assert output =~ "type public_user"
    assert output =~ "origin: project from user"
    assert output =~ "permissions"
  end
end

defmodule MetaDslValidationSingleFileTest do
  use ExUnit.Case, async: true

  test "rejects duplicate type names" do
    assert_raise ArgumentError, ~r/duplicate type names/, fn ->
      Code.compile_string("""
      defmodule DuplicateTypeSchema do
        use MetaDsl

        meta_type :user do
          property :id, :uuid
        end

        meta_type :user do
          property :name, :string
        end
      end
      """)
    end
  end

  test "rejects duplicate property names in a declared type" do
    assert_raise ArgumentError, ~r/duplicate properties/, fn ->
      Code.compile_string("""
      defmodule DuplicatePropertySchema do
        use MetaDsl

        meta_type :user do
          property :id, :uuid
          property :id, :string
        end
      end
      """)
    end
  end

  test "rejects subtype with both only and except" do
    assert_raise ArgumentError, ~r/cannot define both :only and :except/, fn ->
      Code.compile_string("""
      defmodule InvalidSubtypeOptionsSchema do
        use MetaDsl

        meta_type :user do
          property :id, :uuid
          property :name, :string
        end

        subtype :public_user, from: :user, only: [:id], except: [:name]
      end
      """)
    end
  end

  test "rejects subtype when source type does not exist" do
    assert_raise ArgumentError, ~r/unknown source type :user/, fn ->
      Code.compile_string("""
      defmodule MissingSourceSchema do
        use MetaDsl

        subtype :public_user, from: :user, only: [:id]
      end
      """)
    end
  end

  test "rejects subtype when projecting unknown properties" do
    assert_raise ArgumentError, ~r/references unknown properties/, fn ->
      Code.compile_string("""
      defmodule MissingSubtypePropertySchema do
        use MetaDsl

        meta_type :user do
          property :id, :uuid
        end

        subtype :public_user, from: :user, only: [:id, :name]
      end
      """)
    end
  end

  test "rejects duplicate property names introduced by extension" do
    assert_raise ArgumentError, ~r/duplicate properties/, fn ->
      Code.compile_string("""
      defmodule InvalidExtensionSchema do
        use MetaDsl

        meta_type :user do
          property :id, :uuid
          property :name, :string
        end

        extend_type :admin_user, from: :user do
          property :name, :string
        end
      end
      """)
    end
  end
end
