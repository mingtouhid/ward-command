import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import vm from "node:vm";

const html = readFileSync(new URL("../index.html", import.meta.url), "utf8");
const start = html.indexOf("/* R17_RULES_START */");
const end = html.indexOf("/* R17_RULES_END */");

function loadRules() {
  assert.ok(start >= 0 && end > start, "R17 rules block missing from index.html");
  const context = {};
  vm.createContext(context);
  vm.runInContext(html.slice(start, end), context, { filename: "r17-rules.js" });
  return context;
}

const R = loadRules();

const admit = "2026-11-01T02:30:00.000Z"; // 08:00 IST 1 Nov
const today = "2026-11-07";
const todayMorning = "2026-11-07T03:30:00.000Z"; // 09:00 IST
const yesterday = "2026-11-06T03:30:00.000Z";

test("IST day rolls at 00:00 IST, not UTC midnight", () => {
  assert.equal(R.r17IstDay("2026-11-06T18:29:00.000Z"), "2026-11-06");
  assert.equal(R.r17IstDay("2026-11-06T18:30:00.000Z"), "2026-11-07");
  assert.match(R.r17IstWhen("2026-11-07T04:11:00.000Z"), /09:41/);
});

test("server-saved vitals from any intern complete once; queued and failed do not", () => {
  const patient = { id: "p1", name: "A. Sample", status: "admitted", admittedAt: admit, bed: "M-01" };
  const other = { id: "p2", name: "B. Sample", status: "admitted", admittedAt: admit, bed: "M-02" };
  const third = { id: "p3", name: "C. Sample", status: "admitted", admittedAt: admit, bed: "F-01" };
  const vitals = [
    { id: "v1", pid: "p1", at: todayMorning, by: "i2", byName: "Intern Two" },
    { id: "v1b", pid: "p1", at: "2026-11-07T04:00:00.000Z", by: "i1", byName: "Intern One" },
    { id: "v2", pid: "p2", at: todayMorning, by: "i1", byName: "Intern One" },
    { id: "v3", pid: "p3", at: todayMorning, by: "i1", byName: "Intern One" },
    { id: "old", pid: "p1", at: yesterday, by: "i9", byName: "Prior Intern" },
    { id: "pre", pid: "p1", at: "2026-10-20T03:30:00.000Z", by: "i9", byName: "Old Stay" }
  ];
  const ops = [
    { table: "patient_vitals", status: "pending", row: { id: "v2" } },
    { table: "patient_vitals", status: "failed", row: { id: "v3" } },
    { table: "patient_vitals", status: "acked", row: { id: "v1" } }
  ];
  const board = R.r17VitalsBoard([patient, other, third], vitals, ops, today);
  assert.equal(board.completed, 1);
  assert.equal(board.remaining, 2);
  assert.equal(board.saving, 1);
  assert.equal(board.failed, 1);
  assert.equal(board.rows[0].state === "completed", false);
  assert.equal(board.rows[board.rows.length - 1].pid, "p1");
  assert.equal(board.rows.find((r) => r.pid === "p1").by, "Intern One");
  const html = R.r17InternVitalsHtml(board);
  assert.match(html, /Completed <b>1<\/b>/);
  assert.match(html, /Remaining <b>2<\/b>/);
  assert.match(html, /Saving 1/);
  assert.match(html, /Failed 1/);
  assert.ok(html.indexOf('data-pid="p2"') < html.indexOf('data-pid="p1"'));
  assert.match(html, /Record vitals/);
  assert.equal((html.match(/Record vitals/g) || []).length, 2);
});

test("next IST day clears yesterday's saved vitals", () => {
  const patient = { id: "p1", name: "A. Sample", status: "admitted", admittedAt: admit, bed: "M-01" };
  const vitals = [{ id: "v1", pid: "p1", at: todayMorning, byName: "Intern One" }];
  const next = R.r17VitalsBoard([patient], vitals, [], "2026-11-08");
  assert.equal(next.completed, 0);
  assert.equal(next.remaining, 1);
  assert.equal(next.rows[0].state, "remaining");
});

test("discharge review uses this admission only and ignores prepared MSE unless atomic", () => {
  const patient = { id: "p1", admittedAt: admit, status: "admitted" };
  const mses = [
    { id: "old", pid: "p1", at: "2026-10-01T04:00:00.000Z", deleted: false },
    { id: "gone", pid: "p1", at: "2026-11-06T04:00:00.000Z", deleted: true },
    { id: "early", pid: "p1", at: "2026-11-02T04:00:00.000Z", deleted: false }
  ];
  const reports = [
    { id: "r-old", pid: "p1", at: "2026-10-02T04:00:00.000Z", reportedAt: "2026-10-02T04:00:00.000Z", deleted: false },
    { id: "r-del", pid: "p1", at: todayMorning, reportedAt: todayMorning, deleted: true }
  ];
  const missing = R.r17DischargeReview(patient, mses, reports, { stagedMse: { data: true }, stagedAtomic: false });
  assert.deepEqual([...missing.missing], ["report"]);
  assert.equal(missing.hasMse, true);
  assert.equal(missing.hasReport, false);
  assert.equal(missing.latestMseId, "early");
  assert.equal(missing.latestReportWhy, "deleted");
  assert.equal(missing.investigationsComplete, false);
  assert.equal(missing.stagedPrepared, true);
  const lines = R.r17WarnLines(missing);
  assert.match(lines.join("\n"), /does not mean every investigation is complete/);
  assert.match(lines.join("\n"), /not saved yet|counts only if it is saved with the discharge/);
  const none = R.r17DischargeReview(patient, [{ id: "old", pid: "p1", at: "2026-10-01T04:00:00.000Z" }], [], {});
  assert.deepEqual([...none.missing].sort(), ["mse", "report"]);
  assert.equal(none.latestMseWhy, "prior");
  const queued = R.r17DischargeReview(patient, [{ id: "q", pid: "p1", at: todayMorning }], [{ id: "rq", pid: "p1", at: todayMorning, reportedAt: todayMorning }], {
    ops: [{ table: "mse_entries", status: "pending", row: { id: "q" } }, { table: "lab_reports", status: "retrying", row: { id: "rq" } }]
  });
  assert.equal(queued.hasMse, false);
  assert.equal(queued.hasReport, false);
  const atomic = R.r17DischargeReview(patient, [], [], { stagedMse: { data: true }, stagedAtomic: true });
  assert.equal(atomic.hasMse, true);
  assert.equal(atomic.stagedPrepared, false);
  const html = R.r17DischargeWarnHtml(missing);
  for (const label of ["Update MSE", "Review or add reports", "Continue discharge", "Cancel"]) {
    assert.match(html, new RegExp(label));
  }
});

test("override fingerprint changes when the eligible records change", () => {
  const patient = { id: "p1", admittedAt: admit };
  const a = R.r17DischargeReview(patient, [], [], {});
  a.pid = "p1";
  const b = R.r17DischargeReview(patient, [{ id: "m", pid: "p1", at: todayMorning }], [], {});
  b.pid = "p1";
  assert.notEqual(R.r17ReviewFingerprint(a), R.r17ReviewFingerprint(b));
  assert.equal(R.r17OverrideMatches({ pid: "p1", reason: "Needed for transfer", fp: R.r17ReviewFingerprint(a) }, a), true);
  assert.equal(R.r17OverrideMatches({ pid: "p1", reason: "Needed for transfer", fp: R.r17ReviewFingerprint(a) }, b), false);
  assert.equal(R.r17OverrideMatches({ pid: "p1", reason: "no", fp: R.r17ReviewFingerprint(a) }, a), false);
});

test("report tasks link only a saved current-admission report; general tasks are explicit", () => {
  const patient = { id: "p1", admittedAt: admit };
  const reportTask = { id: "t1", pid: "p1", kind: "report", status: "open", dueOn: "2026-11-07" };
  const general = { id: "t2", pid: "p1", kind: "general", status: "open", dueOn: "2026-11-07" };
  const saved = { id: "lab1", pid: "p1", at: todayMorning, reportedAt: todayMorning, deleted: false };
  assert.equal(R.r17ReportCanLink(reportTask, saved, patient, []), true);
  assert.equal(R.r17ReportCanLink(reportTask, { ...saved, deleted: true }, patient, []), false);
  assert.equal(R.r17ReportCanLink(reportTask, { ...saved, reportedAt: "2026-10-01T04:00:00.000Z", at: "2026-10-01T04:00:00.000Z" }, patient, []), false);
  assert.equal(R.r17ReportCanLink(reportTask, saved, patient, [{ table: "lab_reports", status: "pending", row: { id: "lab1" } }]), false);
  assert.equal(R.r17ReportCanLink(general, saved, patient, []), false);
  assert.equal(R.r17GeneralComplete(reportTask, { id: "i1", role: "intern" }).ok, false);
  assert.equal(R.r17GeneralComplete(general, { id: "i1", role: "intern" }).ok, true);
  assert.equal(R.r17GeneralComplete(general, { id: "r1", role: "resident" }).ok, false);
  const again = R.r17GeneralComplete({ ...general, status: "done", completedBy: "i1" }, { id: "i2", role: "intern" });
  assert.equal(again.ok, true);
  assert.equal(again.idempotent, true);
  assert.equal(R.r17GeneralUndo({ ...general, status: "done", completedBy: "i1" }, { id: "i1", role: "intern" }).ok, true);
  assert.equal(R.r17GeneralUndo({ ...general, status: "done", completedBy: "i1" }, { id: "i2", role: "intern" }).ok, false);
  assert.equal(R.r17GeneralUndo({ ...general, status: "done", completedBy: "i1" }, { id: "r1", role: "resident" }).ok, true);
  const html = R.r17InternTasksHtml([reportTask, { ...general, status: "done", completedByName: "Intern One" }]);
  assert.equal((html.match(/Mark complete/g) || []).length, 0);
  assert.match(html, /saved report for this admission is linked/);
  assert.match(html, /Undo/);
});

test("scheduled ECT completion does not schedule the next session and is idempotent", () => {
  const plan = { id: "e1", pid: "p1", status: "planned", nextAt: todayMorning, sessionsDone: 3, npo: true };
  const patient = { id: "p1", status: "admitted", admittedAt: admit, bed: "M-04" };
  const first = R.r17EctDecide(plan, patient, { id: "r1", role: "resident" }, []);
  assert.equal(first.ok, true);
  assert.equal(first.scheduleNext, false);
  assert.equal(first.occurrenceAt, todayMorning);
  assert.equal(first.idempotent, false);
  const hit = { id: "c1", planId: "e1", occurrenceAt: todayMorning, byName: "Dr Sample", at: todayMorning };
  const second = R.r17EctDecide(plan, patient, { id: "r2", role: "admin" }, [hit]);
  assert.equal(second.idempotent, true);
  assert.equal(second.scheduleNext, false);
  assert.equal(R.r17EctDecide(plan, patient, { id: "c1", role: "consultant" }, []).ok, false);
  assert.equal(R.r17EctDecide(plan, patient, { id: "i1", role: "intern" }, []).ok, false);
  assert.equal(R.r17EctDecide(plan, { ...patient, admittedAt: "2026-11-08T02:30:00.000Z" }, { role: "resident" }, []).ok, false);
  const items = R.r17ScheduleItems([plan, { id: "e2", pid: "p9", status: "planned", nextAt: yesterday }], [patient], [hit], today);
  assert.equal(items.length, 1);
  assert.equal(items[0].done, true);
  const html = R.r17ScheduleHtml([
    { kind: "ect", planId: "e1", time: "09:00", txt: "ECT #4 · M-04", done: true, by: "Dr Sample", when: "07 Nov 2026, 09:00" },
    { kind: "note", time: "11:00", txt: "Family meeting", fn: "go('tasks')" }
  ]);
  assert.match(html, /Mark complete|Completed/);
  assert.match(html, /Dr Sample/);
  assert.match(html, /Undo/);
  assert.equal((html.match(/r17EctMark/g) || []).length, 0);
  assert.match(html, /Family meeting/);
  assert.ok(!html.includes("r17EctMark('note'") );
  const open = R.r17ScheduleHtml([{ kind: "ect", planId: "e9", time: "08:00", txt: "ECT #1 · F-02", done: false }]);
  assert.match(open, /Mark complete/);
  assert.match(open, /r17EctMark\('e9'\)/);
});
