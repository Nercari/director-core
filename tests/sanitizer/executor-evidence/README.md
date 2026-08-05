# Sanitizer negative case

This directory holds the negative case for `scripts/check-example-sanitization.sh`.

## Why it is not under `examples/`

The sanitizer scans `examples/executor-evidence/**`. Its negative case has to be a
document the sanitizer *rejects*, which means it has to contain something that looks
like a leak. Putting that file under the scanned tree would create three problems at
once:

1. the sanitizer would reject the repository's own examples, so the check could never
   pass;
2. a realistic-looking secret would be committed to a public repository, which is the
   exact outcome the sanitizer exists to prevent;
3. push protection and secret scanning would have grounds to block the push.

So the case lives here, outside the scanned tree, and it is stored as a template
rather than as a finished document.

## How the case is exercised

`leak-case.generated.invalid.yaml.tmpl` carries placeholders instead of offending
strings:

| Placeholder | What the run substitutes |
|---|---|
| `{{ENV_KEY_NAME}}` | a credential-shaped environment variable name |
| `{{ABSOLUTE_HOME_PATH}}` | an absolute POSIX home path |

The conformance run assembles each replacement from fragments at run time, writes the
completed document to a temporary directory **outside this repository**, asserts that
the sanitizer exits non-zero and names the pattern it matched, and then deletes the
temporary file. Nothing generated is ever written under `examples/`.

Every fragment in the template is inert on its own. There is no real credential, no
real account, and no real hostname in this directory.

## Filename note

The `.yaml.tmpl` extension is the name given in the work handoff and is kept
unchanged. The body is JSON, matching the executor-evidence fixtures, which are JSON
because the repository's deterministic tooling does not depend on a YAML parser. The
sanitizer reads files as text and does not parse either format, so the extension does
not affect the check.
