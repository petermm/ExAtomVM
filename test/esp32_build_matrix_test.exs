defmodule ExAtomVM.Esp32BuildMatrixTest do
  use ExUnit.Case, async: false

  alias ExAtomVM.Esp32BuildMatrix

  @moduletag :tmp_dir

  @manifest "dependencies:\n  atomgl:\n    git: https://example.com/atomgl\n"
  @partitions "nvs, data, nvs, 0x9000, 0x6000,\n"

  setup %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "atomvm_builder/full")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "idf_component.yml"), @manifest)
    File.write!(Path.join(dir, "dependencies.lock"), "project lock")
    File.write!(Path.join(dir, "sdkconfig.defaults"), "CONFIG_BASE=y\n")
    File.write!(Path.join(dir, "custom_partitions.csv"), @partitions)

    {:ok, dir: dir}
  end

  test "resolves the directory convention", %{tmp_dir: tmp_dir, dir: dir} do
    File.cd!(tmp_dir, fn ->
      assert {:ok, [build]} = Esp32BuildMatrix.resolve([full: [chips: ["esp32s3"]]], :all)

      assert build.name == "full"
      assert build.chips == ["esp32s3"]
      assert build.dir == dir
      assert build.components.content == @manifest
      assert build.components.lock_content == "project lock"
      assert build.sdkconfig == Path.join(dir, "sdkconfig.defaults")
      assert build.partition_table.content == @partitions
    end)
  end

  test "a build without files has no customization", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      assert {:ok, [build]} = Esp32BuildMatrix.resolve([plain: [chips: ["esp32"]]], :all)

      assert build.dir == Path.expand("atomvm_builder/plain")
      assert build.components == nil
      assert build.sdkconfig == nil
      assert build.partition_table == nil
    end)
  end

  test "explicit paths override the convention", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      File.mkdir_p!("variants/cam")
      File.write!("variants/cam/idf_component.yml", "dependencies: {}\n")
      File.write!("variants/cam/cam.lock", "cam lock")
      File.write!("variants/cam/sdkconfig.cam", "CONFIG_CAM=y\n")
      File.write!("variants/cam/partitions.csv", @partitions)

      config = [
        cam: [
          chips: ["esp32s3"],
          dir: "variants/cam",
          components: "variants/cam/idf_component.yml",
          lock: "variants/cam/cam.lock",
          sdkconfig: "variants/cam/sdkconfig.cam",
          partitions: "variants/cam/partitions.csv"
        ]
      ]

      assert {:ok, [build]} = Esp32BuildMatrix.resolve(config, :all)
      assert build.components.lock_content == "cam lock"
      assert build.sdkconfig == Path.expand("variants/cam/sdkconfig.cam")
      assert build.partition_table.path == Path.expand("variants/cam/partitions.csv")
    end)
  end

  test "resolves a chip-specific sdkconfig without a base file", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      File.write!("atomvm_builder/full/sdkconfig.defaults.esp32s3", "CONFIG_CHIP=y\n")

      assert {:ok, [build]} = Esp32BuildMatrix.resolve([full: [chips: ["esp32s3"]]], :all)
      assert build.sdkconfig == Path.expand("atomvm_builder/full/sdkconfig.defaults")
    end)
  end

  test "selects builds by name and reports unknown ones", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      config = [one: [chips: ["esp32"]], two: [chips: ["esp32s3"]]]

      assert {:ok, [build]} = Esp32BuildMatrix.resolve(config, ["two"])
      assert build.name == "two"

      assert {:ok, [one, two]} = Esp32BuildMatrix.resolve(config, :all)
      assert {one.name, two.name} == {"one", "two"}

      assert {:error, message} = Esp32BuildMatrix.resolve(config, ["three"])
      assert message =~ "unknown build(s): three"
      assert message =~ "one, two"
    end)
  end

  test "accepts maps and atom names", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      assert {:ok, [build]} = Esp32BuildMatrix.resolve(%{full: %{chips: [:esp32s3]}}, :all)
      assert build.name == "full"
      assert build.chips == ["esp32s3"]
    end)
  end

  test "rejects a configuration without builds" do
    assert {:error, message} = Esp32BuildMatrix.resolve(nil, :all)
    assert message =~ "atomvm_builder"
    assert {:error, "atomvm_builder is empty"} = Esp32BuildMatrix.resolve([], :all)
    assert {:error, message} = Esp32BuildMatrix.resolve("full", :all)
    assert message =~ "keyword list or a map"
  end

  test "rejects invalid entries" do
    assert {:error, "build full has no chips"} = Esp32BuildMatrix.resolve([full: []], :all)

    assert {:error, message} = Esp32BuildMatrix.resolve([full: [chips: "esp32"]], :all)
    assert message =~ "chips must be a list"

    assert {:error, message} = Esp32BuildMatrix.resolve([full: [chips: ["esp8266"]]], :all)
    assert message =~ "unknown chip(s): esp8266"

    assert {:error, message} = Esp32BuildMatrix.resolve([full: [chips: ["esp32"], chip: 1]], :all)
    assert message =~ "unknown option(s): :chip"

    assert {:error, message} =
             Esp32BuildMatrix.resolve([full: [chips: ["esp32"], dir: :cam]], :all)

    assert message =~ "option(s) must be paths: :dir"

    assert {:error, message} =
             Esp32BuildMatrix.resolve([full: [chips: ["esp32"], cmake_args: 1]], :all)

    assert message =~ "cmake_args must be a string or a list of strings"

    assert {:error, message} =
             Esp32BuildMatrix.resolve([full: [chips: ["esp32"], cmake_args: [:x]]], :all)

    assert message =~ "cmake_args must be strings: [:x]"

    assert {:error, message} = Esp32BuildMatrix.resolve([full: "esp32"], :all)
    assert message =~ "options must be a keyword list or map"
  end

  test "resolves cmake_args as a string or a list", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      config = [
        one: [
          chips: ["esp32"],
          cmake_args: "-DAVM_USE_LIBSODIUM=ON -DATOMIC_POINTER_LOCK_FREE_IS_TWO=1"
        ],
        two: [chips: ["esp32"], cmake_args: ["-DX=1"]],
        three: [chips: ["esp32"]]
      ]

      assert {:ok, [one, two, three]} = Esp32BuildMatrix.resolve(config, :all)

      assert one.cmake_args == ["-DAVM_USE_LIBSODIUM=ON", "-DATOMIC_POINTER_LOCK_FREE_IS_TWO=1"]
      assert two.cmake_args == ["-DX=1"]
      assert three.cmake_args == []
    end)
  end

  test "reports a broken input with the build name" do
    assert {:error, "build full: Component manifest file does not exist: " <> _} =
             Esp32BuildMatrix.resolve(
               [full: [chips: ["esp32"], components: "missing.yml"]],
               :all
             )

    assert {:error, "build full sets lock but has no component manifest"} =
             Esp32BuildMatrix.resolve(
               [full: [chips: ["esp32"], lock: "dependencies.lock"]],
               :all
             )

    assert {:error, "build full: SDK config file does not exist: " <> _} =
             Esp32BuildMatrix.resolve(
               [full: [chips: ["esp32"], sdkconfig: "missing.defaults"]],
               :all
             )
  end

  test "plans and serializes the images", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      {:ok, builds} = Esp32BuildMatrix.resolve([full: [chips: ["esp32s3"]]], :all)

      assert [%{name: "full", chips: ["esp32s3"], images: [image]}] =
               Esp32BuildMatrix.plan(builds)

      assert image == "_build/atomvm_images/atomvm-full-esp32s3-elixir.img"

      assert %{"include" => [%{"name" => "full", "chip" => "esp32s3", "image" => ^image}]} =
               builds |> Esp32BuildMatrix.to_json() |> :json.decode()
    end)
  end

  test "image names distinguish builds from the implicit build" do
    assert Esp32BuildMatrix.image_stem(nil, "esp32") == "atomvm-esp32-elixir"
    assert Esp32BuildMatrix.image_stem("full", "esp32s3") == "atomvm-full-esp32s3-elixir"

    assert Esp32BuildMatrix.image_path(nil, "esp32") ==
             "_build/atomvm_images/atomvm-esp32-elixir.img"
  end

  test "config/0 prefers the application environment" do
    Application.put_env(:exatomvm, :atomvm_builder, from_app: [chips: ["esp32"]])
    on_exit(fn -> Application.delete_env(:exatomvm, :atomvm_builder) end)

    assert Esp32BuildMatrix.config()[:from_app][:chips] == ["esp32"]
  end
end
