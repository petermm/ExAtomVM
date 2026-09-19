defmodule Mix.Tasks.Atomvm.Esp32.BuildTest do
  use ExUnit.Case, async: false

  alias ExAtomVM.Esp32FirmwareImages
  alias Mix.Tasks.Atomvm.Esp32.Build

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  @bootloader "bootloader bytes"
  @table "partition table bytes"
  @app "application bytes"
  @lib "boot library bytes"

  @partitions """
  # Name,   Type, SubType, Offset,  Size, Flags
  nvs,      data, nvs,     0x9000,  0x6000,
  factory,  app,  factory, 0x10000, 0x1C0000,
  boot.avm, data, phy,     0x1D0000, 0x80000,
  main.avm, data, phy,     0x250000, 0x1B0000
  """

  test "custom_sdkconfig_paths/2 resolves defaults in given directory", %{tmp_dir: tmp_dir} do
    # 1. Neither base nor chip exists
    assert Build.custom_sdkconfig_paths(Path.join(tmp_dir, "nonexistent"), "esp32s3") == :error

    # 2. Only base exists
    base_file = Path.join(tmp_dir, "my_sdkconfig")
    File.write!(base_file, "CONFIG_TEST=y")
    assert Build.custom_sdkconfig_paths(base_file, "esp32s3") == {:ok, {base_file, nil}}

    # 3. Only chip-specific exists
    File.rm!(base_file)
    chip_file = "#{base_file}.esp32s3"
    File.write!(chip_file, "CONFIG_TEST_CHIP=y")
    assert Build.custom_sdkconfig_paths(base_file, "esp32s3") == {:ok, {nil, chip_file}}

    # 4. Both exist
    File.write!(base_file, "CONFIG_TEST=y")
    assert Build.custom_sdkconfig_paths(base_file, "esp32s3") == {:ok, {base_file, chip_file}}
  end

  test "validate_sdkconfigs/2 performs correct validation checks", %{tmp_dir: tmp_dir} do
    base_file = Path.join(tmp_dir, "valid_sdkconfig")
    chip_file = "#{base_file}.esp32s3"

    # 1. Neither exists
    assert {:error, "SDK config file does not exist:" <> _} =
             Build.validate_sdkconfigs(base_file, "esp32s3")

    # 2. File exists but is empty
    File.touch!(base_file)
    assert {:error, "valid_sdkconfig is empty"} = Build.validate_sdkconfigs(base_file, "esp32s3")

    # 3. File exists but is not a regular file (e.g. a directory)
    File.rm!(base_file)
    File.mkdir!(base_file)

    assert {:error, "valid_sdkconfig exists but is not a regular file"} =
             Build.validate_sdkconfigs(base_file, "esp32s3")

    # Clean up directory
    File.rmdir!(base_file)

    # 4. Valid file
    File.write!(base_file, "CONFIG_TEST=y")
    assert Build.validate_sdkconfigs(base_file, "esp32s3") == :ok

    # 5. Chip-specific file validation
    File.touch!(chip_file)

    assert {:error, "valid_sdkconfig.esp32s3 is empty"} =
             Build.validate_sdkconfigs(base_file, "esp32s3")

    File.write!(chip_file, "CONFIG_CHIP=y")
    assert Build.validate_sdkconfigs(base_file, "esp32s3") == :ok
  end

  test "custom_sdkconfig_paths/2 auto-discovers sdkconfig defaults in cwd", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      refute File.exists?("sdkconfig.defaults")
      assert Build.custom_sdkconfig_paths(nil, "esp32") == :error

      base_file = Path.join(tmp_dir, "sdkconfig.defaults")
      File.write!(base_file, "CONFIG_BASE=y")
      assert Build.custom_sdkconfig_paths(nil, "esp32") == {:ok, {base_file, nil}}

      chip_file = Path.join(tmp_dir, "sdkconfig.defaults.esp32s3")
      File.write!(chip_file, "CONFIG_CHIP=y")
      assert Build.custom_sdkconfig_paths(nil, "esp32s3") == {:ok, {base_file, chip_file}}
    end)
  end

  test "validate_sdkconfigs/2 rejects invalid auto-discovered defaults", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      File.touch!("sdkconfig.defaults")
      assert {:error, "sdkconfig.defaults is empty"} = Build.validate_sdkconfigs(nil, "esp32")

      File.rm!("sdkconfig.defaults")
      File.mkdir!("sdkconfig.defaults")

      assert {:error, "sdkconfig.defaults exists but is not a regular file"} =
               Build.validate_sdkconfigs(nil, "esp32")
    end)
  end

  test "atomvm.esp32.build stages custom defaults after AtomVM chip defaults and restores them",
       %{
         tmp_dir: tmp_dir
       } do
    File.cd!(tmp_dir, fn ->
      atomvm_path = Path.join(tmp_dir, "AtomVM")
      platform_dir = Path.join([atomvm_path, "src", "platforms", "esp32"])
      target_defaults = Path.join(platform_dir, "sdkconfig.defaults.esp32p4")
      captured_defaults = Path.join(tmp_dir, "captured.defaults")

      File.mkdir_p!(Path.join(platform_dir, "main"))
      File.mkdir_p!(Path.join([atomvm_path, "build", "tools", "packbeam"]))
      File.mkdir_p!(Path.join([atomvm_path, "build", "libs", "esp32boot"]))
      File.write!(Path.join([atomvm_path, "build", "tools", "packbeam", "PackBEAM"]), "")

      File.write!(
        Path.join([atomvm_path, "build", "libs", "esp32boot", "elixir_esp32boot.avm"]),
        ""
      )

      File.write!(target_defaults, "CONFIG_SPIRAM=y\nCONFIG_ATOMVM_CHIP_DEFAULT=y\n")
      File.write!("sdkconfig.defaults", "CONFIG_PROJECT_BASE=y")
      File.write!("sdkconfig.defaults.esp32p4", "# CONFIG_SPIRAM is not set")
      File.write!("idf_component.yml.example", "")

      idf_path = Path.join(tmp_dir, "idf.py")

      File.write!(
        idf_path,
        "#!/bin/sh\ncp sdkconfig.defaults.esp32p4 \"#{captured_defaults}\"\nexit 1\n"
      )

      File.chmod!(idf_path, 0o755)

      capture_io(fn ->
        assert catch_exit(
                 Build.run([
                   "--atomvm-path",
                   atomvm_path,
                   "--idf-path",
                   idf_path,
                   "--chip",
                   "esp32p4"
                 ])
               ) == {:shutdown, 1}
      end)

      assert File.read!(captured_defaults) ==
               "CONFIG_SPIRAM=y\nCONFIG_ATOMVM_CHIP_DEFAULT=y\n\n" <>
                 "# User Custom Defaults\nCONFIG_PROJECT_BASE=y\n" <>
                 "# CONFIG_SPIRAM is not set\n"

      assert File.read!(target_defaults) ==
               "CONFIG_SPIRAM=y\nCONFIG_ATOMVM_CHIP_DEFAULT=y\n"
    end)
  end

  test "stages the component manifest for the build and removes it afterwards", %{
    tmp_dir: tmp_dir
  } do
    File.cd!(tmp_dir, fn ->
      atomvm_path = fake_atomvm_tree(tmp_dir)
      platform_dir = Path.join([atomvm_path, "src", "platforms", "esp32"])
      manifest_path = Path.join([platform_dir, "main", "idf_component.yml"])
      lock_path = Path.join(platform_dir, "dependencies.lock")
      captured_manifest = Path.join(tmp_dir, "captured-manifest")
      captured_lock = Path.join(tmp_dir, "captured-lock")
      idf_path = Path.join(tmp_dir, "idf.py")

      File.write!(
        "idf_component.yml",
        "dependencies:\n  atomgl:\n    git: https://example.com/atomgl\n"
      )

      File.write!("dependencies.lock", "project lock")

      write_idf_script(idf_path, """
      cp main/idf_component.yml "#{captured_manifest}"
      cp dependencies.lock "#{captured_lock}"
      exit 1
      """)

      capture_io(fn ->
        assert catch_exit(
                 Build.run([
                   "--atomvm-path",
                   atomvm_path,
                   "--idf-path",
                   idf_path,
                   "--chip",
                   "esp32p4"
                 ])
               ) == {:shutdown, 1}
      end)

      assert File.read!(captured_manifest) == File.read!("idf_component.yml")
      assert File.read!(captured_lock) == "project lock"
      refute File.exists?(manifest_path)
      refute File.exists?(lock_path)
    end)
  end

  test "a build without a manifest does not reuse a staged one", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      atomvm_path = fake_atomvm_tree(tmp_dir)
      platform_dir = Path.join([atomvm_path, "src", "platforms", "esp32"])
      manifest_path = Path.join([platform_dir, "main", "idf_component.yml"])
      idf_path = Path.join(tmp_dir, "idf.py")
      seen = Path.join(tmp_dir, "seen")

      File.write!("idf_component.yml", "dependencies: {}\n")
      write_idf_script(idf_path, "exit 1\n")

      capture_io(fn ->
        assert catch_exit(
                 Build.run([
                   "--atomvm-path",
                   atomvm_path,
                   "--idf-path",
                   idf_path,
                   "--chip",
                   "esp32p4"
                 ])
               ) == {:shutdown, 1}
      end)

      refute File.exists?(manifest_path)

      File.rm!("idf_component.yml")

      write_idf_script(idf_path, """
      if [ -f main/idf_component.yml ]; then echo yes > "#{seen}"; else echo no > "#{seen}"; fi
      exit 1
      """)

      capture_io(fn ->
        assert catch_exit(
                 Build.run([
                   "--atomvm-path",
                   atomvm_path,
                   "--idf-path",
                   idf_path,
                   "--chip",
                   "esp32p4"
                 ])
               ) == {:shutdown, 1}
      end)

      assert File.read!(seen) == "no\n"
    end)
  end

  test "--list-matrix prints the resolved builds", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      write_entry("full", "dependencies: {}\n", "nvs, data, nvs, 0x9000, 0x6000,\n")
      put_matrix(full: [chips: ["esp32p4", "esp32c3"], cmake_args: ["-DAVM_USE_LIBSODIUM=ON"]])

      output = capture_io(fn -> Build.run(["--list-matrix"]) end)

      assert output =~ "Build matrix (1 build(s))"
      assert output =~ "full: esp32p4, esp32c3"
      assert output =~ "cmake_args: -DAVM_USE_LIBSODIUM=ON"
      assert output =~ "atomvm_builder/full"
      assert output =~ "    image: _build/atomvm_images/atomvm-esp32p4-full-elixir.img\n"
      assert output =~ "    image: _build/atomvm_images/atomvm-esp32c3-full-elixir.img\n"
      refute output =~ "false"
    end)
  end

  test "--list-matrix --format json emits a CI matrix", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      put_matrix(one: [chips: ["esp32"]], two: [chips: ["esp32s3"]])

      output = capture_io(fn -> Build.run(["--list-matrix", "--format", "json"]) end)

      assert %{"include" => include} = :json.decode(output)
      assert Enum.map(include, & &1["name"]) == ["one", "two"]
      assert Enum.map(include, & &1["chip"]) == ["esp32", "esp32s3"]
    end)
  end

  test "--list-matrix --output writes the plan to a file", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      put_matrix(one: [chips: ["esp32"]])

      capture_io(fn ->
        Build.run(["--list-matrix", "--format", "json", "--output", "ci/matrix.json"])
      end)

      assert %{"include" => [%{"name" => "one"}]} =
               "ci/matrix.json" |> File.read!() |> :json.decode()
    end)
  end

  test "--matrix reports an unknown build", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      put_matrix(one: [chips: ["esp32"]])

      output =
        capture_io(fn ->
          assert catch_exit(Build.run(["--matrix", "two"])) == {:shutdown, 1}
        end)

      assert output =~ "unknown build(s): two"
    end)
  end

  test "matrix and listing options are refused where they do not apply", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      put_matrix(one: [chips: ["esp32"]])

      output =
        capture_io(fn ->
          assert catch_exit(Build.run(["--format", "json"])) == {:shutdown, 1}
        end)

      assert output =~ "--format and --output only apply to --list-matrix"

      output =
        capture_io(fn ->
          assert catch_exit(Build.run(["--matrix", "one", "--sdkconfig", "custom.defaults"])) ==
                   {:shutdown, 1}
        end)

      assert output =~ "--sdkconfig cannot be combined with --matrix"
    end)
  end

  test "--matrix builds each entry with its own inputs and restores the checkout",
       %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      atomvm_path = fake_atomvm_tree(tmp_dir)
      platform_dir = Path.join([atomvm_path, "src", "platforms", "esp32"])
      manifest_path = Path.join([platform_dir, "main", "idf_component.yml"])
      partitions_path = Path.join(platform_dir, "partitions-elixir.csv")
      capture_dir = Path.join(tmp_dir, "captured")
      File.mkdir_p!(capture_dir)

      write_entry("one", "one manifest\n", "one partitions\n")
      write_entry("two", "two manifest\n", "two partitions\n")
      put_matrix(one: [chips: ["esp32p4"]], two: [chips: ["esp32p4"]])

      idf_path = Path.join(tmp_dir, "idf.py")

      write_idf_script(idf_path, """
      n=$(cat "#{capture_dir}/count" 2>/dev/null || echo 0)
      n=$((n+1))
      echo $n > "#{capture_dir}/count"
      cp main/idf_component.yml "#{capture_dir}/manifest-$n"
      cp partitions-elixir.csv "#{capture_dir}/partitions-$n"
      exit 1
      """)

      output =
        capture_io(fn ->
          assert catch_exit(
                   Build.run([
                     "--atomvm-path",
                     atomvm_path,
                     "--idf-path",
                     idf_path,
                     "--matrix",
                     "all"
                   ])
                 ) == {:shutdown, 1}
        end)

      assert output =~ "one (esp32p4)"
      assert output =~ "two (esp32p4)"
      assert File.read!(Path.join(capture_dir, "manifest-1")) == "one manifest\n"
      assert File.read!(Path.join(capture_dir, "partitions-1")) == "one partitions\n"
      assert File.read!(Path.join(capture_dir, "manifest-2")) == "two manifest\n"
      assert File.read!(Path.join(capture_dir, "partitions-2")) == "two partitions\n"
      refute File.exists?(manifest_path)
      refute File.exists?(partitions_path)
    end)
  end

  test "--clean drops the generated sdkconfig a previous build left behind", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      atomvm_path = fake_atomvm_tree(tmp_dir)
      platform_dir = Path.join([atomvm_path, "src", "platforms", "esp32"])
      idf_path = Path.join(tmp_dir, "idf.py")
      seen = Path.join(tmp_dir, "seen")

      File.write!(Path.join(platform_dir, "sdkconfig"), "CONFIG_ESPTOOLPY_FLASHSIZE=\"16MB\"\n")
      File.write!(Path.join(platform_dir, "sdkconfig.old"), "old\n")

      put_matrix(one: [chips: ["esp32p4"]])

      write_idf_script(idf_path, """
      if [ -f sdkconfig ]; then echo present > "#{seen}"; else echo absent > "#{seen}"; fi
      exit 1
      """)

      output =
        capture_io(fn ->
          assert catch_exit(
                   Build.run([
                     "--atomvm-path",
                     atomvm_path,
                     "--idf-path",
                     idf_path,
                     "--matrix",
                     "one"
                   ])
                 ) == {:shutdown, 1}
        end)

      assert File.read!(seen) == "absent\n"
      assert output =~ "Removing generated sdkconfig and sdkconfig.old..."
      refute File.exists?(Path.join(platform_dir, "sdkconfig.old"))
    end)
  end

  test "--matrix passes cmake_args to idf.py", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      atomvm_path = fake_atomvm_tree(tmp_dir)
      args_file = Path.join(tmp_dir, "args")
      idf_path = Path.join(tmp_dir, "idf.py")

      put_matrix(one: [chips: ["esp32p4"], cmake_args: ["-DAVM_USE_LIBSODIUM=ON"]])

      write_idf_script(idf_path, """
      echo "$@" > "#{args_file}"
      exit 1
      """)

      capture_io(fn ->
        assert catch_exit(
                 Build.run([
                   "--atomvm-path",
                   atomvm_path,
                   "--idf-path",
                   idf_path,
                   "--matrix",
                   "one"
                 ])
               ) == {:shutdown, 1}
      end)

      args = File.read!(args_file)
      assert args =~ "-DATOMVM_ELIXIR_SUPPORT=on"
      assert args =~ "-DAVM_USE_LIBSODIUM=ON"
      assert args =~ "set-target"
      assert args =~ "esp32p4"
    end)
  end

  test "--matrix stages feature sdkconfig before the build's own", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      atomvm_path = fake_atomvm_tree(tmp_dir)
      captured_defaults = Path.join(tmp_dir, "captured-defaults")
      captured_args = Path.join(tmp_dir, "captured-args")
      idf_path = Path.join(tmp_dir, "idf.py")

      write_entry("one", "dependencies: {}\n", "one partitions\n")
      File.write!("atomvm_builder/one/sdkconfig.defaults", "CONFIG_OWN=y\n")

      File.mkdir_p!("atomvm_builder/features")
      File.write!("atomvm_builder/features/psram.sdkconfig", "CONFIG_SPIRAM=y\n")

      put_matrix(
        features: [
          psram: [
            sdkconfig: "atomvm_builder/features/psram.sdkconfig",
            cmake_args: ["-DATOMIC_POINTER_LOCK_FREE_IS_TWO=1"]
          ]
        ],
        one: [chips: ["esp32p4"], features: ["psram"]]
      )

      write_idf_script(idf_path, """
      cp sdkconfig.defaults.esp32p4 "#{captured_defaults}"
      echo "$@" > "#{captured_args}"
      exit 1
      """)

      capture_io(fn ->
        assert catch_exit(
                 Build.run([
                   "--atomvm-path",
                   atomvm_path,
                   "--idf-path",
                   idf_path,
                   "--matrix",
                   "one"
                 ])
               ) == {:shutdown, 1}
      end)

      defaults = File.read!(captured_defaults)
      assert defaults =~ "CONFIG_SPIRAM=y"
      assert defaults =~ "CONFIG_OWN=y"

      assert :binary.match(defaults, "CONFIG_SPIRAM=y") <
               :binary.match(defaults, "CONFIG_OWN=y")

      assert File.read!(captured_args) =~ "-DATOMIC_POINTER_LOCK_FREE_IS_TWO=1"
    end)
  end

  test "--with-zips writes the installer bundle next to the image", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      atomvm_path = fake_atomvm_tree(tmp_dir)
      idf_path = Path.join(tmp_dir, "idf.py")
      fixtures = write_build_fixtures(tmp_dir)

      write_entry("one", "dependencies: {}\n", @partitions)
      put_matrix(one: [chips: ["esp32p4"]])

      # A build that succeeds: every idf.py run recreates the build outputs the
      # bundle is assembled from, including an image whose parts match
      # flasher_args.json, and the sdkconfig ESP-IDF regenerates.
      write_idf_script(idf_path, """
      mkdir -p build
      cp -R #{fixtures}/. build/
      cp #{fixtures}/sdkconfig sdkconfig
      exit 0
      """)

      image = "_build/atomvm_images/atomvm-esp32p4-one-elixir.img"
      zip = "_build/atomvm_images/atomvm-esp32p4-one-elixir.zip"

      output =
        capture_io(fn ->
          Build.run([
            "--atomvm-path",
            atomvm_path,
            "--idf-path",
            idf_path,
            "--matrix",
            "one"
          ])
        end)

      assert File.exists?(image)
      refute File.exists?(zip)
      assert output =~ image

      capture_io(fn ->
        Build.run([
          "--atomvm-path",
          atomvm_path,
          "--idf-path",
          idf_path,
          "--matrix",
          "one",
          "--with-zips"
        ])
      end)

      assert {:ok, bundle} =
               Esp32FirmwareImages.verify_bundle(File.read!(zip), Path.basename(zip), nil)

      assert bundle.stem == "atomvm-esp32p4-one-elixir"
      assert bundle.flash.chip == "esp32p4"
      assert bundle.image == File.read!(image)
      assert bundle.parts["atomvm-esp32.bin"] == @app
      assert bundle.partitions_csv == @partitions
    end)
  end

  test "explains a partition table whose main.avm offset AtomVM does not know", %{
    tmp_dir: tmp_dir
  } do
    File.cd!(tmp_dir, fn ->
      atomvm_path = fake_atomvm_tree(tmp_dir)
      idf_path = Path.join(tmp_dir, "idf.py")
      fixtures = write_build_fixtures(tmp_dir)

      write_entry("one", "dependencies: {}\n", @partitions)
      put_matrix(one: [chips: ["esp32p4"]])

      File.write!(
        Path.join(fixtures, "mkimage.config"),
        "config = [{name, \"boot\"}, {offset, \"0x290000\"}, {path, [\"/project/build/libs/esp32boot/NONE\"]}].\n"
      )

      write_idf_script(idf_path, """
      mkdir -p build
      cp -R #{fixtures}/. build/
      cp #{fixtures}/sdkconfig sdkconfig
      exit 0
      """)

      output =
        capture_io(fn ->
          assert catch_exit(
                   Build.run([
                     "--atomvm-path",
                     atomvm_path,
                     "--idf-path",
                     idf_path,
                     "--matrix",
                     "one"
                   ])
                 ) == {:shutdown, 1}
        end)

      assert output =~ "mkimage.config configures no boot library"
      assert output =~ "keep main.avm at 0x250000"
    end)
  end

  defp put_matrix(config) do
    Application.put_env(:exatomvm, :atomvm_builder, config)
    on_exit(fn -> Application.delete_env(:exatomvm, :atomvm_builder) end)
  end

  defp write_entry(name, manifest, partitions) do
    dir = Path.join("atomvm_builder", name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "idf_component.yml"), manifest)
    File.write!(Path.join(dir, "custom_partitions.csv"), partitions)
  end

  defp fake_atomvm_tree(tmp_dir) do
    atomvm_path = Path.join(tmp_dir, "AtomVM")
    platform_dir = Path.join([atomvm_path, "src", "platforms", "esp32"])

    File.mkdir_p!(Path.join(platform_dir, "main"))
    File.mkdir_p!(Path.join([atomvm_path, "build", "tools", "packbeam"]))
    File.mkdir_p!(Path.join([atomvm_path, "build", "libs", "esp32boot"]))
    File.write!(Path.join([atomvm_path, "build", "tools", "packbeam", "PackBEAM"]), "")

    File.write!(
      Path.join([atomvm_path, "build", "libs", "esp32boot", "elixir_esp32boot.avm"]),
      ""
    )

    atomvm_path
  end

  defp write_idf_script(path, body) do
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
  end

  # Everything a successful ESP-IDF build leaves in its build directory: the
  # parts named in flasher_args.json, the debug files, and an image carrying
  # those parts at their offsets.
  defp write_build_fixtures(tmp_dir) do
    dir = Path.join(tmp_dir, "fixtures")
    File.mkdir_p!(Path.join(dir, "bootloader"))
    File.mkdir_p!(Path.join(dir, "partition_table"))
    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(Path.join(dir, "bootloader/bootloader.bin"), @bootloader)
    File.write!(Path.join(dir, "partition_table/partition-table.bin"), @table)
    File.write!(Path.join(dir, "atomvm-esp32.bin"), @app)
    File.write!(Path.join(dir, "lib/elixir_esp32boot.avm"), @lib)

    for file <- [
          "atomvm-esp32.elf",
          "atomvm-esp32.map",
          "bootloader/bootloader.elf",
          "bootloader/bootloader.map",
          "prefix_map_gdbinit"
        ] do
      File.write!(Path.join(dir, file), "debug #{file}")
    end

    File.write!(Path.join(dir, "image"), build_image())
    File.write!(Path.join(dir, "flasher_args.json"), flasher_args())

    File.write!(Path.join(dir, "sdkconfig"), """
    #
    # Espressif IoT Development Framework (ESP-IDF) 5.5.5 Project Configuration
    #
    CONFIG_APP_PROJECT_VER="test"
    CONFIG_PARTITION_TABLE_CUSTOM_FILENAME="partitions-elixir.csv"
    CONFIG_ESPTOOLPY_FLASHSIZE="16MB"
    """)

    File.write!(Path.join(dir, "mkimage.config"), "config = []\n")
    write_mkimage_script(Path.join(dir, "mkimage.erl"), Path.join(dir, "image"))

    dir
  end

  # A stand-in for the mkimage.erl the AtomVM build generates: it writes the
  # image to the path passed with --out.
  defp write_mkimage_script(path, image_path) do
    File.write!(path, """
    -module(mkimage).
    -export([main/1]).

    main(Args) ->
        {ok, _} = file:copy("#{image_path}", out(Args)),
        halt(0).

    out(["--out", Out | _]) -> Out;
    out([_ | Rest]) -> out(Rest);
    out([]) -> halt(1).
    """)
  end

  defp flasher_args do
    """
    {
      "flash_settings": {"flash_mode": "dio", "flash_size": "4MB", "flash_freq": "80m"},
      "bootloader": {"offset": "0x0", "file": "bootloader/bootloader.bin"},
      "partition-table": {"offset": "0x8000", "file": "partition_table/partition-table.bin"},
      "app": {"offset": "0x10000", "file": "atomvm-esp32.bin"},
      "boot.avm": {"offset": "0x1d0000", "file": "lib/elixir_esp32boot.avm"}
    }
    """
  end

  defp build_image do
    size = 0x1D0000 + byte_size(@lib)

    <<0xFF::size(size * 8)>>
    |> put(0x0, @bootloader)
    |> put(0x8000, @table)
    |> put(0x10000, @app)
    |> put(0x1D0000, @lib)
  end

  defp put(image, offset, data) do
    <<binary_part(image, 0, offset)::binary, data::binary,
      binary_part(image, offset + byte_size(data), byte_size(image) - offset - byte_size(data))::binary>>
  end
end
