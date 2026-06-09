defmodule ExAtomVM.Esp32CustomPartitions do
  @moduledoc false

  @custom_partitions_csv "custom_partitions.csv"
  @atomvm_elixir_partitions_csv "partitions-elixir.csv"

  # Returns {:ok, path} if a custom partition table file is resolved, or :error.
  @doc false
  def custom_partitions_path(nil) do
    path = Path.join(File.cwd!(), @custom_partitions_csv)
    if File.exists?(path), do: {:ok, path}, else: :error
  end

  @doc false
  def custom_partitions_path(user_provided_path) do
    path = Path.expand(user_provided_path)
    if File.exists?(path), do: {:ok, path}, else: :error
  end

  # Validates the project's custom_partitions.csv (if present) up front, before
  # any expensive build work, so an invalid file fails fast.
  @doc false
  def validate_custom_partitions(user_provided_path) do
    cond do
      not is_nil(user_provided_path) and not File.exists?(Path.expand(user_provided_path)) ->
        {:error, "Partition table file does not exist: #{user_provided_path}"}

      true ->
        case custom_partitions_path(user_provided_path) do
          :error -> :ok
          {:ok, path} -> validate_partition_file(path)
        end
    end
  end

  @doc false
  def with_custom_partitions(platform_dir, partition_table, fun) do
    case custom_partitions_path(partition_table) do
      :error ->
        fun.()

      {:ok, source_path} ->
        copy_custom_partitions(source_path, platform_dir, fun)
    end
  end

  @doc false
  def copy_custom_partitions(source_path, platform_dir, fun) do
    dest_path = Path.join(platform_dir, @atomvm_elixir_partitions_csv)

    if same_file?(source_path, dest_path) do
      IO.puts("Using custom ESP32 partition table: #{source_path}")
      fun.()
    else
      case snapshot_file(dest_path) do
        {:ok, original} ->
          source_filename = Path.basename(source_path)

          IO.puts("Copying #{source_filename} to #{dest_path} for this build...")

          try do
            case File.cp(source_path, dest_path) do
              :ok ->
                fun.()

              {:error, reason} ->
                {:error, "Failed to copy #{source_filename}: #{:file.format_error(reason)}"}
            end
          after
            restore_file(dest_path, original)
          end

        {:error, reason} ->
          {:error,
           "Failed to read existing #{@atomvm_elixir_partitions_csv}: #{:file.format_error(reason)}"}
      end
    end
  end

  # Returns {:ok, {:content, binary}} when the file exists, {:ok, :missing} when
  # it does not, or {:error, reason} if it exists but cannot be read.
  @doc false
  def snapshot_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, {:content, content}}
      {:error, :enoent} -> {:ok, :missing}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def restore_file(path, {:content, content}) do
    case File.write(path, content) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(
          "Warning: failed to restore #{path}: #{:file.format_error(reason)} " <>
            "(AtomVM checkout may be left modified)"
        )
    end
  end

  @doc false
  def restore_file(path, :missing) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        IO.puts(
          "Warning: failed to remove temporary #{path}: #{:file.format_error(reason)} " <>
            "(AtomVM checkout may be left modified)"
        )
    end
  end

  @doc false
  def same_file?(left, right) do
    Path.expand(left) == Path.expand(right) or
      with {:ok, l} <- File.stat(left),
           {:ok, r} <- File.stat(right) do
        l.inode != 0 and
          {l.major_device, l.minor_device, l.inode} ==
            {r.major_device, r.minor_device, r.inode}
      else
        _ -> false
      end
  end

  defp validate_partition_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: 0}} ->
        {:error, "#{Path.basename(path)} is empty"}

      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, _stat} ->
        {:error, "#{Path.basename(path)} exists but is not a regular file"}

      {:error, reason} ->
        {:error, "cannot read #{Path.basename(path)}: #{:file.format_error(reason)}"}
    end
  end
end
