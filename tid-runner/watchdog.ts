// tid-runner/watchdog.ts — TID-3.3 independent watchdog.
// Runs on its own schedule, separate from the runner. Calls tid.hb_check and exits non-zero when there is
// a new finding (or when it cannot reach the database at all), so the workflow fails and alerts.
//
// Usage: deno run -A watchdog.ts [--canary]
// Env:   DATABASE_URL (required), WATCHDOG_NAME (default "github-actions"), ALERT_FILE (optional path; a
//        Markdown alert body is written there when the exit code is non-zero)

import postgres from "npm:postgres@3.4.4";

const canary = Deno.args.includes("--canary");
const alertFile = Deno.env.get("ALERT_FILE");
const checker = Deno.env.get("WATCHDOG_NAME") ?? "github-actions";

async function alert(title: string, lines: string[]) {
  const body = [`## ${title}`, "", ...lines, "", `Checked at ${new Date().toISOString()} by \`${checker}\`.`].join("\n");
  console.log(body);
  if (alertFile) await Deno.writeTextFile(alertFile, body);
}

let code = 0;
const url = Deno.env.get("DATABASE_URL");
if (!url) {
  await alert("TID watchdog cannot run", ["`DATABASE_URL` is not set for the watchdog."]);
  Deno.exit(2);
}
const sql = postgres(url, { max: 1, prepare: false, onnotice: () => {}, connect_timeout: 20 });
try {
  const r = (await sql`select tid.hb_check(${checker}::text, ${canary}::boolean) as r`)[0].r;
  const fresh = r.new_findings as Array<Record<string, unknown>>;
  console.log(`watchdog_run_id=${r.watchdog_run_id} days=${JSON.stringify(r.checked_days)} findings=${r.findings.length} new=${fresh.length}`);
  if (fresh.length) {
    code = 1;
    const lines = fresh.map((f) => {
      switch (f.code) {
        case "canary": return `- **Canary test alert.** If you are reading this, alerts reach you. Record it with:\n  \`select tid.hb_ack_canary(${r.watchdog_run_id}, 'github', 'received');\``;
        case "scan_missing": return `- **${f.scan_type}** scan for ${f.session}: no run at all by ${f.deadline_et} ET.`;
        case "scan_incomplete": return `- **${f.scan_type}** scan for ${f.session}: runs exist but none completed by ${f.deadline_et} ET (statuses: ${f.statuses}).`;
        case "snapshots_off": return `- **${f.scan_type}** scan for ${f.session}: completed without TID-3.2 snapshots.`;
        default: return `- ${JSON.stringify(f)}`;
      }
    });
    await alert(canary ? `TID canary alert (watchdog run ${r.watchdog_run_id})` : `TID watchdog: ${fresh.length} new finding(s)`, lines);
  }
} catch (e) {
  code = 1;
  await alert("TID watchdog could not complete its check", ["The database check itself failed:", "", "```", String((e as Error).message), "```"]);
} finally {
  await sql.end({ timeout: 5 });
}
Deno.exit(code);
