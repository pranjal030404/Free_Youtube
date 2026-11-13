# Security Policy

## Reporting a vulnerability

Please do not open a public issue for security problems. Use GitHub's
**Security → Report a vulnerability** form on this repository so the report stays
private until a fix is available.

Include what you found, how to reproduce it, and the app version and Android
version you tested on.

## Scope

This app has no backend and stores no accounts of its own. It embeds YouTube's
web pages in a WebView, so issues in YouTube or Google sign-in should be reported
to Google. Relevant reports here include the navigation allowlist, injected
scripts, file handling for downloads, and anything that exposes user data.
