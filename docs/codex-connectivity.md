# Codex connectivity on Windows

## Symptom

Codex may report reconnecting, stream disconnected before completion, connection refused, or request timeouts while browser traffic works. These symptoms do not establish whether the failing layer is Codex, a local proxy, DNS, or the outbound node.

## Check the actual route

1. Keep the current working FlClash and AdGuard configuration intact. Check the active mixed port in FlClash.
2. In PowerShell, inspect proxy environment variables (do not share credentials or tokens):

```powershell
Get-ChildItem Env: | Where-Object Name -Match '^(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY)$'
Test-NetConnection 127.0.0.1 -Port 7890
```

Replace 7890 with the actual mixed port. If variables point to a stale local port, correct them for a new terminal session; do not change the whole machine.

3. With FlClash running, use the tray's Copy environment variables command in PowerShell. It sets HTTP_PROXY, HTTPS_PROXY and ALL_PROXY consistently for the current process and its children. Test:

```powershell
curl.exe --proxy http://127.0.0.1:7890 -I --connect-timeout 10 --max-time 20 https://chatgpt.com/
```

A completed HTTPS response, even an HTTP error status, is not proof of successful Codex streaming. Test a new Codex request and compare a fixed known-good node with the automatic group. Restart Codex fully when changing inherited environment variables. For desktop launchers, terminal-only variables may not be inherited; check user environment and Codex configuration for stale endpoint overrides, without exposing secrets. Do not blindly disable system proxy, turn off certificate validation, or reset DNS.

## Regression scope

The copied PowerShell command now uses valid assignment syntax and all three proxy variables; the POSIX command sets both cases. This addresses one confirmed client-side configuration defect, not every possible Codex disconnection. Real WebSocket/HTTPS stream validation, network handover, and AdGuard coexistence still need device-side reproduction.

References: https://github.com/openai/codex/issues/38402 and https://github.com/openai/codex/issues/44517 (community reports, not a confirmed diagnosis of this installation).
