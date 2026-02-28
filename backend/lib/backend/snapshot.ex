defmodule Backend.Snapshot do
  @spec encode(binary()) :: String.t()
  def encode(grid) when is_binary(grid) do
    grid
    |> :zlib.gzip()
    |> Base.encode64()
  end

  @spec decode(String.t()) :: binary()
  def decode(bytes_b64) when is_binary(bytes_b64) do
    bytes_b64
    |> Base.decode64!()
    |> :zlib.gunzip()
  end
end
