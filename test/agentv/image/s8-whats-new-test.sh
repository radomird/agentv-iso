#!/bin/bash
#
# What's new and new episodes on an installed box (stage 8, S8.1, S8.2),
# with a stand-in for TMDB. Two stand-in streaming apps, Kino and Lumen, are
# the household's services, so no real one is named. The TMDB key goes to
# root the way Settings → what's new keeps it, and only the router's
# service reads it: the stand-in sees it, the person's account can't. Then
# what's new for the box's region is this week's titles on those two, and
# home's New this week shows them, a new episode is yes with the next air
# date, both again from a sentence
# through a stand-in for Anthropic's API, and agentv selftest S8.1 and S8.2
# pass. The journal has neither the key nor the show that was asked about.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/test/integration.d/base-test.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tv.sh"

base_image_ready || { echo "No base image; run ./test/integration first" >&2; exit 1; }

MARK="s8check$RANDOM$RANDOM"
TOKEN="eyJhbGciOiJIUzI1NiJ9.agentv-image-check.$MARK"
TMDB_PORT=8778
ROUTER_PORT=8777
DROPINS=/run/systemd/system

start_vm_from_base
wait_for_ssh 300 failure-S8-ssh-timeout || exit 1
wait_tv 240 >/dev/null || true
passwordless_sudo
guest "agentv setup skip" >"$RUN_DIR/setup.log" 2>&1 || true
sleep 3

# --- The household's services: two stand-in streaming apps -----------------

for pair in kino:Kino lumen:Lumen; do
  id=${pair%%:*}
  name=${pair#*:}
  ssh_guest "rm -rf /tmp/$id && mkdir -p /tmp/$id && cat >/tmp/$id/manifest.json" <<MANIFEST
{
  "schemaVersion": 1,
  "id": "local.$id",
  "name": "$name",
  "version": "1.0.0",
  "author": "your agent",
  "license": "MIT",
  "description": "A stand-in streaming service for stage 8's image check",
  "kinds": ["tv-app"],
  "entryPoints": { "tvApp": "app.ts" },
  "tv": { "contract": 1, "category": "streaming", "runtime": "web", "homeUrl": "https://$id.test/", "capabilities": ["launch"], "origins": ["https://$id.test"], "childSafe": false }
}
MANIFEST
  ssh_guest "cat >/tmp/$id/app.ts" <<APP
const app = {
  id: "local.$id",
  async launch(ctx: { page?: { goto(url: string): Promise<unknown> } }) {
    await ctx.page?.goto("https://$id.test/");
  },
};
export default app;
APP
  ssh_sudo "agentv app install --local /tmp/$id --yes" >"$RUN_DIR/install-$id.log" 2>&1 || true
done
check "the two stand-in services install as the box's apps" ssh_guest "agentv app list | grep -q local.kino && agentv app list | grep -q local.lumen"

# --- A stand-in for TMDB, behind the router's service --------------------------

# It answers the few paths the box asks for, with this week's dates on the
# box's own clock, and keeps the key it was sent.
ssh_guest "cat >/tmp/tmdb-standin.mjs" <<'STANDIN'
import { createServer } from "node:http";
import { writeFileSync } from "node:fs";
const pad = (n) => String(n).padStart(2, "0");
const day = (n) => { const d = new Date(); d.setDate(d.getDate() + n); return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`; };
const answer = (response, data) => { response.writeHead(200, { "Content-Type": "application/json" }); response.end(JSON.stringify(data)); };
createServer((request, response) => {
  writeFileSync("/tmp/tmdb-standin-auth", String(request.headers.authorization ?? ""));
  const url = new URL(request.url, "http://standin");
  const q = url.searchParams;
  const path = url.pathname.replace(/^\/3/, "");
  const on = q.get("with_watch_providers") ?? "";
  if (path.startsWith("/watch/providers/")) return answer(response, { results: [{ provider_id: 901, provider_name: "Kino" }, { provider_id: 902, provider_name: "Lumen" }] });
  if (path === "/discover/movie") {
    if (on === "901" && q.has("with_release_type")) return answer(response, { results: [{ id: 101, title: "Night Train", release_date: day(-40), popularity: 80, poster_path: "/night.jpg" }] });
    if (on === "902" && q.has("primary_release_date.gte")) return answer(response, { results: [{ id: 103, title: "Small Hours", release_date: day(-2), popularity: 30, poster_path: "/small.jpg" }] });
    return answer(response, { results: [] });
  }
  if (path === "/discover/tv") {
    if (on === "901" && q.has("first_air_date.gte")) return answer(response, { results: [{ id: 201, name: "The Long Field", first_air_date: day(-3), popularity: 60, poster_path: "/field.jpg" }] });
    if (on === "902" && q.has("air_date.gte")) return answer(response, { results: [{ id: 202, name: "Copper Hill", first_air_date: "2022-05-05", popularity: 70, poster_path: "/copper.jpg" }] });
    return answer(response, { results: [] });
  }
  if (path === "/search/tv") return answer(response, { results: /copper/i.test(q.get("query") ?? "") ? [{ id: 202, name: "Copper Hill", first_air_date: "2022-05-05", popularity: 70 }] : [] });
  if (path === "/tv/202") return answer(response, { id: 202, name: "Copper Hill", status: "Returning Series", last_episode_to_air: { season_number: 3, episode_number: 1, air_date: day(-4) }, next_episode_to_air: { season_number: 3, episode_number: 2, air_date: day(3) }, seasons: [{ season_number: 2, air_date: "2024-04-01", episode_count: 8 }, { season_number: 3, air_date: day(-4), episode_count: 8 }] });
  response.writeHead(404, { "Content-Type": "application/json" });
  response.end(JSON.stringify({ status_message: "The resource you requested could not be found." }));
}).listen(Number(process.argv[2]), "127.0.0.1");
STANDIN
ssh_guest "nohup node /tmp/tmdb-standin.mjs $TMDB_PORT >/tmp/tmdb-standin.log 2>&1 </dev/null & disown" || true
ssh_guest "sudo mkdir -p $DROPINS/agentv-router.service.d && printf '[Service]\nEnvironment=AGENTV_TMDB_UPSTREAM=http://127.0.0.1:$TMDB_PORT/3\nEnvironment=AGENTV_ROUTER_UPSTREAM=http://127.0.0.1:$ROUTER_PORT\n' | sudo tee $DROPINS/agentv-router.service.d/standin.conf >/dev/null && sudo systemctl daemon-reload && sudo systemctl restart agentv-router.service"
today=$(ssh_guest "date +%F")
next=$(ssh_guest "date -d '+3 days' +%F")
# api <method> <path> <body or ""> <name>: the daemon's answer in <name>.json.
# A body goes on stdin, so its quotes never meet the shell's.
api() {
  if [[ -n $3 ]]; then
    ssh_guest "curl -sS --max-time 120 -X $1 -H 'Content-Type: application/json' --data-binary @- 'http://127.0.0.1:3000$2'" <<<"$3" >"$RUN_DIR/$4.json" 2>&1 || true
  else
    ssh_guest "curl -sS --max-time 120 -X $1 'http://127.0.0.1:3000$2'" >"$RUN_DIR/$4.json" 2>&1 || true
  fi
}

# --- The key, as Settings → what's new keeps it -----------------------------------

# TMDB's region: the box's country on a release that has it (ADR-055), as
# Settings → country picks it, and Settings → what's new's own before that.
api PUT /api/country '{"code":"NL"}' region
if jq -e '.code == "NL"' "$RUN_DIR/region.json" >/dev/null 2>&1; then
  check "Settings → country keeps NL, and the time zone follows it" jq -e '.code == "NL" and .zone == "Europe/Amsterdam"' "$RUN_DIR/region.json"
else
  api PUT /api/whats-new/settings '{"region":"NL"}' region
  check "Settings → what's new keeps a region" jq -e '.region == "NL"' "$RUN_DIR/region.json"
fi
api GET /api/whats-new "" no-key
check "with no TMDB key yet, what's new says so" jq -e '.feed.ok == false and .feed.why == "no-key"' "$RUN_DIR/no-key.json"
api PUT /api/tmdb-key "{\"key\":\"$TOKEN\"}" key
check "a TMDB key is kept, as Settings → what's new keeps it" jq -e '.key.set == true' "$RUN_DIR/key.json"
check "it's in the env file, root's alone" ssh_sudo "test \"\$(stat -c '%U %a' /etc/agentv/env)\" = 'root 600' && grep -qx 'TMDB_API_KEY=$TOKEN' /etc/agentv/env"
cant_read() { ! ssh_guest "cat /etc/agentv/env" >/dev/null 2>&1; }
check "the person's account can't read it" cant_read
check "tmdb.json says there's one, with no key in it" ssh_guest "jq -e '.set == true' /etc/agentv/tmdb.json >/dev/null && ! grep -q '$MARK' /etc/agentv/tmdb.json"
check "and the household's apps are matched to TMDB's services by name" jq -e '[.services[] | "\(.name)=\(.providers | map(.id) | join("|"))"] == ["Kino=901", "Lumen=902"]' "$RUN_DIR/key.json"
sleep 2

# --- S8.1 ---------------------------------------------------------------------------

api GET "/api/whats-new?fresh=1" "" feed
check "S8.1 what's new is this week's titles on the household's services" \
  jq -e '[.feed.titles[] | "\(.title) on \(.app)\(if .season then " s\(.season)" else "" end)"] == ["Night Train on local.kino", "Copper Hill on local.lumen s3", "The Long Field on local.kino", "Small Hours on local.lumen"]' "$RUN_DIR/feed.json"
# shellcheck disable=SC2016 # $today is jq's own variable
check "S8.1 for the box's region, from this week" jq -e --arg today "$today" '.feed.region == "NL" and .feed.to == $today' "$RUN_DIR/feed.json"
check "S8.1 with TMDB's posters" jq -e '.feed.titles[0].poster == "https://image.tmdb.org/t/p/w342/night.jpg"' "$RUN_DIR/feed.json"
check "the key reached TMDB, through the router's service" ssh_guest "grep -qx 'Bearer $TOKEN' /tmp/tmdb-standin-auth"

# --- S8.1 on home: New this week, large, with this week's titles ------------------

# Home with New this week in it, large, as a streaming household's has it.
ssh_guest "curl -fsS -X PUT -H 'Content-Type: application/json' -d '{\"layout\":[{\"id\":\"agentv.clock\",\"x\":0,\"y\":0,\"size\":\"s\"},{\"id\":\"agentv.new\",\"x\":1,\"y\":0,\"size\":\"l\"},{\"id\":\"apps\",\"x\":3,\"y\":0,\"size\":\"s\"}]}' http://127.0.0.1:3000/api/layout" >"$RUN_DIR/layout.json" 2>&1 || true
guest "agentv screen home" >/dev/null 2>&1 || true
api GET /api/tile/agentv.new/l "" tile
check "S8.1 New this week's tile has this week's titles, each with its app and TMDB's poster" \
  jq -e '[.tile.entries[] | "\(.label) \(.caption)"][:2] == ["night train kino", "copper hill lumen · season 3"] and (.tile.entries[0].image | startswith("https://image.tmdb.org/"))' "$RUN_DIR/tile.json"
check "S8.1 home's top rail shows a title new this week on one of the household's services (OCR)" ocr_finds success-s8-rail "night train" 60
check "S8.1 with TMDB's and JustWatch's credit under it (OCR)" grep -Eqi "justwatch|tmdb" "$RUN_DIR/success-s8-rail.txt"

# --- S8.2 ---------------------------------------------------------------------------

api POST /api/whats-new/episode '{"query":"copper hill"}' episode
# shellcheck disable=SC2016 # $next is jq's own variable
check "S8.2 a new episode of a running show is yes, with the next air date" \
  jq -e --arg next "$next" '.answer.yes == true and .answer.next.date == $next and (.answer.say | startswith("yes: copper hill s3 e1 came out"))' "$RUN_DIR/episode.json"

# --- Both from a sentence, through a stand-in for Anthropic's API --------------------

ssh_guest "cat >/tmp/router-standin.mjs" <<'STANDIN'
import { createServer } from "node:http";
const none = { intent: "none", query: null, kind: null, app: null, season: null, episode: null };
createServer(async (request, response) => {
  let body = "";
  for await (const chunk of request) body += chunk;
  const said = String(JSON.parse(body || "{}").messages?.[0]?.content ?? "");
  const route = said.includes("what's new") ? { ...none, intent: "whats_new" } : said.includes("new episode") ? { ...none, intent: "new_episode", query: "Copper Hill" } : none;
  response.writeHead(200, { "Content-Type": "application/json" });
  response.end(JSON.stringify({ type: "message", content: [{ type: "text", text: JSON.stringify(route) }], stop_reason: "end_turn", usage: { input_tokens: 1500, output_tokens: 40 } }));
}).listen(Number(process.argv[2]), "127.0.0.1");
STANDIN
ssh_guest "nohup node /tmp/router-standin.mjs $ROUTER_PORT >/tmp/router-standin.log 2>&1 </dev/null & disown" || true
KEY="sk-ant-api03-agentvwhatsnew$(printf '0%.0s' {1..30})"
code=$(ssh_guest "curl -fsS -X POST http://127.0.0.1:3000/api/phones/pair" 2>/dev/null | jq -r '.pairing.code // empty')
phone=$(ssh_guest "curl -fsS -H 'Content-Type: application/json' -d '{\"code\": \"$code\", \"name\": \"image check\"}' http://127.0.0.1:3001/api/phone/pair" 2>/dev/null | jq -r '.token // empty')
# The key asks for Anthropic's terms first, which an adult accepts on a
# phone (Q104), then it's kept.
api PUT /api/key "{\"provider\":\"claude\",\"key\":\"$KEY\"}" provider-key-asked
ssh_guest "curl -fsS -H 'Authorization: Bearer $phone' -H 'Content-Type: application/json' -d '{\"provider\": \"claude\", \"path\": \"key\"}' http://127.0.0.1:3001/api/phone/terms" >/dev/null 2>&1 || true
api PUT /api/key "{\"provider\":\"claude\",\"key\":\"$KEY\"}" provider-key
check "a key for claude is kept for the router" jq -e '.set == true and .provider == "claude"' "$RUN_DIR/provider-key.json"
sleep 3
api POST /api/say '{"sentence":"what'"'"'s new this week"}' said-new
check "S8.1 what's new from a sentence says this week's top three and offers them" \
  jq -e '.said.outcome.kind == "choose" and .said.outcome.say == "new this week: night train, copper hill, season 3 and the long field" and ([.said.outcome.candidates[].name] == ["Kino", "Lumen", "Kino"])' "$RUN_DIR/said-new.json"
api POST /api/say '{"sentence":"is there a new episode of copper hill"}' said-episode
check "S8.2 a new episode from a sentence is told, yes with the next air date" \
  jq -e '.said.outcome.kind == "told" and (.said.outcome.say | startswith("yes: copper hill s3 e1 came out")) and (.said.outcome.say | contains("the next is s3 e2"))' "$RUN_DIR/said-episode.json"

guest "agentv selftest S8.1 S8.2 --show 'Copper Hill'" >"$RUN_DIR/selftest.log" 2>&1 || true
cat "$RUN_DIR/selftest.log"
check "agentv selftest S8.1 passes" grep -q '^pass S8.1 4 titles new on Kino, Lumen in NL' "$RUN_DIR/selftest.log"
check "agentv selftest S8.2 passes" grep -q '^pass S8.2 yes: copper hill s3 e1 came out' "$RUN_DIR/selftest.log"

ssh_sudo "journalctl -b --no-pager -u agentv-daemon -u agentv-router -u agentv-key" >"$RUN_DIR/journal.log" 2>&1 || true
not_logged() {
  grep -q "tmdb /discover/movie: 200" "$RUN_DIR/journal.log" && grep -q "tmdb /tv/:id: 200" "$RUN_DIR/journal.log" &&
    ! grep -q -e "$MARK" -e "$KEY" -i -e "copper" "$RUN_DIR/journal.log"
}
check "the journal says which of TMDB's paths were asked, and never the key or the show" not_logged

ssh_guest "sudo rm -f '${DROPINS:?}/agentv-router.service.d/standin.conf' && sudo systemctl daemon-reload; pkill -f tmdb-standin.mjs; pkill -f router-standin.mjs" || true
stop_vm
finish
