import assert from "node:assert/strict";
import {spawnSync} from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {fileURLToPath} from "node:url";

import {createBrowserCoverageOwner} from "../browser_coverage_owner.mjs";


const HERE = path.dirname(fileURLToPath(import.meta.url));
const NORMALIZER = path.join(HERE, "..", "frontend_coverage.mjs");
const APP_ORIGIN = "http://127.0.0.1:5173";

function sha256(data) {
  return crypto.createHash("sha256").update(data).digest("hex");
}

function fakeFixture({takeFails = false, truncated = false} = {}) {
  const calls = [];
  let readCount = 0;
  const cdp = {
    async send(method, params = {}) {
      calls.push({kind: "cdp", method, params});
      if (method === "Profiler.takePreciseCoverage") {
        if (takeFails) throw new Error("injected take failure");
        return {
          result: [{
            scriptId: "7",
            url: `${APP_ORIGIN}/assets/app.js?private=drop#fragment`,
            functions: [{
              functionName: "render",
              ranges: [{startOffset: 0, endOffset: 100, count: 1}],
              isBlockCoverage: true,
            }],
          }],
        };
      }
      return {};
    },
    async readEvents(options) {
      calls.push({kind: "events", options});
      readCount += 1;
      if (readCount === 1) {
        return {events: [], cursor: 10, hasMore: false, truncated: false};
      }
      if (readCount === 2) {
        return {events: [], cursor: 11, hasMore: false, truncated: false};
      }
      if (readCount === 3) {
        return {
          events: [{
            method: "Network.requestWillBeSent",
            sequence: 12,
            params: {
              requestId: "request-1",
              request: {
                method: "POST",
                url: `${APP_ORIGIN}/api/orders?api_key=never-write#secret`,
                headers: {Authorization: "Bearer never-write", Cookie: "secret"},
                postData: "credential=never-write",
              },
            },
          }],
          cursor: 12,
          hasMore: true,
          truncated,
        };
      }
      if (readCount === 4) {
        return {
          events: [{
            method: "Network.responseReceived",
            sequence: 13,
            params: {
              requestId: "request-1",
              response: {
                url: `${APP_ORIGIN}/api/orders?api_key=never-write`,
                status: 201,
                headers: {"Set-Cookie": "never-write"},
              },
            },
          }],
          cursor: 13,
          hasMore: false,
          truncated: false,
        };
      }
      return {events: [], cursor: 14, hasMore: false, truncated: false};
    },
  };
  let capabilityGets = 0;
  const tab = {
    id: "opaque-tab-1",
    capabilities: {
      async get(name) {
        capabilityGets += 1;
        assert.equal(name, "cdp");
        return cdp;
      },
    },
  };
  const browser = {id: "browser-1"};
  return {browser, tab, cdp, calls, get capabilityGets() { return capabilityGets; }};
}

test("one retained owner starts before actions, drains cursors, redacts, and finalizes", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "browser-owner-"));
  try {
    const fixture = fakeFixture();
    const owner = createBrowserCoverageOwner({
      browser: fixture.browser,
      tab: fixture.tab,
      runDir: root,
      inertUrl: `${APP_ORIGIN}/coverage-owner.html`,
      frontendOrigin: APP_ORIGIN,
      randomBytes: () => Buffer.alloc(32, 0x11),
      now: (() => {
        let tick = 0;
        return () => new Date(Date.UTC(2026, 6, 23, 0, 0, tick++)).toISOString();
      })(),
    });
    assert.equal(Object.hasOwn(owner, "nonce"), false);
    assert.equal(Object.hasOwn(owner, "cdp"), false);

    const started = await owner.start();
    await assert.rejects(() => owner.start(), /already started/);
    await owner.runAction("navigate-application", async () => {
      fixture.calls.push({kind: "action", name: "navigate-application"});
    });
    const finalized = await owner.finalize({browserEnvelopeShas: ["b".repeat(64)]});

    assert.equal(fixture.capabilityGets, 1);
    const ordered = fixture.calls.map((entry) =>
      entry.kind === "cdp" ? entry.method : entry.kind === "action" ? "ACTION" : "EVENTS"
    );
    assert.deepEqual(ordered.slice(0, 4), [
      "Profiler.enable",
      "Network.enable",
      "EVENTS",
      "Profiler.startPreciseCoverage",
    ]);
    assert.ok(ordered.indexOf("Profiler.startPreciseCoverage") < ordered.indexOf("ACTION"));
    assert.equal(ordered.filter((value) => value === "Profiler.startPreciseCoverage").length, 1);
    assert.equal(ordered.filter((value) => value === "Profiler.takePreciseCoverage").length, 1);
    assert.equal(ordered.filter((value) => value === "Profiler.stopPreciseCoverage").length, 1);
    assert.equal(ordered.filter((value) => value === "Network.disable").length, 1);
    assert.equal(ordered.filter((value) => value === "Profiler.disable").length, 1);
    const eventReads = fixture.calls.filter((entry) => entry.kind === "events");
    assert.equal(eventReads[2].options.afterSequence, 11);
    assert.equal(eventReads[3].options.afterSequence, 12);

    const startBytes = fs.readFileSync(started.path);
    assert.equal(started.sha256, sha256(startBytes));
    const start = JSON.parse(startBytes);
    assert.equal(start.browser_id, "browser-1");
    assert.equal(start.tab_id, "opaque-tab-1");
    assert.equal(start.owner_nonce, "11".repeat(32));
    assert.equal(start.command_order.at(-1), "Profiler.startPreciseCoverage");
    const actions = fs.readFileSync(path.join(root, "browser/actions.jsonl"), "utf8");
    assert.match(actions, /\/api\/orders/);
    assert.doesNotMatch(actions, /api_key|Authorization|Bearer|Cookie|credential|never-write/);

    const rawText = fs.readFileSync(finalized.path, "utf8");
    const raw = JSON.parse(rawText);
    assert.equal(raw.browser_id, start.browser_id);
    assert.equal(raw.tab_id, start.tab_id);
    assert.equal(raw.owner_nonce, start.owner_nonce);
    assert.equal(raw.owner_start_sha256, started.sha256);
    assert.equal(raw.precise_result_sha256, sha256(JSON.stringify(raw.precise_result)));
    assert.deepEqual(raw.browser_envelope_sha256, ["b".repeat(64)]);
    assert.equal(raw.precise_result.result[0].functions[0].ranges.length, 1);

    const normalized = path.join(root, "coverage/frontend-precise.json");
    const normalizer = subprocessSync([
      "node", NORMALIZER, "external-owner/normalize",
      "--raw", finalized.path,
      "--owner-start", started.path,
      "--output", normalized,
    ]);
    assert.equal(normalizer.status, 0, normalizer.output);
    const normalizedValue = JSON.parse(fs.readFileSync(normalized, "utf8"));
    assert.equal(normalizedValue.owner_start_sha256, started.sha256);
    assert.equal(normalizedValue.raw_artifact_sha256, sha256(rawText));
  } finally {
    fs.rmSync(root, {recursive: true, force: true});
  }
});

test("truncated network pages fail and precise-take failure still disables", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "browser-owner-failure-"));
  try {
    const truncated = fakeFixture({truncated: true});
    const owner = createBrowserCoverageOwner({
      browser: truncated.browser,
      tab: truncated.tab,
      runDir: root,
      inertUrl: `${APP_ORIGIN}/coverage-owner.html`,
      frontendOrigin: APP_ORIGIN,
    });
    await owner.start();
    await assert.rejects(() => owner.runAction("bad", async () => {}), /truncated/);

    const failureRoot = fs.mkdtempSync(path.join(os.tmpdir(), "browser-owner-take-"));
    try {
      const takeFailure = fakeFixture({takeFails: true});
      const failingOwner = createBrowserCoverageOwner({
        browser: takeFailure.browser,
        tab: takeFailure.tab,
        runDir: failureRoot,
        inertUrl: `${APP_ORIGIN}/coverage-owner.html`,
        frontendOrigin: APP_ORIGIN,
      });
      await failingOwner.start();
      await assert.rejects(() => failingOwner.finalize(), /injected take failure/);
      const methods = takeFailure.calls
        .filter((entry) => entry.kind === "cdp")
        .map((entry) => entry.method);
      assert.equal(methods.filter((method) => method === "Profiler.stopPreciseCoverage").length, 1);
      assert.equal(methods.filter((method) => method === "Network.disable").length, 1);
      assert.equal(methods.filter((method) => method === "Profiler.disable").length, 1);
    } finally {
      fs.rmSync(failureRoot, {recursive: true, force: true});
    }
  } finally {
    fs.rmSync(root, {recursive: true, force: true});
  }
});

test("normalizer rejects profiler ownership flags", () => {
  for (const flag of ["--chrome-debug-url", "--attach", "--start-profiler"]) {
    const result = subprocessSync(["node", NORMALIZER, flag, "value"]);
    assert.notEqual(result.status, 0, flag);
  }
});

function subprocessSync(argv) {
  const result = spawnSync(argv[0], argv.slice(1), {encoding: "utf8"});
  return {status: result.status, output: `${result.stdout}${result.stderr}`};
}
