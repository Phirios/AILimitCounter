// Run with: gjs -m gnome/tests/format.test.js
import System from 'system';
import {
    parseCredentialsToken,
    parseCredentialsPlan,
    parseClaudeHeaders,
    parseCodexLine,
    windowUtil,
    levelFor,
    formatReset,
    formatAge,
} from '../ailimitcounter@firatege.github.io/lib/format.js';

const NOW = 1_790_500_000;
let failures = 0;
let passed = 0;

function test(name, fn) {
    try {
        fn();
        passed++;
    } catch (e) {
        failures++;
        print(`FAIL ${name}\n     ${e.message}`);
    }
}

function eq(actual, expected) {
    const a = JSON.stringify(actual);
    const b = JSON.stringify(expected);
    if (a !== b)
        throw new Error(`expected ${b}, got ${a}`);
}

function codexLine(primaryUsed, primaryReset, secondaryUsed, secondaryReset, reached = null) {
    return JSON.stringify({
        timestamp: '2026-09-26T13:40:47.505Z',
        type: 'event_msg',
        payload: {
            type: 'token_count',
            rate_limits: {
                limit_id: 'codex',
                primary: {used_percent: primaryUsed, window_minutes: 300, resets_at: primaryReset},
                secondary: {used_percent: secondaryUsed, window_minutes: 10080, resets_at: secondaryReset},
                plan_type: 'plus',
                rate_limit_reached_type: reached,
            },
        },
    });
}

test('reads access token from Claude credentials json', () => {
    const text = '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","expiresAt":1}}';
    eq(parseCredentialsToken(text), 'sk-ant-oat01-abc');
});

test('reads Claude plan and tier from credentials json', () => {
    const text = '{"claudeAiOauth":{"subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}';
    eq(parseCredentialsPlan(text), 'max 5x');
    eq(parseCredentialsPlan('{"claudeAiOauth":{"subscriptionType":"pro"}}'), 'pro');
    eq(parseCredentialsPlan('{"claudeAiOauth":{}}'), '');
    eq(parseCredentialsPlan('not json'), '');
});

test('rejects credentials without a usable token', () => {
    eq(parseCredentialsToken('{"claudeAiOauth":{"accessToken":"  "}}'), null);
    eq(parseCredentialsToken('{"other":{}}'), null);
    eq(parseCredentialsToken('not json'), null);
});

test('parses Claude unified rate-limit headers', () => {
    const headers = {
        'anthropic-ratelimit-unified-5h-utilization': '0.32',
        'anthropic-ratelimit-unified-5h-reset': String(NOW + 3600),
        'anthropic-ratelimit-unified-7d-utilization': '0.4',
        'anthropic-ratelimit-unified-7d-reset': String(NOW + 86400),
        'anthropic-ratelimit-unified-status': 'allowed',
    };
    const usage = parseClaudeHeaders(name => headers[name] ?? null, NOW);
    eq(usage.fiveHour, {pct: 32, resetAt: NOW + 3600});
    eq(usage.sevenDay, {pct: 40, resetAt: NOW + 86400});
    eq(usage.status, 'allowed');
});

test('returns null when Claude headers are missing', () => {
    eq(parseClaudeHeaders(() => null, NOW), null);
});

test('parses current Codex rate-limit event', () => {
    const usage = parseCodexLine(codexLine(42, NOW + 3600, 15, NOW + 86400), NOW);
    eq(usage.fiveHour, {pct: 42, resetAt: NOW + 3600});
    eq(usage.sevenDay, {pct: 15, resetAt: NOW + 86400});
    eq(usage.plan, 'plus');
    eq(usage.status, 'allowed');
});

test('Codex window whose reset has passed counts as zero', () => {
    const usage = parseCodexLine(codexLine(94, NOW - 60, 15, NOW + 86400), NOW);
    eq(usage.fiveHour.pct, 0);
    eq(usage.sevenDay.pct, 15);
});

test('Codex reached limit is reported as blocked', () => {
    const usage = parseCodexLine(codexLine(100, NOW + 60, 15, NOW + 86400, 'primary'), NOW);
    eq(usage.status, 'blocked');
});

test('ignores lines without rate limits', () => {
    eq(parseCodexLine('{"type":"event_msg","payload":{"type":"agent_message"}}', NOW), null);
    eq(parseCodexLine('garbage', NOW), null);
});

test('windowUtil zeroes a window once its reset time is reached', () => {
    eq(windowUtil(55, NOW + 1, NOW), 55);
    eq(windowUtil(55, NOW, NOW), 0);
});

test('levelFor flags usage of 85% and above as critical', () => {
    eq([0, 54, 84, 85, 100].map(levelFor), ['normal', 'normal', 'normal', 'crit', 'crit']);
});

test('formatReset renders remaining time', () => {
    eq(formatReset(NOW + 3 * 3600 + 42 * 60, NOW), '3h 42m');
    eq(formatReset(NOW + 4 * 86400 + 2 * 3600, NOW), '4d 2h');
    eq(formatReset(NOW + 30, NOW), '<1m');
    eq(formatReset(NOW - 1, NOW), null);
});

test('formatAge renders data age', () => {
    eq(formatAge(NOW - 20, NOW), 'just now');
    eq(formatAge(NOW - 5 * 60, NOW), '5m ago');
    eq(formatAge(NOW - 2 * 86400, NOW), '2d ago');
});

print(`${passed} passed, ${failures} failed`);
if (failures > 0)
    System.exit(1);
