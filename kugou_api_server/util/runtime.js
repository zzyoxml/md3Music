const { URL } = require('url');

/** @type {string | undefined} */
let cachedProxyRaw;
/** @type {import('axios').AxiosProxyConfig | null} */
let cachedProxy;

/**
 * Parse CLI arguments (only `--key=value` form).
 * @param {string[] | undefined} args
 * @returns {Record<string, string>}
 */
function parseCliArgs(args) {
  const source = Array.isArray(args) ? args : process.argv.slice(2);
  return source.reduce((acc, rawArg) => {
    if (typeof rawArg !== 'string') {
      return acc;
    }
    const arg = rawArg.trim();
    if (!arg.startsWith('--')) {
      return acc;
    }
    const eqIndex = arg.indexOf('=');
    if (eqIndex <= 2 || eqIndex === arg.length - 1) {
      return acc;
    }
    const key = arg.slice(2, eqIndex).trim();
    const value = arg.slice(eqIndex + 1).trim();
    if (!key || !value) return acc;
    acc[key] = value;
    return acc;
  }, {});
}

/**
 * Apply CLI overrides for known parameters (proxy/platform/port).
 * @param {string[] | undefined} args
 */
function applyCliOverrides(args) {
  const parsed = parseCliArgs(args);

  if (parsed.proxy) {
    process.env.KUGOU_API_PROXY = parsed.proxy;
  }

  if (parsed.platform) {
    process.env.platform = parsed.platform;
  }

  // 强制走概念版（lite）协议
  process.env.platform = 'lite';

  if (parsed.guid) {
    process.env.KUGOU_API_GUID = parsed.guid;
  }

  if (parsed.dev) {
    process.env.KUGOU_API_DEV = parsed.dev;
  }

  if (parsed.mac) {
    process.env.KUGOU_API_MAC = parsed.mac;
  }

  if (parsed.port) {
    const port = Number(parsed.port);
    if (!Number.isNaN(port) && port > 0) {
      process.env.PORT = String(port);
    } else {
      console.warn(`[cli] Invalid port value "${parsed.port}", fallback to default.`);
    }
  }
}

/**
 * Resolve proxy configuration from environment variable.
 * Caches latest parsed result to avoid repeated parsing.
 * @returns {import('axios').AxiosProxyConfig | null}
 */
function resolveProxy() {
  // 检查KUGOU_API_PROXY环境变量
  const rawProxyEnv = typeof process.env.KUGOU_API_PROXY === 'string' ? process.env.KUGOU_API_PROXY.trim() : undefined;
  const rawProxy = rawProxyEnv && rawProxyEnv.length > 0 ? rawProxyEnv : undefined;

  // 如果没有设置KUGOU_API_PROXY，检查系统代理环境变量
  const systemProxy = process.env.HTTPS_PROXY || process.env.https_proxy || process.env.HTTP_PROXY || process.env.http_proxy;
  const proxyToUse = rawProxy || systemProxy;

  if (!proxyToUse) {
    return null;
  }

  if (cachedProxyRaw === proxyToUse) {
    return cachedProxy;
  }

  cachedProxyRaw = proxyToUse;
  try {
    const parsed = new URL(proxyToUse);
    if (!/^https?:$/.test(parsed.protocol)) {
      console.warn(`[proxy] Unsupported proxy protocol: ${parsed.protocol}`);
      cachedProxy = null;
      return null;
    }

    const proxyConfig = {
      protocol: parsed.protocol.replace(':', ''),
      host: parsed.hostname,
      port: parsed.port ? Number(parsed.port) : parsed.protocol === 'https:' ? 443 : 80,
    };

    if (parsed.username || parsed.password) {
      proxyConfig.auth = {
        username: parsed.username,
        password: parsed.password,
      };
    }

    cachedProxy = proxyConfig;
    console.info(`[proxy] Using proxy ${parsed.protocol}//${parsed.host}`);
  } catch (error) {
    console.warn(`[proxy] Failed to parse proxy address "${rawProxy}": ${error.message}`);
    cachedProxy = null;
  }

  return cachedProxy;
}

module.exports = { applyCliOverrides, parseCliArgs, resolveProxy };
