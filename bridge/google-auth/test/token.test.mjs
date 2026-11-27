import test, {afterEach, beforeEach} from 'node:test';
import assert from 'node:assert/strict';
import nock from 'nock';
import {mkdtemp, readFile, writeFile, chmod, lstat, readdir, rm, symlink} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {Readable} from 'node:stream';
import {validateConfiguration, fetchToken, writeToken, readConfiguration, verifyAwsSubject} from '../token.mjs';

const AUDIENCE = '//iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/janitor-aws/providers/aws-ec2';
const IAM_PATH = '/v1/projects/-/serviceAccounts/janitor-google@janitor-project.iam.gserviceaccount.com:generateAccessToken';
const FINAL_TOKEN = 'GOOGLE_ACCESS_TOKEN_SENTINEL';
function config(kind = 'aws') {
  const source = kind === 'aws' ? {
    environment_id: 'aws1',
    region_url: 'http://169.254.169.254/latest/meta-data/placement/availability-zone',
    url: 'http://169.254.169.254/latest/meta-data/iam/security-credentials',
    regional_cred_verification_url: 'https://sts.{region}.amazonaws.com?Action=GetCallerIdentity&Version=2011-06-15',
    imdsv2_session_token_url: 'http://169.254.169.254/latest/api/token',
  } : {
    url: 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&client_id=11111111-2222-3333-4444-555555555555&resource=api%3A%2F%2Fjanitor-wif',
    headers: {Metadata: 'True'},
    format: {type: 'json', subject_token_field_name: 'access_token'},
  };
  return {type: 'external_account', audience: AUDIENCE,
    subject_token_type: kind === 'aws' ? 'urn:ietf:params:aws:token-type:aws4_request' : 'urn:ietf:params:oauth:token-type:jwt',
    token_url: 'https://sts.googleapis.com/v1/token',
    service_account_impersonation_url: `https://iamcredentials.googleapis.com${IAM_PATH}`,
    credential_source: source};
}
function mockIam(status = 200, body) {
  return nock('https://iamcredentials.googleapis.com', {reqheaders: {authorization: 'Bearer FEDERATED_TOKEN_SENTINEL'}})
    .post(IAM_PATH, data => {
      assert.deepEqual(data.scope, ['https://www.googleapis.com/auth/pubsub']);
      assert.equal(data.lifetime, '3600s');
      return true;
    }).reply(status, body ?? {accessToken: FINAL_TOKEN, expireTime: new Date(Date.now() + 3600000).toISOString()});
}
function mockSts(validateSubject, status = 200) {
  return nock('https://sts.googleapis.com').post('/v1/token', data => {
    const form = new URLSearchParams(data);
    assert.equal(form.get('audience'), AUDIENCE);
    validateSubject(form.get('subject_token'));
    return true;
  }).reply(status, status === 200 ? {access_token: 'FEDERATED_TOKEN_SENTINEL', expires_in: 3600, token_type: 'Bearer'} : {error: 'PRIVATE_PROVIDER_ERROR_SENTINEL'});
}
function mockAzure() {
  return nock('http://169.254.169.254', {reqheaders: {Metadata: 'True'}})
    .get('/metadata/identity/oauth2/token').query({
      'api-version': '2018-02-01', client_id: '11111111-2222-3333-4444-555555555555', resource: 'api://janitor-wif',
    }).reply(200, {access_token: 'AZURE_SUBJECT_TOKEN_SENTINEL'});
}
let directory;
beforeEach(async () => {nock.disableNetConnect(); directory = await mkdtemp(join(tmpdir(), 'ej-google-auth-'));});
afterEach(async () => {nock.cleanAll(); nock.enableNetConnect(); await rm(directory, {recursive: true, force: true});});

test('official SDK signs AWS IMDSv2 credentials, exchanges and impersonates for Pub/Sub only', async () => {
  // Ambient credentials must not supersede the operator-selected instance role.
  process.env.AWS_ACCESS_KEY_ID = 'WRONG_AMBIENT_KEY';
  process.env.AWS_SECRET_ACCESS_KEY = 'WRONG_AMBIENT_SECRET';
  process.env.AWS_REGION = 'wrong-region';
  const metadata = nock('http://169.254.169.254')
    .put('/latest/api/token').twice().reply(200, 'IMDS_TOKEN_SENTINEL')
    .get('/latest/meta-data/placement/availability-zone').matchHeader('x-aws-ec2-metadata-token', 'IMDS_TOKEN_SENTINEL').reply(200, 'us-east-1a')
    .get('/latest/meta-data/iam/security-credentials').matchHeader('x-aws-ec2-metadata-token', 'IMDS_TOKEN_SENTINEL').reply(200, 'JanitorRole')
    .get('/latest/meta-data/iam/security-credentials/JanitorRole').reply(200, {
      AccessKeyId: 'FAKEACCESSKEY', SecretAccessKey: 'AWS_SECRET_SENTINEL', Token: 'AWS_SESSION_SENTINEL',
    });
  let actualSubject;
  const sts = mockSts(subject => {
    actualSubject = subject;
    const request = JSON.parse(decodeURIComponent(subject));
    assert.equal(request.url, 'https://sts.us-east-1.amazonaws.com?Action=GetCallerIdentity&Version=2011-06-15');
    assert.equal(request.method, 'POST');
    const headers = Object.fromEntries(request.headers.map(({key, value}) => [key.toLowerCase(), value]));
    assert.equal(headers['x-goog-cloud-target-resource'], AUDIENCE);
    assert.match(headers.authorization, /^AWS4-HMAC-SHA256 Credential=FAKEACCESSKEY\//);
    assert.match(headers.authorization, /Signature=[a-f0-9]{64}$/);
    const signed = headers.authorization.match(/SignedHeaders=([^, ]+)/)[1].split(';');
    for (const name of ['host', 'x-amz-date', 'x-amz-security-token', 'x-goog-cloud-target-resource']) {
      assert.ok(signed.includes(name), `${name} must be cryptographically bound by the SDK`);
    }
    assert.equal(headers['x-amz-security-token'], 'AWS_SESSION_SENTINEL');
  });
  const iam = mockIam();
  assert.equal(validateConfiguration(config()), 'aws');
  const token = await fetchToken(config());
  assert.equal(token.access_token, FINAL_TOKEN);
  assert.ok(token.expires_at >= Math.floor(Date.now() / 1000) + 3500);
  assert.ok(metadata.isDone() && sts.isDone() && iam.isDone());
  assert.doesNotThrow(() => verifyAwsSubject(actualSubject, AUDIENCE));
  const altered = JSON.parse(decodeURIComponent(actualSubject));
  altered.headers.find(h => h.key === 'x-goog-cloud-target-resource').value = AUDIENCE + '-other';
  assert.throws(() => verifyAwsSubject(encodeURIComponent(JSON.stringify(altered)), AUDIENCE));
  const unexpected = JSON.parse(decodeURIComponent(actualSubject));
  unexpected.headers.find(h => h.key === 'authorization').value =
    unexpected.headers.find(h => h.key === 'authorization').value.replace('SignedHeaders=host;', 'SignedHeaders=evil;host;');
  assert.throws(() => verifyAwsSubject(encodeURIComponent(JSON.stringify(unexpected)), AUDIENCE));
  const extra = JSON.parse(decodeURIComponent(actualSubject));
  extra.headers.push({key: 'evil', value: 'unexpected'});
  assert.throws(() => verifyAwsSubject(encodeURIComponent(JSON.stringify(extra)), AUDIENCE));
  const endpoint = JSON.parse(decodeURIComponent(actualSubject));
  endpoint.url = endpoint.url.replace('sts.us-east-1.amazonaws.com', 'sts.attacker.example');
  endpoint.headers.find(h => h.key === 'host').value = 'sts.attacker.example';
  assert.throws(() => verifyAwsSubject(encodeURIComponent(JSON.stringify(endpoint)), AUDIENCE));
  const mismatched = JSON.parse(decodeURIComponent(actualSubject));
  mismatched.headers.find(h => h.key === 'host').value = 'sts.us-west-2.amazonaws.com';
  assert.throws(() => verifyAwsSubject(encodeURIComponent(JSON.stringify(mismatched)), AUDIENCE));
});

test('official SDK exchanges explicitly selected Azure managed identity with no project discovery', async () => {
  const metadata = mockAzure();
  const sts = mockSts(subject => assert.equal(subject, 'AZURE_SUBJECT_TOKEN_SENTINEL'));
  const iam = mockIam();
  assert.equal(validateConfiguration(config('azure')), 'azure');
  assert.equal((await fetchToken(config('azure'))).access_token, FINAL_TOKEN);
  assert.ok(metadata.isDone() && sts.isDone() && iam.isDone());
});

test('reject untrusted credential types, endpoints, sources and options before any network', async () => {
  const changes = [
    c => c.token_url = 'https://attacker.example/token',
    c => c.token_info_url = 'https://attacker.example/introspect',
    c => c.service_account_impersonation_url += '?exfiltrate=true',
    c => c.audience = '//iam.googleapis.com/locations/global/workforcePools/other/providers/other',
    c => c.type = 'service_account',
    c => c.credential_source.url = 'http://attacker.example/creds',
    c => c.credential_source.imdsv2_session_token_url = undefined,
    c => c.credential_source.executable = {command: 'evil'},
    c => c.transporterOptions = {proxy: 'https://attacker.example'},
    c => c.service_account_impersonation = {token_lifetime_seconds: 43200},
  ];
  for (const change of changes) {
    const value = config(); change(value);
    await assert.rejects(fetchToken(value), {message: 'federation_failed'});
  }
  const azure = config('azure');
  azure.credential_source.url = azure.credential_source.url.replace('&client_id=', '&client_id=&extra=');
  await assert.rejects(fetchToken(azure), {message: 'federation_failed'});
});

test('SDK errors are fixed and STS failures do not retry', async () => {
  const metadata = mockAzure();
  let attempts = 0;
  const sts = nock('https://sts.googleapis.com').persist().post('/v1/token')
    .reply(() => {attempts++; return [503, {error: 'PRIVATE_PROVIDER_ERROR_SENTINEL'}];});
  await assert.rejects(fetchToken(config('azure')), {message: 'federation_failed'});
  assert.ok(metadata.isDone() && sts.isDone());
  assert.equal(attempts, 1);
});

test('STS redirects never forward any method or subject credentials to another endpoint', async () => {
  let leaked = 0;
  for (const method of ['get', 'post']) {
    nock('https://attacker.example').persist()[method]('/steal').reply(() => {leaked++; return [500, {}];});
  }
  for (const status of [302, 307, 308]) {
    const metadata = mockAzure();
    const sts = nock('https://sts.googleapis.com').post('/v1/token').reply(status, '', {location: 'https://attacker.example/steal'});
    await assert.rejects(fetchToken(config('azure')), {message: 'federation_failed'});
    assert.ok(metadata.isDone() && sts.isDone());
  }
  assert.equal(leaked, 0);
});

test('oversized chunked metadata is stopped before its subject token can be exchanged', async () => {
  const metadata = nock('http://169.254.169.254').get('/metadata/identity/oauth2/token').query(true)
    .reply(200, () => Readable.from([JSON.stringify({access_token: 'AZURE_SUBJECT_TOKEN_SENTINEL', padding: 'x'.repeat(100000)})]));
  const sts = mockSts(() => {});
  mockIam();
  await assert.rejects(fetchToken(config('azure')), {message: 'federation_failed'});
  assert.ok(metadata.isDone());
  assert.equal(sts.isDone(), false);
});

test('malformed or expiring impersonated tokens cannot replace runtime credentials', async () => {
  for (const body of [{accessToken: FINAL_TOKEN}, {accessToken: 'bad\r\nheader', expireTime: new Date(Date.now() + 3600000).toISOString()},
    {accessToken: FINAL_TOKEN, expireTime: new Date(Date.now() + 60000).toISOString()}]) {
    mockAzure(); mockSts(() => {}); mockIam(200, body);
    await assert.rejects(fetchToken(config('azure')), {message: 'federation_failed'});
  }
});

test('atomic token replacement leaves only private validated access token and expiry', async () => {
  const path = join(directory, 'token.json');
  const token = {access_token: FINAL_TOKEN, expires_at: Math.floor(Date.now() / 1000) + 3600};
  await writeToken(path, token);
  assert.deepEqual(JSON.parse(await readFile(path, 'utf8')), token);
  assert.equal((await lstat(path)).mode & 0o777, 0o640);
  assert.deepEqual(await readdir(directory), ['token.json']);
  await assert.rejects(writeToken(path, {...token, refresh_token: 'FORBIDDEN'}));
  assert.deepEqual(JSON.parse(await readFile(path, 'utf8')), token);
  await chmod(directory, 0o770);
  await assert.rejects(writeToken(path, token));
  assert.deepEqual(JSON.parse(await readFile(path, 'utf8')), token);
});

test('configuration must be an owned nonwritable regular file, never a symlink', async () => {
  const path = join(directory, 'config.json');
  await writeFile(path, JSON.stringify(config()), {mode: 0o600});
  assert.deepEqual(await readConfiguration(path), config());
  const alias = join(directory, 'alias.json');
  await symlink(path, alias);
  await assert.rejects(readConfiguration(alias));
  await chmod(path, 0o666);
  await assert.rejects(readConfiguration(path));
  await chmod(path, 0o600);
  await writeFile(path, 'x'.repeat(16385));
  await assert.rejects(readConfiguration(path), {message: 'invalid_configuration'});
  await assert.rejects(readConfiguration(directory), {message: 'invalid_configuration'});
});

test('CLI errors never expose provider/config secrets and preserve existing token', async () => {
  const path = join(directory, 'config.json');
  const output = join(directory, 'token.json');
  await writeFile(path, JSON.stringify({secret: 'PRIVATE_CONFIGURATION_SENTINEL'}), {mode: 0o600});
  await writeFile(output, 'previous-token');
  const result = spawnSync(process.execPath, ['cli.mjs', '--config', path, '--output', output], {
    cwd: new URL('..', import.meta.url), encoding: 'utf8', env: {...process.env, GOOGLE_SDK_NODE_LOGGING: '*'},
  });
  assert.equal(result.status, 1);
  assert.equal(result.stdout, '');
  assert.equal(result.stderr, 'Google service token refresh failed.\n');
  assert.equal(await readFile(output, 'utf8'), 'previous-token');
});

test('CLI masks real SDK provider errors even when ambient SDK debug is enabled', async () => {
  const path = join(directory, 'config.json');
  const preload = join(directory, 'mock.mjs');
  const output = join(directory, 'token.json');
  await writeFile(path, JSON.stringify(config('azure')), {mode: 0o600});
  await writeFile(output, 'previous-token');
  await writeFile(preload, `import nock from ${JSON.stringify(import.meta.resolve('nock'))};
    nock.disableNetConnect();
    nock('http://169.254.169.254').get('/metadata/identity/oauth2/token').query(true)
      .reply(200, {access_token: 'AZURE_SUBJECT_TOKEN_SENTINEL'});
    nock('https://sts.googleapis.com').post('/v1/token')
      .reply(503, {error: 'PRIVATE_PROVIDER_ERROR_SENTINEL'});`);
  const result = spawnSync(process.execPath, ['--import', preload, 'cli.mjs', '--config', path, '--output', output], {
    cwd: new URL('..', import.meta.url), encoding: 'utf8', env: {...process.env, GOOGLE_SDK_NODE_LOGGING: '*'},
  });
  assert.equal(result.status, 1);
  assert.equal(result.stdout, '');
  assert.equal(result.stderr, 'Google service token refresh failed.\n');
  assert.equal(await readFile(output, 'utf8'), 'previous-token');
});
