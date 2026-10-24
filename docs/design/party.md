# Parties (design + status)

User request: "join a group with my kids, and when we are all readied up the leader could hit go and it would toss us into the
dedicated server". A party is a small, short-lived group of pilots. They see each other's ready state and operator summary, chat,
and the leader picks where they go. When everybody is ready the leader presses Go and every member's client connects to that
game server; the server keeps the party together. Afterwards the members return to the party screen.

Status markers: **[built]** built and tested, **[later]** designed, not built.

## 1. Model

- A party has a **code** (5 characters of `ABCDEFGHJKMNPQRSTUVWXYZ23456789`: no 0/O, 1/I/L), a **leader**, up to 8 **members**
  (name, ready flag, operator summary line, "away on a raid" flag), a **destination** (address, name, mode, map and, for a password
  server, the password) and a short **chat**. Nothing else; no accounts, no stored history. **[built]**
- Everything is kept **in memory** by a party service and forgotten: a member who has not asked for 3 minutes (his PC may stand still
  for a minute while it builds a big map), a party nobody touched for 30 min. The leader leaving hands the lead to the oldest member. Names are what the pilots typed (clean text, 24 characters).
- A member is known by a random key only he and the service know (a way to tell members apart, not a password: whoever knows the code
  can join; keep the code among friends). A password of the destination server is shared with the members through the service; do
  not use a password you use elsewhere.

## 2. The party service (`PartyRegistry`, pure logic) and its two homes

`engine/online/party_registry.gd` implements the API (POST, JSON, every answer is the member's view of the party):
`/party/create`, `/party/join`, `/party/state` (the poll, once a second), `/party/ready`, `/party/summary`, `/party/destination`
(leader), `/party/go` (leader; refused unless a destination is chosen and every member is ready), `/party/say`, `/party/back` (a member
is back from the raid), `/party/kick` (leader), `/party/leave`. Limits: 256 parties, 12 per creating address, bodies up to 2 KB,
900 requests per address per minute (a household of kids polls once a second each). **[built]**

1. **Online: the master server** (`MasterServer`, `POST /party/...`, no change to the game-list routes; `party_rate_limit` and `max_parties`
   in `master.json`). Players set the master's address in Options > Online. **[built]**
2. **LAN: the leader's PC** (`PartyLanHost`): the same service on TCP 47703, one party, and a UDP broadcast every second on the LAN
   discovery port 47701 (`{proto: "siege-engine-party/1", code, name, members, max, port}`), which the other PCs collect in `Net.parties`
   and list on the party screen; one click joins, or type the code and the leader's address. The host is a node of the scene root
   (`PartySession`), so it keeps serving while the leader is in a raid. **[built]**

## 3. The party screen (`PartyScreen`, Play tab > Party) **[built]**

Built on the standard lobby look (ScreenFrame, Widgets, the lobby chat's look), with mouse, keyboard and gamepad (every control is a
focusable button/field of the frame's focus chain; Back = `menu_back`).

- **No party yet**: Create online party (needs the master address), Create LAN party, Join by code (online) or from the LAN list /
  the leader's address (LAN).
- **In a party**: the members (name, LEADER mark, READY / not ready / away on a raid, the operator summary: armour, kit, credits;
  the leader has Remove), Operator Setup... (the stash and the raid kit, then the summary is sent again), Leave party, the chat, and the
  **destination**: the leader picks a server from the LAN games, the online games (master list) or a typed address (`ServerPicker`,
  the lists of the Join browser); the others see it. The footer: members get Ready / Not ready, the leader gets **Go** (enabled when
  everybody is ready and a destination is chosen; the line above says who is missing).

## 4. Go (`PartyFlow`) **[built]**

The service answers Go by increasing the party's Go counter and putting the destination in it; every member's poll sees it, so every
client (the leader's too) starts `PartyFlow`: join the address (ENet, or `ws://`), wait for the roster entry, announce the operator's
build and raid kit like the lobby does (`LobbyAnnouncer.make_fields`) plus `party: {id: code, size: members}` and `ready: true`, and wait for
the server to start the game. Nobody sees the server's lobby (`Launcher` skips it while `PartySession.is_joining`). The party screen
shows the progress and a Cancel; a refusal (password, full, version) or a timeout is shown there and the member stays in the party.

**The server keeps the party together** (the roster key `party`, `PartyRoster`):
- versus and co-op (the lobby server): one team (`MatchFlow.apply_free_for_all_teams`, `TeamAssignment.make_assign_all`: the rest of
  a party joins the team of the first member);
- extraction (`RaidServer`): one team (`RaidTeams`, so teammates can revive each other), and one drop-in: the server waits until every member
  who is connected has built the battle (and up to `party_wait_seconds` for members who have not connected yet), then all soldiers are spawned and
  flown in on the **same transport**.

## 5. After the raid **[built]**

A raid on an extraction server ends for each pilot when he extracts or is killed: his banner, then `RaidResultExit` leaves the server
and opens the results screen; Continue opens the **party screen** (the launcher sees `PartySession.on_trip`) and tells the service the
member is back (`/party/back`: the "away" mark goes, the ready flag is cleared). A match on a lobby server (versus, co-op) ends on
the usual results screen; Continue also goes back to the party (the pilot leaves the server's lobby quietly). The party survives
the whole time: the client polls from the scene root.

## 6. Limits and ideas **[later]**

- A party cannot move between services (an online party stays on its master, a LAN party on its leader's PC; the leader of a LAN
  party closing the game ends the party for everybody).
- No invitations from a friends list; the code is the invitation.
- A party Go to a lobby server whose match is running is refused ("Game already in progress"); the leader presses Go again later.
- The LAN host needs TCP 47703 reachable on the leader's PC (a firewall prompt on first use).

## 7. Code and tests

| code | role |
|---|---|
| `engine/online/party_registry.gd` | the service (rules, limits, expiry) |
| `engine/online/master_server.gd` | online home (routes `/party/*`) |
| `engine/online/party_lan_host.gd` | LAN home (HTTP + broadcast) |
| `engine/online/party_client.gd`, `party_session.gd`, `party_flow.gd`, `party_roster.gd` | the member's side, Go, the roster key |
| `engine/ui/screens/party_screen.gd`, `ui/party_member_list.gd`, `ui/party_chat_strip.gd`, `ui/server_picker.gd` | the screen |
| `engine/extraction/raid_teams.gd`, `game/server/raid_server.gd` | the server keeps the party together |

Tests: `tests/party_registry_check.tscn` (the service's rules without sockets, the master's party routes and their rate limit, how a
party stays on one team); `tests/party_check.tscn` (a master, a dedicated extraction server and client processes that use the real
launcher's party screen: create and join by code online and over the LAN, chat, ready, the leader's Go moves the members onto one server in
one squad on one transport, results, and back to the party screen).
