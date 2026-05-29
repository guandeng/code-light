#!/bin/bash
# CodeLight 集成测试 — 测试 HTTP API 端点
# 用法: make test 或 bash Tests/run_tests.sh
set -e

HOST="http://127.0.0.1:8866"
PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✅ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ❌ $desc — expected: $expected, got: $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -q "$needle"; then
        echo "  ✅ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ❌ $desc — expected to contain: $needle, got: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

# 检查服务是否运行
if ! curl -s "$HOST/api/state" > /dev/null 2>&1; then
    echo "❌ CodeLight 服务未运行 ($HOST)"
    exit 1
fi

echo "🧪 CodeLight 集成测试"
echo ""

# ---- 状态 API ----
echo "📡 状态 API"

R=$(curl -s "$HOST/api/state")
assert_contains "GET /api/state 返回 JSON" "\"state\"" "$R"

R=$(curl -s -X POST "$HOST/api/state" -H 'Content-Type: application/json' \
    -d '{"state":"thinking","message":"test","session_id":"test-1"}')
assert_contains "POST /api/state 返回 state" "\"state\"" "$R"

# 优先级测试：working > thinking（通过会话验证）
R=$(curl -s -X POST "$HOST/api/state" -H 'Content-Type: application/json' \
    -d '{"state":"working","message":"test","session_id":"test-2"}')
assert_contains "working 会话已注册" "\"working\"" "$R"

# ---- 无效状态 ----
echo ""
echo "📡 无效输入"
R=$(curl -s -X POST "$HOST/api/state" -H 'Content-Type: application/json' \
    -d '{"state":"invalid_state"}')
assert_contains "无效状态返回错误" "\"error\"" "$R"

R=$(curl -s -X POST "$HOST/api/state" -H 'Content-Type: application/json' \
    -d 'not json')
assert_contains "无效 JSON 返回错误" "\"error\"" "$R"

# ---- 会话 API ----
echo ""
echo "📡 会话 API"
curl -s -X POST "$HOST/api/state" -H 'Content-Type: application/json' \
    -d '{"state":"idle","message":"session test","session_id":"test-sessions"}' > /dev/null

R=$(curl -s "$HOST/api/sessions")
assert_contains "GET /api/sessions 返回会话列表" "test-sessions" "$R"

curl -s -X DELETE "$HOST/api/session/test-sessions" > /dev/null

# ---- 历史记录 API ----
echo ""
echo "📡 历史记录 API"
R=$(curl -s "$HOST/api/history")
assert_contains "GET /api/history 返回数组" "\"state\"" "$R"

# ---- 权限 API ----
echo ""
echo "📡 权限 API"

R=$(curl -s -X POST "$HOST/api/permission" \
    -d '{"tool_name":"Bash","tool_input":{"command":"echo test"},"session_id":"test-perm"}' \
    -H 'Content-Type: application/json')
ID=$(echo "$R" | python3 -c "import json,sys;print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
assert_contains "POST /api/permission 返回 id" "$ID" "$R"

R=$(curl -s "$HOST/api/permission/$ID/decision")
S=$(echo "$R" | python3 -c "import json,sys;print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
assert_eq "决策状态为 pending" "pending" "$S"

# 设置允许
R=$(curl -s "$HOST/api/permission/$ID/allow")
assert_contains "设置允许成功" "\"ok\":true" "$R"

R=$(curl -s "$HOST/api/permission/$ID/decision")
S=$(echo "$R" | python3 -c "import json,sys;print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
assert_eq "决策状态变为 done" "done" "$S"

D=$(echo "$R" | python3 -c "import json,sys;d=json.load(sys.stdin).get('decision',{});print(d.get('decision',''))" 2>/dev/null)
assert_eq "决策结果为 allow" "allow" "$D"

# ---- 404 路由 ----
echo ""
echo "📡 未知路由"
R=$(curl -s "$HOST/api/nonexistent")
assert_contains "未知路由返回错误" "\"error\"" "$R"

# ---- 汇总 ----
echo ""
echo "━━━━━━━━━━━━━━━━━━━━"
echo "通过: $PASS  失败: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "❌ 有测试失败"
    exit 1
else
    echo "✅ 全部通过"
fi
