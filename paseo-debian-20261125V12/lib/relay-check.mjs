// Real TLS/E2EE Relay round trip with the installed official client. No model request.
import fs from 'node:fs';
import path from 'node:path';
import {createRequire} from 'node:module';
import {pathToFileURL} from 'node:url';
import {randomUUID} from 'node:crypto';
import {setTimeout as delay} from 'node:timers/promises';
import {errorLabel,stageHint} from './relay-diagnostics.mjs';
const noop = () => {};
let client;
let stage = '加载运行时依赖';
const timer = setTimeout(() => {
  console.error(`RELAY_CHECK_FAILED：${stage}超时；${stageHint(stage)}。`);
  process.exit(1);
}, 45000);

async function waitForDaemonStartup(home, readinessApi, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    try {
      return await readinessApi(home, {
        timeoutMs: Math.min(1000, deadline - Date.now()),
      });
    } catch (error) {
      if (!['DAEMON_NOT_RUNNING', 'DAEMON_NOT_READY'].includes(error?.code)) throw error;
      lastError = error;
      await delay(Math.min(250, Math.max(1, deadline - Date.now())));
    }
  }
  throw lastError ?? new Error('Daemon readiness timed out');
}

try {
  const runtimeRoot = process.env.PASEO_RUNTIME_ROOT || '/srv/paseo/runtime';
  if (!path.isAbsolute(runtimeRoot)) throw Error('PASEO_RUNTIME_ROOT must be absolute');
  const cliPackagePath = path.join(runtimeRoot, 'apps/node_modules/@getpaseo/cli/package.json');
  const require = createRequire(pathToFileURL(cliPackagePath));
  const {version: cliVersion} = JSON.parse(fs.readFileSync(cliPackagePath, 'utf8'));
  const {DaemonClient} = await import(pathToFileURL(require.resolve('@getpaseo/client/internal/daemon-client')).href);
  const {buildRelayWebSocketUrl} = await import(pathToFileURL(require.resolve('@getpaseo/protocol/daemon-endpoints')).href);
  const {waitForDaemonReady:waitForDaemonReadyFromPaseo,readLocalCredentialForTarget} = await import(pathToFileURL(require.resolve('@getpaseo/server/daemon-control')).href);
  const {WebSocket} = require('ws');
  stage = '读取配置与 daemon 身份';
  const home = process.env.PASEO_HOME || '/srv/paseo/.paseo';
  const daemonConfig = JSON.parse(fs.readFileSync(path.join(home,'config.json'),'utf8')).daemon;
  const relay = daemonConfig?.relay;
  if (relay?.enabled !== true || relay.useTls !== true || relay.publicUseTls !== true) throw Error('Relay TLS config');
  const localListen = daemonConfig?.listen;
  if (typeof localListen !== 'string' || !localListen) throw Error('Daemon listen address is missing');
  const serverId = fs.readFileSync(path.join(home,'server-id'),'utf8').trim();
  const daemonPublicKeyB64 = JSON.parse(fs.readFileSync(path.join(home,'daemon-keypair.json'),'utf8')).publicKeyB64;
  if (!serverId || typeof daemonPublicKeyB64 !== 'string' || !daemonPublicKeyB64) {
    throw Error('Daemon identity files are incomplete');
  }
  const activeInstance = await waitForDaemonStartup(home, waitForDaemonReadyFromPaseo);
  if (activeInstance.listen !== localListen
    || (activeInstance.serverId && activeInstance.serverId !== serverId)) {
    const error = new Error('Active daemon identity does not match the configured Paseo home');
    error.code = 'LOCAL_DAEMON_IDENTITY_MISMATCH';
    throw error;
  }
  const getLocalCredential = () => readLocalCredentialForTarget(home, activeInstance.listen) ?? undefined;
  if (!getLocalCredential()) {
    const error = new Error('Local daemon credential is unavailable for the active listener');
    error.code = 'LOCAL_CREDENTIAL_UNAVAILABLE';
    throw error;
  }
  stage = 'Relay TLS/WebSocket 握手';
  let negotiatedSecurityMode;
  client = new DaemonClient({
    url: buildRelayWebSocketUrl({endpoint:relay.publicEndpoint || relay.endpoint,useTls:true,serverId,role:'client'}),
    clientId:randomUUID(),clientType:'cli',appVersion:cliVersion,connectTimeoutMs:15000,
    localCredential:getLocalCredential,
    reconnect:{enabled:false},e2ee:{
      enabled:true,daemonPublicKeyB64,minimumMode:'protected',
      onSecurityMode:mode=>{negotiatedSecurityMode=mode;}
    },
    webSocketFactory:(url,opts)=>new WebSocket(url,opts?.protocols,{headers:opts?.headers,handshakeTimeout:12000,perMessageDeflate:false}),
    logger:{debug:noop,info:noop,warn:noop,error:noop}
  });
  await client.connect();
  stage = 'Relay E2EE 安全模式校验';
  if (negotiatedSecurityMode !== 'protected') throw Error('Relay did not negotiate protected endpoint security');
  stage = 'Relay daemon 身份校验';
  if (client.getLastServerInfoMessage()?.serverId !== serverId) throw Error('Wrong daemon');
  stage = 'daemon 状态 RPC';
  const status = await client.getDaemonStatus({timeout:8000});
  if (status.serverId !== serverId || status.version !== cliVersion) throw Error('Wrong daemon status');
  console.log('RELAY_OK：已通过 TLS/E2EE Relay 完成与本 daemon 的状态请求。未调用模型 API。');
} catch (error) {
  console.error(`RELAY_CHECK_FAILED：${stage}未完成（${errorLabel(error)}）。${stageHint(stage,error)}。`);
  process.exitCode = 1;
} finally {
  if (client) await client.close().catch(noop);
  clearTimeout(timer);
}
