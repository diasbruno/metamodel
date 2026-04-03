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

defmodule MetaDslGeneratorOutputTest do
  use ExUnit.Case, async: true

  # A minimal generator that emits a valid Elixir module definition so that
  # compile/3 can be exercised end-to-end.
  defmodule ElixirModuleGenerator do
    @behaviour MetaDsl.Generator

    @impl true
    def generate(meta_types, _opts \\ []) do
      body =
        Enum.map_join(meta_types, "\n", fn t ->
          "  def #{t.name}, do: #{inspect(t.name)}"
        end)

      code = "defmodule MetaDslGeneratorOutputTest.Generated do\n#{body}\nend\n"
      {:ok, code}
    end
  end

  defmodule SimpleSchema do
    use MetaDsl

    meta_type :widget do
      property :id, :uuid, required: true
      property :label, :string
    end

    subtype :slim_widget, from: :widget, only: [:id]
  end

  test "compile/3 compiles generator output into live Elixir modules" do
    assert {:ok, modules} =
             MetaDsl.Generator.compile(ElixirModuleGenerator, SimpleSchema.meta_types())

    assert Enum.any?(modules, fn {mod, _bin} -> mod == MetaDslGeneratorOutputTest.Generated end)
    assert MetaDslGeneratorOutputTest.Generated.widget() == :widget
    assert MetaDslGeneratorOutputTest.Generated.slim_widget() == :slim_widget
  end

  test "compile/3 propagates generator errors" do
    defmodule FailingGenerator do
      @behaviour MetaDsl.Generator
      @impl true
      def generate(_meta_types, _opts), do: {:error, "something went wrong"}
    end

    assert {:error, "something went wrong"} =
             MetaDsl.Generator.compile(FailingGenerator, SimpleSchema.meta_types())
  end

  test "to_file/4 writes generator output to a file" do
    path = Path.join(System.tmp_dir!(), "metamodel_test_#{System.unique_integer()}.txt")

    on_exit(fn -> File.rm(path) end)

    assert :ok =
             MetaDsl.Generator.to_file(
               MetaDsl.Generators.Debug,
               SimpleSchema.meta_types(),
               path
             )

    content = File.read!(path)
    assert content =~ "type widget"
    assert content =~ "type slim_widget"
    assert content =~ "origin: project from widget"
  end

  test "to_file/4 propagates generator errors" do
    defmodule AnotherFailingGenerator do
      @behaviour MetaDsl.Generator
      @impl true
      def generate(_meta_types, _opts), do: {:error, :bad_input}
    end

    assert {:error, :bad_input} =
             MetaDsl.Generator.to_file(
               AnotherFailingGenerator,
               SimpleSchema.meta_types(),
               Path.join(System.tmp_dir!(), "should_not_be_created.txt")
             )

    refute File.exists?(Path.join(System.tmp_dir!(), "should_not_be_created.txt"))
  end
end
