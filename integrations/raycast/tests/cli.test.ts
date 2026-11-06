import assert from "node:assert/strict";
import { mkdtemp, writeFile, chmod, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { commandArguments, runDilated, statusDescription } from "../src/cli.ts";

test("commands use argument arrays and timed holds validate minutes", () => {
  assert.deepEqual(commandArguments("start"), [
    "on",
    "--label",
    "Raycast",
    "--json",
  ]);
  assert.deepEqual(commandArguments("stop"), ["off", "--json"]);
  assert.deepEqual(commandArguments("status"), ["status", "--json"]);
  assert.deepEqual(commandArguments("hold", "30"), [
    "on",
    "--for",
    "30m",
    "--label",
    "Raycast",
    "--json",
  ]);
  for (const invalid of [
    "",
    "0",
    "-1",
    "1.5",
    "30; touch x",
    "999999999999999999999",
  ]) {
    assert.throws(() => commandArguments("hold", invalid), /whole number/);
  }
});

test("the executable may contain spaces and apostrophes; arguments stay literal", async () => {
  const directory = await mkdtemp(join(tmpdir(), "dilated-raycast-"));
  try {
    const cli = join(directory, "Dilated's CLI");
    await writeFile(
      cli,
      `#!${process.execPath}\nconsole.log(JSON.stringify({ok:true,id:process.argv.slice(2).join('|')}));\n`,
    );
    await chmod(cli, 0o700);
    const response = await runDilated(cli, [
      "on",
      "--label",
      "a; $(whoami) 'quoted'",
      "--json",
    ]);
    assert.equal(response.id, "on|--label|a; $(whoami) 'quoted'|--json");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("paused, ended, malformed and missing CLI replies are actionable", async () => {
  const directory = await mkdtemp(join(tmpdir(), "dilated-raycast-"));
  try {
    const cli = join(directory, "fixture");
    for (const [body, code, message] of [
      [
        {
          ok: false,
          code: "automationPaused",
          message: "Automation is paused. Choose Resume automation in Dilated.",
        },
        4,
        /Resume automation/,
      ],
      [
        { ok: false, code: "holdNotFound", message: "That hold has ended." },
        1,
        /ended/,
      ],
      [{ nope: true }, 0, /invalid response/],
    ] as const) {
      await writeFile(
        cli,
        `#!${process.execPath}\nconsole.log(${JSON.stringify(JSON.stringify(body))});process.exit(${code});\n`,
      );
      await chmod(cli, 0o700);
      await assert.rejects(runDilated(cli, ["status", "--json"]), message);
    }
    await writeFile(cli, `#!${process.execPath}\nconsole.log('not JSON');\n`);
    await assert.rejects(
      runDilated(cli, ["status", "--json"]),
      /invalid response/,
    );
    await assert.rejects(
      runDilated(join(directory, "missing"), ["status"]),
      /Settings.*command line/i,
    );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("status distinguishes paused automation and independent active holds", () => {
  assert.equal(
    statusDescription({
      ok: true,
      snapshot: { holds: [], automationPaused: false },
    }),
    "No active holds. Automation running.",
  );
  assert.equal(
    statusDescription({
      ok: true,
      snapshot: { holds: [{ label: "Build" }], automationPaused: true },
    }),
    "1 active hold: Build. Automation paused.",
  );
  assert.throws(() => statusDescription({ ok: true }), /invalid response/);
});
