import assert from 'node:assert/strict';
import test from 'node:test';
import {errorLabel, stageHint} from '../lib/relay-diagnostics.mjs';

test('labels nested network failures and masks credentials and URLs', () => {
  const cause = Object.assign(new Error('connect ECONNRESET https://relay.example.test/path?token=secret-value'), {
    code: 'ECONNRESET',
  });
  const error = Object.assign(new Error('Relay connection failed; Bearer abcdefghijklmnopqrstuvwxyz0123456789'), {
    cause,
  });
  const label = errorLabel(error);
  assert.match(label, /type=Error/);
  assert.match(label, /code=ECONNRESET/);
  assert.match(label, /ECONNRESET/);
  assert.doesNotMatch(label, /secret-value|abcdefghijklmnopqrstuvwxyz0123456789|https:\/\//);
  assert.equal(stageHint('Relay TLS/WebSocket 握手', error), 'Relay TCP 443 连接失败；检查 VPS 出站防火墙、路由和 Relay 可用性');
});

test('identifies DNS, TLS, and WebSocket handshake failures', () => {
  assert.match(stageHint('Relay TLS/WebSocket 握手', {code: 'EAI_AGAIN'}), /DNS/);
  assert.match(stageHint('Relay TLS/WebSocket 握手', {code: 'CERT_HAS_EXPIRED'}), /系统时间/);
  assert.match(stageHint('Relay TLS/WebSocket 握手', {message: 'Unexpected server response: 502'}), /HTTP 502/);
  assert.match(stageHint('Relay E2EE 安全模式校验', new Error('no security mode')), /协议版本/);
  assert.match(stageHint('Relay daemon 身份校验', new Error('Wrong daemon')), /server-id/);
});

test('keeps local daemon readiness failures actionable', () => {
  assert.match(stageHint('daemon 状态 RPC', {code: 'DAEMON_NOT_READY'}), /paseo.pid/);
  assert.match(errorLabel(null), /^type=Error$/);
});
