# Email reply metadata

`Mail.Message.new/2` keeps its existing bounded plain-message contract.
`new/3` creates a reply using metadata from an authenticated source message:

```elixir
Message.new("Re: Daily activity", Content.new("I returned that email to your inbox."),
  in_reply_to: "source-id@example.org"
)
```

The canonical bare parent ID is required. `references` defaults to that single
parent; an explicit chain must be unique, end in that parent, contain at most
20 canonical IDs and fit a 900-byte header budget. Using only the immediate
parent avoids accumulating long headers. IDs are references, never proof that
an incoming command is authenticated.

Reply subjects can be empty and accept up to 980 UTF-8 bytes; reply text accepts
up to 64,000 bytes. Both are transient `Content`. Controls in subjects, malformed
references, extra options and invalid destination structs fail before the HTTP
request. A host can use a fixed Janitor subject for an unsupported original
subject while retaining the exact parent reference.

The maintained `gen_smtp` MIME encoder handles Unicode headers and body transfer
encoding. The maintained ExAws SES SDK performs `SendRawEmail`, signing, query
encoding and response parsing. The sender stays in trusted transport config and
the sole recipient stays in the host-supplied inbox. Constructors expose neither
destination nor arbitrary header options. Replies carry `In-Reply-To`,
`References`, `Auto-Submitted: auto-replied` and `X-Auto-Response-Suppress: All`.
Rendering and SDK failures produce fixed errors; the existing privacy observers
and one-attempt transport policy remain in force. Raw MIME is never persisted.

Reply IDs use random UUIDs on the configured sender domain, and Date uses UTC,
so rendering never performs hostname discovery. The adapter normalizes text line
endings to CRLF and corrects gen_smtp 1.3.0's semicolon folding in Subject without
changing the body or other headers.

SES replaces the supplied Message-ID and Date, so delivery evidence continues
to use its returned provider ID. The existing IAM module permits both send
operations only for the configured Janitor identity and From address.
See [SES SendRawEmail requirements](https://docs.aws.amazon.com/ses/latest/APIReference/API_SendRawEmail.html).
