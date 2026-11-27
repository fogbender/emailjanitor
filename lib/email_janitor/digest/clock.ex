defmodule EmailJanitor.Digest.Clock do
  @moduledoc "Recompute local 21:00 boundaries from pinned IANA rules, rather than adding 24-hour offsets."
  @database Tzdata.TimeZoneDatabase

  def local(%DateTime{} = now, zone) when is_binary(zone),
    do: DateTime.shift_zone(now, zone, @database)

  def local(_, _), do: {:error, :invalid_timezone}

  def cutoff(%DateTime{} = now, zone) do
    with {:ok, local} <- local(now, zone) do
      date = DateTime.to_date(local)

      date =
        if Time.compare(DateTime.to_time(local), ~T[21:00:00]) == :lt,
          do: Date.add(date, -1),
          else: date

      with {:ok, boundary} <- boundary(date, zone),
           {:ok, utc} <- DateTime.shift_zone(boundary, "Etc/UTC", @database) do
        {:ok, date, %{utc | microsecond: {elem(utc.microsecond, 0), 6}}}
      end
    end
  rescue
    _ -> {:error, :invalid_timezone}
  end

  defp boundary(date, zone) do
    case DateTime.new(date, ~T[21:00:00], zone, @database) do
      {:ok, boundary} -> {:ok, boundary}
      {:ambiguous, first, _} -> {:ok, first}
      {:gap, _, after_gap} -> {:ok, after_gap}
      _ -> {:error, :invalid_timezone}
    end
  end
end
