defmodule ExAtomVM.Esp32CustomComponents do
  @moduledoc false

  alias ExAtomVM.Esp32BuildStaging

  @component_manifest "idf_component.yml"
  @dependencies_lock "dependencies.lock"
  @managed_components "managed_components"
  @manifest_marker ".exatomvm_manifest.sha256"

  # Capture the manifest and its lock before cloning or cleaning can remove the
  # source, so every chip in a run stages the same bytes.
  def load_custom_components(user_provided_path) do
    path = Path.expand(user_provided_path || @component_manifest)
    lock_path = Path.join(Path.dirname(path), @dependencies_lock)

    case File.lstat(path) do
      {:error, :enoent} when is_nil(user_provided_path) ->
        {:ok, nil}

      {:error, :enoent} ->
        {:error, "Component manifest file does not exist: #{user_provided_path}"}

      _ ->
        with :ok <- validate_component_file(path),
             {:ok, content} <- read_component_file(path),
             {:ok, lock_content} <- read_lock_file(lock_path) do
          {:ok, %{path: path, content: content, lock_path: lock_path, lock_content: lock_content}}
        end
    end
  end

  def with_custom_components(_platform_dir, nil, fun), do: fun.()

  def with_custom_components(platform_dir, %{path: source_path, content: content} = selected, fun) do
    manifest_path = Path.join([platform_dir, "main", @component_manifest])
    lock_path = Path.join(platform_dir, @dependencies_lock)

    with {:ok, manifest_snapshot} <- Esp32BuildStaging.snapshot_file(manifest_path),
         {:ok, lock_snapshot} <- Esp32BuildStaging.snapshot_file(lock_path) do
      source_filename = Path.basename(source_path)
      IO.puts("Copying #{source_filename} to #{manifest_path} for this build...")

      try do
        invalidate_managed_components(platform_dir, content)

        case File.write(manifest_path, content) do
          :ok ->
            with :ok <- stage_lock(lock_path, selected) do
              case fun.() do
                {:ok, _output} = result ->
                  write_back_lock(lock_path, selected)
                  result

                result ->
                  result
              end
            end

          {:error, reason} ->
            {:error, "Failed to copy #{source_filename}: #{:file.format_error(reason)}"}
        end
      after
        restore!(manifest_path, manifest_snapshot)
        restore!(lock_path, lock_snapshot)
      end
    else
      {:error, reason} ->
        {:error, "Failed to read existing #{@component_manifest}: #{:file.format_error(reason)}"}
    end
  end

  # The IDF component manager resolves the manifest into managed_components and
  # keeps whatever it fetched there, so components from an earlier manifest
  # would be reused. The marker records which manifest those components belong
  # to; a different manifest clears them first.
  defp invalidate_managed_components(platform_dir, content) do
    dir = Path.join(platform_dir, @managed_components)
    marker = Path.join(dir, @manifest_marker)
    digest = Base.encode16(:crypto.hash(:sha256, content), case: :lower)

    if File.read(marker) != {:ok, digest} do
      if File.dir?(dir) do
        IO.puts("Component manifest changed; clearing managed_components...")
        ExAtomVM.AtomVMBuilder.clean_dir(dir)
      end

      File.mkdir_p!(dir)
      File.write!(marker, digest)
    end
  end

  defp stage_lock(lock_path, %{lock_path: source_lock, lock_content: content}) do
    if content do
      IO.puts("Copying #{Path.basename(source_lock)} to #{lock_path}...")

      case File.write(lock_path, content) do
        :ok ->
          :ok

        {:error, reason} ->
          {:error, "Failed to copy #{Path.basename(source_lock)}: #{:file.format_error(reason)}"}
      end
    else
      :ok
    end
  end

  defp write_back_lock(platform_lock, %{lock_path: source_lock, lock_content: current}) do
    case File.read(platform_lock) do
      {:ok, content} ->
        if content != current do
          IO.puts("Updating #{Path.basename(source_lock)} from ESP-IDF component manager...")
          File.write!(source_lock, content)
        end

      {:error, _reason} ->
        :ok
    end
  end

  # A failed restoration leaves the AtomVM checkout modified, so it must raise
  # rather than let the build report success.
  defp restore!(path, snapshot) do
    case Esp32BuildStaging.restore_file(path, snapshot) do
      :ok ->
        :ok

      {:error, reason} ->
        raise File.Error, reason: reason, action: "restore", path: path
    end
  end

  defp read_component_file(path) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, content}

      {:error, reason} ->
        {:error, "cannot read #{Path.basename(path)}: #{:file.format_error(reason)}"}
    end
  end

  defp read_lock_file(lock_path) do
    case File.lstat(lock_path) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.read(lock_path) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:error, lock_error(reason)}
        end

      {:ok, _stat} ->
        {:error, "#{@dependencies_lock} exists but is not a regular file"}

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, lock_error(reason)}
    end
  end

  defp lock_error(reason), do: "cannot read #{@dependencies_lock}: #{:file.format_error(reason)}"

  defp validate_component_file(path) do
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
