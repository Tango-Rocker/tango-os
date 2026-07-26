# EngineOS ChatGPT WPE experiment

`engineos-chatgpt` is a single-purpose WPE WebKit client for ChatGPT and its
OpenAI/Google authentication flow. It runs as a normal shell-owned Wayland
client; WPE exports accelerated buffers and `engineos-shell` remains the
compositor and input authority.

The normal launch path is:

```bash
eos-app launch chatgpt
```

Use `eos-app launch chatgpt --login` to enter through ChatGPT's dedicated
login route while retaining the same persistent cookie and credential profile.

Persistent cookies, credentials, and website data live below
`$XDG_DATA_HOME/engineos-chatgpt`; disposable cache data lives below
`$XDG_CACHE_HOME/engineos-chatgpt`. The application accepts only HTTPS
top-level documents in the ChatGPT, OpenAI, and Google authentication domain
families. The observed Google callback families are `google.com` and
`google.com.ar`, including their subdomains; lookalike suffixes are rejected.
Device permissions and downloads are denied because they are not part of this
experiment.

The browser exposes its current HTTPS origin in the Wayland toplevel title and
logs every accepted or blocked top-level response to stderr. Logs retain only
the scheme, host, port, and path; OAuth query parameters and fragments are
discarded. It uses WPE's default user agent and does not inject JavaScript into
Google or spoof another browser.

Run the direct WebAuthn regression probe with:

```bash
engineos-chatgpt --probe-web-authn
```

The probe uses WPE's headless platform, loads ChatGPT's `robots.txt` secure
context, and fails if `PublicKeyCredential.getClientCapabilities()` does not
settle within five seconds.

Run the local URI-policy regression check with:

```bash
engineos-chatgpt --self-test
```

It covers the localized Google `SetSID` callback and rejects a suffix-confusion
URL. It makes no network requests and does not access the persistent profile.

Keyboard shortcuts:

- `Ctrl+R`: reload
- `Alt+Left`: back
- `Alt+Right`: forward
- `Ctrl+Q`: close
