# Closing egress for the bounded executor — operator task

Issue [#31](https://github.com/Nercari/director-core/issues/31), under
[#27](https://github.com/Nercari/director-core/issues/27). Blueprint §21.8, §21.9.

**Every command in this file changes system security settings, so the operator
runs them. The orchestrator does not, and will not.** What the orchestrator has
built is the proxy, its behavior check, and the boundary probe. What it cannot
do is grant itself the boundary it is being measured against.

## Why hostname and not address

The recorded plan this replaces proposed blocking the gate's published IP
ranges. That cannot work, in both directions at once:

- The gate and the model API sit behind shared CDN infrastructure. **Permitting
  the model API by address can permit the gate.**
- Those addresses churn. The 2026-07-28 baseline observed the model host
  answering from eight rotating IPv4 addresses in a shared Google range.
  **Refusing the gate by address can refuse the model**, and will, on a DNS
  change nobody made.

So: deny outbound by default for the account, permit exactly two things — name
resolution and the local proxy — and let the proxy allow the model API **by
hostname**. Nothing is allowlisted by address, so CDN sharing stops being a hole
and address churn stops being an outage.

## Status: probed 2026-07-30, TCP half proven

`scripts/egress-boundary-probe.sh` ran under `director-exec` and every direct
TCP probe failed while the proxy path worked. Evidence:
[`docs/evidence/egress-boundary-2026-07-30.md`](../evidence/egress-boundary-2026-07-30.md).

**UDP/443 is denied by rule and has never been observed being denied** — this
curl has no HTTP3 support. That gap is real and is recorded in the registry as
`quic_udp_443`.

**The rule shape below was rewritten after the first attempt failed.** Sections 3
and 4 no longer describe what was originally written here; read them rather than
recalling them.

**History, because this document has been wrong twice and both errors cost a run.**

**1. Deny rules pre-existed and this document did not know it.** Two
deny-all-outbound rules from an earlier session had been live for days with no
matching allow rules, so the account had no route out at all. The registry
meanwhile said egress was open. This document told the operator to create rules
that already existed, under names that would have produced duplicates.

Those original rules — `deny all outbound (IPv4)`, which despite its name was
`Any/Any->Any` and did cover IPv6, and `deny all outbound (UDP 443 / QUIC)` —
were deleted during the 2026-07-30 work and **replaced** by the two in section 3.
The replacement exists because the original pair could not coexist with a working
DNS allow rule; see that section.

**2. `-LocalUser` enforcement is verified, not assumed.** This document used to
call it the unverified assumption the whole design rested on. It got settled
incidentally: `director-exec` was refused every network probe in 10–16 ms while
`dorot` reached the internet normally on the same machine, under exactly these
SID-scoped rules. Windows enforces it for an ordinary console process on this
build.

Fallbacks are retained in case a future build regresses, not because the question
is open: run the executor under a Windows service or job object with its own
service SID and scope the rule to that; or put it in a network-namespace
equivalent, a container or VM with no route except the proxy's. Record which, and
why, before building it.

## Order matters

### 1. Baseline the restricted account — DONE 2026-07-30

Recorded in
[`docs/evidence/baseline-director-exec-2026-07-30.md`](../evidence/baseline-director-exec-2026-07-30.md).
Do not redo it unless the account or the machine changes.

It had to be taken with the existing deny rules **temporarily disabled**, because
they were already live — a baseline taken with them on measures our own boundary,
not the account's unrestricted state. That recovery is the only reason this
document's original claim ("once the deny rule is in place this measurement is
unrecoverable") did not cost the whole plan. Disable, never delete: the SDDL then
does not have to be reconstructed.

```powershell
Get-NetFirewallRule -DisplayName "director-exec: *" | Disable-NetFirewallRule
Get-NetFirewallRule -DisplayName "director-exec: *" | Select-Object DisplayName,Enabled
```

Both must read `False` before the probe runs, and `True` again immediately after:

```powershell
Get-NetFirewallRule -DisplayName "director-exec: *" | Enable-NetFirewallRule
```

**A probe that hangs leaves the rules disabled.** That happened on 2026-07-30:
the push probe reached Git Credential Manager, printed *"please complete
authentication in your browser"* into a `runas` console with no browser session,
and waited indefinitely with the boundary switched off. `baseline-probe.sh` now
sets `GIT_TERMINAL_PROMPT=0` and `GCM_INTERACTIVE=never` on that probe so a
credential prompt is an immediate failure instead of a hang. If any future probe
does hang: close the window, re-enable the rules, then diagnose. In that order.

The restricted account also needs read access to the repository and its own
`safe.directory` entry, or the push probe dies on dubious ownership before it
measures anything:

```powershell
icacls "C:\Users\dorot\Documents\AI Projects\director-core" /grant "director-exec:(OI)(CI)RX" /T
```

Read and execute only. The executor never needs write access to the operator's
checkout.

### 2. Start the proxy

Under the operator's own account, so the executor cannot stop it:

```powershell
python "C:\Users\dorot\Documents\AI Projects\director-core\scripts\egress-proxy.py" --port 8899 --log "$env:TEMP\egress-proxy.log"
```

Default allow list is the one model host. Verify it in isolation first — this
needs no privileges and no network:

```powershell
python "C:\Users\dorot\Documents\AI Projects\director-core\scripts\egress-proxy-check.py"
```

### 3. The rules — four, and the shape matters

**Do not change the machine-wide `DefaultOutboundAction`.** It stays `Allow`.
Setting it to `Block` denies SYSTEM and every service account that has no allow
rule of its own, and it makes the probe unattributable: a failing direct probe
then has two sufficient causes and proves nothing about the boundary. This was
tried on 2026-07-30 and both problems occurred.

Run as Administrator. The SID is read live rather than pasted, so a rebuilt
account cannot leave a rule pointing at a principal that no longer exists.

```powershell
$sid = (Get-LocalUser -Name director-exec).SID.Value
$sddl = "D:(A;;CC;;;$sid)"

New-NetFirewallRule -DisplayName "director-exec: deny TCP outbound" -Direction Outbound `
  -Action Block -Protocol TCP -LocalUser $sddl

New-NetFirewallRule -DisplayName "director-exec: deny UDP except DNS" -Direction Outbound `
  -Action Block -Protocol UDP -RemotePort @("1-52","54-65535") -LocalUser $sddl

New-NetFirewallRule -DisplayName "director-exec: allow DNS" -Direction Outbound `
  -Action Allow -Protocol UDP -RemotePort 53 -LocalUser $sddl

New-NetFirewallRule -DisplayName "director-exec: allow local proxy" -Direction Outbound `
  -Action Allow -Protocol TCP -RemoteAddress 127.0.0.1 -RemotePort 8899 -LocalUser $sddl
```

Then confirm exactly four `director-exec:` rules exist and every one is
SID-scoped. If any reports `Any`, stop — an unscoped Block rule would apply to
every account on the machine:

```powershell
Get-NetFirewallRule -DisplayName "director-exec: *" | ForEach-Object {
  "{0} | {1} | {2}" -f $_.DisplayName, $_.Action,
    (Get-NetFirewallSecurityFilter -AssociatedNetFirewallRule $_).LocalUser }
```

Why this shape rather than the obvious one:

- **DNS is carved out of the Block rule, not permitted beside it.** The first
  attempt was deny-all-outbound plus an allow rule for UDP/53. DNS still timed
  out, with the allow rule present and enabled: **Block defeats Allow at equal
  specificity on this build.** Expressing the exception as a port range inside
  the Block rule removes the precedence question instead of depending on an
  answer to it. Resolution has to work — a probe that cannot resolve produces
  refusals with two possible causes, which is why the boundary probe checks it
  first and aborts on failure.
- **QUIC is denied by the same rule.** UDP/443 falls inside `54-65535` and would
  otherwise route around a TCP-only policy. Note that the probe has never
  *observed* this refusal; the rule is present, the traffic is unmeasured.
- **Loopback needs no allow rule.** Windows Firewall does not filter loopback, so
  the proxy stays reachable under a blanket TCP deny. The allow rule is kept as a
  statement of intent; it is not what makes the proxy work.
- **Nothing here names an internet IP range.** `127.0.0.1` is the loopback
  address of the proxy, not an allowance for any external host. If a future edit
  adds an internet address to any of these rules, the design has been abandoned
  rather than adjusted.
- **Disable, never delete.** Recovering a rule costs one command; reconstructing
  its SDDL costs a session. On 2026-07-30 the original rules were deleted on the
  orchestrator's advice and the account was briefly left with wider reach than it
  had before the work started.

### 4. Prove it by attempting the forbidden action

Start the proxy first (section 2) and leave its window open — it must be running
for the whole probe.

The form actually used on 2026-07-30 was a `.cmd` wrapper, which avoids the
`runas` quoting problem entirely and is the shorter of the two. In `cmd` as
Administrator:

```
echo @echo off > C:\Temp\run-probe.cmd
echo set HTTP_PROXY=http://127.0.0.1:8899 >> C:\Temp\run-probe.cmd
echo set HTTPS_PROXY=http://127.0.0.1:8899 >> C:\Temp\run-probe.cmd
echo "C:\Program Files\Git\bin\bash.exe" -lc "cd /c/Users/dorot/Documents/AI\ Projects/director-core && bash scripts/egress-boundary-probe.sh" >> C:\Temp\run-probe.cmd
```

```
runas /user:director-exec "C:\Temp\run-probe.cmd"
```

The `bash.exe` form below also works and writes the output to a file instead of
the console. `runas` mis-parses a quoted command containing both a space and a
colon, so the command goes in a script and `runas` points at the script. Both
accounts need to reach it, so not `%TEMP%`. In `cmd`:

```
mkdir C:\Temp
(
echo set -e
echo export GIT_TERMINAL_PROMPT=0
echo export GCM_INTERACTIVE=never
echo cd '/c/Users/dorot/Documents/AI Projects/director-core'
echo bash scripts/egress-boundary-probe.sh ^> /c/Temp/director-exec-after.txt 2^>^&1
) > C:\Temp\boundary-run.sh
```

`^` escapes the redirection characters so they land literally in the file instead
of being consumed by `cmd`. Grant the restricted account write access to that
directory once, as Administrator:

```powershell
icacls C:\Temp /grant "director-exec:(OI)(CI)M"
```

Then run it. Note only the executable path is quoted — quoting the argument after
`-lc` is what triggers the mis-parse:

```
runas /user:director-exec "\"C:\Program Files\Git\bin\bash.exe\" -lc /c/Temp/boundary-run.sh"
```

The console opens, runs, and closes itself. Read the output with
`type C:\Temp\director-exec-after.txt`.

Read the `DIRECT, WITH THE PROXY VARIABLES UNSET` section **first**. Every probe
in it must fail. A success there means the executor can decline the proxy, and
nothing else in the run counts.

The probe prints no verdict, mutates nothing, and keeps credential results and
network results in separate sections, so a firewall refusal is never read as a
credential-wrapper success. Its push is `--dry-run` against a ref name that
exists nowhere.

### 5. Record the result, then stop — DONE 2026-07-30

Recorded in
[`docs/evidence/egress-boundary-2026-07-30.md`](../evidence/egress-boundary-2026-07-30.md),
with all three runs' raw output beside it including the two that failed. The
registry now carries `egress_boundary: TCP_CLOSED_MEASURED_2026_07_30` and
`quic_udp_443: DENIED_BY_RULE_NEVER_MEASURED`.

The instructions below stand for any future re-run. Two things must be recorded
even though neither is flattering:

- **The wrapper has still not been probed against this executor.** That is
  [#32](https://github.com/Nercari/director-core/issues/32) and it is a separate
  question from egress. Closing the network half does not license lifting the
  quarantine.
- **Exfiltration through the model endpoint itself remains possible.** That
  endpoint must be reachable, and repository content can be placed in a prompt.
  This design reduces that; it does not eliminate it. It belongs in the registry
  as a stated residual, not omitted because it is inconvenient.

The quarantine is lifted on evidence or not at all.
