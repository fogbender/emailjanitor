import {open, lstat, realpath, rename, unlink} from 'node:fs/promises';
import {constants} from 'node:fs';
import {dirname, isAbsolute, resolve, basename, join} from 'node:path';
import {randomUUID} from 'node:crypto';

const STS = 'https://sts.googleapis.com/v1/token';
const AWS_SOURCE = {
  environment_id: 'aws1',
  region_url: 'http://169.254.169.254/latest/meta-data/placement/availability-zone',
  url: 'http://169.254.169.254/latest/meta-data/iam/security-credentials',
  regional_cred_verification_url: 'https://sts.{region}.amazonaws.com?Action=GetCallerIdentity&Version=2011-06-15',
  imdsv2_session_token_url: 'http://169.254.169.254/latest/api/token',
};
const PUBSUB = 'https://www.googleapis.com/auth/pubsub';
const AWS_TYPE = 'urn:ietf:params:aws:token-type:aws4_request';
const JWT_TYPE = 'urn:ietf:params:oauth:token-type:jwt';
const allowed = (value, keys) => value && typeof value === 'object' && !Array.isArray(value) &&
  Object.keys(value).every(key => keys.includes(key));
const validToken = value => typeof value === 'string' && value.length >= 16 && value.length <= 16384 &&
  /^[A-Za-z0-9._~+/-]+=*$/.test(value);
const invalid = () => {throw new Error('invalid_configuration');};

export function validateConfiguration(config) {
  if (!allowed(config, ['type', 'audience', 'subject_token_type', 'token_url',
    'service_account_impersonation_url', 'service_account_impersonation',
    'credential_source', 'universe_domain', 'token_info_url']) ||
    config.type !== 'external_account' || config.token_url !== STS ||
    !/^\/\/iam\.googleapis\.com\/projects\/[0-9]{6,20}\/locations\/global\/workloadIdentityPools\/[a-z][a-z0-9-]{2,31}\/providers\/[a-z][a-z0-9-]{2,31}$/.test(config.audience) ||
    !/^https:\/\/iamcredentials\.googleapis\.com\/v1\/projects\/-\/serviceAccounts\/[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]{4,28}[a-z0-9]\.iam\.gserviceaccount\.com:generateAccessToken$/.test(config.service_account_impersonation_url) ||
    (config.universe_domain !== undefined && config.universe_domain !== 'googleapis.com') ||
    (config.token_info_url !== undefined && config.token_info_url !== 'https://sts.googleapis.com/v1/introspect') ||
    (config.service_account_impersonation !== undefined &&
      (!allowed(config.service_account_impersonation, ['token_lifetime_seconds']) ||
        config.service_account_impersonation.token_lifetime_seconds !== 3600))) invalid();

  const source = config.credential_source;
  if (config.subject_token_type === AWS_TYPE) {
    if (!allowed(source, Object.keys(AWS_SOURCE)) ||
      !Object.entries(AWS_SOURCE).every(([key, value]) => source[key] === value)) invalid();
    return 'aws';
  }

  if (config.subject_token_type !== JWT_TYPE || !allowed(source, ['url', 'headers', 'format']) ||
    !allowed(source.headers, ['Metadata']) || source.headers.Metadata !== 'True' ||
    !allowed(source.format, ['type', 'subject_token_field_name']) ||
    source.format.type !== 'json' || source.format.subject_token_field_name !== 'access_token') invalid();
  let url;
  try {url = new URL(source.url);} catch {invalid();}
  if (url.origin !== 'http://169.254.169.254' || url.username || url.password || url.hash ||
    url.pathname !== '/metadata/identity/oauth2/token' ||
    [...url.searchParams.keys()].sort().join(',') !== 'api-version,client_id,resource' ||
    url.searchParams.get('api-version') !== '2018-02-01' ||
    !/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(url.searchParams.get('client_id')) ||
    !/^[\x21-\x7e]{1,512}$/.test(url.searchParams.get('resource'))) invalid();
  return 'azure';
}

export function hardenEnvironment() {
  // This dedicated process never selects ambient user credentials or proxies.
  for (const key of Object.keys(process.env)) {
    if (/^(?:AWS_|GOOGLE_|GCLOUD_|DEBUG$|NODE_DEBUG$|NODE_OPTIONS$|HTTPS?_PROXY$|ALL_PROXY$|https?_proxy$|all_proxy$)/.test(key)) {
      delete process.env[key];
    }
  }
}

export async function fetchToken(config) {
  try {
    const kind = validateConfiguration(config);
    hardenEnvironment();
    const {AwsClient, IdentityPoolClient, gaxios} = await import('google-auth-library');
    const transporter = new gaxios.Gaxios({timeout: 10000, maxRedirects: 0, maxContentLength: 65536});
    transporter.interceptors.request.add({resolved: async options =>
      ({...options, retry: false, retryConfig: {retry: 0}})});
    const Client = kind === 'aws' ? AwsClient : IdentityPoolClient;
    const client = new Client({...config, transporter, scopes: [PUBSUB], useAuthRequestParameters: false});
    // The pinned SDK creates STS with a separate transport. Configure that SDK
    // object too; all signing, token exchange and impersonation stay in its SDK.
    client.stsCredential.transporter = transporter;
    const result = await client.getAccessToken();
    const expires_at = Math.floor(client.credentials.expiry_date / 1000);
    const now = Math.floor(Date.now() / 1000);
    if (!validToken(result.token) || !Number.isSafeInteger(expires_at) ||
      expires_at < now + 120 || expires_at > now + 3660) throw new Error();
    return {access_token: result.token, expires_at};
  } catch {
    throw new Error('federation_failed');
  }
}

async function trustedFile(path) {
  if (!isAbsolute(path) || await realpath(path) !== resolve(path)) invalid();
  const info = await lstat(path);
  if (!info.isFile() || info.uid !== process.geteuid() || (info.mode & 0o022) || info.size > 16384) invalid();
  return info;
}

export async function readConfiguration(path) {
  await trustedFile(path);
  const handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const config = JSON.parse(await handle.readFile('utf8'));
    validateConfiguration(config);
    return config;
  } finally {await handle.close();}
}

export async function writeToken(path, token) {
  const now = Math.floor(Date.now() / 1000);
  if (!isAbsolute(path) || !allowed(token, ['access_token', 'expires_at']) ||
    !validToken(token.access_token) || !Number.isSafeInteger(token.expires_at) ||
    token.expires_at < now + 120 || token.expires_at > now + 3660) invalid();
  const parent = dirname(path);
  const info = await lstat(parent);
  if (!info.isDirectory() || info.uid !== process.geteuid() || (info.mode & 0o022) ||
    await realpath(parent) !== resolve(parent)) invalid();
  const temporary = join(parent, `.${basename(path)}.${randomUUID()}.tmp`);
  let handle;
  try {
    handle = await open(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    await handle.chown(process.geteuid(), info.gid);
    await handle.chmod(0o640);
    await handle.writeFile(JSON.stringify(token) + '\n', 'utf8');
    await handle.sync();
    await handle.close();
    handle = undefined;
    await rename(temporary, path);
  } finally {
    if (handle) await handle.close();
    await unlink(temporary).catch(() => {});
  }
}
