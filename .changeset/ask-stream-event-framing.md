---
"hex-app": patch
---

Fix Ask streaming event dispatch when `URLSession.bytes(...).lines` omits SSE blank separators so xAI deltas and completion events still arrive in order (#0).
