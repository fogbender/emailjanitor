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

  test "message inspection hides header values as well as body text" do
    value =
      message(
        headers: [{"From", "PRIVATE_HEADER_SENTINEL"}, {"Subject", "PRIVATE_SUBJECT_SENTINEL"}],
        body: "PRIVATE_BODY_SENTINEL"
      )

    for marker <- ["PRIVATE_HEADER_SENTINEL", "PRIVATE_SUBJECT_SENTINEL", "PRIVATE_BODY_SENTINEL"] do
      refute inspect(value) =~ marker
    end
  end

  test "contradictory high-confidence Done classifications are rejected" do
    for category <- ["legitimate", "uncertain"] do
      assert {:error, :invalid_decision} =
               Decision.parse(%{
                 "action" => "done",
                 "confidence" => "high",
                 "category" => category
               })
    end
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

  test "hidden body blocks are excluded before truncation, including nested links" do
    for attrs <- [
          "hidden",
          "hidden='false'",
          "style='display:none'",
          "style='DISPLAY : NONE !important; color:red'",
          "style='color:red; visibility: hidden'"
        ] do
      source =
        "<div #{attrs}><a href='https://hidden.example.com'>" <>
          String.duplicate("HIDDEN_SENTINEL", 5000) <>
          "</a></div><p>Visible development pitch</p>"

      assert {:ok, result} = HTML.readable(Content.new(source), 100)
      assert Content.read(result) =~ "Visible development pitch"
      refute Content.read(result) =~ "HIDDEN_SENTINEL"
      refute Content.read(result) =~ "hidden.example.com"
    end
  end

  test "accessibility hints and explicitly visible hidden elements keep their text" do
    for attrs <- [
          "aria-hidden='true'",
          "hidden style='display:block'",
          "hidden style='display:inline !important'",
          "style='display:none;display:block'",
          "style='display:block!important;display:none'"
        ] do
      assert {:ok, result} = HTML.readable(Content.new("<p #{attrs}>Visible pitch</p>"))
      assert Content.read(result) == "Visible pitch"
    end
  end

  test "comments and common hidden preheaders are removed before the text budget" do
    for style <- [
          "/*comment*/display:none",
          "display:/*comment*/none",
          "opacity:0",
          "mso-hide:all",
          "max-height:0px;overflow:hidden",
          "display:none!important;display:block"
        ] do
      source =
        "<div style='#{style}'>" <>
          String.duplicate("HIDDEN_SENTINEL", 5000) <> "</div><p>Visible pitch</p>"

      assert {:ok, result} = HTML.readable(Content.new(source), 100)
      assert Content.read(result) == "Visible pitch"
    end
  end

  test "template contents do not crowd out the visible message" do
    source =
      "<template>" <>
        String.duplicate("HIDDEN_SENTINEL", 5000) <> "</template><p>Visible pitch</p>"

    assert {:ok, result} = HTML.readable(Content.new(source), 100)
    assert Content.read(result) == "Visible pitch"
  end
end
