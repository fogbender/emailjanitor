defmodule EmailJanitor.Mail.Feedback.Migration do
  use Ecto.Migration

  def change do
    create table(:mail_feedback, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:kind, :text, null: false)
      add(:source_ses_id, :text, null: false)
      add(:sender_address, :text, null: false)
      add(:sender_inbox_id, :text, null: false)
      add(:rfc_message_id, :text, null: false)
      add(:route_key, :text)
      add(:context_key, :text)
      add(:command_inbox_id, :text)
      add(:conversation_id, :uuid)
      add(:request_id, :uuid)
      add(:original_subject, :text)
      add(:received_at, :utc_datetime_usec, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:authenticated_at, :utc_datetime_usec)
      add(:state, :text, null: false, default: "pending")
      add(:outcome, :text)
      add(:attempts, :integer, null: false, default: 0)
      add(:claim_id, :uuid)
      add(:lease_until, :utc_datetime_usec)
      add(:next_attempt_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:mail_feedback, [:next_attempt_at, :id]))
    create(index(:mail_feedback, [:kind, :received_at]))
    create(constraint(:mail_feedback, :feedback_kind, check: "kind IN ('feedback','signup')"))

    create(
      constraint(:mail_feedback, :feedback_state,
        check:
          "state IN ('pending','processing','waiting_sent','workflow_retry','reply_pending','completed','unresolved','rejected','expired')"
      )
    )

    create(
      constraint(:mail_feedback, :feedback_bounded_metadata,
        check:
          "char_length(sender_address)<=254 AND char_length(sender_inbox_id)<=256 AND char_length(rfc_message_id)<=600 AND char_length(source_ses_id)<=256 AND (route_key IS NULL OR char_length(route_key)<=1024) AND (context_key IS NULL OR char_length(context_key)<=1024)"
      )
    )
  end
end

defmodule EmailJanitor.Mail.Feedback.Record do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}
  @derive {Inspect, only: [:id, :kind, :sender_inbox_id, :state, :outcome]}
  schema "mail_feedback" do
    field(:kind, Ecto.Enum, values: [:feedback, :signup])
    field(:source_ses_id, :string)
    field(:sender_address, :string)
    field(:sender_inbox_id, :string)
    field(:rfc_message_id, :string)
    field(:route_key, :string)
    field(:context_key, :string)
    field(:command_inbox_id, :string)
    field(:conversation_id, Ecto.UUID)
    field(:request_id, Ecto.UUID)
    field(:original_subject, :string)
    field(:received_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:authenticated_at, :utc_datetime_usec)

    field(:state, Ecto.Enum,
      values: [
        :pending,
        :processing,
        :waiting_sent,
        :workflow_retry,
        :reply_pending,
        :completed,
        :unresolved,
        :rejected,
        :expired
      ],
      default: :pending
    )

    field(:outcome, Ecto.Enum,
      values: [
        :processed,
        :clarify_unsupported,
        :clarify_ambiguous,
        :answer_unavailable,
        :expired,
        :rejected
      ]
    )

    field(:attempts, :integer, default: 0)
    field(:claim_id, Ecto.UUID)
    field(:lease_until, :utc_datetime_usec)
    field(:next_attempt_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
