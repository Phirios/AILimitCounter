// Pure parsing and formatting helpers. No GNOME imports, so they run under plain `gjs -m`.

const CLAUDE_HEADER = 'anthropic-ratelimit-unified-';

/** Usage (percent) from which a window is drawn in the warning color instead of the accent. */
const CRITICAL_PCT = 85;

function parseOauth(text) {
    try {
        return JSON.parse(text)?.claudeAiOauth ?? null;
    } catch {
        return null;
    }
}

export function parseCredentialsToken(text) {
    const token = parseOauth(text)?.accessToken;
    return typeof token === 'string' && token.trim() ? token.trim() : null;
}

/** e.g. subscriptionType "max" + rateLimitTier "default_claude_max_5x" → "max 5x". */
export function parseCredentialsPlan(text) {
    const oauth = parseOauth(text);
    const type = typeof oauth?.subscriptionType === 'string' ? oauth.subscriptionType : '';
    const tier = typeof oauth?.rateLimitTier === 'string' ? oauth.rateLimitTier.match(/_(\d+x)$/)?.[1] : null;
    return [type, tier].filter(Boolean).join(' ');
}

/** A window whose reset time has passed has been refilled, whatever the last report said. */
export function windowUtil(pct, resetAt, now) {
    return resetAt <= now ? 0 : pct;
}

function makeWindow(pct, resetAt, now) {
    return {pct: Math.round(windowUtil(pct, resetAt, now)), resetAt};
}

/** @param {(name: string) => string|null} getHeader */
export function parseClaudeHeaders(getHeader, now) {
    const num = key => {
        const raw = getHeader(CLAUDE_HEADER + key);
        const value = raw === null ? NaN : Number(raw);
        return Number.isFinite(value) ? value : null;
    };
    const fiveUtil = num('5h-utilization');
    const sevenUtil = num('7d-utilization');
    if (fiveUtil === null || sevenUtil === null)
        return null;

    return {
        fiveHour: makeWindow(fiveUtil * 100, num('5h-reset') ?? now + 1, now),
        sevenDay: makeWindow(sevenUtil * 100, num('7d-reset') ?? now + 1, now),
        status: getHeader(`${CLAUDE_HEADER}status`) ?? 'unknown',
        plan: '',
    };
}

export function parseCodexLine(line, now) {
    let limits;
    try {
        limits = JSON.parse(line)?.payload?.rate_limits;
    } catch {
        return null;
    }
    const primary = limits?.primary;
    if (typeof primary?.used_percent !== 'number' || typeof primary?.resets_at !== 'number')
        return null;

    const secondary = limits.secondary ?? primary;
    return {
        fiveHour: makeWindow(primary.used_percent, primary.resets_at, now),
        sevenDay: makeWindow(
            secondary.used_percent ?? primary.used_percent,
            secondary.resets_at ?? primary.resets_at,
            now),
        status: limits.rate_limit_reached_type ? 'blocked' : 'allowed',
        plan: limits.plan_type ?? '',
    };
}

export function levelFor(pct) {
    return pct >= CRITICAL_PCT ? 'crit' : 'normal';
}

export function formatReset(resetAt, now) {
    const secs = resetAt - now;
    if (secs < 0)
        return null;
    const days = Math.floor(secs / 86400);
    const hours = Math.floor((secs % 86400) / 3600);
    const mins = Math.floor((secs % 3600) / 60);
    if (days > 0)
        return `${days}d ${hours}h`;
    if (hours > 0)
        return `${hours}h ${mins}m`;
    return mins > 0 ? `${mins}m` : '<1m';
}

export function formatAge(at, now) {
    const secs = Math.max(0, now - at);
    if (secs < 60)
        return 'just now';
    if (secs < 3600)
        return `${Math.floor(secs / 60)}m ago`;
    if (secs < 86400)
        return `${Math.floor(secs / 3600)}h ago`;
    return `${Math.floor(secs / 86400)}d ago`;
}
