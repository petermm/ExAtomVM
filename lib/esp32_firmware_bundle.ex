defmodule ExAtomVM.Esp32FirmwareBundle do
  @moduledoc false

  # Assembles the bundle the firmware factory publishes, next to a built image:
  # the image with its checksums, the sdkconfig and partition table it was built
  # with, the parts of the image, FLASH.txt, the ELF and map files, and
  # SHA256SUMS. `mix atomvm.esp32.install` reads this format, so a build's
  # output can be installed by path, or shared as one file.

  @flash_entries ["bootloader", "partition-table", "app", "boot.avm"]

  @part_names %{
    "bootloader" => "bootloader.bin",
    "partition-table" => "partition-table.bin",
    "app" => "atomvm-esp32.bin"
  }

  @debug_files [
    "atomvm-esp32.elf",
    "atomvm-esp32.map",
    "bootloader/bootloader.elf",
    "bootloader/bootloader.map",
    "prefix_map_gdbinit"
  ]

  @doc """
  Writes `<image>.zip` next to the image.

  Options:

    * `:stem` - image name without the `.img` extension
    * `:image` - path to the built image
    * `:build_dir` - ESP-IDF build directory, with `flasher_args.json` and the
      debug files
    * `:platform_dir` - AtomVM's ESP32 platform directory, with `sdkconfig` and
      the partition table
    * `:chip` - target chip
    * `:partitions` - the partition table CSV the image was built with, when it
      differs from the one in the platform directory
  """
  def write(options) do
    build_dir = options.build_dir
    platform_dir = options.platform_dir

    with {:ok, parts, flash} <- flash_parts(build_dir),
         {:ok, image} <- read_file(options.image),
         :ok <- check_parts_in_image(Path.basename(options.image), image, parts),
         {:ok, sdkconfig} <- read_file(Path.join(platform_dir, "sdkconfig")),
         {:ok, partitions} <- partitions_csv(platform_dir, sdkconfig, options[:partitions]),
         {:ok, debug} <- debug_members(build_dir) do
      members =
        members(options.stem, image, sdkconfig, partitions, parts, flash, debug, options.chip)

      zip_path = Path.rootname(options.image) <> ".zip"

      case write_zip(zip_path, members) do
        :ok -> {:ok, zip_path}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # --- the build's outputs ---

  defp flash_parts(build_dir) do
    path = Path.join(build_dir, "flasher_args.json")

    with {:ok, text} <- read_file(path),
         {:ok, json} <- decode_json(text, path),
         {:ok, parts} <- read_parts(json, build_dir) do
      {:ok, parts, json["flash_settings"] || %{}}
    end
  end

  defp decode_json(text, path) do
    case :json.decode(text) do
      json when is_map(json) -> {:ok, json}
      _other -> {:error, "#{Path.basename(path)} is not a JSON object"}
    end
  rescue
    _error -> {:error, "#{Path.basename(path)} is not valid JSON"}
  end

  defp read_parts(json, build_dir) do
    Enum.reduce_while(@flash_entries, {:ok, []}, fn entry, {:ok, parts} ->
      case json[entry] do
        %{"offset" => offset, "file" => file} ->
          with {:ok, offset} <- parse_offset(offset),
               {:ok, data} <- read_file(Path.join(build_dir, file)) do
            name = Map.get(@part_names, entry, Path.basename(file))
            {:cont, {:ok, parts ++ [%{name: name, offset: offset, data: data}]}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end

        _other ->
          {:halt, {:error, "flasher_args.json has no #{entry} entry"}}
      end
    end)
  end

  defp parse_offset("0x" <> digits), do: parse_hex(digits)
  defp parse_offset(offset) when is_integer(offset), do: {:ok, offset}
  defp parse_offset(_other), do: {:error, "unexpected flash offset in flasher_args.json"}

  defp parse_hex(digits) do
    case Integer.parse(digits, 16) do
      {offset, ""} -> {:ok, offset}
      _other -> {:error, "unexpected flash offset in flasher_args.json"}
    end
  end

  # Each part must be in the image at its offset: install and update write the
  # same bytes.
  defp check_parts_in_image(name, image, parts) do
    base = base_offset(parts)

    Enum.reduce_while(parts, :ok, fn part, :ok ->
      start = part.offset - base
      size = byte_size(part.data)

      if start >= 0 and start + size <= byte_size(image) and
           binary_part(image, start, size) == part.data do
        {:cont, :ok}
      else
        {:halt, {:error, "#{name}: #{part.name} differs from the image at #{hex(part.offset)}"}}
      end
    end)
  end

  defp base_offset(parts) do
    parts |> Enum.find(&(&1.name == "bootloader.bin")) |> Map.fetch!(:offset)
  end

  defp partitions_csv(platform_dir, sdkconfig, nil) do
    filename =
      sdkconfig_value(sdkconfig, "CONFIG_PARTITION_TABLE_CUSTOM_FILENAME") || "partitions.csv"

    read_file(Path.join(platform_dir, filename))
  end

  defp partitions_csv(_platform_dir, _sdkconfig, content) when is_binary(content),
    do: {:ok, content}

  defp debug_members(build_dir) do
    Enum.reduce_while(@debug_files, {:ok, []}, fn relative, {:ok, members} ->
      case read_file(Path.join(build_dir, relative)) do
        {:ok, data} -> {:cont, {:ok, members ++ [{Path.basename(relative), data}]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # --- the bundle ---

  defp members(stem, image, sdkconfig, partitions, parts, flash, debug, chip) do
    app_offset = partition_offset(partitions, "main.avm")
    elf_sha = elf_sha256(debug)

    flash_txt =
      flash_txt(stem, chip, parts, flash, sdkconfig, app_offset, elf_sha)
      |> String.trim_leading("\n")

    summed =
      [
        {"#{stem}.img", image},
        {"sdkconfig", sdkconfig},
        {"partitions.csv", partitions},
        {"FLASH.txt", flash_txt}
      ] ++ Enum.map(parts, &{&1.name, &1.data}) ++ debug

    [
      {"#{stem}.img", image},
      {"#{stem}.img.sha256", "#{sha256(image)}  #{stem}.img\n"},
      {"sdkconfig", sdkconfig},
      {"partitions.csv", partitions},
      {"FLASH.txt", flash_txt}
    ] ++
      Enum.map(parts, &{&1.name, &1.data}) ++
      debug ++ [{"SHA256SUMS", sha256sums(summed)}]
  end

  defp elf_sha256(debug) do
    case Enum.find(debug, fn {name, _data} -> name == "atomvm-esp32.elf" end) do
      {_name, elf} -> sha256(elf)
      nil -> "unknown"
    end
  end

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp sha256sums(members) do
    Enum.map_join(members, "", fn {name, data} -> "#{sha256(data)}  #{name}\n" end)
  end

  defp flash_txt(stem, chip, parts, flash, sdkconfig, app_offset, elf_sha) do
    base = base_offset(parts)
    [bootloader, table, app, lib] = parts
    stamp = sdkconfig_value(sdkconfig, "CONFIG_APP_PROJECT_VER") || "unknown"
    idf = idf_version(sdkconfig)
    port = "--chip #{chip} --port /dev/ttyUSB0 --baud 921600"
    mode = flash["flash_mode"] || "dio"
    freq = flash["flash_freq"] || "80m"

    """

    AtomVM firmware image: #{stem}.img
    Chip: #{chip}
    AtomVM build: #{stamp}
    ESP-IDF: #{idf}
    Flash offset: #{hex(base)}
    #{app_offset && "Application partition (main.avm): #{hex(app_offset)}"}

    Run the commands below from an ESP-IDF environment, with the serial port your
    board shows up as (e.g. /dev/ttyACM0 for native USB) instead of /dev/ttyUSB0.
    Check the extracted files first:

      sha256sum -c SHA256SUMS

    Install
    -------

    The image holds the bootloader, the partition table, the AtomVM virtual
    machine and its boot library, laid out for a 4 MB flash. The gaps between
    them are filled with 0xFF, so flashing the image also erases the NVS
    partition (Wi-Fi settings and data stored by applications) and phy_init;
    main.avm is left untouched.

      esptool.py #{port} erase_flash
      esptool.py #{port} \\
          --before default_reset --after hard_reset write_flash \\
          --flash_mode #{mode} --flash_freq #{freq} --flash_size detect \\
          #{hex(base)} #{stem}.img

    Or, from the project this bundle was built in:

      mix atomvm.esp32.install --image #{stem}.zip

    Update an existing AtomVM installation
    --------------------------------------

    This writes only the virtual machine (#{app.name}) and its boot library
    (#{lib.name}), keeping the bootloader, the partition table, NVS and
    main.avm. The partition table on the board must be identical to this image's
    (#{table.name} checks it), and its bootloader must not come from a newer
    ESP-IDF than #{idf}.

      esptool.py #{port} --after no_reset \\
          verify_flash #{hex(table.offset)} #{table.name} && \\
      esptool.py #{port} \\
          --before default_reset --after hard_reset write_flash \\
          #{hex(app.offset)} #{app.name} #{hex(lib.offset)} #{lib.name}

    Or: mix atomvm.esp32.install --update --image #{stem}.zip

    Contents
    --------

    #{contents(parts)}

    Debugging
    ---------

    #{bootloader.name} starts the app; atomvm-esp32.elf holds its symbols. The
    board prints the start of the app ELF's SHA-256 at boot and on panics:

      #{elf_sha}

    Decode addresses with the toolchain's addr2line, or monitor the board with:

      python -m esp_idf_monitor --port /dev/ttyUSB0 --target #{chip} \\
          atomvm-esp32.elf bootloader.elf
    """
  end

  defp contents(parts) do
    Enum.map_join(parts, "\n", fn part -> "  #{hex(part.offset)} #{part.name}" end)
  end

  defp hex(offset), do: "0x" <> Integer.to_string(offset, 16)

  defp sdkconfig_value(text, key) do
    case Regex.run(~r/^#{key}=(.*)$/m, text) do
      [_, value] -> String.trim(value, "\"")
      nil -> nil
    end
  end

  defp idf_version(sdkconfig) do
    case Regex.run(
           ~r/^# Espressif IoT Development Framework \(ESP-IDF\) (\S+) Project Configuration$/m,
           sdkconfig
         ) do
      [_, version] -> version
      nil -> "unknown"
    end
  end

  # The offset column of the partition called `name`, as written in the CSV.
  defp partition_offset(csv, name) do
    csv
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      fields =
        line
        |> String.split("#", parts: 2)
        |> hd()
        |> String.split(",")
        |> Enum.map(&String.trim/1)

      case fields do
        [^name, _type, _subtype, offset | _rest] ->
          case parse_offset(offset) do
            {:ok, offset} -> offset
            {:error, _reason} -> nil
          end

        _other ->
          nil
      end
    end)
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp write_zip(path, members) do
    File.mkdir_p!(Path.dirname(path))
    entries = Enum.map(members, fn {name, data} -> {String.to_charlist(name), data} end)

    case :zip.create(String.to_charlist(path), entries, []) do
      {:ok, _path} -> :ok
      {:error, reason} -> {:error, "cannot write #{Path.basename(path)}: #{inspect(reason)}"}
    end
  end
end
