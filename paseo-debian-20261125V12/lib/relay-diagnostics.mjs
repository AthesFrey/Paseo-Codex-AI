function safeText(value) {
  return String(value ?? '')
    .replace(/(?:https?|wss?):\/\/[^\s"'<>]+/gi, '[url]')
    .replace(/\bBearer\s+\S+/gi, 'Bearer [redacted]')
    .replace(/\b(authorization|cookie|set-cookie|password|secret|token|credential|api[_ -]?key)\b(\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s,;]+)/gi, '$1$2[redacted]')
    .replace(/\b[A-Za-z0-9_-]{32,}\b/g, '[redacted]')
    .replace(/[\r\n\t]+/g, ' ')
    .slice(0, 160);
}

function errorChain(error) {
  const chain = [];
  const seen = new Set();
  let current = error;
  while (current && typeof current === 'object' && chain.length < 4 && !seen.has(current)) {
    chain.push(current);
    seen.add(current);
    current = current.cause;
  }
  return chain;
}

export function errorLabel(error) {
  const chain = errorChain(error);
  if (chain.length === 0) return 'type=Error';
  return chain.map(current => {
    const name = safeText(current.name || 'Error').replace(/[^A-Za-z0-9_.-]/g, '') || 'Error';
    const fields = [`type=${name}`];
    for (const key of ['code', 'reason']) {
      if (typeof current[key] === 'string' && current[key]) {
        const value = safeText(current[key]).replace(/[^A-Za-z0-9_.-]/g, '').slice(0, 48);
        if (value) fields.push(`${key}=${value}`);
      }
    }
    if (current.message) fields.push(`message=${safeText(current.message)}`);
    return fields.join(' ');
  }).join(' <- ');
}

export function stageHint(stage, error) {
  const chain = errorChain(error);
  const codes = chain.map(current => String(current.code || '').toUpperCase());
  const messages = chain.map(current => String(current.message || '')).join(' ');

  if (chain.some(current => current.name === 'DaemonAuthenticationError')) {
    const authError = chain.find(current => current.name === 'DaemonAuthenticationError');
    if (authError.reason === 'password_required') return '检查当前 daemon 的 local-credential 与 paseo.pid';
    if (authError.reason === 'incorrect_password') return '确认 daemon 已完成启动，并检查本机凭据是否属于当前实例';
  }
  if (codes.some(code => ['DAEMON_NOT_RUNNING', 'DAEMON_NOT_READY'].includes(code))) {
    return '等待 Paseo daemon 就绪；检查服务状态和 paseo.pid';
  }
  if (codes.includes('LOCAL_DAEMON_IDENTITY_MISMATCH')) return '检查 config.json、server-id 和活动 daemon 监听地址是否一致';
  if (codes.includes('LOCAL_CREDENTIAL_UNAVAILABLE')) return '检查 PASEO_HOME/local-credential 是否属于当前活动 daemon';

  if (stage === 'Relay daemon 身份校验') {
    return 'Relay 返回了不同的 daemon 身份；检查 PASEO_HOME/server-id、daemon-keypair.json 和 Relay 注册状态';
  }
  if (stage === 'Relay E2EE 安全模式校验') {
    return 'Relay 未确认受保护 E2EE；检查 daemon 与客户端协议版本及安全模式协商';
  }
  if (stage === 'Relay TLS/WebSocket 握手') {
    if (codes.some(code => ['ENOTFOUND', 'EAI_AGAIN', 'ENODATA'].includes(code))) {
      return 'Relay DNS 解析失败；检查域名解析器和 VPS DNS 配置';
    }
    if (codes.some(code => ['ECONNREFUSED', 'ECONNRESET', 'ETIMEDOUT', 'EHOSTUNREACH', 'ENETUNREACH'].includes(code))) {
      return 'Relay TCP 443 连接失败；检查 VPS 出站防火墙、路由和 Relay 可用性';
    }
    if (codes.some(code => code.startsWith('CERT_') || code.startsWith('ERR_TLS') || code.startsWith('ERR_SSL'))
      || /certificate|tls|ssl/i.test(messages)) {
      return 'TLS 握手失败；检查系统时间、CA 证书和 Relay 证书链';
    }
    const response = messages.match(/unexpected server response:\s*(\d{3})/i);
    if (response) return `Relay WebSocket 握手返回 HTTP ${response[1]}；检查 Relay 服务和 endpoint 配置`;
    return '检查 DNS、出站 TCP 443、TLS 握手、Relay WebSocket 和 E2EE 协商';
  }

  if (stage === '加载运行时依赖') return '检查 PASEO_RUNTIME_ROOT 和 runtime/apps/node_modules';
  if (stage === '读取配置与 daemon 身份') return '检查 PASEO_HOME 下的配置、daemon 身份和本机凭据';
  return '检查 Paseo daemon 状态和服务日志';
}
