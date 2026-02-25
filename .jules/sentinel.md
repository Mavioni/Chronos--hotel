SENTINEL'S JOURNAL - CRITICAL LEARNINGS ONLY

## 2026-02-22 - [HIGH] Exposed Database Port & Dangerous Rate Limit Patch
**Vulnerability:** The database port `3310` was bound to `0.0.0.0` (all interfaces) by default in `compose.yaml`, exposing the database to the local network or internet. Additionally, a script `tmp_rate_patch.sh` existed that disabled rate limiting in the CMS by modifying Laravel service providers. Finally, `tmp_cookies.txt` containing valid session tokens was present in the repository.
**Learning:** Development configurations often prioritize convenience (easy access to DB via HeidiSQL) over security, but this can lead to accidental exposure in production. Scripts used for "quick fixes" or testing can become dangerous artifacts if left in the repository. Committing session tokens (cookies) is a critical security risk.
**Prevention:** Always bind database ports to `127.0.0.1` unless external access is explicitly required and secured. Remove temporary scripts and artifacts before committing. Ensure `.gitignore` includes `tmp_*` files.
