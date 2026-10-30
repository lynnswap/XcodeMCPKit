"""Extract evidence from Apple crash logs without classifying the crash."""

from datetime import datetime
import json
import re


HANDLER_SYMBOLS = re.compile(
    r"\b(?:FIRCLSMachExceptionServer|FIRCLSMachExceptionReadMessage|"
    r"FIRCLSMachExceptionDispatchMessage|FIRCLSMachExceptionRecord|FIRCLSSignalHandler)\b"
)
LAUNCH_MARKER = "(terminated at launch; ignore backtrace)"
THREAD_HEADER = re.compile(r"^Thread[ \t]+(\d+)([ \t]+Crashed)?::?[^\n]*$")


def _text(value):
    if isinstance(value, str):
        return value.strip() or None
    if type(value) in (int, float):
        return str(value)
    return None


def _field(raw, label):
    match = re.search(r"^" + re.escape(label) + r":[ \t]*([^\n]*)", raw, re.MULTILINE)
    return match.group(1).strip() or None if match else None


def _date(value):
    if isinstance(value, datetime):
        parsed = value
    elif isinstance(value, str) and value.strip():
        normalized = re.sub(r"\s+([+-]\d{2}:?\d{2})$", r"\1", value.strip())
        if normalized.endswith("Z"):
            normalized = normalized[:-1] + "+00:00"
        normalized = re.sub(r"([+-]\d{2})(\d{2})$", r"\1:\2", normalized)
        normalized = re.sub(r"(\d{2}:\d{2}:\d{2})[.,](\d+)",
                            lambda match: match[1] + "." + match[2].ljust(6, "0")[:6], normalized)
        try:
            parsed = datetime.fromisoformat(normalized)
        except ValueError:
            return None
    else:
        return None
    return parsed if parsed.tzinfo is not None and parsed.utcoffset() is not None else None


def _log_date(value, label, warnings):
    parsed = _date(value)
    if parsed is None:
        warnings.append(f"{label} is missing, invalid, or has no timezone.")
    return parsed


def in_window(crashed_at, start, end):
    """Return inside/outside/unknown for the half-open, timezone-aware window.

    Arguments may be ISO 8601 strings or datetime objects. Missing or invalid
    timestamps, naive datetimes, and empty/reversed windows return unknown.
    """
    crashed, first, last = (_date(value) for value in (crashed_at, start, end))
    if crashed is None or first is None or last is None or first >= last:
        return "unknown"
    return "inside" if first <= crashed < last else "outside"


def _decode(raw, warnings):
    # .ips metadata and report are separate JSON objects, not a JSON array.
    rest = raw.lstrip()
    if not rest.startswith(("{", "[")):
        return {}, raw
    data = {}
    decoder = json.JSONDecoder()
    while rest:
        try:
            document, end = decoder.raw_decode(rest)
        except ValueError:
            warnings.append("JSON could not be fully decoded; available fields and text headers were retained.")
            return data, rest
        if not isinstance(document, dict):
            warnings.append("The JSON crash report is not an object.")
        else:
            data.update(document)
        rest = rest[end:].lstrip()
    return data, ""


def _text_stacks(raw, warnings):
    sections = []
    current = None
    in_stack = False
    handlers = []
    for line in raw.splitlines():
        header = THREAD_HEADER.match(line)
        if header:
            current = {"index": int(header.group(1)), "crashed": bool(header.group(2)), "frames": []}
            sections.append(current)
            in_stack = True
        elif line.startswith("Last Exception Backtrace:"):
            current = None
            in_stack = True
        elif re.match(r"^\s*\d+\s+", line) and in_stack:
            frame = line.strip()
            if current is not None:
                current["frames"].append(frame)
            if HANDLER_SYMBOLS.search(line):
                handlers.append(frame)
        elif line.strip():
            current = None
            in_stack = False
    selected = _field(raw, "Triggered by Thread") or _field(raw, "Crashed Thread")
    index = re.match(r"\d+\b", selected) if selected else None
    marked = [section for section in sections if section["crashed"]]
    if index is not None:
        number = int(index.group())
        if any(section["index"] != number for section in marked):
            warnings.append("Faulting thread headers disagree.")
            return [], handlers
        matches = [section for section in sections if section["index"] == number]
    else:
        matches = marked
    if len(matches) != 1:
        if sections:
            warnings.append("The faulting thread could not be uniquely identified.")
        return [], handlers
    return matches[0]["frames"][:40], handlers


def _json_frame(data, frame, thread_index, number):
    images = data.get("usedImages")
    image_index = frame.get("imageIndex")
    image = (images[image_index] if isinstance(images, list) and type(image_index) is int
             and 0 <= image_index < len(images) and isinstance(images[image_index], dict) else {})
    name = _text(frame.get("imageName")) or _text(image.get("name"))
    if name is None and isinstance(image.get("path"), str):
        name = image["path"].rsplit("/", 1)[-1]
    symbol = _text(frame.get("symbol"))
    if symbol is not None and type(frame.get("symbolLocation")) is int:
        symbol += f" + {frame['symbolLocation']}"
    elif symbol is None and type(frame.get("imageOffset")) is int:
        symbol = f"+ 0x{frame['imageOffset']:x}"
    detail = " ".join(value for value in (name, symbol) if value)
    return f"Thread {thread_index} frame {number}: " + (detail or json.dumps(frame, ensure_ascii=False))


def _json_stacks(data, warnings):
    threads = data.get("threads")
    if not isinstance(threads, list):
        return [], []
    stacks = {}
    handlers = []
    for index, thread in enumerate(threads):
        if not isinstance(thread, dict) or not isinstance(thread.get("frames"), list):
            continue
        frames = []
        for number, frame in enumerate(thread["frames"]):
            if not isinstance(frame, dict):
                warnings.append(f"Thread {index} frame {number} is not an object.")
                continue
            line = _json_frame(data, frame, index, number)
            frames.append(line)
            if isinstance(frame.get("symbol"), str) and HANDLER_SYMBOLS.search(frame["symbol"]):
                handlers.append(line)
        stacks[index] = frames
    triggered = [index for index, thread in enumerate(threads)
                 if isinstance(thread, dict) and thread.get("triggered") is True]
    index = data.get("faultingThread")
    if type(index) is not int:
        index = triggered[0] if len(triggered) == 1 else None
    if index is None or index not in stacks or (triggered and triggered != [index]):
        warnings.append("The faulting thread could not be uniquely identified.")
        return [], handlers
    return stacks[index][:40], handlers


def _has_marker(value):
    if isinstance(value, str):
        return LAUNCH_MARKER in value
    if isinstance(value, dict):
        return any(_has_marker(item) for item in value.values())
    if isinstance(value, list):
        return any(_has_marker(item) for item in value)
    return False


def parse_log(raw: str) -> dict:
    """Extract recorded timestamps and stack evidence; None means unknown.

    Handler frames may be on a waiting thread. Their presence does not imply
    that this crash was captured or uploaded, and their absence proves neither
    an early crash nor that Crashlytics was uninitialized.
    """
    warnings = []
    data, text = _decode(raw, warnings)
    bundle = data.get("bundleInfo")
    bundle = bundle if isinstance(bundle, dict) else {}
    version = _field(text, "Version")
    version_match = re.match(r"^(.*?)\s*\(([^()]*)\)\s*$", version or "")
    os_data = data.get("osVersion")
    os_version = (" ".join(filter(None, (_text(os_data.get("train")), _text(os_data.get("build")))))
                  if isinstance(os_data, dict) else _text(os_data))
    exception = data.get("exception")
    exception_type = (" ".join(filter(None, (_text(exception.get("type")), _text(exception.get("signal")))))
                      if isinstance(exception, dict) else _text(exception))
    termination = data.get("termination")
    reason = (json.dumps(termination, ensure_ascii=False) if isinstance(termination, dict)
              else _text(termination)) or _field(text, "Termination Reason")
    namespace = _text(termination.get("namespace")) if isinstance(termination, dict) else None
    if namespace is None and reason:
        match = re.match(r"^(?:Namespace\s+)?([A-Z][A-Z0-9_]*)\b", reason)
        namespace = match.group(1) if match else None
    crashed = _log_date(data.get("captureTime") or data.get("timestamp") or _field(text, "Date/Time"),
                        "Crash timestamp", warnings)
    launched = _log_date(data.get("procLaunch") or data.get("launchTime") or _field(text, "Launch Time"),
                         "Launch timestamp", warnings)
    elapsed = None
    if crashed is not None and launched is not None:
        if crashed < launched:
            warnings.append("Crash timestamp precedes launch timestamp; elapsed time is unknown.")
        else:
            elapsed = (crashed - launched).total_seconds()
    text_frames, text_handlers = _text_stacks(text, warnings)
    json_frames, json_handlers = _json_stacks(data, warnings)
    header = re.split(r"^(?:Thread \d+|Last Exception Backtrace:|Binary Images:)",
                      text, maxsplit=1, flags=re.MULTILINE)[0]
    return {
        "crashedAt": crashed.isoformat() if crashed else None,
        "launchedAt": launched.isoformat() if launched else None,
        "elapsedSeconds": elapsed,
        "appVersion": _text(bundle.get("CFBundleShortVersionString")) or _text(data.get("app_version"))
            or (version_match.group(1).strip() if version_match else version),
        "build": _text(bundle.get("CFBundleVersion")) or _text(data.get("build_version"))
            or (version_match.group(2) if version_match else None),
        "osVersion": os_version or _text(data.get("os_version")) or _field(text, "OS Version"),
        "hardware": _text(data.get("modelCode")) or _text(data.get("hardwareModel")) or _field(text, "Hardware Model"),
        "exceptionType": exception_type or _field(text, "Exception Type"),
        "terminationReason": reason,
        "terminationNamespace": namespace,
        "faultingThreadFrames": json_frames or text_frames,
        "launchTerminationMarker": _has_marker(termination) or LAUNCH_MARKER in header,
        "crashlyticsHandlerFrames": list(dict.fromkeys(json_handlers + text_handlers)),
        "parseWarnings": warnings,
    }
