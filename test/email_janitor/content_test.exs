defmodule EmailJanitor.ContentTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import ExUnit.CaptureLog
  import EmailJanitor.Fixtures
  alias EmailJanitor.{Classifier, Content, Decision, HTML, TestClassifier}

  test "normal inspection and JSON never expose content" do
    body = Content.new("PRIVATE_BODY_SENTINEL")
    assert Content.read(body) == "PRIVATE_BODY_SENTINEL"
    refute inspect(%{email: [body]}) =~ "PRIVATE_BODY_SENTINEL"
    refute Jason.encode!(%{email: body}) =~ "PRIVATE_BODY_SENTINEL"
  end

  test "provider failures, exceptions and throws expose only fixed error categories" do
    logs =
      capture_log(fn ->
        for mode <- [:raise, :raw_error, :throw] do
          assert {:error, :model_unavailable} =
                   Classifier.propose(
                     {TestClassifier, [mode: mode]},
                     [message(body: "PRIVATE_BODY_SENTINEL")],
                     ""
                   )
        end
      end)

    refute logs =~ "PRIVATE_BODY_SENTINEL"
  end

  test "invalid and extra model output cannot smuggle body text into durable output" do
    for value <- [
          "PRIVATE_BODY_SENTINEL",
          "{\"broken\":PRIVATE_BODY_SENTINEL}",
          %{
            "action" => "done",
            "confidence" => "high",
            "category" => "cold_outreach",
            "reason" => "PRIVATE_BODY_SENTINEL"
          },
          %{"action" => "done", "confidence" => "high", "category" => "PRIVATE_BODY_SENTINEL"}
        ] do
      assert {:error, :invalid_decision} = Decision.parse(value)
    end
  end

  test "HTML markup cannot crowd out a notification's embedded pitch" do
    source =
      "<html><head><style>" <>
        String.duplicate("decoration{}", 5000) <>
        "</style></head><body><script>PRIVATE_SCRIPT</script><p>Your clip: development services</p>" <>
        "<a href='https://vendor.com/book'>Book a sales call</a></body></html>"

    assert {:ok, result} = HTML.readable(Content.new(source), 500)
    assert Content.read(result) =~ "development services"
    assert Content.read(result) =~ "https://vendor.com/book"
    refute Content.read(result) =~ "PRIVATE_SCRIPT"
    refute Content.read(result) =~ "decoration"
  end

  property "arbitrary model bytes never escape as an exception or raw error" do
    check all(bytes <- binary(max_length: 4096)) do
      result = Decision.parse(bytes)
      assert match?({:ok, %Decision{}}, result) or result == {:error, :invalid_decision}
    end
  end
end
