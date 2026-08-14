defmodule Mix.Tasks.Atomvm.Esp32.Flash do
  use Mix.Task

  @shortdoc "Flash the application to an ESP32 micro-controller"

  @moduledoc """
  Flashes the application to an ESP32 micro-controller.

  > #### Important {: .warning}
  >
  > Before running this task, you must flash the AtomVM virtual machine to the target device.
  >
  > This tasks depends on `esptool` and can be installed using package managers:
  >  - linux (debian): apt install esptool
  >  - macos: brew install esptool
  >  - or follow these [installation instructions](https://docs.espressif.com/projects/esptool/en/latest/esp32/installation.html#installation) when not available through a package manager.

  ## Usage example

  Within your AtomVM mix project run

  `
  $ mix atomvm.esp32.flash
  `

  Or with optional flags (which will override the config in mix.exs)

  `
  $ mix atomvm.esp32.flash --port /dev/tty.usbserial-0001
  `

  Or detect the port automatically with

  `
  $ mix atomvm.esp32.flash --port auto
  `

  Subsequent successful flashes use esptool's differential flashing when supported. To discard
  the cached previous image and perform a full application flash, use

  `
  $ mix atomvm.esp32.flash --clean
  `

  ## Configuration

  ExAtomVM can be configured from the mix.ex file and supports the following settings for the
  `atomvm.esp32.flash` task.

    * `:flash_offset` - The start address of the flash to write the application to in hexademical format,
      defaults to `0x250000`.

    * `:chip` - Chip type, defaults to `auto`.

    * `:port` - The port to which device is connected on the host computer, defaults to `/dev/ttyUSB0`.

    * `:baud` - The BAUD rate used when flashing to device, defaults to `115200`.

    * `:max_size` - Maximum application AVM size in bytes, defaults to `0x100000` (1 MiB),
      matching AtomVM's standard ESP32 `main.avm` partition. Slot padding is reduced to
      fit; compact content that exceeds the limit is not flashed.

  ## Command line options

  Properties in the mix.exs file may be over-ridden on the command line using long-style flags (prefixed by --) by the same name
  as the [supported properties](#module-configuration)

  For example, you can use the `--port` option to specify or override the port property.

    * `--clean` - Discard the cached previous application image and perform a full application
      flash. This does not erase the whole device.

    * `--trust-flash-content` - Skip esptool's check of unchanged flash content. This is faster,
      but should only be used when the device has not been erased, flashed by another tool, or
      replaced since the previous successful flash.

    * `--max-size` - Override the maximum application AVM size in decimal or hexadecimal bytes.
      Only increase this when the device partition table provides a larger `main.avm` partition.

    * `--no-compress` - Disable esptool serial compression. Compression is enabled by default;
      this option is primarily useful for benchmarking or troubleshooting.

  ## Differential flashing

  After a successful flash, ExAtomVM caches the application image below the Mix build directory.
  When that image is present and esptool supports `--diff-with`, later flashes only rewrite changed
  4KB sectors. The cache is updated only after esptool reports success.

  ESP32 application images use esptool's default serial compression. This is particularly useful
  for clean flashes of development images containing zero-filled slot padding.

  `--trust-flash-content` is never enabled automatically. Without it, esptool verifies the expected
  flash contents and falls back to a full application rewrite if they do not match. `mix clean` and
  `mix atomvm.esp32.flash --clean` both discard the differential-flashing baseline.
  """

  alias Mix.Project
  alias Mix.Tasks.Atomvm.Packbeam

  @esp_tool_path "/components/esptool_py/esptool/esptool.py"
  @default_max_size 0x100000

  def run(args) do
    config = Project.config()

    with {:atomvm, {:ok, avm_config}} <- {:atomvm, Keyword.fetch(config, :atomvm)},
         {:args, {:ok, options}} <- {:args, parse_args(args)},
         {:pack, {:ok, _}} <- {:pack, Packbeam.run(args, packbeam_options())},
         idf_path <- System.get_env("IDF_PATH", <<"">>) do
      chip = Map.get(options, :chip, Keyword.get(avm_config, :chip, "auto"))
      port = Map.get(options, :port, Keyword.get(avm_config, :port, "/dev/ttyUSB0"))
      baud = Map.get(options, :baud, Keyword.get(avm_config, :baud, "115200"))

      flash_offset =
        Map.get(options, :flash_offset, Keyword.get(avm_config, :flash_offset, 0x250000))

      flash(idf_path, chip, port, baud, flash_offset,
        clean: Map.get(options, :clean, false),
        trust_flash_content: Map.get(options, :trust_flash_content, false),
        no_compress: Map.get(options, :no_compress, false)
      )
    else
      {:atomvm, :error} ->
        IO.puts("error: missing AtomVM project config.")
        exit({:shutdown, 1})

      {:args, :error} ->
        IO.puts("Syntax: ")
        exit({:shutdown, 1})

      {:pack, _} ->
        IO.puts("error: failed PackBEAM, target will not be flashed.")
        exit({:shutdown, 1})
    end
  end

  @doc false
  def default_max_size, do: @default_max_size

  @doc false
  def packbeam_options(env \\ Mix.env()) do
    [max_size: default_max_size(), slot_modules: env == :dev]
  end

  def flash(idf_path, chip, port, baud, flash_offset, opts \\ []) do
    app = Project.config()[:app]
    image_path = Path.expand("#{app}.avm")
    cache_path = flash_cache_path(app, flash_offset)

    if Keyword.get(opts, :clean, false) do
      clear_flash_cache(cache_path)
    end

    previous_image = if File.regular?(cache_path), do: cache_path
    trust_flash_content = Keyword.get(opts, :trust_flash_content, false)
    no_compress = Keyword.get(opts, :no_compress, false)

    case Code.ensure_loaded(Pythonx) do
      {:module, Pythonx} ->
        IO.puts("Flashing using Pythonx installed esptool..")
        ExAtomVM.EsptoolHelper.setup()

        tool_args =
          flash_tool_args(chip, port, baud, flash_offset, image_path,
            previous_image: previous_image,
            trust_flash_content: trust_flash_content,
            no_compress: no_compress,
            modern: true
          )

        report_differential_flash(previous_image, trust_flash_content)

        case ExAtomVM.EsptoolHelper.flash_pythonx(tool_args) do
          true ->
            save_flash_cache(image_path, cache_path)
            :ok

          false ->
            exit({:shutdown, 1})
        end

      _ ->
        IO.puts("Flashing using esptool..")
        tool_full_path = get_esptool_path(idf_path)
        {tool_exec, prefix_args} = resolve_esptool_exec(tool_full_path, idf_path)

        diff_supported =
          is_nil(previous_image) or esptool_supports_diff?(tool_exec, prefix_args)

        previous_image = if diff_supported, do: previous_image
        effective_trust = trust_flash_content and diff_supported

        if not diff_supported do
          IO.puts(
            "Cached application image found, but this esptool does not support --diff-with; performing a full application flash."
          )
        end

        tool_args =
          flash_tool_args(chip, port, baud, flash_offset, image_path,
            previous_image: previous_image,
            trust_flash_content: effective_trust,
            no_compress: no_compress
          )

        report_differential_flash(previous_image, effective_trust)

        case System.cmd(
               tool_exec,
               prefix_args ++ tool_args,
               stderr_to_stdout: true,
               into: IO.stream(:stdio, 1)
             ) do
          {_, 0} ->
            save_flash_cache(image_path, cache_path)
            :ok

          {_, _status} ->
            exit({:shutdown, 1})
        end
    end
  end

  @doc false
  def flash_tool_args(chip, port, baud, flash_offset, image_path, opts \\ []) do
    modern? = Keyword.get(opts, :modern, false)

    compression_args =
      if Keyword.get(opts, :no_compress, false) do
        [if(modern?, do: "--no-compress", else: "-u")]
      else
        []
      end

    tool_args =
      [
        "--chip",
        chip,
        "--baud",
        baud,
        "--before",
        "default_reset",
        "--after",
        "hard_reset",
        "write_flash"
      ] ++
        compression_args ++
        [
          "--flash_mode",
          "keep",
          "--flash_freq",
          "keep",
          "--flash_size",
          "detect",
          "0x#{Integer.to_string(flash_offset, 16)}",
          image_path
        ]

    tool_args = if port == "auto", do: tool_args, else: ["--port", port] ++ tool_args

    tool_args =
      case Keyword.get(opts, :previous_image) do
        nil -> tool_args
        previous_image -> tool_args ++ ["--diff-with", previous_image]
      end

    tool_args =
      if Keyword.get(opts, :trust_flash_content, false) and
           not is_nil(Keyword.get(opts, :previous_image)) do
        tool_args ++ ["--trust-flash-content"]
      else
        tool_args
      end

    if modern? do
      # Avoid deprecation warnings for the pinned Pythonx esptool 5.x.
      Enum.map(tool_args, fn
        "--flash_mode" -> "--flash-mode"
        "--flash_freq" -> "--flash-freq"
        "--flash_size" -> "--flash-size"
        "default_reset" -> "default-reset"
        "hard_reset" -> "hard-reset"
        "write_flash" -> "write-flash"
        arg -> arg
      end)
    else
      tool_args
    end
  end

  @doc false
  def flash_cache_path(app, flash_offset, manifest_path \\ Project.manifest_path()) do
    filename = "#{app}-0x#{Integer.to_string(flash_offset, 16)}.avm"

    [manifest_path, "atomvm", "esp32", "flash", filename]
    |> Path.join()
    |> Path.expand()
  end

  @doc false
  def cache_flash_image(image_path, cache_path) do
    with :ok <- File.mkdir_p(Path.dirname(cache_path)),
         :ok <- File.cp(image_path, cache_path) do
      :ok
    end
  end

  defp clear_flash_cache(cache_path) do
    case File.rm(cache_path) do
      :ok ->
        IO.puts("Discarded cached application image; performing a full application flash.")

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Mix.raise("Could not remove cached application image #{cache_path}: #{inspect(reason)}")
    end
  end

  defp save_flash_cache(image_path, cache_path) do
    case cache_flash_image(image_path, cache_path) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.warn(
          "Flash succeeded, but the differential-flashing cache could not be updated: #{inspect(reason)}"
        )
    end
  end

  defp report_differential_flash(nil, true) do
    IO.puts(
      "--trust-flash-content requires a previous successful flash; performing a full application flash and establishing a baseline."
    )
  end

  defp report_differential_flash(nil, false), do: :ok

  defp report_differential_flash(previous_image, trust_flash_content) do
    message = "Using cached application image for differential flashing: #{previous_image}"

    if trust_flash_content do
      IO.puts(message <> " (trusting unchanged flash content)")
    else
      IO.puts(message)
    end
  end

  defp esptool_supports_diff?(tool_exec, prefix_args) do
    case System.cmd(tool_exec, prefix_args ++ ["write_flash", "--help"], stderr_to_stdout: true) do
      {help, 0} -> String.contains?(help, "--diff-with")
      _ -> false
    end
  end

  defp get_esptool_path(<<"">>) do
    "esptool.py"
  end

  defp get_esptool_path(idf_path) do
    "#{idf_path}#{@esp_tool_path}"
  end

  defp resolve_esptool_exec(tool_full_path, <<"">>) do
    # IDF_PATH is not set: run esptool from PATH (usually "esptool.py").
    {tool_full_path, []}
  end

  defp resolve_esptool_exec(tool_full_path, _idf_path) do
    # IDF_PATH is set: tool_full_path is ESP-IDF's esptool.py.
    # Some ESP-IDF installs ship it without the executable bit, so run it via python.
    if not File.exists?(tool_full_path) do
      Mix.raise("""
      IDF_PATH is set, but esptool.py was not found: #{tool_full_path}
      Try: env -u IDF_PATH mix atomvm.esp32.flash ...  (or install esptool)
      """)
    end

    python = System.find_executable("python") || System.find_executable("python3")

    if is_nil(python) do
      Mix.raise("""
      IDF_PATH is set, but python is missing from PATH
      Try: env -u IDF_PATH mix atomvm.esp32.flash ...  (or install python3)
      """)
    end

    {python, [tool_full_path]}
  end

  @doc false
  def parse_options(args) do
    parse_args(args, %{})
  end

  defp parse_args(args), do: parse_options(args)

  defp parse_args([], accum) do
    {:ok, accum}
  end

  defp parse_args([<<"--port">>, port | t], accum) do
    parse_args(t, Map.put(accum, :port, port))
  end

  defp parse_args([<<"--baud">>, baud | t], accum) do
    parse_args(t, Map.put(accum, :baud, baud))
  end

  defp parse_args([<<"--chip">>, chip | t], accum) do
    parse_args(t, Map.put(accum, :chip, chip))
  end

  defp parse_args([<<"--clean">> | t], accum) do
    parse_args(t, Map.put(accum, :clean, true))
  end

  defp parse_args([<<"--trust-flash-content">> | t], accum) do
    parse_args(t, Map.put(accum, :trust_flash_content, true))
  end

  defp parse_args([<<"--no-compress">> | t], accum) do
    parse_args(t, Map.put(accum, :no_compress, true))
  end

  defp parse_args([<<"--flash_offset">>, "0x" <> hex = _flash_offset | t], accum) do
    {offset, _} = Integer.parse(hex, 16)
    parse_args(t, Map.put(accum, :flash_offset, offset))
  end

  defp parse_args([_ | t], accum) do
    parse_args(t, accum)
  end
end
