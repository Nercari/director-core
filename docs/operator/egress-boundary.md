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

## Honest status of this design

The hostname-filtering half has **not been probed end to end**. It is the plan
because the recorded alternative is known broken, and
`scripts/egress-boundary-probe.sh` is what decides it.

**Corrected 2026-07-30. Two things this document previously got wrong.**

**1. The deny rules already exist.** Created in an earlier session, live ever
since. `Get-NetFirewallRule` shows:

```
director-exec: deny all outbound (IPv4)            Block  Outbound  Any/Any->Any
director-exec: deny all outbound (UDP 443 / QUIC)  Block  Outbound  UDP/Any->443
```

Both scoped to `D:(A;;CC;;;S-1-5-21-…-1010)`, which is `director-exec`. So the
rules step below is **not** building a boundary from nothing — it adds the two
*allow* rules that were missing. Creating rules under this document's original
names would have produced duplicates. What the account lacked was never the deny.
It was the permit, and with the deny present and no permit it simply had no route
out at all.

The `(IPv4)` rule is `Any/Any->Any` and does cover IPv6 — the name is wrong, the
rule is not. Do not "fix" it by narrowing it to IPv4: the 2026-07-30 baseline
shows this machine reaching both the model host and the gate over IPv6, so an
IPv4-only rule would be decorative.

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

### 3. Add the two missing allow rules

The two deny rules already exist and must be left alone. Only these two are
missing. Run as Administrator; the SID is read live rather than pasted, so a
rebuilt account cannot leave a rule pointing at a principal that no longer exists.

```powershell
$sid = (Get-LocalUser -Name director-exec).SID.Value
$sddl = "D:(A;;CC;;;$sid)"

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

Notes, because each rule is load-bearing:

- **DNS is permitted deliberately.** The proxy resolves names, and a probe that
  cannot resolve produces refusals with two possible causes, which proves
  nothing. The boundary probe checks resolution first for that reason.
- **QUIC is denied explicitly.** UDP/443 would route around a TCP-only policy.
  Denying it is the difference between a boundary and a speed bump.
- **The deny rule is last but not least-priority.** Windows evaluates Block
  before Allow at equal specificity, so verify the intended outcome with the
  probe rather than reasoning about precedence.
- **Nothing here names an internet IP range.** `127.0.0.1` is the loopback
  address of the proxy, not an allowance for any external host. If a future
  edit adds an internet address to any of these rules, the design has been
  abandoned rather than adjusted.

### 4. Prove it by attempting the forbidden action

`runas` mis-parses a quoted command containing both a space and a colon, so put
the command in a script and point `runas` at the script. Both accounts need to
reach it, so not `%TEMP%`. In `cmd`:

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

### 5. Record the result, then stop

Write the output to `docs/evidence/`, pass or fail, and update
`.director/routes.yaml` to say what is now true. Two things must be recorded even
though neither is flattering:

- **The wrapper has still not been probed against this executor.** That is
  [#32](https://github.com/Nercari/director-core/issues/32) and it is a separate
  question from egress. Closing the network half does not license lifting the
  quarantine.
- **Exfiltration through the model endpoint itself remains possible.** That
  endpoint must be reachable, and repository content can be placed in a prompt.
  This design reduces that; it does not eliminate it. It belongs in the registry
  as a stated residual, not omitted because it is inconvenient.

The quarantine is lifted on evidence or not at all.
