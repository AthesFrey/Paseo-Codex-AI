// Real TLS/E2EE Relay round trip with the installed official client. No model request.
import fs from 'node:fs';
import path from 'node:path';
import {createRequire} from 'node:module';
import {pathToFileURL} from 'node:url';
import {randomUUID} from 'node:crypto';
import {setTimeout as delay} from 'node:timers/promises';
const noop = () => {};
let client;
let stage = '加载运行时依赖';
const timer = setTimeout(() => {
  console.error(`RELAY_CHECK_FAILED：${stage}超时；${stageHint(stage)}。`);
  process.exit(1);
}, 45000);

function stageHint(value, error) {
  if (value === '加载运行时依赖') return '检查 PASEO_RUNTIME_ROOT 和 runtime/apps/node_modules';
  if (error?.name === 'DaemonAuthenticationError') {
    if (error.reason === 'password_required') return '检查当前 daemon 的 local-credential 与 paseo.pid';
    if (error.reason === 'incorrect_password') return '本机凭据未被当前 daemon 接受；确认服务已完成启动后重试';
  }
  if (error?.code === 'DAEMON_NOT_RUNNING' || error?.code === 'DAEMON_NOT_READY') {
    return '等待 Paseo daemon 就绪超时；检查服务状态和 paseo.pid';
  }
  if (error?.code === 'LOCAL_DAEMON_IDENTITY_MISMATCH') return '检查 config.json、server-id 和活动 daemon 监听地址是否一致';
  if (error?.code === 'LOCAL_CREDENTIAL_UNAVAILABLE') return '检查 PASEO_HOME/local-credential 是否属于当前活动 daemon';
  if (value === '读取配置与 daemon 身份') return '检查 PASEO_HOME 下的配置、daemon 身份和本机凭据';
  if (value === 'Relay TLS/E2EE 连接') return '检查 DNS、出站 TCP 443 和 Relay 服务';
  return '检查 Paseo daemon 状态和服务日志';
}

function errorLabel(error) {
  const name = typeof error?.name === 'string' ? error.name : 'Error';
  const code = typeof error?.code === 'string' ? error.code : '';
  const reason = typeof error?.reason === 'string' ? error.reason : '';
  const safeName = name.replace(/[^A-Za-z0-9_.-]/g, '').slice(0, 48) || 'Error';
  const safeCode = code.replace(/[^A-Za-z0-9_.-]/g, '').slice(0, 48);
  const safeReason = reason.replace(/[^A-Za-z0-9_.-]/g, '').slice(0, 48);
  return [
    `type=${safeName}`,
    ...(safeCode ? [`code=${safeCode}`] : []),
    ...(safeReason ? [`reason=${safeReason}`] : []),
  ].join(' ');
}

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
  stage = 'Relay TLS/E2EE 连接';
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
  if (negotiatedSecurityMode !== 'protected') throw Error('Relay did not negotiate protected endpoint security');
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
