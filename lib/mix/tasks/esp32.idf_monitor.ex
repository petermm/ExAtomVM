defmodule Mix.Tasks.Atomvm.Esp32.IdfMonitor do
  @moduledoc """
  Shows the console output of an ESP32 board with the ESP-IDF monitor.

  The [ESP-IDF monitor](https://github.com/espressif/esp-idf-monitor) is
  installed in the Pythonx environment, so no serial console program is
  needed. It is the monitor ESP-IDF users know, and it decodes the addresses
  of an ELF file, adds timestamps, and filters output when asked to.

  The optional `pythonx` dependency is needed:

      {:pythonx, "~> 0.4.0", runtime: false}

  The board is reset so that its output is shown from the boot messages on;
  `--no-reset` leaves it running instead. The monitor is quit with Ctrl+C,
  the key of `atomvm.esp32.monitor`; `--exit-key` chooses another key, such
  as `]` for the ESP-IDF monitor's own Ctrl+]. `--timeout` stops it after a
  number of seconds instead.

  Arguments after `--` are passed to the ESP-IDF monitor, such as an ELF
  file to decode addresses with.

  ## Options

    * `--port` - Serial port to use. Defaults to the configured AtomVM port,
      or automatic device selection when no port is configured.
    * `--baud` - Baud rate of the console, 115200 by default. The `baud` key
      of `mix.exs` is the flashing speed and does not apply.
    * `--no-reset` - Do not reset the board, show its output from now on.
    * `--exit-key` - Key that quits the monitor, C (Ctrl+C) by default. A
      single letter, or one of `[`, `]`, `^`, `_` or the backslash.
    * `--timeout` - Stop after this many seconds, for scripts.

  ## Examples

      mix atomvm.esp32.idf_monitor
      mix atomvm.esp32.idf_monitor --no-reset --port /dev/ttyACM0
      mix atomvm.esp32.idf_monitor --exit-key Q
      mix atomvm.esp32.idf_monitor --timeout 10
      mix atomvm.esp32.idf_monitor -- --timestamps build/atomvm.elf
  """

  use Mix.Task

  alias ExAtomVM.EsptoolHelper

  @shortdoc "Show the console output of an ESP32 board with the ESP-IDF monitor"

  @usage "mix atomvm.esp32.idf_monitor [--port PORT] [--baud RATE] [--no-reset] [--exit-key KEY] [--timeout SECONDS] [-- ESP-IDF-MONITOR-OPTIONS]"

  @exit_key_error "--exit-key must be a single letter, or one of [ ] \\ ^ _"

  @impl Mix.Task
  def run(args) do
    {opts, extra_args, invalid} =
      OptionParser.parse(args,
        strict: [
          port: :string,
          baud: :integer,
          no_reset: :boolean,
          exit_key: :string,
          timeout: :integer
        ]
      )

    if invalid != [] do
      Mix.raise("Usage: #{@usage}")
    end

    baud = Keyword.get(opts, :baud, 115_200)
    exit_key = Keyword.get(opts, :exit_key, "C")
    timeout = Keyword.get(opts, :timeout)

    if baud < 1, do: Mix.raise("--baud must be greater than zero")

    if not valid_exit_key?(exit_key), do: Mix.raise(@exit_key_error)

    if timeout != nil and timeout < 1 do
      Mix.raise("--timeout must be a number of seconds greater than zero")
    end

    with :ok <- EsptoolHelper.setup_idf_monitor(),
         port <- resolve_port(Keyword.get(opts, :port, configured_port())),
         :ok <-
           EsptoolHelper.idf_monitor(port, baud,
             reset: not Keyword.get(opts, :no_reset, false),
             exit_key: exit_key,
             timeout: timeout,
             args: extra_args
           ) do
      if timeout != nil, do: IO.puts(stopped_line(timeout))
    else
      {:error, :pythonx_not_available, message} ->
        Mix.raise(message)

      {:error, {_reason, message}} ->
        Mix.raise(message)
    end
  end

  @doc false
  def stopped_line(1), do: "Stopped after 1 second."
  def stopped_line(seconds), do: "Stopped after #{seconds} seconds."

  defp valid_exit_key?(key) do
    String.length(key) == 1 and (key =~ ~r/^[A-Za-z]$/ or key in ["[", "]", "\\", "^", "_"])
  end

  defp configured_port do
    Mix.Project.config()
    |> Keyword.get(:atomvm, [])
    |> Keyword.get(:port, "auto")
  end

  defp resolve_port("auto") do
    EsptoolHelper.select_device()
    |> Map.fetch!("port")
  end

  defp resolve_port(port), do: port
end
