# Community policy lists (Draupnir / Mjolnir)

When **federation** is enabled, you should run a moderation bot (Draupnir or Mjolnir) and **subscribe to at least one community policy list** before considering the server fully federated. Policy lists are shared block/deny lists; subscribing protects your rooms from known bad actors.

**Order (no loop):** Enable federation → run Draupnir/Mjolnir → subscribe to list(s). You need federation enabled first so your server can reach the list servers.

## Recommended policy list rooms

| List | Room address | Description |
|------|----------------|-------------|
| **Community Moderation Effort (CME)** | `#community-moderation-effort-bl:neko.dev` | Spammers & scammers; trusted by Debian/Ubuntu; low false positives. |
| **Codestorm auto open reg (CS-open)** | `#cs-auto-open_reg:codestorm.net` | Servers with unsafe open registration (spam risk). Automated. |
| **Huginn/Muninn Active Threats (CAT)** | `#huginn-muninn-active-threats:feline.support` | Servers actively used in attacks; manually checked. |
| **Matrix.org Code of Conduct** | `#matrix-org-coc-bl:matrix.org` | matrix.org CoC violations (spam, trolls, abuse). |

Ref: [Asgard.Chat – Subscribing to policy lists](https://asgard.chat/draupnir/subscribe-to-policy-lists.html), [Matrix.org community moderation](https://matrix.org/docs/communities/moderation).

## Subscribe (Draupnir)

In the **Draupnir management room**, send:

```
!draupnir watch #community-moderation-effort-bl:neko.dev
```

Repeat for other lists. To subscribe via script (e.g. after install), use `subscribe-draupnir-community-lists.sh` with admin token and management room ID.

## Subscribe (Mjolnir)

In the **Mjolnir management room**, send:

```
!mjolnir watch #community-moderation-effort-bl:neko.dev
```

## Default list for installers

The install script and k8s-qa use **CME** (`#community-moderation-effort-bl:neko.dev`) as the default first subscription when federation + Draupnir/Mjolnir are enabled.
