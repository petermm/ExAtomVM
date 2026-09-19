defmodule ExAtomVM.Esp32BuildMatrix do
  @moduledoc false

  # The build matrix: named ESP32 builds, each with its own component manifest,
  # sdkconfig defaults, and partition table, over one or more chips.
  #
  # A build is configured in the Mix project (or the `:exatomvm` application
  # environment) and its inputs live in a directory named after the build:
  #
  #     atomvm_builder/full/
  #       idf_component.yml
  #       dependencies.lock
  #       sdkconfig.defaults
  #       sdkconfig.defaults.esp32s3
  #       custom_partitions.csv
  #
  # Explicit `components`, `lock`, `sdkconfig`, and `partitions` options
  # override the convention; a missing file means no customization on that axis.

  alias ExAtomVM.Esp32CustomComponents
  alias ExAtomVM.Esp32CustomPartitions

  @config_key :atomvm_builder
  @builds_dir "atomvm_builder"
  @component_manifest "idf_component.yml"
  @sdkconfig_defaults "sdkconfig.defaults"
  @custom_partitions "custom_partitions.csv"
  @entry_keys [:chips, :dir, :components, :lock, :sdkconfig, :partitions]
  @path_keys [:dir, :components, :lock, :sdkconfig, :partitions]
  @chip_format ~r/^esp32[a-z0-9]*$/

  @doc """
  The configured builds, from the Mix project or the application environment.

  The application environment takes precedence, so a project can override the
  matrix and tests can provide one.
  """
  def config do
    Application.get_env(:exatomvm, @config_key) || Mix.Project.config()[@config_key]
  end

  @doc """
  Resolves `selection` (`:all` or a list of build names) against `config`.

  Loads and validates each selected build's inputs up front, so a broken entry
  fails before any build starts. Returns `{:ok, builds}` or `{:error, reason}`.
  """
  def resolve(config, selection) do
    with {:ok, entries} <- normalize(config),
         {:ok, selected} <- select(entries, selection) do
      resolve_entries(selected)
    end
  end

  @doc """
  The resolved builds as plain data, for display and for `to_json/1`.
  """
  def plan(builds) do
    Enum.map(builds, fn build ->
      %{
        name: build.name,
        chips: build.chips,
        dir: Path.relative_to_cwd(build.dir),
        components: build.components && Path.relative_to_cwd(build.components.path),
        sdkconfig: build.sdkconfig && Path.relative_to_cwd(build.sdkconfig),
        partition_table:
          build.partition_table && Path.relative_to_cwd(build.partition_table.path),
        images: Enum.map(build.chips, &image_path(build.name, &1))
      }
    end)
  end

  @doc """
  The builds as a GitHub Actions matrix, one entry per build and chip.
  """
  def to_json(builds) do
    include =
      for build <- builds, chip <- build.chips do
        %{"name" => build.name, "chip" => chip, "image" => image_path(build.name, chip)}
      end

    %{"include" => include}
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  @doc """
  The base name of the image a build produces for a chip.
  """
  def image_stem(nil, chip), do: "atomvm-#{chip}-elixir"
  def image_stem(name, chip), do: "atomvm-#{name}-#{chip}-elixir"

  @doc """
  The image path a build produces for a chip, relative to the project root.
  """
  def image_path(name, chip) do
    Path.join(["_build", "atomvm_images", "#{image_stem(name, chip)}.img"])
  end

  defp normalize(nil) do
    {:error,
     "no atomvm_builder configuration found; add one to mix.exs, for example:\n" <>
       "    atomvm_builder: [plain: [chips: [\"esp32\"]]]"}
  end

  defp normalize(config) when is_list(config) or is_map(config) do
    entries = Enum.to_list(config)

    cond do
      entries == [] ->
        {:error, "atomvm_builder is empty"}

      not Enum.all?(entries, &named_entry?/1) ->
        {:error, "atomvm_builder must map build names to options"}

      true ->
        entries = Enum.map(entries, fn {name, opts} -> {to_string(name), opts} end)

        case duplicates(Enum.map(entries, &elem(&1, 0))) do
          [] -> {:ok, entries}
          names -> {:error, "atomvm_builder has duplicate build(s): #{Enum.join(names, ", ")}"}
        end
    end
  end

  defp normalize(_config) do
    {:error, "atomvm_builder must be a keyword list or a map of builds"}
  end

  defp named_entry?({name, _opts}) when is_atom(name) or is_binary(name), do: true
  defp named_entry?(_entry), do: false

  defp duplicates(names) do
    names
    |> Enum.frequencies()
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp select(entries, :all), do: {:ok, entries}

  defp select(entries, names) when is_list(names) do
    known = Enum.map(entries, &elem(&1, 0))

    case Enum.reject(names, &(&1 in known)) do
      [] ->
        {:ok, Enum.filter(entries, fn {name, _opts} -> name in names end)}

      unknown ->
        {:error,
         "unknown build(s): #{Enum.join(unknown, ", ")}; configured builds: " <>
           "#{Enum.join(known, ", ")}"}
    end
  end

  defp select(_entries, selection), do: {:error, "invalid build selection: #{inspect(selection)}"}

  defp resolve_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, builds} ->
      with {:ok, options} <- entry_options(entry),
           {:ok, build} <- resolve_entry(options) do
        {:cont, {:ok, builds ++ [build]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp entry_options({name, opts}) do
    with {:ok, options} <- options_map(name, opts),
         :ok <- reject_unknown_keys(name, options),
         {:ok, chips} <- entry_chips(name, options) do
      {:ok, %{name: name, options: options, chips: chips}}
    end
  end

  defp options_map(name, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      {:ok, Map.new(opts)}
    else
      {:error, "build #{name} options must be a keyword list"}
    end
  end

  defp options_map(name, opts) when is_map(opts) do
    if Enum.all?(Map.keys(opts), &is_atom/1) do
      {:ok, opts}
    else
      {:error, "build #{name} option keys must be atoms"}
    end
  end

  defp options_map(name, _opts),
    do: {:error, "build #{name} options must be a keyword list or map"}

  defp reject_unknown_keys(name, options) do
    case Map.keys(options) -- @entry_keys do
      [] ->
        validate_path_options(name, options)

      unknown ->
        names = Enum.map_join(unknown, ", ", &inspect/1)
        {:error, "build #{name} has unknown option(s): #{names}"}
    end
  end

  defp validate_path_options(name, options) do
    invalid =
      Enum.filter(@path_keys, fn key ->
        case Map.fetch(options, key) do
          {:ok, value} -> not is_binary(value)
          :error -> false
        end
      end)

    case invalid do
      [] ->
        :ok

      keys ->
        names = Enum.map_join(keys, ", ", &inspect/1)
        {:error, "build #{name} option(s) must be paths: #{names}"}
    end
  end

  defp entry_chips(name, options) do
    case Map.get(options, :chips) do
      nil ->
        {:error, "build #{name} has no chips"}

      chips when is_list(chips) ->
        chips = chips |> Enum.map(&to_string/1) |> Enum.uniq()

        case Enum.reject(chips, &Regex.match?(@chip_format, &1)) do
          [] when chips != [] ->
            {:ok, chips}

          [] ->
            {:error, "build #{name} has no chips"}

          unknown ->
            {:error, "build #{name} has unknown chip(s): #{Enum.join(unknown, ", ")}"}
        end

      _other ->
        {:error, "build #{name} chips must be a list"}
    end
  end

  defp resolve_entry(%{name: name, options: options, chips: chips}) do
    dir = Path.expand(Map.get(options, :dir) || Path.join(@builds_dir, name))

    with {:ok, components} <- load_components(name, options, dir),
         {:ok, partition_table} <- load_partitions(name, options, dir),
         {:ok, sdkconfig} <- sdkconfig_path(name, options, dir, chips) do
      {:ok,
       %{
         name: name,
         dir: dir,
         chips: chips,
         components: components,
         sdkconfig: sdkconfig,
         partition_table: partition_table
       }}
    end
  end

  defp load_components(name, options, dir) do
    manifest = configured_or_convention(options, :components, dir, @component_manifest)
    lock = Map.get(options, :lock)

    cond do
      is_nil(manifest) and not is_nil(lock) ->
        {:error, "build #{name} sets lock but has no component manifest"}

      is_nil(manifest) ->
        {:ok, nil}

      true ->
        case Esp32CustomComponents.load_custom_components(manifest, lock) do
          {:ok, selected} -> {:ok, selected}
          {:error, reason} -> {:error, "build #{name}: #{reason}"}
        end
    end
  end

  defp load_partitions(name, options, dir) do
    case configured_or_convention(options, :partitions, dir, @custom_partitions) do
      nil ->
        {:ok, nil}

      path ->
        case Esp32CustomPartitions.load_custom_partitions(path) do
          {:ok, selected} -> {:ok, selected}
          {:error, reason} -> {:error, "build #{name}: #{reason}"}
        end
    end
  end

  defp sdkconfig_path(name, options, dir, chips) do
    case Map.get(options, :sdkconfig) do
      nil ->
        base = Path.join(dir, @sdkconfig_defaults)

        if File.exists?(base) or Enum.any?(chips, &File.exists?("#{base}.#{&1}")) do
          {:ok, base}
        else
          {:ok, nil}
        end

      path ->
        path = Path.expand(path)

        if File.exists?(path) or Enum.any?(chips, &File.exists?("#{path}.#{&1}")) do
          {:ok, path}
        else
          {:error,
           "build #{name}: SDK config file does not exist: #{path} " <>
             "(or target-specific override #{path}.<chip>)"}
        end
    end
  end

  # An explicit option wins; otherwise the file is used when the build's
  # directory holds one, and no customization is the default.
  defp configured_or_convention(options, key, dir, filename) do
    case Map.get(options, key) do
      nil ->
        path = Path.join(dir, filename)
        if File.exists?(path), do: path, else: nil

      path ->
        Path.expand(path)
    end
  end
end
