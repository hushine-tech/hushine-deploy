from datetime import datetime, timedelta, timezone
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import ProxyHandler, Request, build_opener
import json

from .writer import append_jsonl, write_json


class ObservabilityUnavailable(RuntimeError):
    pass


DIRECT_OPENER = build_opener(ProxyHandler({}))


def fetch_json(url: str, timeout: float = 5.0) -> dict:
    req = Request(url, headers={"Accept": "application/json"})
    with DIRECT_OPENER.open(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def post_json(url: str, payload: dict, timeout: float = 10.0) -> dict:
    body = json.dumps(payload).encode("utf-8")
    req = Request(url, data=body, headers={"Accept": "application/json", "Content-Type": "application/json"}, method="POST")
    with DIRECT_OPENER.open(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def require_observability(ctx, cfg) -> None:
    obs = cfg.observability
    es_url = obs.get("elasticsearch_url", "").rstrip("/")
    jaeger_url = obs.get("jaeger_url", "").rstrip("/")
    checks = {"elasticsearch_url": es_url, "jaeger_url": jaeger_url, "checks": []}
    try:
        if not es_url or not jaeger_url:
            raise ObservabilityUnavailable("missing observability url")
        es_health = fetch_json(f"{es_url}/_cluster/health")
        checks["checks"].append({"name": "elasticsearch_health", "ok": True, "status": es_health.get("status")})
        services = fetch_json(f"{jaeger_url}/api/services")
        checks["checks"].append({"name": "jaeger_services", "ok": True, "count": len(services.get("data", []))})
    except (URLError, HTTPError, TimeoutError, OSError, ValueError, ObservabilityUnavailable) as exc:
        checks["failed"] = True
        checks["error"] = f"FAILED_PRECHECK: observability unavailable: {exc}"
        write_json(ctx.run_dir / "observability/precheck.json", checks)
        raise ObservabilityUnavailable(checks["error"]) from exc
    write_json(ctx.run_dir / "observability/precheck.json", checks)


def collect_observability_snapshot(ctx, cfg, window_minutes: int | None = None) -> dict:
    obs = cfg.observability
    es_url = obs.get("elasticsearch_url", "").rstrip("/")
    jaeger_url = obs.get("jaeger_url", "").rstrip("/")
    minutes = window_minutes or int(obs.get("lookback_minutes", 1440))
    end = datetime.now(timezone.utc)
    start = end - timedelta(minutes=minutes)
    try:
        logs = query_elasticsearch_logs(es_url, obs.get("es_index_patterns", ["app-logs-*"]), start, end)
        services = fetch_json(f"{jaeger_url}/api/services").get("data", [])
        traces = query_jaeger_traces(jaeger_url, services, start, end)
    except (URLError, HTTPError, TimeoutError, OSError, ValueError) as exc:
        write_json(ctx.run_dir / "observability/snapshot-error.json", {"error": str(exc)})
        raise ObservabilityUnavailable(f"FAILED_PRECHECK: observability unavailable: {exc}") from exc
    log_summary = summarize_logs(logs)
    trace_summary = summarize_traces(traces)
    endpoint_activity = summarize_endpoint_activity(logs, traces)
    write_json(ctx.run_dir / "observability/logs-summary.json", log_summary)
    write_json(ctx.run_dir / "observability/traces-summary.json", trace_summary)
    write_json(ctx.run_dir / "observability/endpoint-activity.json", endpoint_activity)
    for item in endpoint_activity.get("items", []):
        append_jsonl(ctx.run_dir / "evidence/observability.jsonl", {"kind": "observability", "subject": item["subject"], "source": item["source"], "confidence": "high", "details": item})
    return {"logs": log_summary, "traces": trace_summary, "endpoint_activity": endpoint_activity}


def query_elasticsearch_logs(es_url: str, patterns: list[str], start: datetime, end: datetime) -> list[dict]:
    hits = []
    body = {
        "size": 500,
        "query": {"range": {"@timestamp": {"gte": start.isoformat(), "lte": end.isoformat()}}},
        "sort": [{"@timestamp": {"order": "desc"}}],
    }
    for pattern in patterns:
        result = post_json(f"{es_url}/{pattern}/_search", body)
        hits.extend(result.get("hits", {}).get("hits", []))
    return hits


def query_jaeger_traces(jaeger_url: str, services: list[str], start: datetime, end: datetime) -> list[dict]:
    traces = []
    params_common = {
        "start": int(start.timestamp() * 1_000_000),
        "end": int(end.timestamp() * 1_000_000),
        "limit": 20,
    }
    for service in services[:20]:
        params = dict(params_common)
        params["service"] = service
        result = fetch_json(f"{jaeger_url}/api/traces?{urlencode(params)}", timeout=10.0)
        traces.extend(result.get("data", []))
    return traces


def summarize_logs(hits: list[dict]) -> dict:
    summary = {"total": len(hits), "by_service": {}, "by_log_type": {}, "trace_ids": []}
    trace_ids = set()
    for hit in hits:
        src = hit.get("_source", hit)
        service = first_value(src, ["service", "service_name", "app", "application"]) or "unknown"
        log_type = first_value(src, ["log_type", "type", "logger"]) or "unknown"
        trace_id = first_value(src, ["trace_id", "traceId", "traceID"])
        summary["by_service"][service] = summary["by_service"].get(service, 0) + 1
        summary["by_log_type"][log_type] = summary["by_log_type"].get(log_type, 0) + 1
        if trace_id:
            trace_ids.add(trace_id)
    summary["trace_ids"] = sorted(trace_ids)[:100]
    return summary


def summarize_traces(traces: list[dict]) -> dict:
    by_service = {}
    operations = {}
    for trace in traces:
        processes = trace.get("processes", {})
        for span in trace.get("spans", []):
            service = processes.get(span.get("processID"), {}).get("serviceName", "unknown")
            op = span.get("operationName", "unknown")
            by_service[service] = by_service.get(service, 0) + 1
            operations[op] = operations.get(op, 0) + 1
    return {"total": len(traces), "by_service": by_service, "operations": operations}


def summarize_endpoint_activity(logs: list[dict], traces: list[dict]) -> dict:
    items = []
    seen = set()
    for hit in logs:
        src = hit.get("_source", hit)
        service = first_value(src, ["service", "service_name", "app", "application"]) or "unknown"
        for key in ["grpc.method", "grpc_method", "method", "http.path", "path", "route", "kafka.topic", "topic"]:
            value = first_value(src, [key])
            if value:
                subject = f"{service}:{value}"
                marker = ("log", subject)
                if marker not in seen:
                    seen.add(marker)
                    items.append({"subject": subject, "source": "elasticsearch", "service": service, "field": key, "value": value})
    for trace in traces:
        processes = trace.get("processes", {})
        for span in trace.get("spans", []):
            service = processes.get(span.get("processID"), {}).get("serviceName", "unknown")
            op = span.get("operationName", "unknown")
            subject = f"{service}:{op}"
            marker = ("trace", subject)
            if marker not in seen:
                seen.add(marker)
                items.append({"subject": subject, "source": "jaeger", "service": service, "field": "operationName", "value": op})
    return {"items": items}


def first_value(data: dict, keys: list[str]):
    for key in keys:
        if key in data and data[key]:
            return data[key]
        if "." in key:
            cur = data
            ok = True
            for part in key.split("."):
                if isinstance(cur, dict) and part in cur:
                    cur = cur[part]
                else:
                    ok = False
                    break
            if ok and cur:
                return cur
    return None
