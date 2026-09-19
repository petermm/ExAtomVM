defmodule Mix.Tasks.Atomvm.Esp32.BuildTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Atomvm.Esp32.Build

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

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
      assert output =~ "    image: _build/atomvm_images/atomvm-full-esp32p4-elixir.img\n"
      assert output =~ "    image: _build/atomvm_images/atomvm-full-esp32c3-elixir.img\n"
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
end
