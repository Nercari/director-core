# Does the egress boundary hold? — 2026-07-30

Measurement for [#31](https://github.com/Nercari/director-core/issues/31), under
[#27](https://github.com/Nercari/director-core/issues/27).

**Raw output of all three runs, verbatim:**
[`egress-boundary-2026-07-30.raw.txt`](egress-boundary-2026-07-30.raw.txt). Run
by the operator under `director-exec`; the orchestrator cannot run it and did not.

## Answer

**The boundary holds for TCP.** With proxy variables removed and `--noproxy '*'`
set, the restricted account could not reach the model host, the gate, or an
arbitrary third host. Through the loopback proxy it reached the model host and
was refused the other two. Name resolution worked throughout, so no refusal has
a second possible cause.

**UDP/443 was never measured.** It is denied by rule and untested. See the gap
section — this is the one thing that stops the answer being unqualified.

## The configuration this is true of

Machine-wide `DefaultOutboundAction` is `Allow` on all three profiles. The
boundary is carried entirely by two Block rules scoped to the `director-exec`
SID:

| Rule | Action | Protocol | Remote port |
|---|---|---|---|
| `director-exec: deny TCP outbound` | Block | TCP | any |
| `director-exec: deny UDP except DNS` | Block | UDP | `1-52`, `54-65535` |
| `director-exec: allow DNS` | Allow | UDP | `53` |
| `director-exec: allow local proxy` | Allow | TCP | `127.0.0.1:8899` |

Two things about this shape are load-bearing and were arrived at by failure
rather than by design:

**DNS is carved out of the Block rule, not permitted alongside it.** The
original shape was deny-all-outbound plus an allow rule for UDP/53. That does
not work: run 1 had the allow rule present and enabled, and DNS still timed out.
A Block rule defeats an Allow rule at equal specificity on this build. Expressing
the exception as a port range inside the Block rule removes the question entirely
instead of relying on an answer to it.

**Loopback needs no allow rule.** Windows Firewall does not filter loopback
traffic, so `127.0.0.1:8899` stays reachable under a blanket TCP deny. The allow
rule for it is retained as documentation of intent, not because it does work.

## Results

### Name resolution — precondition, met

Both hosts resolved. The model host answered from 8 IPv6 and 8 IPv4 addresses,
a **third distinct set** across three baselines (2026-07-28, the earlier
2026-07-30 baseline, and this run). This is now three independent observations
of the same fact, and it retires the recorded plan's premise permanently:
allowlisting this endpoint by address was never going to survive its own DNS.

`nslookup` exits 0 even when every query times out, as run 1 shows. Exit code
alone would have read a total resolution failure as a pass. The probe prints raw
output beside the exit code for exactly this reason.

### Through the proxy — discriminates correctly

| Probe | Result | Reading |
|---|---|---|
| model host | `exit=0`, `http_code=404`, `remote_ip=127.0.0.1` | Tunnel established. A 404 is the API answering; a refusal never produces one. `remote_ip` confirms the request went via loopback. |
| gate | `exit=56`, `CONNECT tunnel failed, response 403` | Refused by policy. |
| blocked host | `exit=56`, `CONNECT tunnel failed, response 403` | Refused by policy. |

The 403 is the proxy's own refusal code, distinct from any upstream failure —
the distinction the behavior check in CI already covers, here confirmed against
live DNS and real addresses rather than local sockets.

### Direct, proxy variables removed — every probe failed

| Probe | Result |
|---|---|
| model host | `exit=7`, `Could not connect`, 26 ms |
| gate | `exit=7`, `Could not connect`, 11 ms |
| blocked host | `exit=7`, `Could not connect`, 16 ms |

11–26 ms is a local refusal, not a timeout. This is the section the whole unit
turns on: the proxy is not a suggestion the executor can decline for TCP.

### Credentials — the finding holds, one probe does not

`gh auth status` exit 1 and `gh api user` exit 4 both report no GitHub login.
Neither needs the network to reach that conclusion, so the boundary does not
confound them.

`git-push-dry-run` is a different story. It exited 128 on
`Unsupported proxy syntax` — Git for Windows rejected the proxy value the wrapper
exported for curl, and died before it ever attempted authentication. **The probe
reported a failure whose cause is not the one its name claims.** The push did not
fail because credentials were absent; it failed because git could not parse an
environment variable. The credential conclusion survives on the two `gh` probes;
this probe contributed nothing to it.

Fixed in this unit: the push probe now removes the proxy variables and disables
credential prompting, the same guards `scripts/baseline-probe.sh` already carried
and this script did not.

## The gap, stated rather than buried

**UDP/443 is denied by rule and has never been observed being denied.**
`direct-quic-model` exits 127 on every run because this curl has no HTTP3
support. QUIC would route around a TCP-only policy, so the rule matters; but
"the rule exists" and "the traffic is refused" are different claims and only the
first is true here. An executor speaking QUIC is unmeasured.

This is the same shape as the entries in the failure ledger about declarations
nobody exercised, and it is recorded now rather than discovered later.

## What this does not decide

- **The wrapper has still not been probed against this executor.** That is
  [#32](https://github.com/Nercari/director-core/issues/32), a separate question.
  Closing the network half does not lift the quarantine.
- **Exfiltration through the model endpoint remains possible by construction.**
  That endpoint must stay reachable and repository content can be placed in a
  prompt to it. This design reduces the surface; nothing about a hostname allow
  list can eliminate it.
- **This account holds no gate credentials with no wrapper involved.** Observed
  again here. It suggests the credential-stripping wrapper may be redundant
  rather than unproven for an account-separated executor — an observation for
  #32 to settle, not a conclusion drawn here.

## Two process failures this run cost

Recorded in `.director/failures.md` and summarised here because both were the
orchestrator's, not the executor's.

**A precedence rule was asserted as fact before being tested.** The claim that
Block defeats Allow was stated confidently, then contradicted by evidence, then
confirmed — in that order. It happened to be right. It was not known to be right
when it was used to justify a change to the operator's machine.

**A retraction left the machine less protected than it started.** Advice to
delete the existing rules was issued and acted on, then the machine-wide default
that had been substituting for them was reverted, leaving the restricted account
with a wider network reach than before the session began. It was closed within
the same session, and it should never have been opened. The disable-never-delete
principle already recorded for the baseline applies to this case too and was not
applied.
