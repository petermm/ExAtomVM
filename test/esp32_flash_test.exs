defmodule Mix.Tasks.Atomvm.Esp32.FlashTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Atomvm.Esp32.Flash

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "exatomvm-esp32-flash-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir}
  end

  test "adds the previous image and optional trust flag to modern esptool arguments" do
    args =
      Flash.flash_tool_args("esp32", "auto", "115200", 0x250000, "/tmp/current.avm",
        previous_image: "/tmp/previous.avm",
        trust_flash_content: true,
        modern: true
      )

    assert "write-flash" in args
    assert "--flash-mode" in args
    refute "--port" in args

    assert Enum.slice(args, -3, 3) == [
             "--diff-with",
             "/tmp/previous.avm",
             "--trust-flash-content"
           ]
  end

  test "does not pass trust-flash-content without a previous image" do
    args =
      Flash.flash_tool_args("esp32", "/dev/ttyUSB0", "115200", 0x250000, "current.avm",
        trust_flash_content: true
      )

    assert Enum.take(args, 2) == ["--port", "/dev/ttyUSB0"]
    assert "write_flash" in args
    refute "--diff-with" in args
    refute "--trust-flash-content" in args
  end

  test "stores and replaces the successful-flash baseline", %{tmp_dir: tmp_dir} do
    image_path = Path.join(tmp_dir, "current.avm")
    cache_path = Path.join([tmp_dir, "nested", "previous.avm"])

    File.write!(image_path, "first")
    assert :ok = Flash.cache_flash_image(image_path, cache_path)
    assert File.read!(cache_path) == "first"

    File.write!(image_path, "second")
    assert :ok = Flash.cache_flash_image(image_path, cache_path)
    assert File.read!(cache_path) == "second"
  end

  test "scopes the cache to the application and flash offset", %{tmp_dir: tmp_dir} do
    assert Flash.flash_cache_path(:demo, 0x250000, tmp_dir) ==
             Path.join([tmp_dir, "atomvm", "esp32", "flash", "demo-0x250000.avm"])
  end
end
