defmodule Mix.Tasks.Atomvm.Esp32.Build do
  @moduledoc """
  Mix task for building AtomVM for ESP32 from source.

  Builds AtomVM from a local repository or git URL using ESP-IDF.

  ## Requirements

  **General requirements**
    * Erlang/OTP (27 or later)
    * Elixir (1.18 or later)
    * Git
    * CMake (3.13 or later)
    * Ninja (preferred) or Make

  **Without Docker:**
    * ESP-IDF (v5.5.4 or later recommended)
    * On macOS, AtomVM's generic Unix build needs MbedTLS 3.x. Homebrew's
      default `mbedtls` is 4.x, so pass
      `--mbedtls-prefix /opt/homebrew/opt/mbedtls@3 --clean` (see the README)

  **With Docker (--use-docker flag):**
    * Docker
    * Note: Docker build support requires AtomVM main branch from Jan 2, 2026 or later (https://github.com/atomvm/AtomVM/commit/2a4f0d0fe100ef6d440bef86eabfd08c5b290f6c).
      Previous AtomVM versions must be built with the local ESP-IDF toolchain installed.

  ## Options

    * `--atomvm-path` - Path to local AtomVM repository (optional, overrides URL if both provided)
    * `--atomvm-url` - Git URL to clone AtomVM from (optional, defaults to AtomVM/AtomVM main branch)
    * `--ref` - Git reference to checkout - branch, tag, commit SHA, or PR (e.g. `pr/1234` or `pull/1234/head`) (default: main)
    * `--chip` - Target chip(s), comma-separated for multiple (default: esp32, options: esp32, esp32s2, esp32s3, esp32c2, esp32c3, esp32c6, esp32h2, esp32p4)
    * `--idf-path` - Path to idf.py executable (default: idf.py)
    * `--use-docker` - Use ESP-IDF Docker image instead of local installation
    * `--idf-version` - ESP-IDF version for Docker image (default: v5.5.4)
    * `--clean` - Clean the build directory and the generated sdkconfig before building,
      so ESP-IDF regenerates the configuration
    * `--mbedtls-prefix` - Path to custom MbedTLS installation (optional, falls back to MBEDTLS_PREFIX env var)
    * `--partition-table` - Path to custom partition table CSV file (optional, defaults to custom_partitions.csv if present)
    * `--sdkconfig` - Path to custom sdkconfig.defaults file (optional, defaults to sdkconfig.defaults if present)
    * `--matrix` - Build(s) from the `atomvm_builder` configuration: a name, comma-separated names, or `all`
    * `--list-matrix` - Resolve the configured builds, print them, and exit without building
    * `--format` - With `--list-matrix`, `text` (default) or `json`
    * `--output` - With `--list-matrix`, write the plan to this file instead of stdout
    * `--with-zips` - Also write the flashable bundle next to each image (default: off)

  If `--partition-table` is provided, or if your Mix project root contains `custom_partitions.csv`,
  it will be used as the ESP32 partition table for the build. ExAtomVM passes the contents
  through unchanged, without imposing partition names, types, offsets, or sizes. The selected
  file must be readable, non-empty, and regular; AtomVM and ESP-IDF handle its contents.

  ## Build matrix

  `--matrix` builds named ESP32 builds declared in `mix.exs` under
  `atomvm_builder`. Each build has its own chips and, in a directory named after
  it, its own component manifest, sdkconfig defaults, and partition table:

      atomvm_builder: [
        plain: [chips: ["esp32"]],
        full: [chips: ["esp32s3"]]
      ]

      atomvm_builder/full/
        idf_component.yml
        dependencies.lock
        sdkconfig.defaults
        sdkconfig.defaults.esp32s3
        custom_partitions.csv

  Explicit `dir`, `components`, `lock`, `sdkconfig`, and `partitions` options
  override the convention, and a missing file means no customization on that
  axis. `cmake_args` passes extra arguments to `idf.py`, as a list of strings
  or a single string, for example
  `["-DAVM_USE_LIBSODIUM=ON", "-DATOMIC_POINTER_LOCK_FREE_IS_TWO=1"]`. Inputs
  are staged into the AtomVM checkout for the build and restored afterwards;
  matrix builds always start from a clean ESP32 build directory. Each image is
  written as `atomvm-<chip>-<build>-elixir.img`, and `--chip` overrides the
  chips of every selected build. With `--with-zips`, the build also writes next
  to the image the bundle `mix atomvm.esp32.install` reads, with the parts of
  the image, the sdkconfig and partition table it was built with, FLASH.txt,
  checksums, and the ELF and map files.

  Builds may select shared `features`, declared under the reserved `features`
  key, which contribute an sdkconfig fragment and CMake arguments:

      atomvm_builder: [
        features: [
          psram: [
            sdkconfig: "atomvm_builder/features/psram.sdkconfig",
            cmake_args: ["-DATOMIC_POINTER_LOCK_FREE_IS_TWO=1"]
          ]
        ],
        full: [chips: ["esp32s3"], features: ["psram"]]
      ]

  A fragment is appended before the build's own sdkconfig files, so the build
  can override a feature. Two selected features setting the same CONFIG_ key is
  an error, and a fragment holds only CONFIG_* assignments, "# CONFIG_* is not
  set" lines, and comments. Components stay one file per build.

  ## Examples

      # Build from local repository
      mix atomvm.esp32.build --atomvm-path /path/to/AtomVM

      # Build from git URL
      mix atomvm.esp32.build --atomvm-url https://github.com/atomvm/AtomVM --ref main

      # Build from specific tag
      mix atomvm.esp32.build --atomvm-url https://github.com/atomvm/AtomVM --ref v0.6.5

      # Build from specific commit
      mix atomvm.esp32.build --atomvm-url https://github.com/atomvm/AtomVM --ref abc123def

      # Build for specific chip with clean build
      mix atomvm.esp32.build --atomvm-path /path/to/AtomVM --chip esp32s3 --clean

      # Build using Docker (relative paths are expanded automatically)
      mix atomvm.esp32.build --atomvm-path ./_build/atomvm_source/AtomVM/ --use-docker --chip esp32s3

      # Build using Docker with specific IDF version
      mix atomvm.esp32.build --atomvm-path ./_build/atomvm_source/AtomVM/ --use-docker --idf-version v5.5.4 --chip esp32s3

      # Build with custom MbedTLS
      mix atomvm.esp32.build --atomvm-path /path/to/AtomVM --mbedtls-prefix /usr/local/opt/mbedtls@3

      # Build with custom sdkconfig defaults
      mix atomvm.esp32.build --sdkconfig path/to/my_config.defaults

      # Build from a pull request (shorthand)
      mix atomvm.esp32.build --ref pr/1234

      # Build from a pull request (full refspec)
      mix atomvm.esp32.build --ref pull/1234/head --chip esp32s3

      # Build for multiple chips
      mix atomvm.esp32.build --chip esp32,esp32s3,esp32c6

      # Build one configured build, several, or every one of them
      mix atomvm.esp32.build --matrix full
      mix atomvm.esp32.build --matrix full,cam
      mix atomvm.esp32.build --matrix all

      # Show the resolved builds, or emit a CI matrix
      mix atomvm.esp32.build --list-matrix
      mix atomvm.esp32.build --list-matrix --format json --output matrix.json

  """
  use Mix.Task
  alias ExAtomVM.Esp32BuildMatrix
  alias ExAtomVM.Esp32BuildStaging
  alias ExAtomVM.Esp32CustomComponents
  alias ExAtomVM.Esp32CustomPartitions
  alias ExAtomVM.Esp32FirmwareBundle

  @shortdoc "Build AtomVM for ESP32 from source"

  @default_chip "esp32"
  @default_ref "main"
  @default_atomvm_url "https://github.com/atomvm/AtomVM"
  @default_idf_path "idf.py"
  @default_idf_version "v5.5.4"
  @elixir_cmake_arg "-DATOMVM_ELIXIR_SUPPORT=on"

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [
          atomvm_path: :string,
          atomvm_url: :string,
          ref: :string,
          chip: :string,
          idf_path: :string,
          use_docker: :boolean,
          idf_version: :string,
          clean: :boolean,
          mbedtls_prefix: :string,
          partition_table: :string,
          sdkconfig: :string,
          matrix: :string,
          list_matrix: :boolean,
          format: :string,
          output: :string,
          with_zips: :boolean
        ]
      )

    if not Keyword.get(opts, :list_matrix, false) and
         (Keyword.has_key?(opts, :format) or Keyword.has_key?(opts, :output)) do
      error_exit("--format and --output only apply to --list-matrix")
    end

    cond do
      Keyword.get(opts, :list_matrix, false) ->
        list_matrix(opts)

      matrix = Keyword.get(opts, :matrix) ->
        execute(builds_for_matrix(matrix, opts), opts)

      true ->
        execute([legacy_build(opts)], opts)
    end
  end

  # Resolves and prints the configured builds instead of building them.
  defp list_matrix(opts) do
    if Keyword.has_key?(opts, :partition_table) or Keyword.has_key?(opts, :sdkconfig) do
      error_exit("--partition-table and --sdkconfig cannot be combined with --list-matrix")
    end

    selection =
      case Keyword.get(opts, :matrix) do
        nil -> :all
        names -> parse_selection(names)
      end

    case Esp32BuildMatrix.resolve(Esp32BuildMatrix.config(), selection) do
      {:ok, builds} ->
        plan = render_plan(builds, Keyword.get(opts, :format, "text"))

        case Keyword.get(opts, :output) do
          nil -> IO.write(plan)
          path -> write_plan(path, plan)
        end

      {:error, reason} ->
        error_exit(reason)
    end
  end

  defp render_plan(builds, "text"), do: plan_text(builds)
  defp render_plan(builds, "json"), do: Esp32BuildMatrix.to_json(builds) <> "\n"

  defp render_plan(_builds, format) do
    error_exit("unknown --format #{inspect(format)}; use text or json")
  end

  defp plan_text(builds) do
    plans = Esp32BuildMatrix.plan(builds)

    body =
      Enum.map_join(plans, "\n", fn plan ->
        [
          "  #{plan.name}: #{Enum.join(plan.chips, ", ")}",
          "    directory: #{plan.dir}",
          plan.features != [] && "    features: #{Enum.join(plan.features, ", ")}",
          plan.cmake_args != [] && "    cmake_args: #{Enum.join(plan.cmake_args, " ")}",
          plan.components && "    components: #{plan.components}",
          plan.sdkconfig && "    sdkconfig: #{plan.sdkconfig}",
          plan.partition_table && "    partitions: #{plan.partition_table}",
          Enum.map(plan.images, &"    image: #{&1}")
        ]
        |> List.flatten()
        |> Enum.reject(&(&1 in [nil, false]))
        |> Enum.join("\n")
      end)

    "Build matrix (#{length(plans)} build(s))\n\n" <> body <> "\n"
  end

  defp write_plan(path, content) do
    path = Path.expand(path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    IO.puts("Wrote #{Path.relative_to_cwd(path)}")
  end

  # Matrix builds are resolved before anything is cloned or built, so a broken
  # configuration fails fast.
  defp builds_for_matrix(selection, opts) do
    if Keyword.has_key?(opts, :partition_table) or Keyword.has_key?(opts, :sdkconfig) do
      error_exit(
        "--partition-table and --sdkconfig cannot be combined with --matrix; " <>
          "configure them per build in atomvm_builder"
      )
    end

    builds =
      case Esp32BuildMatrix.resolve(Esp32BuildMatrix.config(), parse_selection(selection)) do
        {:ok, builds} -> builds
        {:error, reason} -> error_exit(reason)
      end

    case Keyword.get(opts, :chip) do
      nil -> builds
      chip -> Enum.map(builds, &%{&1 | chips: parse_chips(chip)})
    end
  end

  # Without --matrix there is one implicit build, configured from the project
  # root like before.
  defp legacy_build(opts) do
    partition_table =
      case Esp32CustomPartitions.load_custom_partitions(Keyword.get(opts, :partition_table)) do
        {:ok, selected} -> selected
        {:error, reason} -> error_exit(reason)
      end

    components =
      case Esp32CustomComponents.load_custom_components(nil) do
        {:ok, selected} -> selected
        {:error, reason} -> error_exit(reason)
      end

    %{
      name: nil,
      dir: nil,
      chips: parse_chips(Keyword.get(opts, :chip, @default_chip)),
      features: [],
      feature_sdkconfigs: [],
      cmake_args: [],
      components: components,
      sdkconfig: Keyword.get(opts, :sdkconfig),
      partition_table: partition_table
    }
  end

  defp parse_selection(value) do
    case value |> String.split(",", trim: true) |> Enum.map(&String.trim/1) do
      [] -> :all
      ["all"] -> :all
      names -> names
    end
  end

  defp parse_chips(value) do
    value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

  defp execute(builds, opts) do
    idf_path = Keyword.get(opts, :idf_path, @default_idf_path)
    use_docker = Keyword.get(opts, :use_docker, false)
    idf_version = Keyword.get(opts, :idf_version, @default_idf_version)
    clean = Keyword.get(opts, :clean, false)
    mbedtls_prefix = Keyword.get(opts, :mbedtls_prefix) || System.get_env("MBEDTLS_PREFIX")
    matrix? = Enum.any?(builds, &(&1.name != nil))

    context = %{
      idf_path: idf_path,
      idf_version: idf_version,
      use_docker: use_docker,
      clean: clean,
      matrix?: matrix?,
      with_zips?: Keyword.get(opts, :with_zips, false)
    }

    # Use --atomvm-path, --atomvm-url, or default to AtomVM/AtomVM main branch.
    # Expand to an absolute path so Docker bind mounts (`-v <host>:/project`)
    # and any later relative-path math work consistently.
    atomvm_path =
      case Keyword.get(opts, :atomvm_path) do
        nil ->
          ExAtomVM.AtomVMBuilder.clone_or_update_repo(
            Keyword.get(opts, :atomvm_url, @default_atomvm_url),
            Keyword.get(opts, :ref, @default_ref)
          )

        atomvm_path ->
          atomvm_path
      end
      |> Path.expand()

    # Verify AtomVM path exists
    unless File.dir?(atomvm_path) do
      error_exit("AtomVM path does not exist: #{atomvm_path}")
    end

    IO.puts(banner(builds, atomvm_path, clean, matrix?))

    with :ok <- validate_builds(builds),
         :ok <- check_esp_idf(idf_path, use_docker, idf_version),
         :ok <- check_escript(),
         :ok <- ExAtomVM.AtomVMBuilder.build_generic_unix(atomvm_path, mbedtls_prefix, clean) do
      if not matrix? and is_nil(hd(builds).components), do: offer_component_example()

      results =
        Enum.flat_map(builds, fn build ->
          build.chips
          |> Enum.with_index(1)
          |> Enum.map(fn {chip, index} ->
            build_chip(build, chip, index, atomvm_path, context)
          end)
        end)

      print_summary(results)

      if Enum.any?(results, fn {_name, _chip, status, _detail} -> status == :error end) do
        exit({:shutdown, 1})
      end
    else
      {:error, reason} ->
        error_exit(reason)
    end
  end

  defp banner(builds, atomvm_path, _clean, true) do
    builds_label = Enum.map_join(builds, ", ", &"#{&1.name} (#{Enum.join(&1.chips, ", ")})")

    """

    Building AtomVM from source
    Repository: #{atomvm_path}
    Build(s): #{builds_label}
    Clean build: always (each build stages its own inputs)

    """
  end

  defp banner([build], atomvm_path, clean, false) do
    """

    Building AtomVM from source
    Repository: #{atomvm_path}
    Chip(s): #{Enum.join(build.chips, ", ")}
    Clean build: #{clean}

    """
  end

  defp build_chip(build, chip, index, atomvm_path, context) do
    %{
      idf_path: idf_path,
      idf_version: idf_version,
      use_docker: use_docker,
      clean: clean,
      matrix?: matrix?,
      with_zips?: with_zips?
    } = context

    total = length(build.chips)

    cond do
      matrix? ->
        IO.puts("\n━━━ Building #{build.name}: #{chip} (#{index}/#{total}) ━━━\n")

      total > 1 ->
        IO.puts("\n━━━ Building chip #{index}/#{total}: #{chip} ━━━\n")

      true ->
        :ok
    end

    custom_sdkconfig? =
      build.feature_sdkconfigs != [] or
        match?({:ok, _}, custom_sdkconfig_paths(build.sdkconfig, chip))

    if not matrix? and not clean do
      warn_forced_clean(build, chip, custom_sdkconfig?)
    end

    force_clean =
      clean or matrix? or index > 1 or not is_nil(build.partition_table) or custom_sdkconfig?

    case build_atomvm(atomvm_path, chip, idf_path, idf_version, use_docker, force_clean, build) do
      {:ok, src_img} ->
        img = save_image(src_img)

        if with_zips? do
          case write_bundle(build, chip, img, atomvm_path) do
            {:ok, zip} ->
              IO.puts("Wrote #{zip}")
              {build.name, chip, :ok, img}

            {:error, reason} ->
              {build.name, chip, :error, reason}
          end
        else
          {build.name, chip, :ok, img}
        end

      {:error, reason} ->
        {build.name, chip, :error, reason}
    end
  end

  # With --with-zips, every image is also written as the bundle
  # `mix atomvm.esp32.install` reads, next to the image: the parts of the image,
  # the config it was built with, FLASH.txt, checksums, and the ELF and map
  # files.
  defp write_bundle(build, chip, image_path, atomvm_path) do
    platform_dir = Path.join([atomvm_path, "src", "platforms", "esp32"])

    options = %{
      stem: Path.basename(image_path, ".img"),
      image: image_path,
      build_dir: Path.join(platform_dir, "build"),
      platform_dir: platform_dir,
      chip: chip,
      partitions: build.partition_table && build.partition_table.content
    }

    case Esp32FirmwareBundle.write(options) do
      {:ok, zip} -> {:ok, relative_path(zip, File.cwd!())}
      {:error, reason} -> {:error, "could not write the bundle: #{reason}"}
    end
  end

  defp warn_forced_clean(build, chip, custom_sdkconfig?) do
    if build.partition_table do
      filename = Path.basename(build.partition_table.path)

      IO.puts(
        "#{filename} detected; forcing clean ESP32 platform build so partition metadata is regenerated..."
      )
    end

    if custom_sdkconfig? do
      case custom_sdkconfig_paths(build.sdkconfig, chip) do
        {:ok, {base, chip_spec}} ->
          files =
            [base, chip_spec]
            |> Enum.filter(& &1)
            |> Enum.map(&Path.basename/1)
            |> Enum.join(" and ")

          IO.puts(
            "Custom sdkconfig (#{files}) detected; forcing clean ESP32 platform build so configurations are regenerated..."
          )

        _ ->
          :ok
      end
    end
  end

  defp validate_builds(builds) do
    Enum.reduce_while(builds, :ok, fn build, :ok ->
      case validate_build_sdkconfigs(build) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_build_sdkconfigs(build) do
    Enum.reduce_while(build.chips, :ok, fn chip, :ok ->
      case validate_sdkconfigs(build.sdkconfig, chip) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, build_error(build, reason)}}
      end
    end)
  end

  defp build_error(%{name: nil}, reason), do: reason
  defp build_error(%{name: name}, reason), do: "#{name}: #{reason}"

  defp error_exit(reason) do
    IO.puts("Error: #{reason}")
    exit({:shutdown, 1})
  end

  defp print_summary(results) do
    IO.puts("\n━━━ Build Summary ━━━\n")

    cwd = File.cwd!()

    Enum.each(results, fn
      {name, chip, :ok, img} ->
        label = summary_label(name, chip)

        if File.exists?(img) do
          IO.puts("  ✅ #{label}: #{img}")
        else
          IO.puts("  ⚠️  #{label}: built but image not found at #{img}")
        end

      {name, chip, :error, reason} ->
        IO.puts("  ❌ #{summary_label(name, chip)}: #{reason}")
    end)

    successful =
      Enum.filter(results, fn {_name, _chip, status, img} ->
        status == :ok and File.exists?(img)
      end)

    if successful != [] do
      IO.puts("\nTo flash a specific image:")

      Enum.each(successful, fn {_name, _chip, _status, img} ->
        IO.puts("  mix atomvm.esp32.install --image #{relative_path(img, cwd)}")
      end)
    end

    IO.puts("")
  end

  defp summary_label(nil, chip), do: chip
  defp summary_label(name, chip), do: "#{name} (#{chip})"

  defp relative_path(path, cwd) do
    Path.relative_to(path, cwd, force: true)
  end

  defp check_escript do
    case System.find_executable("escript") do
      nil ->
        {:error, "escript not found. Please install Erlang/OTP and ensure escript is on PATH."}

      _ ->
        :ok
    end
  end

  defp save_image(src_img) do
    output_dir = Path.join([File.cwd!(), "_build", "atomvm_images"])
    File.mkdir_p!(output_dir)
    dest_img = Path.join(output_dir, Path.basename(src_img))

    if File.exists?(src_img) do
      File.cp!(src_img, dest_img)
      dest_img
    else
      src_img
    end
  end

  defp check_esp_idf(idf_path, use_docker, idf_version) do
    if use_docker do
      case System.find_executable("docker") do
        nil ->
          {:error,
           """
           Docker not found. Please install Docker:

           https://docs.docker.com/get-docker/
           """}

        docker_path ->
          IO.puts("Found Docker: #{docker_path}")
          IO.puts("Using ESP-IDF Docker image: espressif/idf:#{idf_version}")
          :ok
      end
    else
      case System.find_executable(idf_path) do
        nil ->
          {:error,
           """
           ESP-IDF not found in the current environment.

           If ESP-IDF is already installed, activate it in this shell with:

             get_idf

           If the get_idf alias is not configured, source the export script directly:

             . "$HOME/esp/esp-idf/export.sh"

           To install ESP-IDF, follow Espressif's setup guide:

           https://docs.espressif.com/projects/esp-idf/en/latest/esp32/get-started/

           Alternatively, use --use-docker to build with Espressif's ESP-IDF Docker image.
           """}

        idf_path_found ->
          IO.puts("Found ESP-IDF: #{idf_path_found}")
          :ok
      end
    end
  end

  defp build_atomvm(atomvm_path, chip, idf_path, idf_version, use_docker, clean, build) do
    build_dir = Path.join([atomvm_path, "src", "platforms", "esp32", "build"])
    platform_dir = Path.join([atomvm_path, "src", "platforms", "esp32"])

    Esp32CustomPartitions.with_custom_partitions(platform_dir, build.partition_table, fn ->
      with_staged_sdkconfig(platform_dir, chip, build, fn ->
        Esp32CustomComponents.with_custom_components(platform_dir, build.components, fn ->
          if clean do
            if File.dir?(build_dir) do
              IO.puts("Cleaning build directory...")
              ExAtomVM.AtomVMBuilder.clean_dir(build_dir)
            end

            reset_generated_sdkconfig(platform_dir)
          end

          IO.puts("Configuring build for #{chip}...")

          {_output, status} =
            run_idf_command(
              use_docker,
              idf_version,
              atomvm_path,
              platform_dir,
              idf_path,
              idf_set_target_args(chip, build.cmake_args)
            )

          case status do
            0 ->
              IO.puts("Building AtomVM... (this may take several minutes)")

              {_output, build_status} =
                run_idf_command(
                  use_docker,
                  idf_version,
                  atomvm_path,
                  platform_dir,
                  idf_path,
                  idf_build_args(build.cmake_args)
                )

              case build_status do
                0 ->
                  create_flashable_image(
                    Path.expand(atomvm_path),
                    Path.expand(build_dir),
                    use_docker,
                    Esp32BuildMatrix.image_stem(build.name, chip)
                  )

                _status ->
                  {:error, "Build failed"}
              end

            _status ->
              {:error, "Failed to set target chip"}
          end
        end)
      end)
    end)
  end

  defp idf_set_target_args(chip, cmake_args) do
    [@elixir_cmake_arg] ++ cmake_args ++ ["set-target", chip]
  end

  defp idf_build_args(cmake_args) do
    [@elixir_cmake_arg] ++ cmake_args ++ ["build"]
  end

  # ESP-IDF keeps the generated sdkconfig, and its values win over
  # sdkconfig.defaults, so settings a previous build left behind (flash size,
  # PSRAM, ...) would leak into this one. A clean build regenerates it from
  # AtomVM's defaults and the staged sdkconfig files.
  defp reset_generated_sdkconfig(platform_dir) do
    removed =
      for name <- ["sdkconfig", "sdkconfig.old"],
          path = Path.join(platform_dir, name),
          File.exists?(path) do
        File.rm!(path)
        name
      end

    if removed != [] do
      IO.puts("Removing generated #{Enum.join(removed, " and ")}...")
    end
  end

  defp run_idf_command(true, idf_version, atomvm_path, platform_dir, _idf_path, idf_args) do
    run_idf_docker(idf_version, atomvm_path, platform_dir, idf_args)
  end

  defp run_idf_command(false, _idf_version, _atomvm_path, platform_dir, idf_path, idf_args) do
    System.cmd(idf_path, idf_args,
      cd: platform_dir,
      stderr_to_stdout: true,
      into: IO.stream(:stdio, :line)
    )
  end

  defp offer_component_example do
    example_path = Path.join(File.cwd!(), "idf_component.yml.example")

    unless File.exists?(example_path) do
      example_src = Application.app_dir(:exatomvm, "priv/idf_component.yml.example")
      File.cp!(example_src, example_path)
    end

    IO.puts(
      "Hint: To add ESP-IDF components (e.g. NIFs), rename the example in your project root:\n" <>
        "      mv idf_component.yml.example idf_component.yml"
    )
  end

  defp create_flashable_image(atomvm_path, build_dir, use_docker, stem) do
    mkimage_erl = Path.join(build_dir, "mkimage.erl")
    mkimage_config = Path.join(build_dir, "mkimage.config")
    output_img = Path.join(build_dir, "#{stem}.img")

    cond do
      not File.exists?(mkimage_erl) ->
        {:error, "mkimage.erl not found in #{build_dir}"}

      not File.exists?(mkimage_config) ->
        {:error, "mkimage.config not found in #{build_dir}"}

      stock_esp32boot_configured?(mkimage_config) ->
        {:error,
         "mkimage.config still points at stock esp32boot.avm. " <>
           "The ESP32 build was not configured with AtomVM Elixir support; " <>
           "retry with --clean, and ensure the AtomVM ref honours -DATOMVM_ELIXIR_SUPPORT=on " <>
           "(older AtomVM revisions predate this CMake option)."}

      no_boot_library_configured?(mkimage_config) ->
        {:error,
         "mkimage.config configures no boot library. AtomVM selects it from the " <>
           "partition table's main.avm offset, so a custom partition table has to keep " <>
           "main.avm at 0x250000 (0x300000 for a JIT build); boot.avm can sit anywhere, " <>
           "it is found by partition name."}

      true ->
        IO.puts("Creating flashable image...")
        run_mkimage(atomvm_path, build_dir, mkimage_erl, mkimage_config, output_img, use_docker)
    end
  end

  defp stock_esp32boot_configured?(mkimage_config) do
    mkimage_config
    |> File.read!()
    |> String.contains?("esp32boot/esp32boot.avm")
  end

  # AtomVM's GetBootAVM.cmake sets the boot library to NONE when the partition
  # table's main.avm offset is neither 0x250000 nor 0x300000.
  defp no_boot_library_configured?(mkimage_config) do
    mkimage_config
    |> File.read!()
    |> String.contains?("esp32boot/NONE")
  end

  defp run_mkimage(atomvm_path, build_dir, mkimage_erl, mkimage_config, output_img, use_docker) do
    case System.find_executable("escript") do
      nil ->
        {:error, "escript not found. Please install Erlang/OTP and ensure escript is on PATH."}

      escript ->
        # Only Docker-generated configs reference container `/project` paths and
        # need localizing; local builds already contain valid host paths.
        local_config =
          if use_docker do
            local_mkimage_config(atomvm_path, build_dir, mkimage_config)
          else
            mkimage_config
          end

        {_output, status} =
          System.cmd(
            escript,
            [mkimage_erl, "--config", local_config, "--out", output_img],
            cd: build_dir,
            stderr_to_stdout: true,
            into: IO.stream(:stdio, :line)
          )

        case status do
          0 -> verify_output_image(output_img)
          _ -> {:error, "Failed to create image"}
        end
    end
  end

  defp verify_output_image(output_img) do
    case File.stat(output_img) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > 0 ->
        {:ok, output_img}

      {:ok, _stat} ->
        {:error, "mkimage completed but produced no valid image at #{output_img}"}

      {:error, reason} ->
        {:error,
         "mkimage completed but did not create #{output_img}: #{:file.format_error(reason)}"}
    end
  end

  defp local_mkimage_config(atomvm_path, build_dir, mkimage_config) do
    content = File.read!(mkimage_config)
    # The host path is inserted inside an Erlang double-quoted string, so escape
    # any `\` and `"` that are legal in POSIX paths but special in Erlang strings.
    replacement = escape_erlang_string_content(atomvm_path)
    # Only rewrite "/project" when it appears as a path prefix inside a quoted
    # string (i.e. followed by `/` or a closing quote), to avoid clobbering
    # unrelated tokens like "/project_backup/..." or comments.
    # Use the function form so backslashes / `\N` sequences in the replacement
    # are not interpreted as replacement escapes / backrefs by Regex.replace/3.
    local_content =
      Regex.replace(~r{(?<=")/project(?=/|")}, content, fn _ -> replacement end)

    if local_content == content do
      mkimage_config
    else
      local_config = Path.join(build_dir, "mkimage.local.config")
      File.write!(local_config, local_content)
      local_config
    end
  end

  defp escape_erlang_string_content(path) do
    path
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp run_idf_docker(idf_version, atomvm_path, platform_dir, idf_args) do
    # Calculate the relative path from atomvm_path to platform_dir
    relative_dir = Path.relative_to(platform_dir, atomvm_path)

    # Build docker command
    docker_args =
      [
        "run",
        "--rm",
        "-v",
        "#{atomvm_path}:/project",
        "-w",
        "/project/#{relative_dir}",
        "espressif/idf:#{idf_version}",
        "idf.py"
      ] ++ idf_args

    System.cmd("docker", docker_args,
      stderr_to_stdout: true,
      into: IO.stream(:stdio, :line)
    )
  end

  # Returns {:ok, {base_path, chip_path}} or {:ok, {base_path, nil}} or {:ok, {nil, chip_path}} or :error
  @doc false
  def custom_sdkconfig_paths(nil, chip) do
    default_base = Path.join(File.cwd!(), "sdkconfig.defaults")
    default_chip = Path.join(File.cwd!(), "sdkconfig.defaults.#{chip}")

    base_exists = File.exists?(default_base)
    chip_exists = File.exists?(default_chip)

    cond do
      base_exists and chip_exists -> {:ok, {default_base, default_chip}}
      base_exists -> {:ok, {default_base, nil}}
      chip_exists -> {:ok, {nil, default_chip}}
      true -> :error
    end
  end

  @doc false
  def custom_sdkconfig_paths(user_provided_path, chip) do
    base_path = Path.expand(user_provided_path)
    chip_path = "#{base_path}.#{chip}"

    base_exists = File.exists?(base_path)
    chip_exists = File.exists?(chip_path)

    cond do
      base_exists and chip_exists -> {:ok, {base_path, chip_path}}
      base_exists -> {:ok, {base_path, nil}}
      chip_exists -> {:ok, {nil, chip_path}}
      true -> :error
    end
  end

  # Validates the project's custom sdkconfig defaults up front, so an invalid file fails fast.
  @doc false
  def validate_sdkconfigs(nil, chip) do
    case custom_sdkconfig_paths(nil, chip) do
      :error ->
        :ok

      {:ok, {base_path, chip_path}} ->
        [base_path, chip_path]
        |> Enum.filter(& &1)
        |> validate_sdkconfig_files()
    end
  end

  @doc false
  def validate_sdkconfigs(user_provided_path, chip) do
    case custom_sdkconfig_paths(user_provided_path, chip) do
      :error ->
        {:error,
         "SDK config file does not exist: #{user_provided_path} (or target-specific override #{user_provided_path}.#{chip})"}

      {:ok, {base_path, chip_path}} ->
        [base_path, chip_path]
        |> Enum.filter(& &1)
        |> validate_sdkconfig_files()
    end
  end

  defp validate_sdkconfig_files(files) do
    Enum.reduce_while(files, :ok, fn path, :ok ->
      case File.stat(path) do
        {:ok, %File.Stat{type: :regular, size: 0}} ->
          {:halt, {:error, "#{Path.basename(path)} is empty"}}

        {:ok, %File.Stat{type: :regular}} ->
          {:cont, :ok}

        {:ok, _stat} ->
          {:halt, {:error, "#{Path.basename(path)} exists but is not a regular file"}}

        {:error, reason} ->
          {:halt, {:error, "cannot read #{Path.basename(path)}: #{inspect(reason)}"}}
      end
    end)
  end

  defp with_staged_sdkconfig(platform_dir, chip, build, fun) do
    case custom_sdkconfig_paths(build.sdkconfig, chip) do
      :error ->
        if build.feature_sdkconfigs == [] do
          fun.()
        else
          stage_sdkconfigs(nil, build.feature_sdkconfigs, platform_dir, chip, fun)
        end

      {:ok, paths} ->
        stage_sdkconfigs(paths, build.feature_sdkconfigs, platform_dir, chip, fun)
    end
  end

  defp stage_sdkconfigs(paths, feature_paths, platform_dir, chip, fun) do
    target_path = Path.join(platform_dir, "sdkconfig.defaults.#{chip}")
    {base_path, chip_path} = paths || {nil, nil}

    case Esp32BuildStaging.snapshot_file(target_path) do
      {:ok, snapshot} ->
        original_content =
          case snapshot do
            {:content, content} -> content
            :missing -> ""
          end

        base_content =
          if base_path && File.exists?(base_path), do: File.read!(base_path), else: ""

        chip_content =
          if chip_path && File.exists?(chip_path), do: File.read!(chip_path), else: ""

        feature_content = Enum.map_join(feature_paths, "", &(File.read!(&1) <> "\n"))

        appended_data =
          "\n# User Custom Defaults\n" <>
            feature_content <> base_content <> "\n" <> chip_content <> "\n"

        try do
          IO.puts("Staging custom sdkconfig settings into #{Path.basename(target_path)}...")
          File.write!(target_path, original_content <> appended_data)
          fun.()
        after
          restore_staged_file(target_path, snapshot)
        end

      {:error, reason} ->
        {:error, "Failed to read #{Path.basename(target_path)}: #{:file.format_error(reason)}"}
    end
  end

  # Staged files are restored from an after block, so warn instead of raising
  # and masking a build failure; a checkout left modified is reported all the
  # same.
  defp restore_staged_file(path, snapshot) do
    case Esp32BuildStaging.restore_file(path, snapshot) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(
          "Warning: failed to restore #{path}: #{:file.format_error(reason)} " <>
            "(AtomVM checkout may be left modified)"
        )
    end
  end
end
