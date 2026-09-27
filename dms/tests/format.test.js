// Run with: node --test dms/tests/format.test.js
// format.js is a QML `.pragma library` script, so it has no exports; evaluate it and pick the functions.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {test} = require('node:test');

const NAMES = ['levelFor', 'formatReset', 'formatAge', 'parseUsage', 'isClaudeDue', 'expandHome'];
const source = fs
    .readFileSync(path.join(__dirname, '../aiLimitCounter/format.js'), 'utf8')
    .replace(/^\.pragma library$/m, '');
const Format = new Function(`${source}\nreturn {${NAMES.join(', ')}};`)();

const NOW = 1_000_000;

test('usage below 85% is normal, 85% and above is critical', () => {
    assert.equal(Format.levelFor(84), 'normal');
    assert.equal(Format.levelFor(85), 'crit');
});

test('formats the time left until a reset at the coarsest useful unit', () => {
    assert.equal(Format.formatReset(NOW + 2 * 86400 + 3 * 3600, NOW), '2d 3h');
    assert.equal(Format.formatReset(NOW + 3 * 3600 + 5 * 60, NOW), '3h 5m');
    assert.equal(Format.formatReset(NOW + 5 * 60, NOW), '5m');
    assert.equal(Format.formatReset(NOW + 20, NOW), '<1m');
});

test('returns null for a reset time that has already passed', () => {
    assert.equal(Format.formatReset(NOW - 1, NOW), null);
});

test('formats how long ago data was fetched', () => {
    assert.equal(Format.formatAge(NOW - 5, NOW), 'just now');
    assert.equal(Format.formatAge(NOW - 125, NOW), '2m ago');
    assert.equal(Format.formatAge(NOW - 7200, NOW), '2h ago');
    assert.equal(Format.formatAge(NOW + 50, NOW), 'just now');
});

test('parses a successful usage report', () => {
    const text = JSON.stringify({
        error: null, fetched_at: NOW, five_h_pct: 8, five_h_reset: NOW + 60,
        seven_d_pct: 4, seven_d_reset: NOW + 120, plan: 'max 5x', status: 'allowed',
    });
    assert.deepEqual(Format.parseUsage(text), {
        error: null,
        usage: {
            fiveHour: {pct: 8, resetAt: NOW + 60},
            sevenDay: {pct: 4, resetAt: NOW + 120},
            plan: 'max 5x',
            status: 'allowed',
            dataAt: NOW,
        },
    });
});

test('passes through an error reported by the helper', () => {
    const text = JSON.stringify({error: 'Token not found', provider: 'Claude Code'});
    assert.deepEqual(Format.parseUsage(text), {usage: null, error: 'Token not found'});
});

test('reports unreadable helper output as an error instead of throwing', () => {
    assert.equal(Format.parseUsage('').usage, null);
    assert.match(Format.parseUsage('').error, /no output/i);
    assert.match(Format.parseUsage('<html>').error, /unreadable/i);
    assert.match(Format.parseUsage('{"five_h_pct":"x"}').error, /unreadable/i);
});

test('polls Claude every minute while it runs and every five minutes otherwise', () => {
    assert.equal(Format.isClaudeDue(NOW - 59, NOW, true), false);
    assert.equal(Format.isClaudeDue(NOW - 60, NOW, true), true);
    assert.equal(Format.isClaudeDue(NOW - 299, NOW, false), false);
    assert.equal(Format.isClaudeDue(NOW - 300, NOW, false), true);
});

test('prefers the age of the data itself over the time it was read', () => {
    const report = {
        error: null, fetched_at: NOW, data_at: NOW - 900, five_h_pct: 1, five_h_reset: NOW + 60,
        seven_d_pct: 2, seven_d_reset: NOW + 120,
    };
    assert.equal(Format.parseUsage(JSON.stringify(report)).usage.dataAt, NOW - 900);
    delete report.data_at;
    assert.equal(Format.parseUsage(JSON.stringify(report)).usage.dataAt, NOW);
});

test('expands a leading tilde because the helper is started without a shell', () => {
    assert.equal(Format.expandHome('~/.local/bin/helper', '/home/me'), '/home/me/.local/bin/helper');
    assert.equal(Format.expandHome('~', '/home/me'), '/home/me');
    assert.equal(Format.expandHome('  ~/bin/helper  ', '/home/me'), '/home/me/bin/helper');
});

test('leaves absolute paths and other tildes alone', () => {
    assert.equal(Format.expandHome('/usr/bin/helper', '/home/me'), '/usr/bin/helper');
    assert.equal(Format.expandHome('~other/helper', '/home/me'), '~other/helper');
    assert.equal(Format.expandHome('', '/home/me'), '');
});
