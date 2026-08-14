defmodule ExAtomVM.PackBEAM do
  @flash_sector_size 4 * 1024
  @slot_headroom 1024
  @archive_slot_size 4 * @flash_sector_size
  @archive_headroom @flash_sector_size
  @archive_padding_names %{
    deps: "__exatomvm_deps_padding__",
    priv: "__exatomvm_priv_padding__"
  }

  @allowed_chunks MapSet.new([
                    ~c"AtU8",
                    ~c"Code",
                    ~c"ExpT",
                    ~c"LocT",
                    ~c"ImpT",
                    ~c"LitU",
                    ~c"FunT",
                    ~c"StrT",
                    ~c"LitT"
                  ])

  @avm_header <<0x23, 0x21, 0x2F, 0x75, 0x73, 0x72, 0x2F, 0x62, 0x69, 0x6E, 0x2F, 0x65, 0x6E,
                0x76, 0x20, 0x41, 0x74, 0x6F, 0x6D, 0x56, 0x4D, 0x0A, 0x00, 0x00>>

  defp uncompress_literals(chunks) do
    with {~c"LitT", litt} <- List.keyfind(chunks, ~c"LitT", 0),
         litu <- maybe_uncompress_literals(litt) do
      chunks
      |> List.keyreplace(~c"LitT", 0, {~c"LitU", litu})
    else
      nil -> chunks
      _ -> :error
    end
  end

  defp maybe_uncompress_literals(chunk) do
    case chunk do
      <<0::32, data::binary>> ->
        data

      <<_size::4-binary, data::binary>> ->
        :zlib.uncompress(data)

      _ ->
        nil
    end
  end

  defp strip(chunks) do
    Enum.filter(chunks, fn {chunk_name, _} ->
      MapSet.member?(@allowed_chunks, chunk_name)
    end)
  end

  defp transform(beam_bytes) do
    with {:ok, module_name, chunks} <- :beam_lib.all_chunks(beam_bytes),
         u_chunks = uncompress_literals(chunks),
         s_chunks = strip(u_chunks),
         {:ok, bytes} <- :beam_lib.build_module(s_chunks) do
      {:ok, module_name, bytes}
    end
  end

  defp section_header_size(module_name) do
    12 + byte_size(module_name) + 1
  end

  defp section_header(module_name, type, size) do
    reserved = 0

    flags =
      case type do
        :eof -> 0
        :raw -> 0x04
        type when type in [:beam_start, :beam_start_slot] -> 1
        type when type in [:beam, :beam_slot] -> 2
      end

    <<size::32-big, flags::32-big, reserved::32-big, module_name::binary, 0>>
  end

  defp padding(size) do
    if rem(size, 4) != 0 do
      padding_size = 4 - rem(size, 4)
      {List.duplicate(0, padding_size), padding_size}
    else
      {[], 0}
    end
  end

  defp prepare_module(module, opts) do
    with {:ok, beam_bytes} <- File.read(module),
         {:ok, module_atom, transformed_module} <- transform(beam_bytes) do
      module_name = "#{Atom.to_string(module_atom)}.beam"
      header_size = section_header_size(module_name)
      {header_padding, header_padding_size} = padding(header_size)
      {beam_padding, beam_padding_size} = padding(byte_size(transformed_module))

      compact_size =
        header_size + header_padding_size + byte_size(transformed_module) + beam_padding_size

      {:ok,
       %{
         kind: :beam,
         module_name: module_name,
         type: opts,
         compact_size: compact_size,
         body: [header_padding, transformed_module, beam_padding],
         slotted?: opts in [:beam_slot, :beam_start_slot]
       }}
    else
      {:error, :enoent} = error ->
        IO.puts(:stderr, "Cannot find #{module}. Wrong module name?")
        error

      {:error, _} = error ->
        IO.puts(:stderr, "Cannot pack #{module}.")
        error
    end
  end

  defp round_up(size, multiple), do: div(size + multiple - 1, multiple) * multiple

  def extract_avm_content(avm_file) do
    with {:ok, avm_bytes} <- File.read(avm_file),
         <<@avm_header, without_header::binary>> <- avm_bytes do
      without_header_size = byte_size(without_header)
      end_header_size = byte_size(section_header("end", :eof, 0))

      {:ok, :binary.part(without_header, 0, without_header_size - end_header_size)}
    end
  end

  @doc false
  def sections(avm_file) do
    with {:ok, avm_bytes} <- File.read(avm_file),
         <<@avm_header, content::binary>> <- avm_bytes do
      parse_sections(content, [])
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_avm_header}
    end
  end

  @doc false
  def start_section?(%{flags: flags}) do
    Bitwise.band(flags, 1) == 1
  end

  defp parse_sections(<<0::32-big, _rest::binary>>, accum) do
    {:ok, Enum.reverse(accum)}
  end

  defp parse_sections(
         <<size::32-big, flags::32-big, _reserved::32-big, rest::binary>>,
         accum
       )
       when size >= 16 do
    section_content_size = size - 12

    case rest do
      <<section_content::binary-size(^section_content_size), remaining::binary>> ->
        case :binary.match(section_content, <<0>>) do
          {name_size, 1} ->
            section = %{
              name: binary_part(section_content, 0, name_size),
              flags: flags,
              size: size
            }

            parse_sections(remaining, [section | accum])

          :nomatch ->
            {:error, :invalid_section_name}
        end

      _ ->
        {:error, :truncated_section}
    end
  end

  defp parse_sections(_content, _accum), do: {:error, :invalid_section}

  defp prepare_any_file(file_path, opts) do
    with {:ok, file_bytes} <- File.read(file_path),
         {:ok, filename} <- Keyword.fetch(opts, :file) do
      header_size = section_header_size(filename)
      {header_padding, header_padding_size} = padding(header_size)
      {beam_padding, beam_padding_size} = padding(byte_size(file_bytes))

      file_size = byte_size(file_bytes)
      size = header_size + header_padding_size + 4 + file_size + beam_padding_size

      header = section_header(filename, :beam, size)
      iodata = [header, header_padding, <<file_size::32-big>>, file_bytes, beam_padding]

      {:ok, %{kind: :raw, compact_size: size, iodata: iodata, slotted?: false}}
    end
  end

  defp prepare_file(file, opts) do
    cond do
      String.ends_with?(file, ".beam") ->
        prepare_module(file, opts)

      String.ends_with?(file, ".avm") ->
        with {:ok, content} <- extract_avm_content(file) do
          case opts do
            {:avm_slot, archive} when archive in [:deps, :priv] ->
              alignment_prefix = if archive == :deps, do: byte_size(@avm_header), else: 0

              {:ok,
               %{
                 kind: :archive,
                 archive: archive,
                 alignment_prefix: alignment_prefix,
                 compact_size: byte_size(content),
                 iodata: content,
                 slotted?: false
               }}

            _ ->
              {:ok,
               %{kind: :raw, compact_size: byte_size(content), iodata: content, slotted?: false}}
          end
        end

      true ->
        prepare_any_file(file, opts)
    end
  end

  defp prepare_files(modules) do
    modules
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn {module, opts}, {:ok, acc} ->
      case prepare_file(module, opts) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp desired_size(%{
         kind: :archive,
         compact_size: compact_size,
         alignment_prefix: alignment_prefix
       }) do
    round_up(
      alignment_prefix + compact_size + @archive_headroom,
      @archive_slot_size
    ) - alignment_prefix
  end

  defp desired_size(%{compact_size: compact_size, slotted?: true}) do
    round_up(compact_size + @slot_headroom, @flash_sector_size)
  end

  defp desired_size(%{compact_size: compact_size}), do: compact_size

  defp minimum_size(%{
         kind: :archive,
         archive: archive,
         compact_size: compact_size,
         alignment_prefix: alignment_prefix
       }) do
    aligned_size =
      round_up(alignment_prefix + compact_size, @flash_sector_size) - alignment_prefix

    padding_size = aligned_size - compact_size

    if padding_size > 0 and padding_size < archive_padding_section_min_size(archive) do
      aligned_size + @flash_sector_size
    else
      aligned_size
    end
  end

  defp minimum_size(%{compact_size: compact_size, slotted?: true}) do
    round_up(compact_size, @flash_sector_size)
  end

  defp minimum_size(%{compact_size: compact_size}), do: compact_size

  defp assign_sizes(entries, nil) do
    Enum.map(entries, fn entry ->
      entry
      |> Map.put(:size, desired_size(entry))
      |> Map.put(:slot_level, :desired)
    end)
  end

  defp assign_sizes(entries, padding_budget) do
    entries =
      Enum.map(entries, fn entry ->
        entry
        |> Map.put(:size, entry.compact_size)
        |> Map.put(:slot_level, :compact)
      end)

    {entries, padding_budget} = assign_archive_alignment(entries, padding_budget)
    {entries, padding_budget} = assign_module_sector_prefix(entries, padding_budget)
    {entries, padding_budget} = assign_module_headroom(entries, padding_budget)
    {entries, _padding_budget} = assign_archive_reserves(entries, padding_budget)

    entries
  end

  defp assign_archive_alignment(entries, padding_budget) do
    required_padding =
      entries
      |> Enum.filter(&(&1.kind == :archive))
      |> Enum.reduce(0, fn entry, total ->
        total + minimum_size(entry) - entry.compact_size
      end)

    if required_padding <= padding_budget do
      entries =
        Enum.map(entries, fn
          %{kind: :archive} = entry ->
            entry
            |> Map.put(:size, minimum_size(entry))
            |> Map.put(:slot_level, :minimum)

          entry ->
            entry
        end)

      {entries, padding_budget - required_padding}
    else
      {entries, padding_budget}
    end
  end

  defp assign_archive_reserves(entries, padding_budget) do
    Enum.reduce([:deps, :priv], {entries, padding_budget}, fn archive, {entries, remaining} ->
      case Enum.find(entries, &(&1.kind == :archive and &1.archive == archive)) do
        %{slot_level: :minimum} = entry ->
          extra = desired_size(entry) - minimum_size(entry)

          if extra <= remaining do
            entries =
              Enum.map(entries, fn
                %{kind: :archive, archive: ^archive} = entry ->
                  entry
                  |> Map.put(:size, desired_size(entry))
                  |> Map.put(:slot_level, :desired)

                entry ->
                  entry
              end)

            {entries, remaining - extra}
          else
            {entries, remaining}
          end

        _ ->
          {entries, remaining}
      end
    end)
  end

  defp assign_module_sector_prefix(entries, padding_budget) do
    {entries, {remaining, _padding_prefix?}} =
      Enum.map_reduce(entries, {padding_budget, true}, fn entry, {remaining, padding_prefix?} ->
        padding = minimum_size(entry) - entry.compact_size

        cond do
          not entry.slotted? ->
            {entry, {remaining, padding_prefix?}}

          padding_prefix? and padding <= remaining ->
            entry =
              entry
              |> Map.put(:size, entry.compact_size + padding)
              |> Map.put(:slot_level, :minimum)

            {entry, {remaining - padding, true}}

          true ->
            {Map.put(entry, :size, entry.compact_size), {remaining, false}}
        end
      end)

    {entries, remaining}
  end

  defp assign_module_headroom(entries, padding_budget) do
    Enum.map_reduce(entries, padding_budget, fn entry, remaining ->
      if entry.slotted? and entry.slot_level == :minimum do
        extra = desired_size(entry) - minimum_size(entry)

        if extra <= remaining do
          entry =
            entry
            |> Map.put(:size, desired_size(entry))
            |> Map.put(:slot_level, :desired)

          {entry, remaining - extra}
        else
          {entry, remaining}
        end
      else
        {entry, remaining}
      end
    end)
  end

  defp render_entry(%{kind: :raw, iodata: iodata}), do: iodata

  defp render_entry(%{
         kind: :archive,
         archive: archive,
         compact_size: compact_size,
         size: size,
         iodata: iodata
       }) do
    padding_size = size - compact_size

    if padding_size == 0 do
      iodata
    else
      [iodata, archive_padding_section(archive, padding_size)]
    end
  end

  defp render_entry(%{
         kind: :beam,
         module_name: module_name,
         type: type,
         compact_size: compact_size,
         size: size,
         body: body
       }) do
    slot_padding = :binary.copy(<<0>>, size - compact_size)
    [section_header(module_name, type, size), body, slot_padding]
  end

  defp archive_padding_section(archive, size) do
    name = archive_padding_name(archive)
    header_size = section_header_size(name)
    {header_padding, header_padding_size} = padding(header_size)
    content_padding_size = size - header_size - header_padding_size - 4

    [
      section_header(name, :raw, size),
      header_padding,
      <<0::32-big>>,
      :binary.copy(<<0>>, content_padding_size)
    ]
  end

  defp archive_padding_section_min_size(archive) do
    name = archive_padding_name(archive)
    header_size = section_header_size(name)
    {_header_padding, header_padding_size} = padding(header_size)
    header_size + header_padding_size + 4
  end

  @doc false
  def archive_padding_name(archive), do: Map.fetch!(@archive_padding_names, archive)

  defp make_stats(entries, compact_size, max_size) do
    size = container_size() + Enum.sum(Enum.map(entries, & &1.size))
    slotted_entries = Enum.filter(entries, & &1.slotted?)

    desired_padding =
      Enum.reduce(entries, 0, fn entry, total ->
        total + desired_size(entry) - entry.compact_size
      end)

    archive_entries = Enum.filter(entries, &(&1.kind == :archive))

    archive_alignment_padding_size =
      Enum.sum(Enum.map(archive_entries, &(minimum_size(&1) - &1.compact_size)))

    padded_modules = Enum.count(slotted_entries, &(&1.size > &1.compact_size))

    full_headroom_modules =
      Enum.count(slotted_entries, &(&1.size - &1.compact_size >= @slot_headroom))

    %{
      size: size,
      compact_size: compact_size,
      padding_size: size - compact_size,
      desired_padding_size: desired_padding,
      max_size: max_size,
      module_count: length(slotted_entries),
      padded_modules: padded_modules,
      full_headroom_modules: full_headroom_modules,
      archive_count: length(archive_entries),
      archive_alignment_padding_size: archive_alignment_padding_size,
      archive_padding_size: Enum.sum(Enum.map(archive_entries, &(&1.size - &1.compact_size))),
      full_archive_slots: Enum.count(archive_entries, &(&1.size == desired_size(&1))),
      module_padding_size: Enum.sum(Enum.map(slotted_entries, &(&1.size - &1.compact_size))),
      padding_reduced?: size - compact_size < desired_padding
    }
  end

  defp container_size do
    byte_size(@avm_header) + byte_size(section_header("end", :eof, 0))
  end

  defp build_avm(modules, opts) do
    max_size = Keyword.get(opts, :max_size)

    with :ok <- validate_max_size(max_size),
         {:ok, entries} <- prepare_files(modules) do
      compact_size = container_size() + Enum.sum(Enum.map(entries, & &1.compact_size))

      if is_integer(max_size) and compact_size > max_size do
        {:error,
         {:max_size_exceeded,
          %{
            compact_size: compact_size,
            max_size: max_size,
            over_by: compact_size - max_size
          }}}
      else
        padding_budget = if is_integer(max_size), do: max_size - compact_size
        entries = assign_sizes(entries, padding_budget)
        stats = make_stats(entries, compact_size, max_size)
        packed = Enum.map(entries, &render_entry/1)

        {:ok, [@avm_header, packed, section_header("end", :eof, 0)], stats}
      end
    end
  end

  defp validate_max_size(nil), do: :ok
  defp validate_max_size(max_size) when is_integer(max_size) and max_size > 0, do: :ok
  defp validate_max_size(max_size), do: {:error, {:invalid_max_size, max_size}}

  def make_avm(modules, out) do
    with {:ok, _stats} <- make_avm(modules, out, []) do
      :ok
    end
  end

  def make_avm(modules, out, opts) do
    with {:ok, bytes, stats} <- build_avm(modules, opts),
         :ok <- File.write(out, bytes) do
      {:ok, stats}
    end
  end

  @doc false
  def packing_stats(modules, opts \\ []) do
    with {:ok, _bytes, stats} <- build_avm(modules, opts) do
      {:ok, stats}
    end
  end
end
