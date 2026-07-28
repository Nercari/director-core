# Unrestricted baseline — 2026-07-28

The "before" column for the containment work in
[#27](https://github.com/Nercari/director-core/issues/27), captured under
[#28](https://github.com/Nercari/director-core/issues/28).

Nothing was changed to produce this. It records what the ordinary operator
environment could reach on the date below, so that every refusal recorded later
under the restricted account means something. A refusal with no "before" is
indistinguishable from a broken environment, a host that is down, or a ref that
never existed.

**Raw output:** [`baseline-unrestricted-2026-07-28.raw.txt`](baseline-unrestricted-2026-07-28.raw.txt),
verbatim, including the successes — the successes are the point.

| | |
|---|---|
| Account | `dorot` |
| Machine | `Pedro-dsktp` |
| OS | `MINGW64_NT-10.0-26200 3.6.7-fb42d713.x86_64` (Windows 11, Git Bash) |
| Date | 2026-07-28T15:11:45Z |
| Probe | `scripts/baseline-probe.sh`, no arguments |

## Results as observed

Credential results and network results stay in separate sections and are not
merged into a verdict. A firewall refusal must never later be read as a
credential-wrapper success.

### Credentials

| Probe | Exit | Observed |
|---|---|---|
| `gh auth status` | 0 | Logged in to github.com as `Nercari` (keyring); scopes `gist`, `read:org`, `repo`, `workflow` |
| `gh api user` | 0 | Live authenticated JSON for `Nercari` |
| `git push --dry-run origin HEAD:refs/heads/director-baseline-probe-never-created` | 0 | `* [new branch]  HEAD -> director-baseline-probe-never-created` |

The push was `--dry-run` against a ref name that exists nowhere. Nothing was
created; the ref is absent on the remote. `[new branch]` is the measurement: it
records that this account **would have pushed**.

### Network

| Probe | Exit | Observed |
|---|---|---|
| `nslookup github.com` | 0 | resolves — `4.228.31.150` |
| `nslookup generativelanguage.googleapis.com` | 0 | resolves — 8 IPv6 and 8 IPv4 addresses |
| `GET https://example.com` | 0 | `http_code=200` |
| `GET https://generativelanguage.googleapis.com` | 0 | `http_code=404` — TLS completed to the host; 404 is the endpoint's answer to a bare path, and reachability is what is being measured |
| `GET https://api.github.com` | 0 | `http_code=200` |

No credentials were sent to the model host. Every probe was a plain GET.

## One observation worth carrying forward

The model host answered from eight rotating IPv4 addresses in `172.217.112.0/20`
and eight IPv6 addresses in `2001:4860:48xx::`. That is shared Google edge
infrastructure and it churns. It is a concrete instance of the reason #27 gives
for filtering on hostname rather than address, recorded here as observed rather
than argued.

Stated as an observation only. Nothing here decides whether the proxy design in
[#31](https://github.com/Nercari/director-core/issues/31) works; that ticket
measures it.

## Re-running this later

Run the same file, unedited, under the restricted account:

```bash
bash scripts/baseline-probe.sh
```

Three hosts are overridable by environment variable
(`DIRECTOR_GATE_HOST`, `DIRECTOR_MODEL_HOST`, `DIRECTOR_BLOCKED_HOST`) so that a
corrected model endpoint discovered in #31 does not require editing the probe
and breaking comparability. The defaults are what this baseline used.

The model endpoint above is the vendor's documented public host, **not** an
endpoint observed on the wire from the bounded executor. If #31 finds the
executor talks to a different host, this line is the one to revisit.
