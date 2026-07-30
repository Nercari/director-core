# Restricted-account baseline — `director-exec`, 2026-07-30

The before-column for [#31](https://github.com/Nercari/director-core/issues/31),
under [#27](https://github.com/Nercari/director-core/issues/27).

The 2026-07-28 baseline was taken as `dorot`. That is a different account with
different rights, so it could never serve as the before-column for
`director-exec`. This is that column.

**Raw output:** [`baseline-director-exec-2026-07-30.raw.txt`](baseline-director-exec-2026-07-30.raw.txt),
verbatim, successes included — the successes are the point.

| | |
|---|---|
| Account | `director-exec` (SID `…-1010`) |
| Machine | `Pedro-dsktp` |
| OS | `MINGW64_NT-10.0-26200` (Windows 11, Git Bash) |
| Date | 2026-07-30T00:56:37Z |
| Probe | `scripts/baseline-probe.sh`, no arguments |
| Firewall state | **the two `director-exec` deny rules were temporarily disabled** — see below |

## It took three attempts, and the first two are the finding

**Attempt 1 recorded a boundary that already existed.** Every network probe
failed, in 10–16 ms. That is not a network timeout, it is a local refusal, and it
was ours: `Get-NetFirewallRule` showed `director-exec: deny all outbound (IPv4)`
and `director-exec: deny all outbound (UDP 443 / QUIC)` already present and
enabled, created in an earlier session, with **no matching allow rules at all**.

The registry said `blocked_on: "Egress is open"` at that moment. It was false when
written, and the operator document described applying rules that were already
applied. The account had no route out; what was missing was not the deny, it was
the permit.

**Attempt 2 hung forever.** Fixing Git's `safe.directory` complaint let the push
probe get further — far enough to contact the remote, find no stored credential,
and hand off to Git Credential Manager, which printed *"please complete
authentication in your browser"* into a `runas` console with no usable browser
session. It waited indefinitely, **while holding the firewall rules disabled.**

`scripts/exec-jail.sh` had set `GIT_TERMINAL_PROMPT=0` and `GCM_INTERACTIVE=never`
for exactly this reason since it was written. The probe did not. It does now.

**Attempt 3, below, is the measurement.** Deny rules disabled, prompt guards on.

## Results as observed

Credential results and network results stay in separate sections and are never
merged into a verdict. A firewall refusal must never later be read as a
credential-wrapper success.

### Credentials — with no jail, no wrapper, nothing but the account boundary

| Probe | Exit | Observed |
|---|---|---|
| `gh auth status` | 1 | `You are not logged into any GitHub hosts` |
| `gh api user` | 4 | refused; no token, no login |
| `git push --dry-run` to a ref that exists nowhere | 128 | `could not read Username for 'https://github.com': terminal prompts disabled` |

Compare the same three probes as `dorot` on 2026-07-28: authenticated as
`Nercari` with `repo`+`workflow` scope, live API JSON, and `* [new branch]` —
that account **would have pushed**.

**Worth carrying forward: `exec-jail.sh` may be redundant for an
account-separated executor.** The wrapper exists to strip gate credentials from
the environment. `director-exec` has none to strip — its profile has no `gh`
login and no credential-manager entry, so all three probes fail on the account
boundary alone, with no wrapper involved. That is a stronger control than the
wrapper, because it does not depend on remembering to invoke it. Not a conclusion:
[#32](https://github.com/Nercari/director-core/issues/32) is still the ticket that
probes the wrapper against this executor, and this observation does not close it.

### Network — deny rules temporarily disabled

| Probe | Exit | Observed |
|---|---|---|
| `nslookup github.com` | 0 | `4.228.31.150` |
| `nslookup generativelanguage.googleapis.com` | 0 | **8 IPv6 and 8 IPv4 addresses** |
| `GET https://example.com` | 0 | `http_code=200` |
| `GET https://generativelanguage.googleapis.com` | 0 | `http_code=404` — TLS completed; 404 is the endpoint's answer to a bare path, and reachability is the measurement |
| `GET https://api.github.com` | 0 | `http_code=200` |

## The observation that decides the design

The model host answered from eight IPv6 addresses in `2001:4860:484x::` and eight
IPv4 addresses in `172.217.112.0/20`. `github.com` answered from
`4.228.31.150`; the API host from `4.228.31.149`.

Shared Google edge infrastructure, sixteen addresses deep, and it churns — the
2026-07-28 baseline saw a *different* set of eight IPv4 addresses in the same
range. This is the second independent observation of it.

That is the concrete refutation of the recorded plan to allow the model API and
refuse the gate **by address**. Permitting sixteen rotating shared-CDN addresses
permits whatever else those addresses front; refusing by address breaks on the
next DNS change. Filtering on the CONNECT hostname, which is what
`scripts/egress-proxy.py` does, is not a preference here — it is the only form of
the rule that survives this table.

Also note both `curl` successes went out over **IPv6**. Any rule written for IPv4
only would have been decorative. The existing deny rule is `Any/Any->Any` despite
its `(IPv4)` name, so it does cover IPv6; the name is wrong, the rule is not.

## What is still not established

- **The boundary has not been proven.** The deny rules are back on, but the two
  allow rules (DNS, loopback proxy) do not exist yet, and
  `scripts/egress-boundary-probe.sh` has never run. Until its
  `DIRECT, WITH THE PROXY VARIABLES UNSET` section is read, nothing here says the
  executor cannot go around the proxy.
- **`-LocalUser` enforcement is now verified**, incidentally and for free:
  `director-exec` was refused while `dorot` reached the internet on the same
  machine, under rules scoped by SID. The operator document had called this the
  unverified assumption the whole design rested on. It rests on it no longer.
- The quarantine on `EXEC_PRIMARY` stands. It is lifted on evidence or not at all.
