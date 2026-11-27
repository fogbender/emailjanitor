import {hardenEnvironment} from './token.mjs';

const ENDPOINT = 'https://oauth2.googleapis.com/revoke';
const invalid = () => {throw new Error('revocation_unavailable');};

export async function revokeRefreshToken(value) {
  try {
    if (!value || typeof value !== 'object' || Array.isArray(value) ||
      Object.keys(value).length !== 1 || typeof value.refresh_token !== 'string' ||
      !/^[\x21-\x7e]{1,32768}$/.test(value.refresh_token)) invalid();
    hardenEnvironment();
    const {OAuth2Client, gaxios} = await import('google-auth-library');
    const transporter = new gaxios.Gaxios({timeout: 10000, maxContentLength: 4096, maxRedirects: 0});
    transporter.interceptors.request.add({resolved: async options => {
      const url = new URL(options.url);
      if (url.origin + url.pathname !== ENDPOINT || url.username || url.password || url.hash ||
        [...url.searchParams.keys()].join(',') !== 'token' ||
        url.searchParams.get('token') !== value.refresh_token || options.method !== 'POST') invalid();
      return {...options, retry: false, retryConfig: {retry: 0}, follow: 0,
        redirect: 'error', size: 4096, responseType: 'json'};
    }});
    const client = new OAuth2Client({transporter, useAuthRequestParameters: false});
    // revokeCredentials() selects an access token, which can already be expired
    // while an offline grant remains live. The maintained SDK owns this wire call.
    const response = await client.revokeToken(value.refresh_token);
    if (response.status !== 200) invalid();
    return {status: 'revoked'};
  } catch (error) {
    // A crash after HTTP 200 can leave a later retry with an invalid token.
    // Report the exact typed result but do not claim the project grant is gone.
    if (error?.response?.status === 400 && error.response.data?.error === 'invalid_token') {
      return {status: 'refresh_token_invalid'};
    }
    invalid();
  }
}
