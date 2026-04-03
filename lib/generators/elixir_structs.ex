defmodule MetaDsl.Generators.ElixirStructs do
  @moduledoc """
  Generator that produces Elixir struct module definitions from MetaDsl
  meta-types.

  Given a list of `MetaDsl.MetaType` structs, `generate/2` returns a list of
  quoted Elixir expressions — one `defmodule … defstruct` block per type —
  that can be evaluated or injected at compile time.

  Required properties are reflected as `@enforce_keys`; optional properties
  with a non-`nil` default carry that default into the `defstruct` field list.

  ## Functional usage

      defmodule MyApp.Schema do
        use MetaDsl

        meta_type :user do
          property :id,   :uuid,   required: true
          property :name, :string, required: true
          property :role, :string, default: "member"
        end
      end

      MyApp.Schema.meta_types()
      |> MetaDsl.Generators.ElixirStructs.generate(namespace: MyApp.Structs)
      |> Enum.each(&Code.eval_quoted/1)

      # Structs are now available at runtime:
      %MyApp.Structs.User{id: "abc", name: "Alice"}

  ## Compile-time usage via `use`

      defmodule MyApp.Structs do
        use MetaDsl.Generators.ElixirStructs, schema: MyApp.Schema
        # Defines MyApp.Structs.User at compile time.
      end

      %MyApp.Structs.User{id: "abc", name: "Alice"}
  """

  @doc """
  Generates quoted Elixir struct module definitions from a list of
  `MetaDsl.MetaType` structs.

  Returns a list of quoted expressions, one per meta-type.  Each expression
  is a `defmodule` block containing an optional `@enforce_keys` attribute and
  a `defstruct` declaration matching the meta-type's properties.

  ## Options

    * `:namespace` – a module used as the namespace prefix for every generated
      struct module.  For example, passing `namespace: MyApp` turns the
      meta-type `:admin_user` into `MyApp.AdminUser`.  When omitted, the
      generated module names have no prefix (e.g. `AdminUser`).

  ## Examples

      iex> alias MetaDsl.{MetaType, Property}
      iex> types = [
      ...>   %MetaType{
      ...>     name: :point,
      ...>     properties: [
      ...>       %Property{name: :x, type: :float, required: true, default: nil, annotations: %{}},
      ...>       %Property{name: :y, type: :float, required: true, default: nil, annotations: %{}}
      ...>     ]
      ...>   }
      ...> ]
      iex> [ast] = MetaDsl.Generators.ElixirStructs.generate(types)
      iex> Code.eval_quoted(ast)
      iex> %Point{x: 1.0, y: 2.0}
      %Point{x: 1.0, y: 2.0}
  """
  @spec generate([MetaDsl.MetaType.t()], keyword()) :: [Macro.t()]
  def generate(meta_types, opts \\ []) when is_list(meta_types) do
    namespace = Keyword.get(opts, :namespace, nil)
    Enum.map(meta_types, &generate_struct(&1, namespace))
  end

  @doc false
  defmacro __using__(opts) do
    schema = Keyword.fetch!(opts, :schema)
    schema_module = Macro.expand(schema, __CALLER__)
    namespace = Keyword.get(opts, :namespace, __CALLER__.module)

    meta_types = schema_module.meta_types()
    asts = generate(meta_types, namespace: namespace)

    quote do
      unquote_splicing(asts)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp generate_struct(%MetaDsl.MetaType{name: name, properties: properties}, namespace) do
    module_name = build_module_name(name, namespace)
    enforce_keys = properties |> Enum.filter(& &1.required) |> Enum.map(& &1.name)
    struct_fields = build_struct_fields(properties)

    if Enum.empty?(enforce_keys) do
      quote do
        defmodule unquote(module_name) do
          defstruct unquote(struct_fields)
        end
      end
    else
      quote do
        defmodule unquote(module_name) do
          @enforce_keys unquote(enforce_keys)
          defstruct unquote(struct_fields)
        end
      end
    end
  end

  defp build_module_name(name, nil) do
    name
    |> Atom.to_string()
    |> Macro.camelize()
    |> then(&Module.concat([&1]))
  end

  defp build_module_name(name, namespace) do
    name
    |> Atom.to_string()
    |> Macro.camelize()
    |> then(&Module.concat(namespace, &1))
  end

  defp build_struct_fields(properties) do
    Enum.map(properties, fn
      %MetaDsl.Property{name: name, default: nil} -> name
      %MetaDsl.Property{name: name, default: default} -> {name, default}
    end)
  end
end
