defmodule MetaDsl.Property do
  @moduledoc """
  Canonical property representation used by the DSL and generators.
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

  Every declared or derived type should resolve to this structure before it
  reaches generators.
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
  Behaviour for code generators that consume resolved meta-types.
  """

  @callback generate([MetaDsl.MetaType.t()], keyword()) ::
              {:ok, iodata()} | {:error, term()}
end

defmodule MetaDsl do
  @moduledoc """
  A DSL for defining generator-agnostic meta-types and deriving new types from
  existing ones.

  This module intentionally does not generate code. It only builds a stable
  intermediate representation that can later be consumed by generators.

  Supported in this single-file prototype:

    * `meta_type/2`
    * `property/2` and `property/3`
    * `subtype/2` using `:only` or `:except`
    * `extend_type/2`
    * `meta_types/0`
    * `meta_type/1`
    * `properties/1`
    * `to_meta/0`
    * `resolve/1`

  ## Example

      defmodule Example.Schema do
        use MetaDsl

        meta_type :user do
          property :id, :uuid, required: true
          property :name, :string, required: true
          property :email, :string, required: true
          property :password_hash, :string, required: true
        end

        subtype :public_user, from: :user, only: [:id, :name, :email]

        extend_type :admin_user, from: :user do
          property :permissions, {:list, :string}, required: true
        end
      end

      Example.Schema.meta_types()
      Example.Schema.meta_type(:user)
      Example.Schema.properties(:public_user)
  """

  alias MetaDsl.{Derivation, MetaType, Property}

  defmacro __using__(_opts) do
    quote do
      import MetaDsl

      Module.register_attribute(__MODULE__, :meta_dsl_defs, accumulate: true)

      @before_compile MetaDsl
    end
  end

  defmacro meta_type(name, do: block) when is_atom(name) do
    properties = extract_properties!(block, __CALLER__)

    quote bind_quoted: [name: name, properties: Macro.escape(properties)] do
      @meta_dsl_defs {:meta_type, name, properties, %{}}
    end
  end

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

  defmacro extend_type(name, opts, do: block)
           when is_atom(name) and is_list(opts) do
    from = Keyword.fetch!(opts, :from)
    properties = extract_properties!(block, __CALLER__)

    quote bind_quoted: [name: name, from: from, properties: Macro.escape(properties)] do
      @meta_dsl_defs {:extend_type, name, from, properties}
    end
  end

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
  Resolves a list of definition tuples into a list of canonical meta-types.
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
  Tiny example generator that renders resolved meta-types as inspectable text.
  This exists only to demonstrate the generator boundary.
  """

  @behaviour MetaDsl.Generator

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
