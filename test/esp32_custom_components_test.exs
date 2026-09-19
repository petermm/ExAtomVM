defmodule ExAtomVM.Esp32CustomComponentsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias ExAtomVM.Esp32CustomComponents

  @moduletag :tmp_dir

  @manifest """
  dependencies:
    atomgl:
      git: https://github.com/atomvm/atomgl
      version: "main"
  """

  setup %{tmp_dir: tmp_dir} do
    platform_dir = Path.join(tmp_dir, "platform")
    File.mkdir_p!(Path.join(platform_dir, "main"))

    source_dir = Path.join(tmp_dir, "project")
    File.mkdir_p!(source_dir)
    source_path = Path.join(source_dir, "idf_component.yml")
    File.write!(source_path, @manifest)

    {:ok, selected} = Esp32CustomComponents.load_custom_components(source_path)

    {:ok,
     platform_dir: platform_dir,
     source_dir: source_dir,
     source_path: source_path,
     manifest_path: Path.join([platform_dir, "main", "idf_component.yml"]),
     lock_path: Path.join(platform_dir, "dependencies.lock"),
     source_lock: Path.join(source_dir, "dependencies.lock"),
     selected: selected}
  end

  test "loads the default manifest, or retains no selection if absent", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      File.write!("idf_component.yml", @manifest)
      assert {:ok, %{content: @manifest}} = Esp32CustomComponents.load_custom_components(nil)
      File.rm!("idf_component.yml")
      assert {:ok, nil} = Esp32CustomComponents.load_custom_components(nil)
    end)
  end

  test "rejects missing, empty, and directory paths", %{tmp_dir: tmp_dir} do
    assert {:error, "Component manifest file does not exist: " <> _} =
             Esp32CustomComponents.load_custom_components(Path.join(tmp_dir, "missing.yml"))

    path = Path.join(tmp_dir, "empty.yml")
    File.write!(path, "")
    assert {:error, "empty.yml is empty"} = Esp32CustomComponents.load_custom_components(path)

    assert {:error, message} = Esp32CustomComponents.load_custom_components(tmp_dir)
    assert message =~ "not a regular file"
  end

  test "rejects a non-regular dependencies.lock", %{source_dir: dir} do
    File.mkdir!(Path.join(dir, "dependencies.lock"))

    assert {:error, "dependencies.lock exists but is not a regular file"} =
             Esp32CustomComponents.load_custom_components(Path.join(dir, "idf_component.yml"))
  end

  test "stages the manifest and its lock for the build and removes them afterwards", ctx do
    File.write!(ctx.source_lock, "project lock")
    {:ok, selected} = Esp32CustomComponents.load_custom_components(ctx.source_path)

    capture_io(fn ->
      assert :ok =
               Esp32CustomComponents.with_custom_components(ctx.platform_dir, selected, fn ->
                 assert File.read!(ctx.manifest_path) == @manifest
                 assert File.read!(ctx.lock_path) == "project lock"
                 :ok
               end)
    end)

    refute File.exists?(ctx.manifest_path)
    refute File.exists?(ctx.lock_path)
  end

  test "restores a manifest and lock that were already in the checkout", ctx do
    File.write!(ctx.manifest_path, "original manifest")
    File.write!(ctx.lock_path, "original lock")

    capture_io(fn ->
      assert :ok =
               Esp32CustomComponents.with_custom_components(ctx.platform_dir, ctx.selected, fn ->
                 assert File.read!(ctx.manifest_path) == @manifest
                 :ok
               end)
    end)

    assert File.read!(ctx.manifest_path) == "original manifest"
    assert File.read!(ctx.lock_path) == "original lock"
  end

  test "writes the resolved lock back next to the manifest", ctx do
    capture_io(fn ->
      assert {:ok, :image} =
               Esp32CustomComponents.with_custom_components(ctx.platform_dir, ctx.selected, fn ->
                 File.write!(ctx.lock_path, "resolved lock")
                 {:ok, :image}
               end)
    end)

    assert File.read!(ctx.source_lock) == "resolved lock"
  end

  test "keeps the project lock when the build fails", ctx do
    capture_io(fn ->
      assert {:error, "build failed"} =
               Esp32CustomComponents.with_custom_components(ctx.platform_dir, ctx.selected, fn ->
                 File.write!(ctx.lock_path, "resolved lock")
                 {:error, "build failed"}
               end)
    end)

    refute File.exists?(ctx.source_lock)
  end

  test "clears managed_components only when the manifest changes", ctx do
    components_dir = Path.join(ctx.platform_dir, "managed_components")
    marker = Path.join(components_dir, ".exatomvm_manifest.sha256")

    capture_io(fn ->
      Esp32CustomComponents.with_custom_components(ctx.platform_dir, ctx.selected, fn -> :ok end)
      assert File.exists?(marker)

      File.write!(Path.join(components_dir, "sentinel"), "")
      Esp32CustomComponents.with_custom_components(ctx.platform_dir, ctx.selected, fn -> :ok end)
      assert File.exists?(Path.join(components_dir, "sentinel"))

      File.write!(ctx.source_path, @manifest <> "  extra:\n    git: https://example.com/extra\n")
      {:ok, changed} = Esp32CustomComponents.load_custom_components(ctx.source_path)

      Esp32CustomComponents.with_custom_components(ctx.platform_dir, changed, fn -> :ok end)
      refute File.exists?(Path.join(components_dir, "sentinel"))
    end)
  end

  test "restores the checkout when the build raises", ctx do
    File.write!(ctx.manifest_path, "original manifest")

    capture_io(fn ->
      assert_raise RuntimeError, "build failed", fn ->
        Esp32CustomComponents.with_custom_components(ctx.platform_dir, ctx.selected, fn ->
          raise "build failed"
        end)
      end
    end)

    assert File.read!(ctx.manifest_path) == "original manifest"
    refute File.exists?(ctx.lock_path)
  end
end
