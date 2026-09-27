.pragma library

// Pure parsing and formatting helpers. No QML imports, so dms/tests can run them under node.

/** Usage (percent) from which a window is drawn in the warning color instead of the accent. */
var CRITICAL_PCT = 85;

/** Each Claude check spends ~10 Haiku tokens, so poll it gently. */
var CLAUDE_IDLE_INTERVAL_SECS = 300;
var CLAUDE_LIVE_INTERVAL_SECS = 60;

function levelFor(pct) {
    return pct >= CRITICAL_PCT ? "crit" : "normal";
}

function formatReset(resetAt, now) {
    var secs = resetAt - now;
    if (secs < 0)
        return null;
    var days = Math.floor(secs / 86400);
    var hours = Math.floor((secs % 86400) / 3600);
    var mins = Math.floor((secs % 3600) / 60);
    if (days > 0)
        return days + "d " + hours + "h";
    if (hours > 0)
        return hours + "h " + mins + "m";
    return mins > 0 ? mins + "m" : "<1m";
}

function formatAge(at, now) {
    var secs = Math.max(0, now - at);
    if (secs < 60)
        return "just now";
    if (secs < 3600)
        return Math.floor(secs / 60) + "m ago";
    if (secs < 86400)
        return Math.floor(secs / 3600) + "h ago";
    return Math.floor(secs / 86400) + "d ago";
}

function isFiniteNumber(value) {
    return typeof value === "number" && isFinite(value);
}

/** Turns one line of `ai-limit-counter --json` output into {usage, error}; never throws. */
function parseUsage(text) {
    if (!text || !text.trim())
        return {usage: null, error: "Helper produced no output"};

    var report;
    try {
        report = JSON.parse(text);
    } catch (e) {
        return {usage: null, error: "Unreadable helper output"};
    }
    if (report && typeof report.error === "string" && report.error)
        return {usage: null, error: report.error};

    var fields = ["five_h_pct", "five_h_reset", "seven_d_pct", "seven_d_reset", "fetched_at"];
    if (!report || !fields.every(function (key) { return isFiniteNumber(report[key]); }))
        return {usage: null, error: "Unreadable helper output"};

    return {
        error: null,
        usage: {
            fiveHour: {pct: report.five_h_pct, resetAt: report.five_h_reset},
            sevenDay: {pct: report.seven_d_pct, resetAt: report.seven_d_reset},
            plan: typeof report.plan === "string" ? report.plan : "",
            status: typeof report.status === "string" ? report.status : "unknown",
            dataAt: isFiniteNumber(report.data_at) ? report.data_at : report.fetched_at
        }
    };
}

/** The helper is started without a shell, so a "~" typed into the settings has to be expanded here. */
function expandHome(path, home) {
    var trimmed = (path || "").trim();
    if (trimmed === "~")
        return home;
    return trimmed.indexOf("~/") === 0 ? home + trimmed.slice(1) : trimmed;
}

/** Shortest gap between two automatic refreshes; Codex only reads local files, so it may go faster. */
var MIN_REFRESH_AGE_SECS = {claude: 60, codex: 5};

function mayRefresh(id, fetchedAt, now, force) {
    return force || now - fetchedAt >= (MIN_REFRESH_AGE_SECS[id] || 0);
}

function isClaudeDue(fetchedAt, now, live) {
    var interval = live ? CLAUDE_LIVE_INTERVAL_SECS : CLAUDE_IDLE_INTERVAL_SECS;
    return now - fetchedAt >= interval;
}
