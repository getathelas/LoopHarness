// goal_agent — persistent, goal-directed agent that tracks a measurable KPI
// over a quarter or longer. Stores state in Workspace/Skills/goal_agent/agents/
// and dispatches work via Devin, Cursor, SSH, GitHub, and Slack.
//
// Subcommands:
//   "create" (default) — register a new goal or run a check-in on an existing one
//   "list"             — return all active goal agents and their status
//   "kill"             — terminate (delete state for) a goal by name

async function run(args, host) {
    var subcommand = (args.subcommand || "create").toLowerCase();

    if (subcommand === "list") {
        return await listGoals(host);
    }
    if (subcommand === "kill") {
        return await killGoal(args, host);
    }

    // "create" or check-in
    return await createOrCheckIn(args, host);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

var AGENTS_DIR = "Skills/goal_agent/agents";

function goalId(name) {
    return name.toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "");
}

function statePath(gid) {
    return AGENTS_DIR + "/" + gid + ".json";
}

function nowISO() {
    return new Date().toISOString();
}

// ---------------------------------------------------------------------------
// State I/O — read/write JSON via the host file_* tools
// ---------------------------------------------------------------------------

async function readState(host, gid) {
    try {
        var raw = await host.callTool("file_read", { path: statePath(gid) });
        if (raw && typeof raw === "object" && raw.content) {
            return JSON.parse(raw.content);
        }
        if (raw && typeof raw === "string") {
            return JSON.parse(raw);
        }
        return null;
    } catch (e) {
        return null;
    }
}

async function writeState(host, gid, state) {
    await host.callTool("folder_create", { path: AGENTS_DIR });
    await host.callTool("file_write", {
        path: statePath(gid),
        content: JSON.stringify(state, null, 2)
    });
}

async function deleteState(host, gid) {
    try {
        await host.callTool("file_delete", { path: statePath(gid) });
    } catch (e) {
        // already gone — fine
    }
}

// ---------------------------------------------------------------------------
// Subcommand: list
// ---------------------------------------------------------------------------

async function listGoals(host) {
    host.log("Listing active goal agents...");
    try {
        var listing = await host.callTool("file_list", {
            path: AGENTS_DIR
        });

        var files = [];
        if (listing && Array.isArray(listing.entries)) {
            files = listing.entries;
        } else if (listing && Array.isArray(listing)) {
            files = listing;
        }

        var goals = [];
        for (var i = 0; i < files.length; i++) {
            var f = files[i];
            var name = (typeof f === "string") ? f : (f.name || f.path || "");
            if (!name.endsWith(".json")) continue;
            var gid = name.replace(/\.json$/, "").replace(/^.*\//, "");
            var state = await readState(host, gid);
            if (!state) continue;
            goals.push({
                goal_id: gid,
                goal_name: state.goal_name,
                target_metric: state.target_metric,
                target_value: state.target_value,
                current_value: state.current_value,
                deadline: state.deadline,
                check_cadence: state.check_cadence,
                checks_count: (state.history || []).length,
                dispatched_jobs: (state.dispatched_jobs || []).length,
                blocker: state.blocker || null,
                last_checked: state.last_checked || null
            });
        }
        return { status: "ok", active_goals: goals, count: goals.length };
    } catch (e) {
        return { status: "ok", active_goals: [], count: 0, note: "No agents directory yet." };
    }
}

// ---------------------------------------------------------------------------
// Subcommand: kill
// ---------------------------------------------------------------------------

async function killGoal(args, host) {
    var name = args.goal_name;
    if (!name) {
        return { status: "error", error: "goal_name is required for the kill subcommand." };
    }
    var gid = goalId(name);
    host.log("Terminating goal agent: " + name + " (" + gid + ")");

    var state = await readState(host, gid);
    if (!state) {
        return { status: "error", error: "No active goal agent found with name '" + name + "'." };
    }
    await deleteState(host, gid);
    return {
        status: "ok",
        message: "Goal agent '" + name + "' terminated.",
        final_state: {
            goal_name: state.goal_name,
            current_value: state.current_value,
            target_value: state.target_value,
            checks_count: (state.history || []).length
        }
    };
}

// ---------------------------------------------------------------------------
// Subcommand: create / check-in
// ---------------------------------------------------------------------------

async function createOrCheckIn(args, host) {
    var name = args.goal_name;
    if (!name) {
        return { status: "error", error: "goal_name is required." };
    }

    var gid = goalId(name);
    var state = await readState(host, gid);
    var isNew = !state;

    if (isNew) {
        // Validate required fields for creation
        if (!args.target_metric) {
            return { status: "error", error: "target_metric is required when creating a new goal." };
        }
        if (args.target_value == null) {
            return { status: "error", error: "target_value is required when creating a new goal." };
        }
        if (!args.deadline) {
            return { status: "error", error: "deadline is required when creating a new goal." };
        }

        host.log("Creating new goal agent: " + name);
        state = {
            goal_id: gid,
            goal_name: name,
            target_metric: args.target_metric,
            metric_source: args.metric_source || null,
            target_value: args.target_value,
            deadline: args.deadline,
            check_cadence: args.check_cadence || "0 9 * * 1",
            tools: args.tools || [],
            current_value: null,
            history: [],
            planned_actions: [],
            dispatched_jobs: [],
            blocker: null,
            created_at: nowISO(),
            last_checked: null
        };
    } else {
        host.log("Check-in for goal: " + name);
    }

    // 1. Read current metric
    var metricResult = await readMetric(state, host);
    state.current_value = metricResult.value;

    var checkEntry = {
        timestamp: nowISO(),
        metric_value: metricResult.value,
        metric_raw: metricResult.raw || null,
        metric_error: metricResult.error || null
    };

    // 2. Compute velocity and projection
    var analysis = analyzeProgress(state);
    checkEntry.analysis = analysis;

    // 3. Review previous dispatched jobs
    var jobReview = reviewJobs(state);
    checkEntry.job_review = jobReview;

    // 4. Plan next actions
    var plan = planActions(state, analysis);
    state.planned_actions = plan.actions;
    checkEntry.planned_actions = plan.actions;

    // 5. Dispatch actions (respecting safety caps)
    var dispatched = await dispatchActions(state, plan.actions, host);
    checkEntry.dispatched = dispatched;

    state.history.push(checkEntry);
    state.last_checked = nowISO();
    await writeState(host, gid, state);

    // Build summary
    var summary = buildSummary(state, analysis, metricResult, dispatched, isNew);
    host.log(summary.headline);

    var result = {
        status: "ok",
        goal_name: name,
        is_new: isNew,
        current_value: state.current_value,
        target_value: state.target_value,
        deadline: state.deadline,
        summary: summary.headline,
        detail: summary.detail,
        dispatched_jobs: dispatched,
        planned_actions: state.planned_actions
    };

    if (state.blocker) {
        result.blocker = state.blocker;
    }
    return result;
}

// ---------------------------------------------------------------------------
// Metric reading
// ---------------------------------------------------------------------------

async function readMetric(state, host) {
    var src = state.metric_source;
    if (!src || !src.type) {
        return { value: state.current_value, error: "No metric_source configured; using last known value." };
    }

    host.log("Reading metric from " + src.type + "...");

    try {
        if (src.type === "ssh_command") {
            return await readMetricSSH(src.config || {}, host);
        }
        if (src.type === "github") {
            return await readMetricGitHub(src.config || {}, host);
        }
        if (src.type === "stripe") {
            return await readMetricStripe(src.config || {}, host);
        }
        if (src.type === "custom_url") {
            return await readMetricURL(src.config || {}, host);
        }
        return { value: state.current_value, error: "Unknown metric_source type: " + src.type };
    } catch (e) {
        return { value: state.current_value, error: "Metric read failed: " + String(e) };
    }
}

async function readMetricSSH(config, host) {
    var result = await host.callTool("ssh_client", {
        command: config.command || "echo 0",
        host: config.host,
        session_id: config.session_id || "goal_agent_metric"
    });
    var stdout = (result && result.stdout) || (typeof result === "string" ? result : "");
    var parsed = parseFloat(stdout.trim());
    return {
        value: isNaN(parsed) ? stdout.trim() : parsed,
        raw: stdout
    };
}

async function readMetricGitHub(config, host) {
    var result = await host.callTool("github_file_contents", {
        repo: config.repo,
        path: config.path || "",
        ref: config.ref || "main"
    });
    var content = (result && result.content) || (typeof result === "string" ? result : "");
    if (config.jq) {
        // Simple JSON path extraction (dot-notation only)
        try {
            var obj = JSON.parse(content);
            var keys = config.jq.split(".");
            for (var i = 0; i < keys.length; i++) {
                if (keys[i] && obj != null) obj = obj[keys[i]];
            }
            return { value: obj, raw: content };
        } catch (e) {
            return { value: content, raw: content, error: "JSON parse/extract failed: " + e };
        }
    }
    return { value: content, raw: content };
}

async function readMetricStripe(config, host) {
    var endpoint = config.endpoint || "https://api.stripe.com/v1/balance";
    var res = await host.http({
        url: endpoint,
        method: "GET",
        headers: {
            "Authorization": "Bearer " + (config.api_key || host.getConfig("stripe_api_key") || ""),
            "Accept": "application/json"
        }
    });
    if (res.status !== 200) {
        return { value: null, error: "Stripe returned HTTP " + res.status, raw: (res.body || "").slice(0, 500) };
    }
    var data = res.json || {};
    // Default: sum available balance amounts
    if (data.available && Array.isArray(data.available)) {
        var total = 0;
        for (var i = 0; i < data.available.length; i++) {
            total += (data.available[i].amount || 0);
        }
        return { value: total / 100, raw: data };
    }
    if (config.json_path) {
        var val = data;
        var parts = config.json_path.split(".");
        for (var j = 0; j < parts.length; j++) {
            if (parts[j] && val != null) val = val[parts[j]];
        }
        return { value: val, raw: data };
    }
    return { value: data, raw: data };
}

async function readMetricURL(config, host) {
    var url = config.url;
    if (!url) {
        return { value: null, error: "custom_url metric_source requires config.url" };
    }
    var res = await host.http({
        url: url,
        method: config.method || "GET",
        headers: config.headers || { "Accept": "application/json" }
    });
    if (res.status < 200 || res.status >= 300) {
        return { value: null, error: "HTTP " + res.status, raw: (res.body || "").slice(0, 500) };
    }
    if (res.json && config.json_path) {
        var val = res.json;
        var parts = config.json_path.split(".");
        for (var k = 0; k < parts.length; k++) {
            if (parts[k] && val != null) val = val[parts[k]];
        }
        return { value: val, raw: res.json };
    }
    return { value: res.json || res.body, raw: res.json || res.body };
}

// ---------------------------------------------------------------------------
// Progress analysis
// ---------------------------------------------------------------------------

function analyzeProgress(state) {
    var target = parseFloat(state.target_value);
    var current = parseFloat(state.current_value);
    var deadline = new Date(state.deadline);
    var now = new Date();

    var result = {
        target: target,
        current: current,
        gap: null,
        pct_complete: null,
        days_remaining: null,
        velocity_per_day: null,
        projected_value_at_deadline: null,
        on_track: null
    };

    if (isNaN(target) || isNaN(current)) {
        result.note = "Cannot compute numeric progress (target or current is non-numeric).";
        return result;
    }

    result.gap = target - current;
    result.pct_complete = target !== 0 ? Math.round((current / target) * 1000) / 10 : 0;
    result.days_remaining = Math.max(0, Math.ceil((deadline - now) / (1000 * 60 * 60 * 24)));

    // Compute velocity from history
    var history = state.history || [];
    if (history.length >= 2) {
        var first = history[0];
        var last = history[history.length - 1];
        var firstVal = parseFloat(first.metric_value);
        var lastVal = parseFloat(last.metric_value);
        var firstTime = new Date(first.timestamp);
        var lastTime = new Date(last.timestamp);
        var daysBetween = (lastTime - firstTime) / (1000 * 60 * 60 * 24);
        if (daysBetween > 0 && !isNaN(firstVal) && !isNaN(lastVal)) {
            result.velocity_per_day = (lastVal - firstVal) / daysBetween;
            result.projected_value_at_deadline = current + (result.velocity_per_day * result.days_remaining);
            result.on_track = result.projected_value_at_deadline >= target;
        }
    }

    if (result.on_track === null) {
        result.on_track = result.pct_complete >= 50 || result.days_remaining > 60;
    }

    return result;
}

// ---------------------------------------------------------------------------
// Job review
// ---------------------------------------------------------------------------

function reviewJobs(state) {
    var jobs = state.dispatched_jobs || [];
    if (jobs.length === 0) return { active: 0, summary: "No dispatched jobs." };

    var active = 0;
    for (var i = 0; i < jobs.length; i++) {
        if (jobs[i].status === "dispatched" || jobs[i].status === "running") {
            active++;
        }
    }
    return {
        active: active,
        total: jobs.length,
        summary: active + " active of " + jobs.length + " total dispatched jobs."
    };
}

// ---------------------------------------------------------------------------
// Action planning
// ---------------------------------------------------------------------------

function planActions(state, analysis) {
    var actions = [];
    var tools = state.tools || [];

    if (analysis.gap === null) {
        actions.push({
            type: "investigate",
            description: "Metric value is non-numeric or unavailable. Investigate metric_source config."
        });
        return { actions: actions };
    }

    if (analysis.gap <= 0) {
        return { actions: [{ type: "none", description: "Goal already met! Current: " + analysis.current + ", Target: " + analysis.target }] };
    }

    // If not on track, escalate
    if (analysis.on_track === false) {
        if (tools.indexOf("devin") >= 0) {
            actions.push({
                type: "devin",
                description: "Goal behind schedule. Dispatch Devin to accelerate: gap=" + analysis.gap +
                    ", days_left=" + analysis.days_remaining +
                    ", velocity=" + (analysis.velocity_per_day != null ? analysis.velocity_per_day.toFixed(2) : "unknown") + "/day"
            });
        }
        if (tools.indexOf("cursor") >= 0) {
            actions.push({
                type: "cursor",
                description: "Dispatch Cursor for code improvements to accelerate metric."
            });
        }
        if (tools.indexOf("slack_dm") >= 0) {
            actions.push({
                type: "notify",
                description: "Goal '" + state.goal_name + "' is behind schedule. Alert stakeholders via Slack."
            });
        }
    }

    // Routine check actions
    if (tools.indexOf("ssh") >= 0) {
        actions.push({
            type: "ssh",
            description: "Run infra health check via SSH."
        });
    }

    if (tools.indexOf("github") >= 0) {
        actions.push({
            type: "github",
            description: "Review recent PRs and issues related to this goal."
        });
    }

    if (actions.length === 0) {
        actions.push({ type: "none", description: "On track. No action needed this cycle." });
    }

    return { actions: actions };
}

// ---------------------------------------------------------------------------
// Action dispatch (with safety caps)
// ---------------------------------------------------------------------------

async function dispatchActions(state, actions, host) {
    var dispatched = [];
    var tools = state.tools || [];

    // Count active dispatches per type
    var activeDevin = 0;
    var activeCursor = 0;
    var jobs = state.dispatched_jobs || [];
    for (var i = 0; i < jobs.length; i++) {
        var j = jobs[i];
        if (j.status === "dispatched" || j.status === "running") {
            if (j.type === "devin") activeDevin++;
            if (j.type === "cursor") activeCursor++;
        }
    }

    for (var idx = 0; idx < actions.length; idx++) {
        var action = actions[idx];
        if (action.type === "none" || action.type === "investigate") continue;

        try {
            if (action.type === "devin" && tools.indexOf("devin") >= 0) {
                if (activeDevin >= 1) {
                    dispatched.push({
                        type: "devin",
                        status: "skipped",
                        reason: "Max 1 concurrent Devin dispatch per goal."
                    });
                    continue;
                }
                var taskStr = "[Goal: " + state.goal_name + "] " + action.description +
                    "\nTarget: " + state.target_value + " " + state.target_metric +
                    "\nCurrent: " + state.current_value +
                    "\nDeadline: " + state.deadline;
                var devinResult = await safeCallTool(host, "devin_dispatch_agent", {
                    task: taskStr
                });
                var jobEntry = {
                    type: "devin",
                    status: "dispatched",
                    dispatched_at: nowISO(),
                    task: taskStr.slice(0, 200),
                    result: devinResult
                };
                state.dispatched_jobs.push(jobEntry);
                dispatched.push(jobEntry);
                activeDevin++;
            }

            if (action.type === "cursor" && tools.indexOf("cursor") >= 0) {
                if (activeCursor >= 1) {
                    dispatched.push({
                        type: "cursor",
                        status: "skipped",
                        reason: "Max 1 concurrent Cursor dispatch per goal."
                    });
                    continue;
                }
                var cursorTask = "[Goal: " + state.goal_name + "] " + action.description +
                    "\nTarget: " + state.target_value + " " + state.target_metric +
                    "\nCurrent: " + state.current_value +
                    "\nDeadline: " + state.deadline;
                var cursorResult = await safeCallTool(host, "cursor_dispatch_agent", {
                    task: cursorTask
                });
                var cursorJob = {
                    type: "cursor",
                    status: "dispatched",
                    dispatched_at: nowISO(),
                    task: cursorTask.slice(0, 200),
                    result: cursorResult
                };
                state.dispatched_jobs.push(cursorJob);
                dispatched.push(cursorJob);
                activeCursor++;
            }

            if (action.type === "ssh" && tools.indexOf("ssh") >= 0) {
                var sshResult = await safeCallTool(host, "ssh_client", {
                    command: "uptime && df -h / && free -m",
                    session_id: "goal_agent_" + state.goal_id
                });
                dispatched.push({
                    type: "ssh",
                    status: "completed",
                    result: sshResult
                });
            }

            if (action.type === "github" && tools.indexOf("github") >= 0) {
                var ghResult = await safeCallTool(host, "github_file_contents", {
                    repo: (state.metric_source && state.metric_source.config && state.metric_source.config.repo) || "",
                    path: ""
                });
                dispatched.push({
                    type: "github",
                    status: "completed",
                    result: ghResult
                });
            }

            if (action.type === "notify" && tools.indexOf("slack_dm") >= 0) {
                host.notify(
                    "Goal Alert: " + state.goal_name,
                    action.description
                );
                dispatched.push({
                    type: "notify",
                    status: "completed",
                    message: action.description
                });
            }
        } catch (e) {
            // Record error in state — don't crash
            var errEntry = {
                type: action.type,
                status: "error",
                error: String(e),
                timestamp: nowISO()
            };
            dispatched.push(errEntry);
            state.blocker = {
                type: action.type,
                error: String(e),
                timestamp: nowISO(),
                description: "Action dispatch failed. Human review may be needed."
            };
        }
    }

    return dispatched;
}

async function safeCallTool(host, toolName, args) {
    try {
        return await host.callTool(toolName, args);
    } catch (e) {
        return { status: "error", error: String(e) };
    }
}

// ---------------------------------------------------------------------------
// Summary builder
// ---------------------------------------------------------------------------

function buildSummary(state, analysis, metricResult, dispatched, isNew) {
    var headline = "";
    if (isNew) {
        headline = "Created goal '" + state.goal_name + "'. ";
    }

    if (metricResult.error) {
        headline += "Metric warning: " + metricResult.error + ". ";
    }

    if (analysis.gap !== null) {
        headline += "Current: " + analysis.current + " / Target: " + analysis.target +
            " (" + analysis.pct_complete + "% complete). ";
        if (analysis.days_remaining !== null) {
            headline += analysis.days_remaining + " days remaining. ";
        }
        if (analysis.on_track === true) {
            headline += "ON TRACK.";
        } else if (analysis.on_track === false) {
            headline += "BEHIND SCHEDULE.";
        }
    } else {
        headline += "Metric is non-numeric — manual review recommended.";
    }

    var detail = {
        velocity_per_day: analysis.velocity_per_day,
        projected_value_at_deadline: analysis.projected_value_at_deadline,
        dispatched_count: dispatched.length,
        blocker: state.blocker
    };

    return { headline: headline.trim(), detail: detail };
}
