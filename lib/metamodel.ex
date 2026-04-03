defmodule MetaDsl.Property do
  @moduledoc """
  Canonical property representation used by the DSL and generators.

  A `MetaDsl.Property` captures everything there is to know about a single
  field on a meta-type: its name, its type term, whether the field is
  required, an optional default value, and a free-form annotations map that
  generators can use for custom metadata.

  ## Fields

    * `:name` – atom identifying the property (required).
    * `:type` – any term describing the type, e.g. `:string`, `:uuid`,
      `{:list, :string}`.
    * `:required` – whether the property must be present; defaults to
      `false`.
    * `:default` – optional default value; defaults to `nil`.
    * `:annotations` – free-form map of extra metadata for generators;
      defaults to `%{}`.

  Properties are never constructed directly by callers. They are produced
  by the `property/2` and `property/3` macros inside `meta_type` or
  `extend_type` blocks.
  """

  @enforce_keys [:name, :type]
  defstruct [
    :name,
    :type,
    required: false,
    default: nil,
    annotations: %{}
  ]

  @type t :: %__MODULE__{
          name: atom(),
          type: term(),
          required: boolean(),
          default: term(),
          annotations: map()
        }
end

defmodule MetaDsl.Derivation do
  @moduledoc """
  Provenance information for meta-types derived from other meta-types.

  When a type is created with `subtype/2` or `extend_type/3`, the resulting
  `MetaDsl.MetaType` struct carries a `MetaDsl.Derivation` in its
  `:derived_from` field so that generators and tooling can trace where a
  type came from.

  ## Fields

    * `:kind` – one of `:project` (produced by `subtype/2`) or `:extend`
      (produced by `extend_type/3`).
    * `:from` – the atom name of the source type this type was derived
      from.
    * `:opts` – a map of extra derivation options (e.g. the `:only` /
      `:except` lists for `:project` derivations).

  Base types declared with `meta_type/2` have `derived_from: nil` on their
  `MetaDsl.MetaType` struct.
  """

  defstruct [
    :kind,
    :from,
    opts: %{}
  ]

  @type t :: %__MODULE__{
          kind: :project | :extend,
          from: atom(),
          opts: map()
        }
end

defmodule MetaDsl.MetaType do
  @moduledoc """
  Canonical meta-type representation.

  Every declared or derived type is resolved to a `MetaDsl.MetaType` struct
  before it is handed to generators.  This struct is the stable intermediate
  representation that the rest of the system works with.

  ## Fields

    * `:name` – atom identifying the type (required).
    * `:properties` – ordered list of `MetaDsl.Property` structs.
    * `:annotations` – free-form map of extra metadata for generators;
      defaults to `%{}`.
    * `:derived_from` – `nil` for base types declared with `meta_type/2`,
      or a `MetaDsl.Derivation` struct for types produced by `subtype/2` /
      `extend_type/3`.

  ## Example

      %MetaDsl.MetaType{
        name: :admin_user,
        properties: [...],
        derived_from: %MetaDsl.Derivation{kind: :extend, from: :user}
      }
  """

  @enforce_keys [:name]
  defstruct [
    :name,
    properties: [],
    annotations: %{},
    derived_from: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          properties: [MetaDsl.Property.t()],
          annotations: map(),
          derived_from: nil | MetaDsl.Derivation.t()
        }
end

defmodule MetaDsl.Generator do
  @moduledoc """
  Behaviour and utilities for code generators that consume resolved meta-types.

  Any module that wants to act as a MetaDsl generator must adopt this
  behaviour and implement the `c:generate/2` callback.

  ## Implementing a generator

      defmodule MyApp.Generators.TypeScript do
        @behaviour MetaDsl.Generator

        @impl true
        def generate(meta_types, _opts \\\\ []) do
          # ... render TypeScript interfaces from meta_types ...
          {:ok, rendered}
        end
      end

  The callback receives a list of fully resolved `MetaDsl.MetaType` structs
  (sorted by name) and a keyword list of generator-specific options.  It
  must return `{:ok, iodata()}` on success or `{:error, term()}` on
  failure.

  ## Choosing an output mode

  Once a generator has produced its output you can direct it to one of two
  destinations:

    * **Compile** — pass the generated Elixir source to the Elixir compiler
      so that the resulting modules are immediately available in the runtime:

          {:ok, modules} =
            MetaDsl.Generator.compile(MyApp.Generators.Structs, schema.meta_types())

    * **File** — write the generated source (or any other text) to a path on
      disk so that it can be committed, formatted, or compiled later:

          :ok =
            MetaDsl.Generator.to_file(MyApp.Generators.Structs, schema.meta_types(), "lib/generated.ex")

  Both helpers delegate to `generate/2` internally and propagate any
  `{:error, reason}` the generator returns.
  """

  @callback generate([MetaDsl.MetaType.t()], keyword()) ::
              {:ok, iodata()} | {:error, term()}

  @doc """
  Runs `generator_module.generate/2` and compiles the resulting Elixir source.

  The iodata returned by the generator is converted to a binary and passed to
  `Code.compile_string/2`.  On success the list of `{module, binary}` tuples
  produced by the compiler is returned inside `{:ok, ...}`.

  ## Examples

      {:ok, modules} =
        MetaDsl.Generator.compile(MetaDsl.Generators.Debug, schema.meta_types())

  """
  @spec compile(module(), [MetaDsl.MetaType.t()], keyword()) ::
          {:ok, [{module(), binary()}]} | {:error, term()}
  def compile(generator_module, meta_types, opts \\ []) do
    with {:ok, code} <- generator_module.generate(meta_types, opts) do
      {:ok, Code.compile_string(IO.iodata_to_binary(code))}
    end
  end

  @doc """
  Runs `generator_module.generate/2` and writes the output to `path`.

  The iodata returned by the generator is written atomically to the given
  file path using `File.write/2`.  Returns `:ok` on success or
  `{:error, reason}` on failure (either from the generator or from the file
  system).

  ## Examples

      :ok =
        MetaDsl.Generator.to_file(
          MetaDsl.Generators.Debug,
          schema.meta_types(),
          "priv/schema_debug.txt"
        )

  """
  @spec to_file(module(), [MetaDsl.MetaType.t()], Path.t(), keyword()) ::
          :ok | {:error, term()}
  def to_file(generator_module, meta_types, path, opts \\ []) do
    with {:ok, code} <- generator_module.generate(meta_types, opts) do
      File.write(path, code)
    end
  end
end

defmodule MetaDsl do
  @moduledoc """
  A DSL for defining generator-agnostic meta-types and deriving new types
  from existing ones.

  `MetaDsl` lets you declare a schema of typed properties once and then
  project or extend it into as many derived types as you need.  The library
  builds a stable intermediate representation (a list of
  `MetaDsl.MetaType` structs) that can be consumed by any module that
  implements the `MetaDsl.Generator` behaviour.

  ## Quick start

      defmodule MyApp.Schema do
        use MetaDsl

        meta_type :user do
          property :id,            :uuid,     required: true
          property :name,          :string,   required: true
          property :email,         :string,   required: true
          property :password_hash, :string,   required: true
          property :role,          :string,   required: true
          property :inserted_at,   :datetime, required: true
        end

        # Keep only a subset of properties
        subtype :create_user, from: :user, except: [:id, :inserted_at]
        subtype :update_user, from: :user, only:   [:id, :name, :email]

        # Add extra properties on top of an existing type
        extend_type :admin_user, from: :user do
          property :permissions, {:list, :string}, required: true
        end
      end

      MyApp.Schema.meta_types()
      #=> [%MetaDsl.MetaType{name: :admin_user, ...}, ...]

      MyApp.Schema.meta_type(:admin_user)
      #=> %MetaDsl.MetaType{name: :admin_user, derived_from: %MetaDsl.Derivation{kind: :extend, from: :user}, ...}

      MyApp.Schema.properties(:update_user) |> Enum.map(& &1.name)
      #=> [:id, :name, :email]

  ## Macros overview

  | Macro | Description |
  |---|---|
  | `meta_type/2` | Declares a base type with an explicit list of properties |
  | `property/2`, `property/3` | Declares a single property inside `meta_type` or `extend_type` |
  | `subtype/2` | Derives a type by projecting properties with `:only` or `:except` |
  | `extend_type/3` | Derives a type by inheriting all properties and appending new ones |

  ## Runtime query functions

  Modules that `use MetaDsl` automatically gain the following functions:

  | Function | Description |
  |---|---|
  | `meta_types/0` | All registered types sorted by name |
  | `meta_type/1` | Look up a single type by atom name |
  | `properties/1` | List the properties of a type by atom name |
  | `to_meta/0` | Alias for `meta_types/0` |

  ## Derivation kinds

  | Macro | `:derived_from` kind | Description |
  |---|---|---|
  | `meta_type … do … end` | `nil` | Declares a base type with no derivation |
  | `subtype …, only: [...]` | `:project` | Keep only the listed properties |
  | `subtype …, except: [...]` | `:project` | Drop the listed properties |
  | `extend_type … do … end` | `:extend` | Inherit all properties and append new ones |
  """

  alias MetaDsl.{Derivation, MetaType, Property}

  defmacro __using__(_opts) do
    quote do
      import MetaDsl

      Module.register_attribute(__MODULE__, :meta_dsl_defs, accumulate: true)

      @before_compile MetaDsl
    end
  end

  @doc """
  Declares a base meta-type with a block of `property` declarations.

  The `name` must be a unique atom within the schema module.  Every property
  inside the `do` block must be declared with `property/2` or `property/3`.

  ## Example

      meta_type :user do
        property :id,   :uuid,   required: true
        property :name, :string, required: true
      end
  """
  defmacro meta_type(name, do: block) when is_atom(name) do
    properties = extract_properties!(block, __CALLER__)

    quote bind_quoted: [name: name, properties: Macro.escape(properties)] do
      @meta_dsl_defs {:meta_type, name, properties, %{}}
    end
  end

  @doc """
  Derives a new type by projecting properties from an existing type.

  Requires exactly one of:

    * `:only` – keep only the listed property names.
    * `:except` – drop the listed property names and keep the rest.

  Raises `ArgumentError` at compile time if both or neither option is
  given, if the source type does not exist, or if any listed property name
  is not present on the source type.

  ## Options

    * `:from` – atom name of the source type (required).
    * `:only` – list of property name atoms to keep.
    * `:except` – list of property name atoms to drop.

  ## Examples

      subtype :public_user,  from: :user, only:   [:id, :name]
      subtype :create_user,  from: :user, except: [:id, :inserted_at]
  """
  defmacro subtype(name, opts) when is_atom(name) and is_list(opts) do
    from = Keyword.fetch!(opts, :from)
    only = Keyword.get(opts, :only)
    except = Keyword.get(opts, :except)

    if only && except do
      raise ArgumentError, "subtype cannot define both :only and :except"
    end

    if is_nil(only) and is_nil(except) do
      raise ArgumentError, "subtype requires either :only or :except"
    end

    quote bind_quoted: [name: name, from: from, only: only, except: except] do
      @meta_dsl_defs {:subtype, name, from, %{only: only, except: except}}
    end
  end

  @doc """
  Derives a new type by inheriting all properties from an existing type and
  appending extra ones declared in the `do` block.

  Raises `ArgumentError` at compile time if the source type does not exist
  or if any property name would be duplicated in the result.

  ## Options

    * `:from` – atom name of the source type (required).

  ## Example

      extend_type :admin_user, from: :user do
        property :permissions, {:list, :string}, required: true
      end
  """
  defmacro extend_type(name, opts, do: block)
           when is_atom(name) and is_list(opts) do
    from = Keyword.fetch!(opts, :from)
    properties = extract_properties!(block, __CALLER__)

    quote bind_quoted: [name: name, from: from, properties: Macro.escape(properties)] do
      @meta_dsl_defs {:extend_type, name, from, properties}
    end
  end

  @doc """
  Declares a property inside a `meta_type` or `extend_type` block.

  Accepts an optional keyword list of options:

    * `:required` – boolean; defaults to `false`.
    * `:default` – any term; defaults to `nil`.

  Any additional options are collected into the property's `:annotations`
  map and passed through to generators unchanged.

  ## Examples

      property :email, :string
      property :role, :string, required: true
      property :score, :float, default: 0.0
  """
  defmacro property(_name, _type), do: raise "property/2 can only be used inside meta_type or extend_type"
  defmacro property(_name, _type, _opts), do: raise "property/3 can only be used inside meta_type or extend_type"

  defmacro __before_compile__(env) do
    defs = Module.get_attribute(env.module, :meta_dsl_defs) |> Enum.reverse()
    meta_types = build_and_resolve!(defs)

    quote bind_quoted: [resolved_meta_types: Macro.escape(meta_types)] do
      @meta_dsl_resolved_meta_types resolved_meta_types

      def meta_types, do: @meta_dsl_resolved_meta_types
      def to_meta, do: @meta_dsl_resolved_meta_types

      def meta_type(name) when is_atom(name) do
        Enum.find(@meta_dsl_resolved_meta_types, &(&1.name == name))
      end

      def properties(name) when is_atom(name) do
        case meta_type(name) do
          nil -> nil
          type -> type.properties
        end
      end
    end
  end

  @doc """
  Resolves a list of raw definition tuples into a sorted list of
  `MetaDsl.MetaType` structs.

  This is the programmatic counterpart to the compile-time macro pipeline.
  It is useful when building definition lists dynamically at runtime rather
  than through the `use MetaDsl` DSL.

  Definition tuples have the same shape that the macros emit:

    * `{:meta_type, name, properties, annotations}`
    * `{:subtype, name, from, %{only: [...] | nil, except: [...] | nil}}`
    * `{:extend_type, name, from, extra_properties}`

  Returns `{:ok, [MetaDsl.MetaType.t()]}` on success, or
  `{:error, message}` when any validation or resolution step fails.

  ## Example

      iex> MetaDsl.resolve([])
      {:ok, []}
  """
  @spec resolve(list()) :: {:ok, [MetaType.t()]} | {:error, term()}
  def resolve(defs) when is_list(defs) do
    {:ok, build_and_resolve!(defs)}
  rescue
    e in [ArgumentError, RuntimeError] -> {:error, Exception.message(e)}
  end

  defp build_and_resolve!(defs) do
    defs
    |> validate_definition_names!()
    |> do_resolve(%{}, MapSet.new())
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  defp do_resolve([], acc, _visiting), do: acc

  defp do_resolve([defn | rest], acc, visiting) do
    {new_acc, _type} = resolve_one!(defn, defs_index([defn | rest], acc), acc, visiting)
    do_resolve(rest, new_acc, visiting)
  end

  defp defs_index(defs, acc) do
    defs
    |> Enum.reduce(%{}, fn
      {:meta_type, name, properties, annotations}, map ->
        Map.put(map, name, {:meta_type, name, properties, annotations})

      {:subtype, name, from, opts}, map ->
        Map.put(map, name, {:subtype, name, from, opts})

      {:extend_type, name, from, properties}, map ->
        Map.put(map, name, {:extend_type, name, from, properties})
    end)
    |> Map.merge(Map.new(acc, fn {name, type} -> {name, {:resolved, type}} end))
  end

  defp resolve_one!({:meta_type, name, properties, annotations}, _defs, acc, _visiting) do
    type = %MetaType{
      name: name,
      properties: validate_properties!(name, properties),
      annotations: annotations,
      derived_from: nil
    }

    {Map.put(acc, name, type), type}
  end

  defp resolve_one!({:subtype, name, from, opts}, defs, acc, visiting) do
    if MapSet.member?(visiting, name) do
      raise ArgumentError, "cyclic derivation detected while resolving #{inspect(name)}"
    end

    {acc, source_type} = fetch_or_resolve!(from, defs, acc, MapSet.put(visiting, name))

    properties =
      source_type.properties
      |> select_properties!(name, opts)
      |> then(&(validate_properties!(name, &1)))

    type = %MetaType{
      name: name,
      properties: properties,
      derived_from: %Derivation{kind: :project, from: from, opts: Map.new(opts)}
    }

    {Map.put(acc, name, type), type}
  end

  defp resolve_one!({:extend_type, name, from, extra_properties}, defs, acc, visiting) do
    if MapSet.member?(visiting, name) do
      raise ArgumentError, "cyclic derivation detected while resolving #{inspect(name)}"
    end

    {acc, source_type} = fetch_or_resolve!(from, defs, acc, MapSet.put(visiting, name))

    merged_properties =
      source_type.properties ++ extra_properties
      |> then(&(validate_properties!(name, &1)))

    type = %MetaType{
      name: name,
      properties: merged_properties,
      derived_from: %Derivation{kind: :extend, from: from, opts: %{}}
    }

    {Map.put(acc, name, type), type}
  end

  defp fetch_or_resolve!(name, defs, acc, visiting) do
    case acc do
      %{^name => type} ->
        {acc, type}

      _ ->
        case Map.fetch(defs, name) do
          {:ok, {:resolved, type}} ->
            {Map.put(acc, name, type), type}

          {:ok, defn} ->
            resolve_one!(defn, defs, acc, visiting)

          :error ->
            raise ArgumentError, "unknown source type #{inspect(name)}"
        end
    end
  end

  defp select_properties!(properties, target_name, %{only: only, except: nil}) when is_list(only) do
    names = MapSet.new(only)

    missing =
      only
      |> Enum.reject(fn key -> Enum.any?(properties, &(&1.name == key)) end)

    if missing != [] do
      raise ArgumentError,
            "subtype #{inspect(target_name)} references unknown properties: #{inspect(missing)}"
    end

    Enum.filter(properties, &MapSet.member?(names, &1.name))
  end

  defp select_properties!(properties, target_name, %{only: nil, except: except}) when is_list(except) do
    names = MapSet.new(except)

    missing =
      except
      |> Enum.reject(fn key -> Enum.any?(properties, &(&1.name == key)) end)

    if missing != [] do
      raise ArgumentError,
            "subtype #{inspect(target_name)} references unknown properties: #{inspect(missing)}"
    end

    Enum.reject(properties, &MapSet.member?(names, &1.name))
  end

  defp validate_definition_names!(defs) do
    names =
      Enum.map(defs, fn
        {:meta_type, name, _, _} -> name
        {:subtype, name, _, _} -> name
        {:extend_type, name, _, _} -> name
      end)

    duplicates =
      names
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicates != [] do
      raise ArgumentError, "duplicate type names: #{inspect(duplicates)}"
    end

    defs
  end

  defp validate_properties!(type_name, properties) do
    duplicates =
      properties
      |> Enum.map(& &1.name)
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicates != [] do
      raise ArgumentError,
            "type #{inspect(type_name)} has duplicate properties: #{inspect(duplicates)}"
    end

    properties
  end

  defp extract_properties!({:__block__, _, nodes}, caller) do
    Enum.map(nodes, &expand_property!(&1, caller))
  end

  defp extract_properties!(node, caller) do
    [expand_property!(node, caller)]
  end

  defp expand_property!({:property, _meta, [name, type]}, caller) do
    expand_property!({:property, [], [name, type, []]}, caller)
  end

  defp expand_property!({:property, _meta, [name, type, opts]}, caller)
       when is_atom(name) and is_list(opts) do
    %Property{
      name: name,
      type: Macro.expand(type, caller),
      required: Keyword.get(opts, :required, false),
      default: Keyword.get(opts, :default),
      annotations:
        opts
        |> Keyword.drop([:required, :default])
        |> Enum.into(%{})
    }
  end

  defp expand_property!(other, _caller) do
    raise ArgumentError,
          "invalid DSL entry inside meta_type/extend_type: #{Macro.to_string(other)}"
  end
end

defmodule MetaDsl.Generators.Debug do
  @moduledoc """
  Example generator that renders resolved meta-types as human-readable text.

  This generator is intentionally simple — it exists to demonstrate how the
  `MetaDsl.Generator` behaviour is implemented and to make it easy to
  inspect a schema at a glance during development.

  ## Usage

      {:ok, output} = MetaDsl.Generators.Debug.generate(MyApp.Schema.meta_types())
      IO.puts(output)

  Each type is printed in the following format:

      type <name>
        origin: declared | <kind> from <source>
        - <prop_name>: <type> (required | optional)
        ...
  """

  @behaviour MetaDsl.Generator

  @doc """
  Renders a list of resolved `MetaDsl.MetaType` structs as plain text.

  Always returns `{:ok, iodata()}`.  Accepts and ignores any `opts`.
  """
  @impl true
  def generate(meta_types, _opts \\ []) do
    rendered =
      Enum.map_join(meta_types, "\n\n", fn type ->
        header = "type #{type.name}"

        provenance =
          case type.derived_from do
            nil -> "  origin: declared"
            derivation -> "  origin: #{derivation.kind} from #{derivation.from}"
          end

        props =
          Enum.map_join(type.properties, "\n", fn prop ->
            req = if prop.required, do: "required", else: "optional"
            "  - #{prop.name}: #{inspect(prop.type)} (#{req})"
          end)

        Enum.join([header, provenance, props], "\n")
      end)

    {:ok, rendered}
  end
end
