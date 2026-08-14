defmodule Mix.Tasks.Atomvm.Packbeam do
  use Mix.Task

  @shortdoc "Bundle the application into an AVM file"

  @moduledoc """
  Bundle an application into an AVM file that can be flashed to a micro-controller and (or directly on a unix host) executed by the AtomVM virtual machine.

  Dependency and private-content archives are packed before deterministically ordered application
  modules. The configured start module is packed last. This keeps stable content at fixed offsets,
  improving ESP32 differential flashing when application modules change size. The ESP32 flash task
  opts development builds into aligned dependency and private-content archive slots, plus
  flash-sector-sized application module slots. Standalone, Pico, STM32, and production packing stay
  compact.

  > #### Info {: .info}
  >
  > Normally using this task manually is not required, it is called automatically by `atomvm.esp32.flash`, `atomvm.stm32.flash` and `atomvm.pico.flash`.

  ## Usage example

  Within your AtomVM mix project run

  `
  $ mix atomvm.packbeam
  `

  ## Configuration

  ExAtomVM can be configured from the mix.ex file and supports the following settings for the
  `atomvm.packbeam` task.

    * `:start` - The name of the module containing the start/0 entrypoint function. Only to be used to override the `:start` options defined in the the projects `mix.exs` This would not normally be needed, unless the user had an alternate mode of operation e.g like a client/server app that normally builds the client, but when building the server uses a different start module.

    * `:max_size` - Optional maximum output AVM size in bytes. Slot padding is reduced as
      needed to stay within this limit. Packing fails if the compact content itself does not fit.

  ## Command line options

  Properties in the mix.exs file may be over-ridden on the command line using long-style flags (prefixed by --) by the same name
  as the [supported properties](#module-configuration)

  For example, you can use the `--start` option to specify or override the `start` property, or
  `--max-size 0x100000` to set the maximum output size.
  """

  alias ExAtomVM.PackBEAM
  alias Mix.Project
  alias Mix.Tasks.Atomvm.Check

  def run(args), do: run(args, [])

  @doc false
  def run(args, task_options) do
    with {:check, {:ok, _}} <- {:check, Check.run(args)},
         {:args, {:ok, options}} <- {:args, parse_args(args)},
         config = Project.config(),
         {:atomvm, {:ok, avm_config}} <- {:atomvm, Keyword.fetch(config, :atomvm)},
         {:start, {:ok, start_module}} <-
           {:start, Map.get(options, :start, Keyword.fetch(avm_config, :start))},
         {:max_size, {:ok, max_size}} <-
           {:max_size, resolve_max_size(options, avm_config, task_options)},
         :ok <- pack_avm_deps(),
         :ok <- pack_priv(),
         start_beam_file = "#{Atom.to_string(start_module)}.beam",
         {:pack, {:ok, stats}} <-
           {:pack,
            pack_beams(
              Project.compile_path(),
              start_beam_file,
              "#{config[:app]}.avm",
              max_size,
              Keyword.get(task_options, :slot_modules, false)
            )} do
      report_pack_stats("#{config[:app]}.avm", stats)
      {:ok, []}
    else
      {:check, _} ->
        IO.puts("error: failed check, .beam files will not be packed.")
        :error

      {:atomvm, :error} ->
        IO.puts("error: missing AtomVM project config.")
        :error

      {:args, :error} ->
        IO.puts("error: invalid atomvm.packbeam arguments.")
        :error

      {:start, :error} ->
        IO.puts("error: missing startup module.")
        :error

      {:max_size, {:error, value}} ->
        IO.puts("error: max_size must be a positive byte count, got: #{inspect(value)}.")
        :error

      {:pack, {:error, {:max_size_exceeded, stats}}} ->
        IO.puts(
          "error: compact AVM is #{stats.compact_size} bytes and exceeds max_size " <>
            "#{stats.max_size} by #{stats.over_by} bytes."
        )

        IO.puts(
          "Reduce dependencies or private assets, or increase :max_size only when the target " <>
            "partition is large enough."
        )

        :error

      {:pack, error} ->
        IO.puts("error: failed to pack application: #{inspect(error)}.")
        :error

      nil ->
        IO.puts("error: ATOMVM_INSTALL_PREFIX env var is not set.")
        :error

      error ->
        IO.puts("error: unexpected error: #{inspect(error)}.")
        :error
    end
  end

  defp pack_avm_deps() do
    dep_beams = list_dep_beams()

    case avm_deps_path() do
      {:ok, avm_path} ->
        dep_avms = list_dep_avms(avm_path)
        PackBEAM.make_avm(dep_beams ++ dep_avms, "deps.avm")

      {:error, :no_avm_deps_path} ->
        PackBEAM.make_avm(dep_beams, "deps.avm")
    end
  end

  defp list_dep_avms(avm_path) do
    avm_path
    |> File.ls!()
    |> Enum.sort()
    |> Enum.map(fn file -> {Path.join(avm_path, file), :avm} end)
  end

  defp list_dep_beams() do
    runtime_deps_beams()
    |> Enum.sort()
    |> Enum.map(fn beam_file -> {beam_file, :beam} end)
  end

  def beam_files(path) do
    for file <- File.ls!(path), String.ends_with?(file, ".beam") do
      Path.join(path, file)
    end
  end

  defp pack_priv() do
    priv_dir_path =
      Project.config()[:app]
      |> Application.app_dir("priv")

    packbeam_inputs =
      case File.exists?(priv_dir_path) do
        true ->
          prefix =
            Project.config()[:app]
            |> Atom.to_string()
            |> Path.join("priv")

          priv_dir_path
          |> get_all_files()
          |> Enum.map(fn file ->
            {file, [file: Path.join(prefix, Path.relative_to(file, priv_dir_path))]}
          end)

        false ->
          []
      end

    packbeam_inputs = Enum.sort_by(packbeam_inputs, fn {_file, opts} -> opts[:file] end)

    PackBEAM.make_avm(packbeam_inputs, "priv.avm")
  end

  defp get_all_files(dir) do
    all_files = Path.wildcard(Path.join(dir, "*"))

    regular_files =
      Enum.filter(all_files, fn path ->
        File.regular?(path)
      end)

    sub_dirs =
      Enum.filter(all_files, fn path ->
        File.dir?(path)
      end)

    sub_files =
      Enum.reduce(sub_dirs, [], fn sub_dir, accum ->
        get_all_files(sub_dir) ++ accum
      end)

    regular_files ++ sub_files
  end

  defp pack_beams(beams_path, start_beam_file, out, max_size, slot_modules) do
    options = [slot_modules: slot_modules]

    with {:ok, inputs} <-
           ordered_packbeam_inputs(beams_path, start_beam_file, "deps.avm", "priv.avm", options) do
      PackBEAM.make_avm(inputs, out, max_size: max_size)
    end
  end

  @doc false
  def resolve_max_size(options, avm_config, task_options) do
    case fetch_max_size(options, avm_config, task_options) do
      :error -> {:ok, nil}
      {:ok, max_size} when is_integer(max_size) and max_size > 0 -> {:ok, max_size}
      {:ok, max_size} -> {:error, max_size}
    end
  end

  defp fetch_max_size(options, avm_config, task_options) do
    cond do
      Map.has_key?(options, :max_size) -> Map.fetch(options, :max_size)
      Keyword.has_key?(avm_config, :max_size) -> Keyword.fetch(avm_config, :max_size)
      true -> Keyword.fetch(task_options, :max_size)
    end
  end

  defp report_pack_stats(out, stats) do
    size_summary =
      case stats.max_size do
        nil ->
          "#{stats.size} bytes"

        max_size ->
          percent = Float.round(stats.size * 100 / max_size, 1)
          "#{stats.size} / #{max_size} bytes (#{percent}%)"
      end

    IO.puts("Packed #{out}: #{size_summary}")
    IO.puts("  compact content: #{stats.compact_size} bytes")

    padding_summary =
      if stats.padding_reduced? do
        "#{stats.padding_size} bytes (#{stats.desired_padding_size} requested)"
      else
        "#{stats.padding_size} bytes"
      end

    IO.puts("  slot padding: #{padding_summary}")

    if stats.archive_count > 0 do
      IO.puts("    archives: #{stats.archive_padding_size} bytes")
      IO.puts("    application modules: #{stats.module_padding_size} bytes")
    end

    if stats.max_size do
      IO.puts("  remaining: #{stats.max_size - stats.size} bytes")
    end

    if stats.padding_reduced? do
      IO.puts(
        :stderr,
        "warning: reduced slot padding to fit max_size; " <>
          "#{stats.full_archive_slots}/#{stats.archive_count} archives retain full slots; " <>
          "#{stats.full_headroom_modules}/#{stats.module_count} application modules retain " <>
          "at least 1 KiB headroom, and #{stats.padded_modules}/#{stats.module_count} retain padding."
      )
    end
  end

  @doc false
  def ordered_packbeam_inputs(
        beams_path,
        start_beam_file,
        deps_avm \\ "deps.avm",
        priv_avm \\ "priv.avm",
        options \\ []
      ) do
    with {:ok, files} <- File.ls(beams_path),
         app_beam_files =
           files
           |> Enum.filter(&String.ends_with?(&1, ".beam"))
           |> Enum.sort(),
         true <- start_beam_file in app_beam_files,
         :ok <- validate_dependency_layout(deps_avm, app_beam_files) do
      slot_modules = Keyword.get(options, :slot_modules, false)
      slot_archives = Keyword.get(options, :slot_archives, slot_modules)

      {beam_type, start_type} =
        if slot_modules do
          {:beam_slot, :beam_start_slot}
        else
          {:beam, :beam_start}
        end

      {deps_type, priv_type} =
        if slot_archives do
          {{:avm_slot, :deps}, {:avm_slot, :priv}}
        else
          {:avm, :avm}
        end

      app_inputs =
        app_beam_files
        |> List.delete(start_beam_file)
        |> Enum.map(fn file -> {Path.join(beams_path, file), beam_type} end)

      {:ok,
       [{deps_avm, deps_type}, {priv_avm, priv_type}] ++
         app_inputs ++ [{Path.join(beams_path, start_beam_file), start_type}]}
    else
      false -> {:error, {:start_module_not_found, start_beam_file}}
      error -> error
    end
  end

  defp validate_dependency_layout(deps_avm, app_beam_files) do
    with {:ok, sections} <- PackBEAM.sections(deps_avm) do
      dependency_start_sections =
        sections
        |> Enum.filter(&PackBEAM.start_section?/1)
        |> Enum.map(& &1.name)
        |> Enum.sort()

      dependency_names = MapSet.new(sections, & &1.name)

      collisions =
        app_beam_files
        |> Enum.filter(&MapSet.member?(dependency_names, &1))
        |> Enum.sort()

      cond do
        dependency_start_sections != [] ->
          {:error, {:dependency_start_sections, dependency_start_sections}}

        collisions != [] ->
          {:error, {:dependency_module_collisions, collisions}}

        true ->
          :ok
      end
    else
      {:error, reason} -> {:error, {:invalid_dependency_archive, deps_avm, reason}}
    end
  end

  defp avm_deps_path() do
    deps_path = Project.deps_path()

    with true <- String.ends_with?(deps_path, "/deps"),
         deps_len = String.length(deps_path),
         prj_path = String.slice(deps_path, 0, deps_len - 5),
         avm_deps_path = Path.join(prj_path, "/avm_deps"),
         true <- File.exists?(avm_deps_path) do
      {:ok, avm_deps_path}
    else
      _ ->
        with prefix when prefix != nil <- System.get_env("ATOMVM_INSTALL_PREFIX"),
             true <- File.exists?(prefix) do
          {:ok, Path.join(prefix, "lib/AtomVM/ebin/")}
        else
          _ ->
            IO.puts("No avm_deps directory found.")

            IO.puts(
              "This message can be safely ignored when standard libraries are already flashed to lib partition."
            )

            {:error, :no_avm_deps_path}
        end
    end
  end

  def runtime_deps(deps, is_runtime_dep \\ false) do
    Enum.reduce(deps, [], fn dep, acc ->
      if Keyword.get(dep.opts, :runtime, true) and
           (is_runtime_dep == true or dep.top_level == true) do
        ["#{dep.opts[:build]}/ebin" | runtime_deps(dep.deps, true) ++ acc]
      else
        acc
      end
    end)
  end

  def runtime_deps_beams() do
    Mix.Dep.cached()
    |> runtime_deps()
    |> Enum.reduce([], fn path, acc -> beam_files(path) ++ acc end)
  end

  @doc false
  def parse_options(args) do
    parse_args(args, %{})
  end

  defp parse_args(args), do: parse_options(args)

  defp parse_args([], accum) do
    {:ok, accum}
  end

  defp parse_args([<<"--start">>, start | t], accum) do
    parse_args(t, Map.put(accum, :start, start))
  end

  defp parse_args([option], _accum) when option in ["--max-size", "--max_size"], do: :error

  defp parse_args([option, max_size | t], accum)
       when option in ["--max-size", "--max_size"] do
    case parse_size(max_size) do
      {:ok, size} -> parse_args(t, Map.put(accum, :max_size, size))
      :error -> :error
    end
  end

  defp parse_args([_ | t], accum) do
    parse_args(t, accum)
  end

  defp parse_size("0x" <> hex), do: parse_hex_size(hex)
  defp parse_size("0X" <> hex), do: parse_hex_size(hex)

  defp parse_size(decimal) do
    case Integer.parse(decimal) do
      {size, ""} when size > 0 -> {:ok, size}
      _ -> :error
    end
  end

  defp parse_hex_size(hex) do
    case Integer.parse(hex, 16) do
      {size, ""} when size > 0 -> {:ok, size}
      _ -> :error
    end
  end
end
