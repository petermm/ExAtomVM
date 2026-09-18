defmodule Mix.Tasks.Atomvm.Esp32.IdfMonitorTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Atomvm.Esp32.IdfMonitor

  @usage "Usage: mix atomvm.esp32.idf_monitor [--port PORT] [--baud RATE] [--no-reset] [--exit-key KEY] [--timeout SECONDS] [-- ESP-IDF-MONITOR-OPTIONS]"

  test "rejects unknown options and values that are not numbers" do
    for args <- [
          ["--chip", "esp32s3"],
          ["--baud", "fast"],
          ["--timeout", "soon"]
        ] do
      assert_raise Mix.Error, @usage, fn -> IdfMonitor.run(args) end
    end
  end

  test "rejects a baud rate that is not greater than zero" do
    for baud <- ["0", "-115200"] do
      assert_raise Mix.Error, "--baud must be greater than zero", fn ->
        IdfMonitor.run(["--baud", baud])
      end
    end
  end

  test "rejects a timeout that is not greater than zero" do
    for timeout <- ["0", "-1"] do
      assert_raise Mix.Error, "--timeout must be a number of seconds greater than zero", fn ->
        IdfMonitor.run(["--timeout", timeout])
      end
    end
  end

  test "rejects an exit key the ESP-IDF monitor cannot use" do
    for key <- ["", "CC", "1", "-", "]x"] do
      assert_raise Mix.Error, "--exit-key must be a single letter, or one of [ ] \\ ^ _", fn ->
        IdfMonitor.run(["--exit-key", key])
      end
    end
  end

  test "says how long it ran" do
    assert IdfMonitor.stopped_line(1) == "Stopped after 1 second."
    assert IdfMonitor.stopped_line(10) == "Stopped after 10 seconds."
  end
end
