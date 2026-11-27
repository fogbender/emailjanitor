defmodule EmailJanitor.Digest.Clock do
  @moduledoc "Recompute local 21:00 boundaries from pinned IANA rules, rather than adding 24-hour offsets."
  @database Tzdata.TimeZoneDatabase

  def local(%DateTime{} = now, zone) when is_binary(zone),
    do: DateTime.shift_zone(now, zone, @database)

  def local(_, _), do: {:error, :invalid_timezone}

  def cutoff(%DateTime{} = now, zone) do
    with {:ok, local} <- local(now, zone) do
      date = DateTime.to_date(local)

      with {:ok, today} <- utc_boundary(date, zone) do
        if DateTime.compare(today, now) == :gt do
          prior = Date.add(date, -1)
          with {:ok, utc} <- utc_boundary(prior, zone), do: {:ok, prior, utc}
        else
          {:ok, date, today}
        end
      end
    end
  rescue
    _ -> {:error, :invalid_timezone}
  end

  defp utc_boundary(date, zone) do
    with {:ok, boundary} <- boundary(date, zone),
         {:ok, utc} <- DateTime.shift_zone(boundary, "Etc/UTC", @database) do
      {:ok, %{utc | microsecond: {elem(utc.microsecond, 0), 6}}}
    end
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
