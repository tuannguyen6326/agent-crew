# slack-remote - Slack transport hooks for ac-remote.sh (setup guide)

Ready-made hook set that turns ONE Slack channel into the captain's remote order channel for ONE fleet home.
`remote-poll` fetches new captain messages (channel history plus registered threads) and emits them as JSON lines for `ac-remote.sh poll`.
`remote-reply` posts fleet replies into the right thread via `chat.postMessage`.
`remote-ack` (optional) walks a reaction lifecycle on each captain message - `:eyes:` the moment the fleet durably ingested it, `:gear:` when a task is linked to it, `:white_check_mark:` when the landing reply went out - so the captain sees where the order stands without asking.
With the reply hook wired, every task also gets its own channel thread: spawn announces the start, every room entry (gates, asks, decisions, landings) mirrors into it, and your replies in that thread come back as orders bound to that task (`config/remote-mirror=off` disables the mirror).
Each hook's header comment is its authoritative contract; this page is the setup guide.
Wire one fleet at a time - config lives per home, so two fleets use two channels (or two apps).

## Prerequisites

- A Slack workspace you administer (or can install apps into).
- The fleet home you are wiring (examples below use `~/Work/ac-homes/drydock`).
- `curl` and `jq` on the machine (already required by the distro toolchain).

## Slack-side steps (once per fleet)

1. Create the app: https://api.slack.com/apps -> Create New App -> From scratch -> name it after the fleet (e.g. `ac-drydock`) -> pick your workspace.
2. Grant scopes and install: OAuth & Permissions -> Bot Token Scopes -> add `channels:history`, `groups:history`, `chat:write`, `reactions:write` (the seen-receipt ack) -> Install to Workspace -> copy the bot token (`xoxb-...`).
3. Control channel: create or pick one (private works - that is what `groups:history` covers) and invite the bot: `/invite @<app-name>`.
4. Collect two ids:
   - Channel ID (`C...`): click the channel name -> channel details -> the ID is at the bottom.
   - Your member ID (`U...`): your profile -> the three-dots menu -> Copy member ID.
     Only messages authored by a listed member ID become orders - the filter is the ID, never the display name, so nobody can spoof it by renaming.
     Multiple ids are supported (`config/slack-captain-id`, one per line) and EVERY listed id is a full co-captain - its words are tier-1 orders; list only accounts you control or trust completely.

## Fleet-home steps

5. Write the config (the token stays out of git - `.env` is gitignored):

```bash
cd ~/Work/ac-homes/drydock
printf 'SLACK_BOT_TOKEN=xoxb-...\n' >> .env && chmod 600 .env
printf 'C0XXXXXXX\n' > config/slack-channel
printf 'U0XXXXXXX\n' > config/slack-captain-id           # one id per line; add more lines for co-captains
```

6. Copy the hook pair into place and make them executable (the poll slot and the drain ride-along key off `config/remote-poll` being EXECUTABLE):

```bash
cd ~/Work/agent-crew
cp docs/examples/slack-remote/remote-poll docs/examples/slack-remote/remote-reply \
   docs/examples/slack-remote/remote-ack ~/Work/ac-homes/drydock/config/
chmod +x ~/Work/ac-homes/drydock/config/remote-poll ~/Work/ac-homes/drydock/config/remote-reply \
         ~/Work/ac-homes/drydock/config/remote-ack
```

`remote-ack` is optional - skip the cp (or delete the file) and orders simply ingest without the reaction lifecycle.

7. Verify end to end: post a test message in the channel (from a listed captain account), then:

```bash
cd ~/Work/agent-crew && AC_HOME=~/Work/ac-homes/drydock bin/ac-remote.sh poll
```

One `remote-order sl-C...-...` line means the pipe is live.
To see the raw JSON instead, run `"$AC_HOME/config/remote-poll"` directly - any cwd works, only `AC_HOME` needs to be set.

## What happens after setup

- The lock-holding fleet watcher polls every `AC_REMOTE_POLL` seconds (default 300); scoped roomchief watchers never poll, so exactly one poller exists fleet-wide.
- A new captain message becomes a durable `remote-order <rid>` wake; the crewchief reads the order from disk (`ac-remote.sh show <rid>`) and runs the normal captain-word attribution ladder on it (the `remote-orders` skill owns the mechanics).
- Every decision is receipted `DECIDED:` to the family room AND echoed back into the Slack thread.
- Pending captain items (gates, asks) are pushed at wake-drain as ONE batched message per family thread; replying inside a family's thread binds your answer to that family mechanically.
- Tasks spawned from a remote order are linked (`ac-remote.sh link`) so their landing posts a follow-up into the thread that asked.
- Destructive confirmations (`--force` discard, repo deletion) are refused remotely - the fleet replies "answer in the terminal" (AGENTS.md section 8).

## Security notes

- Turn on 2FA for EVERY listed captain account: each member ID is a remote command key.
- The bot token can read the control channel and post as the fleet - treat it like a credential (`chmod 600 .env`; rotate it from the Slack app page if leaked).
- The token travels only inside a curl header file (0600, removed on exit), never in argv or command output.
- Remote message text is treated as untrusted everywhere: it never touches a shell unquoted, and only the slug-guarded rid ever becomes a filename.

## Troubleshooting

- `poll` prints nothing: no NEW captain-authored messages since the cursor; post again from a listed captain account (bot and unlisted-user messages are dropped by design).
- `remote-poll` exits 0 silently with nothing configured: intentional - the hook is inert until step 5 is done.
- `remote-reply` fails loudly on missing config: intentional - a gate answer must never vanish quietly.
- Re-read history from scratch: delete `state/.slack-cursor` (channel) or `state/remote-threads/<rid>.thread` (one thread); already-stashed rids dedup, but rids pruned by `gc` would re-arrive as new orders.
- Stranded orders (stashed but never woken, e.g. a crash mid-poll): `ac-remote.sh gc` lists them as `unwoken <rid>` advisories on stderr.
- Auth errors in `state/` logs: re-check the token scopes (private channel needs `groups:history`) and that the bot was invited to the channel.
