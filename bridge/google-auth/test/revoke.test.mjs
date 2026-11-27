import test, {afterEach, beforeEach} from 'node:test';
import assert from 'node:assert/strict';
import nock from 'nock';
import {spawnSync} from 'node:child_process';
import {revokeRefreshToken} from '../revoke.mjs';

const REFRESH = '1//PRIVATE_OFFLINE_REFRESH_TOKEN_SENTINEL';
beforeEach(() => nock.disableNetConnect());
afterEach(() => {nock.cleanAll(); nock.enableNetConnect();});

test('official SDK revokes the offline refresh token even when its associated access token has expired', async () => {
  const stored = {refresh_token: REFRESH, access_token: 'EXPIRED_ACCESS_TOKEN_SENTINEL', expires_at: 1};
  const server = nock('https://oauth2.googleapis.com')
    .post('/revoke').query({token: stored.refresh_token}).once().reply(200, {});
  assert.deepEqual(await revokeRefreshToken({refresh_token: stored.refresh_token}), {status: 'revoked'});
  assert.ok(server.isDone());
});

test('repeating HTTP 200 after a simulated post-wire crash converges without a different token or endpoint', async () => {
  const server = nock('https://oauth2.googleapis.com')
    .post('/revoke').query({token: REFRESH}).twice().reply(200, {});
  await revokeRefreshToken({refresh_token: REFRESH}); // host confirmation lost
  assert.deepEqual(await revokeRefreshToken({refresh_token: REFRESH}), {status: 'revoked'});
  assert.ok(server.isDone());
});

test('an exact invalid refresh token is typed pending/manual evidence rather than successful erasure', async () => {
  const server = nock('https://oauth2.googleapis.com')
    .post('/revoke').query({token: REFRESH}).reply(400, {error: 'invalid_token', error_description: REFRESH});
  const result = await revokeRefreshToken({refresh_token: REFRESH});
  assert.deepEqual(result, {status: 'refresh_token_invalid'});
  assert.ok(server.isDone());
  assert.ok(!JSON.stringify(result).includes(REFRESH));
});

test('provider failures never retry and errors contain no credential, URL or provider text', async () => {
  const server = nock('https://oauth2.googleapis.com')
    .post('/revoke').query({token: REFRESH}).once().reply(503, {error: REFRESH});
  await assert.rejects(revokeRefreshToken({refresh_token: REFRESH}), error =>
    error.message === 'revocation_unavailable' && !error.stack.includes(REFRESH));
  assert.ok(server.isDone());
});

test('the maintained SDK bounds a stalled revocation without retrying', {timeout: 15000}, async () => {
  const server = nock('https://oauth2.googleapis.com')
    .post('/revoke').query({token: REFRESH}).once().delay(12000).reply(200, {});
  await assert.rejects(revokeRefreshToken({refresh_token: REFRESH}), /revocation_unavailable/);
  assert.ok(server.isDone());
});

test('redirects and excessive successful response bodies fail closed', async () => {
  const redirect = nock('https://oauth2.googleapis.com')
    .post('/revoke').query({token: REFRESH}).reply(302, '', {Location: 'https://attacker.example/steal'});
  let redirected = false;
  nock('https://attacker.example').get('/steal').optionally().reply(() => {redirected = true; return [200, {}];});
  await assert.rejects(revokeRefreshToken({refresh_token: REFRESH}), /revocation_unavailable/);
  assert.ok(redirect.isDone());
  assert.equal(redirected, false);
  nock.cleanAll();
  const oversized = nock('https://oauth2.googleapis.com')
    .post('/revoke').query({token: REFRESH}).reply(200, 'x'.repeat(32768));
  await assert.rejects(revokeRefreshToken({refresh_token: REFRESH}), /revocation_unavailable/);
  assert.ok(oversized.isDone());
});

test('access-only credentials, caller endpoints and malformed frames never reach a provider', async () => {
  for (const value of [{access_token: REFRESH}, {refresh_token: REFRESH, endpoint: 'https://attacker.example'}, {refresh_token: 'bad\nvalue'}, null]) {
    await assert.rejects(revokeRefreshToken(value), /revocation_unavailable/);
  }
  for (const input of ['not JSON\n', '{}\n', '{"refresh_token":"short"}\n{}\n', 'x'.repeat(131073)]) {
    const result = spawnSync(process.execPath, ['revoke-cli.mjs'], {cwd: new URL('..', import.meta.url), input, encoding: 'utf8', timeout: 15000});
    assert.equal(result.status, 1);
    assert.equal(result.stdout, '');
    assert.equal(result.stderr, 'Google grant revocation unavailable.\n');
  }
});
