import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

// Execute the actual embedded request script against an in-memory fetch double.
// No browser session, cookies, credentials, or real HTTP requests are used.
const source = readFileSync(new URL('../CivitViewer/SiteSession.swift', import.meta.url), 'utf8');
const request = source.slice(source.indexOf('private func request<T: Decodable>'));
const script = request.match(/let script = """\n([\s\S]*?)\n        """/)[1];
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const run = new AsyncFunction('fetch', 'location', 'origin', 'path', 'method', 'body', 'rpc', 'identity', script);
let checks = 0, calls = 0;
async function response({ status = 200, retryAfter = null, payload = {} }) {
  const fake = async () => {
    calls++;
    return { ok: status >= 200 && status < 300, status,
      headers: { get: name => name === 'Retry-After' ? retryAfter : null },
      json: async () => payload };
  };
  return JSON.parse(await run(fake, { origin: 'https://example.invalid' },
    'https://example.invalid', '/api/trpc/tag.fixture', 'GET', '', true, false));
}
const wrapped = await response({ retryAfter: '700', payload: { error: { json: { data: { httpStatus: 429 } } } } });
assert.deepEqual(wrapped, { ok: false, status: 429, retryAfter: '700' }); checks++;
const direct = await response({ status: 429, retryAfter: '700' });
assert.deepEqual(direct, wrapped); checks++;
const missing = await response({ payload: { error: { json: { data: { httpStatus: 429 } } } } });
assert.deepEqual(missing, { ok: false, status: 429, retryAfter: null }); checks++;
const dated = 'Fri, 01 Jan 2027 12:00:00 GMT';
const dateEnvelope = await response({ retryAfter: dated, payload: { error: { json: { data: { httpStatus: 429 } } } } });
assert.equal(dateEnvelope.retryAfter, dated); checks++;
const success = await response({ payload: { result: { data: { json: { count: 3 } } } } });
assert.deepEqual(success, { ok: true, payload: { count: 3 } }); checks++;
assert.equal(calls, 5); checks++;
console.log(`SiteWebCooldownChecks: ${checks} actual-script assertions passed; zero real requests`);
