# Third-party notices

Agentbox is licensed under the MIT License. It relies on third-party software
that remains subject to its own license and terms.

## Vendor agent software

Claude Code is provided by Anthropic PBC. Codex is provided by OpenAI, L.L.C.
Neither vendor program is included in the Agentbox source tree, Homebrew
archive, or public runtime image. `agentbox setup` downloads the exact
release-pinned artifacts directly from each vendor for the end user. Use of
those programs is governed by the applicable vendor license and terms, not the
Agentbox MIT License.

- Claude Code: <https://www.anthropic.com/legal/commercial-terms>
- Codex: <https://github.com/openai/codex>

## Runtime and host dependencies

The runtime image is based on Debian and contains Debian packages and other
utilities under their respective licenses. Their package metadata and license
texts are installed in `/usr/share/doc` in the image. Homebrew installs Python
and jq as separate dependencies under their respective licenses. Agentbox uses
the Bash supplied by macOS. Docker Desktop is an external prerequisite and is
not distributed by Agentbox.

The complete Codex package may itself contain third-party components and
license notices supplied by OpenAI. Agentbox preserves the verified package as
downloaded and does not relicense it.
