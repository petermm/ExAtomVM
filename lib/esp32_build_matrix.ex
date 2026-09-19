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
  #
  # Builds may select shared `features`, declared under the reserved `features`
  # key, which contribute sdkconfig fragments and CMake arguments:
  #
  #     atomvm_builder: [
  #       features: [
  #         psram: [
  #           sdkconfig: "atomvm_builder/features/psram.sdkconfig",
  #           cmake_args: ["-DATOMIC_POINTER_LOCK_FREE_IS_TWO=1"]
  #         ]
  #       ],
  #       full: [chips: ["esp32s3"], features: ["psram"]]
  #     ]
  #
  # A fragment is appended before the build's own sdkconfig files, so the build
  # can override a feature. Two selected features setting the same CONFIG_ key
  # is an error.

  alias ExAtomVM.Esp32CustomComponents
  alias ExAtomVM.Esp32CustomPartitions

  @config_key :atomvm_builder
  @builds_dir "atomvm_builder"
  @component_manifest "idf_component.yml"
  @sdkconfig_defaults "sdkconfig.defaults"
  @custom_partitions "custom_partitions.csv"
  @features_key "features"
  @entry_keys [
    :chips,
    :dir,
    :components,
    :lock,
    :sdkconfig,
    :partitions,
    :cmake_args,
    :features,
    :output_name
  ]
  @feature_keys [:sdkconfig, :cmake_args]
  @path_keys [:dir, :components, :lock, :sdkconfig, :partitions]
  @chip_format ~r/^esp32[a-z0-9]*$/
  @config_assignment ~r/^(CONFIG_[A-Z0-9_]+)=/
  @config_not_set ~r/^# (CONFIG_[A-Z0-9_]+) is not set$/

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
    with {:ok, features, builds} <- normalize(config),
         {:ok, selected} <- select(builds, selection),
         {:ok, resolved} <- resolve_entries(selected, features),
         :ok <- validate_outputs(resolved) do
      {:ok, resolved}
    end
  end

  @doc """
  Checks that no two builds write the same image.

  `output_name` lets builds that differ only in their board inputs share a
  product name, so two of them on one chip would overwrite each other.
  """
  def validate_outputs(builds) do
    builds
    |> Enum.flat_map(fn build ->
      Enum.map(build.chips, &{image_path(build.output_name, &1), build.name})
    end)
    |> Enum.reduce_while(%{}, fn {image, name}, seen ->
      case Map.fetch(seen, image) do
        :error -> {:cont, Map.put(seen, image, name)}
        {:ok, other} -> {:halt, {:error, "builds #{other} and #{name} both write #{image}"}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      %{} -> :ok
    end
  end

  @doc """
  The resolved builds as plain data, for display and for `to_json/1`.
  """
  def plan(builds) do
    Enum.map(builds, fn build ->
      %{
        name: build.name,
        output_name: build.output_name,
        chips: build.chips,
        dir: Path.relative_to_cwd(build.dir),
        features: build.features,
        cmake_args: build.cmake_args,
        components: build.components && Path.relative_to_cwd(build.components.path),
        sdkconfig: build.sdkconfig && Path.relative_to_cwd(build.sdkconfig),
        partition_table:
          build.partition_table && Path.relative_to_cwd(build.partition_table.path),
        images: Enum.map(build.chips, &image_path(build.output_name, &1))
      }
    end)
  end

  @doc """
  The builds as a GitHub Actions matrix, one entry per build and chip.
  """
  def to_json(builds) do
    include =
      for build <- builds, chip <- build.chips do
        %{
          "name" => build.name,
          "output_name" => build.output_name,
          "chip" => chip,
          "features" => build.features,
          "image" => image_path(build.output_name, chip)
        }
        |> Map.reject(fn
          {"output_name", output_name} -> output_name == build.name
          {_key, value} -> value == []
        end)
      end

    %{"include" => include}
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  @doc """
  The base name of the image a build produces for a chip.

  Matrix images carry the chip first, `atomvm-<chip>-<build>-elixir`, like the
  image names `mix atomvm.esp32.install` understands, so it can tell their chip
  and Elixir support apart.
  """
  def image_stem(nil, chip), do: "atomvm-#{chip}-elixir"
  def image_stem(name, chip), do: "atomvm-#{chip}-#{name}-elixir"

  @doc """
  The image path a build produces for a chip, relative to the project root.
  """
  def image_path(name, chip) do
    Path.join(["_build", "atomvm_images", "#{image_stem(name, chip)}.img"])
  end

  # --- configuration ---

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

        {feature_entries, build_entries} =
          Enum.split_with(entries, fn {name, _opts} -> name == @features_key end)

        with :ok <- single_features_section(feature_entries),
             {:ok, features} <- parse_features(feature_entries),
             {:ok, builds} <- parse_builds(build_entries) do
          {:ok, features, builds}
        end
    end
  end

  defp normalize(_config) do
    {:error, "atomvm_builder must be a keyword list or a map of builds"}
  end

  defp named_entry?({name, _opts}) when is_atom(name) or is_binary(name), do: true
  defp named_entry?(_entry), do: false

  defp single_features_section([]), do: :ok
  defp single_features_section([_entry]), do: :ok

  defp single_features_section(_entries) do
    {:error, "atomvm_builder has more than one #{@features_key} section"}
  end

  defp parse_builds(entries) do
    case duplicates(Enum.map(entries, &elem(&1, 0))) do
      [] -> {:ok, entries}
      names -> {:error, "atomvm_builder has duplicate build(s): #{Enum.join(names, ", ")}"}
    end
  end

  defp parse_features([]), do: {:ok, %{}}

  defp parse_features([{@features_key, definitions}]) do
    with {:ok, entries} <- feature_entries(definitions) do
      {:ok, Map.new(entries, fn feature -> {feature.name, feature} end)}
    end
  end

  defp feature_entries(definitions) when is_list(definitions) or is_map(definitions) do
    entries = Enum.to_list(definitions)

    cond do
      not Enum.all?(entries, &named_entry?/1) ->
        {:error, "#{@features_key} must map feature names to options"}

      true ->
        entries = Enum.map(entries, fn {name, opts} -> {to_string(name), opts} end)

        case duplicates(Enum.map(entries, &elem(&1, 0))) do
          [] ->
            reduce_features(entries)

          names ->
            {:error, "#{@features_key} has duplicate feature(s): #{Enum.join(names, ", ")}"}
        end
    end
  end

  defp feature_entries(_definitions) do
    {:error, "#{@features_key} must map feature names to options"}
  end

  defp reduce_features(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, features} ->
      case parse_feature(entry) do
        {:ok, feature} -> {:cont, {:ok, features ++ [feature]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_feature({name, opts}) do
    with {:ok, options} <- options_map("feature", name, opts),
         :ok <- reject_unknown_keys("feature", name, options, @feature_keys),
         {:ok, sdkconfig} <- feature_sdkconfig(name, options),
         {:ok, cmake_args} <- cmake_args("feature", name, options),
         :ok <- feature_does_something(name, sdkconfig, cmake_args),
         {:ok, keys} <- fragment_keys(name, sdkconfig) do
      {:ok, %{name: name, sdkconfig: sdkconfig, keys: keys, cmake_args: cmake_args}}
    end
  end

  defp feature_does_something(name, nil, []) do
    {:error, "feature #{name} has no sdkconfig or cmake_args"}
  end

  defp feature_does_something(_name, _sdkconfig, _cmake_args), do: :ok

  defp feature_sdkconfig(name, options) do
    case Map.get(options, :sdkconfig) do
      nil ->
        {:ok, nil}

      path when is_binary(path) ->
        validate_fragment(name, Path.expand(path))

      _other ->
        {:error, "feature #{name} sdkconfig must be a path"}
    end
  end

  defp validate_fragment(name, path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: 0}} ->
        {:error, "feature #{name}: #{Path.basename(path)} is empty"}

      {:ok, %File.Stat{type: :regular}} ->
        {:ok, path}

      {:ok, _stat} ->
        {:error, "feature #{name}: #{Path.basename(path)} exists but is not a regular file"}

      {:error, reason} ->
        {:error,
         "feature #{name}: cannot read #{Path.basename(path)}: #{:file.format_error(reason)}"}
    end
  end

  defp fragment_keys(_name, nil), do: {:ok, []}

  defp fragment_keys(name, path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, number}, {:ok, keys} ->
      case fragment_key(line) do
        :ignore ->
          {:cont, {:ok, keys}}

        {:ok, key} ->
          if key in keys do
            {:halt,
             {:error, "feature #{name}: #{Path.basename(path)}:#{number} sets #{key} twice"}}
          else
            {:cont, {:ok, keys ++ [key]}}
          end

        :error ->
          {:halt,
           {:error,
            "feature #{name}: #{Path.basename(path)}:#{number} is not a CONFIG_* assignment: " <>
              inspect(String.trim(line))}}
      end
    end)
  end

  # Comments and blank lines pass through; assignments and "# CONFIG_X is not
  # set" lines carry the keys a feature owns.
  defp fragment_key(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        :ignore

      match = Regex.run(@config_assignment, trimmed) ->
        {:ok, Enum.at(match, 1)}

      match = Regex.run(@config_not_set, trimmed) ->
        {:ok, Enum.at(match, 1)}

      String.starts_with?(trimmed, "#") ->
        :ignore

      true ->
        :error
    end
  end

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

  defp resolve_entries(entries, features) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, builds} ->
      with {:ok, options} <- entry_options(entry, features),
           {:ok, build} <- resolve_entry(options) do
        {:cont, {:ok, builds ++ [build]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp entry_options({name, opts}, features) do
    with {:ok, options} <- options_map("build", name, opts),
         :ok <- reject_unknown_keys("build", name, options, @entry_keys),
         {:ok, chips} <- entry_chips(name, options),
         {:ok, output_name} <- entry_output_name(name, options),
         {:ok, selected} <- entry_features(name, options, features),
         {:ok, cmake_args} <- cmake_args("build", name, options) do
      {:ok,
       %{
         name: name,
         output_name: output_name,
         options: options,
         chips: chips,
         features: Enum.map(selected, & &1.name),
         feature_sdkconfigs: selected |> Enum.map(& &1.sdkconfig) |> Enum.reject(&is_nil/1),
         cmake_args: Enum.uniq(Enum.flat_map(selected, & &1.cmake_args) ++ cmake_args)
       }}
    end
  end

  # The name this build's images carry, `atomvm-<chip>-<output_name>-elixir`.
  # It defaults to the entry's own name, and lets builds that differ only in how
  # they fit a board (a partition table, say) still produce the same product
  # name on every chip.
  defp entry_output_name(name, options) do
    case Map.get(options, :output_name, name) do
      output_name when is_binary(output_name) ->
        if String.trim(output_name) == "" do
          {:error, "build #{name} output_name must not be empty"}
        else
          {:ok, output_name}
        end

      _other ->
        {:error, "build #{name} output_name must be a string"}
    end
  end

  defp options_map(kind, name, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      {:ok, Map.new(opts)}
    else
      {:error, "#{kind} #{name} options must be a keyword list"}
    end
  end

  defp options_map(kind, name, opts) when is_map(opts) do
    if Enum.all?(Map.keys(opts), &is_atom/1) do
      {:ok, opts}
    else
      {:error, "#{kind} #{name} option keys must be atoms"}
    end
  end

  defp options_map(kind, name, _opts) do
    {:error, "#{kind} #{name} options must be a keyword list or map"}
  end

  defp reject_unknown_keys(kind, name, options, allowed) do
    case Map.keys(options) -- allowed do
      [] ->
        validate_path_options(kind, name, options)

      unknown ->
        names = Enum.map_join(unknown, ", ", &inspect/1)
        {:error, "#{kind} #{name} has unknown option(s): #{names}"}
    end
  end

  defp validate_path_options(kind, name, options) do
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
        {:error, "#{kind} #{name} option(s) must be paths: #{names}"}
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

  defp cmake_args(kind, name, options) do
    case Map.get(options, :cmake_args, []) do
      args when is_binary(args) ->
        {:ok, String.split(args)}

      args when is_list(args) ->
        case Enum.reject(args, &(is_binary(&1) and &1 != "")) do
          [] -> {:ok, args}
          invalid -> {:error, "#{kind} #{name} cmake_args must be strings: #{inspect(invalid)}"}
        end

      _other ->
        {:error, "#{kind} #{name} cmake_args must be a string or a list of strings"}
    end
  end

  defp entry_features(name, options, features) do
    case Map.get(options, :features, []) do
      names when is_list(names) ->
        names = names |> Enum.map(&to_string/1) |> Enum.uniq()

        case Enum.reject(names, &Map.has_key?(features, &1)) do
          [] ->
            select_features(names, features)

          unknown ->
            known = features |> Map.keys() |> Enum.sort()

            {:error,
             "build #{name} has unknown feature(s): #{Enum.join(unknown, ", ")}; " <>
               "defined features: #{Enum.join(known, ", ")}"}
        end

      _other ->
        {:error, "build #{name} features must be a list"}
    end
  end

  defp select_features(names, features) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, selected} ->
      feature = Map.fetch!(features, name)

      case conflicting_key(feature, selected) do
        nil -> {:cont, {:ok, selected ++ [feature]}}
        {other, key} -> {:halt, {:error, "features #{other} and #{name} both set #{key}"}}
      end
    end)
  end

  defp conflicting_key(feature, selected) do
    Enum.find_value(selected, fn other ->
      case Enum.find(feature.keys, &(&1 in other.keys)) do
        nil -> nil
        key -> {other.name, key}
      end
    end)
  end

  defp resolve_entry(%{
         name: name,
         output_name: output_name,
         options: options,
         chips: chips,
         features: features,
         feature_sdkconfigs: feature_sdkconfigs,
         cmake_args: cmake_args
       }) do
    dir = Path.expand(Map.get(options, :dir) || Path.join(@builds_dir, name))

    with {:ok, components} <- load_components(name, options, dir),
         {:ok, partition_table} <- load_partitions(name, options, dir),
         {:ok, sdkconfig} <- sdkconfig_path(name, options, dir, chips) do
      {:ok,
       %{
         name: name,
         output_name: output_name,
         dir: dir,
         chips: chips,
         features: features,
         feature_sdkconfigs: feature_sdkconfigs,
         cmake_args: cmake_args,
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
