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

This inversion comes from a single external opinion and **has not been probed**.
It is the plan because the recorded alternative is known broken, not because it
has been demonstrated. `scripts/egress-boundary-probe.sh` is what decides it.

One specific uncertainty, stated rather than buried: **user-scoped outbound
filtering is the load-bearing assumption and it is unverified here.**
`New-NetFirewallRule` accepts `-LocalUser`, and the parameter exists on this
machine, but whether Windows enforces it for outbound traffic from an ordinary
console process on this build is exactly what step 4 measures. If the probe
finds direct egress still succeeds, this approach has failed and must be
replaced — not patched with more rules. Candidate fallbacks, in the order worth
trying: run the executor under a Windows service or job object with its own
service SID and scope the rule to that; or put the executor in a network
namespace equivalent, meaning a container or a VM with no route except the
proxy's. Record whichever, and why, before building it.

## Order matters — step 1 cannot be done later

### 1. Baseline the restricted account BEFORE any rule exists

```powershell
runas /user:director-exec "\"C:\Program Files\Git\bin\bash.exe\" -lc \"cd '/c/Users/dorot/Documents/AI Projects/director-core' && bash scripts/baseline-probe.sh\""
```

Save the output. The existing baseline was taken under `dorot`, a different
account with different rights, so it cannot serve as the before-column for
`director-exec`. **Once the deny rule is in place this measurement is
unrecoverable**, and every later refusal becomes indistinguishable from an
account that never had access in the first place. This is the ordering error that
sank an earlier version of this plan.

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

### 3. Apply the rules

Run as Administrator. The SID is read live rather than pasted, so a rebuilt
account cannot leave a rule pointing at a principal that no longer exists.

```powershell
$sid = (Get-LocalUser -Name director-exec).SID.Value
$sddl = "D:(A;;CC;;;$sid)"

New-NetFirewallRule -DisplayName "director-exec: allow DNS" -Direction Outbound `
  -Action Allow -Protocol UDP -RemotePort 53 -LocalUser $sddl

New-NetFirewallRule -DisplayName "director-exec: allow local proxy" -Direction Outbound `
  -Action Allow -Protocol TCP -RemoteAddress 127.0.0.1 -RemotePort 8899 -LocalUser $sddl

New-NetFirewallRule -DisplayName "director-exec: deny QUIC" -Direction Outbound `
  -Action Block -Protocol UDP -RemotePort 443 -LocalUser $sddl

New-NetFirewallRule -DisplayName "director-exec: deny all other outbound" -Direction Outbound `
  -Action Block -LocalUser $sddl
```

Notes on the four rules, because each is load-bearing:

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

```powershell
runas /user:director-exec "\"C:\Program Files\Git\bin\bash.exe\" -lc \"cd '/c/Users/dorot/Documents/AI Projects/director-core' && bash scripts/egress-boundary-probe.sh\""
```

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
