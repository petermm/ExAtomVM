defmodule ExAtomVM.Esp32FirmwareBundleTest do
  use ExUnit.Case, async: false

  alias ExAtomVM.Esp32FirmwareBundle
  alias ExAtomVM.Esp32FirmwareImages

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

  setup %{tmp_dir: tmp_dir} do
    build_dir = Path.join(tmp_dir, "build")
    platform_dir = Path.join(tmp_dir, "platform")
    images_dir = Path.join(tmp_dir, "_build/atomvm_images")

    File.mkdir_p!(Path.join(build_dir, "bootloader"))
    File.mkdir_p!(Path.join(build_dir, "partition_table"))
    File.mkdir_p!(Path.join(build_dir, "lib"))
    File.mkdir_p!(platform_dir)
    File.mkdir_p!(images_dir)

    write_part(build_dir, "bootloader/bootloader.bin", @bootloader)
    write_part(build_dir, "partition_table/partition-table.bin", @table)
    write_part(build_dir, "atomvm-esp32.bin", @app)
    write_part(build_dir, "lib/elixir_esp32boot.avm", @lib)

    for file <- [
          "atomvm-esp32.elf",
          "atomvm-esp32.map",
          "bootloader/bootloader.elf",
          "bootloader/bootloader.map",
          "prefix_map_gdbinit"
        ] do
      File.write!(Path.join(build_dir, file), "debug #{file}")
    end

    File.write!(Path.join(build_dir, "flasher_args.json"), flasher_args())

    File.write!(
      Path.join(platform_dir, "sdkconfig"),
      """
      #
      # Espressif IoT Development Framework (ESP-IDF) 5.5.5 Project Configuration
      #
      CONFIG_APP_PROJECT_VER="test"
      CONFIG_PARTITION_TABLE_CUSTOM_FILENAME="partitions-elixir.csv"
      CONFIG_ESPTOOLPY_FLASHSIZE="16MB"
      """
    )

    image = Path.join(images_dir, "atomvm-esp32s3-full-elixir.img")
    File.write!(image, build_image())

    {:ok, build_dir: build_dir, platform_dir: platform_dir, image: image}
  end

  test "writes a bundle the installer reads", ctx do
    assert {:ok, zip} = write(ctx)

    assert Path.basename(zip) == "atomvm-esp32s3-full-elixir.zip"
    assert Path.dirname(zip) == Path.dirname(ctx.image)

    {:ok, names} = Esp32FirmwareImages.bundle_members(File.read!(zip))
    assert "atomvm-esp32s3-full-elixir.img" in names
    assert "atomvm-esp32s3-full-elixir.img.sha256" in names
    assert "sdkconfig" in names
    assert "partitions.csv" in names
    assert "FLASH.txt" in names
    assert "bootloader.bin" in names
    assert "partition-table.bin" in names
    assert "atomvm-esp32.bin" in names
    assert "elixir_esp32boot.avm" in names
    assert "atomvm-esp32.elf" in names
    assert "atomvm-esp32.map" in names
    assert "SHA256SUMS" in names

    assert {:ok, bundle} =
             Esp32FirmwareImages.verify_bundle(File.read!(zip), Path.basename(zip), nil)

    assert bundle.stem == "atomvm-esp32s3-full-elixir"
    assert bundle.flash.chip == "esp32s3"
    assert bundle.flash.flash_offset == 0
    assert bundle.image == File.read!(ctx.image)
    assert bundle.parts["atomvm-esp32.bin"] == @app
    assert bundle.parts["elixir_esp32boot.avm"] == @lib
    assert bundle.partitions_csv == @partitions
  end

  test "the FLASH.txt describes the image and its parts", ctx do
    assert {:ok, zip} = write(ctx)

    {:ok, %{"FLASH.txt" => flash}} =
      Esp32FirmwareImages.bundle_extract(File.read!(zip), ["FLASH.txt"])

    assert flash =~ "AtomVM firmware image: atomvm-esp32s3-full-elixir.img\n"
    assert flash =~ "Chip: esp32s3\n"
    assert flash =~ "AtomVM build: test\n"
    assert flash =~ "ESP-IDF: 5.5.5\n"
    assert flash =~ "Flash offset: 0x0\n"
    assert flash =~ "Application partition (main.avm): 0x250000\n"
    assert flash =~ "laid out for a 16 MB flash"
    assert flash =~ "  0x10000 atomvm-esp32.bin\n"
    assert flash =~ "mix atomvm.esp32.install --image atomvm-esp32s3-full-elixir.zip"
  end

  test "reads the partition table named in the sdkconfig", ctx do
    File.write!(Path.join(ctx.platform_dir, "partitions-elixir.csv"), @partitions)

    assert {:ok, zip} = write(Map.delete(ctx, :partitions))

    assert {:ok, bundle} =
             Esp32FirmwareImages.verify_bundle(File.read!(zip), Path.basename(zip), nil)

    assert bundle.partitions_csv == @partitions
  end

  test "refuses a part that differs from the image", ctx do
    File.write!(Path.join(ctx.build_dir, "atomvm-esp32.bin"), "other bytes")

    assert {:error, message} = write(ctx)
    assert message =~ "atomvm-esp32.bin differs from the image at 0x10000"
  end

  test "reports missing build outputs", ctx do
    File.rm!(Path.join(ctx.build_dir, "atomvm-esp32.elf"))

    assert {:error, message} = write(ctx)
    assert message =~ "cannot read"
    assert message =~ "atomvm-esp32.elf"
  end

  test "reports a build directory without flasher_args.json", %{tmp_dir: tmp_dir} do
    assert {:error, message} =
             Esp32FirmwareBundle.write(%{
               stem: "atomvm-esp32s3-full-elixir",
               image: Path.join(tmp_dir, "missing.img"),
               build_dir: tmp_dir,
               platform_dir: tmp_dir,
               chip: "esp32s3"
             })

    assert message =~ "cannot read"
    assert message =~ "flasher_args.json"
  end

  defp write(ctx) do
    Esp32FirmwareBundle.write(%{
      stem: "atomvm-esp32s3-full-elixir",
      image: ctx.image,
      build_dir: ctx.build_dir,
      platform_dir: ctx.platform_dir,
      chip: "esp32s3",
      partitions: Map.get(ctx, :partitions, @partitions)
    })
  end

  defp write_part(build_dir, relative, data) do
    File.write!(Path.join(build_dir, relative), data)
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
