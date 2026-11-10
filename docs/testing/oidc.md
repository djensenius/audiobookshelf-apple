# Manual test: OpenID Connect sign-in

`OIDCLoginService` (ABSAPI) is covered by stubbed unit tests. Run this check against a real
identity provider (IdP) before releasing changes to OpenID sign-in, and whenever the
supported server range changes. The sign-in UI arrives in
[#40](https://github.com/djensenius/audiobookshelf-apple/issues/40); until then, drive the
flow from a debug view or a test harness that calls `OIDCLoginService.login(to:using:)` with
`WebAuthenticationSessionAuthenticator`.

## How the flow works

1. The app calls `GET <server>/auth/openid?code_challenge=…&code_challenge_method=S256&redirect_uri=audiobookshelf://oauth&client_id=Audiobookshelf-App&response_type=code`
   and reads the `Location` of the redirect (the IdP's authorize URL). The server sets its
   session cookie and `auth_method=openid-mobile`.
2. The app opens that URL in a `WebAuthenticationSession`. After sign-in the IdP redirects to
   `<server>/auth/openid/mobile-redirect`, which redirects to
   `audiobookshelf://oauth?code=…&state=…`.
3. The app checks `state` against the one in the IdP URL, then calls
   `GET <server>/auth/openid/callback?state=…&code=…&code_verifier=…` with the same cookie
   jar. The server exchanges the code and returns the `/login` payload with the access and
   refresh tokens.

Upstream references (advplyr/audiobookshelf v2.37.2; the same flow exists at the minimum
supported v2.26.0): `server/Auth.js` routes `/auth/openid`, `/auth/openid/mobile-redirect` and
`/auth/openid/callback`; `server/auth/OidcAuthStrategy.js` `getAuthorizationUrl`,
`isValidRedirectUri` and `handleMobileRedirect`.

## Set up the server and IdP

Use Audiobookshelf 2.26.0 or newer over `https`. The app requires the IdP's sign-in URL to
be `https`; an `http` IdP URL is accepted only when the server itself is `http` (local
testing).

### Authentik

1. Applications › Providers › Create › OAuth2/OpenID Provider.
   - Client type: Confidential. Note the client ID and secret.
   - Redirect URIs (strict): `https://<server>/auth/openid/callback` and
     `https://<server>/auth/openid/mobile-redirect`. Add the server's subfolder if it runs
     under one (for example `https://example.com/abs/auth/openid/mobile-redirect`).
   - Signing key: any; scopes `openid`, `email`, `profile`.
2. Applications › Create, linked to the provider. Note the issuer URL
   (`https://<authentik>/application/o/<slug>/`).

### Keycloak

1. Create a client with Client authentication on and Standard flow on.
2. Valid redirect URIs: the same two server URLs as above.
3. Note the client ID, the secret (Credentials tab) and the issuer
   (`https://<keycloak>/realms/<realm>`).

### Audiobookshelf

1. Settings › Authentication › enable OpenID Connect Authentication.
2. Enter the issuer URL and select Auto-populate, then the client ID and secret.
3. Allowed Mobile Redirect URIs must contain `audiobookshelf://oauth` (the default). The app
   uses no other redirect URI.
4. Choose how users match (by email or username) or enable Auto Register, and save.
5. If the server runs under a subfolder, set Subfolder for Redirect URLs to match.

## What to verify

On an iPhone (or simulator) and on a Mac:

- [ ] The server's sign-in screen offers single sign-on (`authMethods` includes `openid`).
- [ ] With `.shared` browser sessions, the system asks for consent to use the IdP's site, then
      opens the IdP's sign-in page. With `.ephemeral` there is no prompt and no IdP cookies
      are reused.
- [ ] After signing in at the IdP, the browser sheet closes by itself and the app is signed
      in. `LoginResult.tokens` has an access and a refresh token.
- [ ] Closing the browser sheet (Cancel) returns to the sign-in screen with no error shown.
- [ ] A denied user sees the message for where the denial happened (2.26.0–2.37.2):
  - The IdP refuses and redirects back with `error=…` (for example Keycloak's "Deny" on a
    consent screen): the server's mobile redirect drops the error and forwards
    `code=undefined`, so the app shows `.missingCode`, "The identity provider didn't
    complete the sign-in. Try again."
  - The IdP blocks the user on its own page (Authentik policy denial): the IdP never
    redirects; the user closes the sheet and no error is shown (`.cancelled`).
  - Audiobookshelf refuses the user (group claim missing when a group claim is configured,
    no matching user with Auto Register off, account disabled, already linked): the
    callback answers `302 /login?error=Unauthorized&autoLaunch=0` and the app shows
    `.serverRefused`, "The server refused the sign-in (Unauthorized). …".
  - The server can't exchange the code with the IdP (for example a wrong client secret):
    `302 /login?error=Error%20in%20callback`, shown as "The server refused the sign-in
    (Error in callback). …".
- [ ] Signing in a second time with `.shared` skips the IdP's password prompt.
- [ ] Removing `audiobookshelf://oauth` from Allowed Mobile Redirect URIs makes sign-in fail
      with the "couldn't start single sign-on" message, without opening a browser.
- [ ] After the sign-in, an API request with the stored tokens works, and a token refresh
      works (wait for the access token to expire, 1 hour by default, or lower it on the
      server).
- [ ] The device log (Console.app, filtered on the app) contains no authorization code, PKCE
      verifier, `state` or token.

## Notes

- Sign-out loses the IdP end-session URL. The server's `auth_method=openid-mobile` and
  `openid_id_token` cookies live only in the flow's cookie jar, which is discarded after
  sign-in, so the main client never receives them. `POST /logout` reads the auth method and
  ID token only from those cookies (`req.cookies.auth_method`, Auth.js v2.37.2:508, 515) and
  has no body field or header for them (only `x-refresh-token`), so a later sign-out gets
  `redirect_url: null`.
- Servers 2.26.0–2.37.2 redirect every callback refusal to `/login?error=…` instead of
  answering 401/500, because `passportCallback` checks `session.mobile === true` while
  `mobile` holds the redirect URI (Auth.js v2.37.2:424). The app reads `error` from that
  redirect only when it points at the server's own `…/login` page, filters it to visible
  letters, digits and basic punctuation, and shortens it.

- `WebAuthenticationSession` intercepts the `audiobookshelf` callback itself, before the
  system routes the URL. The app also declares the scheme in `CFBundleURLTypes`, for deep
  links (ADR 0004), and so does the legacy app (`com.audiobookshelf.app`). Having both
  installed does not affect this flow, because the session captures the callback first.
  `DeepLink` returns `nil` for `audiobookshelf://oauth`, so a callback that reached
  `onOpenURL` anyway would be ignored.
- The server only allows redirect URIs from its allow-list, so the app can't switch to an
  `https` universal-link callback without a server setting change.
