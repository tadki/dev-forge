#!/bin/bash
# read-stdin.lib.sh — hook stdin 缓冲与 payload 字段提取的单源实现（SEE-1516 F3）。
#
# 历史背景：dispatcher / mention-check / atlas-taskflow×3 / unified-hook 各自
# 复制同一段 WSL-safe stdin 缓冲循环（CC 以 --login -i 启动 bash 时管道 EOF
# 不传播，裸 read/cat 会永久阻塞，故用 3s 逐行读超时）。本文件把该循环与
# 「从 payload JSON 取一个字段」的 node -e 样板收敛为两个函数。
#
# 超时语义（如实记录，不擅自统一，见 SEE-1516 F3 台账）：
#   - hook_read_stdin     = `read -r -t 3` 逐行 3s 读超时（本单源口径）
#   - gdformat-gdlint.sh  = `INPUT=$(cat)` 无读超时（未收编，语义不同）
#   - repo-checkout.sh    = CLI 层 `timeout $MULTICA_CLI_TIMEOUT`（语义不同）
#   - dispatcher/unified-hook 保留内联循环：v2 契约夹具仅复制入口文件、不复制
#     scripts/lib（tests/test_v2_unified_engine_p0.sh §10），本文件不可成为其依赖。
#
# 契约：hook_read_stdin 设置全局 INPUT 为完整 payload，并恰好去掉一个尾部
# 换行（与历史内联循环逐字节一致）。调用方沿用 INPUT 变量名。

hook_read_stdin() {
    INPUT=""
    local line
    while IFS= read -r -t 3 line || [ -n "$line" ]; do
        INPUT="${INPUT}${line}"$'\n'
    done
    INPUT="${INPUT%$'\n'}"
}

# hook_json_field <dot-path> [<alt-dot-path>...] — 从 stdin JSON 提取字段。
# 依次尝试各 dot-path，打印第一个非空字符串值；解析失败/全部缺失输出空串。
# 语义与被收编的内联样板逐点一致：`i.tool_input?.command || ''`（catch 输出
# 空串 = 解析失败输出空串）。仅覆盖简单点路径字段读取；复杂解析器（如
# mark-b 的 tool_response 多形态遍历）保持各自内联实现。
hook_json_field() {
    local paths="$*"
    node -e '
      const paths = process.argv[1].split(" ").filter(Boolean);
      let d = "";
      process.stdin.on("data", c => d += c);
      process.stdin.on("end", () => {
        try {
          const o = JSON.parse(d);
          for (const p of paths) {
            let v = o;
            for (const k of p.split(".")) { v = (v == null ? undefined : v[k]); }
            if (typeof v === "string" && v !== "") { process.stdout.write(v); return; }
          }
        } catch (e) { process.stdout.write(""); }
      });
    ' "$paths" 2>/dev/null
}
