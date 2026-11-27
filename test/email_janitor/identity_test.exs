defmodule EmailJanitor.IdentityTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import EmailJanitor.Fixtures
  alias EmailJanitor.{Address, Identity, Inbox, Safeguards}

  test "parent correspondence stops at the registrable domain, not co.uk" do
    assert Address.contact_keys("sales@mail.vendor.co.uk") == [
             "mail.vendor.co.uk",
             "vendor.co.uk"
           ]

    assert {:keep, :prior_correspondence} =
             Safeguards.evaluate(
               [message(from: "sales@mail.vendor.co.uk")],
               inbox(),
               MapSet.new(["vendor.co.uk"])
             )

    assert {:classify, _} =
             Safeguards.evaluate(
               [message(from: "sales@other.co.uk")],
               inbox(),
               MapSet.new(["vendor.co.uk"])
             )
  end

  test "having emailed one Gmail or QQ sender never protects the entire provider" do
    for provider <- ["gmail.com", "qq.com", "outlook.com", "proton.me"] do
      assert {:classify, _} =
               Safeguards.evaluate(
                 [message(from: "stranger@#{provider}")],
                 inbox(),
                 MapSet.new(["friend@#{provider}"])
               )

      assert {:keep, :prior_correspondence} =
               Safeguards.evaluate(
                 [message(from: "friend@#{provider}")],
                 inbox(),
                 MapSet.new(["friend@#{provider}"])
               )
    end
  end

  test "a personal Gmail inbox does not treat all Gmail senders as colleagues" do
    assert {:ok, ["stranger@gmail.com"]} =
             Identity.resolve(message(from: "stranger@gmail.com"), inbox("owner@gmail.com"))
  end

  test "an external Reply-To does not hide prior Gmail correspondence" do
    m = message(headers: [{"From", "known@gmail.com"}, {"Reply-To", "sales@vendor.com"}])

    assert {:keep, :prior_correspondence} =
             Safeguards.evaluate([m], inbox("owner@gmail.com"), MapSet.new(["known@gmail.com"]))
  end

  test "internal colleagues stay protected even with an external reply address" do
    for sender <- ["colleague@acme.com", "notify@app.acme.com"] do
      m = message(headers: [{"From", sender}, {"Reply-To", "sales@vendor.com"}])
      assert {:keep, :own_domain} = Identity.resolve(m, inbox())
    end
  end

  test "configured hello relay is checked against the external author, not our domain" do
    m =
      message(
        headers: [{"From", "Vendor via Hello <hello@acme.com>"}, {"Reply-To", "sales@vendor.com"}]
      )

    assert {:ok, ["vendor.com"]} =
             Identity.resolve(m, inbox("owner@acme.com", ["hello@acme.com"]))

    assert {:keep, :own_domain} = Identity.resolve(m, inbox())
  end

  test "relay original-author header works without Reply-To" do
    m = message(headers: [{"From", "hello@acme.com"}, {"X-Original-Sender", "sales@vendor.com"}])

    assert {:ok, ["vendor.com"]} =
             Identity.resolve(m, inbox("owner@acme.com", ["hello@acme.com"]))
  end

  test "known external author behind relay stays protected" do
    m = message(headers: [{"From", "hello@acme.com"}, {"Reply-To", "known@vendor.com"}])

    assert {:keep, :prior_correspondence} =
             Safeguards.evaluate(
               [m],
               inbox("owner@acme.com", ["hello@acme.com"]),
               MapSet.new(["vendor.com"])
             )
  end

  test "external senders cannot acquire own-domain protection through Reply-To or original headers" do
    m =
      message(
        headers: [
          {"From", "acme.com@evil.com"},
          {"Reply-To", "owner@acme.com"},
          {"X-Original-Sender", "owner@acme.com"}
        ]
      )

    assert {:ok, ["evil.com"]} = Identity.resolve(m, inbox())
  end

  test "relay lacking an external author is preserved" do
    assert {:keep, :own_domain} =
             Identity.resolve(
               message(from: "hello@acme.com"),
               inbox("owner@acme.com", ["hello@acme.com"])
             )
  end

  test "duplicate headers, malformed addresses and injection stay unclassified" do
    cases = [
      [{"From", "sales@vendor.com"}, {"From", "owner@acme.com"}],
      [{"From", "sales@vendor.com"}, {"Reply-To", "not an address"}],
      [{"From", "x@[127.0.0.1]"}],
      [{"From", "invalid"}],
      [{"From", "x@ven..dor.com"}],
      [{"From", "x@-vendor.com"}],
      [{"From", "x@vendor.com\r\nReply-To: owner@acme.com"}],
      [{"From", "x@" <> <<255>> <> ".com"}]
    ]

    for headers <- cases do
      assert {:keep, :unknown_sender} =
               Safeguards.evaluate([message(headers: headers)], inbox(), MapSet.new())
    end
  end

  test "only operator-specified relays inside the inbox domain are accepted" do
    assert {:error, :invalid_relay} = Inbox.new("one", "owner@acme.com", ["hello@evil.com"])
  end

  property "contact keys never include a public suffix or unrelated domain" do
    check all(label <- string(:alphanumeric, min_length: 1, max_length: 20)) do
      domain = String.downcase(label) <> ".vendor.co.uk"
      assert Address.contact_keys("sales@" <> domain) == [domain, "vendor.co.uk"]
    end
  end
end
