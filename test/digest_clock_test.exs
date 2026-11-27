defmodule EmailJanitor.DigestClockTest do
  use ExUnit.Case, async: true
  alias EmailJanitor.Digest.{Clock, Event}

  test "local 21:00 follows spring DST rather than adding 24 hours" do
    assert {:ok, ~D[2026-03-07], a} =
             Clock.cutoff(~U[2026-03-08 05:00:00Z], "America/Los_Angeles")

    assert DateTime.compare(a, ~U[2026-03-08 05:00:00Z]) == :eq

    assert {:ok, ~D[2026-03-08], b} =
             Clock.cutoff(~U[2026-03-09 04:00:00Z], "America/Los_Angeles")

    assert DateTime.diff(b, a) == 23 * 3600

    assert {:ok, ~D[2026-03-07], ^a} =
             Clock.cutoff(~U[2026-03-09 03:59:59.999999Z], "America/Los_Angeles")
  end

  test "fall DST produces one boundary after a 25-hour interval" do
    assert {:ok, ~D[2026-10-31], a} =
             Clock.cutoff(~U[2026-11-01 04:00:00Z], "America/Los_Angeles")

    assert {:ok, ~D[2026-11-01], b} =
             Clock.cutoff(~U[2026-11-02 05:00:00Z], "America/Los_Angeles")

    assert DateTime.diff(b, a) == 25 * 3600
  end

  test "invalid timezone fails closed without changing process-wide configuration" do
    previous = Calendar.get_time_zone_database()
    assert {:error, _} = Clock.cutoff(~U[2026-11-20 21:00:00Z], "Not/A_Zone")
    assert Calendar.get_time_zone_database() == previous
  end

  test "minimal headers are bounded UTF-8 and cannot inject lines" do
    {:ok, event} =
      Event.new(
        Ecto.UUID.generate(),
        "a1",
        :done,
        "Daniela <daniela@example.com>",
        "  subject\r\nPRIVATE-HEADER " <> String.duplicate("€", 100),
        ~U[2026-11-20 20:00:00Z]
      )

    assert event.sender == "daniela@example.com"
    assert String.valid?(event.subject)
    assert byte_size(event.subject) <= 256
    refute event.subject =~ "\n"

    assert {:error, :invalid_digest_event} =
             Event.new(
               "PRIVATE-BODY",
               "a1",
               :done,
               "sender@example.com",
               "subject",
               ~U[2026-11-20 20:00:00Z]
             )

    assert {:error, :invalid_digest_event} =
             Event.new(
               Ecto.UUID.generate(),
               "PRIVATE-BODY",
               :done,
               "sender@example.com",
               "subject",
               ~U[2026-11-20 20:00:00Z]
             )
  end
end
