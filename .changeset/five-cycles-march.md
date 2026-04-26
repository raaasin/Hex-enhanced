---
"hex-app": patch
---

Fix Ask mode streaming so answers continue rendering when xAI emits Responses SSE output through `part`, `item.content`, nested `response.output`, or delta payloads instead of flat output text (#0).
