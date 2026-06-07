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
    }

    static let all: [Seed] = [polymarketTrending, runSSHCommand, claudeCode, goalAgent]

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

    // MARK: - Goal Agent

    /// Persistent, KPI-bound agent that tracks a measurable goal over time.
    /// Reads a metric from a configured source on each run, compares progress
    /// against a target and deadline, reviews past actions, plans next steps,
    /// and dispatches code/infra work via Devin/Cursor/SSH/GitHub tools.
    /// Supports `list` and `kill` sub-commands to manage active agents.
    private static let goalAgent = Seed(
        name: "goal_agent",
        description: "Create and run a persistent goal agent that tracks a KPI, plans actions to close the gap, and dispatches code/infra work autonomously. Supports sub-commands: 'run' (default), 'list', 'kill'.",
        parameters: [
            "type": "object",
            "properties": [
                "command": [
                    "type": "string",
                    "description": "Sub-command: 'run' (default — create or advance a goal agent), 'list' (show all active agents), 'kill' (terminate an agent by goal_id)."
                ],
                "goal_id": [
                    "type": "string",
                    "description": "Unique identifier for the goal agent. Required for 'run' and 'kill'. Auto-derived from goal_name if omitted on first run."
                ],
                "goal_name": [
                    "type": "string",
                    "description": "Human-readable name for the goal (e.g. 'Grow rcmapi.com revenue to $20k/month'). Required on first run."
                ],
                "target_metric": [
                    "type": "string",
                    "description": "Human-readable description of the metric being tracked (e.g. 'Monthly Recurring Revenue')."
                ],
                "metric_source": [
                    "type": "object",
                    "description": "How to read the current metric value. Object with `type` ('stripe', 'github', 'ssh_command', 'custom_url') and type-specific fields (api_key, owner, repo, command, url, headers, json_path)."
                ],
                "target_value": [
                    "type": "string",
                    "description": "Target value for the metric (e.g. '20000')."
                ],
                "deadline": [
                    "type": "string",
                    "description": "ISO 8601 date by which the target should be reached (e.g. '2025-09-30')."
                ],
                "check_cadence": [
                    "type": "string",
                    "description": "Cron expression for check-in frequency (e.g. '0 9 * * 1' for weekly Monday 9am). Informational — the scheduler fires this skill on cadence."
                ],
                "tools": [
                    "type": "array",
                    "description": "Which dispatch tools the agent is allowed to use: 'devin', 'cursor', 'ssh', 'github', 'slack_dm'."
                ]
            ],
            "required": [String]()
        ],
        source: #"""
        // goal_agent — persistent, KPI-bound autonomous agent.
        //
        // State is persisted in Workspace/Skills/goal_agent/agents/<id>.json
        // via the file_read / file_write native tools. Each run:
        //   1. Loads (or creates) agent state
        //   2. Reads the current metric from the configured source
        //   3. Computes velocity and projected outcome vs deadline
        //   4. Reviews previous actions and outcomes
        //   5. Plans next actions
        //   6. Dispatches work (max 1 Devin + 1 Cursor concurrently)
        //   7. Persists updated state and returns a summary
        async function run(args, host) {
            var cmd = (args.command || "run").toLowerCase();

            // ── Sub-commands: list / kill ──────────────────────────────

            if (cmd === "list") {
                return await listAgents(host);
            }
            if (cmd === "kill") {
                if (!args.goal_id) {
                    return { status: "error", error: "goal_id is required for the 'kill' command." };
                }
                return await killAgent(args.goal_id, host);
            }

            // ── Run: create or advance ─────────────────────────────────

            var goalId = args.goal_id || slugify(args.goal_name || "");
            if (!goalId) {
                return { status: "error", error: "Provide goal_name (first run) or goal_id (subsequent runs)." };
            }

            var state = await loadState(goalId, host);
            var isNew = !state;

            if (isNew) {
                if (!args.goal_name || !args.target_value || !args.deadline) {
                    return {
                        status: "error",
                        error: "First run requires goal_name, target_value, and deadline."
                    };
                }
                state = {
                    goal_id: goalId,
                    goal_name: args.goal_name,
                    target_metric: args.target_metric || args.goal_name,
                    metric_source: args.metric_source || null,
                    target_value: args.target_value,
                    deadline: args.deadline,
                    check_cadence: args.check_cadence || "0 9 * * 1",
                    allowed_tools: args.tools || ["devin", "cursor", "ssh", "github"],
                    status: "active",
                    created_at: new Date().toISOString(),
                    history: [],
                    active_dispatches: { devin: null, cursor: null },
                    pending_decisions: []
                };
                host.log("Creating new goal agent: " + state.goal_name);
            } else {
                host.log("Resuming goal agent: " + state.goal_name);
                // Merge any updated config from args
                if (args.metric_source) state.metric_source = args.metric_source;
                if (args.tools) state.allowed_tools = args.tools;
                if (args.target_value) state.target_value = args.target_value;
                if (args.deadline) state.deadline = args.deadline;
            }

            // Step 1: Read current metric
            host.log("Step 1/5: Reading current metric...");
            var metricResult = await readMetric(state, host);

            // Step 2: Compute velocity & projection
            host.log("Step 2/5: Computing velocity and projection...");
            var analysis = computeAnalysis(state, metricResult);

            // Step 3: Review previous actions
            host.log("Step 3/5: Reviewing previous action outcomes...");
            var actionReview = await reviewPreviousActions(state, host);

            // Step 4: Plan next actions
            host.log("Step 4/5: Planning next actions...");
            var plan = planNextActions(state, analysis, actionReview);

            // Step 5: Dispatch work (if any)
            host.log("Step 5/5: Dispatching work...");
            var dispatched = await dispatchActions(state, plan, host);

            // Record this run in history
            var entry = {
                timestamp: new Date().toISOString(),
                metric_value: metricResult.value,
                metric_raw: metricResult.raw,
                metric_error: metricResult.error || null,
                analysis: analysis,
                actions_planned: plan,
                actions_dispatched: dispatched,
                pending_decisions: state.pending_decisions
            };
            state.history.push(entry);

            // Cap history at 50 entries to keep file size manageable
            if (state.history.length > 50) {
                state.history = state.history.slice(-50);
            }

            state.last_run = new Date().toISOString();
            await saveState(goalId, state, host);

            // Build summary
            var metricLine = metricResult.error
                ? "Metric read FAILED: " + metricResult.error
                : "Current value: " + metricResult.value + " (target: " + state.target_value + ")";

            var projLine = analysis.projected_value != null
                ? "Projected at deadline: " + analysis.projected_value.toFixed(1)
                  + " (" + (analysis.on_track ? "ON TRACK" : "OFF TRACK") + ")"
                : "Insufficient data to project";

            var actionLines = dispatched.length > 0
                ? dispatched.map(function(d) { return "- [" + d.tool + "] " + d.description; }).join("\n")
                : "- No actions dispatched this cycle";

            var blockerLines = state.pending_decisions.length > 0
                ? "\n\nBLOCKERS (need your decision):\n" + state.pending_decisions.map(function(b) {
                    return "- " + b;
                  }).join("\n")
                : "";

            var summary = "Goal: " + state.goal_name
                + "\n" + metricLine
                + "\n" + projLine
                + "\nRuns: " + state.history.length
                + "\nDeadline: " + state.deadline
                + "\n\nActions this cycle:\n" + actionLines
                + blockerLines;

            if (state.pending_decisions.length > 0) {
                host.notify("Goal Agent needs a decision",
                    state.goal_name + ": " + state.pending_decisions[0]);
            }

            return {
                summary: summary,
                goal_id: goalId,
                status: state.status,
                metric_value: metricResult.value,
                target_value: state.target_value,
                on_track: analysis.on_track,
                actions_dispatched: dispatched.length,
                pending_decisions: state.pending_decisions
            };
        }

        // ── State persistence ─────────────────────────────────────────

        function stateDir() {
            return "Skills/goal_agent/agents";
        }

        function statePath(goalId) {
            return stateDir() + "/" + goalId + ".json";
        }

        async function loadState(goalId, host) {
            try {
                var result = await host.callTool("file_read", { path: statePath(goalId) });
                if (result && result.status !== "error" && result.content) {
                    return JSON.parse(result.content);
                }
                // Try alternate response shapes
                if (typeof result === "string") {
                    return JSON.parse(result);
                }
            } catch (e) {
                // File doesn't exist yet — that's fine for a new agent
            }
            return null;
        }

        async function saveState(goalId, state, host) {
            try {
                await host.callTool("file_write", {
                    path: statePath(goalId),
                    content: JSON.stringify(state, null, 2)
                });
            } catch (e) {
                host.log("Warning: failed to persist state — " + String(e));
            }
        }

        async function listAgents(host) {
            try {
                var result = await host.callTool("file_list", { path: stateDir() });
                var files = [];
                if (result && result.entries) {
                    files = result.entries;
                } else if (Array.isArray(result)) {
                    files = result;
                }

                var agents = [];
                for (var i = 0; i < files.length; i++) {
                    var f = files[i];
                    var name = (typeof f === "string") ? f : (f.name || f.path || "");
                    if (!name.endsWith(".json")) continue;
                    var id = name.replace(/\.json$/, "");
                    var st = await loadState(id, host);
                    if (st) {
                        agents.push({
                            goal_id: st.goal_id,
                            goal_name: st.goal_name,
                            status: st.status,
                            target_value: st.target_value,
                            deadline: st.deadline,
                            last_run: st.last_run || null,
                            runs: (st.history || []).length,
                            pending_decisions: (st.pending_decisions || []).length
                        });
                    }
                }

                if (agents.length === 0) {
                    return { summary: "No active goal agents.", agents: [] };
                }

                var lines = agents.map(function(a) {
                    return "- " + a.goal_id + ": " + a.goal_name
                        + " (target: " + a.target_value + ", deadline: " + a.deadline
                        + ", runs: " + a.runs
                        + ", status: " + a.status + ")";
                });

                return {
                    summary: agents.length + " goal agent(s):\n" + lines.join("\n"),
                    agents: agents
                };
            } catch (e) {
                return { summary: "No active goal agents (directory not yet created).", agents: [] };
            }
        }

        async function killAgent(goalId, host) {
            var state = await loadState(goalId, host);
            if (!state) {
                return { status: "error", error: "No agent found with id '" + goalId + "'." };
            }
            state.status = "killed";
            state.killed_at = new Date().toISOString();
            await saveState(goalId, state, host);
            return {
                summary: "Goal agent '" + state.goal_name + "' (" + goalId + ") has been terminated.",
                goal_id: goalId,
                status: "killed"
            };
        }

        // ── Metric reading ────────────────────────────────────────────

        async function readMetric(state, host) {
            var src = state.metric_source;
            if (!src || !src.type) {
                return { value: null, raw: null, error: "No metric_source configured." };
            }

            try {
                if (src.type === "stripe") {
                    return await readStripeMetric(src, host);
                } else if (src.type === "github") {
                    return await readGitHubMetric(src, host);
                } else if (src.type === "ssh_command") {
                    return await readSSHMetric(src, host);
                } else if (src.type === "custom_url") {
                    return await readCustomURLMetric(src, host);
                } else {
                    return { value: null, raw: null, error: "Unknown metric_source type: " + src.type };
                }
            } catch (e) {
                return { value: null, raw: null, error: String(e) };
            }
        }

        async function readStripeMetric(src, host) {
            // Stripe Balance or MRR via the Stripe API
            var apiKey = src.api_key || host.getConfig("stripe_api_key");
            if (!apiKey) {
                return { value: null, raw: null, error: "Stripe API key not configured. Set it in metric_source.api_key or Settings." };
            }

            var endpoint = src.endpoint || "https://api.stripe.com/v1/balance";
            var res = await host.http({
                url: endpoint,
                method: "GET",
                headers: { "Authorization": "Bearer " + apiKey }
            });

            if (res.status !== 200) {
                return { value: null, raw: res.body, error: "Stripe API returned HTTP " + res.status };
            }

            var data = res.json || {};
            // Extract value using json_path if provided, otherwise use available balance
            var value = extractJsonPath(data, src.json_path || "available.0.amount");
            // Stripe amounts are in cents
            if (typeof value === "number" && !src.skip_cents_conversion) {
                value = value / 100;
            }

            return { value: value, raw: data };
        }

        async function readGitHubMetric(src, host) {
            // Read a metric from GitHub (stars, issues, etc.)
            var owner = src.owner;
            var repo = src.repo;
            if (!owner || !repo) {
                return { value: null, raw: null, error: "GitHub metric_source requires owner and repo." };
            }

            try {
                var result = await host.callTool("github_file_contents", {
                    owner: owner,
                    repo: repo,
                    path: src.path || ""
                });
                if (src.json_path && result) {
                    var parsed = typeof result === "string" ? JSON.parse(result) : result;
                    return { value: extractJsonPath(parsed, src.json_path), raw: parsed };
                }
                return { value: result, raw: result };
            } catch (e) {
                return { value: null, raw: null, error: "GitHub read failed: " + String(e) };
            }
        }

        async function readSSHMetric(src, host) {
            // Run a command via SSH and parse the output
            var command = src.command;
            if (!command) {
                return { value: null, raw: null, error: "ssh_command metric_source requires a command." };
            }

            try {
                var result = await host.callSkill("run_ssh_command", {
                    command: command,
                    timeout_ms: src.timeout_ms || 30000
                });
                if (result && result.status === "ok") {
                    var output = (result.stdout || "").trim();
                    var numVal = parseFloat(output);
                    return {
                        value: isNaN(numVal) ? output : numVal,
                        raw: result
                    };
                }
                return { value: null, raw: result, error: (result && result.error) || "SSH command failed" };
            } catch (e) {
                return { value: null, raw: null, error: "SSH metric failed: " + String(e) };
            }
        }

        async function readCustomURLMetric(src, host) {
            var url = src.url;
            if (!url) {
                return { value: null, raw: null, error: "custom_url metric_source requires a url." };
            }

            var headers = src.headers || {};
            var res = await host.http({ url: url, method: "GET", headers: headers });

            if (res.status !== 200) {
                return { value: null, raw: res.body, error: "Custom URL returned HTTP " + res.status };
            }

            var data = res.json || res.body;
            if (src.json_path && typeof data === "object") {
                return { value: extractJsonPath(data, src.json_path), raw: data };
            }
            // Try to parse as number
            if (typeof data === "string") {
                var num = parseFloat(data.trim());
                return { value: isNaN(num) ? data.trim() : num, raw: data };
            }
            return { value: data, raw: data };
        }

        // ── Analysis ──────────────────────────────────────────────────

        function computeAnalysis(state, metricResult) {
            var result = {
                current_value: metricResult.value,
                target_value: parseFloat(state.target_value) || 0,
                days_remaining: 0,
                velocity_per_day: null,
                projected_value: null,
                on_track: false,
                gap: null,
                completion_pct: null
            };

            var target = result.target_value;
            var now = new Date();
            var deadline = new Date(state.deadline);
            result.days_remaining = Math.max(0, Math.ceil((deadline - now) / (1000 * 60 * 60 * 24)));

            if (metricResult.value == null || typeof metricResult.value !== "number") {
                return result;
            }

            var current = metricResult.value;
            result.gap = target - current;
            result.completion_pct = target !== 0 ? Math.round((current / target) * 100) : 0;

            // Compute velocity from history
            var history = state.history || [];
            var dataPoints = history
                .filter(function(h) { return h.metric_value != null && typeof h.metric_value === "number"; })
                .map(function(h) { return { t: new Date(h.timestamp).getTime(), v: h.metric_value }; });

            // Add current reading
            dataPoints.push({ t: now.getTime(), v: current });

            if (dataPoints.length >= 2) {
                var first = dataPoints[0];
                var last = dataPoints[dataPoints.length - 1];
                var daysDiff = (last.t - first.t) / (1000 * 60 * 60 * 24);
                if (daysDiff > 0) {
                    result.velocity_per_day = (last.v - first.v) / daysDiff;
                    result.projected_value = current + (result.velocity_per_day * result.days_remaining);
                    result.on_track = result.projected_value >= target;
                }
            }

            return result;
        }

        // ── Action review ─────────────────────────────────────────────

        async function reviewPreviousActions(state, host) {
            var lastRun = state.history.length > 0 ? state.history[state.history.length - 1] : null;
            if (!lastRun) return { summary: "First run — no previous actions to review." };

            var dispatched = lastRun.actions_dispatched || [];
            var reviews = [];

            for (var i = 0; i < dispatched.length; i++) {
                var d = dispatched[i];
                if (d.tool === "devin" && d.session_id) {
                    try {
                        var check = await host.callTool("devin_check_agent", { session_id: d.session_id });
                        reviews.push({
                            action: d.description,
                            tool: "devin",
                            status: (check && check.status) || "unknown",
                            pr_url: (check && check.pr_url) || null
                        });
                    } catch (e) {
                        reviews.push({ action: d.description, tool: "devin", status: "check_failed" });
                    }
                } else if (d.tool === "cursor" && d.agent_id) {
                    try {
                        var check2 = await host.callTool("cursor_check_agent", { agent_id: d.agent_id });
                        reviews.push({
                            action: d.description,
                            tool: "cursor",
                            status: (check2 && check2.status) || "unknown",
                            pr_url: (check2 && check2.pr_url) || null
                        });
                    } catch (e) {
                        reviews.push({ action: d.description, tool: "cursor", status: "check_failed" });
                    }
                } else {
                    reviews.push({ action: d.description, tool: d.tool, status: "completed" });
                }
            }

            return {
                summary: reviews.length + " previous action(s) reviewed",
                reviews: reviews
            };
        }

        // ── Action planning ───────────────────────────────────────────

        function planNextActions(state, analysis, actionReview) {
            var actions = [];

            // If metric couldn't be read, plan a diagnostic action
            if (analysis.current_value == null) {
                actions.push({
                    type: "diagnose",
                    tool: "ssh",
                    description: "Diagnose metric collection failure — check service health and logs",
                    priority: "high"
                });
                return actions;
            }

            // Check for pending dispatches — enforce concurrency cap
            var activeDevin = state.active_dispatches && state.active_dispatches.devin;
            var activeCursor = state.active_dispatches && state.active_dispatches.cursor;

            // If we have unresolved blockers, don't dispatch more work
            if (state.pending_decisions && state.pending_decisions.length > 0) {
                return [{
                    type: "blocked",
                    tool: "none",
                    description: "Waiting on user decisions: " + state.pending_decisions.join("; "),
                    priority: "high"
                }];
            }

            // Plan based on gap analysis
            if (analysis.on_track) {
                // On track — do lighter maintenance work
                if (canUse(state, "ssh")) {
                    actions.push({
                        type: "monitor",
                        tool: "ssh",
                        description: "Review application logs for errors or performance issues",
                        priority: "low"
                    });
                }
                if (canUse(state, "github")) {
                    actions.push({
                        type: "review",
                        tool: "github",
                        description: "Check for open issues or PRs that need attention",
                        priority: "low"
                    });
                }
            } else {
                // Off track — plan more aggressive actions
                if (!activeDevin && canUse(state, "devin")) {
                    actions.push({
                        type: "build",
                        tool: "devin",
                        description: "Implement feature or fix to close the gap toward "
                            + state.target_metric + " (current: "
                            + analysis.current_value + ", target: " + analysis.target_value + ")",
                        priority: "high"
                    });
                }
                if (canUse(state, "ssh")) {
                    actions.push({
                        type: "diagnose",
                        tool: "ssh",
                        description: "Review server logs and metrics for growth bottlenecks",
                        priority: "medium"
                    });
                }
                if (canUse(state, "github")) {
                    actions.push({
                        type: "review",
                        tool: "github",
                        description: "Review codebase for quick-win optimizations",
                        priority: "medium"
                    });
                }
            }

            return actions;
        }

        // ── Action dispatching ────────────────────────────────────────

        async function dispatchActions(state, plan, host) {
            var dispatched = [];

            for (var i = 0; i < plan.length; i++) {
                var action = plan[i];

                if (action.type === "blocked") {
                    dispatched.push({ tool: "none", description: action.description, skipped: true });
                    continue;
                }

                if (action.tool === "devin" && canUse(state, "devin")) {
                    // Safety: max 1 concurrent Devin dispatch
                    if (state.active_dispatches.devin) {
                        dispatched.push({
                            tool: "devin",
                            description: action.description,
                            skipped: true,
                            reason: "Devin dispatch already active"
                        });
                        continue;
                    }
                    try {
                        var taskPrompt = "[Goal Agent: " + state.goal_name + "]\n\n" + action.description
                            + "\n\nContext: target is " + state.target_value
                            + " by " + state.deadline + ". Current metric: " + (state.history.length > 0
                                ? state.history[state.history.length - 1].metric_value
                                : "unknown") + ".";

                        var devinResult = await host.callTool("devin_dispatch_agent", {
                            task: taskPrompt,
                            title: "Goal: " + state.goal_name
                        });
                        var sessionId = (devinResult && devinResult.session_id) || null;
                        state.active_dispatches.devin = sessionId;
                        dispatched.push({
                            tool: "devin",
                            description: action.description,
                            session_id: sessionId,
                            dispatched: true
                        });
                    } catch (e) {
                        dispatched.push({
                            tool: "devin",
                            description: action.description,
                            error: String(e)
                        });
                    }

                } else if (action.tool === "cursor" && canUse(state, "cursor")) {
                    // Safety: max 1 concurrent Cursor dispatch
                    if (state.active_dispatches.cursor) {
                        dispatched.push({
                            tool: "cursor",
                            description: action.description,
                            skipped: true,
                            reason: "Cursor dispatch already active"
                        });
                        continue;
                    }
                    try {
                        var cursorResult = await host.callTool("cursor_dispatch_agent", {
                            task: "[Goal Agent: " + state.goal_name + "] " + action.description
                        });
                        var agentId = (cursorResult && cursorResult.agent_id) || null;
                        state.active_dispatches.cursor = agentId;
                        dispatched.push({
                            tool: "cursor",
                            description: action.description,
                            agent_id: agentId,
                            dispatched: true
                        });
                    } catch (e) {
                        dispatched.push({
                            tool: "cursor",
                            description: action.description,
                            error: String(e)
                        });
                    }

                } else if (action.tool === "ssh" && canUse(state, "ssh")) {
                    try {
                        var sshResult = await host.callSkill("run_ssh_command", {
                            command: "tail -100 /var/log/syslog 2>/dev/null || journalctl -n 100 --no-pager 2>/dev/null || echo 'No standard log source found'",
                            timeout_ms: 15000
                        });
                        dispatched.push({
                            tool: "ssh",
                            description: action.description,
                            status: (sshResult && sshResult.status) || "unknown",
                            output_preview: sshResult && sshResult.stdout
                                ? sshResult.stdout.slice(0, 500) : null
                        });
                    } catch (e) {
                        dispatched.push({
                            tool: "ssh",
                            description: action.description,
                            error: String(e)
                        });
                    }

                } else if (action.tool === "github" && canUse(state, "github")) {
                    try {
                        // Read repo info/issues if metric_source has owner/repo
                        var src = state.metric_source || {};
                        if (src.owner && src.repo) {
                            var ghResult = await host.callTool("github_file_contents", {
                                owner: src.owner,
                                repo: src.repo,
                                path: "README.md"
                            });
                            dispatched.push({
                                tool: "github",
                                description: action.description,
                                status: "ok"
                            });
                        } else {
                            dispatched.push({
                                tool: "github",
                                description: action.description,
                                skipped: true,
                                reason: "No owner/repo configured in metric_source"
                            });
                        }
                    } catch (e) {
                        dispatched.push({
                            tool: "github",
                            description: action.description,
                            error: String(e)
                        });
                    }

                } else {
                    dispatched.push({
                        tool: action.tool,
                        description: action.description,
                        skipped: true,
                        reason: "Tool not available or not allowed"
                    });
                }
            }

            return dispatched;
        }

        // ── Helpers ───────────────────────────────────────────────────

        function canUse(state, tool) {
            return (state.allowed_tools || []).indexOf(tool) !== -1;
        }

        function slugify(str) {
            return str.toLowerCase()
                .replace(/[^a-z0-9]+/g, "_")
                .replace(/^_|_$/g, "")
                .slice(0, 60);
        }

        function extractJsonPath(obj, path) {
            if (!path || !obj) return obj;
            var parts = path.split(".");
            var current = obj;
            for (var i = 0; i < parts.length; i++) {
                if (current == null) return null;
                var key = parts[i];
                // Support numeric indices for arrays
                var idx = parseInt(key, 10);
                if (Array.isArray(current) && !isNaN(idx)) {
                    current = current[idx];
                } else {
                    current = current[key];
                }
            }
            return current;
        }
        """#
    )
}
