// Data sources: Claude (API rate-limit headers) and Codex (local session logs).
// Everything is async so the shell's main loop never blocks on disk or network.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Soup from 'gi://Soup?version=3.0';

import {
    parseClaudeHeaders,
    parseCodexLine,
    parseCredentialsPlan,
    parseCredentialsToken,
} from './format.js';

Gio._promisify(Gio.File.prototype, 'load_contents_async');
Gio._promisify(Gio.File.prototype, 'enumerate_children_async');
Gio._promisify(Gio.File.prototype, 'read_async');
Gio._promisify(Gio.File.prototype, 'query_info_async');
Gio._promisify(Gio.FileEnumerator.prototype, 'next_files_async');
Gio._promisify(Gio.InputStream.prototype, 'read_bytes_async');
Gio._promisify(Gio.Subprocess.prototype, 'wait_check_async');
Gio._promisify(Soup.Session.prototype, 'send_and_read_async');

const CLAUDE_URL = 'https://api.anthropic.com/v1/messages';
const CLAUDE_PROBE_MODEL = 'claude-haiku-4-5-20251001';
/** Codex logs are large (MBs); the latest rate-limit event is near the end. */
const CODEX_TAIL_BYTES = 512 * 1024;
const CODEX_LIVE_WINDOW_SECS = 120;
const ENUMERATE_BATCH = 64;

const HOME = GLib.get_home_dir();
const decoder = new TextDecoder();

export const nowSecs = () => Math.floor(Date.now() / 1000);

export class SourceError extends Error {}

async function readText(file, cancellable) {
    const [bytes] = await file.load_contents_async(cancellable);
    return decoder.decode(bytes);
}

// ── Claude ───────────────────────────────────────────────────────────────────

/** @returns {Promise<{token: string|null, plan: string}>} */
async function readClaudeCredentials(cancellable) {
    const claudeDir = GLib.build_filenamev([HOME, '.claude']);
    try {
        const text = await readText(
            Gio.File.new_for_path(GLib.build_filenamev([claudeDir, '.credentials.json'])), cancellable);
        const token = parseCredentialsToken(text);
        if (token)
            return {token, plan: parseCredentialsPlan(text)};
    } catch (e) {
        if (e.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
            throw e;
    }
    // Legacy plain-text token file used by the macOS/KDE builds.
    try {
        const text = await readText(
            Gio.File.new_for_path(GLib.build_filenamev([claudeDir, 'claude-menubar-token'])), cancellable);
        return {token: text.trim() || null, plan: ''};
    } catch {
        return {token: null, plan: ''};
    }
}

export async function fetchClaude(session, cancellable) {
    const {token, plan} = await readClaudeCredentials(cancellable);
    if (!token)
        throw new SourceError('Claude token not found — run `claude auth login`');

    const message = Soup.Message.new('POST', CLAUDE_URL);
    // Never follow a redirect with the bearer token attached.
    message.add_flags(Soup.MessageFlags.NO_REDIRECT);
    const headers = message.get_request_headers();
    headers.append('authorization', `Bearer ${token}`);
    headers.append('anthropic-version', '2023-06-01');
    headers.append('anthropic-beta', 'oauth-2025-04-20');
    const body = JSON.stringify({
        model: CLAUDE_PROBE_MODEL,
        max_tokens: 1,
        messages: [{role: 'user', content: '.'}],
    });
    message.set_request_body_from_bytes('application/json', new GLib.Bytes(new TextEncoder().encode(body)));

    await session.send_and_read_async(message, GLib.PRIORITY_DEFAULT, cancellable);

    const status = message.get_status();
    if (status === Soup.Status.UNAUTHORIZED)
        throw new SourceError('Session expired — run `claude auth login`');

    // Rate-limit headers are present even on 429, so parse regardless of status.
    const responseHeaders = message.get_response_headers();
    const now = nowSecs();
    const usage = parseClaudeHeaders(name => responseHeaders.get_one(name), now);
    if (!usage)
        throw new SourceError(`Couldn't read rate limits (HTTP ${status})`);
    return {...usage, plan, dataAt: now};
}

// ── Codex ────────────────────────────────────────────────────────────────────

const FILE_ATTRS = 'standard::name,standard::type,time::modified';

async function newestJsonl(dir, cancellable) {
    let enumerator;
    try {
        enumerator = await dir.enumerate_children_async(
            FILE_ATTRS, Gio.FileQueryInfoFlags.NOFOLLOW_SYMLINKS, GLib.PRIORITY_LOW, cancellable);
    } catch (e) {
        if (e.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
            throw e;
        return null;
    }

    let best = null;
    const consider = candidate => {
        if (candidate && (!best || candidate.mtime > best.mtime))
            best = candidate;
    };
    for (;;) {
        const infos = await enumerator.next_files_async(ENUMERATE_BATCH, GLib.PRIORITY_LOW, cancellable);
        if (infos.length === 0)
            break;
        for (const info of infos) {
            const child = dir.get_child(info.get_name());
            if (info.get_file_type() === Gio.FileType.DIRECTORY)
                consider(await newestJsonl(child, cancellable));
            else if (info.get_name().endsWith('.jsonl'))
                consider({file: child, mtime: info.get_modification_date_time().to_unix()});
        }
    }
    return best;
}

async function readTail(file, cancellable) {
    const info = await file.query_info_async(
        'standard::size', Gio.FileQueryInfoFlags.NONE, GLib.PRIORITY_LOW, cancellable);
    const size = info.get_size();
    const stream = await file.read_async(GLib.PRIORITY_LOW, cancellable);
    try {
        const offset = Math.max(0, size - CODEX_TAIL_BYTES);
        stream.seek(offset, GLib.SeekType.SET, cancellable);
        const bytes = await stream.read_bytes_async(CODEX_TAIL_BYTES, GLib.PRIORITY_LOW, cancellable);
        return {text: decoder.decode(bytes.toArray()), complete: offset === 0};
    } finally {
        stream.close(null);
    }
}

function lastCodexEvent(text, now) {
    const lines = text.split('\n');
    for (let i = lines.length - 1; i >= 0; i--) {
        if (!lines[i].includes('rate_limits'))
            continue;
        const usage = parseCodexLine(lines[i], now);
        if (usage)
            return usage;
    }
    return null;
}

export async function fetchCodex(cancellable) {
    const sessionsDir = Gio.File.new_for_path(GLib.build_filenamev([HOME, '.codex', 'sessions']));
    const newest = await newestJsonl(sessionsDir, cancellable);
    if (!newest)
        throw new SourceError('No Codex session log found (~/.codex/sessions)');

    const now = nowSecs();
    const tail = await readTail(newest.file, cancellable);
    let usage = lastCodexEvent(tail.text, now);
    if (!usage && !tail.complete)
        usage = lastCodexEvent(await readText(newest.file, cancellable), now);
    if (!usage)
        throw new SourceError('Latest Codex session has no rate-limit data');

    return {...usage, dataAt: newest.mtime, live: now - newest.mtime <= CODEX_LIVE_WINDOW_SECS};
}

// ── Liveness ─────────────────────────────────────────────────────────────────

/** True while a `claude` process runs (exact name match, so paths containing "claude" don't count). */
export async function isClaudeRunning(cancellable) {
    const proc = Gio.Subprocess.new(
        ['pgrep', '-x', 'claude'],
        Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_SILENCE);
    try {
        await proc.wait_check_async(cancellable);
        return true;
    } catch (e) {
        if (e.matches?.(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
            throw e;
        return false;
    }
}
