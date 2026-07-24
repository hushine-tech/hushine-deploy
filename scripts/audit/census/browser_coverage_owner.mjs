import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";


const NETWORK_METHODS = [
  "Network.requestWillBeSent",
  "Network.responseReceived",
  "Network.loadingFailed",
];

function sha256(data) {
  return crypto.createHash("sha256").update(data).digest("hex");
}

function safeUrl(value) {
  try {
    const parsed = new URL(value);
    return `${parsed.origin}${parsed.pathname}`;
  } catch {
    return null;
  }
}

function eventCategory(method, url) {
  if (method === "Network.loadingFailed") return "failure";
  if (!url) return "unknown";
  try {
    const parsed = new URL(url);
    return parsed.pathname.startsWith("/api/") ? "application-api" : "asset";
  } catch {
    return "unknown";
  }
}

function redactNetworkEvent(event) {
  const method = event?.method;
  const params = event?.params || {};
  if (!NETWORK_METHODS.includes(method)) return null;
  if (method === "Network.requestWillBeSent") {
    const request = params.request || {};
    return {
      event: method,
      sequence: event.sequence ?? null,
      request_id: params.requestId ?? null,
      method: request.method ?? null,
      path: safeUrl(request.url),
      category: eventCategory(method, request.url),
    };
  }
  if (method === "Network.responseReceived") {
    const response = params.response || {};
    return {
      event: method,
      sequence: event.sequence ?? null,
      request_id: params.requestId ?? null,
      path: safeUrl(response.url),
      status: Number.isFinite(response.status) ? response.status : null,
      category: eventCategory(method, response.url),
    };
  }
  return {
    event: method,
    sequence: event.sequence ?? null,
    request_id: params.requestId ?? null,
    path: safeUrl(params.url),
    category: "failure",
    canceled: params.canceled === true,
    blocked_reason: params.blockedReason ? "blocked" : null,
  };
}

function sanitizePreciseCoverage(value) {
  const scripts = Array.isArray(value?.result) ? value.result : [];
  return {
    result: scripts.map((script) => ({
      scriptId: String(script?.scriptId ?? ""),
      url: safeUrl(script?.url) || "",
      functions: (Array.isArray(script?.functions) ? script.functions : []).map((fn) => ({
        functionName: String(fn?.functionName ?? ""),
        isBlockCoverage: fn?.isBlockCoverage === true,
        ranges: (Array.isArray(fn?.ranges) ? fn.ranges : []).map((range) => ({
          startOffset: Number(range?.startOffset),
          endOffset: Number(range?.endOffset),
          count: Number(range?.count),
        })).filter((range) =>
          Number.isFinite(range.startOffset)
          && Number.isFinite(range.endOffset)
          && Number.isFinite(range.count)
          && range.endOffset > range.startOffset
        ),
      })),
    })),
  };
}

function requireApplicationCoverage(precise, frontendOrigin) {
  const application = precise.result.filter((script) =>
    script.url.startsWith(`${frontendOrigin}/`)
    && script.functions.some((fn) => fn.ranges.length > 0)
  );
  if (application.length === 0) {
    throw new Error(`precise coverage contains no application script for ${frontendOrigin}`);
  }
}

function exclusiveWrite(file, text) {
  fs.mkdirSync(path.dirname(file), {recursive: true, mode: 0o700});
  const descriptor = fs.openSync(file, "wx", 0o600);
  try {
    fs.writeFileSync(descriptor, text, {encoding: "utf8"});
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
}

function exclusiveAtomicWrite(file, text, randomBytes) {
  fs.mkdirSync(path.dirname(file), {recursive: true, mode: 0o700});
  const temporary = `${file}.tmp-${randomBytes(12).toString("hex")}`;
  try {
    exclusiveWrite(temporary, text);
    fs.linkSync(temporary, file);
  } finally {
    try {
      fs.unlinkSync(temporary);
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
  }
}

function appendJsonLine(file, value) {
  fs.mkdirSync(path.dirname(file), {recursive: true, mode: 0o700});
  if (fs.existsSync(file) && fs.lstatSync(file).isSymbolicLink()) {
    throw new Error(`refusing symbolic-link action log: ${file}`);
  }
  const flags = fs.constants.O_APPEND
    | fs.constants.O_CREAT
    | fs.constants.O_WRONLY
    | (fs.constants.O_NOFOLLOW || 0);
  const descriptor = fs.openSync(file, flags, 0o600);
  try {
    fs.writeSync(descriptor, `${JSON.stringify(value)}\n`);
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
}

function aggregateError(primary, cleanupErrors) {
  if (!primary && cleanupErrors.length === 0) return null;
  if (primary && cleanupErrors.length === 0) return primary;
  const messages = cleanupErrors.map((error) => error.message).join("; ");
  if (primary) {
    primary.message = `${primary.message}; cleanup errors: ${messages}`;
    return primary;
  }
  return new Error(`coverage cleanup failed: ${messages}`);
}

export function createBrowserCoverageOwner({
  browser,
  tab,
  runDir,
  inertUrl,
  frontendOrigin,
  cdpTargetId = null,
  randomBytes = crypto.randomBytes,
  now = () => new Date().toISOString(),
}) {
  if (!browser || typeof browser.id !== "string" || !browser.id) {
    throw new Error("browser.id is required");
  }
  if (!tab || typeof tab.id !== "string" || !tab.id) {
    throw new Error("opaque tab.id is required");
  }
  if (!tab.capabilities || typeof tab.capabilities.get !== "function") {
    throw new Error("tab.capabilities.get is required");
  }
  const origin = new URL(frontendOrigin).origin;
  if (new URL(inertUrl).origin !== origin) {
    throw new Error("inert page and frontend must be same-origin");
  }
  const browserId = browser.id;
  const tabId = tab.id;
  const runRoot = path.resolve(runDir);
  const startPath = path.join(runRoot, "coverage/frontend-owner-start.json");
  const rawPath = path.join(runRoot, "coverage/frontend-precise-raw.json");
  const actionsPath = path.join(runRoot, "browser/actions.jsonl");
  const ownerNonce = randomBytes(32).toString("hex");
  const commandOrder = [];
  let cdp;
  let cursor;
  let started = false;
  let preciseStarted = false;
  let finalized = false;
  let ownerStartSha;

  function assertBinding() {
    if (browser.id !== browserId || tab.id !== tabId) {
      throw new Error("browser/tab binding changed during coverage ownership");
    }
  }

  async function send(method, params = {}) {
    const result = await cdp.send(method, params);
    commandOrder.push(method);
    return result;
  }

  async function drainNetwork() {
    const redacted = [];
    let pages = 0;
    while (true) {
      pages += 1;
      if (pages > 10000) throw new Error("network event drain exceeded page limit");
      const options = {methods: NETWORK_METHODS};
      if (cursor !== undefined && cursor !== null) options.afterSequence = cursor;
      const page = await cdp.readEvents(options);
      if (page?.truncated === true) {
        throw new Error("network event history was truncated");
      }
      for (const event of Array.isArray(page?.events) ? page.events : []) {
        const safe = redactNetworkEvent(event);
        if (safe) redacted.push(safe);
      }
      const previous = cursor;
      cursor = page?.cursor ?? cursor;
      if (page?.hasMore !== true) break;
      if (JSON.stringify(previous) === JSON.stringify(cursor)) {
        throw new Error("network event cursor did not advance");
      }
    }
    return redacted;
  }

  async function cleanupProfiler() {
    const errors = [];
    if (!cdp) return errors;
    if (preciseStarted) {
      try {
        await send("Profiler.stopPreciseCoverage");
      } catch (error) {
        errors.push(error);
      }
      preciseStarted = false;
    }
    try {
      await send("Network.disable");
    } catch (error) {
      errors.push(error);
    }
    try {
      await send("Profiler.disable");
    } catch (error) {
      errors.push(error);
    }
    return errors;
  }

  async function start() {
    if (started || finalized) throw new Error("coverage owner already started");
    assertBinding();
    cdp = await tab.capabilities.get("cdp");
    if (!cdp || typeof cdp.send !== "function" || typeof cdp.readEvents !== "function") {
      throw new Error("documented CDP send/readEvents capability is required");
    }
    let failure;
    try {
      await send("Profiler.enable");
      await send("Network.enable");
      await drainNetwork();
      commandOrder.push("Network.readEvents");
      await send("Profiler.startPreciseCoverage", {
        callCount: true,
        detailed: true,
        allowTriggeredUpdates: false,
      });
      preciseStarted = true;
      assertBinding();
      const startRecord = {
        schema_version: 1,
        browser_id: browserId,
        tab_id: tabId,
        cdp_target_id: cdpTargetId,
        inert_url: safeUrl(inertUrl),
        frontend_origin: origin,
        owner_nonce: ownerNonce,
        network_cursor: cursor ?? null,
        started_at: now(),
        command_order: [...commandOrder],
      };
      const text = `${JSON.stringify(startRecord, null, 2)}\n`;
      exclusiveWrite(startPath, text);
      ownerStartSha = sha256(text);
      started = true;
      return {path: startPath, sha256: ownerStartSha};
    } catch (error) {
      failure = error;
      const cleanupErrors = await cleanupProfiler();
      throw aggregateError(failure, cleanupErrors);
    }
  }

  async function runAction(name, perform) {
    if (!started || finalized) throw new Error("coverage owner is not active");
    if (typeof name !== "string" || !name) throw new Error("action name is required");
    if (typeof perform !== "function") throw new Error("action callback is required");
    assertBinding();
    const beforeEvents = await drainNetwork();
    const beforeCursor = cursor ?? null;
    const startedAt = now();
    const result = await perform();
    assertBinding();
    const events = await drainNetwork();
    appendJsonLine(actionsPath, {
      schema_version: 1,
      action: name,
      browser_id: browserId,
      tab_id: tabId,
      owner_start_sha256: ownerStartSha,
      started_at: startedAt,
      completed_at: now(),
      cursor_before: beforeCursor,
      cursor_after: cursor ?? null,
      baseline_event_count: beforeEvents.length,
      network_events: events,
      truncated: false,
    });
    return result;
  }

  async function finalize({browserEnvelopeShas = []} = {}) {
    if (!started || finalized) throw new Error("coverage owner is not active");
    finalized = true;
    let failure;
    let precise;
    let takenAt;
    try {
      assertBinding();
      await drainNetwork();
      const result = await send("Profiler.takePreciseCoverage");
      takenAt = now();
      assertBinding();
      precise = sanitizePreciseCoverage(result);
      requireApplicationCoverage(precise, origin);
    } catch (error) {
      failure = error;
    }
    const cleanupErrors = await cleanupProfiler();
    const finalError = aggregateError(failure, cleanupErrors);
    if (finalError) throw finalError;

    const preciseText = JSON.stringify(precise);
    const rawRecord = {
      schema_version: 1,
      browser_id: browserId,
      tab_id: tabId,
      cdp_target_id: cdpTargetId,
      owner_nonce: ownerNonce,
      owner_start_sha256: ownerStartSha,
      browser_envelope_sha256: [...browserEnvelopeShas],
      frontend_origin: origin,
      taken_at: takenAt,
      finalized_at: now(),
      final_network_cursor: cursor ?? null,
      command_order: [...commandOrder],
      precise_result_sha256: sha256(preciseText),
      precise_result: precise,
    };
    const text = `${JSON.stringify(rawRecord, null, 2)}\n`;
    exclusiveAtomicWrite(rawPath, text, randomBytes);
    return {path: rawPath, sha256: sha256(text)};
  }

  return Object.freeze({start, runAction, finalize});
}
