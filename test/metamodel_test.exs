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

defmodule MetaDslSharedUserModelTest do
  use ExUnit.Case, async: true

  defmodule FullSchema do
    use MetaDsl

    meta_type :user do
      property :id,            :uuid,     required: true
      property :name,          :string,   required: true
      property :email,         :string,   required: true
      property :password_hash, :string,   required: true
      property :role,          :string,   required: true
      property :inserted_at,   :datetime, required: true
    end

    # Option A — CRUD input shapes
    subtype :create_user, from: :user, except: [:id, :inserted_at]
    subtype :update_user, from: :user, only:   [:id, :name, :email]
    subtype :delete_user, from: :user, only:   [:id]

    # Option B — API response shapes
    subtype :public_user,  from: :user, only:   [:id, :name]
    subtype :session_user, from: :user, except: [:password_hash]

    extend_type :admin_user, from: :user do
      property :permissions, {:list, :string}, required: true
    end

    # Option C — domain events
    extend_type :user_created_event, from: :user do
      property :occurred_at, :datetime, required: true
    end

    subtype :user_deleted_event, from: :user, only: [:id]
  end

  # Option A — CRUD input shapes

  test "create_user excludes server-generated fields" do
    assert %MetaDsl.MetaType{derived_from: %MetaDsl.Derivation{kind: :project, from: :user}} =
             FullSchema.meta_type(:create_user)

    assert [:name, :email, :password_hash, :role] =
             FullSchema.properties(:create_user) |> Enum.map(& &1.name)
  end

  test "update_user contains only the key and editable fields" do
    assert %MetaDsl.MetaType{derived_from: %MetaDsl.Derivation{kind: :project, from: :user}} =
             FullSchema.meta_type(:update_user)

    assert [:id, :name, :email] =
             FullSchema.properties(:update_user) |> Enum.map(& &1.name)
  end

  test "delete_user contains only the key" do
    assert [:id] =
             FullSchema.properties(:delete_user) |> Enum.map(& &1.name)
  end

  # Option B — API response shapes

  test "public_user exposes only safe fields for anonymous visitors" do
    assert [:id, :name] =
             FullSchema.properties(:public_user) |> Enum.map(& &1.name)
  end

  test "session_user omits the password hash" do
    assert %MetaDsl.MetaType{derived_from: %MetaDsl.Derivation{kind: :project, from: :user}} =
             FullSchema.meta_type(:session_user)

    refute :password_hash in (FullSchema.properties(:session_user) |> Enum.map(& &1.name))

    assert [:id, :name, :email, :role, :inserted_at] =
             FullSchema.properties(:session_user) |> Enum.map(& &1.name)
  end

  test "admin_user inherits all user fields and adds permissions" do
    assert %MetaDsl.MetaType{derived_from: %MetaDsl.Derivation{kind: :extend, from: :user}} =
             FullSchema.meta_type(:admin_user)

    assert [:id, :name, :email, :password_hash, :role, :inserted_at, :permissions] =
             FullSchema.properties(:admin_user) |> Enum.map(& &1.name)

    assert %MetaDsl.Property{name: :permissions, type: {:list, :string}, required: true} =
             List.last(FullSchema.properties(:admin_user))
  end

  # Option C — domain events

  test "user_created_event carries a full user snapshot plus occurred_at" do
    assert %MetaDsl.MetaType{derived_from: %MetaDsl.Derivation{kind: :extend, from: :user}} =
             FullSchema.meta_type(:user_created_event)

    assert [:id, :name, :email, :password_hash, :role, :inserted_at, :occurred_at] =
             FullSchema.properties(:user_created_event) |> Enum.map(& &1.name)

    assert %MetaDsl.Property{name: :occurred_at, type: :datetime, required: true} =
             List.last(FullSchema.properties(:user_created_event))
  end

  test "user_deleted_event carries only the identity" do
    assert %MetaDsl.MetaType{derived_from: %MetaDsl.Derivation{kind: :project, from: :user}} =
             FullSchema.meta_type(:user_deleted_event)

    assert [:id] =
             FullSchema.properties(:user_deleted_event) |> Enum.map(& &1.name)
  end

  test "all nine types are registered" do
    names = FullSchema.meta_types() |> Enum.map(& &1.name)

    assert :user               in names
    assert :create_user        in names
    assert :update_user        in names
    assert :delete_user        in names
    assert :public_user        in names
    assert :session_user       in names
    assert :admin_user         in names
    assert :user_created_event in names
    assert :user_deleted_event in names
  end

  test "meta_types/0 returns types sorted by name" do
    names = FullSchema.meta_types() |> Enum.map(& &1.name)
    assert names == Enum.sort(names)
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

defmodule MetaDslTypeScriptGeneratorTest do
  use ExUnit.Case, async: true

  defmodule Schema do
    use MetaDsl

    meta_type :user do
      property :id,          :uuid,    required: true
      property :name,        :string,  required: true
      property :score,       :float
      property :active,      :boolean
      property :age,         :integer
      property :inserted_at, :datetime
    end

    subtype :public_user, from: :user, only: [:id, :name]

    extend_type :admin_user, from: :user do
      property :permissions, {:list, :string}, required: true
    end
  end

  test "generates TypeScript interfaces for all types" do
    assert {:ok, output} = MetaDsl.Generators.TypeScript.generate(Schema.meta_types())

    assert output =~ "interface AdminUser {"
    assert output =~ "interface PublicUser {"
    assert output =~ "interface User {"
  end

  test "generates a single TypeScript interface when :name option is given" do
    assert {:ok, output} =
             MetaDsl.Generators.TypeScript.generate(Schema.meta_types(), name: :user)

    assert output =~ "interface User {"
    refute output =~ "interface AdminUser {"
    refute output =~ "interface PublicUser {"
  end

  test "returns empty string for an unknown :name option" do
    assert {:ok, ""} =
             MetaDsl.Generators.TypeScript.generate(Schema.meta_types(), name: :missing)
  end

  test "required properties have no question mark" do
    assert {:ok, output} =
             MetaDsl.Generators.TypeScript.generate(Schema.meta_types(), name: :user)

    assert output =~ "  id: string;"
    assert output =~ "  name: string;"
  end

  test "optional properties have a question mark suffix on the key" do
    assert {:ok, output} =
             MetaDsl.Generators.TypeScript.generate(Schema.meta_types(), name: :user)

    assert output =~ "  score?: number;"
    assert output =~ "  active?: boolean;"
    assert output =~ "  age?: number;"
    assert output =~ "  inserted_at?: string;"
  end

  test "maps list types to TypeScript array syntax" do
    assert {:ok, output} =
             MetaDsl.Generators.TypeScript.generate(Schema.meta_types(), name: :admin_user)

    assert output =~ "  permissions: string[];"
  end

  test "generates a subtype with only the projected properties" do
    assert {:ok, output} =
             MetaDsl.Generators.TypeScript.generate(Schema.meta_types(), name: :public_user)

    assert output =~ "interface PublicUser {"
    assert output =~ "  id: string;"
    assert output =~ "  name: string;"
    refute output =~ "score"
    refute output =~ "active"
  end

  test "converts snake_case atom names to PascalCase interface names" do
    assert {:ok, output} = MetaDsl.Generators.TypeScript.generate(Schema.meta_types())

    assert output =~ "interface AdminUser {"
    assert output =~ "interface PublicUser {"
    assert output =~ "interface User {"
  end
end
