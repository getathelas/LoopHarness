//
//  BundledSkillSeeds.swift
//  Loop
//
//  Seeds the Workspace/Skills folder with starter skills on first launch.
//
//  We don't ship .js files as bundle resources — instead each seed's source is
//  a Swift string literal here, written into the workspace on first launch.
//  Keeps the file layout in the Xcode project trivial and avoids resource-
//  copy build phases.
//
//  Add a starter skill by appending a `Seed` to `all`.
//

import Foundation

enum BundledSkillSeeds {

    /// One bundled skill: name, manifest description + parameter schema,
    /// and the literal JS source. Add new entries to `all` to ship starters.
    struct Seed {
        let name: String
        let description: String
        let parameters: [String: Any]
        let source: String
    }

    /// Run on AgentHarness init. For each seed, write it into the workspace
    /// only if the folder doesn't already exist — so user edits / deletions
    /// stick across launches and we never clobber custom changes.
    static func seedIfNeeded() {
        let registry = DynamicSkillRegistry.shared
        let fm = FileManager.default
        let root = registry.skillsRoot

        for seed in all {
            let folder = root.appendingPathComponent(seed.name, isDirectory: true)
            if fm.fileExists(atPath: folder.path) { continue }
            do {
                _ = try registry.writeSkill(
                    name: seed.name,
                    description: seed.description,
                    parameters: seed.parameters,
                    source: seed.source
                )
                print("BundledSkillSeeds: seeded \(seed.name)")
            } catch {
                print("BundledSkillSeeds: failed to seed \(seed.name) — \(error)")
            }
        }

        migrateLegacyPodsipsEndpoint()
    }

    /// One-time repair for devices that seeded the original `podsips_search`,
    /// which hit the wrong `/api/v1/search` path and 404s. `seedIfNeeded` never
    /// overwrites an existing skill (so user edits stick), so those copies stay
    /// broken forever. Rewrite the skill from the current seed — but ONLY when
    /// the installed source still carries the bad path, so a user who hand-fixed
    /// or repurposed the skill is left untouched.
    private static func migrateLegacyPodsipsEndpoint() {
        let registry = DynamicSkillRegistry.shared
        let safeName = DynamicSkillRegistry.sanitize(podsipsSearch.name)
        let scriptURL = registry.skillsRoot
            .appendingPathComponent(safeName, isDirectory: true)
            .appendingPathComponent("skill.js")

        // Pull it out of iCloud if it's only a placeholder locally, then read.
        try? Workspace.shared.ensureDownloaded(scriptURL)
        guard let installed = try? String(contentsOf: scriptURL, encoding: .utf8),
              installed.contains("/api/v1/search") else { return }

        do {
            _ = try registry.writeSkill(
                name: podsipsSearch.name,
                description: podsipsSearch.description,
                parameters: podsipsSearch.parameters,
                source: podsipsSearch.source
            )
            print("BundledSkillSeeds: migrated podsips_search to /public/v1 endpoint")
        } catch {
            print("BundledSkillSeeds: failed to migrate podsips_search — \(error)")
        }
    }

    static let all: [Seed] = [polymarketTrending, runSSHCommand, claudeCode, podsipsSearch]

    // MARK: - Polymarket

    /// Hits Gamma — Polymarket's public REST API for market data — pulls the
    /// top markets by 24h volume, and composes a short summary that doubles
    /// as a snapshot of what the world is currently betting on. No auth
    /// required.
    private static let polymarketTrending = Seed(
        name: "polymarket_trending",
        description: "Fetch the top trending Polymarket markets and summarize the major events the world is currently betting on.",
        parameters: [
            "type": "object",
            "properties": [
                "limit": [
                    "type": "integer",
                    "description": "How many trending markets to summarize. Defaults to 8."
                ]
            ],
            "required": [String]()
        ],
        source: #"""
        // Polymarket trending markets → world-events digest.
        //
        // The Gamma API at https://gamma-api.polymarket.com/markets is a
        // public, unauthenticated JSON endpoint. We sort by 24h volume to get
        // a feed of "what people are actually putting money on right now"
        // and turn that into a short summary the model can read back.
        async function run(args, host) {
            const limit = (args && args.limit) || 8;
            host.log("Fetching trending Polymarket markets...");

            const url = "https://gamma-api.polymarket.com/markets"
                + "?active=true&closed=false&order=volume24hr&ascending=false"
                + "&limit=" + encodeURIComponent(limit);

            const res = await host.http({
                url: url,
                method: "GET",
                headers: { "Accept": "application/json" }
            });

            if (res.status !== 200 || !res.json) {
                return {
                    status: "error",
                    error: "Polymarket Gamma returned HTTP " + res.status,
                    body: (res.body || "").slice(0, 500)
                };
            }

            const rows = Array.isArray(res.json) ? res.json : [];
            if (rows.length === 0) {
                return {
                    summary: "Polymarket returned no active markets — try again in a moment.",
                    markets: []
                };
            }

            host.log("Got " + rows.length + " markets, summarizing...");

            // Each market has a `question` and `outcomePrices` (array of JSON-
            // encoded probability strings). Pull the yes-price for the primary
            // outcome so we have a single number to talk about.
            const markets = rows.map(function(m) {
                let yes = null;
                try {
                    const prices = typeof m.outcomePrices === 'string'
                        ? JSON.parse(m.outcomePrices)
                        : (m.outcomePrices || []);
                    if (prices.length > 0) yes = parseFloat(prices[0]);
                } catch (e) {}
                return {
                    question: m.question || m.slug || "(untitled market)",
                    yes_probability: yes,
                    volume_24hr: m.volume24hr || 0,
                    end_date: m.endDate || null,
                    slug: m.slug || null
                };
            });

            const lines = markets.slice(0, limit).map(function(m, i) {
                const pct = (m.yes_probability != null)
                    ? Math.round(m.yes_probability * 100) + "%"
                    : "??";
                return (i + 1) + ". " + m.question + " — " + pct + " yes";
            });

            const summary =
                "Top " + lines.length + " markets by 24h volume:\n" + lines.join("\n");

            return {
                summary: summary,
                markets: markets,
                fetched_at: new Date().toISOString()
            };
        }
        """#
    )

    // MARK: - run_ssh_command

    /// Executes a shell command on a remote host via the HTTP-based SSH relay.
    /// Reads relay host/port/user from `host.getConfig(...)` so the user only
    /// configures the connection once in Settings → SSH.
    private static let runSSHCommand = Seed(
        name: "run_ssh_command",
        description: "Execute a shell command on the configured SSH relay host. Returns stdout, stderr, and exit_code.",
        parameters: [
            "type": "object",
            "properties": [
                "command": [
                    "type": "string",
                    "description": "The shell command to execute on the remote host."
                ],
                "session_id": [
                    "type": "string",
                    "description": "Optional session identifier for persistent sessions."
                ],
                "timeout_ms": [
                    "type": "integer",
                    "description": "Timeout in milliseconds (default: 30000)."
                ]
            ],
            "required": ["command"]
        ],
        source: #"""
        // run_ssh_command — execute a shell command via the SSH relay.
        //
        // Reads connection config from host.getConfig() so the relay
        // endpoint is configured once in Settings and shared across skills.
        async function run(args, host) {
            const command = args.command;
            if (!command) {
                return { status: "error", error: "The `command` argument is required." };
            }

            const relayHost = host.getConfig("ssh_relay_host");
            const relayPort = host.getConfig("ssh_relay_port") || "22";
            const relayUser = host.getConfig("ssh_relay_user");

            if (!relayHost || !relayUser) {
                return {
                    status: "error",
                    error: "SSH relay not configured. Set host and username in Settings → SSH."
                };
            }

            const timeoutMs = args.timeout_ms || 30000;
            const sessionId = args.session_id || "default";

            host.log("Running on " + relayUser + "@" + relayHost + ": " + command.slice(0, 60));

            // Use the native ssh_client tool via the relay — the HTTP bridge
            // at the relay host accepts POST /exec with command + session_id.
            var relayURL = "https://" + relayHost + "/exec";
            var payload = {
                command: command,
                session_id: sessionId,
                user: relayUser,
                timeout_ms: timeoutMs
            };

            try {
                var res = await host.http({
                    url: relayURL,
                    method: "POST",
                    json: payload
                });

                if (res.status === 200 && res.json) {
                    return {
                        status: "ok",
                        stdout: res.json.stdout || "",
                        stderr: res.json.stderr || "",
                        exit_code: res.json.exit_code != null ? res.json.exit_code : -1
                    };
                }

                return {
                    status: "error",
                    error: "Relay returned HTTP " + res.status,
                    detail: (res.body || "").slice(0, 500)
                };
            } catch (e) {
                return { status: "error", error: String(e) };
            }
        }
        """#
    )

    // MARK: - claude_code

    /// Dispatches a Claude Code session by composing `run_ssh_command`. Instead
    /// of duplicating SSH relay logic, this skill calls `run_ssh_command` via
    /// `host.callSkill`, demonstrating skill composition.
    private static let claudeCode = Seed(
        name: "claude_code",
        description: "Start or continue a Claude Code session on the remote SSH host. Sends a prompt to Claude Code CLI and returns its output.",
        parameters: [
            "type": "object",
            "properties": [
                "prompt": [
                    "type": "string",
                    "description": "The prompt or instruction to send to Claude Code."
                ],
                "session_id": [
                    "type": "string",
                    "description": "Optional session ID for persistent Claude Code sessions."
                ],
                "timeout_ms": [
                    "type": "integer",
                    "description": "Timeout in milliseconds (default: 60000)."
                ]
            ],
            "required": ["prompt"]
        ],
        source: #"""
        // claude_code — thin wrapper around run_ssh_command that constructs
        // a Claude Code CLI invocation. Uses host.callSkill for composition.
        async function run(args, host) {
            const prompt = args.prompt;
            if (!prompt) {
                return { status: "error", error: "The `prompt` argument is required." };
            }

            const sessionId = args.session_id || "claude-" + Date.now();
            const timeoutMs = args.timeout_ms || 60000;

            host.log("Dispatching to Claude Code...");

            // Construct the Claude Code CLI command. The prompt is passed via
            // stdin heredoc to avoid shell escaping issues.
            var escapedPrompt = prompt.replace(/'/g, "'\\''");
            var command = "claude --print '" + escapedPrompt + "'";

            try {
                var result = await host.callSkill("run_ssh_command", {
                    command: command,
                    session_id: sessionId,
                    timeout_ms: timeoutMs
                });

                if (result && result.status === "ok") {
                    return {
                        status: "ok",
                        summary: (result.stdout || "").slice(0, 2000),
                        stdout: result.stdout || "",
                        stderr: result.stderr || "",
                        exit_code: result.exit_code
                    };
                }

                return {
                    status: "error",
                    error: (result && result.error) || "run_ssh_command failed",
                    detail: result
                };
            } catch (e) {
                return { status: "error", error: String(e) };
            }
        }
        """#
    )

    // MARK: - PodSips Search

    /// Search podcast transcripts by topic via the PodSips API. Returns
    /// timestamped clips with speaker names, episode metadata, and context.
    private static let podsipsSearch = Seed(
        name: "podsips_search",
        description: "Search podcast transcripts by topic and get back timestamped clips with speaker names, episode metadata, and context. Powered by PodSips API.",
        parameters: [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "Natural-language topic or idea to search for across podcast transcripts (e.g. 'AI safety', 'founding lessons from Stripe', 'mental models for decision making')"
                ],
                "limit": [
                    "type": "integer",
                    "description": "Max number of results to return. Default 5."
                ]
            ],
            "required": ["query"]
        ],
        source: #"""
        // podsips_search — search podcast transcripts via PodSips API.
        //
        // Reads the PODSIPS_API_KEY from the Keychain via host.getApiKey and
        // hits the PodSips search endpoint for timestamped transcript clips.
        async function run(args, host) {
            const query = args.query;
            if (!query) {
                return { status: "error", error: "The `query` argument is required." };
            }

            const apiKey = host.getApiKey("podsips");
            if (!apiKey) {
                return {
                    status: "error",
                    error: "No PodSips API key configured. Add one in Settings → Keys → PodSips. Get a key at https://developer.podsips.com/"
                };
            }

            // API caps top_k at 50; our tool default is 5.
            const limit = (args.limit && args.limit > 0) ? Math.min(args.limit, 50) : 5;
            host.log("Searching podcasts for \"" + query + "\"...");

            // Public API lives under /public/v1 (NOT /api/v1). `top_k` bounds the
            // number of transcript chunks returned; results come back grouped by
            // episode. See https://developer.podsips.com/docs
            var url = "https://api.podsips.com/public/v1/search"
                + "?q=" + encodeURIComponent(query)
                + "&top_k=" + limit;

            // Render a seconds offset (e.g. 932.4) as "15:32" so clips are easy
            // to scrub to. Hours roll into the minutes field for long episodes.
            function fmtTime(secs) {
                if (typeof secs !== "number" || !isFinite(secs) || secs < 0) return "";
                var total = Math.floor(secs);
                var m = Math.floor(total / 60);
                var s = total % 60;
                return m + ":" + (s < 10 ? "0" + s : String(s));
            }

            try {
                var res = await host.http({
                    url: url,
                    method: "GET",
                    headers: {
                        "Authorization": "Bearer " + apiKey,
                        "Accept": "application/json"
                    }
                });

                if (res.status === 401 || res.status === 403) {
                    return {
                        status: "error",
                        error: "PodSips API key was rejected (HTTP " + res.status + "). Check Settings → Keys → PodSips."
                    };
                }

                if (res.status === 429) {
                    return { status: "error", error: "PodSips rate limit hit. Try again shortly." };
                }

                if (res.status !== 200 || !res.json) {
                    return {
                        status: "error",
                        error: "PodSips returned HTTP " + res.status,
                        body: (res.body || "").slice(0, 500)
                    };
                }

                // Response shape: { groups: [{ episode_id, episode_name,
                // series_id, series_name, chunks: [{ text, start_time,
                // end_time, score, speakers[], word_count }] }], meta }.
                // Flatten the per-episode groups into a flat, ranked clip list,
                // carrying each chunk's episode/series context down with it.
                var groups = Array.isArray(res.json.groups) ? res.json.groups : [];
                var clips = [];
                groups.forEach(function(g) {
                    var chunks = Array.isArray(g.chunks) ? g.chunks : [];
                    chunks.forEach(function(c) {
                        clips.push({
                            podcast: g.series_name || "",
                            episode: g.episode_name || "",
                            episode_id: g.episode_id || "",
                            series_id: g.series_id || "",
                            speaker: Array.isArray(c.speakers) ? c.speakers.join(", ") : "",
                            timestamp: fmtTime(c.start_time),
                            start_time: c.start_time,
                            end_time: c.end_time,
                            score: c.score,
                            text: c.text || ""
                        });
                    });
                });

                // Best matches first, then trim to the caller's requested count.
                clips.sort(function(a, b) { return (b.score || 0) - (a.score || 0); });
                clips = clips.slice(0, limit);

                var podcastSet = {};
                clips.forEach(function(c) {
                    var key = c.podcast || c.episode;
                    if (key) podcastSet[key] = true;
                });
                var podcastCount = Object.keys(podcastSet).length;

                var summary = "Found " + clips.length + " clip" + (clips.length !== 1 ? "s" : "")
                    + " about \"" + query + "\""
                    + (podcastCount > 0 ? " across " + podcastCount + " podcast" + (podcastCount !== 1 ? "s" : "") : "");

                return { summary: summary, clips: clips };
            } catch (e) {
                return { status: "error", error: String(e) };
            }
        }
        """#
    )
}
