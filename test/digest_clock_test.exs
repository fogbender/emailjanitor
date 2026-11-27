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

  test "a repeated local date chooses its already-passed first 21:00 boundary" do
    now = ~U[1969-10-01 00:00:00Z]
    assert {:ok, local} = Clock.local(now, "Pacific/Kwajalein")
    assert local.hour == 12
    assert {:ok, ~D[1969-09-30], cutoff} = Clock.cutoff(now, "Pacific/Kwajalein")
    assert DateTime.compare(cutoff, ~U[1969-09-30 10:00:00Z]) == :eq
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
               "PRIVATE/BODY",
               :done,
               "sender@example.com",
               "subject",
               ~U[2026-11-20 20:00:00Z]
             )
  end

  test "cleanup-compatible multi-address From and long or absent subjects still produce metadata" do
    id = Ecto.UUID.generate()
    at = ~U[2026-11-20 20:00:00Z]

    assert {:ok, event} =
             Event.new(
               id,
               "aa",
               :done,
               "First <first@example.com>, Second <second@example.net>",
               String.duplicate("€", 10_000),
               at
             )

    assert event.sender == "first@example.com"
    assert byte_size(event.subject) <= 256
    assert String.valid?(event.subject)

    assert {:ok, %{subject: "(no subject)"}} =
             Event.new(id, "aa", :done, "first@example.com", nil, at)

    assert {:ok, %{subject: "(unavailable subject)"}} =
             Event.new(id, "aa", :done, "first@example.com", :duplicate, at)
  end
end
