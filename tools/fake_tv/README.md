# Fake TVs

Small standard-library Python servers that pretend to be TVs, for integration tests and
for trying the app on a LAN without hardware.

| Script | Emulates | Phase |
|---|---|---|
| `roku_ecp.py` | Roku ECP on :8060: device-info, apps, icons, key/launch commands | 1 |
| `samsung_ws.py` | Minimal Samsung WebSocket remote endpoint | 2 (not yet) |

```bash
python3 tools/fake_tv/roku_ecp.py --host 0.0.0.0 --port 8060
```

With `--host 0.0.0.0` the fake Roku is reachable from an iPhone on the same Wi-Fi. Use
"Add by IP address" with your computer's IP, since the subnet sweep also finds it on 8060.

Test-only endpoints: `POST /_test/reset`, `POST /_test/limited?on=1` (answer 403 like
*Control by mobile apps: Limited*), `GET /_test/log`.

Repo Python style: no `zip()`, and no `with` for file operations.
