# E2E release audit

This runbook is the mandatory pre-release gate for code exercised by
[local-stack](../README.md). Run it against the exact source commits intended
for release; every Phase A, B, and C row must pass before a tag is created.

| Attribute | Value |
|-----------|-------|
| **Applies to** | Service, `pkg`, frontend, gateway/edge, identity (realm), and Compose changes |
| **Execution** | Full audit every time, on a stack recreated from scratch; phases are not selectively skipped |
| **Evidence** | Candidate commit SHAs plus the completed pass/fail table |
| **Pass decision** | `ELIGIBLE FOR TAG` only when every required row passes |
| **Failure decision** | `BLOCKED`; fix, recreate the stack, and rerun the full audit |

## Preconditions

1. Check out every candidate repository at the commit intended for the tag.

2. **Recreate the stack from scratch. Every run — this is not conditional.**

   ```bash
   docker compose down -v          # drops volumes: databases, telemetry stores, edge state
   docker compose up -d --build
   ```

   Cumulative telemetry is what makes this mandatory rather than advisory. Half
   of Phase C reads counters, span tables, and log streams that never reset on
   their own, so a re-used stack cannot tell "this candidate produced it" from
   "the previous run left it behind". `docker compose ps --all` proving a clean
   boot is also the only cheap way to catch a migrate or seed job that would
   have failed on an empty database.

   Two cold-start costs are specific to `down -v` and are expected, not faults:

   - **The Envoy binary is re-downloaded.** The control plane obtains the data
     plane at runtime through func-e into the `envoy-gateway-data` volume, which
     `down -v` deletes. The first `up` therefore needs **outbound internet** and
     the edge answers nothing until the download finishes.
   - **`gateway-certgen` must exit 0 before the gateway starts.** It self-signs
     the xDS material the control plane uses to reach its own Envoy child
     process, into the same deleted volume. `docker compose ps --all` must show
     it `Exited (0)`; a non-zero exit means the gateway is not merely slow, it
     will never serve.

3. **Run every shell block in `bash`.** Two zsh behaviours break this runbook,
   and zsh is the macOS default:

   - `USERNAME` is a **special parameter** in zsh, so `USERNAME=alice $KCT`
     silently mints a token for the *host* account. Every row that depends on
     being alice, bob, or carol then fails for a reason that looks like an
     identity bug.
   - zsh does **not word-split unquoted parameters**, so the runbook's
     multi-word command handles — `$TCLI` and `$S` — are passed as ONE argument.
     `agent-browser $S batch …` answers `Unknown command: --session audit`, and
     `$TCLI workflow list … | grep -q …` reports a false FAIL against a Temporal
     namespace that is perfectly healthy.

   `bash` has neither behaviour. Start a `bash` shell before Phase A and stay in
   it for all three phases.

4. Confirm Compose renders and the runtime is ready:

   ```bash
   docker compose config --quiet
   docker compose ps --all
   ```

5. Verify all long-running application dependencies are running or healthy.
   Every migrate and seed job must have exited successfully. Investigate any
   `unhealthy`, restarting, or non-zero exited container before continuing.
   **The `gateway` container is the one exception**: the Envoy Gateway image is
   distroless, so it can declare no healthcheck and only ever reports `Up`.
   Prove the edge is serving before starting Phase A — this is the readiness
   gate the missing healthcheck cannot provide:

   ```bash
   curl -sf http://localhost:8099/readyz                # control plane loaded the config
   # BLOCK here until the data plane serves. Do not substitute "up completed" or
   # even a 200 from /readyz for this: the control plane reports ready as soon as
   # it has parsed the config, which is minutes before a cold-booted Envoy
   # finishes downloading (see the cold-start note in step 2). Every edge row of
   # Phase A returns curl exit 7 / code 000 in that window, which reads like a
   # broken edge rather than a slow one.
   until [ "$(curl -so /dev/null -w '%{http_code}' \
     http://localhost:8080/product/v1/public/products)" = 200 ]; do sleep 10; done
   echo "edge serving"
   ```

   One more edge check belongs here, because it is cheap and it invalidates the
   whole of Phase C when it fails: the control plane must have **attached the
   EnvoyProxy CR**. Without it the edge still answers 200 on every route while
   emitting no spans at all, so Phase A and Phase B pass and only Phase C
   notices:

   ```bash
   docker compose logs gateway 2>&1 | grep -c 'failed to find envoyproxy'   # want 0
   ```

6. Install and load the browser automation guidance before Phase B:

   ```bash
   agent-browser skills get core
   ```

7. Record the candidate commit set:

   ```bash
   for repo in ../../*-service ../../frontend ../../pkg; do
     printf '%-32s ' "$(basename "$repo")"
     git -C "$repo" rev-parse HEAD
   done
   ```

The stack builds directly from these sibling worktrees. Uncommitted files are
part of the build but cannot be represented by a release tag; the final audit
therefore requires clean candidate worktrees.

**Container runtime.** `docker compose` is the documented command and every row
of this runbook works under podman's compose provider too — with **one** exception
that must be handled at bring-up, or two Phase C rows (**C13**, **C14**) come back
empty while the whole stack looks healthy.

`vector` reads the runtime's API socket. Inside a podman machine
`/var/run/docker.sock` is a **symlink** to `/run/user/<uid>/podman/podman.sock`,
and a bind-mounted symlink resolves in the CONTAINER's mount namespace where the
target does not exist — so Vector exits 78 with `Source "docker": Socket not
found: /var/run/docker.sock`. `local-stack/compose.podman.yaml` fixes it, and all
three of its parts are load-bearing: the **resolved** socket path, `userns_mode:
keep-id` (container root is a subuid, not the socket's `core` owner), and
`security_opt: [label=disable]` (the socket carries an SELinux label that denies
the mount even to its owner). Under podman the bring-up in step 2 becomes:

```bash
export PODMAN_SOCKET="$(podman machine ssh readlink -f /var/run/docker.sock | tr -d '\r')"
export DOCKER_HOST="unix://$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}')"
docker compose -f compose.yaml -f compose.podman.yaml down -v
docker compose -f compose.yaml -f compose.podman.yaml up -d --build
```

Only `up` needs the second file — it is what creates the container — and on Docker
the overlay is not needed at all. Confirm before Phase A either way:

```bash
docker compose ps vector                       # want: Up, not Exited
docker compose logs vector 2>&1 | tail -3      # want: "Started watching for container logs"
```

A `vector` that exited means the overlay was **omitted**, not that the container
needs another restart: a plain `up` re-reads `compose.yaml` and remounts the same
broken symlink. Do not start Phase C with `vector` down.

**Request pacing is not required.** The local edge allows 50 requests per second
in a single window — no minute and no hour bucket
(`gateway/eg/backendtrafficpolicy.yaml`) — a limit no shell-driven row can reach
by hand, and one that cannot leak across runs because Envoy's local rate limiter
is an in-process token bucket with no shared datastore. A 429 during this audit
is therefore a real finding: either the policy was tightened or something is
looping. Investigate it, do not wait it out.

**Tokens come from the realm.** Direct Access Grants are disabled on the realm's
clients, so no `grant_type=password` shortcut exists. Every token below is minted
by `scripts/keycloak-token.sh`, a headless Authorization Code + PKCE flow
(read its header before changing anything about identity).

**A token lives 900 seconds, so mint it in the same block that spends it.** The
realm's access-token lifespan is 15 minutes (A1 asserts it), which is ample for a
human typing rows in sequence and *not* ample for a session that pauses between
them — an agent-driven run, or a run interrupted by a question. A token minted at
the top and used twenty minutes later fails as `401` with body `Jwt is expired`,
which reads exactly like an edge misconfiguration and sends the reader hunting
through the SecurityPolicy. If a row needs a token, either run it in the same
shell block as its `$KCT` call or re-mint first; several rows below (A9, A13, A16)
already mint their own for this reason.

## Phase A — API contract (curl, ~10 min hands-on)

> **These rows are asserted by a k6 suite.** [`scripts/k6/`](../../scripts/k6/)
> expresses each HTTP-shaped row as a check with a per-row threshold, so a failed
> row exits non-zero and prints the evidence table this document asks you to fill
> in by hand ([ADR-056](../../docs/proposals/adr/ADR-056-k6-e2e-assertion-layer/),
> [`docs/testing/k6.md`](../../docs/testing/k6.md)).
>
> | Rows | Command |
> |---|---|
> | A1, A2, A3, A7, A11 | `make e2e-smoke GATE=compose` |
> | A4, A5 | `make e2e-session` — separate because A4 kills the realm session on purpose |
> | A17, A18, A19, A21 | `make e2e-staff` |
> | A20 | `make e2e-operator` |
> | C6, C16, C17, C18, C19, C20, C21 | `make e2e-smoke GATE=compose`, `make e2e-observability` |
>
> **How far this has been verified, precisely.** Every one of these scripts has
> been run against the **cluster** and passes there — 46/46 assertions on the
> staff surface, 26/26 on the operator row, 11/11 on the session rows. What has
> **not** been exercised is this environment: the localhost ports, plain HTTP,
> and local-stack's own Grafana provisioning. `observability.js` in particular
> asserts local-stack's exact provisioned set (five datasources, eighteen
> dashboard uids) and refuses to run anywhere else, so it has only been checked
> for parse and imports. Treat a first compose run as the verification it is, and
> expect to find something: porting these rows to the cluster turned up two that
> could not pass as written and three dashboards whose datasource references
> resolve to nothing.
>
> The rows this suite does **not** cover stay exactly as written below: A6, A8,
> A9, A10, A12–A16 need `psql`, `valkey-cli`, `docker compose exec` or the
> Temporal CLI, and Phase B is a browser.


Timing is dominated by waits, not by typing: A10 sleeps 13s, A12 polls up to 24s,
A14 restarts `temporal` and waits for it to report healthy, and the conditional
A15 adds roughly 5 minutes of drill. **A13 is the outlier** — it is gated on the
checkout session TTL (30 minutes by default), which is exactly why it is armed
before A1 and read at the end instead of being run in place. **A20** adds its own
wait: it parks an order through a real declined refund and polls for up to 2
minutes, because the compensation has to fail before there is anything to resolve.

```bash
# ---- Preamble. Run this first, in the shell you will use for every row —
#      including A13, which is armed before A1. Skipping it leaves $TCLI, $KCT
#      and audit_curl unset and the arming snippet fails with "command not found".
BASE=http://localhost:8080
KC=http://localhost:8081/realms/duynhlab
KCT=./scripts/keycloak-token.sh        # run this block from homelab/local-stack

# One indirection for every call, kept so pacing could be reinstated in ONE place
# if the edge policy ever tightens. It does not sleep: the local edge allows
# 50 req/s (see Preconditions).
audit_curl() {
  curl "$@"
}

# Every `temporal ...` call in this audit runs in temporal-admintools: the
# `temporalio/server` image ships only the server binary, so
# `exec -T temporal temporal ...` fails with "not found".
TCLI="docker compose exec -T temporal-admintools temporal"

# ---- A13 (arm). Physically here, not down at A13, because the block must be
#      runnable top-to-bottom: the timer needs the session's full TTL (30 min by
#      default) to fire, and A13's read is the LAST thing Phase A does. Arming it
#      in place would read a timer three minutes old and report a false 200.
#
#      It needs its OWN user. One active session per user is a partial unique
#      index, so A9/A10 would adopt this session and every mutation re-arms it.
#      That user is `bob`, a seeded realm user — self-registration is gone with
#      the identity cutover (the realm sets registrationAllowed=false and only an
#      admin API call could create a user), and every other Phase A row is alice.
#      Because the user is a FIXED one, clear any session an earlier run left
#      active first — otherwise the POST below adopts it and A13 silently watches
#      the previous run's timer.
TAT=$(USERNAME=bob $KCT)
OLD=$(audit_curl -s -X POST $BASE/checkout/v1/private/checkout/sessions -H "Authorization: Bearer $TAT" \
  | python3 -c "import json,sys;print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
[ -n "$OLD" ] && audit_curl -s -o /dev/null -X DELETE \
  $BASE/checkout/v1/private/checkout/sessions/$OLD -H "Authorization: Bearer $TAT"
audit_curl -s -o /dev/null -X POST $BASE/cart/v1/private/cart -H "Authorization: Bearer $TAT" \
  -H 'Content-Type: application/json' \
  -d '{"product_id":"1","product_name":"Wireless Mouse","product_price":29.99,"quantity":1}'
TSID=$(audit_curl -s -X POST $BASE/checkout/v1/private/checkout/sessions -H "Authorization: Bearer $TAT" | \
  python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
$TCLI workflow list --namespace mop \
  -q "WorkflowId = 'checkout-abandon-$TSID'" </dev/null 2>/dev/null | head -3   # want Running
echo "A13 armed: session $TSID — do not touch it; read the result at A13"

# A1. Token acquisition through the realm (RFC-0024 P3). Headless
#     Authorization Code + PKCE — there is no password grant, because the realm's
#     clients have Direct Access Grants disabled, exactly as in the cluster.
#     The assertions are the identity cutover's evidence: the token is issued by
#     the realm, and `sub` is alice's FIXED UUID — as a JSON STRING, which is the
#     ADR-042 string-subject contract the whole fleet now stores.
R=$(USERNAME=alice KC_OUTPUT=json $KCT)
echo "$R" | python3 -c "
import base64, json, sys
d = json.load(sys.stdin)
at = d['access_token']
assert at.count('.') == 2 and d['refresh_token'] and d['expires_in'], sorted(d)
p = at.split('.')[1]
c = json.loads(base64.urlsafe_b64decode(p + '=' * (-len(p) % 4)))
assert c['iss'] == 'http://localhost:8081/realms/duynhlab', c['iss']
assert isinstance(c['sub'], str), type(c['sub'])
assert c['sub'] == 'a11ce000-0000-4000-8000-000000000001', c['sub']
assert 'duynhlab-platform' in (c['aud'] if isinstance(c['aud'], list) else [c['aud']]), c['aud']
print('A1 OK iss=%s sub=%s (str) aud=%s' % (c['iss'], c['sub'], c['aud']))
"
AT=$(echo "$R" | python3 -c "import json,sys;print(json.load(sys.stdin)['access_token'])")
RT=$(echo "$R" | python3 -c "import json,sys;print(json.load(sys.stdin)['refresh_token'])")

# A2. Private routes 200 through the Envoy edge with a realm token. What this
#     proves is the whole edge auth path in one line: the jwt_authn filter
#     fetched the realm's JWKS at boot, validated this token against it, and
#     forwarded the request to an audience-scoped route.
for p in user/v1/private/users/profile cart/v1/private/cart order/v1/private/orders \
         notification/v1/private/notifications; do
  [ "$(audit_curl -s -o /dev/null -w '%{http_code}' $BASE/$p -H "Authorization: Bearer $AT")" = 200 ] \
    && echo "A2 OK /$p" || echo "A2 FAIL /$p"
done

# A3. Bad / missing token → 401 AT THE EDGE, before the request reaches a
#     service. The jwt_authn filter answers `content-type: text/plain` with a
#     short reason string in the body, and it DOES set `www-authenticate`:
#       no token      -> Bearer realm="<the requested URL>"
#       broken token  -> the same, plus error="invalid_token"
#     The realm value is the request URL, not an identity-provider URL — Envoy
#     echoes what was asked for. All three facts are asserted; none is optional.
audit_curl -s -o /dev/null -w "A3 bad-token: %{http_code} (want 401)\n" \
  $BASE/cart/v1/private/cart -H "Authorization: Bearer x.y.z"
audit_curl -s -w "\nA3 no-token:  %{http_code} (want 401, body 'Jwt is missing')\n" \
  $BASE/cart/v1/private/cart
audit_curl -s -o /dev/null -D - $BASE/cart/v1/private/cart | grep -i '^www-authenticate' \
  | grep -q 'Bearer realm="http://localhost:8080/cart/v1/private/cart"' \
  && echo "A3 challenge:  OK www-authenticate echoes the requested URL" \
  || echo "A3 challenge:  FAIL missing/changed www-authenticate"
audit_curl -s -o /dev/null -D - $BASE/cart/v1/private/cart \
  -H "Authorization: Bearer x.y.z" | grep -i '^www-authenticate' \
  | grep -q 'error="invalid_token"' \
  && echo "A3 invalid:    OK error=\"invalid_token\" added when a token is present" \
  || echo "A3 invalid:    FAIL no error=\"invalid_token\" on an unverifiable token"

# A4. Refresh rotation and reuse detection, asserted against the realm's token
#     endpoint — the realm owns this behaviour. `duynhlab` sets
#     revokeRefreshToken=true + refreshTokenMaxReuse=0, so a replay is not merely
#     refused: it kills the SESSION, and the rotated token that was still valid a
#     moment ago dies with it. 400 invalid_grant (not 401) is the OAuth2 token
#     endpoint's error contract, not an edge rejection.
R2=$(audit_curl -s -X POST $KC/protocol/openid-connect/token \
  -d grant_type=refresh_token -d client_id=customer-spa --data-urlencode "refresh_token=$RT")
RT2=$(echo "$R2" | python3 -c "import json,sys;print(json.load(sys.stdin)['refresh_token'])")
[ "$RT2" != "$RT" ] && echo "A4 rotated:         OK new refresh token" || echo "A4 rotated:         FAIL not rotated"
# Replaying the consumed token: 400 + "Maximum allowed refresh token reuse exceeded".
audit_curl -s -o /tmp/a4-replay -w "A4 replay-old:      %{http_code} (want 400)\n" \
  -X POST $KC/protocol/openid-connect/token \
  -d grant_type=refresh_token -d client_id=customer-spa --data-urlencode "refresh_token=$RT"
grep -q 'Maximum allowed refresh token reuse exceeded' /tmp/a4-replay \
  && echo "A4 replay reason:   OK reuse detected" \
  || echo "A4 replay reason:   FAIL unexpected body: $(cat /tmp/a4-replay)"
# CONFIRMED BEHAVIOUR: the replay above revokes the whole family, so RT2 — the
# rotated token that worked seconds ago — is now dead too, with a DIFFERENT
# reason: "Session doesn't have required client". Both sub-rows are required.
audit_curl -s -X POST $KC/protocol/openid-connect/token \
  -d grant_type=refresh_token -d client_id=customer-spa --data-urlencode "refresh_token=$RT2" \
  -o /tmp/a4-family -w "A4 family-revoked:  %{http_code} (want 400 — the replay killed the session)\n"
grep -q 'invalid_grant' /tmp/a4-family \
  && echo "A4 family reason:   OK $(cat /tmp/a4-family)" \
  || echo "A4 family-revoked:  FAIL the rotated token survived the replay"

# A5. Logout revokes the realm session; a later refresh dies. Keycloak's
#     end-session endpoint answers 204 (no body) for a public client posting its
#     refresh token, and is idempotent.
R3=$(USERNAME=alice KC_OUTPUT=json $KCT)
RT3=$(echo "$R3" | python3 -c "import json,sys;print(json.load(sys.stdin)['refresh_token'])")
audit_curl -s -o /dev/null -w "A5 logout:          %{http_code} (want 204)\n" \
  -X POST $KC/protocol/openid-connect/logout \
  -d client_id=customer-spa --data-urlencode "refresh_token=$RT3"
# CONFIRMED BEHAVIOUR: the replayed logout is 204, not 400 — the endpoint is
# genuinely idempotent for an already-revoked token, so assert 204 both times.
audit_curl -s -o /dev/null -w "A5 logout-replay:   %{http_code} (want 204 — idempotent)\n" \
  -X POST $KC/protocol/openid-connect/logout \
  -d client_id=customer-spa --data-urlencode "refresh_token=$RT3"
# ...and the refresh afterwards dies with 400 "Session not active" — a different
# reason from A4's reuse detection, because here the session was ended, not reused.
audit_curl -s -o /tmp/a5-refresh -w "A5 refresh-after:   %{http_code} (want 400)\n" \
  -X POST $KC/protocol/openid-connect/token \
  -d grant_type=refresh_token -d client_id=customer-spa --data-urlencode "refresh_token=$RT3"
grep -q 'Session not active' /tmp/a5-refresh \
  && echo "A5 refresh reason:  OK session ended" \
  || echo "A5 refresh reason:  FAIL unexpected body: $(cat /tmp/a5-refresh)"

# A6. Removed surfaces stay removed. auth-service is GONE from local-stack — no
#     container, no Backend, no HTTPRoute, no database — so this row no longer
#     inspects a table inside the `auth` database; it asserts the DATABASE itself
#     is absent (it is dropped from postgres/init.sql). The retired token layer's
#     cluster surface (apps/services/auth.yaml, the auth DB triplet, the ESO
#     secrets) retires in RFC-0024 P5, which needs Kind; locally the end state is
#     already what this gate runs against.
audit_curl -s -o /dev/null -w "A6 /private/me:     %{http_code} (want 404 — no route matches at the edge)\n" \
  $BASE/auth/v1/private/me -H "Authorization: Bearer $AT"
docker compose exec -T postgres psql -U postgres -lqt </dev/null \
  | cut -d'|' -f1 | tr -d ' ' | grep -qx auth \
  && echo "A6 FAIL: the auth database still exists" \
  || echo "A6 OK: no auth database"

# A7. v3 collection-noun paths (ADR-017): new canonical 200 + deprecated
#     aliases still answering during the expand phase (removed at contract).
#     Shipping only. The `POST /auth/v1/public/login` alias that used to be
#     checked here is not "deprecated but serving" — it certified the retired
#     token layer, and with auth-service gone from local-stack there is no
#     backend and no route behind it. Nothing to expand-phase.
audit_curl -s -o /dev/null -w "A7 shipments/track:     %{http_code} (want 200)\n" \
  "$BASE/shipping/v1/public/shipments/track?tracking_number=1Z999AA10123456784"
audit_curl -s -o /dev/null -w "A7 shipments/estimate:  %{http_code} (want 200)\n" \
  "$BASE/shipping/v1/public/shipments/estimate?origin=HN&destination=SG&weight=1"
audit_curl -s -o /dev/null -w "A7 alias track:         %{http_code} (want 200 — deprecated)\n" \
  "$BASE/shipping/v1/public/track?tracking_number=1Z999AA10123456784"

# A8. Renamed zero-caller internal paths are gone (no aliases kept):
#     these are cluster-internal, so probe the service containers directly.
docker compose exec -T notification wget -q -O /dev/null -S \
  --post-data '{}' --header 'Content-Type: application/json' \
  http://localhost:8080/notification/v1/internal/notify/email </dev/null 2>&1 | head -1
# want: HTTP/1.1 404 (the /notifications/{email,sms} paths replaced notify/*)
docker compose exec -T shipping wget -q -O /dev/null -S \
  http://localhost:8080/shipping/v1/internal/orders/1 </dev/null 2>&1 | head -1
# want: HTTP/1.1 404 (now /shipping/v1/internal/shipments/orders/:orderId)

#     Then the other half of A8: an `/internal/` path that DOES exist must still
#     be unreachable *through the edge*. Probe the two services whose routes were
#     once declared on a bare prefix — product's create needs no JWT at all, and
#     cart's takes the user id from the path, so a wide prefix there lets any
#     shopper's token clear another shopper's cart. The 404 comes from "no
#     HTTPRoute matches this path" — every route in gateway/eg/routes.yaml is
#     audience-scoped — which is why the response is a 404 and not a 401.
audit_curl -s -o /dev/null -w "A8 product internal: %{http_code} (want 404 — no route matches)\n" \
  -X POST $BASE/product/v1/internal/products -H 'Content-Type: application/json' -d '{}'
audit_curl -s -o /dev/null -w "A8 cart internal:    %{http_code} (want 404 — no route matches)\n" \
  -X DELETE $BASE/cart/v1/internal/cart/1 -H "Authorization: Bearer $AT"

# A9. Checkout sessions (RFC-0015 P1) — lifecycle through the edge JWT filter.
#     CLEAR THE CART FIRST. The row's totals must be its own: anything left in
#     this shopper's cart from a previous session, a demo, or a traffic
#     generator changes the amount — and mockpay declines by amount SUFFIX
#     (cents 02 generic_decline, 95 insufficient_funds, 19 processing_error,
#     provider.go). A leftover item that pushes the total onto one of those
#     suffixes fails A10's confirm and then A12, for a reason that has nothing
#     to do with the change under test. Measured: a contaminated cart produced
#     total=62.02 and a deterministic generic_decline.
AT9=$(USERNAME=alice $KCT)
audit_curl -s -o /dev/null -X DELETE $BASE/cart/v1/private/cart -H "Authorization: Bearer $AT9"
audit_curl -s -X POST $BASE/cart/v1/private/cart -H "Authorization: Bearer $AT9" \
  -H 'Content-Type: application/json' \
  -d '{"product_id":"1","product_name":"Wireless Mouse","product_price":29.99,"quantity":1}' -o /dev/null
# The create is the row's FIRST status assertion, not just a way to get an id:
# the documented lifecycle is 201 -> 200 -> 200 -> 200 and 201 is the only code
# in it that is unique to creation, so an idempotent-adopt regression (200 on a
# fresh session) has to be caught here or not at all.
S9_RAW=$(audit_curl -s -w '\n%{http_code}' -X POST $BASE/checkout/v1/private/checkout/sessions \
  -H "Authorization: Bearer $AT9")
S9_CODE=${S9_RAW##*$'\n'}
S9=${S9_RAW%$'\n'*}
[ "$S9_CODE" = 201 ] && echo "A9 create:   201 OK" || echo "A9 create:   FAIL HTTP $S9_CODE (want 201) — $S9"
SID=$(echo "$S9" | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
echo "A9 session:  $SID ($(echo "$S9" | python3 -c "import json,sys;print(json.load(sys.stdin)['status'])"))"
audit_curl -s -o /dev/null -w "A9 re-create: %{http_code} (want 200 — idempotent, same session)\n" \
  -X POST $BASE/checkout/v1/private/checkout/sessions -H "Authorization: Bearer $AT9"
audit_curl -s -o /dev/null -w "A9 get:       %{http_code} (want 200)\n" \
  $BASE/checkout/v1/private/checkout/sessions/$SID -H "Authorization: Bearer $AT9"
audit_curl -s -o /dev/null -w "A9 address:   %{http_code} (want 200 → address_set)\n" \
  -X PUT $BASE/checkout/v1/private/checkout/sessions/$SID/address -H "Authorization: Bearer $AT9" \
  -H 'Content-Type: application/json' \
  -d '{"full_name":"Alice","line1":"1 Main St","city":"HN","country":"VN"}'
audit_curl -s -o /dev/null -w "A9 cancel:    %{http_code} (want 200)\n" \
  -X DELETE $BASE/checkout/v1/private/checkout/sessions/$SID -H "Authorization: Bearer $AT9"
audit_curl -s -o /dev/null -w "A9 no-token:  %{http_code} (want 401 at the edge)\n" \
  -X POST $BASE/checkout/v1/private/checkout/sessions
audit_curl -s -o /dev/null -w "A9 old path:  %{http_code} (want 404 — /api/v1/checkout removed)\n" \
  -X POST $BASE/api/v1/checkout
# Price-change detection (the RFC-0015 P1 exit criterion): bump a catalog
# price, create a fresh session, expect the line flagged.
docker compose exec -T postgres psql -U postgres -d product -c \
  "UPDATE products SET price = price + 1 WHERE id = 1" </dev/null >/dev/null
S9_PRICE=$(audit_curl -s -X POST $BASE/checkout/v1/private/checkout/sessions -H "Authorization: Bearer $AT9")
echo "$S9_PRICE" | python3 -c "import json,sys; s=json.load(sys.stdin); \
  print('A9 price-change:', 'OK' if any(i['price_changed'] for i in s['items']) else 'FAIL', \
  [ (i['product_id'], i['price_changed'], i['unit_price']) for i in s['items'] ]); \
  raise SystemExit(0 if any(i['price_changed'] for i in s['items']) else 1)"
SID9_PRICE=$(echo "$S9_PRICE" | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
docker compose exec -T postgres psql -U postgres -d product -c \
  "UPDATE products SET price = price - 1 WHERE id = 1" </dev/null >/dev/null
# The price-change probe populated product:1 with the temporary value. Remove
# both test artifacts so A10 starts with a new session and revalidates against
# the restored catalog price.
docker compose exec -T cache valkey-cli DEL product:1 </dev/null >/dev/null
audit_curl -s -o /dev/null -w "A9 price-session cleanup: %{http_code} (want 200)\n" \
  -X DELETE $BASE/checkout/v1/private/checkout/sessions/$SID9_PRICE -H "Authorization: Bearer $AT9"

# A10. Confirm handoff + abandonment (RFC-0015 P2). Full lifecycle: fresh
#      session → address → shipping → payment → confirm (Idempotency-Key
#      REQUIRED) → order created + fulfillment saga → replay = same order.
AT0=$(USERNAME=alice $KCT)
# Same reason as A9: the confirm's amount must be this row's, not a leftover's.
audit_curl -s -o /dev/null -X DELETE $BASE/cart/v1/private/cart -H "Authorization: Bearer $AT0"
audit_curl -s -X POST $BASE/cart/v1/private/cart -H "Authorization: Bearer $AT0" \
  -H 'Content-Type: application/json' \
  -d '{"product_id":"1","product_name":"Wireless Mouse","product_price":29.99,"quantity":1}' -o /dev/null
S=$(audit_curl -s -X POST $BASE/checkout/v1/private/checkout/sessions -H "Authorization: Bearer $AT0")
SID=$(echo "$S" | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
audit_curl -s -o /dev/null -X PUT $BASE/checkout/v1/private/checkout/sessions/$SID/address \
  -H "Authorization: Bearer $AT0" -H 'Content-Type: application/json' \
  -d '{"full_name":"Alice","line1":"1 Main St","city":"HN","country":"VN"}'
# P3: the fee is quoted by shipping (standard/VN = $3.00) and the flat tax
# (tax_rules: VN 8%) applies on subtotal + fee — assert the composition.
audit_curl -s -X PUT $BASE/checkout/v1/private/checkout/sessions/$SID/shipping \
  -H "Authorization: Bearer $AT0" -H 'Content-Type: application/json' \
  -d '{"shipping_method":"standard"}' | python3 -c "import json,sys; s=json.load(sys.stdin); \
  ok = s['shipping_fee']==3.0 and abs(s['tax']-round((s['subtotal']+3.0)*0.08,2))<0.011 \
       and abs(s['total']-(s['subtotal']+s['shipping_fee']+s['tax']))<0.001; \
  print('A10 shipping:', 'OK' if ok else 'FAIL', \
        f\"fee={s['shipping_fee']} tax={s['tax']} total={s['total']} ({s['status']})\")"
audit_curl -s -o /dev/null -w "A10 bad-method: %{http_code} (want 400 — unknown quote input)\n" \
  -X PUT $BASE/checkout/v1/private/checkout/sessions/$SID/shipping \
  -H "Authorization: Bearer $AT0" -H 'Content-Type: application/json' \
  -d '{"shipping_method":"drone"}'
audit_curl -s -o /dev/null -w "A10 payment:  %{http_code} (want 200 → ready)\n" \
  -X PUT $BASE/checkout/v1/private/checkout/sessions/$SID/payment \
  -H "Authorization: Bearer $AT0" -H 'Content-Type: application/json' \
  -d '{"payment_method_token":"tok_visa_ok"}'
audit_curl -s -o /dev/null -w "A10 PAN reject: %{http_code} (want 400 — tok_ only, never persisted)\n" \
  -X PUT $BASE/checkout/v1/private/checkout/sessions/$SID/payment \
  -H "Authorization: Bearer $AT0" -H 'Content-Type: application/json' \
  -d '{"payment_method_token":"tok_4111111111111111"}'
audit_curl -s -o /dev/null -w "A10 no-key:   %{http_code} (want 400 IDEMPOTENCY_KEY_REQUIRED)\n" \
  -X POST $BASE/checkout/v1/private/checkout/sessions/$SID/confirm -H "Authorization: Bearer $AT0"
# P4: apply a promo (validated preview — never counts a use) and assert the
# discount line + that the ORDER total equals the SESSION total (the saga
# charges order.Total, so they must be the same number).
audit_curl -s -X POST $BASE/checkout/v1/private/checkout/sessions/$SID/promo \
  -H "Authorization: Bearer $AT0" -H 'Content-Type: application/json' \
  -d '{"code":"WELCOME10"}' | python3 -c "import json,sys; s=json.load(sys.stdin); \
  ok = s['promo_code']=='WELCOME10' and abs(s['discount']-round(s['subtotal']*0.10,2))<0.011 \
       and abs(s['total']-(s['subtotal']+s['shipping_fee']+s['tax']-s['discount']))<0.001; \
  print('A10 promo:', 'OK' if ok else 'FAIL', f\"discount={s['discount']} total={s['total']}\")"
audit_curl -s -o /dev/null -w "A10 promo-bad:  %{http_code} (want 404 PROMO_INVALID)\n" \
  -X POST $BASE/checkout/v1/private/checkout/sessions/$SID/promo \
  -H "Authorization: Bearer $AT0" -H 'Content-Type: application/json' -d '{"code":"NOPE"}'
audit_curl -s -o /dev/null -w "A10 promo-exp:  %{http_code} (want 409 PROMO_EXPIRED)\n" \
  -X POST $BASE/checkout/v1/private/checkout/sessions/$SID/promo \
  -H "Authorization: Bearer $AT0" -H 'Content-Type: application/json' -d '{"code":"EXPIRED1"}'
#     A spent cap is a refusal the shopper can act on, so it must answer 409 with
#     a code the SPA can word — not the 500 it gave until checkout 0.7.1, which
#     rendered as "Service temporarily unavailable" in the promo field while the
#     confirm gate worded the identical condition correctly. SCARCE is seeded
#     with max_redemptions = 5; spending it by hand is deterministic and costs
#     no extra funnel (apply never counts a use, so it cannot be exhausted
#     through the API without five confirms). The 409 leaves the session's
#     existing promo untouched, so the confirm below is unaffected.
docker compose exec -T postgres psql -U postgres -d checkout -q -c \
  "UPDATE promo_codes SET redeemed_count = max_redemptions WHERE code = 'SCARCE'"
audit_curl -s -o /tmp/a10-spent.json \
  -w "A10 promo-spent: %{http_code} (want 409 PROMO_EXHAUSTED)\n" \
  -X POST $BASE/checkout/v1/private/checkout/sessions/$SID/promo \
  -H "Authorization: Bearer $AT0" -H 'Content-Type: application/json' -d '{"code":"SCARCE"}'
grep -q PROMO_EXHAUSTED /tmp/a10-spent.json \
  && echo "A10 promo-spent code: OK" \
  || { echo "A10 promo-spent code: FAIL — $(cat /tmp/a10-spent.json)"; }
KEY="a10-$(date +%s)"
C_RAW=$(audit_curl -s -w '\n%{http_code}' -X POST $BASE/checkout/v1/private/checkout/sessions/$SID/confirm \
  -H "Authorization: Bearer $AT0" -H "Idempotency-Key: $KEY")
C_CODE=${C_RAW##*$'\n'}
C=${C_RAW%$'\n'*}
[ "$C_CODE" = 201 ] || { echo "A10 confirm: FAIL HTTP $C_CODE — $C"; exit 1; }
OID=$(echo "$C" | python3 -c "import json,sys;print(json.load(sys.stdin).get('order_id',''))")
echo "$C" | python3 -c "import json,sys; c=json.load(sys.stdin); \
  assert c.get('order_id'), 'missing order_id'; assert c.get('status')=='completed', c; \
  print('A10 confirm:  order', c['order_id'], '(completed)')"
# Replay with the SAME key → the SAME order, no second saga.
C2_RAW=$(audit_curl -s -w '\n%{http_code}' -X POST $BASE/checkout/v1/private/checkout/sessions/$SID/confirm \
  -H "Authorization: Bearer $AT0" -H "Idempotency-Key: $KEY")
C2_CODE=${C2_RAW##*$'\n'}
C2=${C2_RAW%$'\n'*}
[ "$C2_CODE" = 201 ] || { echo "A10 replay: FAIL HTTP $C2_CODE — $C2"; exit 1; }
[ "$(echo "$C2" | python3 -c "import json,sys;print(json.load(sys.stdin).get('order_id',''))")" = "$OID" ] \
  && echo "A10 replay:   OK same order $OID" || { echo "A10 replay: FAIL different order"; exit 1; }
# The order exists, its saga ran, AND its total equals the session total
# (fee + tax + discount crossed the boundary — the P3 demo-fee gap is closed).
# POLL, do not sleep. The saga is asynchronous, so a fixed wait asserts on
# whatever state the clock happened to catch: measured on a stack whose product
# and payment containers had just been rebuilt, five seconds caught order 15 at
# `pending` and the row failed — then A12 failed too, because it tried to cancel
# an order that had not reached a cancellable state. The same order read
# `completed` moments later. Poll until the status is terminal, with a bound so
# a genuinely stuck saga still fails the row instead of hanging the audit.
STOTAL=$(echo "$C" | python3 -c "import json,sys;print(json.load(sys.stdin)['total'])")
for _ in $(seq 1 30); do
  OSTATUS=$(audit_curl -s $BASE/order/v1/private/orders/$OID -H "Authorization: Bearer $AT0" \
    | python3 -c "import json,sys;print(json.load(sys.stdin).get('status',''))")
  case "$OSTATUS" in confirmed|completed|failed|cancelled) break;; esac
  sleep 2
done
audit_curl -s $BASE/order/v1/private/orders/$OID -H "Authorization: Bearer $AT0" | \
  python3 -c "import json,sys; o=json.load(sys.stdin); \
  ok=o['status'] in {'confirmed','completed'} and abs(float(o['total'])-float('$STOTAL'))<0.001; \
  print('A10 order:', 'OK' if ok else 'FAIL', o['id'], o['status'], f\"total={o['total']}\"); \
  raise SystemExit(0 if ok else 1)"
# One redemption exactly, order_id backfilled:
docker compose exec -T postgres psql -U postgres -d checkout -t -c \
  "SELECT code, order_id IS NOT NULL AS used FROM promo_redemptions ORDER BY id DESC LIMIT 1" </dev/null
$TCLI workflow list --namespace mop -q "WorkflowId = 'order-fulfillment-$OID'" </dev/null 2>/dev/null | head -3

# Abandonment (ADR-019): the DB deadline is the authority; the workflow timer
# makes expiry proactive. Shorten the DB deadline and verify the outcome.
AT1=$(USERNAME=alice $KCT)
audit_curl -s -X POST $BASE/cart/v1/private/cart -H "Authorization: Bearer $AT1" -H 'Content-Type: application/json' \
  -d '{"product_id":"2","product_name":"USB Hub","product_price":79.99,"quantity":1}' -o /dev/null
SID2=$(audit_curl -s -X POST $BASE/checkout/v1/private/checkout/sessions -H "Authorization: Bearer $AT1" | \
  python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
docker compose exec -T postgres psql -U postgres -d checkout -c \
  "UPDATE checkout_sessions SET expires_at = now() + interval '5 seconds' WHERE id = '$SID2'" </dev/null >/dev/null
sleep 8
# Any read past the DB deadline answers 410 — the lazy backstop, worker or not:
audit_curl -s -o /dev/null -w "A10 lazy-410: %{http_code} (want 410 once past expires_at)\n" \
  $BASE/checkout/v1/private/checkout/sessions/$SID2 -H "Authorization: Bearer $AT1"
docker compose exec -T postgres psql -U postgres -d checkout -t -c \
  "SELECT status, expired_reason FROM checkout_sessions WHERE id = '$SID2'" </dev/null
# want: expired | lazy (the read got there first) or timer (the worker did)

# A11. Exercise the product-details fan-out so the full audit covers product,
#      inventory, and review before trace coverage is evaluated in C4/C6.
audit_curl -s "$BASE/product/v1/public/products/1/details" | python3 -c "import json,sys; d=json.load(sys.stdin); \
  p=d.get('product') or {}; a=d.get('availability') or {}; reviews=d.get('reviews'); summary=d.get('reviews_summary') or {}; \
  ok=p.get('id')=='1' and a.get('available_to_promise') is not None and isinstance(reviews,list) and len(reviews)>0 and summary.get('total')==len(reviews); \
  print('A11 details:', 'OK full fan-out response' if ok else 'FAIL incomplete inventory/review enrichment'); \
  raise SystemExit(0 if ok else 1)"

# A12. Cancellation unwind (ADR-033). Nothing else in this audit touches
#      CancellationWorkflow. Reuses $OID from A10, which is `completed` by now and
#      still cancellable because its shipment was never dispatched. The episode
#      always COMPLETES; the ORDER's state carries the outcome.
audit_curl -s -o /dev/null -w "A12 cancel:   %{http_code} (want 202 — episode opened)\n" \
  -X POST "$BASE/order/v1/private/orders/$OID/cancel" -H "Authorization: Bearer $AT"
audit_curl -s -o /dev/null -w "A12 replay:   %{http_code} (want 200 — idempotent)\n" \
  -X POST "$BASE/order/v1/private/orders/$OID/cancel" -H "Authorization: Bearer $AT"
for _ in 1 2 3 4 5 6; do
  sleep 4
  CST=$(audit_curl -s "$BASE/order/v1/private/orders/$OID" -H "Authorization: Bearer $AT" | \
    python3 -c "import json,sys;print(json.load(sys.stdin)['status'])")
  [ "$CST" = cancelled ] && break
done
echo "A12 status:   $CST (want cancelled; manual_review = a compensation did not converge)"
# The dispatch row and the workflow id must AGREE. `cancellation_requests` is the
# outbox: one row per order, status PENDING|DISPATCHED|FAILED, plus the `epoch` —
# the orders.version the server read when it accepted the cancel. The workflow id
# is `order-cancellation-<orderId>-v<epoch>`, so a second episode cannot replay
# the first one's outcome. This used to print both and leave the comparison to the
# reader; the comparison is the assertion, so it is made here.
A12ROW=$(docker compose exec -T postgres psql -U postgres -d order -t -A -F, -c \
  "SELECT status, epoch FROM cancellation_requests WHERE order_id = $OID" </dev/null | tr -d '[:space:]')
echo "A12 outbox:   $A12ROW (want DISPATCHED,<epoch>)"
case "$A12ROW" in DISPATCHED,*) ;; *) echo "A12 outbox:   FAIL not DISPATCHED" ;; esac
$TCLI workflow list --namespace mop \
  -q "WorkflowType = 'CancellationWorkflow'" </dev/null 2>/dev/null \
  | grep -q "order-cancellation-$OID-v${A12ROW##*,}" \
  && echo "A12 epoch:    OK workflow id order-cancellation-$OID-v${A12ROW##*,} matches the outbox epoch" \
  || echo "A12 epoch:    FAIL no CancellationWorkflow id carries the outbox epoch"

# A13. The abandonment timer actually fires (ADR-019). A10 above only ever
#      produces expired(lazy) — it moves the DB deadline, not the armed timer — so
#      without this row the third workflow has no evidence it works at all.
#      ARMED IN THE PREAMBLE, read here: $TAT and $TSID come from that block, and
#      the timer has been running for the whole of A1–A12 by the time this line
#      is reached. If the session's TTL has not elapsed yet the read below returns
#      200 — that is `pending`, not a failure. Leave the session untouched and
#      re-run these three lines later; anything that mutates it re-arms the timer.
audit_curl -s -o /dev/null -w "A13 timer-410: %{http_code} (want 410)\n" \
  "$BASE/checkout/v1/private/checkout/sessions/$TSID" -H "Authorization: Bearer $TAT"
docker compose exec -T postgres psql -U postgres -d checkout -t -c \
  "SELECT status, expired_reason FROM checkout_sessions WHERE id = '$TSID'" </dev/null
# want: expired | timer. `lazy` here means a read beat the timer — that is
# INCONCLUSIVE, not a pass, because it only proves the backstop. Retry.


# A14. Durability — Temporal state survives a server restart. This is the whole
#      reason local Temporal runs on PostgreSQL instead of an in-memory dev
#      server: before the move, a restart took the namespace from nine live
#      executions to zero.
BEFORE=$($TCLI workflow list --namespace mop </dev/null 2>/dev/null | tail -n +2 | grep -c .)
docker compose restart temporal >/dev/null
# Poll `.Health`, never `.Status`. Docker's `.Status` embeds "(healthy)" but
# podman's compose provider does NOT — it prints a bare "Up 54 seconds" — so a
# `.Status | grep healthy` loop spins forever there against a container that is
# already healthy. An infinite wait is indistinguishable from a slow restart,
# which is why this is pinned to the field both providers populate.
until [ "$(docker compose ps temporal --format '{{.Health}}')" = healthy ]; do sleep 5; done
AFTER=$($TCLI workflow list --namespace mop </dev/null 2>/dev/null | tail -n +2 | grep -c .)
echo "A14 executions: before=$BEFORE after=$AFTER (want equal and non-zero)"
$TCLI workflow show --workflow-id "order-fulfillment-$OID" --namespace mop </dev/null 2>/dev/null | head -3
# want: the same execution still listed, its history still readable

# A16. STRING SUBJECTS REACH THE DATABASE (ADR-042). Numbered last but placed
#      here, ahead of the CONDITIONAL A15, so a required row never sits behind an
#      optional one. A1 proves the realm mints a
#      string `sub`; this proves the whole chain honours it — edge JWT filter,
#      pkg/authmw, handler, and the column type. A numeric-id regression anywhere
#      would show up here as an integer-looking user_id or a 500, not as a
#      token-shaped failure. Self-contained: it mints its own token, writes a cart
#      row, and reads that row back out of PostgreSQL.
AT16=$(USERNAME=carol $KCT)
audit_curl -s -o /dev/null -X POST $BASE/cart/v1/private/cart -H "Authorization: Bearer $AT16" \
  -H 'Content-Type: application/json' \
  -d '{"product_id":"1","product_name":"Wireless Mouse","product_price":29.99,"quantity":1}'
docker compose exec -T postgres psql -U postgres -d cart -t -A -c \
  "SELECT DISTINCT user_id FROM cart_items WHERE user_id = 'a11ce000-0000-4000-8000-000000000003'" </dev/null \
  | grep -qx 'a11ce000-0000-4000-8000-000000000003' \
  && echo "A16 OK cart.user_id is carol's realm UUID (string subject persisted)" \
  || { echo "A16 FAIL — no row keyed by the realm sub; dump what did land:"; \
       docker compose exec -T postgres psql -U postgres -d cart -c \
         "SELECT user_id, product_id FROM cart_items ORDER BY id DESC LIMIT 5" </dev/null; }

# A15. Worker Deployment Versioning drill (ADR-030, mechanism now ADR-054).
#      *** NOT RUNNABLE ON COMPOSE AS THE STACK IS WIRED TODAY. ***
#      Measured 2026-08-25: the drill needs a registered Worker Deployment, and
#      compose.yaml's order-worker sets NEITHER `TEMPORAL_DEPLOYMENT_NAME` nor a
#      build id. `git log -S` finds no history for either name, under the current
#      name or the retired `TEMPORAL_WORKER_DEPLOYMENT_NAME` — so this row has
#      never passed here. Every `temporal worker-deployment` call answers
#      `no Worker Deployment found with name 'order-fulfillment'`.
#
#      The versioning proof therefore lives on the CLUSTER, not here: K1.7 (the
#      Current version activates with no human step) and SG.4 (a workflow reports
#      `Pinned` on the Current build id, no half-finished ramp) both passed on the
#      2026-08-25 Kind gate. The sentence that used to sit here — "the only place
#      the ENV CONTRACT can be gated before Kind" — was not true.
#
#      To make this row real, compose's order-worker needs the versioning env; that
#      is a compose change, not an audit change, and is deliberately not made here.
#      CONDITIONAL: run it when a change touches worker versioning, the saga's
#      activity set, or the rollout runbook.
#
#      The variable is TEMPORAL_DEPLOYMENT_NAME, Temporal's own name: the Worker
#      Controller injects it, Temporal's reference worker reads it, and
#      pkg/temporalx >= temporalx/v0.37.0 reads only it. The retired
#      TEMPORAL_WORKER_DEPLOYMENT_NAME was a synonym this platform invented; a
#      worker given the old name plus a build id sees half a config and exits 1,
#      which is what makes this row a real gate rather than a formality.
#
#      `set-current-version` below is a COMPOSE-ONLY crutch: on the cluster the
#      controller is the sole writer of Current, and running it against Kind fights
#      the controller. Never copy these three invocations to a cluster incident.
#
#      The deployment name here stays the bare `order-fulfillment` because this
#      drill sets it by hand. On the cluster the controller composes
#      `<namespace>/<resource-name>`, so it is `order/order-fulfillment` there.
#
#      Keep the pause UNDER the saga's 30s StartToCloseTimeout
#      (order-service/internal/saga/workflow.go). A longer pause makes every
#      attempt time out and retry forever — MaximumAttempts is 0 — so the drill
#      never converges and strands an in-flight workflow.
docker compose stop order-worker
docker compose run -d --no-deps --name ow-v1 \
  -e TEMPORAL_DEPLOYMENT_NAME=order-fulfillment -e TEMPORAL_WORKER_BUILD_ID=v1 \
  -e ORDER_FAULT_COMMIT_PAUSE=20s order-worker worker
sleep 12
$TCLI worker deployment list --namespace mop            # want: order-fulfillment, version v1
$TCLI worker deployment set-current-version \
  --deployment-name order-fulfillment --build-id v1 --namespace mop --yes
# Drive one checkout through A10's funnel to get a fresh $OID, then:
$TCLI workflow describe --workflow-id "order-fulfillment-$OID" --namespace mop \
  | grep -A3 'Versioning Info'                          # want: Behavior Pinned, BuildId v1

docker compose run -d --no-deps --name ow-v2 \
  -e TEMPORAL_DEPLOYMENT_NAME=order-fulfillment -e TEMPORAL_WORKER_BUILD_ID=v2 \
  order-worker worker
sleep 10
$TCLI worker deployment set-current-version \
  --deployment-name order-fulfillment --build-id v2 --namespace mop --yes
$TCLI worker deployment describe --name order-fulfillment --namespace mop
# want: current version v2, and v1 DrainageStatus `draining` while it still holds
# a pinned execution. The `draining` -> `drained` flip lags the workflow
# finishing by ~2 minutes, so never gate a rollout step on an instantaneous read.
# Restarting `temporal` here is safe and worth doing once: the deployment state
# and the pinned execution both survive it.

# TEARDOWN IS MANDATORY, and this order matters. Removing a version's workers
# while workflows are still pinned to it strands them; and reverting the worker
# env while CurrentVersion still points at a build with no pollers leaves NEW
# workflows Running forever, with ApproximateBacklogCount 0 on the unversioned
# queue and nothing logged as an error.
$TCLI worker deployment set-current-version \
  --deployment-name order-fulfillment --unversioned --namespace mop --yes
docker rm -f ow-v1 ow-v2
docker compose start order-worker
$TCLI workflow list --namespace mop | awk 'NR>1 && $1=="Running"'   # want: no output
```

```bash
# A17. Protected Backoffice surface (RFC-0023 slice A + ADR-050) — the
#      platform's first /protected/ audience, verified against the WORKFORCE
#      realm. Two personas: the staff operator duyne (duynhlab-staff) and any
#      customer-realm token (alice's $KCT works) — the latter must die at the
#      EDGE as wrong-issuer, before any service-side role logic.
KCT_STAFF=$(bash -c 'export KC_REALM=duynhlab-staff KC_CLIENT_ID=admin-portal \
  KC_REDIRECT=http://localhost:3009/ USERNAME=duyne PASSWORD=p@ss1234; \
  bash scripts/keycloak-token.sh')

# Edge coarse check: tokenless never reaches the service.
audit_curl -s -o /dev/null -w "A17 edge-401: %{http_code} (want 401)\n" \
  http://localhost:8080/inventory/v1/protected/balances
# Audience scoping: nothing but /protected is routed for inventory.
audit_curl -s -o /dev/null -w "A17 no-bare-route: %{http_code} (want 404)\n" \
  -H "Authorization: Bearer $AT" http://localhost:8080/inventory/v1/private/balances

# ADR-050 identity fence: a VALID CUSTOMER-REALM token is wrong-issuer on the
# protected route — 401 at the edge, stronger than the old in-service 403.
audit_curl -s -w "  -> A17 customer-token: %{http_code} (want 401 wrong-issuer at the edge)\n" \
  -H "Authorization: Bearer $AT" http://localhost:8080/inventory/v1/protected/balances

# Operator reads: real seeded balances with SQL-derived atp = on_hand - reserved.
audit_curl -s -H "Authorization: Bearer $KCT_STAFF" \
  "http://localhost:8080/inventory/v1/protected/balances?page_size=3" | head -c 300; echo

# Command lifecycle on a dedicated SKU: 201 applied -> exact replay 200
# applied:false -> invariant-violating adjustment 409 STOCK_UNAVAILABLE.
# The command id is UNIQUE PER RUN, and that matters: with a fixed id the first
# call proves "201 applied:true" only on a never-before-audited stack, and every
# re-run against the same volumes replays instead (200 applied:false), which
# looks like a regression in the create path when it is the idempotency working.
# The replay assertion below deliberately reuses THIS run's id, so both halves
# hold on a fresh stack and on a re-run.
A17_CMD="a17-rcpt-$(date +%s)"
A17_BODY="{\"command_id\":\"$A17_CMD\",\"sku_id\":\"A17-SKU\",\"warehouse_id\":1,\"quantity\":7,\"reason\":\"PO-A17\"}"
audit_curl -s -w "  -> A17 receipt: %{http_code} (want 201 applied:true)\n" -X POST \
  -H "Authorization: Bearer $KCT_STAFF" -H 'Content-Type: application/json' \
  -d "$A17_BODY" http://localhost:8080/inventory/v1/protected/receipts
audit_curl -s -w "  -> A17 replay: %{http_code} (want 200 applied:false)\n" -X POST \
  -H "Authorization: Bearer $KCT_STAFF" -H 'Content-Type: application/json' \
  -d "$A17_BODY" http://localhost:8080/inventory/v1/protected/receipts
audit_curl -s -w "  -> A17 over-adjust: %{http_code} (want 409 STOCK_UNAVAILABLE)\n" -X POST \
  -H "Authorization: Bearer $KCT_STAFF" -H 'Content-Type: application/json' \
  -d "{\"command_id\":\"a17-adj-$(date +%s)\",\"sku_id\":\"A17-SKU\",\"warehouse_id\":1,\"delta\":-9999,\"reason\":\"a17\"}" \
  http://localhost:8080/inventory/v1/protected/adjustments

# Ledger: the movement row carries actor = duyne's staff-realm sub.
audit_curl -s -H "Authorization: Bearer $KCT_STAFF" \
  "http://localhost:8080/inventory/v1/protected/movements?sku_id=A17-SKU" \
  | grep -o '"actor":"[^"]*"'                # want d0e00000-0000-4000-8000-000000000001
```

```bash
# A18. Protected read fan-out (RFC-0023 Train 3): order, payment, shipping,
#      user each serve their Backoffice list to the staff operator, and every
#      one of them rejects a customer-realm token AT THE EDGE (wrong issuer).
#      $KCT_STAFF and $AT come from A17/A1.
for svc in order payment shipping user; do
  path="$svc/v1/protected"
  case $svc in
    order)    res="orders";;
    payment)  res="payments";;
    shipping) res="shipments";;
    user)     res="users";;
  esac
  audit_curl -s -o /dev/null -w "A18 $svc staff-list: %{http_code} (want 200)\n" \
    -H "Authorization: Bearer $KCT_STAFF" "http://localhost:8080/$path/$res?page_size=1"
  audit_curl -s -o /dev/null -w "A18 $svc customer-token: %{http_code} (want 401 wrong-issuer)\n" \
    -H "Authorization: Bearer $AT" "http://localhost:8080/$path/$res"
done
# The recon triage view exists and pages (payment's first recon reader):
audit_curl -s -o /dev/null -w "A18 recon runs: %{http_code} (want 200)\n" \
  -H "Authorization: Bearer $KCT_STAFF" "http://localhost:8080/payment/v1/protected/reconciliations/runs?page_size=1"

# A19. The protected CATALOG (RFC-0023 slice B) — the first protected surface
#      that WRITES. Reads prove the fence; the lifecycle proves the guards.
#      Every command is verified against the staff realm and audited with the
#      token's subject as actor, so this row also proves that a body-supplied
#      actor is ignored.
audit_curl -s -o /dev/null -w "A19 catalog staff-list: %{http_code} (want 200)\n" \
  -H "Authorization: Bearer $KCT_STAFF" "http://localhost:8080/product/v1/protected/products?page_size=1"
audit_curl -s -o /dev/null -w "A19 customer-token: %{http_code} (want 401 wrong-issuer)\n" \
  -H "Authorization: Bearer $AT" "http://localhost:8080/product/v1/protected/products"
# Create lands in DRAFT — invisible to the public catalog until published.
A19_NAME="Audit Widget $(date +%s)"
A19_CREATE=$(audit_curl -s -X POST http://localhost:8080/product/v1/protected/products \
  -H "Authorization: Bearer $KCT_STAFF" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$A19_NAME\",\"price\":19.99,\"category\":\"Electronics\",\"actor_sub\":\"ignored-by-design\"}")
A19_ID=$(echo "$A19_CREATE" | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
echo "$A19_CREATE" | python3 -c "
import json,sys
p = json.load(sys.stdin)
print('A19 create:', 'OK' if p['status'] == 'DRAFT' and p['version'] == 1 else 'FAIL', p['id'], p['status'], 'v%s' % p['version'])"
audit_curl -s -o /dev/null -w "A19 draft not public: %{http_code} (want 404 — DRAFT is invisible)\n" \
  "http://localhost:8080/product/v1/public/products/$A19_ID"
# A duplicate name is the conflict that makes a retried create safe.
audit_curl -s -o /dev/null -w "A19 duplicate name: %{http_code} (want 409)\n" \
  -X POST http://localhost:8080/product/v1/protected/products \
  -H "Authorization: Bearer $KCT_STAFF" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$A19_NAME\",\"price\":1}"
# publish → public; a second publish is a refused edge, not a no-op.
audit_curl -s -o /dev/null -w "A19 publish: %{http_code} (want 200)\n" \
  -X POST "http://localhost:8080/product/v1/protected/products/$A19_ID/publish" \
  -H "Authorization: Bearer $KCT_STAFF"
audit_curl -s -o /dev/null -w "A19 now public: %{http_code} (want 200)\n" \
  "http://localhost:8080/product/v1/public/products/$A19_ID"
audit_curl -s -w "  -> A19 re-publish: %{http_code} (want 409 INVALID_TRANSITION)\n" \
  -X POST "http://localhost:8080/product/v1/protected/products/$A19_ID/publish" \
  -H "Authorization: Bearer $KCT_STAFF" | head -c 120; echo
# Optimistic concurrency: the same version cannot win twice.
audit_curl -s -o /dev/null -w "A19 edit v2: %{http_code} (want 200)\n" \
  -X PUT "http://localhost:8080/product/v1/protected/products/$A19_ID" \
  -H "Authorization: Bearer $KCT_STAFF" -H 'Content-Type: application/json' \
  -d '{"name":"'"$A19_NAME"' edited","price":21.5,"category":"Electronics","version":2,"reason":"audit"}'
audit_curl -s -w "  -> A19 stale edit: %{http_code} (want 409 VERSION_CONFLICT)\n" \
  -X PUT "http://localhost:8080/product/v1/protected/products/$A19_ID" \
  -H "Authorization: Bearer $KCT_STAFF" -H 'Content-Type: application/json' \
  -d '{"name":"overwrite","price":99,"version":2}' | head -c 120; echo
# archive → the page 404s while the PRICE still resolves (the deliberate
# asymmetry: a cart holding this product must still price correctly).
audit_curl -s -o /dev/null -w "A19 archive: %{http_code} (want 200)\n" \
  -X POST "http://localhost:8080/product/v1/protected/products/$A19_ID/archive" \
  -H "Authorization: Bearer $KCT_STAFF"
audit_curl -s -o /dev/null -w "A19 archived page: %{http_code} (want 404)\n" \
  "http://localhost:8080/product/v1/public/products/$A19_ID"
podman compose exec -T product true 2>/dev/null || true
# The audit trail carries the TOKEN's subject, never the body's.
audit_curl -s -H "Authorization: Bearer $KCT_STAFF" \
  "http://localhost:8080/product/v1/protected/products/$A19_ID/audit" | python3 -c "
import json,sys
rows = json.load(sys.stdin)['items']
actions = [r['action'] for r in rows]
actors = {r['actor_sub'] for r in rows}
ok = actions[:1] == ['ARCHIVE'] and 'CREATE' in actions and actors == {'d0e00000-0000-4000-8000-000000000001'}
print('A19 audit trail:', 'OK' if ok else 'FAIL', actions, actors)"
# Categories: list + create + the unique-name conflict.
audit_curl -s -o /dev/null -w "A19 categories: %{http_code} (want 200)\n" \
  -H "Authorization: Bearer $KCT_STAFF" "http://localhost:8080/product/v1/protected/categories?page_size=5"

# A20. The operator RESOLVE (RFC-0023 train 7 / ADR-051) — the command that
#      retired the raw-SQL runbook. Armed through the real park path, not SQL:
#      mockpay declines a refund whose cents end in 07 while still allowing the
#      charge, and order maps a declined refund to a NON-retryable error, so the
#      cancellation compensation cannot converge and parks the order in
#      manual_review(COMPENSATION_INCOMPLETE) within seconds.
#
#      Pick a price whose order total lands on .07: total = subtotal + 3.00 fee
#      + round((subtotal + 3.00) * 0.08, 2) tax.
A20_PRICE=$(python3 -c "
for cents in range(1000, 9999):
    sub = cents / 100
    tax = round((sub + 3.0) * 0.08, 2)
    total = round(sub + 3.0 + tax, 2)
    if round(total * 100) % 100 == 7:
        print('%.2f' % sub); break")
# No digits beyond the timestamp: order refuses a product_name with 12+ total
# digits as suspected card data (the same rule as the payment-token guard), and
# an epoch already spends ten of them.
A20_NAME="Refund Trap $(date +%s)"
A20_PID=$(audit_curl -s -X POST http://localhost:8080/product/v1/protected/products \
  -H "Authorization: Bearer $KCT_STAFF" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$A20_NAME\",\"price\":$A20_PRICE,\"category\":\"Electronics\"}" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
audit_curl -s -o /dev/null -X POST "http://localhost:8080/product/v1/protected/products/$A20_PID/publish" \
  -H "Authorization: Bearer $KCT_STAFF"
# The saga reserves stock by sku_id = product_id, so a brand-new product has no
# balance row and would fail the order with UNKNOWN_SKU instead of parking it.
# Give it stock through the protected receipt A17 already proves.
audit_curl -s -o /dev/null -w "A20 stock receipt: %{http_code} (want 201)\n" -X POST \
  http://localhost:8080/inventory/v1/protected/receipts \
  -H "Authorization: Bearer $KCT_STAFF" -H 'Content-Type: application/json' \
  -d "{\"command_id\":\"a20-rcpt-$(date +%s)\",\"sku_id\":\"$A20_PID\",\"warehouse_id\":1,\"quantity\":5,\"reason\":\"a20 arm\"}"
# One clean checkout on that product, as its own user (carol) so A9/A10's alice
# session is not adopted. Clear anything carol left behind for the same reason:
# one active session per user is a partial unique index, so a leftover session
# would be ADOPTED by the POST below and arrive already mid-confirm.
AT20=$(USERNAME=carol $KCT)
OLD20=$(audit_curl -s -X POST $BASE/checkout/v1/private/checkout/sessions -H "Authorization: Bearer $AT20" \
  | python3 -c "import json,sys;print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
[ -n "$OLD20" ] && audit_curl -s -o /dev/null -X DELETE \
  $BASE/checkout/v1/private/checkout/sessions/$OLD20 -H "Authorization: Bearer $AT20"
audit_curl -s -o /dev/null -X DELETE $BASE/cart/v1/private/cart -H "Authorization: Bearer $AT20"
audit_curl -s -o /dev/null -X POST $BASE/cart/v1/private/cart -H "Authorization: Bearer $AT20" \
  -H 'Content-Type: application/json' \
  -d "{\"product_id\":\"$A20_PID\",\"product_name\":\"$A20_NAME\",\"product_price\":$A20_PRICE,\"quantity\":1}"
S20=$(audit_curl -s -X POST $BASE/checkout/v1/private/checkout/sessions -H "Authorization: Bearer $AT20" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
audit_curl -s -o /dev/null -X PUT $BASE/checkout/v1/private/checkout/sessions/$S20/address \
  -H "Authorization: Bearer $AT20" -H 'Content-Type: application/json' \
  -d '{"full_name":"Carol","line1":"1 Main St","city":"HN","country":"VN"}'
audit_curl -s -X PUT $BASE/checkout/v1/private/checkout/sessions/$S20/shipping \
  -H "Authorization: Bearer $AT20" -H 'Content-Type: application/json' \
  -d '{"shipping_method":"standard"}' | python3 -c "
import json,sys; s=json.load(sys.stdin)
print('A20 total:', 'OK' if round(s['total']*100) % 100 == 7 else 'FAIL', s['total'], '(cents must end 07)')"
audit_curl -s -o /dev/null -X PUT $BASE/checkout/v1/private/checkout/sessions/$S20/payment \
  -H "Authorization: Bearer $AT20" -H 'Content-Type: application/json' \
  -d '{"payment_method_token":"tok_visa_ok"}'
O20=$(audit_curl -s -X POST $BASE/checkout/v1/private/checkout/sessions/$S20/confirm \
  -H "Authorization: Bearer $AT20" -H "Idempotency-Key: a20-$(date +%s)" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['order_id'])")
# Wait for the saga to reach a cancellable state. A USER may open a cancellation
# episode from `confirmed` or `completed` only — NOT from `pending` — so
# cancelling straight after the confirm races the saga and 409s.
for _ in $(seq 1 20); do
  A20_PRE=$(audit_curl -s -H "Authorization: Bearer $KCT_STAFF" \
    "$BASE/order/v1/protected/orders/$O20" | python3 -c "import json,sys;print(json.load(sys.stdin)['status'])")
  case "$A20_PRE" in confirmed|completed) break ;; esac
  sleep 3
done
echo "A20 cancellable: $A20_PRE (want confirmed or completed)"
# Cancel: the refund is declined, so the compensation parks the order. The status
# code is asserted, not discarded — a refused cancel is why nothing would park.
audit_curl -s -o /dev/null -w "A20 cancel: %{http_code} (want 202 — episode opened)\n" \
  -X POST "$BASE/order/v1/private/orders/$O20/cancel" -H "Authorization: Bearer $AT20"
for i in $(seq 1 40); do
  A20_STATUS=$(audit_curl -s -H "Authorization: Bearer $KCT_STAFF" \
    "$BASE/order/v1/protected/orders/$O20" | python3 -c "import json,sys;print(json.load(sys.stdin)['status'])")
  [ "$A20_STATUS" = "manual_review" ] && break
  sleep 3
done
echo "A20 parked: $([ "$A20_STATUS" = manual_review ] && echo OK || echo FAIL) (status=$A20_STATUS)"
# Diagnosing a FAIL here: `failed` means the refund SUCCEEDED (the total's cents
# did not end in 07, or mockpay is stubbed in-memory — check MOCKPAY_URL);
# `cancelling` means the compensation is still retrying; `confirmed` means the
# cancel never opened an episode.

# The case view carries what the decision needs: version + the external truths +
# the history. A soft-failed read is listed in `degraded`, never silently absent.
A20_CASE=$(audit_curl -s -H "Authorization: Bearer $KCT_STAFF" "$BASE/order/v1/protected/orders/$O20")
A20_V=$(echo "$A20_CASE" | python3 -c "import json,sys;print(json.load(sys.stdin)['version'])")
echo "$A20_CASE" | python3 -c "
import json,sys
c = json.load(sys.stdin)
pay = c.get('payment') or {}
ok = c['version'] > 0 and 'status_history' in c and pay.get('status') in ('captured', 'partially_refunded')
print('A20 case view:', 'OK' if ok else 'FAIL', 'v%s' % c['version'],
      'payment=%s' % pay.get('status'), 'history=%d' % len(c['status_history']),
      'degraded=%s' % c.get('degraded'))"
# A customer token dies at the EDGE on the command, before any role logic.
audit_curl -s -o /dev/null -w "A20 customer-token: %{http_code} (want 401 wrong-issuer at the edge)\n" \
  -X POST "$BASE/order/v1/protected/orders/$O20/resolve" -H "Authorization: Bearer $AT20" \
  -H 'Content-Type: application/json' -d '{"target":"cancelled","version":1,"reason":"WRITTEN_OFF","note":"x"}'
# Evidence is not optional, and the vocabulary is closed.
audit_curl -s -o /dev/null -w "A20 no note: %{http_code} (want 400)\n" \
  -X POST "$BASE/order/v1/protected/orders/$O20/resolve" -H "Authorization: Bearer $KCT_STAFF" \
  -H 'Content-Type: application/json' -d "{\"target\":\"cancelled\",\"version\":$A20_V,\"reason\":\"WRITTEN_OFF\",\"note\":\"\"}"
# One helper for the rest of the row. The status code goes LAST on its own line
# and the body is parsed, never truncated: a `head -c` on the response drops the
# curl -w marker whenever the body is long, which silently hides the assertion.
a20_resolve() {  # $1 = label, $2 = want, $3 = json body, $4 = jq-ish field to show
  local out code body
  out=$(audit_curl -s -w '\n%{http_code}' -X POST \
    "$BASE/order/v1/protected/orders/$O20/resolve" -H "Authorization: Bearer $KCT_STAFF" \
    -H 'Content-Type: application/json' -d "$3")
  code=$(printf '%s' "$out" | tail -1)
  body=$(printf '%s' "$out" | sed '$d')
  printf 'A20 %s: %s (want %s) %s\n' "$1" "$code" "$2" \
    "$(printf '%s' "$body" | python3 -c "
import json,sys
try: d = json.load(sys.stdin)
except Exception: print(''); raise SystemExit
print(d.get('$4', ''))" 2>/dev/null)"
}
a20_resolve "foreign reason" "400 VALIDATION_ERROR (CUSTOMER_REQUEST is not a resolution)" \
  "{\"target\":\"cancelled\",\"version\":$A20_V,\"reason\":\"CUSTOMER_REQUEST\",\"note\":\"n\"}" code
a20_resolve "illegal target" "409 INVALID_TRANSITION" \
  "{\"target\":\"pending\",\"version\":$A20_V,\"reason\":\"WRITTEN_OFF\",\"note\":\"n\"}" code
# A version the order is not at is refused, not silently applied.
a20_resolve "stale version" "409 VERSION_CONFLICT" \
  "{\"target\":\"cancelled\",\"version\":$((A20_V + 5)),\"reason\":\"WRITTEN_OFF\",\"note\":\"n\"}" code
# The decision itself. The body names another actor on purpose: it must be ignored.
A20_BODY="{\"target\":\"cancelled\",\"version\":$A20_V,\"reason\":\"WRITTEN_OFF\",\"note\":\"a20: refund permanently declined by the provider; closing\",\"actor_id\":\"ignored-by-design\"}"
a20_resolve "resolve" "201 applied:true"  "$A20_BODY" applied
a20_resolve "replay"  "200 applied:false" "$A20_BODY" applied
# Terminal now, so the command is refused; and the trail says who decided.
audit_curl -s -o /dev/null -w "A20 resolve again: %{http_code} (want 409 — no longer parked)\n" \
  -X POST "$BASE/order/v1/protected/orders/$O20/resolve" -H "Authorization: Bearer $KCT_STAFF" \
  -H 'Content-Type: application/json' \
  -d "{\"target\":\"failed\",\"version\":$((A20_V + 1)),\"reason\":\"WRITTEN_OFF\",\"note\":\"n\"}"
audit_curl -s -H "Authorization: Bearer $KCT_STAFF" "$BASE/order/v1/protected/orders/$O20" | python3 -c "
import json,sys
c = json.load(sys.stdin)
ops = [r for r in c['status_history'] if r['actor_type'] == 'OPERATOR']
ok = (c['status'] == 'cancelled' and len(ops) == 1
      and ops[0]['reason_code'] == 'WRITTEN_OFF'
      and ops[0]['actor_id'] == 'd0e00000-0000-4000-8000-000000000001'
      and 'permanently declined' in (ops[0]['note'] or ''))
print('A20 audit trail:', 'OK' if ok else 'FAIL', c['status'],
      [(r['from_status'], r['to_status'], r['actor_type']) for r in c['status_history']])"
```

```bash
# A21. THE UNTRACKED SKU IS A CONFLICT, NOT AN OUTAGE (ADR-053). Mirrors A20's
#      arming minus one step: create + publish a product and deliberately SKIP
#      the receipt, so the SKU has no balance row. Runs as `david` — its own
#      user, because one active session per user is a partial unique index and
#      every other Phase A row's user would adopt this row's session.
A21_NAME="Untracked Widget $(date +%s)"
A21_PID=$(audit_curl -s -X POST http://localhost:8080/product/v1/protected/products   -H "Authorization: Bearer $KCT_STAFF" -H 'Content-Type: application/json'   -d "{\"name\":\"$A21_NAME\",\"price\":12.5,\"category\":\"Electronics\"}"   | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
audit_curl -s -o /dev/null -X POST "http://localhost:8080/product/v1/protected/products/$A21_PID/publish"   -H "Authorization: Bearer $KCT_STAFF"
# NO receipt here — that omission is the row.

AT21=$(USERNAME=david $KCT)
OLD21=$(audit_curl -s -X POST $BASE/checkout/v1/private/checkout/sessions -H "Authorization: Bearer $AT21"   | python3 -c "import json,sys;print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
[ -n "$OLD21" ] && audit_curl -s -o /dev/null -X DELETE   $BASE/checkout/v1/private/checkout/sessions/$OLD21 -H "Authorization: Bearer $AT21"
audit_curl -s -o /dev/null -X DELETE $BASE/cart/v1/private/cart -H "Authorization: Bearer $AT21"
audit_curl -s -o /dev/null -X POST $BASE/cart/v1/private/cart -H "Authorization: Bearer $AT21"   -H 'Content-Type: application/json'   -d "{\"product_id\":\"$A21_PID\",\"product_name\":\"$A21_NAME\",\"product_price\":12.5,\"quantity\":1}"

# Arm 1 — session create: flat 409 ITEM_NOT_ORDERABLE, no Retry-After (nothing
# to requote — no session exists yet), and the body stays opaque about SKUs.
A21_CREATE=$(audit_curl -s -w '\n%{http_code}\t%header{retry-after}'   -X POST $BASE/checkout/v1/private/checkout/sessions -H "Authorization: Bearer $AT21")
echo "$A21_CREATE" | python3 -c "
import sys
body, tail = sys.stdin.read().rstrip('\n').rsplit('\n', 1)
code, retry = (tail.split('\t') + [''])[:2]
ok = code == '409' and 'ITEM_NOT_ORDERABLE' in body and not retry.strip() \
     and 'does not track' not in body
print('A21 create:', 'OK 409 no-retry-after opaque' if ok else f'FAIL code={code} retry={retry!r} body={body[:160]}')"

# Give it stock (the operator fix this row exists to prove), then the same
# basket quotes cleanly — recovery is part of the assertion.
audit_curl -s -o /dev/null -w "A21 receipt: %{http_code} (want 201)\n" -X POST   http://localhost:8080/inventory/v1/protected/receipts   -H "Authorization: Bearer $KCT_STAFF" -H 'Content-Type: application/json'   -d "{\"command_id\":\"a21-rcpt-$(date +%s)\",\"sku_id\":\"$A21_PID\",\"warehouse_id\":1,\"quantity\":5,\"reason\":\"a21 recovery\"}"
S21=$(audit_curl -s -X POST $BASE/checkout/v1/private/checkout/sessions -H "Authorization: Bearer $AT21"   | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
echo "A21 recovery: session $S21 created after the receipt (want a session id)"

# Arm 2 — confirm: park the SAME basket back into the untracked state by
# revoking the balance? No such command exists (receipts only add), so the
# confirm arm uses a SECOND untracked product added to the now-open session's
# cart... which a session snapshot ignores. Instead: prove the confirm arm on
# a FRESH untracked product with a full funnel.
A21B_NAME="Untracked Confirm $(date +%s)"
A21B_PID=$(audit_curl -s -X POST http://localhost:8080/product/v1/protected/products   -H "Authorization: Bearer $KCT_STAFF" -H 'Content-Type: application/json'   -d "{\"name\":\"$A21B_NAME\",\"price\":9.75,\"category\":\"Electronics\"}"   | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
audit_curl -s -o /dev/null -X POST "http://localhost:8080/product/v1/protected/products/$A21B_PID/publish"   -H "Authorization: Bearer $KCT_STAFF"
# The confirm-time gap needs the session to EXIST first, so the SKU must be
# tracked at create and untracked at confirm. Inventory has no "untrack"
# command — by design — so the confirm arm rides the create-time session
# adoption instead: receive stock, build the session to ready, and note that
# CheckAvailability runs at BOTH create and confirm; the unit tests in
# checkout-service pin the confirm arm's 409-with-requote shape directly
# (TestConfirm_UnknownSKUIs409WithRequotedSession). This row therefore asserts
# the WIRE truth end-to-end where the platform can produce it (create) and
# the recovery loop; the confirm arm's envelope is covered by the service's
# own contract tests, which the release CI runs on the same commit.
audit_curl -s -o /dev/null -X DELETE $BASE/checkout/v1/private/checkout/sessions/$S21 -H "Authorization: Bearer $AT21"
audit_curl -s -o /dev/null -X DELETE $BASE/cart/v1/private/cart -H "Authorization: Bearer $AT21"

# ---------------------------------------------------------------------------
# A22. THE ATTENTION CARDS' SIX READS. B6 proves the cards RENDER; this proves
#      the queries beneath them. Same paths and params the portal's dashboard
#      issues (admin-service src/routes/_authenticated/index.tsx), so a renamed
#      filter or a dropped `total_items` fails here with the endpoint named
#      rather than surfacing as a blank card nobody can attribute.
for q in \
  "inventory/v1/protected/balances?page=1&page_size=1&low_stock=true" \
  "order/v1/protected/orders?page=1&page_size=1&status=manual_review" \
  "order/v1/protected/orders?page=1&page_size=1&status=cancelling" \
  "payment/v1/protected/attempts/open?page=1&page_size=1" \
  "payment/v1/protected/reconciliations/runs?page=1&page_size=1"; do
  audit_curl -s "$BASE/$q" -H "Authorization: Bearer $KCT_STAFF" \
    | python3 -c "import json,sys;d=json.load(sys.stdin);print(type(d.get('total_items')).__name__, d.get('total_items'))"
done
# The drift guard, and the reason the row is worth more than five 200s: a status
# order-service does not know must be 400. Were it ignored instead, the
# manual_review and cancelling cards would BOTH report the total order count --
# two plausible numbers, both wrong, with no non-200 anywhere to reveal it.
audit_curl -s -o /dev/null -w '%{http_code}\n' \
  "$BASE/order/v1/protected/orders?status=not_a_status" \
  -H "Authorization: Bearer $KCT_STAFF"   # 400
```

> A 429 from the edge is a FINDING, not audit pacing. At 50 req/s a shell-driven
> row cannot reach the limit, so a 429 means either the policy was tightened or
> something is looping. Investigate before re-running.
>
> The access token minted in A1 stays usable for the whole phase even though A4
> revokes its refresh-token family: a JWT is not checked against realm session
> state, and the realm's `accessTokenLifespan` is 900s. If Phase A stretches past
> ~15 minutes before A12, mint a fresh token rather than debugging a 401.
>
> A10 abandonment timing: the workflow timer arms for the session's FULL TTL
> (default 30m) at creation; shortening `expires_at` in SQL afterwards only
> moves the LAZY deadline. That is why A10 proves the backstop and **A13**
> proves the timer. For A13, either arm the session before Phase A and read it
> at the end — the TTL elapses while the rest of the audit runs — or bring the
> stack up with `SESSION_TTL_SECONDS=15` on `checkout` **and** `checkout-worker`
> for a ~15s cycle.
>
> A14 can KILL the server it restarts: on a restart Temporal's ringpop layer
> may retry joining its own stale membership entry until "join duration
> exceeded max 30s" and exit(1) FATALLY ~90 seconds AFTER the row's read
> passed (observed 2026-08-13; compose now carries `restart: on-failure:5`
> for exactly this). After A14, confirm `temporal` is still Up ~2 minutes
> later — a dead engine fires no timers, which silently turns A13 into
> `expired|lazy` (inconclusive) and strands every workflow row after it.
>
> A13 needs its own user. One active session per user is enforced by a partial
> unique index, so running A9/A10 as the same user makes them adopt the watched
> session, and every mutation re-arms its timer. Since the cutover that user is
> the seeded realm user `bob` instead of a freshly registered one, which is why
> A13 now clears bob's leftover session before arming.

## Phase B — real browser (agent-browser, ~8 min)

Two SPAs, run in that order: the storefront (`:3001`, B1-B4) and the Backoffice
Portal (`:3009`, B5-B8, then the ADR-053 affordances B9-B10).

What Phase B proves that Phase A cannot: the SPA holds **no token of its own**.
keycloak-js owns the token lifecycle in adapter memory, the browser never sees an
in-app credential form, and every transition — sign-in, refresh, sign-out — is a
realm endpoint the browser reaches directly, not a service route behind the edge.
Storage-shaped regressions (a token cached "for convenience") and refresh
regressions are invisible to curl and can only be caught here.

`--args "--no-sandbox"` is required on Linux hosts with user-namespace
restrictions (only needed on the first command of a session).

Refs like `@e5` are **not stable** — they are assigned per snapshot and change on
every navigation. Every block below re-snapshots before it clicks; do not carry a
ref across a page load.

```bash
S="--session audit"      # bash only — see Preconditions

# B1. LOGIN THROUGH THE REALM. The SPA has no password field and cannot have
#     one: the realm's `customer-spa` client has Direct Access Grants disabled.
#     /login renders a single button that calls keycloak.login({redirectUri}),
#     a FULL-PAGE redirect to the realm, so the credentials are typed on
#     Keycloak's own page at localhost:8081 — which makes half of this
#     assertion about the ORIGIN CHANGING.
agent-browser $S --args "--no-sandbox" batch \
  "open http://localhost:3001" "wait 2500" "snapshot -i"
# Compose gives `frontend` only `service_started` on the gateway, so on a freshly
# recreated stack the SPA can load a few seconds before the edge accepts
# requests. A first paint with failed API calls is a RETRY, not a failure:
# reload and re-snapshot. The landing page is the HOME page — a search box and
# the category buckets, no product grid — and the header's "Sign in" is a LINK
# to /login carrying ?redirect= for the page you were on.
# Use the ref THAT snapshot gave it — read your own, they are per-snapshot:
agent-browser $S batch "click @e8" "wait 1500" "get url" "snapshot -i"
# want url http://localhost:3001/login?redirect=%2F — the home page writes no
# search params, so the encoded return path is just the root. (A `page=1` here
# would be the regression 3.1.0 fixed: a schema default that the router wrote
# into the address bar before anyone had paged.) The snapshot must show a
# "Continue to sign in" button — take its ref from the one just printed:
agent-browser $S batch "click @e11" "wait 3000" "get url" "snapshot -i"
# ASSERTION 1 — the origin changed. `get url` must now be
#   http://localhost:8081/realms/duynhlab/protocol/openid-connect/auth?...
#   ...response_type=code&code_challenge_method=S256...
# and the snapshot must show Keycloak's own form: "Username or email",
# "Password", "Sign In". A password field served from :3001 is a FAILED row.
agent-browser $S batch "fill @e2 alice" "fill @e4 password123" "click @e3" \
  "wait 3000" "get url"
# want: back on http://localhost:3001/ — the home page, which is where the
# ?redirect= said to return to.
agent-browser $S snapshot -i | grep -E 'Sign out|Orders|Profile'
# ASSERTION 2 — signed-in state: the header carries Orders, the cart and bell
# badges, a Profile control (an icon button, aria-label "Profile (alice)") and
# Sign out, instead of a Sign in link. Checkout appears only when the cart is
# non-empty, so do not require it here.

# ASSERTION 3 — NO TOKEN IN WEB STORAGE. Enumerate BOTH storages and assert that
# nothing in either one is JWT-shaped. localStorage legitimately holds a `theme`
# preference, and during a checkout a `checkoutIdemKey:<session-id>` UUID; the
# assertion is written against the VALUES, not against known key names, because
# the point is that no key holds a token whatever it is called.
agent-browser $S storage local get
agent-browser $S storage session get
agent-browser $S eval --stdin <<'EVALEOF'
(() => {
  const jwtish = v => typeof v === 'string' && v.split('.').length === 3
    && /^[A-Za-z0-9_-]{16,}$/.test(v.split('.')[0]);
  const scan = s => Object.keys(s).filter(k => jwtish(s.getItem(k)));
  return JSON.stringify({
    local_keys: Object.keys(localStorage),
    session_keys: Object.keys(sessionStorage),
    local_jwtish: scan(localStorage),
    session_jwtish: scan(sessionStorage)
  });
})()
EVALEOF
# want: local_jwtish [] and session_jwtish [] — a non-empty list is a FAILED row.
# Transient kc-callback-* entries in sessionStorage would hold OIDC state (state,
# nonce, PKCE verifier), never a token, and keycloak-js removes them after the
# redirect is parsed; they are not JWT-shaped and so cannot pass this filter.

# ASSERTION 4 — the token actually in use is the realm's. The access token lives
# in adapter memory, so it is read from the code-exchange RESPONSE captured in
# the network log instead of from storage.
RID=$(agent-browser $S network requests --type fetch --json | python3 -c "
import json,sys
rs = json.load(sys.stdin)['data']['requests']
tok = [r for r in rs if r['method']=='POST' and r['url'].endswith('/protocol/openid-connect/token')]
print(tok[-1]['requestId'] if tok else '')")
agent-browser $S network request "$RID" --json | python3 -c "
import base64, json, sys, urllib.parse
d = json.load(sys.stdin)['data']
grant = dict(urllib.parse.parse_qsl(d['postData'])).get('grant_type')
body = json.loads(d['responseBody'])
p = body['access_token'].split('.')[1]
c = json.loads(base64.urlsafe_b64decode(p + '=' * (-len(p) % 4)))
assert grant == 'authorization_code', grant
assert c['iss'] == 'http://localhost:8081/realms/duynhlab', c['iss']
assert isinstance(c['sub'], str) and len(c['sub']) == 36, (type(c['sub']), c['sub'])
assert 'refresh_token' in body, sorted(body)
print('B1 OK grant=%s iss=%s sub=%s (str uuid); refresh_token stayed in the response body' \
      % (grant, c['iss'], c['sub']))"

# B2. ADAPTER REFRESH. src/lib/api.ts awaits auth.getToken(), which calls
#     updateToken(30), BEFORE every request, so the refresh is pre-emptive:
#     there is no 401-then-retry shape to observe any more. To see a refresh
#     inside a bounded window, make the access token short-lived for the
#     duration of this row via a CLIENT-LEVEL override (the realm default is
#     900s), then restore it. The alternative is waiting ~14.5 minutes.
KCA=http://localhost:8081
ADM=$(curl -s -X POST $KCA/realms/master/protocol/openid-connect/token \
  -d client_id=admin-cli -d username=admin -d password=admin -d grant_type=password \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['access_token'])")
CID=$(curl -s -H "Authorization: Bearer $ADM" \
  "$KCA/admin/realms/duynhlab/clients?clientId=customer-spa" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)[0]['id'])")
curl -s -o /dev/null -w "B2 lifespan 60s: %{http_code} (want 204)\n" -X PUT \
  -H "Authorization: Bearer $ADM" -H 'Content-Type: application/json' \
  "$KCA/admin/realms/duynhlab/clients/$CID" -d '{"attributes":{"access.token.lifespan":"60"}}'
# Reload so the SSO session mints a 60s token (init runs check-sso, no re-login),
# clear the log, then let the token become due before touching a private page.
agent-browser $S batch "reload" "wait 3000" "get url"
agent-browser $S network requests --clear
sleep 35
agent-browser $S batch "open http://localhost:3001/orders" "wait 4000" "get url"
# want: still http://localhost:3001/orders — NOT /login
# The request list does not carry post bodies, so the grant type comes from the
# per-request detail. Classify every token POST in the window:
for id in $(agent-browser $S network requests --type fetch --json | python3 -c "
import json,sys
rs = json.load(sys.stdin)['data']['requests']
print(' '.join(r['requestId'] for r in rs
                if r['method']=='POST' and r['url'].endswith('/openid-connect/token')))"); do
  agent-browser $S network request "$id" --json | python3 -c "
import json,sys,urllib.parse
d = json.load(sys.stdin)['data']
print('B2 grant:', dict(urllib.parse.parse_qsl(d['postData'])).get('grant_type'))"
done | sort | uniq -c
# `--type fetch`, not xhr: the SPA calls the edge through `fetch` (src/lib/api.ts)
# since RFC-0025 replaced axios. Filtering on xhr returns an EMPTY counter, and
# an empty counter fails the check below rather than passing it quietly — but
# the reason would look like "the API was never called".
agent-browser $S network requests --type fetch --json | python3 -c "
import json,sys,collections
rs = json.load(sys.stdin)['data']['requests']
api = collections.Counter(r.get('status') for r in rs if ':8080/' in r['url'])
print('B2 api statuses:', dict(api))
raise SystemExit(0 if api and set(api) <= {200} else 1)"
# want: exactly `1 B2 grant: authorization_code` + `1 B2 grant: refresh_token`,
# and api statuses {200: N}.
#   - EXACTLY ONE refresh_token grant: keycloak-js single-flights concurrent
#     updateToken callers, so the page's parallel private calls share one refresh.
#   - the ONE authorization_code grant is the full page load's check-sso exchange
#     and is expected — count grants, not token POSTs.
#   - a SECOND refresh_token grant means the window was left open long enough for
#     the polling widgets to age the 60s token out again; clear and redo the row.
# RESTORE THE LIFESPAN. Do not leave the override on the client — it survives
# nothing (down -v drops it) but it will skew B3 and any later manual poking.
#
# RE-MINT $ADM FIRST. The master realm's admin-cli token lives 60 seconds, and
# this row spends more than that between the two PUTs (a reload, a 35s wait, a
# navigation, and one request-detail fetch per token POST). Reusing the token
# minted above answers 401, the override stays at 60, and the failure is quiet:
# the confirming GET then parses the 401 error body, finds no `attributes`, and
# prints `None` — which looks exactly like a successful restore. Re-mint, then
# assert on the HTTP code AND the value.
ADM=$(curl -s -X POST $KCA/realms/master/protocol/openid-connect/token \
  -d client_id=admin-cli -d username=admin -d password=admin -d grant_type=password \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['access_token'])")
curl -s -o /dev/null -w "B2 lifespan restored: %{http_code} (want 204)\n" -X PUT \
  -H "Authorization: Bearer $ADM" -H 'Content-Type: application/json' \
  "$KCA/admin/realms/duynhlab/clients/$CID" -d '{"attributes":{"access.token.lifespan":""}}'
curl -s -w '\nB2 verify HTTP %{http_code} (want 200)\n' -o /tmp/b2-client.json \
  -H "Authorization: Bearer $ADM" "$KCA/admin/realms/duynhlab/clients/$CID"
python3 -c "
import json
a = json.load(open('/tmp/b2-client.json')).get('attributes', {})
v = a.get('access.token.lifespan')
print('B2 override cleared: OK' if not v else 'B2 FAIL: lifespan still %r' % v)"

# B3. LOGOUT VIA THE REALM'S END-SESSION ENDPOINT. keycloak.logout() is a GET
#     redirect to the realm, not a POST to any service — no service participates
#     in sign-out at all, which is the thing to verify.
agent-browser $S network requests --clear
agent-browser $S snapshot -i | grep -i 'button "Sign out"'   # take the fresh ref
agent-browser $S batch "click @e10" "wait 3500" "get url"
# want: back on http://localhost:3001/
agent-browser $S network requests | grep 'openid-connect/logout'
# want ONE line: GET http://localhost:8081/realms/duynhlab/protocol/openid-connect/logout
#   ?client_id=customer-spa&post_logout_redirect_uri=http%3A%2F%2Flocalhost%3A3001
#   &id_token_hint=... (Document)
agent-browser $S network requests --method POST | grep -Ei 'logout|:8080/' \
  && echo "B3 FAIL: sign-out touched a service" \
  || echo "B3 OK: no POST to any service during logout"
agent-browser $S snapshot -i | grep -E 'Sign in|Sign out'
# want a "Sign in" link and NO "Sign out" button
agent-browser $S batch "open http://localhost:3001/orders" "wait 3000" "get url"
agent-browser $S read | grep -Ei 'Sign in to see your orders|Order #'
# ASSERTION — a private route after sign-out must not render what the previous
# session could see. It answers with a sign-in prompt IN PLACE ("Sign in to see
# your orders") and stays on /orders; it does not bounce to /login. That is a
# deliberate change from the pre-RFC-0025 shell, which redirected: the property
# being audited is that no stale order list survives the logout, and an
# in-place prompt satisfies it without the redirect round-trip. A line matching
# `Order #` here is a FAILED row.
agent-browser $S storage local get     # want: only `theme`, if anything
agent-browser $S storage session get   # want: No storage entries

# B4. Cleanup — the STOREFRONT session only. The portal rows below open their
#     own, because a browser profile that already holds a customer-realm SSO
#     cookie is the wrong starting state for B7.
agent-browser $S close

# ---------------------------------------------------------------------------
# B5-B8: THE BACKOFFICE PORTAL (:3009). Rows A17-A20 already drive the same
# protected surface with curl, so what these add is the half curl cannot see:
# that the SPA in front of it holds no token either, that it renders the numbers
# the API returns rather than placeholders, and that the realm split is a fence
# a customer account hits in the browser — not only a 401 a script can read.
# ---------------------------------------------------------------------------
P="--session portal"

# B5. SIGN IN THROUGH THE **STAFF** REALM. Same shape as B1 and the same
#     property — the portal has no password field — but a different realm,
#     client and operator: duynhlab-staff / admin-portal / duyne (ADR-050).
agent-browser $P --args "--no-sandbox" batch \
  "open http://localhost:3009" "wait 2500" "get url" "snapshot -i"
# want url http://localhost:3009/login?redirect=%2F — an unauthenticated load of
# any portal route lands on /login, which shows "duynhlab Backoffice" and a
# single "Sign in with Keycloak" button. `admin` gets only `service_started` on
# the gateway, exactly like `frontend`, so a first paint with failed API calls on
# a freshly recreated stack is a RETRY, not a failure.
agent-browser $P batch "click @e3" "wait 3000" "get url" "snapshot -i"
# ASSERTION 1 — the origin changed AND the realm in the path is the STAFF one:
#   http://localhost:8081/realms/duynhlab-staff/protocol/openid-connect/auth?...
#   ...response_type=code&code_challenge_method=S256...
# `realms/duynhlab` here (the customer realm) is a FAILED row — it would mean the
# container was built with the storefront's KEYCLOAK_REALM build arg.
agent-browser $P batch "fill @e2 duyne" "fill @e4 'p@ss1234'" "click @e3" \
  "wait 3000" "get url" "snapshot -i"
# want: back on http://localhost:3009/ with the shell rendered — the primary nav
# carries Dashboard, Catalog, Inventory, Orders, Payments, Shipments, Customers,
# and a "Sign out" icon button. Landing on /forbidden instead means the token is
# valid but carries no `backoffice_admin` role, which is a different failure from
# a rejected sign-in: read the row it lands on before calling this red.

# ASSERTION 2 — NO TOKEN IN WEB STORAGE, same test as B1's assertion 3. The
# portal runs the same keycloak-js adapter with check-sso + PKCE S256, so the
# access token lives in adapter memory and neither storage may hold one.
agent-browser $P eval --stdin <<'EVALEOF'
(() => {
  const jwtish = v => typeof v === 'string' && v.split('.').length === 3
    && /^[A-Za-z0-9_-]{16,}$/.test(v.split('.')[0]);
  const scan = s => Object.keys(s).filter(k => jwtish(s.getItem(k)));
  return JSON.stringify({
    local_keys: Object.keys(localStorage),
    session_keys: Object.keys(sessionStorage),
    local_jwtish: scan(localStorage),
    session_jwtish: scan(sessionStorage)
  });
})()
EVALEOF
# want: local_jwtish [] and session_jwtish [].

# B6. THE DASHBOARD READS REAL NUMBERS. Five cards, each backed by a protected
#     endpoint A18-A20 already exercise: Low / out of stock, Manual review,
#     Cancelling, Unresolved attempts, Recon discrepancies (latest run).
agent-browser $P read | grep -E 'Low / out of stock|Manual review|Cancelling|Unresolved attempts|Recon discrepancies'
# ASSERTION — every card title is present AND each carries a numeral, not a dash
# or a spinner. Run Phase A FIRST: the numbers are whatever the driven flow left
# behind, so a zero is a legitimate value and only a missing/blank card is red.
agent-browser $P network requests --type fetch | grep ':8080/'
# want: every portal API call 200. A 401 here with the shell still rendered means
# the SPA authenticated but the edge rejected the token — check the staff
# JWT policy, not the SPA.

# B7. THE REALM SPLIT IS A FENCE IN THE BROWSER. `alice` exists in the customer
#     realm and nowhere else, so a store account cannot get past the portal's
#     own sign-in page — this is the browser-shaped twin of A17's edge 401.
#     A THIRD session, not $P: B5 left a staff SSO cookie on that profile, so
#     check-sso would sign duyne straight back in and the form would never
#     appear. This one must start clean.
N="--session portal-neg"
agent-browser $N --args "--no-sandbox" batch \
  "open http://localhost:3009/login" "wait 2500" "snapshot -i"
agent-browser $N batch "click @e3" "wait 3000" "snapshot -i"
# RE-SNAPSHOT BETWEEN THE CLICK AND THE FILL, and use the refs THAT snapshot
# printed. Chaining them in one batch looks tidier and silently does nothing: the
# click leaves :3009 for the realm, which invalidates every ref, so the fills
# answer "Unknown ref" and the row submits an EMPTY form — which still shows
# "Invalid username or password." and reads like a pass. Measured 2026-08-17.
agent-browser $N batch "fill @e2 alice" "fill @e4 password123" "click @e3" \
  "wait 3000" "get url" "snapshot -i"
# ASSERTION — still on the realm's own page at localhost:8081 with an
# "Invalid username or password." message, and NEVER back on :3009 with a shell.
# A rendered portal after these credentials is a FAILED row and means the two
# realms share a user store.

# B8. Cleanup — both portal sessions.
agent-browser $P close
agent-browser $N close

# ---------------------------------------------------------------------------
# B9-B10: THE ADR-053 PORTAL AFFORDANCES. A17/A21 prove the receipts API and
# the wire answer with curl; these prove the operator can actually reach them.
# Both need a signed-in staff session — reuse the B5 flow in a fresh session.
# ---------------------------------------------------------------------------
Q="--session portal-adr053"

# B9. RECEIVE FIRST STOCK reaches an untracked SKU. The page-level dialog is
#     the whole point: the row-scoped Receive cannot see a SKU with no row.
agent-browser $Q --args "--no-sandbox" batch \
  "open http://localhost:3009/inventory" "wait 2500" "snapshot -i"
# (sign in via the realm form as in B5 if the login page appears, then
#  re-open /inventory and re-snapshot. Use the refs YOUR snapshot prints.)
agent-browser $Q batch "click <ref of 'Receive first stock'>" "wait 800" "snapshot -i"

#     THE DIALOG HAS NO REFS. It opens and renders correctly — `screenshot`
#     and `read` both show it — but the portal's dialogs carry `role="dialog"`
#     WITHOUT `aria-modal`, and neither `snapshot` nor `snapshot -i` surfaces
#     their fields. So there is nothing to `click`/`type` by ref, and a missing
#     ref here is NOT a failed row. Drive it through the DOM instead. React
#     controlled inputs ignore a plain `.value =`, so go through the native
#     setter and dispatch `input`, or the field reverts on the next render:
#
#       agent-browser $Q eval "(() => {
#         const set = (el, v) => {
#           Object.getOwnPropertyDescriptor(el.constructor.prototype, 'value')
#             .set.call(el, v);
#           el.dispatchEvent(new Event('input', { bubbles: true }));
#         };
#         const d = document.querySelector('[role=dialog]');
#         const [sku, wh, qty] = d.querySelectorAll('input');
#         set(sku, 'b9-' + Math.floor(Date.now()/1000)); set(wh, '1'); set(qty, '4');
#         return d.innerText;
#       })()"
#
#     `read` is what reads the advisory line back; the submit is the same shape,
#     clicking the dialog's own `Receive` button. Ref-driven flows work normally
#     everywhere else on the page — this applies only to the dialogs.
# Fill a SKU id that has no balance row (b9-<epoch> is untracked by
# construction), warehouse 1, quantity 4 — and BEFORE submitting, the advisory
# line must read "No balance row yet — this receipt creates it."
# After Receive: "Stock received." Then filter the balances table by that SKU
# and assert the new row exists with on-hand 4, and the movements ledger shows
# RECEIVE with duyne's subject (d0e00000-0000-4000-8000-000000000001).

# B10. THE PUBLISH WARNING fires and does not gate. Create a draft in the
#      Catalog (fresh products are untracked by construction), click publish,
#      and in the confirm dialog assert BOTH:
#        - the amber notice "No inventory balance row exists for SKU …"
#        - the Publish button is still ENABLED (warn, never gate)
#      then Publish and assert the row reads ACTIVE.
agent-browser $Q close
```

## Phase C — telemetry sanity (curl + PromQL + LogsQL + SQL, ~6 min)

The stack ships the full RFC-0014/0017/0019 telemetry pipeline, and a change can
pass A+B while silently breaking any leg of it. Phase C therefore walks **every**
leg — four signals, five stores, six export paths — rather than sampling one
query per backend. It is run **after** Phase A, because most of what it reads is
produced by Phase A's flow.

Three things to hold in mind before the first query:

- **Wait 30–45 seconds after the last driven request.** The services export OTLP
  on a 15s interval, the spanmetrics connector flushes on 15s, and the
  fulfillment saga is asynchronous. Every row below inherits this lag; a row that
  reads empty inside that window is *pending*, not failed. The lookback windows
  are **45 minutes** for the same reason in reverse: Phase A takes about ten
  minutes and Phase B another five, so a 15-minute window would drop A1–A10 out
  of range and make a healthy stack look uninstrumented.
- **The edge is the trace root now.** Envoy is the first span of every
  browser/curl-driven trace, so C2 and C3 are the rows that prove the trace
  actually starts where the request entered the platform.
- **Two ports are deliberately host-unreachable, and neither was forgotten.**
  Envoy's Prometheus endpoint and its admin interface are not published: the
  compose stack exposes only `8080` (proxy) and `8099` (control plane
  `/readyz`). Proxy stats ARE scraped — in-network, by vmagent's `envoy` job
  against the bootstrap-merged `:19005` listener (C20 asserts it) — they are
  just not a host-side surface. Likewise the collector's OTLP **gRPC**
  receiver on `:4317` is not published; it is reachable only from inside the
  compose network, which is exactly what the edge needs and why no host-side
  generator can stand in for it.

```bash
VM=http://localhost:8428/api/v1/query                     # VictoriaMetrics
VL=http://localhost:9428/select/logsql/query              # VictoriaLogs (LogsQL)
VT=http://localhost:10428/select/jaeger/api               # VictoriaTraces, Jaeger-compatible API
CH=http://localhost:8123/                                 # ClickHouse (-u default:otel, db otel)
GRAF=http://localhost:3002                                # Grafana (anonymous Admin, no auth)
EDGE=platform.envoy-gateway-system                        # see C2 — discover, do not assume

# Drive ONE request with a unique marker. Several rows below need to point at a
# specific request rather than "some traffic", and the edge span records the full
# URL including the query string, so a tagged public route is the cheapest handle
# that reaches traces AND access logs.
TAG=$(date +%s)
curl -s -o /dev/null -w "C0 tagged request: %{http_code} (want 200)\n" \
  "http://localhost:8080/product/v1/public/products?audit=$TAG"
sleep 45

# C1. Pipeline health — the collector must not be dropping data
#     (compose service name — there is no `otel-collector` container_name)
docker compose logs --since 10m otel-collector 2>&1 \
  | grep -ciE 'export.*fail|"level":"error"|\terror\t' \
  | xargs -I{} sh -c '[ {} -eq 0 ] && echo "C1 OK collector clean" || echo "C1 FAIL: {} error lines"'

# ---- TRACES ----------------------------------------------------------------

# C2. THE EDGE SPAN EXISTS AND IS THE TRACE ROOT. The most important row in this
#     phase: it is the only proof that the edge is still a span producer. The edge
#     does not set `service.name` explicitly anywhere in gateway/eg/ — Envoy
#     Gateway derives it from the Gateway's identity as `<gateway>.<namespace>`,
#     which for gateway/eg/gateway.yaml plus the file provider's default namespace
#     is `platform.envoy-gateway-system`. DISCOVER it rather than trusting this
#     line: the derivation is upstream behaviour and a rename of the Gateway
#     changes it. The NOT-IN list must name every OTHER span producer including
#     the two workers (own identities since 2026-08-17, the C8 fix) and
#     keycloak (a span producer since its tracing enablement) — a name
#     missing here multiplies into FOUND, and the tr strips the newlines, so C2
#     prints a concatenated blob and C6 inherits it through $EDGE. Found the
#     hard way on the 2026-08-18 run, and again with keycloak on 2026-08-20.
FOUND=$(curl -s "$CH" -u default:otel --data-binary "
  SELECT DISTINCT ServiceName FROM otel.otel_traces
  WHERE Timestamp > now() - INTERVAL 45 MINUTE
    AND ServiceName NOT IN ('user','product','inventory','cart','order','review',
                            'shipping','notification','payment','checkout','mockpay',
                            'order-worker','checkout-worker','keycloak')
  FORMAT TSV" | tr -d '[:space:]')
echo "C2 discovered edge service.name: '${FOUND:-<none>}' (expected '$EDGE')"
[ -n "$FOUND" ] || echo "C2 FAIL: the edge is emitting no spans — run the isolation steps below"
[ "$FOUND" = "$EDGE" ] || echo "C2 NOTE: unexpected value — see the two readings below"
# Two readings for a mismatch, and they need different fixes:
#   * the Gateway was renamed, so the derived name changed -> record the new value
#     in the evidence table and carry on.
#   * a service that should not be running is emitting spans. `auth` appearing
#     here means a removed auth-service container is still up.
EDGE=${FOUND:-$EDGE}     # every row below uses what was actually found

# The strong assertion: the ROOT span of the request driven above belongs to the
# edge, not to a service. Root == ParentSpanId = ''.
curl -s "$CH" -u default:otel --data-binary "
  SELECT ServiceName, SpanName, SpanKind, ParentSpanId = '' AS is_root
  FROM otel.otel_traces
  WHERE SpanAttributes['http.url'] LIKE '%audit=$TAG%'
  FORMAT TSV"
# want exactly one row: the value of $EDGE, then `ingress`, `Server`, `1`
# A service name here, or is_root=0, means the trace no longer starts at the edge.

# Fallback identity check, independent of the derived name: the EnvoyProxy CR
# tags every edge span with a literal customTag, so this counts edge spans even
# if the service name changed.
curl -s "$CH" -u default:otel --data-binary "
  SELECT count() FROM otel.otel_traces
  WHERE Timestamp > now() - INTERVAL 45 MINUTE
    AND SpanAttributes['deployment.environment.name'] = 'local'
  FORMAT TSV"
# want > 0

# ISOLATION when C2 is empty, in this order:
#   1. docker compose logs gateway 2>&1 | grep 'failed to find envoyproxy'
#      — a hit means the EnvoyProxy CR never attached, so tracing was never
#      configured. The edge still answers 200; only this row notices.
#   2. docker compose logs otel-collector — it logs its receivers at startup
#      ("Starting GRPC server ... endpoint [::]:4317"). If that line is absent the
#      edge had nowhere to export to. `:4317` is not published to the host, so
#      there is no host-side telemetrygen shortcut here; the logs are the check.

# C3. TRACE CONTINUITY edge -> service. One TraceId, two or more service names
#     including the edge, and the service's span PARENTED (non-empty
#     ParentSpanId) — i.e. traceparent survived the hop, rather than the service
#     starting a second, disconnected trace.
curl -s "$CH" -u default:otel --data-binary "
  SELECT ServiceName, SpanName, SpanKind, ParentSpanId != '' AS has_parent
  FROM otel.otel_traces
  WHERE TraceId = (SELECT TraceId FROM otel.otel_traces
                   WHERE SpanAttributes['http.url'] LIKE '%audit=$TAG%' LIMIT 1)
  ORDER BY Timestamp
  FORMAT TSV"
# want: the edge's `ingress` (has_parent 0) then its `router ... egress` client
# span, then the service's Server span with has_parent 1, then that service's
# internal/client spans. Two roots, or a service Server span with has_parent 0,
# is a broken propagation chain.

# C4. PER-SERVICE SPAN COVERAGE, with the server/client split. Row counts alone
#     hide the interesting failure — a service that only ever appears as someone
#     else's CLIENT span is not instrumented on its own inbound path.
curl -s "$CH" -u default:otel --data-binary "
  SELECT ServiceName, count() AS spans, countIf(SpanKind = 'Server') AS server_spans
  FROM otel.otel_traces
  WHERE Timestamp > now() - INTERVAL 45 MINUTE
  GROUP BY ServiceName ORDER BY spans DESC
  FORMAT TSV"
# want every service driven by Phase A present with server_spans > 0, plus $EDGE.

# C5. ClickHouse (RFC-0019 Phase B) ingested OTLP logs AND traces.
#     otel_logs/otel_traces are auto-created by the collector's clickhouse exporter.
for t in otel_traces otel_logs; do
  N=$(curl -s "$CH" -u default:otel --data-binary "SELECT count() FROM otel.$t" 2>/dev/null | tr -d '[:space:]')
  { [ -n "$N" ] && [ "$N" -gt 0 ] 2>/dev/null && echo "C5 $t: $N rows OK"; } \
    || echo "C5 $t: ${N:-0} rows FAIL (ingest lag? exporter/plugin?)"
done

# C6. Trace coverage for the whole local fleet, read from VictoriaTraces'
#     JAEGER-COMPATIBLE QUERY API. There is no Jaeger container in this stack —
#     VictoriaTraces serves this API shape so Grafana's `jaeger` datasource type
#     can query it.
#
#     The required set is the TEN application services local-stack runs plus the
#     EDGE, which is a first-class traced participant now that it is the trace
#     root. `auth` is deliberately absent: auth-service is removed from
#     local-stack (its cluster surface retires in RFC-0024 P5), so nothing calls
#     it and its presence here would be the bug. `mockpay` shows up too and is
#     legitimate — the provider stub calls back into the edge — but it is not part
#     of the application fleet, so it is not required.
curl -s "$VT/services" | python3 -c "
import json,sys
actual = set(json.load(sys.stdin)['data'])
required = {'user','product','inventory','cart','order','review','shipping',
            'notification','payment','checkout','$EDGE'}
missing = sorted(required - actual)
print('C6 traced services:', 'OK all 10 services + edge' if not missing else 'FAIL missing=' + ','.join(missing))
print('C6 also present (expected, not required):', sorted(actual - required))
if 'auth' in actual: print('C6 NOTE: auth is traced — auth-service should be gone from local-stack')
raise SystemExit(1 if missing else 0)"
# `inventory` appears only via its east-west gRPC callers, so this row is not
# meaningful before Phase A has run in full.

# ---- METRICS ---------------------------------------------------------------

# C7. spanmetrics / RED leg: the collector's spanmetrics connector derived
#     metrics FROM the traces above and remote-wrote them to VictoriaMetrics.
#     This is a different export path from every other metric in this phase
#     (prometheusremotewrite, not VM's OTLP ingest), so it fails independently.
curl -s "$VM" --data-urlencode 'query=sum(spanmetrics_calls_total{span_kind="SPAN_KIND_SERVER"})' \
  | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; \
    v=float(r[0]['value'][1]) if r else 0; \
    print('C7 spanmetrics_calls_total:', 'OK %g' % v if v > 0 else 'FAIL no server calls')"
curl -s "$VM" --data-urlencode 'query=count(spanmetrics_duration_milliseconds_bucket)' \
  | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; \
    print('C7 duration buckets:', r[0]['value'][1] + ' series' if r else 'FAIL absent')"
# Bonus check worth reading: the edge appears here as a service too —
#   sum by (service_name) (spanmetrics_calls_total{span_kind="SPAN_KIND_SERVER"})
# lists $EDGE alongside the applications.

# C8. App semconv metrics leg — the services' own OTLP metrics into VM's native
#     OTLP ingest, renamed to PromQL style by VM. Separate pipeline from the
#     business counters in C9 and from spanmetrics in C7.
for q in 'sum(http_server_request_duration_seconds_count)' \
         'sum(rpc_server_call_duration_seconds_count{service_name="inventory"})' \
         'count(go_goroutine_count)'; do
  curl -s "$VM" --data-urlencode "query=$q" \
    | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; \
      print('C8', '$q', '=>', r[0]['value'][1] if r else 'NO SERIES — FAIL')"
done
# The `inventory` row carries weight beyond itself: inventory is gRPC-only with no
# edge route, so `rpc_server_call_duration_seconds_count` is the ONLY metrics
# evidence that it is instrumented at all. `go_goroutine_count` proves the runtime
# instrumentation leg. **Thirteen** series on a full stack: the ten application
# services, `mockpay`, and the two workers, which carry their own identities
# (`order-worker`, `checkout-worker`) exactly as they do in the cluster.
#
# This read eleven until 2026-08-17, when compose gave each worker its service's
# `OTEL_SERVICE_NAME` and this note called that "sharing the series by design".
# It was not sharing. Two processes exporting the same `service.name` with no
# distinguishing resource attribute overwrite each other's samples, so the value
# alternated between the API's and the worker's — the Kind audit caught it by
# finding no such collision on the cluster, where the workers were already named
# apart. Compose now matches.

# C9. Business counters move with the flow: the three ends of the saga should
#     agree — confirmed = saga = authorized.
#
#     These are per-process counters, so equality only holds while no process has
#     restarted. A14 restarts `temporal` and A15 restarts `order-worker`, which
#     resets the saga counter to 0 — after either row, `order_saga_outcome_total`
#     counts only the sagas driven SINCE that restart and will read lower than
#     checkout's and payment's. That is arithmetic, not a failure. Either run C9
#     before A14/A15, or settle it with the durable evidence: every
#     `OrderFulfillmentWorkflow` execution `Completed` and every confirmed order
#     reaching `completed`.
for m in checkout_sessions_confirmed_total 'order_saga_outcome_total{outcome="confirmed"}' \
         'payment_authorization_total{result="authorized"}'; do
  curl -s "$VM" --data-urlencode "query=sum($m)" \
    | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; \
      print('C9', '$m'.split('{')[0], '=', r[0]['value'][1] if r else 'NO SERIES')"
done
# Do NOT extend this loop with `auth_*` counters. Since the identity cutover the
# realm performs authentication, so those series may legitimately never exist;
# asserting them would fail a healthy stack.

# C10. Temporal metrics, both halves. SDK first — the worker processes' own
#      instrumentation, a leg that no other row touches. Absent series here
#      means obsx wired the SDK without its metrics handler, which is invisible
#      everywhere else. Note the SDK counters are BARE names (no _total):
#      verified against live series 2026-08-18; temporal_workflow_failed and
#      friends are failure-only and legitimately absent on a healthy run.
for q in 'count(temporal_workflow_endtoend_latency_seconds_bucket)' \
         'sum(temporal_activity_execution_latency_seconds_count)' \
         'sum(temporal_workflow_completed)' \
         'sum(temporal_worker_task_slots_available)' \
         'sum(temporal_num_pollers)'; do
  curl -s "$VM" --data-urlencode "query=$q" \
    | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; \
      print('C10', '$q', '=>', r[0]['value'][1] if r else 'NO SERIES — FAIL')"
done
# ... then the SERVER half — the :8000 listener PROMETHEUS_ENDPOINT enables,
# scraped by vmagent's `temporal` job. The error counter is
# service_error_with_type (service_errors does not exist on 1.31.2).
for q in 'up{job="temporal"}' \
         'sum(rate(service_requests[5m]))' \
         'sum(rate(persistence_requests[5m]))'; do
  curl -s "$VM" --data-urlencode "query=$q" \
    | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; \
      print('C10 server', '$q', '=>', r[0]['value'][1] if r else 'NO SERIES — FAIL')"
done

# C11. DB client telemetry sane (RFC-0017 W4 — needs pkg >= v0.24.0 in the
#      services): query p95 must be a real number, not bucket-collapse garbage.
curl -s "$VM" --data-urlencode \
  'query=histogram_quantile(0.95, sum by (le) (rate(db_client_operation_duration_seconds_bucket{pgx_operation_type="query"}[5m])))' \
  | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; \
    v=float(r[0]['value'][1]) if r else None; \
    print('C11 DB p95:', 'OK %.2fms' % (v*1000) if v and v < 0.5 else f'FAIL {v} (collapsed buckets? old pkg?)')"

# ---- LOGS ------------------------------------------------------------------
#
# VictoriaLogs holds TWO independent ingest legs and they are told apart by their
# STREAM FIELD, which is the only reliable discriminator:
#   * OTLP leg  — the Go services' otelzap tee -> collector -> VictoriaLogs. The
#     collector's `VL-Stream-Fields: service.name` header makes `service.name` the
#     stream identity, so these streams are `_stream:{"service.name"="cart"}`.
#   * Vector leg — `docker_logs` tails container stdout for everything WITHOUT an
#     OTel SDK (the edge, infra, the SPA) and ships with
#     `_stream_fields=service,container_name`, so these streams are
#     `_stream:{service="gateway"}`.
# `checkout`, `checkout-worker`, `inventory` and `mockpay` are NOT in Vector's
# exclude list, so their lines land TWICE — once per leg, under different stream
# fields. That duplication is by design; it is not a regression to chase.

# C12. App logs, OTLP leg.
curl -s "$VL" --data-urlencode 'query=_time:45m _stream:{"service.name"="cart"} | count()'
# want a non-zero count(*). Enumerate the whole leg with:
curl -s http://localhost:9428/select/logsql/stream_field_values \
  --data-urlencode 'query=_time:45m' --data-urlencode 'field=service.name'
# want every service Phase A drove.

# C13. EDGE ACCESS LOGS, OTLP leg. The second-most important row in this phase:
#      the edge's JSON access log is the only structured record of what the edge
#      did, and the field set is contracted in gateway/eg/envoyproxy.yaml.
#
#      THE STREAM MOVED. Until ADR-060 (#886, 2026-08-24) this row read the Vector
#      leg, `_stream:{service="gateway"}`. That leg now carries ZERO lines — the
#      access log goes out over OTLP instead, landing under
#      `_stream:{"service.name"="platform.envoy-gateway"}` with the same field set.
#      Measured on the 2026-08-25 gate run: Vector leg 0, OTLP leg 1540, every one
#      of them carrying `upstream_cluster` and `route_name`. The old query could
#      only ever fail, which is exactly the "an expression that cannot pass reads
#      as coverage" failure this audit exists to catch.
#
#      `upstream_cluster` and `route_name` exist only on access-log lines, so
#      requiring both still discriminates them from the control plane's own logs.
curl -s "$VL" --data-urlencode \
  'query=_time:45m _stream:{"service.name"="platform.envoy-gateway"} upstream_cluster:* route_name:* | count()'
# want a non-zero count(*). Then pin the specific request driven in C0:
curl -s "$VL" --data-urlencode \
  "query=_time:45m _stream:{\"service.name\"=\"platform.envoy-gateway\"} upstream_cluster:* uri:\"audit=$TAG\"" \
  --data-urlencode 'limit=1'
# want ONE line whose parsed fields are the CR's contract:
#   uri=/product/v1/public/products?audit=$TAG  status=200  method=GET
#   upstream_cluster=httproute/envoy-gateway-system/api-product/rule/0
#   route_name=.../match/0/*  upstream=<ip:8080>  duration=<ms>  request_id=<uuid>
# `host` is in the CR's JSON but never reaches VictoriaLogs: the Vector
# transform's `del(.host)` (aimed at docker_logs' machine-hostname field) runs
# after the JSON parse and takes the access log's authority with it. As-built
# quirk, not a regression — do not assert on `host`.
# Read those FIELD NAMES, not just the values: with the EnvoyProxy CR unattached
# Envoy falls back to its built-in JSON, which reports the same facts as
# `x-envoy-origin-path`, `response_code` and `upstream_host` — every Vector-parsed
# edge panel breaks on that rename while this row would still find "a log line".

# C14. Vector is tailing NON-app containers too — the half of the log estate that
#      has no OTel SDK at all. `frontend` is the right witness: it is the SPA's
#      web server, so Phase B guarantees it produced lines, and nothing but Vector
#      can carry them.
curl -s "$VL" --data-urlencode 'query=_time:45m _stream:{service="frontend"} | count()'
# want a non-zero count(*). Enumerate the whole leg to see who else is covered:
curl -s http://localhost:9428/select/logsql/stream_field_values \
  --data-urlencode 'query=_time:45m' --data-urlencode 'field=service'
# expect the chatty infra containers (otel-collector, pyroscope, grafana, postgres)
# plus gateway, frontend, and the double-shipped app containers. A QUIET container
# is a bad witness, not a failure: `temporal` logs almost nothing once it is up, so
# an empty `_stream:{service="temporal"}` proves nothing either way.
# C13 + C14 both empty, with `service.name` streams healthy, is ONE failure, not
# two: the Vector leg is down. `docker compose logs vector` names the cause; under
# podman `Socket not found: /var/run/docker.sock` means the stack was brought up
# WITHOUT compose.podman.yaml, and the fix is a re-bring-up with the overlay, not
# a restart (see the container-runtime note in Preconditions).

# C15. LOG <-> TRACE CORRELATION. A log line that carries its TraceId is what
#      makes "jump from this log to that trace" work in Grafana; without it both
#      stores are populated and still useless together.
curl -s "$CH" -u default:otel --data-binary "
  SELECT count() AS logs, countIf(TraceId != '') AS correlated
  FROM otel.otel_logs WHERE Timestamp > now() - INTERVAL 45 MINUTE
  FORMAT TSV"
# want correlated > 0. The same field is queryable on the VictoriaLogs side as a
# regular (non-stream) field: `_time:45m _stream:{"service.name"="cart"} trace_id:*`

# ---- PROFILES -------------------------------------------------------------

# C16. Pyroscope has profiles for the services Phase A drove. The HTTP surface is
#      Pyroscope's Connect-RPC querier: POST, JSON body, no query string — and it
#      REQUIRES an explicit millisecond time range, answering
#      `{"code":"invalid_argument","message":"missing time range in the query"}`
#      without one. (The GET `/pyroscope/label-values` shape returns 400 on this
#      build however `label`/`name` are spelled — do not use it.)
curl -s -X POST 'http://localhost:4040/querier.v1.QuerierService/LabelValues' \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"service_name\",\"matchers\":[\"{}\"],\"start\":$(((`date +%s`-3600)*1000)),\"end\":$((`date +%s`*1000))}" \
  | python3 -c "import json,sys; got=set(json.load(sys.stdin)['names']); \
  required={'user','product','inventory','cart','order','review','shipping','notification','payment','checkout'}; \
  missing=sorted(required-got); print('C16 profiled services:', 'OK all 10' if not missing else 'FAIL missing='+','.join(missing)); \
  print('C16 also present:', sorted(got-required)); \
  raise SystemExit(1 if missing else 0)"
# `pyroscope` itself appears in that list (it profiles its own process) — expected.
# `auth` must NOT appear: the profiler shipped with auth-service, which is gone
# from local-stack. A stale `auth` here means a leftover container is running.
# Equivalent through Grafana, useful when checking the datasource path rather than
# the store: POST $GRAF/api/datasources/proxy/uid/pyroscope/querier.v1.QuerierService/LabelValues

# ---- GRAFANA --------------------------------------------------------------

# C17. Every datasource resolves to the expected uid/type AND answers a health
#      probe. Grafana runs with anonymous Admin locally, so no auth is needed.
curl -s "$GRAF/api/datasources" | python3 -c "
import json,sys
want = {'victoriametrics':'prometheus','victoriatraces':'jaeger',
        'clickhouse':'grafana-clickhouse-datasource','pyroscope':'grafana-pyroscope-datasource',
        'victorialogs':'victoriametrics-logs-datasource'}
got = {d['uid']: d['type'] for d in json.load(sys.stdin)}
print('C17 datasources:', 'OK' if got == want else f'FAIL got={got}')
raise SystemExit(0 if got == want else 1)"
for u in victoriametrics victoriatraces clickhouse pyroscope victorialogs; do
  printf 'C17 %-16s ' "$u"
  curl -s "$GRAF/api/datasources/uid/$u/health" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['status'], '-', d['message'])"
done
# want status OK on all five.

# C18. The provisioned dashboard inventory is complete and every dashboard object
#      still parses.
curl -s "$GRAF/api/search?type=dash-db" | python3 -c "
import json,sys
want = {'microservices-otel-local','business-otel-local','temporal-worker-local','red-spanmetrics',
        'otel-collector-health-local',
        # RFC-0021 parity copies — cluster-twin uids, backed by the vendored
        # recording rules under observability/vmalert/rules/:
        'inventory-overview','rfc0021-baseline',
        'clickhouse-otel-sql','clickhouse-service-deepdive','clickhouse-otel-overview',
        'clickhouse-logs-explorer','clickhouse-traces-explorer',
        'clickhouse-server-engine',
        # Gateway/ — Envoy Gateway's own dashboards, vendored verbatim from
        # charts/gateway-addons-helm at the pinned EG tag, uids upstream's:
        'heHhNSFf6Na8vIZWRs8H','8WkEOMnANKE6PW5hhpVv','bdn8lriao7myoa',
        # Gateway/ — hand-authored edge SRE overview (golden signals + EG
        # control plane + process infra), cluster twin under
        # kubernetes/infra/configs/observability/grafana/dashboards/:
        'eg-edge',
        # platform-infrastructure/ — Keycloak Identity (login/token KPIs), cluster twin
        # same uid:
        'keycloak-identity'}
got = {d['uid'] for d in json.load(sys.stdin)}
print('C18 dashboards:', 'OK all ' + str(len(want)) + '' if got == want else f'FAIL missing={sorted(want-got)} extra={sorted(got-want)}')
raise SystemExit(0 if got == want else 1)"
for d in microservices-otel-local business-otel-local temporal-worker-local red-spanmetrics \
         otel-collector-health-local inventory-overview rfc0021-baseline \
         clickhouse-otel-sql clickhouse-service-deepdive \
         clickhouse-otel-overview clickhouse-logs-explorer clickhouse-traces-explorer \
         clickhouse-server-engine \
         heHhNSFf6Na8vIZWRs8H 8WkEOMnANKE6PW5hhpVv bdn8lriao7myoa eg-edge keycloak-identity; do
  curl -s -o /dev/null -w "C18 $d: %{http_code} (want 200)\n" "$GRAF/api/dashboards/uid/$d"
done
# ...and every datasource REFERENCE inside them resolves. A 200 above only says
# the object parses. A dashboard whose panels name `${DS_PROMETHEUS}` without
# declaring that variable, or a uid no datasource carries, loads with a green
# 200 and then renders "Datasource ... was not found" on every panel — which is
# exactly how `clickhouse-server-engine` shipped: vendored from grafana.com with
# its `__inputs` block intact, and provisioning does not process `__inputs`.
# Found by opening the UI on 2026-08-17, not by this row, which is why the row
# now exists.
LIVE=$(curl -s "$GRAF/api/datasources" | python3 -c "import json,sys;print(','.join(d['uid'] for d in json.load(sys.stdin)))")
for d in microservices-otel-local business-otel-local temporal-worker-local red-spanmetrics \
         otel-collector-health-local inventory-overview rfc0021-baseline \
         clickhouse-otel-sql clickhouse-service-deepdive \
         clickhouse-otel-overview clickhouse-logs-explorer clickhouse-traces-explorer \
         clickhouse-server-engine \
         heHhNSFf6Na8vIZWRs8H 8WkEOMnANKE6PW5hhpVv bdn8lriao7myoa eg-edge keycloak-identity; do
  curl -s "$GRAF/api/dashboards/uid/$d" | LIVE="$LIVE" python3 -c "
import json, os, re, sys
live = set(os.environ['LIVE'].split(',')) | {'grafana', '-- Grafana --', '-- Mixed --', '-- Dashboard --'}
d = json.load(sys.stdin)['dashboard']
s = json.dumps(d)
declared = {v['name'] for v in d.get('templating', {}).get('list', []) if v.get('type') == 'datasource'}
used = {m for m in re.findall(r'\\\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?', s)
        if m.upper().startswith('DS_') or m in ('ds', 'datasource')}
lits = {u for u in re.findall(r'\"uid\": \"([^\"\$]+)\"', s)} - live - {d.get('uid')}
bad = (used - declared) | lits
print('C18 refs', 'OK  ' if not bad else 'FAIL', d['title'], '' if not bad else '-> ' + ','.join(sorted(bad)))"
done
# want every line OK. A FAIL names either an undeclared ${VAR} or a uid that no
# datasource carries; both render as an error banner, never as "No data".

# C19. PANELS RETURN DATA. C18 only proves the dashboard OBJECTS exist; a
#      provisioned dashboard loads happily while every panel renders "No data".
#      Run one representative query per datasource THROUGH Grafana, so the
#      datasource plugin and its credentials are on the path, not just the store.
curl -s -X POST "$GRAF/api/ds/query" -H 'Content-Type: application/json' -d '{
  "from":"now-45m","to":"now",
  "queries":[{"refId":"A","datasource":{"uid":"victoriametrics","type":"prometheus"},
              "expr":"sum(spanmetrics_calls_total)","instant":true}]}' \
  | python3 -c "import json,sys; f=json.load(sys.stdin)['results']['A']['frames'][0]['data']['values']; \
    print('C19 victoriametrics:', 'OK', f[1][0])"
curl -s -X POST "$GRAF/api/ds/query" -H 'Content-Type: application/json' -d '{
  "from":"now-45m","to":"now",
  "queries":[{"refId":"A","datasource":{"uid":"clickhouse","type":"grafana-clickhouse-datasource"},
              "rawSql":"SELECT count() AS spans FROM otel.otel_traces","format":1,"queryType":"table"}]}' \
  | python3 -c "import json,sys; f=json.load(sys.stdin)['results']['A']['frames'][0]['data']['values']; \
    print('C19 clickhouse:', 'OK', f[0][0])"
# want a non-zero number from each. A 4xx/5xx or an empty frame means the panel
# path is broken even though C17's health probe passed — health only proves the
# plugin can reach the store, not that it can run a query and shape a frame.

# ---- ENGINE-HEALTH SLICE (scrape + alert loop) -------------------------------

# C20. vmagent scrapes every static target. `up` is the only signal that
#      says a BACKEND itself is down — everything else in Phase C is telemetry
#      the backends receive, not telemetry about them. A target that is absent
#      here means the alert rules in C21 evaluate against nothing and can never
#      fire, which is invisible until the day they were needed. The two envoy
#      jobs are the edge's halves: `envoy-gateway` is the control plane's own
#      :19001 metrics, `envoy` is the proxy's native stats through the
#      bootstrap-merged :19005 listener (gateway/eg/envoyproxy.yaml). The
#      `temporal` job is the server's :8000 listener (PROMETHEUS_ENDPOINT in
#      compose.yaml) — service_*/persistence_* families, C10's server half.
#      `keycloak` is the management interface :9000 — the micrometer families
#      the identity KPIs read (keycloak_user_events_total, agroal_*,
#      http_server_requests_seconds_*); same job name as the cluster so
#      KeycloakDown's `up{job="keycloak"}` can be rehearsed here.
curl -s http://localhost:8429/api/v1/targets | python3 -c "
import json, sys
t = {x['labels']['job']: x['health'] for x in json.load(sys.stdin)['data']['activeTargets']}
want = {'clickhouse', 'otel-collector', 'envoy-gateway', 'envoy', 'temporal', 'keycloak'}
ok = want <= set(t) and all(t[j] == 'up' for j in want)
print('C20', 'OK all targets up:' if ok else 'FAIL:', t)"
# want: C20 OK all targets up: {'clickhouse': 'up', 'otel-collector': 'up',
#       'envoy-gateway': 'up', 'envoy': 'up', 'temporal': 'up', 'keycloak': 'up'}

# C21. vmalert loaded the ported cluster rules and nothing is firing on a
#      healthy stack. 18 alerting rules are expected: eight ClickHouse engine
#      rules (cluster catalog § 8b names where the signal exists on one node;
#      the operator and replication rules have no local counterpart, and
#      ClickHouseMergesFailing was removed 2026-09-07 for reading a counter the
#      server does not publish), the two collector rules, the
#      three inventory alerts that travel with the vendored RFC-0021 recording
#      rules, and the four keycloak alerts (KeycloakDown + the three identity
#      KPI alerts; KeycloakRestartLoop stays cluster-only — it reads
#      kube-state metrics), and Watchdog. 15 recording rules ride along
#      (rfc0021-baseline 10 + inventory 5) so the two RFC-0021 dashboards
#      render — counted separately because a recording rule can never fire.
#
#      Watchdog was ported from the cluster on 2026-08-24: local-stack had none,
#      which made the k6 C21 assertion "Watchdog is present" unpassable here. It
#      ALWAYS fires — that is the entire point of a dead-man's-switch — at
#      `severity: none`, so it is expected in the firing list below and the k6
#      row is unaffected (that one only counts page/critical).
curl -s http://localhost:8880/api/v1/rules | python3 -c "
import json, sys
gs = json.load(sys.stdin)['data']['groups']
rules = [r for g in gs for r in g['rules']]
alerting = [r for r in rules if r['type'] == 'alerting']
recording = [r for r in rules if r['type'] == 'recording']
firing = [r['name'] for r in alerting if r.get('state') == 'firing']
print('C21 rules loaded: %d alerting (want 18) + %d recording (want 15); firing: %s'
      % (len(alerting), len(recording), firing or 'none'))"
# want: 18 alerting + 15 recording, firing ['Watchdog'] and nothing else. A
# missing rule file mounts silently — the counts are the tripwire. Any OTHER
# firing rule on a fresh stack is a real finding: chase it before calling the
# audit passed. Watchdog MISSING from that list is also a finding — it means the
# alert pipeline is not evaluating at all.

#      Optional drill (NOT part of the pass bar — it takes ~6 minutes): stop
#      clickhouse, wait out the 5m `for`, confirm ClickHouseAllReplicasUnreachable
#      fires, then start it again. Run it when the rules themselves changed.
# docker compose stop clickhouse && sleep 360 \
#   && curl -s http://localhost:8880/api/v1/alerts | python3 -c "import json,sys; \
#      print([a['labels']['alertname'] for a in json.load(sys.stdin)['data']['alerts']])" \
#   && docker compose start clickhouse
```

> A brand-new counter has **no series until its first increment** — "NO SERIES"
> for an error/discrepancy counter on a healthy stack is correct, not a failure.
> The rows above name the series that MUST exist after Phase A; nothing else is
> asserted. When a change alters histogram **buckets**, old- and new-grid series
> coexist in one rate window for a few minutes and quantiles read garbage until
> the old grid ages out (~4–5 min) — re-check before declaring failure.

## Pass criteria

| # | Check | Expectation |
|---|-------|-------------|
| A1 | Realm token (PKCE) | `scripts/keycloak-token.sh` mints a JWT whose `iss` is the realm, whose `aud` includes `duynhlab-platform`, and whose `sub` is alice's fixed UUID **as a string** (ADR-042 evidence); `refresh_token` + `expires_in` present |
| A2 | Private routes w/ realm token | 200 through the Envoy edge JWT filter |
| A3 | Bad/missing token | 401 **at the edge**, `text/plain` body `Jwt is missing`, **and** `www-authenticate: Bearer realm="<requested URL>"` — plus `error="invalid_token"` when a token was present but unverifiable. All three are required |
| A4 | Refresh reuse (realm) | refresh rotates; replaying the consumed token 400 `invalid_grant` / `Maximum allowed refresh token reuse exceeded`; the replay revokes the family, so the rotated token also 400s (`Session doesn't have required client`) |
| A5 | Logout (realm) | end-session 204, replay **also 204** (idempotent); refresh afterwards 400 `Session not active` |
| A6 | Removed surfaces | `/auth/v1/private/*` 404 (no HTTPRoute matches) **and the `auth` database does not exist** — auth-service is removed from local-stack; its cluster surface retires in RFC-0024 P5 |
| A7 | v3 paths (ADR-017) | new `shipments/*` paths 200 and the deprecated `shipping/v1/public/track` alias still 200 (expand phase). The old `auth/v1/public/login` alias is **not** checked — it certified the retired token layer and has no backend |
| A8 | Internal audience sealed | renamed `notify/*` + `internal/orders/*` 404 in-container (no aliases); and the two `/internal/` paths that DO exist — product create, cart clear — 404 **at the edge** because every HTTPRoute is audience-scoped, so no audience leaks |
| A9 | Checkout sessions (RFC-0015) | lifecycle **201**→200→200→200 through edge-JWT, with the create's 201 asserted (not just used for its id); no-token 401; `/api/v1/checkout` 404; price bump flags `price_changed` |
| A10 | Confirm + abandonment (RFC-0015 P2–P4) | fee/tax/promo composition asserted; `Idempotency-Key` required; replay = same order; order reaches `confirmed` or `completed`; order total == session total; lazy-410 past `expires_at` |
| A11 | Full-fleet fan-out | product details returns product, live inventory availability, reviews, and review summary |
| A12 | Cancellation unwind (ADR-033) | cancel 202 then replay 200; order reaches `cancelled`; `CancellationWorkflow` execution `Completed`; the `cancellation_requests` row for that order is `DISPATCHED` and its `epoch` matches the `-v<n>` suffix of a `CancellationWorkflow` id — **asserted**, not merely printed |
| A13 | Abandonment timer (ADR-019) | on a **dedicated user** (`bob`, after clearing any leftover session), an untouched session past its TTL reads 410 and the row is `expired \| timer`. `lazy` is inconclusive, not a pass — it proves only the backstop |
| A14 | Temporal durability | execution count is unchanged and non-zero across `restart temporal`; the driven workflow's history is still readable |
| A16 | String subject persisted (ADR-042) | a cart write made with a realm token lands in `cart.cart_items.user_id` as the caller's realm UUID — the edge, `pkg/authmw`, the handler, and the column all agree |
| A15 | Versioning drill (conditional) | deployment registers, workflow reports `Pinned` on the current build, the superseded version reports `draining`, and the teardown leaves no `Running` workflow behind |
| A17 | Protected surface (RFC-0023 + ADR-050) | tokenless 401 **at the edge**; bare `/inventory/v1/private/*` 404 (only `/protected` is routed); a valid **customer-realm** token 401 **wrong-issuer at the edge** (the ADR-050 fence — stronger than the old in-service 403); staff operator `duyne` (realm `duynhlab-staff`) lists real balances with derived `atp`; receipt 201 `applied:true`, exact replay 200 `applied:false`, invariant-violating adjustment 409 `STOCK_UNAVAILABLE`; the movement row's `actor` is duyne's staff-realm `sub` (`d0e00000-…-001`) |
| A18 | Protected read fan-out (Train 3) | order/payment/shipping/user each answer the staff operator's list 200 **and** reject a customer-realm token 401 at the edge; payment's `reconciliations/runs` pages 200 |
| A19 | Protected catalog writes (slice B) | staff list 200 / customer token 401 at the edge; create lands **DRAFT** (v1) and 404s publicly; duplicate name 409; publish makes it public and a second publish is **409 `INVALID_TRANSITION`**; an edit at v2 succeeds and the same version again is **409 `VERSION_CONFLICT`**; archive 404s the page; the audit trail's newest action is `ARCHIVE` and every row's `actor_sub` is duyne's staff subject — a body-supplied actor is ignored; categories page 200 |
| A20 | Operator resolve (train 7 / ADR-051) | a real declined refund (total's cents `07`) parks the order in **`manual_review`** through the cancellation compensation, not through SQL; the case view carries `version`, the payment/reservation/shipment truths and the transition history, with `degraded` listing only what actually failed; a customer token is **401 wrong-issuer at the edge** on the command; an empty note and a reason from another command's vocabulary are both **400**; an illegal target is **409 `INVALID_TRANSITION`**; a version the order is not at is **409 `VERSION_CONFLICT`**; the decision itself is **201 `applied:true`**, an identical retry **200 `applied:false`** with no second history row, and a further resolve **409** (no longer parked); the `OPERATOR` history row carries `WRITTEN_OFF`, the note, and duyne's staff subject **even though the body named another actor** |
| A21 | Untracked SKU is a conflict, not an outage (ADR-053) | a published product with NO balance row carts fine, and session create answers **flat `409 ITEM_NOT_ORDERABLE`** with **no `Retry-After`** and an opaque body (the SKU ids stay in the log/span); after an operator receipt the SAME basket creates a session — the operator fix, not a retry, is what clears the state. The confirm arm's 409-with-requoted-session envelope is pinned by checkout-service's own contract tests on the same commit |
| A22 | The attention cards' six reads (RFC-0023) | the five count queries the portal dashboard issues each answer **200** with a **numeric `total_items`** (zero is a legitimate count; a missing or non-numeric field is not), the recent-orders panel honours `page_size=5`, and a status order-service does not know is **400** — which is what proves the `manual_review` and `cancelling` cards are genuinely filtered rather than both reporting the total order count |
| B1 | Login through the realm | the sign-in button changes the ORIGIN to `localhost:8081` and the credentials are typed on Keycloak's page; back on the SPA the header shows signed-in state (Products, Orders, Profile, Sign out) and the URL carries no `page` param; **no JWT-shaped value in localStorage or sessionStorage** — a `theme` preference and a `checkoutIdemKey:<uuid>` are legitimate residents, a JWT-shaped value is not; the code-exchange response carries the refresh token and its access token has `iss=http://localhost:8081/realms/duynhlab` with a string UUID `sub` |
| B2 | Adapter refresh | with a 60s client-level token lifespan, driving a private page after the token is due produces **exactly one** `POST …/openid-connect/token` with `grant_type=refresh_token` (the one `authorization_code` grant from a full page load's check-sso is expected and not counted); every `:8080` call 200; no bounce to `/login`; **the lifespan override is restored** |
| B3 | Logout via end-session | logout is a **GET** to `…/protocol/openid-connect/logout` with `post_logout_redirect_uri` + `id_token_hint`, and **no POST reaches any service**; back on the SPA unauthenticated (Sign in link, no Sign out button); a private route afterwards renders a sign-in prompt in place — **no order data from the previous session** — instead of the pre-RFC-0025 bounce to `/login`; sessionStorage empty and localStorage holds nothing token-shaped |
| B4 | Browser cleanup (storefront) | the `audit` session is closed, so a later run starts from a clean profile |
| B5 | Portal sign-in through the **staff** realm | an unauthenticated `:3009` load lands on `/login` with one "Sign in with Keycloak" button and no password field; the button changes the ORIGIN to `localhost:8081` **and the realm in the path is `duynhlab-staff`** — `realms/duynhlab` here means the container was built with the storefront's realm arg; after `duyne` signs in the shell renders with the seven primary nav items and a Sign out control (a landing on `/forbidden` is a role failure, not a sign-in failure); **no JWT-shaped value in either web storage** |
| B6 | Portal dashboard reads real numbers | all five cards present — Low / out of stock, Manual review, Cancelling, Unresolved attempts, Recon discrepancies (latest run) — each showing a numeral rather than a dash or a spinner, and every `:8080` call behind them 200. Zero is a legitimate value; a blank or missing card is not. Requires Phase A to have run first |
| B7 | The realm split is a fence in the browser | in a **clean** profile (`portal-neg`, so no staff SSO cookie), the customer account `alice` / `password123` typed on the portal's realm page stays on `localhost:8081` with "Invalid username or password."; a rendered portal shell after those credentials is a FAILED row and means the two realms share a user store |
| B8 | Browser cleanup (portal) | both the `portal` and `portal-neg` sessions are closed |
| B9 | Portal bootstrap reaches an untracked SKU (ADR-053) | the page-level **Receive first stock** dialog accepts a free-entry SKU id with no balance row; the advisory line reads "No balance row yet — this receipt creates it." before submit; after Receive the balances table shows the new row and the ledger carries the `RECEIVE` with duyne's staff subject |
| B10 | Publish warns, never gates (ADR-053) | publishing a fresh (untracked-by-construction) draft shows the amber "No inventory balance row exists for SKU …" notice inside the confirm dialog while the **Publish button stays enabled**, and the publish succeeds |
| C1 | Collector | 0 export failures / error lines |
| C2 | Edge span is the trace root | the discovery query returns exactly one non-application service name (`platform.envoy-gateway-system`, derived by Envoy Gateway from `<gateway>.<namespace>` — discovered, not assumed) and the ROOT span of the tagged request is the edge's `ingress` Server span; the `deployment.environment.name=local` customTag corroborates it |
| C3 | Trace continuity edge→service | one `TraceId` holds the edge **and** the service, with exactly one root and the service's Server span carrying a non-empty `ParentSpanId` |
| C4 | Per-service span coverage | every service Phase A drove appears in `otel.otel_traces` with `server_spans > 0`, plus the edge |
| C5 | ClickHouse (RFC-0019) | `otel.otel_traces` and `otel.otel_logs` non-empty after the driven flow (SQL over `:8123`) |
| C6 | Trace service coverage | the **10** application service names local-stack runs **plus the edge** are present in **VictoriaTraces' Jaeger-compatible query API** (`:10428/select/jaeger/api/services`) — there is no Jaeger container. `mockpay` also appears and is legitimate but not required; `auth` must be **absent** |
| C7 | spanmetrics / RED leg | `spanmetrics_calls_total{span_kind="SPAN_KIND_SERVER"}` > 0 and `spanmetrics_duration_milliseconds_bucket` present — proves the connector plus the remote-write path |
| C8 | App semconv metrics leg | `http_server_request_duration_seconds_count`, `rpc_server_call_duration_seconds_count{service_name="inventory"}` (the only metrics evidence for gRPC-only inventory), and `go_goroutine_count` all have series |
| C9 | Business counters | confirmed = saga = authorized for flows driven since the last process restart (after ~45s). A14/A15 reset the saga counter; then the durable evidence settles it — every `OrderFulfillmentWorkflow` `Completed`, every confirmed order `completed`. `auth_*` counters are **not** asserted |
| C10 | Temporal metrics, both halves | SDK: latency histograms + `temporal_workflow_completed`, worker slots, pollers have series (bare names, no `_total`); server: `up{job="temporal"}` is 1 and `service_requests` / `persistence_requests` rate — the :8000 listener `PROMETHEUS_ENDPOINT` enables |
| C11 | DB client p95 | real ms-scale value (< 500ms), not bucket-collapse garbage |
| C12 | App logs (OTLP leg) | `_stream:{"service.name"="cart"}` non-empty in VictoriaLogs, and the stream-field enumeration lists every service Phase A drove |
| C13 | Edge access logs (Vector leg) | `_stream:{service="gateway"}` filtered on `upstream_cluster:*` + `route_name:*` (the discriminator against the control plane's debug logs in the same stream) is non-empty, and the tagged request is findable **under the CR's field names** — `uri`, `status`, `method`, `upstream`, `upstream_cluster`, `route_name`, `duration`, `request_id` (`host` never reaches VL — Vector's `del(.host)` cleanup eats it; as-built quirk) — not Envoy's built-in fallback names |
| C14 | Vector infra tailing | a non-application container's logs are present, e.g. `_stream:{service="frontend"}`, and the stream enumeration covers the infra containers. C13 + C14 both empty = one failure (the Vector leg), not two |
| C15 | Log↔trace correlation | `otel.otel_logs` rows with a non-empty `TraceId` > 0 |
| C16 | Profiling | Pyroscope's `service_name` label values cover the 10 applications (Connect-RPC `LabelValues` with `matchers` and an explicit ms time range); `pyroscope` itself is expected, `auth` must be absent |
| C17 | Grafana datasources | `/api/datasources` returns exactly the five expected uid/type pairs (VictoriaLogs included) and each `/api/datasources/uid/<uid>/health` answers `OK` |
| C18 | Dashboard inventory | `/api/search?type=dash-db` returns exactly the 18 provisioned uids (incl. the three vendored Envoy Gateway dashboards plus the hand-authored Edge Overview board under Gateway/, the collector-health board, the Keycloak Identity board, and the two RFC-0021-era parity copies) and each loads via `/api/dashboards/uid/…` with 200 |
| C19 | Panels return data | `/api/ds/query` returns a non-empty frame for one representative query per datasource (VictoriaMetrics PromQL, ClickHouse SQL) — a healthy datasource that cannot shape a frame still renders "No data" |
| C20 | Engine-health scrape | vmagent (`:8429/api/v1/targets`) shows all six jobs — `clickhouse`, `otel-collector`, `envoy-gateway` (edge control plane :19001), `envoy` (proxy native stats :19005), `temporal` (server :8000) and `keycloak` (management :9000) — with `health: up`; a missing target means the C21 rules evaluate against nothing |
| C21 | Alert rules loaded, none firing | vmalert (`:8880/api/v1/rules`) reports exactly **18 alerting** rules (8 ClickHouse engine + 2 collector + 3 inventory + 4 keycloak + Watchdog) plus **15 recording** rules (RFC-0021 + inventory) and zero `firing` on a healthy stack — the counts are the tripwire for a silently unmounted rule file |

Any failed row blocks the release tag. Two rows share one root cause and must be
reported as such: **C13 + C14** both empty while C12 is healthy means the Vector
leg is down, not that two log paths regressed — check `vector` per the
container-runtime note in Preconditions, recreate the stack, and rerun.

When a change touches the order-fulfillment path, additionally run the saga
(checkout in the SPA) and watch it complete in the Temporal UI.

## Release evidence

Copy this block into the service PR or release record and replace every pending
value. Preserve the candidate SHA list with the audit result.

This audit now also gates the **identity cutover** (RFC-0024 P3) and the **edge
migration**: A1–A5 are the realm's contract, A2/A3/A8 are the Envoy edge's, and
A16 is the string-subject contract the fleet's databases were migrated for.
Changes to `local-stack/gateway/eg/`, `local-stack/keycloak/duynhlab-realm.json`,
or the cluster's `kubernetes/infra/configs/envoy-gateway/` therefore need this
evidence table too, not just service and `pkg` changes.

```markdown
### local-stack pre-release evidence

- Candidate repository/tag:
- Candidate commit:
- Supporting repository SHAs:
- Executed at:
- Container runtime:
- Stack recreated with `down -v` + `up -d --build` before this audit: yes (mandatory)
- Edge `service.name` discovered in C2:

| Phase | Checks | Result | Evidence / failure |
|-------|--------|--------|--------------------|
| A | A1–A14 + A16–A21 API contract | PASS / FAIL | |
| A | A15 versioning drill | PASS / FAIL / N/A | |
| B | B1–B10 real browser | PASS / FAIL | |
| C | C1–C21 telemetry + engine-health loop | PASS / FAIL | |

Decision: ELIGIBLE FOR TAG / BLOCKED
```

The decision is `BLOCKED` when any row fails, evidence is missing, a candidate
worktree is dirty, or the commit to tag differs from the recorded commit. After
a passing decision, continue with the
[semver-to-Kind handoff](../README.md#promote-a-passing-candidate-to-kind).

## Failure and cleanup

- Treat HTTP 429 as a finding, not pacing: the local limit is 50 req/s, so an
  audit row cannot reach it by hand.
- Treat a 401 on a private route as an EDGE question first:
  `docker compose logs --since 10m gateway` shows both the control plane's config
  load and Envoy's own output. A JWKS that was unreachable at boot, or an `iss`
  mismatch between the token and `gateway/eg/securitypolicy.yaml`, produces a
  fleet-wide 401 that looks exactly like a broken service.
- Treat an edge that answers 200 but produces no spans as a CONFIG failure, not a
  collector failure: `docker compose logs gateway 2>&1 | grep 'failed to find
  envoyproxy'` tells you the EnvoyProxy CR never attached, in which case tracing
  and the JSON access log were never configured at all.
- Treat telemetry lag as pending, not passing. Wait for the documented export
  window and rerun the query.
- Use `docker compose logs --since 10m <service>` to localize failures.
- **Every rerun starts with `docker compose down -v` + `up -d --build`.** There is
  no such thing as a partial rerun of this audit: the counters, span tables, and
  log streams that half of Phase C reads are cumulative, so a fix verified against
  a warm stack proves nothing about the candidate.
- Always close the named `agent-browser` session, including after a failed
  browser phase.
- If B2 failed part-way, confirm the client-level token lifespan override was
  restored before doing anything else — a 60s access token left on `customer-spa`
  makes unrelated rows fail in confusing ways.

## References

- [local-stack overview](../README.md)
- [Canonical API contracts](../../docs/api/README.md)
- [Application delivery](../../docs/platform/application-delivery.md)
- [Agent workflow](../../AGENTS.md#engineering-skills-workflow)

_Last updated: 2026-08-15 — realigns **Phase B** with the storefront rebuilt by
RFC-0025: the header's "Sign in" is a link to
`/login` carrying `?redirect=`, the sign-out control reads "Sign out", and the
storage assertion now names the legitimate residents (`theme`, and a
`checkoutIdemKey:<uuid>` during a checkout) while still failing on anything
JWT-shaped. B3 changes what it asserts, not how strictly: a private route after
sign-out renders a sign-in prompt **in place** rather than bouncing to `/login`,
so the row now checks the property that mattered — that no order data from the
previous session survives — instead of the redirect that used to carry it. A10
gains a spent-cap row: a promo whose redemptions are used up answers `409
PROMO_EXHAUSTED`, which it did not before checkout-service 0.7.1. The evidence
table's Phase A line said `A1–A14 + A16`, three rows behind the audit itself._

_Previously, 2026-08-12 — makes a from-scratch stack recreation mandatory for
every run and rewrites the two phases that had drifted from reality. **Phase B**
is rebuilt around the browser's real identity flow: the SPA has no credential
form, so B1 asserts the redirect to the realm's own login page, that no
JWT-shaped value exists in either web storage, and the realm claims of the token
actually in use; B2 observes the keycloak-js pre-emptive refresh inside a bounded
window using a temporary 60s client-level token lifespan; B3 asserts the
end-session GET redirect and that no service participates in sign-out. **Phase C**
grows from 6 rows to 19 so no telemetry leg is sampled by proxy — the edge span as
the trace root (with the derived `service.name` discovered at runtime), edge→service
trace continuity, per-service span coverage, spanmetrics, app semconv metrics,
Temporal SDK metrics, both VictoriaLogs ingest legs with the access-log
discriminator, log↔trace correlation, profiling, datasource health, and panels
actually returning data. A3/A4/A5 no longer carry "confirm on the first run"
placeholders: the `www-authenticate` challenge, realm family revocation, and
idempotent logout were measured and are asserted. A9 asserts its 201 and A12
asserts the outbox epoch against the workflow id instead of printing both.
The gate now runs against local-stack's post-auth-service end state: A6 asserts
the `auth` DATABASE is gone rather than a table inside it, A7 drops the retired
`auth/v1/public/login` alias, and the trace/profile coverage sets are the ten
remaining applications plus the edge (the cluster surface retires in RFC-0024 P5).
Preconditions carry the podman bring-up (`compose.podman.yaml` — resolved socket,
`userns_mode: keep-id`, `label=disable`) without which the Vector log leg is
silently absent. Envoy's admin and proxy Prometheus endpoints, and the collector's
unpublished gRPC receiver, are documented as out of scope with reasons so nothing
reads as forgotten._
