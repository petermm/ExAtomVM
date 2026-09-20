defmodule ExAtomVM.Esp32BuildOutput do
  @moduledoc false

  # Streams a build step's output to the console while keeping its last lines, so
  # a failing build can report what went wrong next to the build in the summary,
  # instead of leaving it thousands of lines up the scrollback.
  #
  #   {_output, status} =
  #     System.cmd(idf_path, args, into: ExAtomVM.Esp32BuildOutput.collectable())
  #
  #   ExAtomVM.Esp32BuildOutput.tail()

  # System.cmd hands the collectable raw chunks of the command's output, so keep
  # text and split it into lines when the tail is read.
  @bytes 4000
  @lines 10
  @key {__MODULE__, :tail}

  defstruct []

  @doc """
  The Collectable to pass to `System.cmd/3` as `:into`. Starts a fresh tail.
  """
  def collectable do
    clear()
    %__MODULE__{}
  end

  @doc """
  Forgets what was collected so far, for a step whose failure should not report
  the previous step's output.
  """
  def clear do
    Process.put(@key, "")
    :ok
  end

  @doc """
  The last lines written through the collectable, oldest first, without the
  trailing blank lines commands seem to end with.
  """
  def tail do
    @key
    |> Process.get("")
    |> String.split("\n")
    |> drop_trailing_blank()
    |> Enum.take(-@lines)
  end

  @doc false
  def keep(text) do
    if String.length(text) > @bytes do
      String.slice(text, String.length(text) - @bytes, @bytes)
    else
      text
    end
  end

  defp drop_trailing_blank(lines) do
    lines
    |> Enum.reverse()
    |> Enum.drop_while(&(String.trim(&1) == ""))
    |> Enum.reverse()
  end

  @doc false
  def bytes, do: @bytes

  @doc false
  def lines, do: @lines

  @doc false
  def key, do: @key

  defimpl Collectable do
    def into(%{}) do
      key = ExAtomVM.Esp32BuildOutput.key()

      collector = fn
        acc, {:cont, chunk} ->
          IO.write(chunk)
          Process.put(key, ExAtomVM.Esp32BuildOutput.keep(Process.get(key, "") <> chunk))
          acc

        acc, :done ->
          acc

        _acc, :halt ->
          :ok
      end

      {%{}, collector}
    end
  end
end
