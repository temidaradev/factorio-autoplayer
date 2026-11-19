"""MCP controls for the Factorio process inside the container's private X display."""
import base64
from contextlib import ExitStack
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid

WIDTH, HEIGHT = 1280, 800
DISPLAY_ENV = dict(os.environ, DISPLAY=":99")
BUTTONS = {"left": "1", "middle": "2", "right": "3"}
MODIFIERS = {"shift": "Shift_L", "control": "Control_L"}
KEYS = {
    "left": "Left", "right": "Right", "up": "Up", "down": "Down",
    "escape": "Escape", "space": "space", "return": "Return",
    "tab": "Tab", "delete": "BackSpace",
}
TYPES = ("move", "click", "drag", "scroll", "key", "text", "wait")


def run(*args, timeout=3):
    return subprocess.run(args, env=DISPLAY_ENV, check=True, capture_output=True,
                          timeout=timeout).stdout


def x(*args):
    return run("xdotool", *map(str, args))


def game_pid():
    pid = int(Path("/tmp/factorio.pid").read_text())
    os.kill(pid, 0)
    return pid


def focused():
    try:
        return int(x("getwindowfocus", "getwindowpid")) == game_pid()
    except (ValueError, OSError, subprocess.SubprocessError):
        return False


def require_focus():
    if not focused():
        raise ValueError("The Factorio window lost focus on its private display.")


def game_running():
    try:
        game_pid()
        return True
    except (ValueError, OSError):
        return False


def point(value):
    if not isinstance(value, dict):
        raise ValueError("Provide point coordinates from the screenshot.")
    px, py = value.get("x"), value.get("y")
    if type(px) is not int or type(py) is not int or not (5 <= px < WIDTH - 5 and 5 <= py < HEIGHT - 5):
        raise ValueError("Pointer coordinates must be at least five pixels inside the image.")
    return px, py


def prepare(action):
    kind = action["type"]
    if kind not in TYPES:
        raise ValueError("Unknown action.")
    mods = action.get("modifiers", [])
    if not isinstance(mods, list) or any(m not in MODIFIERS for m in mods) or len(set(mods)) != len(mods):
        raise ValueError("Use unique shift or control modifiers.")
    if mods and kind not in ("key", "click", "drag"):
        raise ValueError("Modifiers apply only to key, click and drag actions.")
    duration = action.get("durationMs", {"click": 70, "key": 70, "drag": 240, "wait": 250}.get(kind, 0))
    minimum = {"click": 35, "key": 35, "drag": 120}.get(kind, 0)
    if type(duration) is not int or not minimum <= duration <= 3300:
        raise ValueError(f"Duration for {kind} must be between {minimum} and 3300 ms.")
    args = ()
    if kind in ("move", "click", "drag", "scroll"):
        args = (point(action.get("at")),)
    if kind == "click":
        args += (BUTTONS[action.get("button", "left")],)
    elif kind == "drag":
        args += (point(action.get("to")),)
    elif kind == "scroll":
        ticks = action.get("ticks")
        if type(ticks) is not int or not 1 <= abs(ticks) <= 8:
            raise ValueError("Scroll takes one to eight ticks in either direction.")
        args += (ticks,)
    elif kind == "key":
        name = action.get("key", "")
        keys = name.split("+")
        singles = len(keys) == 1 and (name in KEYS or re.fullmatch("[a-z0-9]", name))
        diagonals = len(keys) == 2 and set(keys) in ({"w", "d"}, {"w", "a"}, {"s", "a"}, {"s", "d"})
        if not (singles or diagonals) or ("control" in mods and name not in "c f v x y z".split()):
            raise ValueError("Unsupported gameplay key or modifier combination.")
        args = tuple(KEYS.get(k, k) for k in keys)
    elif kind == "text":
        value = action.get("text", "")
        if "durationMs" in action or not re.fullmatch("[a-zA-Z0-9 _-]{1,64}", value):
            raise ValueError("Use up to 64 letters, digits, spaces, hyphens or underscores.")
        args = (value,)
        duration = len(value) * 18
    return kind, args, mods, duration


def hold(ms):
    deadline = time.monotonic() + ms / 1000
    while (remaining := deadline - time.monotonic()) > 0:
        time.sleep(min(0.08, remaining))
        require_focus()


def press(active, down, up, code):
    active.callback(x, up, code)
    x(down, code)


def execute(kind, args, modifiers, duration):
    require_focus()
    with ExitStack() as active:
        for mod in modifiers:
            press(active, "keydown", "keyup", MODIFIERS[mod])
        if kind in ("move", "click", "drag", "scroll"):
            x("mousemove", *args[0])
            hold(45)
        if kind == "click":
            press(active, "mousedown", "mouseup", args[1])
        elif kind == "key":
            for key in args:
                press(active, "keydown", "keyup", key)
        elif kind == "scroll":
            ticks = args[1]
            x("click", "--repeat", abs(ticks), "--delay", 25, 4 if ticks > 0 else 5)
        elif kind == "text":
            x("type", "--delay", 18, "--", args[0])
            return
        elif kind == "drag":
            press(active, "mousedown", "mouseup", "1")
            (a, b), (c, d) = args
            steps = max(4, duration // 40)
            for i in range(1, steps + 1):
                hold(duration / steps)
                x("mousemove", round(a + (c - a) * i / steps), round(b + (d - b) * i / steps))
            return
        hold(duration)


POINT = {"type": "object", "required": ["x", "y"], "properties": {
    "x": {"type": "integer"}, "y": {"type": "integer"}}}
ACTION = {"type": "object", "required": ["type"], "properties": {
    "type": {"enum": TYPES}, "at": POINT, "to": POINT, "button": {"enum": tuple(BUTTONS)},
    "key": {"type": "string", "description": "Letters, digits, arrow keys, space, escape, return, tab, delete or diagonal w+d."},
    "text": {"type": "string", "maxLength": 64}, "modifiers": {"type": "array", "items": {"enum": tuple(MODIFIERS)}},
    "ticks": {"type": "integer", "minimum": -8, "maximum": 8},
    "durationMs": {"type": "integer", "minimum": 0, "maximum": 3300},
}}
BATCH = {"type": "object", "required": ["frameId", "actions"], "properties": {
    "frameId": {"type": "string"}, "actions": {"type": "array", "minItems": 1, "maxItems": 12, "items": ACTION}}}


def definition(name, description, schema=None):
    return {"name": f"factorio_{name}", "description": description,
            "inputSchema": schema or {"type": "object", "additionalProperties": False}}


def text_result(message, is_error=False):
    return {"content": [{"type": "text", "text": message}], "isError": is_error}


class Server:
    def __init__(self, allow_input):
        self.allow_input = allow_input
        self.frame = None
        self.tools = [
            definition("status", "Check Factorio in its isolated Linux display."),
            definition("observe", "Capture only the private game display and return a fresh frame ID."),
        ]
        if allow_input:
            self.tools += [
                definition("focus", "Focus Factorio on its private display. Does not affect the Mac."),
                definition("act", "Send up to 12 normal gameplay actions within four seconds, then inspect a fresh frame.", BATCH),
            ]

    def dispatch(self, method, params):
        if method == "initialize":
            supported = ("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05")
            version = params.get("protocolVersion")
            return {"protocolVersion": version if version in supported else supported[0],
                    "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": {"name": "factorio-background", "version": "0.1.0"}}
        if method == "ping":
            return {}
        if method == "tools/list":
            return {"tools": self.tools}
        if method == "tools/call":
            name = params.get("name")
            if name not in {tool["name"] for tool in self.tools}:
                return text_result("This tool is unavailable in the current mode.", True)
            return self.call(name, params.get("arguments", {}))
        raise NotImplementedError("Unknown method")

    def call(self, name, args):
        if name == "factorio_status":
            return text_result(json.dumps({"factorioRunning": game_running(), "factorioInFront": focused(),
                                           "inputEnabledByOperator": self.allow_input, "background": True}))
        if name == "factorio_focus":
            self.frame = None
            if not focused():
                windows = x("search", "--onlyvisible", "--pid", game_pid()).splitlines()
                if len(windows) != 1:
                    raise ValueError("Could not identify a single visible Factorio window.")
                x("windowactivate", "--sync", windows[0].decode())
                require_focus()
            return text_result("Factorio is focused on the private display.")
        if name == "factorio_observe":
            self.frame = None
            if not game_running():
                raise ValueError("Factorio has not started or has exited. Check the container log.")
            data = run("import", "-window", "root", "png:-", timeout=8)
            frame_id = str(uuid.uuid4())
            self.frame = (frame_id, time.monotonic())
            return {"content": [
                {"type": "text", "text": f"frameId: {frame_id}\nwidth: {WIDTH}\nheight: {HEIGHT}"},
                {"type": "image", "mimeType": "image/png", "data": base64.b64encode(data).decode()},
            ]}
        if self.frame is None or args.get("frameId") != self.frame[0] or time.monotonic() - self.frame[1] > 60:
            raise ValueError("Observe again and use the current frame ID within 60 seconds.")
        steps = args.get("actions", [])
        if not isinstance(steps, list) or not 1 <= len(steps) <= 12:
            raise ValueError("Send one to twelve actions.")
        actions = [prepare(step) for step in steps]
        if sum(step[3] + 75 for step in actions) > 4000:
            raise ValueError("Reduce the batch to four seconds including input overhead.")
        self.frame = None
        completed = 0
        try:
            for action in actions:
                execute(*action)
                completed += 1
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            return text_result(json.dumps({"completed": completed, "requested": len(actions), "error": str(error)}), True)
        return text_result(json.dumps({"completed": completed, "requested": len(actions)}))


def serve(server):
    for line in sys.stdin:
        request_id = None
        try:
            message = json.loads(line)
            if "id" not in message:
                continue
            request_id = message["id"]
            result = server.dispatch(message["method"], message.get("params", {}))
            payload = {"result": result}
        except NotImplementedError as error:
            payload = {"error": {"code": -32601, "message": str(error)}}
        except (KeyError, ValueError, TypeError, AttributeError, OSError, subprocess.SubprocessError) as error:
            payload = {"result": text_result(str(error), True)}
        print(json.dumps({"jsonrpc": "2.0", "id": request_id, **payload}), flush=True)


def main():
    allow = sys.argv[1:] == ["--allow-input"]
    if sys.argv[1:] and not allow:
        sys.exit("Usage: mcp.py [--allow-input]")
    with ExitStack() as resources:
        if allow:
            lock = resources.enter_context(open("/tmp/factorio-input.lock", "a"))
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                sys.exit("Another Factorio player owns the background input session.")
        serve(Server(allow))


if __name__ == "__main__":
    main()
