import { isKimiTokenExpiringSoon } from "@omniroute/open-sse/utils/kimiJwt.ts";
import { exchangeKimiRefreshToken } from "@/lib/kimi/tokenRefresh";
import { updateProviderConnection } from "@/lib/db/providers";

export async function checkKimiWebConnectionIfNeeded(params: {
  conn: any;
  now: string;
  log: (msg: string, ...args: any[]) => void;
  logWarn: (msg: string, ...args: any[]) => void;
  logError: (msg: string, ...args: any[]) => void;
  getConnectionLogLabel: (conn: any) => string;
  logPrefix: string;
  exchangeFn?: typeof exchangeKimiRefreshToken;
  persistFn?: typeof updateProviderConnection;
}): Promise<boolean> {
  const { conn, log, logWarn, getConnectionLogLabel, logPrefix } = params;
  const provider = String(conn?.provider || "").toLowerCase();
  if (provider !== "kimi-web" && provider !== "kimi_web") return false;

  const refreshToken = conn.refreshToken || conn.providerSpecificData?.refreshToken;
  if (!refreshToken) return true; // Handled, but cannot refresh without refresh_token

  const token = conn.apiKey || conn.accessToken;
  // Calculate jitter: random value between 60 and 240 seconds (1 to 4 min before expiry)
  const jitterSec = 60 + Math.floor(Math.random() * 180);
  const expiringSoon = isKimiTokenExpiringSoon(token, jitterSec);

  if (!expiringSoon) return true;

  log(`${logPrefix} Kimi Web connection ${getConnectionLogLabel(conn)} token expiring soon; refreshing in background...`);

  const exchange = params.exchangeFn || exchangeKimiRefreshToken;
  const persist = params.persistFn || updateProviderConnection;

  const res = await exchange(refreshToken);
  if (res.success && res.accessToken) {
    log(`${logPrefix} Kimi Web connection ${getConnectionLogLabel(conn)} token refreshed successfully.`);
    await persist(conn.id, {
      apiKey: res.accessToken,
      accessToken: res.accessToken,
      refreshToken: res.refreshToken,
      expiresAt: res.expiresAtSec ? new Date(res.expiresAtSec * 1000).toISOString() : undefined,
      testStatus: "active",
      lastError: null,
      errorCode: null,
    });
  } else {
    logWarn(`${logPrefix} Failed to auto-refresh Kimi Web token: ${res.error}`);
  }

  return true;
}
