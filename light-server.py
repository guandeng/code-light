"""
CodeLight 红绿灯可视化服务（多实例版）
- 每个 Claude Code 会话独立跟踪
- 聚合显示最严重状态（error > working > fixing > thinking > idle）
- 单实例时行为与之前完全一致
"""

import os
import time
from collections import deque
from flask import Flask, jsonify, request

# ============================================================
# 配置区
# ============================================================
USE_HARDWARE = False
SERIAL_PORT = "/dev/ttyUSB0"
SERIAL_BAUD = 115200

STATE_IDLE = "idle"
STATE_THINKING = "thinking"
STATE_WORKING = "working"
STATE_FIXING = "fixing"
STATE_ERROR = "error"

# 严重程度排序：error > working > fixing > thinking > idle
SEVERITY = {STATE_ERROR: 4, STATE_WORKING: 3, STATE_FIXING: 3, STATE_THINKING: 2, STATE_IDLE: 0}

LIGHT_COLORS = {
    STATE_IDLE:     {"red": 0, "yellow": 0, "green": 1, "label": "空闲中", "css": "#00B329", "blink": False},
    STATE_THINKING: {"red": 0, "yellow": 1, "green": 0, "label": "思考中", "css": "#FFCC00", "blink": False},
    STATE_WORKING:  {"red": 1, "yellow": 0, "green": 0, "label": "执行中", "css": "#D90000", "blink": True},
    STATE_FIXING:   {"red": 0, "yellow": 1, "green": 0, "label": "修复中", "css": "#FFCC00", "blink": True},
    STATE_ERROR:    {"red": 1, "yellow": 0, "green": 0, "label": "报错",   "css": "#D90000", "blink": False},
}

app = Flask(__name__)

# 多会话状态存储: {session_id: {state, message, timestamp, light}}
sessions = {}
state_history = deque(maxlen=MAX_HISTORY)
MAX_HISTORY = 100
SESSION_TIMEOUT = 300  # 5分钟无更新自动降为idle

serial_conn = None


def get_serial():
    global serial_conn
    if not USE_HARDWARE:
        return None
    if serial_conn is None:
        try:
            import serial
            serial_conn = serial.Serial(SERIAL_PORT, SERIAL_BAUD, timeout=1)
        except Exception as e:
            print(f"[硬件] 串口连接失败: {e}")
    return serial_conn


def send_to_hardware(light):
    ser = get_serial()
    if ser is None:
        return
    cmd = f"LED:{light['red']},{light['yellow']},{light['green']}\n"
    try:
        ser.write(cmd.encode())
    except Exception as e:
        print(f"[硬件] 发送失败: {e}")
        global serial_conn
        serial_conn = None


def cleanup_stale_sessions():
    """超时会话自动降为 idle，而不是删除"""
    now = time.time()
    for sid, s in list(sessions.items()):
        if now - s["timestamp"] > SESSION_TIMEOUT and s["state"] != STATE_IDLE:
            print(f"[清理] 会话超时降级: {sid[:16]} {s['state']} → idle")
            s["state"] = STATE_IDLE
            s["message"] = "超时"
            s["light"] = LIGHT_COLORS[STATE_IDLE]
            s["timestamp"] = now
    # 删除超过 1 小时的真正死会话
    dead = [sid for sid, s in sessions.items() if now - s["timestamp"] > 3600]
    for sid in dead:
        del sessions[sid]


def get_aggregate_state():
    """聚合所有会话，取最严重状态"""
    cleanup_stale_sessions()

    if not sessions:
        light = LIGHT_COLORS[STATE_IDLE]
        return {
            "state": STATE_IDLE,
            "timestamp": time.time(),
            "message": "",
            "light": light,
            "sessions": {},
            "active_count": 0,
        }

    # 找最严重的状态
    worst_sid = max(sessions, key=lambda sid: SEVERITY.get(sessions[sid]["state"], 0))
    worst = sessions[worst_sid]

    # 统计活跃数（非idle）
    active = sum(1 for s in sessions.values() if s["state"] != STATE_IDLE)

    # 生成摘要 message
    if len(sessions) == 1:
        msg = worst["message"]
        label = worst["light"]["label"]
    else:
        state_counts = {}
        for s in sessions.values():
            st = s["state"]
            if st != STATE_IDLE:
                state_counts[st] = state_counts.get(st, 0) + 1
        if state_counts:
            parts = [f"{LIGHT_COLORS[k]['label']}×{v}" for k, v in state_counts.items()]
            msg = f"共{len(sessions)}个会话: {', '.join(parts)}"
        else:
            msg = f"{len(sessions)}个会话均空闲"
        label = worst["light"]["label"]

    result_light = dict(worst["light"])
    result_light["label"] = label

    result = {
        "state": worst["state"],
        "timestamp": worst["timestamp"],
        "message": msg,
        "light": result_light,
        "sessions": {sid: {"state": s["state"], "message": s["message"], "light": s["light"]["label"]} for sid, s in sessions.items()},
        "active_count": active,
    }

    if USE_HARDWARE:
        send_to_hardware(result_light)

    return result


# ============================================================
# REST API
# ============================================================

@app.route("/api/state", methods=["GET"])
def get_state():
    return jsonify(get_aggregate_state())


@app.route("/api/state", methods=["POST"])
def update_state():
    data = request.get_json(silent=True) or {}
    state = data.get("state", "")
    message = data.get("message", "")
    session_id = data.get("session_id", "")

    if not session_id:
        session_id = request.remote_addr or "default"

    if state not in LIGHT_COLORS:
        return jsonify({"ok": False, "error": f"invalid state: {state}"}), 400

    light = LIGHT_COLORS[state]
    sessions[session_id] = {
        "state": state,
        "timestamp": time.time(),
        "message": message,
        "light": light,
    }

    agg = get_aggregate_state()
    state_history.append({
        "timestamp": time.time(),
        "state": state,
        "message": message,
        "session_id": session_id[:8],
        "light": light,
    })

    print(f"[状态] [{session_id[:8]}] {state} — {light['label']} {message}")
    return jsonify({"ok": True, "current": agg})


@app.route("/api/history", methods=["GET"])
def get_history():
    return jsonify(state_history)


@app.route("/api/sessions", methods=["GET"])
def get_sessions():
    """查看所有活跃会话"""
    cleanup_stale_sessions()
    return jsonify({
        "count": len(sessions),
        "sessions": {sid: {
            "state": s["state"],
            "message": s["message"],
            "age": f"{time.time() - s['timestamp']:.0f}s",
            "light": s["light"]["label"],
        } for sid, s in sessions.items()}
    })


@app.route("/api/session/<session_id>", methods=["DELETE"])
def delete_session(session_id):
    """手动清理某个会话"""
    if session_id in sessions:
        del sessions[session_id]
        return jsonify({"ok": True})
    return jsonify({"ok": False, "error": "not found"}), 404


# ============================================================

if __name__ == "__main__":
    SERVER_PORT = int(os.environ.get("CODELIGHT_PORT", 8866))
    print("=" * 50)
    print("CodeLight 红绿灯服务启动（多实例版）")
    print(f"��式: {'硬件(ESP32)' if USE_HARDWARE else '纯API'}")
    print(f"地址: http://localhost:{SERVER_PORT}")
    print(f"支持多 Claude Code 会话并行")
    print("=" * 50)
    app.run(host="127.0.0.1", port=SERVER_PORT, debug=False)
