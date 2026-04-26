---
"hex-app": patch
---

Fix Ask streaming SSE framing so CRLF-delimited xAI responses flush each event correctly instead of collapsing into the final event diagnostics (#0).
