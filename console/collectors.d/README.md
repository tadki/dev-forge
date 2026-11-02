# collectors.d — 外部采集器投放目录

丢任意可执行文件到这里（`.sh` / `.py` / `.js` …），stdout 输出一份 `forge-asset/1` 契约 JSON 即可被 registry 收编：

```json
{
  "collector": "my-domain",
  "collectedAt": "2026-11-03T00:00:00+08:00",
  "assets": [
    {
      "id": "custom:my-thing",
      "kind": "custom",
      "name": "my-thing",
      "summary": "一句话",
      "attach": { "level": "user" },
      "enforcement": "advisory",
      "platforms": ["claude-code"],
      "provenance": "first-party",
      "tags": [],
      "source": { "collector": "my-domain", "path": "/whatever/source" },
      "payload": { "anything": true }
    }
  ],
  "relations": [],
  "diagnostics": []
}
```

契约完整定义：`../packages/schema/asset.schema.json`。退出码非 0 = 该采集器失败（记诊断，不影响其他）。超时 30s。
