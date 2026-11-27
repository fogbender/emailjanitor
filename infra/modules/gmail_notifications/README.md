# Google notification identity

This shared module provisions private Gmail/Pub/Sub notification resources and
one service account restricted to the source pull subscription. It stores no
Google service-account key or Gmail grant. OAuth client creation and mailbox
consent remain separate setup steps.

The self-host reference continues to pass only `aws_account_id` and
`aws_runtime_role_name`. Its pool/provider IDs, exact role condition and IMDSv2
credential source remain unchanged; explicit `moved` blocks preserve existing
resource addresses after the neutral `host` rename.

The private Azure SaaS composition instead supplies `azure_identity`, containing
the dedicated managed identity's tenant/object/client GUIDs and its dedicated
`api://application-client-id` audience. AWS identity inputs must then remain null.
The OIDC provider pins the tenant's v1 issuer, audience and exact managed identity
object. Only that object's mapped principal can impersonate the subscription's
consumer service account. It gains no project-wide subscription permissions.

The Azure host must separately provision that audience's Azure application and
service principal, and the intended user-assigned managed identity. Merely
installing an Azure-capable SDK helper does not create those trust resources.
No application password or personal Azure/Google credential belongs here.

`external_account_configuration` returns non-secret metadata accepted by the
pinned official Google auth SDK bridge. The Azure source requests only the
configured managed identity and application audience from IMDS; the AWS source
uses IMDSv2. STS audience and service-account impersonation target are fixed to
the resources created here. A root-owned helper should refresh the short-lived
runtime token file; the application should not access IMDS or a developer profile
on the Azure reference host.

Native mocked plans validate topology and conditions without credentials. Before
enabling processing, verify an actual managed-identity token's issuer/audience,
Google STS exchange, service-account impersonation and empty-subscription pull.
That external round trip, IAM propagation and Gmail consent are not proven by
`tofu apply`, a module output, or the mocked tests.
