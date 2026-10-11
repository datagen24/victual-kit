# Transport test plan

This plan prepares the next discussion on App Transport Security (ATS) and HTTPS. It changes no setting. The tests decide what the apps need before anything in `Info.plist` moves.

## What Apple documents

Apple's pages for `NSAllowsLocalNetworking` and `NSAllowsArbitraryLoads` say the following.

- `NSAllowsLocalNetworking` lets ATS allow unqualified domains, `.local` names and IP addresses.
- On iOS 17 and macOS 14, ATS no longer allows IP addresses by default. Apple says to list individual addresses and CIDR ranges in `NSExceptionDomains`.
- When `NSAllowsLocalNetworking` is present, newer systems ignore `NSAllowsArbitraryLoads`. That key is then only a fallback for older systems.
- Disabling ATS does not disable server trust evaluation. A certificate the system does not trust is still refused.

The pages disagree a little on IP addresses, so the IP rows below are real tests, not formalities.

## Facts about the dev server

The dev instance routes by Host name. A request to its bare IP gets a 404, so the IP test needs a name that resolves to the same address. An `nip.io` name does that, but it is a public DNS name, not a local one.

## Test matrix

Run every row on the simulator and on a device. Use a build with the shipped `Info.plist` and no edits.

| Case | Name form | Scheme | Expected from Apple's pages |
|---|---|---|---|
| 1 | `.local` name | HTTP | Allowed |
| 2 | `.local` name | HTTPS, self-signed | ATS passes; trust fails |
| 3 | Private IP with a matching Host route | HTTP | Unclear; needs an exception on iOS 17 |
| 4 | Private IP with a matching Host route | HTTPS, self-signed | ATS passes; trust fails |
| 5 | Custom LAN hostname, one label | HTTP | Allowed as unqualified |
| 6 | Custom LAN hostname, one label | HTTPS, self-signed | ATS passes; trust fails |
| 7 | Custom LAN hostname, dotted, not `.local` | HTTP | Blocked |
| 8 | Custom LAN hostname, dotted, not `.local` | HTTPS, self-signed | ATS passes; trust fails |

## What to record

For each row, record the result and the error code. An ATS refusal is `-1022`. A certificate failure is `-1200` to `-1203`. A timeout is `-1001`. Note the message the connection form shows.

On a device, also run `log stream --predicate 'subsystem == "com.apple.network"'` from a Mac. The first report had no log, so its cause stayed an inference.

## What this does not prove

A pass on a self-signed row shows that ATS allowed the request. It does not show the certificate is trusted. Trusting one needs an installed profile or a pinning decision, which is a separate design.

Simulator results also differ from a device. The simulator uses the Mac's trust store. A device has its own.

## The production plan

The plan is HTTPS on a public name through Tailscale Funnel, behind a Cloudflare proxy. That path needs no ATS exception if the chain is public and modern. Verify this on the simulator and on a device.

- Run `openssl s_client -showcerts` against the name. Confirm the chain reaches a public root and the name matches.
- Note which certificate the app sees. Behind a Cloudflare proxy it is Cloudflare's edge certificate, not the origin's.
- Confirm TLS 1.2 or later with forward secrecy, which ATS requires.
- Connect with the shipped `Info.plist` and no exceptions. Expect success.
- Send a request over plain HTTP and confirm the redirect to HTTPS works, since ATS applies to each hop.
- Confirm a key rotation and a reconnect still work over the same path.

WebSocket and streaming are out of scope; the apps use plain requests.
