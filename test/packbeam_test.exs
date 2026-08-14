defmodule Mix.Tasks.Atomvm.PackbeamTest do
  use ExUnit.Case, async: true

  alias ExAtomVM.PackBEAM
  alias Mix.Tasks.Atomvm.Packbeam

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "exatomvm-packbeam-test-#{System.unique_integer([:positive])}"
      )

    beams_dir = Path.join(tmp_dir, "beams")
    File.mkdir_p!(beams_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{beams_dir: beams_dir, tmp_dir: tmp_dir}
  end

  test "packs stable archives first and the start module last", %{
    beams_dir: beams_dir,
    tmp_dir: tmp_dir
  } do
    suffix = System.unique_integer([:positive])
    dependency = fixture_module("Dependency", suffix)
    app_a = fixture_module("AppA", suffix)
    app_z = fixture_module("AppZ", suffix)
    start = fixture_module("Start", suffix)

    dependency_beam = write_beam(tmp_dir, dependency)
    app_z_beam = write_beam(beams_dir, app_z)
    start_beam = write_beam(beams_dir, start, "def start(), do: :ok")
    app_a_beam = write_beam(beams_dir, app_a)

    deps_avm = Path.join(tmp_dir, "deps.avm")
    priv_avm = Path.join(tmp_dir, "priv.avm")
    output_avm = Path.join(tmp_dir, "application.avm")

    assert :ok = PackBEAM.make_avm([{dependency_beam, :beam}], deps_avm)
    assert :ok = PackBEAM.make_avm([], priv_avm)

    assert {:ok, inputs} =
             Packbeam.ordered_packbeam_inputs(
               beams_dir,
               Path.basename(start_beam),
               deps_avm,
               priv_avm,
               slot_modules: true
             )

    assert inputs == [
             {deps_avm, {:avm_slot, :deps}},
             {priv_avm, {:avm_slot, :priv}},
             {app_a_beam, :beam_slot},
             {app_z_beam, :beam_slot},
             {start_beam, :beam_start_slot}
           ]

    assert :ok = PackBEAM.make_avm(inputs, output_avm)
    assert {:ok, sections} = PackBEAM.sections(output_avm)

    assert Enum.map(sections, & &1.name) == [
             beam_filename(dependency),
             PackBEAM.archive_padding_name(:deps),
             PackBEAM.archive_padding_name(:priv),
             beam_filename(app_a),
             beam_filename(app_z),
             beam_filename(start)
           ]

    assert sections |> Enum.filter(&PackBEAM.start_section?/1) |> Enum.map(& &1.name) == [
             beam_filename(start)
           ]

    padding_names = [
      PackBEAM.archive_padding_name(:deps),
      PackBEAM.archive_padding_name(:priv)
    ]

    assert sections
           |> Enum.filter(&(&1.name in padding_names))
           |> Enum.all?(&(&1.flags == 0x04))

    section_offsets = section_offsets(sections)

    assert section_end(section_offsets, PackBEAM.archive_padding_name(:deps))
           |> rem(4 * 1024) == 0

    assert section_end(section_offsets, PackBEAM.archive_padding_name(:priv))
           |> rem(4 * 1024) == 0

    app_names = [beam_filename(app_a), beam_filename(app_z), beam_filename(start)]

    assert section_offsets
           |> Enum.filter(fn {section, _offset} -> section.name in app_names end)
           |> Enum.all?(fn {_section, offset} -> rem(offset, 4 * 1024) == 0 end)
  end

  test "reserves one KiB of headroom in flash-sector-sized application slots", %{
    tmp_dir: tmp_dir
  } do
    suffix = System.unique_integer([:positive])
    small_module = fixture_module("SmallSlot", suffix)
    large_module = fixture_module("LargeSlot", suffix)

    small_beam = write_beam(tmp_dir, small_module)

    large_beam =
      write_beam(
        tmp_dir,
        large_module,
        ~s|def value(), do: "#{String.duplicate("x", 3_500)}"|
      )

    compact_avm = Path.join(tmp_dir, "compact.avm")
    slotted_avm = Path.join(tmp_dir, "slotted.avm")

    assert :ok =
             PackBEAM.make_avm(
               [{small_beam, :beam}, {large_beam, :beam}],
               compact_avm
             )

    assert :ok =
             PackBEAM.make_avm(
               [{small_beam, :beam_slot}, {large_beam, :beam_slot}],
               slotted_avm
             )

    assert {:ok, [small_compact, large_compact]} = PackBEAM.sections(compact_avm)
    assert {:ok, [small_slot, large_slot]} = PackBEAM.sections(slotted_avm)

    assert small_compact.size <= 3 * 1024
    assert small_slot.size == 4 * 1024
    assert large_compact.size > 3 * 1024
    assert large_compact.size <= 7 * 1024
    assert large_slot.size == 8 * 1024

    assert small_slot.size == expected_slot_size(small_compact.size)
    assert large_slot.size == expected_slot_size(large_compact.size)
  end

  test "archive slots contain typical archive growth without moving the application", %{
    tmp_dir: tmp_dir
  } do
    suffix = System.unique_integer([:positive])
    dependency_a = fixture_module("ArchiveA", suffix)
    dependency_b = fixture_module("ArchiveB", suffix)
    app = fixture_module("ArchiveApp", suffix)
    dependency_a_beam = write_beam(tmp_dir, dependency_a, literal_body(2_600))
    dependency_b_beam = write_beam(tmp_dir, dependency_b, literal_body(3_100))
    app_beam = write_beam(tmp_dir, app, "def start(), do: :ok")
    deps_a = Path.join(tmp_dir, "deps-a.avm")
    deps_b = Path.join(tmp_dir, "deps-b.avm")
    priv = Path.join(tmp_dir, "priv.avm")
    output_a = Path.join(tmp_dir, "application-a.avm")
    output_b = Path.join(tmp_dir, "application-b.avm")

    assert :ok = PackBEAM.make_avm([{dependency_a_beam, :beam}], deps_a)
    assert :ok = PackBEAM.make_avm([{dependency_b_beam, :beam}], deps_b)
    assert :ok = PackBEAM.make_avm([], priv)

    assert {:ok, [dependency_a_section]} = PackBEAM.sections(deps_a)
    assert {:ok, [dependency_b_section]} = PackBEAM.sections(deps_b)
    assert dependency_b_section.size > dependency_a_section.size

    assert {:ok, _stats} =
             PackBEAM.make_avm(
               [
                 {deps_a, {:avm_slot, :deps}},
                 {priv, {:avm_slot, :priv}},
                 {app_beam, :beam_start_slot}
               ],
               output_a,
               max_size: 0x100000
             )

    assert {:ok, _stats} =
             PackBEAM.make_avm(
               [
                 {deps_b, {:avm_slot, :deps}},
                 {priv, {:avm_slot, :priv}},
                 {app_beam, :beam_start_slot}
               ],
               output_b,
               max_size: 0x100000
             )

    assert {:ok, sections_a} = PackBEAM.sections(output_a)
    assert {:ok, sections_b} = PackBEAM.sections(output_b)

    assert section_offset(sections_a, beam_filename(app)) ==
             section_offset(sections_b, beam_filename(app))

    assert section_size(sections_b, PackBEAM.archive_padding_name(:deps)) <
             section_size(sections_a, PackBEAM.archive_padding_name(:deps))
  end

  test "prioritizes application module slots before extra archive reserves", %{tmp_dir: tmp_dir} do
    suffix = System.unique_integer([:positive])
    dependency = fixture_module("PriorityDep", suffix)
    app_a = fixture_module("PriorityA", suffix)
    app_b = fixture_module("PriorityB", suffix)
    dependency_beam = write_beam(tmp_dir, dependency)
    app_a_beam = write_beam(tmp_dir, app_a)
    app_b_beam = write_beam(tmp_dir, app_b, "def start(), do: :ok")
    deps = Path.join(tmp_dir, "priority-deps.avm")
    priv = Path.join(tmp_dir, "priority-priv.avm")

    assert :ok = PackBEAM.make_avm([{dependency_beam, :beam}], deps)
    assert :ok = PackBEAM.make_avm([], priv)

    compact_inputs = [
      {deps, :avm},
      {priv, :avm},
      {app_a_beam, :beam},
      {app_b_beam, :beam_start}
    ]

    slotted_inputs = [
      {deps, {:avm_slot, :deps}},
      {priv, {:avm_slot, :priv}},
      {app_a_beam, :beam_slot},
      {app_b_beam, :beam_start_slot}
    ]

    assert {:ok, compact_stats} = PackBEAM.packing_stats(compact_inputs)
    assert {:ok, desired_stats} = PackBEAM.packing_stats(slotted_inputs)

    max_size =
      compact_stats.size + desired_stats.archive_alignment_padding_size +
        desired_stats.module_padding_size

    assert {:ok, limited_stats} =
             PackBEAM.packing_stats(slotted_inputs, max_size: max_size)

    assert limited_stats.size == max_size
    assert limited_stats.full_archive_slots == 0

    assert limited_stats.archive_padding_size ==
             desired_stats.archive_alignment_padding_size

    assert limited_stats.module_padding_size == desired_stats.module_padding_size
    assert limited_stats.full_headroom_modules == limited_stats.module_count
    assert limited_stats.padding_reduced?
  end

  test "keeps application modules compact unless a target explicitly enables slots", %{
    beams_dir: beams_dir,
    tmp_dir: tmp_dir
  } do
    suffix = System.unique_integer([:positive])
    app_module = fixture_module("Compact", suffix)
    start_module = fixture_module("CompactStart", suffix)

    app_beam = write_beam(beams_dir, app_module)
    start_beam = write_beam(beams_dir, start_module, "def start(), do: :ok")
    deps_avm = Path.join(tmp_dir, "deps.avm")
    priv_avm = Path.join(tmp_dir, "priv.avm")

    assert :ok = PackBEAM.make_avm([], deps_avm)
    assert :ok = PackBEAM.make_avm([], priv_avm)

    assert {:ok, inputs} =
             Packbeam.ordered_packbeam_inputs(
               beams_dir,
               Path.basename(start_beam),
               deps_avm,
               priv_avm
             )

    assert inputs == [
             {deps_avm, :avm},
             {priv_avm, :avm},
             {app_beam, :beam},
             {start_beam, :beam_start}
           ]
  end

  test "resolves max_size from CLI, configuration, then target default" do
    assert {:ok, 100} = Packbeam.resolve_max_size(%{}, [], max_size: 100)
    assert {:ok, 200} = Packbeam.resolve_max_size(%{}, [max_size: 200], max_size: 100)

    assert {:ok, 300} =
             Packbeam.resolve_max_size(%{max_size: 300}, [max_size: 200], max_size: 100)

    assert {:ok, nil} = Packbeam.resolve_max_size(%{}, [], [])
    assert {:error, 0} = Packbeam.resolve_max_size(%{max_size: 0}, [], [])
    assert {:error, nil} = Packbeam.resolve_max_size(%{}, [max_size: nil], max_size: 100)
  end

  test "parses decimal and hexadecimal max_size and rejects malformed values" do
    assert {:ok, %{max_size: 1_048_576}} =
             Packbeam.parse_options(["--max-size", "1048576"])

    assert {:ok, %{max_size: 0x100000}} =
             Packbeam.parse_options(["--max-size", "0x100000"])

    assert {:ok, %{max_size: 0x1A0000}} =
             Packbeam.parse_options(["--max_size", "0X1A0000"])

    assert :error = Packbeam.parse_options(["--max-size", "0"])
    assert :error = Packbeam.parse_options(["--max-size", "invalid"])
    assert :error = Packbeam.parse_options(["--max-size"])
  end

  test "removes extra headroom before removing sector rounding", %{tmp_dir: tmp_dir} do
    suffix = System.unique_integer([:positive])
    first_module = fixture_module("BoundaryA", suffix)
    second_module = fixture_module("BoundaryB", suffix)
    body = ~s|def value(), do: "#{String.duplicate("x", 2_600)}"|
    first_beam = write_beam(tmp_dir, first_module, body)
    second_beam = write_beam(tmp_dir, second_module, body)
    compact_avm = Path.join(tmp_dir, "boundary-compact.avm")
    output_avm = Path.join(tmp_dir, "boundary.avm")

    assert :ok =
             PackBEAM.make_avm(
               [{first_beam, :beam}, {second_beam, :beam}],
               compact_avm
             )

    compact_size = File.stat!(compact_avm).size
    assert {:ok, compact_sections} = PackBEAM.sections(compact_avm)
    assert Enum.all?(compact_sections, &(&1.size > 3 * 1024 and &1.size <= 4 * 1024))

    minimum_sizes = Enum.map(compact_sections, &round_up(&1.size, 4 * 1024))
    minimum_padding = Enum.zip_with(minimum_sizes, compact_sections, &(&1 - &2.size))
    max_size = compact_size + Enum.sum(minimum_padding)

    assert {:ok, stats} =
             PackBEAM.make_avm(
               [{first_beam, :beam_slot}, {second_beam, :beam_slot}],
               output_avm,
               max_size: max_size
             )

    assert stats.size == max_size
    assert stats.padding_reduced?
    assert stats.padded_modules == 2
    assert stats.full_headroom_modules == 0
    assert {:ok, sections} = PackBEAM.sections(output_avm)
    assert Enum.map(sections, & &1.size) == minimum_sizes
  end

  test "refuses an archive whose compact content exceeds max_size", %{tmp_dir: tmp_dir} do
    suffix = System.unique_integer([:positive])
    module = fixture_module("Oversize", suffix)
    beam = write_beam(tmp_dir, module)
    compact_avm = Path.join(tmp_dir, "compact.avm")
    output_avm = Path.join(tmp_dir, "oversize.avm")

    assert :ok = PackBEAM.make_avm([{beam, :beam}], compact_avm)
    compact_size = File.stat!(compact_avm).size

    assert {:error,
            {:max_size_exceeded, %{compact_size: ^compact_size, max_size: max_size, over_by: 1}}} =
             PackBEAM.make_avm([{beam, :beam_slot}], output_avm, max_size: compact_size - 1)

    assert max_size == compact_size - 1
    refute File.exists?(output_avm)
  end

  test "reports padding reductions while keeping the archive within max_size", %{
    tmp_dir: tmp_dir
  } do
    suffix = System.unique_integer([:positive])
    first_module = fixture_module("LimitedA", suffix)
    second_module = fixture_module("LimitedB", suffix)
    first_beam = write_beam(tmp_dir, first_module)
    second_beam = write_beam(tmp_dir, second_module)
    compact_avm = Path.join(tmp_dir, "limited-compact.avm")
    output_avm = Path.join(tmp_dir, "limited.avm")

    assert :ok =
             PackBEAM.make_avm(
               [{first_beam, :beam}, {second_beam, :beam}],
               compact_avm
             )

    compact_size = File.stat!(compact_avm).size
    assert {:ok, [first_compact, second_compact]} = PackBEAM.sections(compact_avm)
    first_padding = round_up(first_compact.size, 4 * 1024) - first_compact.size
    max_size = compact_size + first_padding

    assert {:ok, stats} =
             PackBEAM.make_avm(
               [{first_beam, :beam_slot}, {second_beam, :beam_slot}],
               output_avm,
               max_size: max_size
             )

    assert stats.size <= max_size
    assert stats.compact_size == compact_size
    assert stats.padding_size == first_padding
    assert stats.padded_modules == 1
    assert stats.module_count == 2
    assert stats.padding_reduced?

    assert {:ok, [first_section, second_section]} = PackBEAM.sections(output_avm)
    assert first_section.size == round_up(first_compact.size, 4 * 1024)
    assert second_section.size == second_compact.size
  end

  test "rejects a start section embedded in the dependency archive", %{
    beams_dir: beams_dir,
    tmp_dir: tmp_dir
  } do
    suffix = System.unique_integer([:positive])
    dependency_start = fixture_module("DependencyStart", suffix)
    app_start = fixture_module("AppStart", suffix)

    dependency_beam = write_beam(tmp_dir, dependency_start, "def start(), do: :ok")
    app_start_beam = write_beam(beams_dir, app_start, "def start(), do: :ok")
    deps_avm = Path.join(tmp_dir, "deps.avm")
    priv_avm = Path.join(tmp_dir, "priv.avm")

    assert :ok = PackBEAM.make_avm([{dependency_beam, :beam_start}], deps_avm)
    assert :ok = PackBEAM.make_avm([], priv_avm)

    assert {:error, {:dependency_start_sections, [name]}} =
             Packbeam.ordered_packbeam_inputs(
               beams_dir,
               Path.basename(app_start_beam),
               deps_avm,
               priv_avm
             )

    assert name == beam_filename(dependency_start)
  end

  test "rejects dependency modules that would shadow application modules", %{
    beams_dir: beams_dir,
    tmp_dir: tmp_dir
  } do
    suffix = System.unique_integer([:positive])
    colliding_module = fixture_module("Collision", suffix)
    app_start = fixture_module("CollisionStart", suffix)

    colliding_beam = write_beam(beams_dir, colliding_module)
    app_start_beam = write_beam(beams_dir, app_start, "def start(), do: :ok")
    deps_avm = Path.join(tmp_dir, "deps.avm")
    priv_avm = Path.join(tmp_dir, "priv.avm")

    assert :ok = PackBEAM.make_avm([{colliding_beam, :beam}], deps_avm)
    assert :ok = PackBEAM.make_avm([], priv_avm)

    assert {:error, {:dependency_module_collisions, [name]}} =
             Packbeam.ordered_packbeam_inputs(
               beams_dir,
               Path.basename(app_start_beam),
               deps_avm,
               priv_avm
             )

    assert name == beam_filename(colliding_module)
  end

  defp fixture_module(prefix, suffix) do
    Module.concat([ExAtomVM.PackBEAMFixtures, "#{prefix}#{suffix}"])
  end

  defp write_beam(directory, module, body \\ "def value(), do: :ok") do
    [{^module, beam}] = Code.compile_string("defmodule #{inspect(module)} do #{body} end")
    path = Path.join(directory, beam_filename(module))
    File.write!(path, beam)
    path
  end

  defp beam_filename(module), do: "#{Atom.to_string(module)}.beam"

  defp literal_body(size), do: ~s|def value(), do: "#{String.duplicate("x", size)}"|

  defp expected_slot_size(compact_size) do
    div(compact_size + 1024 + 4 * 1024 - 1, 4 * 1024) * 4 * 1024
  end

  defp round_up(size, multiple), do: div(size + multiple - 1, multiple) * multiple

  defp section_offsets(sections) do
    {sections, _end_offset} =
      Enum.map_reduce(sections, 24, fn section, offset ->
        {{section, offset}, offset + section.size}
      end)

    sections
  end

  defp section_end(section_offsets, name) do
    {section, offset} =
      Enum.find(section_offsets, fn {section, _offset} -> section.name == name end)

    offset + section.size
  end

  defp section_offset(sections, name) do
    {_section, offset} =
      sections
      |> section_offsets()
      |> Enum.find(fn {section, _offset} -> section.name == name end)

    offset
  end

  defp section_size(sections, name) do
    sections
    |> Enum.find(&(&1.name == name))
    |> Map.fetch!(:size)
  end
end
