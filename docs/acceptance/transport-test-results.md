# Transport test results

This records a run of the [transport test plan](transport-test-plan.md) on 2026-10-11. It changes no setting. The phone app was built with the shipped `Info.plist`, which holds `NSAllowsLocalNetworking` only. Nothing here chooses a configuration.

## What was run and what was not

The run used the iOS 27.0 simulator on a Mac. It did not use a device. The Mac runs a Vallum firewall and a Cisco Secure Endpoint filter. Both closed every inbound connection on the Mac's LAN address, for any program, including a stock `http.server`.

So the LAN-address rows could not be tested. Rows that need a real LAN path are marked as such. Loopback names stood in for the rest, and each such row says so.

## Results

Evidence kinds: SIMULATOR is the phone app's connection form on the simulator. MAC PROBE is a throwaway command-line tool with the plist embedded, so ATS applies. NOT RUN means no result exists.

| Case | Name form tested | Scheme | Expected | Observed | Code | Message in the form | Evidence |
|---|---|---|---|---|---|---|---|
| 1 | `<LocalHostName>.local` | HTTP | Allowed | Connected | none | Connected, Victual 0.4.0 | SIMULATOR |
| 2 | `<LocalHostName>.local` | HTTPS, self-signed | ATS passes; trust fails | Trust failure | -1202 | "The certificate for this server is invalid…" | SIMULATOR |
| 3a | Private IP, LAN address | HTTP | Unclear | Connection reset by the host firewall | -1005 | "The network connection was lost." | SIMULATOR |
| 3b | `127.0.0.1` (stand-in for an IP) | HTTP | Unclear | Connected | none | none | SIMULATOR |
| 4 | `127.0.0.1` (stand-in for an IP) | HTTPS, self-signed | ATS passes; trust fails | Trust failure | -1202 | "The certificate for this server is invalid…" | SIMULATOR |
| 5 | `localhost` (stand-in for a one-label name) | HTTP | Allowed | Connected | none | none | SIMULATOR |
| 6 | `localhost` (stand-in for a one-label name) | HTTPS, self-signed | ATS passes; trust fails | Trust failure | -1202 | "The certificate for this server is invalid…" | SIMULATOR |
| 7 | `127.0.0.1.nip.io` (dotted, not `.local`) | HTTP | Blocked | ATS refusal | -1022 | "…App Transport Security policy requires the use of a secure connection." | SIMULATOR |
| 8 | `127.0.0.1.nip.io` (dotted, not `.local`) | HTTPS, self-signed | ATS passes; trust fails | Trust failure, reported differently | -1200 | "A TLS error caused the secure connection to fail." | SIMULATOR |
| 5, 6 | The Mac's own one-label host name | HTTP, HTTPS | Allowed; trust fails | BLOCKED, the name does not resolve without `/etc/hosts` | n/a | n/a | NOT RUN |
| 3, 4 | Private LAN address from another device | HTTP, HTTPS | see plan | NOT RUN, needs the firewall opened and a device | n/a | n/a | NOT RUN |

Notes on the table.

- Case 3a is not an ATS result. An ATS refusal is -1022 and arrives before any connection. A reset is a network event. The `nscurl` and probe runs saw the same reset.
- Case 3b shows that an IP address over HTTP passes ATS on iOS 27 with only `NSAllowsLocalNetworking`. It was a loopback address, so the same result on a LAN address is still unconfirmed.
- Case 8 differs from the other HTTPS rows. The code is -1200, not -1202. After trust was installed it connected, so the cause was the untrusted certificate on a public-style name, not ATS.
- The form shows the message, not the code. Codes come from the same message text in the `nscurl` and probe runs.

### Extra rows

| Row | Change | Result | Evidence |
|---|---|---|---|
| (a) | Self-signed certificate installed in the simulator with `xcrun simctl keychain booted add-root-cert` | `https://localhost:8443` connected. `https://127.0.0.1.nip.io:8443` connected. | SIMULATOR |
| (b) | Throwaway build with an `NSExceptionDomains` entry for the IP | Not built. It was reserved for a failing IP row, and case 3b passed. | NOT RUN |

Row (a) proves trust, not ATS. It also shows that case 8's -1200 clears once the certificate is trusted.

### The Mac application

The Mac app has no `NSAppTransportSecurity` entry. It is sandboxed with the network client entitlement. A throwaway command-line tool with an embedded plist (no ATS keys) and a second copy with `NSAllowsLocalNetworking` gave identical results.

| Name | Scheme | macOS default ATS | With `NSAllowsLocalNetworking` |
|---|---|---|---|
| `.local` | HTTP | Allowed | Allowed |
| `127.0.0.1` | HTTP | Allowed | Allowed |
| `localhost` | HTTP | Allowed | Allowed |
| Dotted, not `.local` | HTTP | -1022 | -1022 |
| Any, self-signed | HTTPS | -1202 (-1200 for the dotted name) | same |

On this macOS the default already admits `.local`, IP addresses and one-label names over HTTP. The Mac app was not built or launched; the result comes from the probe, which is not sandboxed. The key only needs adding on the Mac if the maintainer wants the same declared intent as the phone.

The `nscurl --ats-diagnostics` runs tested only HTTPS, since it rewrites the URL. Every configuration failed with -1202 on the self-signed certificate, so it could not tell the ATS configurations apart here. Run it against the production name once that is up.

## What the results imply

The maintainer chooses. These are the options the evidence supports.

- **Keep `NSAllowsLocalNetworking` only.** HTTP works for `.local`, IP and one-label names. A dotted LAN name over HTTP is refused. This matches the plan's expectation and needs no change.
- **Add `NSExceptionDomains` for a named dotted host.** It admits that host over HTTP. It costs one entry per host and is per build.
- **Use HTTPS everywhere.** No ATS key is needed for a public chain. A self-signed certificate fails with -1202 or -1200 until it is trusted, and ATS is not the cause.
- **Trust the certificate on each device.** Row (a) shows this works. It is a profile or pinning decision, which is a separate design.

The production path, HTTPS on a public name through Tailscale Funnel and a Cloudflare proxy, needs no ATS key if the chain is public. This run did not test it. The plan's production checklist still applies.

## Reproduce the rig

The rig uses only macOS tools and Python 3. It needs no `sudo`. Keep certificates and keys outside the repository.

1. Create a certificate with subject alternative names for every name under test.
   ```bash
   openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 90 \
     -keyout key.pem -out cert.pem -subj "/CN=<LocalHostName>.local" \
     -addext "subjectAltName=DNS:<LocalHostName>.local,DNS:localhost,DNS:<mac-ip>.nip.io,IP:<mac-ip>,IP:127.0.0.1" \
     -addext "extendedKeyUsage=serverAuth" -addext "basicConstraints=critical,CA:FALSE"
   ```
2. Start the proxy. It reads the dev instance's host name from the environment and rewrites the `Host` header.
   ```bash
   VICTUAL_UPSTREAM_HOST=<dev instance host> python3 Scripts/transport-test-proxy.py \
     --bind <mac-ip> --bind 127.0.0.1 --bind ::1 --cert cert.pem --key key.pem
   ```
   Plain HTTP listens on 8080 and HTTPS on 8443. Repeat `--bind` for each address.
3. Check the rig before blaming ATS.
   ```bash
   curl -v http://localhost:8080/
   curl -v --cacert cert.pem https://localhost:8443/
   openssl s_client -connect 127.0.0.1:8443 -servername localhost -CAfile cert.pem </dev/null
   ```
   Expect a 302 from the dev instance, `Verify return code: 0`, and TLS 1.3.
4. Build the phone app for the simulator with the shipped plist. The headless `xcodebuild` plugin step needs a build outside a command sandbox. The build used the simulator tool's build action on `Apps/VictualPhone/VictualPhone.xcodeproj`, scheme `VictualPhone`, Debug.
5. The result is ad hoc signed. The simulator linker embeds `application-identifier`, and the Keychain stored the key across launches. Re-signing with a separate keychain entitlement stopped the app launching, so the embedded one was used.
6. Reset the form between rows with `xcrun simctl uninstall` and `install`. Type the URL and key, then tap Connect. The first tap often only closes the keyboard, so tap twice.
7. Capture the network log with `xcrun simctl spawn booted log stream --level debug --predicate 'subsystem == "com.apple.network"'`. The run captured about 13,000 lines. They are not committed.
8. Clean up: stop the proxy, then `xcrun simctl shutdown all`.

To make a one-label name resolve, the maintainer would run this once, with `sudo`:

```bash
echo "<mac-ip> victual-lab" | sudo tee -a /etc/hosts
```

Remove the line afterwards. Then use `http://victual-lab:8080` and `https://victual-lab:8443`, and add `victual-lab` to the certificate names.

## Device run sheet

Do this on an iPhone with the shipped build. The simulator cannot show the device trust store.

**Before starting.** The Mac's firewall must accept inbound connections for the proxy. In Vallum, allow the Python program for inbound connections, or pause the filter. Check from another device on the LAN with `curl http://<mac-ip>:8080/`. A 302 means it works. A reset means it is still blocked.

**URLs.** Replace `<mac-ip>` with the Mac's LAN address, `10.130.30.170` at the time of this run, and `<LocalHostName>` with the Bonjour name, `LTCMDR-Data-659`. Verify both with `scutil --get LocalHostName` and `ifconfig`.

| Case | URL | Expect on a device |
|---|---|---|
| 1 | `http://<LocalHostName>.local:8080` | Connects |
| 2 | `https://<LocalHostName>.local:8443` | -1202, certificate invalid |
| 3 | `http://<mac-ip>:8080` | Connects if iOS allows LAN IPs under `NSAllowsLocalNetworking`. -1022 if not. |
| 4 | `https://<mac-ip>:8443` | -1202 |
| 5 | `http://victual-lab:8080` (needs the hosts line) | Connects |
| 6 | `https://victual-lab:8443` | -1202 |
| 7 | `http://<mac-ip>.nip.io:8080` | -1022 |
| 8 | `https://<mac-ip>.nip.io:8443` | -1200 |

**Steps.**

1. Start the proxy on the Mac as in the rig steps, with `--bind <mac-ip>`.
2. On the phone, open Victual. On the Connect screen, type the URL in Instance and the Adult test key in API key. Tap Connect, and tap again if nothing happens.
3. Read the red message. A successful row shows Scan and the connection details under Settings.
4. To retry a row, open Settings, then Connection, then Forget this instance. The URL stays filled; edit it and re-enter the key.

**Capture the log from the Mac.** Connect the phone by cable, then run:

```bash
log stream --device --predicate 'subsystem == "com.apple.network"' --level debug
```

If `--device` is not available, open Console on the Mac, pick the phone in the sidebar, and filter on `subsystem:com.apple.network`. Note the time of each tap. A -1022 appears as an ATS policy message. A reset appears as a closed connection with no request in the proxy output.

**Trust rows.** To make the HTTPS rows succeed, install the certificate on the phone.

1. Send `cert.pem` to the phone, by AirDrop or a file share, renamed `cert.crt` if needed.
2. Open it. Settings shows Profile Downloaded. Tap it and choose Install.
3. Go to Settings, General, About, Certificate Trust Settings. Turn on full trust for the certificate.
4. Repeat cases 2, 4, 6 and 8. Expect them to connect. This proves trust, not ATS.

Remove the profile afterwards in Settings, General, VPN and Device Management.

## Follow-ups

- Run the production checklist from the plan once the Funnel name is up.
- Open the Mac firewall for one run, so cases 3 and 4 get a real LAN result.
- Settle the dotted-name -1200 with the captured log if the maintainer wants the exact TLS reason.
