from dataclasses import asdict, dataclass
from pathlib import Path
import re

from .writer import write_json


@dataclass(frozen=True)
class BackendRoute:
    route: str
    file: str
    line: int
    prefix: bool


@dataclass(frozen=True)
class FrontendCall:
    route: str
    file: str
    line: int


@dataclass(frozen=True)
class HandlerMethod:
    name: str
    file: str
    line: int
    production_refs: int
    test_refs: int


ROUTE_LITERAL = re.compile(r'["`](/api/[^"`\s]+|/healthz)["`]')
MUX_ROUTE = re.compile(r'\bmux\.Handle(?:Func)?\s*\(\s*["`]([^"`]+)["`]')
FRONTEND_API = re.compile(r'["`](/api/[^"`]+)["`]|`[^`]*\$\{apiBase\(\)\}(/api/[^`]+)`')
SERVER_HANDLER = re.compile(r'^func \(s \*server\) (handle[A-Za-z0-9_]+)\(')
TEMPLATE_EXPR = re.compile(r'\$\{[^}]+\}|\{[^}/]+\}')
PARAM_SEGMENT = re.compile(r'(^|/):[^/]+')


def collect_handler_reachability(ctx, cfg) -> dict:
    quant_handler = next((service for service in cfg.services if service.get("name") == "quant-handler"), None)
    frontend = next((service for service in cfg.services if service.get("name") == "quant-frontend"), None)
    if not quant_handler:
        return {}

    backend_root = ctx.workspace / quant_handler["path"]
    frontend_root = ctx.workspace / frontend["path"] if frontend else None

    backend_routes = extract_backend_routes(ctx.workspace, backend_root / "internal/app/app.go")
    frontend_calls = extract_frontend_calls(ctx.workspace, frontend_root / "src/api/client.ts") if frontend_root else []
    handler_methods = extract_handler_methods(ctx.workspace, backend_root / "internal/app")

    candidates = []
    frontend_routes = [call.route for call in frontend_calls]
    backend_patterns = [route.route for route in backend_routes]

    for route in backend_routes:
        if not any(route_matches(frontend_route, route.route) for frontend_route in frontend_routes):
            candidates.append(with_confidence({
                "kind": "backend_route_no_frontend_call",
                "route": route.route,
                "file": route.file,
                "line": route.line,
                "protected": route.route in {"/healthz", "/api/auth/login", "/api/auth/signup"},
                "reason": "后端 BFF 暴露了入口，但前端 API client 中未发现匹配调用；可能是外部/调试/兼容入口，不能直接删除。",
            }))

    for call in frontend_calls:
        if not any(route_matches(call.route, backend_route) for backend_route in backend_patterns):
            candidates.append(with_confidence({
                "kind": "frontend_call_without_backend_route",
                "route": call.route,
                "file": call.file,
                "line": call.line,
                "protected": False,
                "reason": "前端调用没有匹配的 BFF route；这是潜在断链，不是删除候选。",
            }))

    for method in handler_methods:
        if method.production_refs == 0:
            candidates.append(with_confidence({
                "kind": "handler_method_unreferenced",
                "handler": method.name,
                "file": method.file,
                "line": method.line,
                "production_refs": method.production_refs,
                "test_refs": method.test_refs,
                "protected": False,
                "reason": "server handler 方法没有生产代码引用；若没有反射/生成入口，删除置信度较高。",
            }))

    report = {
        "backend_routes": [asdict(route) for route in backend_routes],
        "frontend_calls": [asdict(call) for call in frontend_calls],
        "handler_methods": [asdict(method) for method in handler_methods],
        "candidates": sorted(candidates, key=lambda item: item["deletion_confidence"], reverse=True),
    }
    write_json(ctx.run_dir / "inventory/handler-routes.json", report["backend_routes"])
    write_json(ctx.run_dir / "inventory/frontend-api-calls.json", report["frontend_calls"])
    write_json(ctx.run_dir / "inventory/handler-methods.json", report["handler_methods"])
    write_json(ctx.run_dir / "candidates/handler-reachability.json", report["candidates"])
    return report


def extract_backend_routes(workspace: Path, path: Path) -> list[BackendRoute]:
    if not path.exists():
        return []
    routes = []
    for line_no, line in enumerate(path.read_text(encoding="utf-8", errors="ignore").splitlines(), start=1):
        for match in MUX_ROUTE.finditer(line):
            raw = normalize_route(match.group(1))
            routes.append(BackendRoute(route=raw, file=str(path.relative_to(workspace)), line=line_no, prefix=raw.endswith("/")))
    return dedupe_routes(routes)


def extract_frontend_calls(workspace: Path, path: Path) -> list[FrontendCall]:
    if not path.exists():
        return []
    calls = []
    for line_no, line in enumerate(path.read_text(encoding="utf-8", errors="ignore").splitlines(), start=1):
        for match in FRONTEND_API.finditer(line):
            raw = next((group for group in match.groups() if group), None)
            if raw:
                calls.append(FrontendCall(route=normalize_route(raw), file=str(path.relative_to(workspace)), line=line_no))
    return dedupe_calls(calls)


def extract_handler_methods(workspace: Path, app_dir: Path) -> list[HandlerMethod]:
    if not app_dir.exists():
        return []
    source_files = sorted(app_dir.glob("*.go"))
    production_texts = {path: path.read_text(encoding="utf-8", errors="ignore") for path in source_files if not path.name.endswith("_test.go")}
    test_texts = {path: path.read_text(encoding="utf-8", errors="ignore") for path in source_files if path.name.endswith("_test.go")}
    methods = []
    for path, text in production_texts.items():
        for line_no, line in enumerate(text.splitlines(), start=1):
            match = SERVER_HANDLER.match(line)
            if not match:
                continue
            name = match.group(1)
            production_refs = count_method_refs(name, production_texts, definition=(path, line_no))
            test_refs = count_method_refs(name, test_texts, definition=None)
            methods.append(HandlerMethod(
                name=name,
                file=str(path.relative_to(workspace)),
                line=line_no,
                production_refs=production_refs,
                test_refs=test_refs,
            ))
    return methods


def count_method_refs(name: str, texts: dict[Path, str], definition: tuple[Path, int] | None) -> int:
    pattern = re.compile(r'\b' + re.escape(name) + r'\b')
    count = 0
    for path, text in texts.items():
        for line_no, line in enumerate(text.splitlines(), start=1):
            if definition and path == definition[0] and line_no == definition[1]:
                continue
            count += len(pattern.findall(line))
    return count


def normalize_route(raw: str) -> str:
    route = raw.strip()
    route = TEMPLATE_EXPR.sub(":param", route)
    route = route.replace("//", "/")
    if len(route) > 1 and route.endswith("?"):
        route = route[:-1]
    return route


def route_matches(frontend_route: str, backend_route: str) -> bool:
    front = normalize_route(frontend_route).rstrip("/")
    back = normalize_route(backend_route)
    if back.endswith("/"):
        return front.startswith(back.rstrip("/") + "/")
    if front == back.rstrip("/"):
        return True
    return False


def deletion_confidence(item: dict) -> int:
    if item.get("protected"):
        return 0
    kind = item.get("kind")
    if kind == "handler_method_unreferenced":
        score = 85
        if item.get("test_refs", 0) == 0:
            score += 5
        return min(score, 95)
    if kind == "backend_route_no_frontend_call":
        route = item.get("route", "")
        if route.startswith("/api/runtime-credentials") or route.startswith("/api/runtime-admission-failures"):
            return 25
        return 35
    if kind == "frontend_call_without_backend_route":
        return 0
    return 10


def with_confidence(item: dict) -> dict:
    item["deletion_confidence"] = deletion_confidence(item)
    return item


def dedupe_routes(routes: list[BackendRoute]) -> list[BackendRoute]:
    seen = set()
    out = []
    for route in routes:
        key = (route.route, route.file, route.line)
        if key not in seen:
            seen.add(key)
            out.append(route)
    return out


def dedupe_calls(calls: list[FrontendCall]) -> list[FrontendCall]:
    seen = set()
    out = []
    for call in calls:
        key = (call.route, call.file, call.line)
        if key not in seen:
            seen.add(key)
            out.append(call)
    return out
