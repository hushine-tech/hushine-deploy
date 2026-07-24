#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import {pathToFileURL} from "node:url";


function sha256(data) {
  return crypto.createHash("sha256").update(data).digest("hex");
}

function parseArguments(argv) {
  if (argv[0] !== "external-owner/normalize") {
    throw new Error("only external-owner/normalize mode is supported");
  }
  const allowed = new Set(["--raw", "--owner-start", "--output"]);
  const values = {};
  for (let index = 1; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!allowed.has(flag) || value === undefined || value.startsWith("--")) {
      throw new Error(`unsupported or incomplete argument: ${flag}`);
    }
    if (Object.hasOwn(values, flag)) throw new Error(`duplicate argument: ${flag}`);
    values[flag] = value;
  }
  for (const required of allowed) {
    if (!values[required]) throw new Error(`${required} is required`);
  }
  return {
    raw: path.resolve(values["--raw"]),
    ownerStart: path.resolve(values["--owner-start"]),
    output: path.resolve(values["--output"]),
  };
}

function readRegularFile(file) {
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    throw new Error(`expected a regular non-symlink file: ${file}`);
  }
  return fs.readFileSync(file, "utf8");
}

function validateSha(value, field) {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/.test(value)) {
    throw new Error(`${field} must be a SHA-256 hex digest`);
  }
}

function countCommand(order, name) {
  return order.filter((entry) => entry === name).length;
}

function validateCoverage(raw) {
  const scripts = raw?.precise_result?.result;
  if (!Array.isArray(scripts)) throw new Error("precise_result.result must be an array");
  const prefix = `${new URL(raw.frontend_origin).origin}/`;
  const application = scripts.filter((script) =>
    typeof script.url === "string"
    && script.url.startsWith(prefix)
    && !script.url.includes("?")
    && !script.url.includes("#")
    && Array.isArray(script.functions)
    && script.functions.some((fn) =>
      Array.isArray(fn.ranges) && fn.ranges.length > 0
    )
  );
  if (application.length === 0) throw new Error("no nonempty application coverage found");
  return application;
}

function exclusiveAtomicWrite(file, text) {
  fs.mkdirSync(path.dirname(file), {recursive: true, mode: 0o700});
  const temporary = `${file}.tmp-${crypto.randomBytes(12).toString("hex")}`;
  const descriptor = fs.openSync(temporary, "wx", 0o600);
  try {
    fs.writeFileSync(descriptor, text, {encoding: "utf8"});
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  try {
    fs.linkSync(temporary, file);
  } finally {
    fs.unlinkSync(temporary);
  }
}

export function normalizeExternalOwner({raw: rawPath, ownerStart: startPath, output}) {
  const rawText = readRegularFile(rawPath);
  const startText = readRegularFile(startPath);
  const raw = JSON.parse(rawText);
  const start = JSON.parse(startText);
  const startSha = sha256(startText);
  if (raw.owner_start_sha256 !== startSha) throw new Error("owner-start SHA mismatch");
  for (const field of ["browser_id", "tab_id", "owner_nonce"]) {
    if (!raw[field] || raw[field] !== start[field]) {
      throw new Error(`${field} binding mismatch`);
    }
  }
  if ((raw.cdp_target_id ?? null) !== (start.cdp_target_id ?? null)) {
    throw new Error("cdp_target_id mismatch");
  }
  validateSha(raw.precise_result_sha256, "precise_result_sha256");
  if (sha256(JSON.stringify(raw.precise_result)) !== raw.precise_result_sha256) {
    throw new Error("precise result hash mismatch");
  }
  for (const digest of raw.browser_envelope_sha256 || []) {
    validateSha(digest, "browser_envelope_sha256");
  }
  const order = raw.command_order;
  if (!Array.isArray(order)) throw new Error("command_order must be an array");
  for (const command of [
    "Profiler.enable",
    "Network.enable",
    "Profiler.startPreciseCoverage",
    "Profiler.takePreciseCoverage",
    "Profiler.stopPreciseCoverage",
    "Network.disable",
    "Profiler.disable",
  ]) {
    if (countCommand(order, command) !== 1) {
      throw new Error(`expected exactly one ${command}`);
    }
  }
  if (
    order.indexOf("Profiler.startPreciseCoverage")
      >= order.indexOf("Profiler.takePreciseCoverage")
    || order.indexOf("Profiler.takePreciseCoverage")
      >= order.indexOf("Profiler.stopPreciseCoverage")
  ) {
    throw new Error("Profiler command order is invalid");
  }
  const application = validateCoverage(raw);
  const normalized = {
    schema_version: 1,
    browser_id: raw.browser_id,
    tab_id: raw.tab_id,
    cdp_target_id: raw.cdp_target_id ?? null,
    owner_nonce: raw.owner_nonce,
    owner_start_sha256: startSha,
    raw_artifact_sha256: sha256(rawText),
    precise_result_sha256: raw.precise_result_sha256,
    browser_envelope_sha256: raw.browser_envelope_sha256 || [],
    frontend_origin: raw.frontend_origin,
    application_script_count: application.length,
    application_function_count: application.reduce(
      (sum, script) => sum + script.functions.length,
      0,
    ),
    application_range_count: application.reduce(
      (sum, script) => sum + script.functions.reduce(
        (inner, fn) => inner + fn.ranges.length,
        0,
      ),
      0,
    ),
    command_order: order,
    precise_result: raw.precise_result,
  };
  exclusiveAtomicWrite(output, `${JSON.stringify(normalized, null, 2)}\n`);
  return normalized;
}

function main(argv) {
  const args = parseArguments(argv);
  normalizeExternalOwner(args);
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
