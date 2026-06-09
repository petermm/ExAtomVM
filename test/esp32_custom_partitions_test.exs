defmodule ExAtomVM.Esp32CustomPartitionsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias ExAtomVM.Esp32CustomPartitions

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    tmp_dir = Path.expand(tmp_dir)
    tmp_dir_parent = Path.dirname(tmp_dir)

    on_exit(fn ->
      File.rm_rf(tmp_dir)
      File.rmdir(tmp_dir_parent)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "custom_partitions_path/1 auto-discovers default file in cwd", %{tmp_dir: tmp_dir} do
    File.cd!(tmp_dir, fn ->
      assert Esp32CustomPartitions.custom_partitions_path(nil) == :error

      path = Path.join(tmp_dir, "custom_partitions.csv")
      File.write!(path, "custom table")

      assert Esp32CustomPartitions.custom_partitions_path(nil) == {:ok, path}
    end)
  end

  test "validate_custom_partitions/1 rejects missing, empty, and directory paths", %{
    tmp_dir: tmp_dir
  } do
    missing_path = Path.join(tmp_dir, "missing.csv")

    assert {:error, "Partition table file does not exist: " <> _} =
             Esp32CustomPartitions.validate_custom_partitions(missing_path)

    File.cd!(tmp_dir, fn ->
      File.write!("custom_partitions.csv", "")

      assert {:error, "custom_partitions.csv is empty"} =
               Esp32CustomPartitions.validate_custom_partitions(nil)
    end)

    directory_path = Path.join(tmp_dir, "partitions.csv")
    File.mkdir!(directory_path)

    assert {:error, "partitions.csv exists but is not a regular file"} =
             Esp32CustomPartitions.validate_custom_partitions(directory_path)
  end

  test "validate_custom_partitions/1 accepts a non-empty custom partition table", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "partitions.csv")
    File.write!(path, "# Name, Type, SubType, Offset, Size\n")

    assert Esp32CustomPartitions.validate_custom_partitions(path) == :ok
  end

  test "copy_custom_partitions/3 copies source and restores existing destination", %{
    tmp_dir: tmp_dir
  } do
    platform_dir = Path.join(tmp_dir, "platform")
    File.mkdir_p!(platform_dir)

    source_path = Path.join(tmp_dir, "my_partitions.csv")
    dest_path = Path.join(platform_dir, "partitions-elixir.csv")

    File.write!(source_path, "custom table")
    File.write!(dest_path, "original table")

    output =
      capture_io(fn ->
        assert Esp32CustomPartitions.copy_custom_partitions(source_path, platform_dir, fn ->
                 assert File.read!(dest_path) == "custom table"
                 :ok
               end) == :ok
      end)

    assert output =~ "Copying my_partitions.csv"
    assert File.read!(dest_path) == "original table"
  end

  test "copy_custom_partitions/3 removes destination when it did not exist before copying", %{
    tmp_dir: tmp_dir
  } do
    platform_dir = Path.join(tmp_dir, "platform")
    File.mkdir_p!(platform_dir)

    source_path = Path.join(tmp_dir, "custom_partitions.csv")
    dest_path = Path.join(platform_dir, "partitions-elixir.csv")

    File.write!(source_path, "custom table")

    capture_io(fn ->
      assert Esp32CustomPartitions.copy_custom_partitions(source_path, platform_dir, fn ->
               assert File.read!(dest_path) == "custom table"
               :ok
             end) == :ok
    end)

    refute File.exists?(dest_path)
  end

  test "copy_custom_partitions/3 reports copy failures with the source filename", %{
    tmp_dir: tmp_dir
  } do
    platform_dir = Path.join(tmp_dir, "platform")
    File.mkdir_p!(platform_dir)

    source_path = Path.join(tmp_dir, "missing_partitions.csv")

    capture_io(fn ->
      assert {:error, message} =
               Esp32CustomPartitions.copy_custom_partitions(source_path, platform_dir, fn ->
                 flunk("callback should not run when copying fails")
               end)

      assert message =~ "Failed to copy missing_partitions.csv"
    end)
  end

  test "restore_file/2 restores content and removes previously missing files", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "partitions-elixir.csv")

    File.write!(path, "temporary")
    assert Esp32CustomPartitions.restore_file(path, {:content, "original"}) == :ok
    assert File.read!(path) == "original"

    assert Esp32CustomPartitions.restore_file(path, :missing) == :ok
    refute File.exists?(path)
  end

  test "same_file?/2 detects path equality and inode equality", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "partitions.csv")
    linked_path = Path.join(tmp_dir, "linked_partitions.csv")
    other_path = Path.join(tmp_dir, "other_partitions.csv")

    File.write!(path, "table")
    File.write!(other_path, "other")
    File.ln!(path, linked_path)

    assert Esp32CustomPartitions.same_file?(path, path)
    assert Esp32CustomPartitions.same_file?(path, linked_path)
    refute Esp32CustomPartitions.same_file?(path, other_path)
  end
end
