use std::{
    fs,
    io::{BufRead, BufReader, Read, Write},
    net::{TcpListener, TcpStream},
    path::PathBuf,
    process::{Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc, Mutex,
    },
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tiny_skia::*;

// ── Colors ───────────────────────────────────────────────────────────────────

fn percent_color(pct: i32) -> (u8, u8, u8) {
    match pct {
        85.. => (220, 50, 50),
        70.. => (230, 130, 40),
        55.. => (200, 180, 40),
        _ => (60, 180, 80),
    }
}

// ── Icon rendering ───────────────────────────────────────────────────────────

fn arc_path(cx: f32, cy: f32, r: f32, start: f32, sweep: f32) -> Option<Path> {
    if sweep.abs() < 0.001 {
        return None;
    }
    const STEPS: usize = 64;
    let mut pb = PathBuilder::new();
    for i in 0..=STEPS {
        let a = start + (i as f32 / STEPS as f32) * sweep;
        let (x, y) = (cx + r * a.cos(), cy + r * a.sin());
        if i == 0 {
            pb.move_to(x, y);
        } else {
            pb.line_to(x, y);
        }
    }
    pb.finish()
}

/// Returns ARGB data (network byte order) for the ksni StatusNotifierItem icon.
fn render_icon(session_pct: i32, weekly_pct: i32, blocked: bool, pulse: f32) -> Vec<u8> {
    const S: u32 = 64;
    const CX: f32 = 32.0;
    const CY: f32 = 32.0;
    const OUTER_R: f32 = 27.5;
    const RING_W: f32 = 4.5;
    const INNER_R: f32 = OUTER_R - RING_W - 2.5;

    let mut pm = Pixmap::new(S, S).unwrap();
    let mut paint = Paint::default();
    paint.anti_alias = true;
    let mut stroke = Stroke::default();
    stroke.width = RING_W;
    stroke.line_cap = LineCap::Round;

    // Background ring
    if let Some(p) = arc_path(CX, CY, OUTER_R - RING_W / 2.0, 0.0, std::f32::consts::TAU) {
        paint.set_color_rgba8(150, 150, 150, 65);
        pm.stroke_path(&p, &paint, &stroke, Transform::identity(), None);
    }

    // Session arc: top (−π/2) → clockwise
    if session_pct > 0 {
        let (r, g, b) = if blocked { (220, 50, 50) } else { percent_color(session_pct) };
        let sweep = (session_pct.min(100) as f32 / 100.0) * std::f32::consts::TAU;
        if let Some(p) = arc_path(CX, CY, OUTER_R - RING_W / 2.0, -std::f32::consts::FRAC_PI_2, sweep) {
            paint.set_color_rgba8(r, g, b, 255);
            pm.stroke_path(&p, &paint, &stroke, Transform::identity(), None);
        }
    }

    // Inner circle background
    let inner_circle = PathBuilder::from_circle(CX, CY, INNER_R).unwrap();
    paint.set_color_rgba8(150, 150, 150, 45);
    pm.fill_path(&inner_circle, &paint, FillRule::Winding, Transform::identity(), None);

    // Weekly fill: bottom → top, clipped to inner circle
    if weekly_pct > 0 {
        let (r, g, b) = if blocked { (220, 50, 50) } else { percent_color(weekly_pct) };
        let fill_h = INNER_R * 2.0 * (weekly_pct.min(100) as f32 / 100.0);
        let fill_top = CY + INNER_R - fill_h;

        if let Some(rect) = Rect::from_xywh(CX - INNER_R, fill_top, INNER_R * 2.0, fill_h + 0.5) {
            let fill_path = PathBuilder::from_rect(rect);
            if let Some(mut clip) = Mask::new(S, S) {
                clip.fill_path(
                    &inner_circle,
                    FillRule::Winding,
                    true,
                    Transform::identity(),
                );
                paint.set_color_rgba8(r, g, b, 195);
                pm.fill_path(&fill_path, &paint, FillRule::Winding, Transform::identity(), Some(&clip));
            }
        }
    }

    // Pulsing live dot (top-right corner)
    if pulse > 0.01 {
        if let Some(dot) = PathBuilder::from_circle(S as f32 - 7.0, 7.0, 4.0) {
            paint.set_color_rgba8(0xD9, 0x77, 0x57, (pulse * 255.0) as u8);
            pm.fill_path(&dot, &paint, FillRule::Winding, Transform::identity(), None);
        }
    }

    // tiny-skia premultiplied RGBA → straight ARGB (network byte order for D-Bus)
    pm.data()
        .chunks(4)
        .flat_map(|p| {
            let a = p[3];
            if a == 0 {
                return [0u8, 0, 0, 0];
            }
            let af = a as f32 / 255.0;
            [
                a,
                (p[0] as f32 / af).min(255.0) as u8,
                (p[1] as f32 / af).min(255.0) as u8,
                (p[2] as f32 / af).min(255.0) as u8,
            ]
        })
        .collect()
}

// ── Usage data ───────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Provider {
    Claude,
    Codex,
}

impl Provider {
    fn name(self) -> &'static str {
        match self {
            Provider::Claude => "Claude Code",
            Provider::Codex => "Codex",
        }
    }

    fn process_pattern(self) -> &'static str {
        match self {
            Provider::Claude => "claude",
            Provider::Codex => "codex",
        }
    }
}

#[derive(Debug, Clone)]
struct UsageData {
    provider: Provider,
    five_h_util: f32,
    five_h_reset: i64,
    seven_d_util: f32,
    seven_d_reset: i64,
    overage_util: f32,
    claim: String,
    status: String,
    source: String,
    plan: String,
    fetched_at: i64,
    /// When the usage report was fetched from the provider.
    data_at: i64,
}

/// A window whose reset time has passed has been refilled, whatever the last report said.
fn window_pct(util: f32, reset_at: i64, now: i64) -> i32 {
    if reset_at <= now { 0 } else { (util * 100.0) as i32 }
}

impl UsageData {
    fn five_h_pct(&self) -> i32 { window_pct(self.five_h_util, self.five_h_reset, self.fetched_at) }
    fn seven_d_pct(&self) -> i32 { window_pct(self.seven_d_util, self.seven_d_reset, self.fetched_at) }
    fn overage_pct(&self) -> i32 { (self.overage_util * 100.0) as i32 }
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

#[derive(Debug, Clone)]
struct ClaudeCredentials {
    token: String,
    plan: String,
    /// OAuth tokens authenticate as a bearer token; the legacy token file is sent as an API key.
    is_oauth: bool,
}

/// e.g. subscriptionType "max" + rateLimitTier "default_claude_max_5x" -> "max 5x".
fn parse_credentials(text: &str) -> Option<ClaudeCredentials> {
    let value: serde_json::Value = serde_json::from_str(text).ok()?;
    let oauth = value.get("claudeAiOauth")?;
    let token = oauth.get("accessToken")?.as_str()?.trim();
    if token.is_empty() {
        return None;
    }

    let kind = oauth.get("subscriptionType").and_then(|v| v.as_str()).unwrap_or("");
    let tier = oauth
        .get("rateLimitTier")
        .and_then(|v| v.as_str())
        .and_then(|t| t.rsplit('_').next())
        .filter(|t| {
            t.strip_suffix('x')
                .is_some_and(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()))
        })
        .unwrap_or("");
    let plan = [kind, tier]
        .iter()
        .filter(|part| !part.is_empty())
        .copied()
        .collect::<Vec<_>>()
        .join(" ");

    Some(ClaudeCredentials { token: token.to_owned(), plan, is_oauth: true })
}

fn get_claude_credentials() -> Option<ClaudeCredentials> {
    let claude_dir = PathBuf::from(std::env::var("HOME").ok()?).join(".claude");
    if let Some(creds) = fs::read_to_string(claude_dir.join(".credentials.json"))
        .ok()
        .and_then(|text| parse_credentials(&text))
    {
        return Some(creds);
    }

    // Legacy plain-text token file written by the macOS/KDE install steps.
    let token = fs::read_to_string(claude_dir.join("claude-menubar-token"))
        .ok()?
        .trim()
        .to_owned();
    if token.is_empty() {
        None
    } else {
        Some(ClaudeCredentials { token, plan: String::new(), is_oauth: false })
    }
}

fn hdr_f32(resp: &ureq::Response, key: &str) -> Option<f32> {
    resp.header(key)?.parse().ok()
}

fn hdr_i64(resp: &ureq::Response, key: &str) -> Option<i64> {
    resp.header(key)?.parse().ok()
}

fn parse_headers(resp: &ureq::Response) -> Option<UsageData> {
    let now = now_secs();
    Some(UsageData {
        provider: Provider::Claude,
        five_h_util: hdr_f32(resp, "anthropic-ratelimit-unified-5h-utilization")?,
        five_h_reset: hdr_i64(resp, "anthropic-ratelimit-unified-5h-reset").unwrap_or(now + 1),
        seven_d_util: hdr_f32(resp, "anthropic-ratelimit-unified-7d-utilization")?,
        seven_d_reset: hdr_i64(resp, "anthropic-ratelimit-unified-7d-reset").unwrap_or(now + 1),
        overage_util: hdr_f32(resp, "anthropic-ratelimit-unified-overage-utilization").unwrap_or(0.0),
        claim: resp
            .header("anthropic-ratelimit-unified-representative-claim")
            .unwrap_or("")
            .into(),
        status: resp
            .header("anthropic-ratelimit-unified-status")
            .unwrap_or("unknown")
            .into(),
        source: "Anthropic rate-limit headers".into(),
        plan: String::new(),
        fetched_at: now,
        data_at: now,
    })
}

const HTTP_TIMEOUT_SECS: u64 = 20;

fn fetch_claude_usage(creds: &ClaudeCredentials) -> Result<UsageData, String> {
    let body = serde_json::json!({
        "model": "claude-haiku-4-5-20251001",
        "max_tokens": 1,
        "messages": [{"role": "user", "content": "."}]
    });

    // Never follow a redirect with the token attached.
    let agent = ureq::AgentBuilder::new()
        .redirects(0)
        .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS))
        .build();
    let request = agent
        .post("https://api.anthropic.com/v1/messages")
        .set("anthropic-version", "2023-06-01")
        .set("content-type", "application/json");
    let request = if creds.is_oauth {
        request
            .set("authorization", &format!("Bearer {}", creds.token))
            .set("anthropic-beta", "oauth-2025-04-20")
    } else {
        request.set("x-api-key", &creds.token)
    };
    let result = request.send_json(body);

    let resp = match result {
        Ok(r) => r,
        Err(ureq::Error::Status(401, _)) => {
            return Err("Auth expired — run: claude auth login".into())
        }
        Err(ureq::Error::Status(_, r)) => r,
        Err(e) => return Err(e.to_string()),
    };

    let usage = parse_headers(&resp).ok_or_else(|| "Rate limit headers not found".to_string())?;
    Ok(UsageData { plan: creds.plan.clone(), ..usage })
}

/// Select only the ordinary Codex quota for the account resolved by Codex itself.
fn parse_codex_limits(result: &serde_json::Value) -> Result<UsageData, String> {
    let limits = if let Some(buckets) = result.get("rateLimitsByLimitId").filter(|v| !v.is_null()) {
        buckets.get("codex")
    } else {
        result.get("rateLimits").filter(|v| {
            v.get("limitId").and_then(|id| id.as_str()).is_none_or(|id| id == "codex")
        })
    }.ok_or("Default Codex account has no ordinary Codex quota")?;
    let primary = limits.get("primary").ok_or("Codex returned no primary quota")?;
    let primary_used = primary.get("usedPercent").and_then(|v| v.as_f64())
        .ok_or("Codex returned invalid quota usage")? as f32;
    let primary_reset = primary.get("resetsAt").and_then(|v| v.as_i64())
        .ok_or("Codex returned invalid quota reset")?;
    let secondary = limits.get("secondary").filter(|v| !v.is_null());
    let secondary_used = secondary.and_then(|v| v.get("usedPercent"))
        .and_then(|v| v.as_f64()).unwrap_or(0.0) as f32;
    let secondary_reset = secondary.and_then(|v| v.get("resetsAt"))
        .and_then(|v| v.as_i64()).unwrap_or(0);
    let reached = limits.get("rateLimitReachedType").is_some_and(|v| !v.is_null());
    let now = now_secs();
    Ok(UsageData {
        provider: Provider::Codex,
        five_h_util: primary_used / 100.0,
        five_h_reset: primary_reset,
        seven_d_util: secondary_used / 100.0,
        seven_d_reset: secondary_reset,
        overage_util: 0.0,
        claim: if primary_used >= secondary_used { "five_hour" } else { "seven_day" }.into(),
        status: if reached { "blocked" } else { "allowed" }.into(),
        source: "Codex default account — account/rateLimits/read (codex quota)".into(),
        plan: limits.get("planType").and_then(|v| v.as_str()).unwrap_or("").into(),
        fetched_at: now,
        data_at: now,
    })
}

fn read_codex_rpc(
    input: &mut impl Write,
    output: &mut impl BufRead,
    request: serde_json::Value,
) -> Result<serde_json::Value, String> {
    let id = request["id"].clone();
    writeln!(input, "{}", request).and_then(|_| input.flush())
        .map_err(|_| "Could not send Codex quota request".to_string())?;
    let mut line = String::new();
    loop {
        line.clear();
        if output.read_line(&mut line).map_err(|_| "Could not read Codex response")? == 0 {
            return Err("Codex closed the quota connection".into());
        }
        let Ok(response) = serde_json::from_str::<serde_json::Value>(&line) else { continue };
        if response.get("id") != Some(&id) { continue; }
        // Do not expose raw RPC errors, which may contain account details.
        return response.get("result").cloned()
            .ok_or("Codex quota request failed — check the default Codex login".into());
    }
}

fn fetch_codex_usage() -> Result<UsageData, String> {
    // Codex resolves CODEX_HOME, its credential store and default account. No session
    // logs or credentials are read by this helper, and no inference turn is started.
    let spawn = |executable: PathBuf| {
        Command::new(executable).args(["app-server", "--listen", "stdio://"])
            .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn()
    };
    // Desktop shells may omit ~/.local/bin from PATH, even when the CLI is installed there.
    // Keep PATH's selected Codex first so the user's CLI/account configuration is respected.
    let mut child = spawn(PathBuf::from("codex")).or_else(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            if let Some(home) = std::env::var_os("HOME") {
                return spawn(PathBuf::from(home).join(".local/bin/codex"));
            }
        }
        Err(error)
    }).map_err(|_| "Could not start codex — install it on PATH or in ~/.local/bin".to_string())?;
    let mut input = child.stdin.take().unwrap();
    let mut output = BufReader::new(child.stdout.take().unwrap());
    let (tx, rx) = mpsc::channel();
    let reader = thread::spawn(move || {
        let result = (|| {
            read_codex_rpc(&mut input, &mut output, serde_json::json!({
                "id": 1, "method": "initialize", "params": {
                    "clientInfo": {"name": "ai_limit_counter", "version": env!("CARGO_PKG_VERSION")}
                }
            }))?;
            writeln!(input, "{}", serde_json::json!({"method": "initialized"}))
                .map_err(|_| "Could not initialize Codex quota connection".to_string())?;
            let result = read_codex_rpc(&mut input, &mut output, serde_json::json!({
                "id": 2, "method": "account/rateLimits/read"
            }))?;
            parse_codex_limits(&result)
        })();
        let _ = tx.send(result);
    });
    let result = rx.recv_timeout(Duration::from_secs(20))
        .unwrap_or_else(|_| Err("Codex quota request timed out".into()));
    // Also unblock the reader on a timeout and reap the child on every exit path.
    let _ = child.kill();
    let _ = child.wait();
    let _ = reader.join();
    result
}

fn fetch_usage(provider: Provider) -> Result<UsageData, String> {
    match provider {
        Provider::Claude => match get_claude_credentials() {
            Some(creds) => fetch_claude_usage(&creds),
            None => Err("Token not found. Run: claude auth login".into()),
        },
        Provider::Codex => fetch_codex_usage(),
    }
}

fn default_provider() -> Provider {
    if get_claude_credentials().is_some() {
        Provider::Claude
    } else {
        Provider::Codex
    }
}

fn usage_json(provider: Provider) -> serde_json::Value {
    match fetch_usage(provider) {
        Ok(u) => serde_json::json!({
            "provider": u.provider.name(),
            "five_h_pct": u.five_h_pct(),
            "five_h_reset": u.five_h_reset,
            "seven_d_pct": u.seven_d_pct(),
            "seven_d_reset": u.seven_d_reset,
            "status": u.status,
            "source": u.source,
            "plan": u.plan,
            "fetched_at": u.fetched_at,
            "data_at": u.data_at,
            "is_live": is_provider_running(provider),
            "error": null,
        }),
        Err(error) => serde_json::json!({
            "provider": provider.name(),
            "is_live": is_provider_running(provider),
            "error": error,
        }),
    }
}

fn print_usage_json(provider: Provider) {
    println!("{}", usage_json(provider));
}

fn serve_connection(mut stream: TcpStream, provider: Provider) {
    let mut request = [0u8; 2048];
    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
    if stream.read(&mut request).is_err() {
        return;
    }

    let body = usage_json(provider).to_string();
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    );
    let _ = stream.write_all(response.as_bytes());
}

fn run_status_server(provider: Provider) -> std::io::Result<()> {
    let listener = TcpListener::bind("127.0.0.1:38465")?;
    for stream in listener.incoming().flatten() {
        serve_connection(stream, provider);
    }
    Ok(())
}

// ── Helpers ──────────────────────────────────────────────────────────────────

fn bar(pct: i32) -> String {
    let n = pct.clamp(0, 100) / 5;
    format!("[{}{}]", "█".repeat(n as usize), "░".repeat((20 - n) as usize))
}

fn rel_time(ts: i64) -> String {
    let diff = ts - now_secs();
    if diff <= 0 {
        return "now".into();
    }
    let (h, m) = (diff / 3600, (diff % 3600) / 60);
    if h > 0 {
        format!("in {}h {}m", h, m)
    } else {
        format!("in {}m", m)
    }
}

fn is_provider_running(provider: Provider) -> bool {
    std::process::Command::new("pgrep")
        .args(["-f", provider.process_pattern()])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

// ── Tray ─────────────────────────────────────────────────────────────────────

struct ClaudeTray {
    provider: Provider,
    usage: Option<UsageData>,
    error: Option<String>,
    is_live: bool,
    pulse: f32,
    pulse_dir: f32,
    refresh_tx: mpsc::SyncSender<()>,
    provider_state: Arc<Mutex<Provider>>,
}

impl ksni::Tray for ClaudeTray {
    fn id(&self) -> String {
        "ai-limit-counter".into()
    }

    fn category(&self) -> ksni::Category {
        ksni::Category::ApplicationStatus
    }

    fn title(&self) -> String {
        match &self.usage {
            Some(u) => format!(
                "{} {}%/{}%",
                u.provider.name(),
                u.five_h_pct(),
                u.seven_d_pct()
            ),
            None => format!("{} MenuBar", self.provider.name()),
        }
    }

    fn icon_pixmap(&self) -> Vec<ksni::Icon> {
        let (s5, s7, blocked) = match &self.usage {
            Some(u) => (u.five_h_pct(), u.seven_d_pct(), u.status != "allowed"),
            None => (0, 0, false),
        };
        let pulse = if self.is_live { self.pulse } else { 0.0 };
        vec![ksni::Icon {
            width: 64,
            height: 64,
            data: render_icon(s5, s7, blocked, pulse),
        }]
    }

    fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
        use ksni::menu::StandardItem;

        let disabled = |label: String| -> ksni::MenuItem<Self> {
            StandardItem {
                label,
                enabled: false,
                ..Default::default()
            }
            .into()
        };

        let mut items: Vec<ksni::MenuItem<Self>> = vec![];

        items.push(disabled("Provider".into()));
        for provider in [Provider::Claude, Provider::Codex] {
            let provider_state = Arc::clone(&self.provider_state);
            items.push(
                StandardItem {
                    label: format!(
                        "{} {}",
                        if self.provider == provider { "✓" } else { " " },
                        provider.name()
                    ),
                    activate: Box::new(move |this: &mut Self| {
                        this.provider = provider;
                        this.usage = None;
                        this.error = None;
                        if let Ok(mut selected) = provider_state.lock() {
                            *selected = provider;
                        }
                        let _ = this.refresh_tx.try_send(());
                    }),
                    ..Default::default()
                }
                .into(),
            );
        }
        items.push(ksni::MenuItem::Separator);

        items.push(disabled(if self.is_live {
            format!("● {} is running", self.provider.name())
        } else {
            format!("○ {} is idle", self.provider.name())
        }));
        items.push(ksni::MenuItem::Separator);

        match &self.usage {
            Some(u) => {
                items.push(disabled(if u.status == "allowed" {
                    "✅ Allowed".into()
                } else {
                    "🔴 Blocked".into()
                }));
                items.push(ksni::MenuItem::Separator);

                let a5 = if u.claim == "five_hour" { " ◀" } else { "" };
                items.push(disabled(format!(
                    "5h  {} {}%{}",
                    bar(u.five_h_pct()),
                    u.five_h_pct(),
                    a5
                )));
                items.push(disabled(format!("    Reset: {}", rel_time(u.five_h_reset))));
                items.push(ksni::MenuItem::Separator);

                let a7 = if u.claim == "seven_day" { " ◀" } else { "" };
                items.push(disabled(format!(
                    "7d  {} {}%{}",
                    bar(u.seven_d_pct()),
                    u.seven_d_pct(),
                    a7
                )));
                items.push(disabled(format!("    Reset: {}", rel_time(u.seven_d_reset))));

                if u.overage_pct() > 0 {
                    items.push(ksni::MenuItem::Separator);
                    items.push(disabled(format!(
                        "Ovg {} {}%",
                        bar(u.overage_pct()),
                        u.overage_pct()
                    )));
                }

                items.push(ksni::MenuItem::Separator);
                let ago = now_secs() - u.fetched_at;
                items.push(disabled(if ago < 60 {
                    format!("Updated: {}s ago", ago)
                } else {
                    format!("Updated: {}m ago", ago / 60)
                }));
                items.push(disabled(format!("Source: {}", u.source)));
            }
            None => {
                items.push(disabled(match &self.error {
                    Some(e) => format!("⚠ {}", e),
                    None => "Fetching...".into(),
                }));
            }
        }

        items.push(ksni::MenuItem::Separator);
        items.push(
            StandardItem {
                label: "Refresh Now".into(),
                activate: Box::new(|this: &mut Self| {
                    let _ = this.refresh_tx.try_send(());
                }),
                ..Default::default()
            }
            .into(),
        );
        items.push(ksni::MenuItem::Separator);
        items.push(
            StandardItem {
                label: "Quit".into(),
                activate: Box::new(|_| std::process::exit(0)),
                ..Default::default()
            }
            .into(),
        );

        items
    }
}

// ── Main ─────────────────────────────────────────────────────────────────────

fn fetch_and_update(handle: &ksni::Handle<ClaudeTray>, provider: Provider) {
    let result = fetch_usage(provider);
    handle.update(move |t| match result {
        Ok(u) => {
            t.provider = provider;
            t.usage = Some(u);
            t.error = None;
        }
        Err(e) => {
            t.error = Some(e);
        }
    });
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).is_some_and(|arg| arg == "--json") {
        let provider = match args.get(2).map(String::as_str) {
            Some("claude") => Provider::Claude,
            Some("codex") => Provider::Codex,
            _ => default_provider(),
        };
        print_usage_json(provider);
        return;
    }
    if args.get(1).is_some_and(|arg| arg == "--server") {
        if let Err(error) = run_status_server(default_provider()) {
            eprintln!("AI Limit Counter status server failed: {error}");
            std::process::exit(1);
        }
        return;
    }

    let (refresh_tx, refresh_rx) = mpsc::sync_channel::<()>(1);
    let initial_provider = default_provider();
    let provider_state = Arc::new(Mutex::new(initial_provider));

    let service = ksni::TrayService::new(ClaudeTray {
        provider: initial_provider,
        usage: None,
        error: None,
        is_live: false,
        pulse: 1.0,
        pulse_dir: -1.0,
        refresh_tx,
        provider_state: Arc::clone(&provider_state),
    });
    let handle = service.handle();
    service.spawn();

    let is_live_flag = Arc::new(AtomicBool::new(false));

    // Initial fetch
    {
        let h = handle.clone();
        let provider_state = Arc::clone(&provider_state);
        thread::spawn(move || {
            let provider = provider_state.lock().map(|p| *p).unwrap_or(Provider::Claude);
            fetch_and_update(&h, provider);
        });
    }

    // Refresh loop: fires on timer OR manual "Refresh Now"
    {
        let h = handle.clone();
        let live_flag = Arc::clone(&is_live_flag);
        let provider_state = Arc::clone(&provider_state);
        thread::spawn(move || loop {
            let secs = if live_flag.load(Ordering::Relaxed) { 60 } else { 300 };
            match refresh_rx.recv_timeout(Duration::from_secs(secs)) {
                Ok(()) | Err(mpsc::RecvTimeoutError::Timeout) => {
                    let provider = provider_state
                        .lock()
                        .map(|p| *p)
                        .unwrap_or(Provider::Claude);
                    fetch_and_update(&h, provider);
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
        });
    }

    // Process check loop: detect active claude sessions
    {
        let h = handle.clone();
        let live_flag = Arc::clone(&is_live_flag);
        let provider_state = Arc::clone(&provider_state);
        thread::spawn(move || loop {
            let provider = provider_state.lock().map(|p| *p).unwrap_or(Provider::Claude);
            let live = is_provider_running(provider);
            live_flag.store(live, Ordering::Relaxed);
            h.update(move |t| {
                t.provider = provider;
                if !live && t.is_live {
                    t.pulse = 1.0;
                }
                t.is_live = live;
            });
            thread::sleep(Duration::from_secs(3));
        });
    }

    // Pulse animation loop (~15 fps while live)
    {
        let h = handle.clone();
        thread::spawn(move || loop {
            h.update(|t| {
                if t.is_live {
                    t.pulse += t.pulse_dir * 0.04;
                    if t.pulse <= 0.3 {
                        t.pulse = 0.3;
                        t.pulse_dir = 1.0;
                    } else if t.pulse >= 1.0 {
                        t.pulse = 1.0;
                        t.pulse_dir = -1.0;
                    }
                }
            });
            thread::sleep(Duration::from_millis(70));
        });
    }

    loop {
        thread::sleep(Duration::from_secs(3600));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const OAUTH_JSON: &str = r#"{"claudeAiOauth":{"accessToken":" tok-123 ","subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}"#;

    #[test]
    fn parses_token_and_plan_from_credentials_json() {
        let creds = parse_credentials(OAUTH_JSON).expect("credentials");
        assert_eq!(creds.token, "tok-123");
        assert_eq!(creds.plan, "max 5x");
        assert!(creds.is_oauth);
    }

    #[test]
    fn plan_omits_tier_when_it_has_no_multiplier() {
        let text = r#"{"claudeAiOauth":{"accessToken":"t","subscriptionType":"pro","rateLimitTier":"default_claude_ai"}}"#;
        assert_eq!(parse_credentials(text).expect("credentials").plan, "pro");
    }

    #[test]
    fn rejects_credentials_without_a_token() {
        assert!(parse_credentials(r#"{"claudeAiOauth":{"accessToken":"  "}}"#).is_none());
        assert!(parse_credentials(r#"{"other":{}}"#).is_none());
        assert!(parse_credentials("not json").is_none());
    }

    #[test]
    fn window_that_already_reset_reports_zero() {
        assert_eq!(window_pct(0.94, 1_000, 1_000), 0);
        assert_eq!(window_pct(0.94, 999, 1_000), 0);
    }

    #[test]
    fn window_still_open_reports_its_utilization() {
        assert_eq!(window_pct(0.94, 1_001, 1_000), 94);
        assert_eq!(window_pct(0.0, 1_001, 1_000), 0);
    }

    fn quota(id: &str, used: i32) -> serde_json::Value {
        serde_json::json!({"limitId": id, "primary": {"usedPercent": used, "resetsAt": 2000},
            "secondary": {"usedPercent": 14, "resetsAt": 9000}, "planType": "plus"})
    }

    #[test]
    fn ordinary_quota_wins_over_reserve_and_legacy_bucket() {
        let result = serde_json::json!({"rateLimits": quota("base_model_inference", 0),
            "rateLimitsByLimitId": {"base_model_inference": quota("base_model_inference", 0),
                "codex": quota("codex", 88)}});
        let usage = parse_codex_limits(&result).unwrap();
        assert_eq!(window_pct(usage.five_h_util, usage.five_h_reset, 1000), 88);
        assert_eq!(window_pct(usage.seven_d_util, usage.seven_d_reset, 1000), 14);
        assert_eq!(usage.plan, "plus");
        assert_eq!(usage.data_at, usage.fetched_at);
        assert_eq!(usage.status, "allowed");
    }

    #[test]
    fn reserve_only_response_is_not_a_codex_quota() {
        let reserve = quota("base_model_inference", 0);
        assert!(parse_codex_limits(&serde_json::json!({"rateLimits": reserve})).is_err());
        assert!(parse_codex_limits(&serde_json::json!({"rateLimits": quota("codex", 88),
            "rateLimitsByLimitId": {"base_model_inference": reserve}})).is_err());
    }

    #[test]
    fn legacy_response_and_blocked_status_are_supported() {
        let mut limits = quota("codex", 100);
        limits["rateLimitReachedType"] = serde_json::json!("primary");
        let usage = parse_codex_limits(&serde_json::json!({"rateLimits": limits})).unwrap();
        assert_eq!(usage.status, "blocked");
        assert!(parse_codex_limits(&serde_json::json!({})).is_err());
    }

    #[test]
    fn rpc_ignores_notifications_and_unrelated_responses() {
        let mut input = Vec::new();
        let mut output = std::io::Cursor::new(
            b"{\"method\":\"account/updated\"}\n{\"id\":7,\"result\":{}}\n{\"id\":2,\"result\":{\"ok\":true}}\n");
        let result = read_codex_rpc(&mut input, &mut output,
            serde_json::json!({"id": 2, "method": "account/rateLimits/read"})).unwrap();
        assert_eq!(result["ok"], true);
    }
}
