// Real TLS/E2EE Relay round trip with the installed official client. No model request.
import fs from 'node:fs';
import path from 'node:path';
import {createRequire} from 'node:module';
import {pathToFileURL} from 'node:url';
import {randomUUID} from 'node:crypto';
const noop = () => {};
let client;
let stage = '读取配置与 daemon 身份';
const timer = setTimeout(() => {
  console.error(`RELAY_CHECK_FAILED：${stage}超时；检查出站 TCP 443、Relay 服务和 daemon 日志。`);
  process.exit(1);
}, 45000);

function errorLabel(error) {
  const name = typeof error?.name === 'string' ? error.name : 'Error';
  const code = typeof error?.code === 'string' ? error.code : '';
  const safeName = name.replace(/[^A-Za-z0-9_.-]/g, '').slice(0, 48) || 'Error';
  const safeCode = code.replace(/[^A-Za-z0-9_.-]/g, '').slice(0, 48);
  return safeCode ? `type=${safeName} code=${safeCode}` : `type=${safeName}`;
}

try {
  const require = createRequire(new URL('../apps/node_modules/@getpaseo/cli/package.json', import.meta.url));
  const {version: cliVersion} = JSON.parse(fs.readFileSync(new URL('../apps/node_modules/@getpaseo/cli/package.json', import.meta.url), 'utf8'));
  const {DaemonClient} = await import(pathToFileURL(require.resolve('@getpaseo/client/internal/daemon-client')).href);
  const {buildRelayWebSocketUrl} = await import(pathToFileURL(require.resolve('@getpaseo/protocol/daemon-endpoints')).href);
  const {WebSocket} = require('ws');
  const home = process.env.PASEO_HOME || '/srv/paseo/.paseo';
  const relay = JSON.parse(fs.readFileSync(path.join(home,'config.json'),'utf8')).daemon?.relay;
  if (relay?.enabled !== true || relay.useTls !== true || relay.publicUseTls !== true) throw Error('Relay TLS config');
  const serverId = fs.readFileSync(path.join(home,'server-id'),'utf8').trim();
  const daemonPublicKeyB64 = JSON.parse(fs.readFileSync(path.join(home,'daemon-keypair.json'),'utf8')).publicKeyB64;
  stage = 'Relay TLS/E2EE 连接';
  client = new DaemonClient({
    url: buildRelayWebSocketUrl({endpoint:relay.publicEndpoint || relay.endpoint,useTls:true,serverId,role:'client'}),
    clientId:randomUUID(),clientType:'cli',appVersion:cliVersion,connectTimeoutMs:15000,
    reconnect:{enabled:false},e2ee:{enabled:true,daemonPublicKeyB64},
    webSocketFactory:(url,opts)=>new WebSocket(url,opts?.protocols,{headers:opts?.headers,handshakeTimeout:12000,perMessageDeflate:false}),
    logger:{debug:noop,info:noop,warn:noop,error:noop}
  });
  await client.connect();
  if (client.getLastServerInfoMessage()?.serverId !== serverId) throw Error('Wrong daemon');
  stage = 'daemon 状态 RPC';
  const status = await client.getDaemonStatus({timeout:8000});
  if (status.serverId !== serverId || status.version !== cliVersion) throw Error('Wrong daemon status');
  console.log('RELAY_OK：已通过 TLS/E2EE Relay 完成与本 daemon 的状态请求。未调用模型 API。');
} catch (error) {
  console.error(`RELAY_CHECK_FAILED：${stage}未完成（${errorLabel(error)}）。检查 DNS、出站 TCP 443、Relay 服务及 daemon 日志。`);
  process.exitCode = 1;
} finally {
  if (client) await client.close().catch(noop);
  clearTimeout(timer);
}
